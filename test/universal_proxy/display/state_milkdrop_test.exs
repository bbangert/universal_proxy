defmodule UniversalProxy.Display.StateMilkDropTest do
  # The MilkDrop handover in Display.State, against a fake viewport
  # (`FakeRenderer`) and the fake renderer binary (a Python script).
  use ExUnit.Case, async: true

  @moduletag :capture_log
  @moduletag :tmp_dir
  @moduletag :python3

  import ExUnit.CaptureLog

  alias UniversalProxy.Display.FakeRenderer
  alias UniversalProxy.Display.MilkDrop, as: Renderer
  alias UniversalProxy.Display.Mode
  alias UniversalProxy.Display.State
  alias UniversalProxy.MilkDrop.Store

  @fake_binary Path.expand("../../support/fake_milkdrop_renderer.py", __DIR__)
  @key {"vc4-hdmi", nil, nil}
  @output %{key: @key, client_id: "c0", card_index: 1, display_roles: true}
  @adapter %{dev: "/dev/cec0", card_index: 1, phys_addr: "1.0.0.0", tv_presence: :present}
  @version "2026.11.1"
  @ring "/run/up-pcm-c0"
  # Each renderer event is a round trip through a Python process.
  @timeout 5_000

  setup context do
    sup = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    dri_dir = Path.join(context.tmp_dir, "dri")
    pack_dir = Path.join(context.tmp_dir, "pack")
    File.mkdir_p!(dri_dir)
    File.mkdir_p!(pack_dir)
    File.write!(Path.join(dri_dir, "card0"), "")
    skip_file = Path.join(context.tmp_dir, "skip.txt")
    on_exit(fn -> Enum.each(renderer_os_pids(skip_file), &kill_os_pid/1) end)
    %{sup: sup, dri_dir: dri_dir, pack_dir: pack_dir, skip_file: skip_file}
  end

  # Starts State with the UI and MilkDrop on (unless `milkdrop: false`),
  # the fake viewport running, fake audio/CEC/pack funs reporting to the
  # test. `:fake` is the fake renderer's fake.json.
  defp start_ui(ctx, opts \\ []) do
    test = self()
    pubsub = :"#{inspect(__MODULE__)}.#{ctx.test}.PubSub"
    start_supervised!({Phoenix.PubSub, name: pubsub})
    tasks = start_supervised!(Task.Supervisor)
    ready = {:ready, @version, ctx.pack_dir}

    if fake = opts[:fake],
      do: File.write!(Path.join(ctx.pack_dir, "fake.json"), Jason.encode!(fake))

    world =
      start_supervised!(
        {Agent,
         fn ->
           %{
             pack: Keyword.get(opts, :pack, ready),
             ensured: Keyword.get(opts, :ensured, Keyword.get(opts, :pack, ready))
           }
         end}
      )

    audio = %{
      list_outputs: fn -> [@output] end,
      display_snapshot: fn _key -> {0, %{}} end,
      controller: fn key, cmd ->
        send(test, {:audio, :controller, key, cmd})
        :ok
      end,
      viz_enable: fn _key, _on? -> :ok end,
      update_config: fn key, params -> send(test, {:audio, :update_config, key, params}) end,
      pcm_tap: fn key, on?, owner ->
        send(test, {:audio, :pcm_tap, key, on?})
        send(test, {:audio, :pcm_tap_owner, owner})
        :ok
      end,
      pcm_tap_status: fn _key -> {:ok, %{path: @ring, enabled: true}} end
    }

    pack = %{
      status: fn ->
        send(test, :pack_status)
        Agent.get(world, & &1.pack)
      end,
      ensure: fn ->
        send(test, :pack_ensure)
        Agent.get(world, & &1.ensured)
      end
    }

    cec = %{
      list_adapters: fn -> [@adapter] end,
      claim_keys: fn _dev, _pid -> :ok end,
      release_keys: fn _dev -> :ok end
    }

    skip_file = ctx.skip_file

    state =
      start_supervised!({
        State,
        name: :"#{inspect(__MODULE__)}.#{ctx.test}",
        ui: true,
        renderer: FakeRenderer,
        viewport_supervisor: ctx.sup,
        dri_dir: ctx.dri_dir,
        viewport_opts: [
          test_pid: test,
          on_start: fn -> send(test, {:viewport_start, cmd_names(skip_file)}) end
        ],
        view_opts: [bars: 8, drift_period_ms: 1_000_000_000_000],
        model_opts:
          Keyword.merge(
            [idle_ms: 60_000, restart_ms: 60_000, restart_max_ms: 60_000, stable_ms: 60_000],
            Keyword.get(opts, :model_opts, [])
          ),
        pubsub: pubsub,
        task_supervisor: tasks,
        audio: audio,
        cec: cec,
        pack: pack,
        milkdrop: Keyword.get(opts, :milkdrop, true),
        milkdrop_opts: [
          binary: @fake_binary,
          skip_file: skip_file,
          settings: Store.defaults(),
          skipped: %{},
          store: :"#{inspect(__MODULE__)}.NoStore",
          task_supervisor: tasks,
          kill_grace_ms: Keyword.get(opts, :kill_grace_ms, 300)
        ],
        milkdrop_timeouts: Keyword.get(opts, :timeouts, %{})
      })

    _ = :sys.get_state(state)
    assert_receive {:fake_renderer, :start, _opts}
    assert_receive {:viewport_start, []}
    Map.merge(ctx, %{state: state, pubsub: pubsub, world: world})
  end

  defp status(ctx), do: GenServer.call(ctx.state, :status)
  defp md(ctx), do: status(ctx).milkdrop

  defp viewport(ctx), do: GenServer.call(ctx.state, :viewport)

  defp playing(ctx) do
    Phoenix.PubSub.broadcast(
      ctx.pubsub,
      "sendspin:state",
      {:sendspin_state, @key, %{event: "stream_start"}}
    )

    ctx
  end

  defp paused(ctx) do
    Phoenix.PubSub.broadcast(
      ctx.pubsub,
      "sendspin:display",
      {:sendspin_display, @key, 100, %{event: "group", playback_state: "paused"}}
    )

    ctx
  end

  defp key(ctx, key), do: send(ctx.state, {:cec_key, "/dev/cec0", key})

  defp milkdrop_mode(ctx) do
    :ok = GenServer.call(ctx.state, {:set_mode, :milkdrop})
    ctx
  end

  # Playing in MilkDrop mode until the renderer presents.
  defp presenting(ctx) do
    vp = viewport(ctx)
    ctx |> milkdrop_mode() |> playing()
    assert_receive {:audio, :pcm_tap, @key, true}, @timeout
    assert_receive {:fake_renderer, :stop, ^vp}, @timeout
    wait_until(fn -> md(ctx).phase == :presenting end)
    ctx
  end

  defp renderer(ctx), do: md(ctx).renderer

  defp cmd_names(skip_file) do
    case File.read(skip_file <> ".cmds") do
      {:ok, body} ->
        body |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!(&1)["cmd"])

      {:error, _} ->
        []
    end
  end

  defp texts({:text, _attrs, s}), do: [s]

  defp texts({_tag, _attrs, children}) when is_list(children),
    do: Enum.flat_map(children, &texts/1)

  defp texts(_node), do: []

  # The next pushed screen whose texts satisfy `fun`.
  defp assert_pushed(fun) do
    receive do
      {:fake_renderer, :push, _vp, spec} ->
        if fun.(texts(spec)), do: spec, else: assert_pushed(fun)
    after
      @timeout -> flunk("no matching screen pushed")
    end
  end

  defp flush_stops do
    receive do
      {:fake_renderer, :stop, _vp} -> flush_stops()
    after
      0 -> :ok
    end
  end

  defp wait_until(fun, timeout \\ @timeout) do
    cond do
      fun.() ->
        :ok

      timeout <= 0 ->
        flunk("condition not met in time")

      true ->
        Process.sleep(20)
        wait_until(fun, timeout - 20)
    end
  end

  defp renderer_os_pids(skip_file) do
    for dir <- Path.wildcard("/proc/[0-9]*"),
        {:ok, cmdline} <- [File.read(Path.join(dir, "cmdline"))],
        skip_file in String.split(cmdline, <<0>>),
        do: dir |> Path.basename() |> String.to_integer()
  end

  defp kill_os_pid(os_pid),
    do: System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)

  # ── The handover ─────────────────────────────────────────────────────

  test "yield → present → keys → reclaim, in the handover's order", ctx do
    ctx = start_ui(ctx)
    ctx = presenting(ctx)

    assert %{
             phase: :presenting,
             ring: @ring,
             pack_version: @version,
             yield: true,
             latch: nil
           } = md(ctx)

    assert %{screen: :milkdrop, lifecycle: %{status: :yielded}, viewport: nil} = status(ctx)
    assert "take" in cmd_names(ctx.skip_file)

    key(ctx, :right)
    key(ctx, :left)
    key(ctx, :select)
    wait_until(fn -> Enum.take(cmd_names(ctx.skip_file), -3) == ["next", "prev", "lock"] end)
    wait_until(fn -> md(ctx).locked == true end)
    key(ctx, :select)
    wait_until(fn -> List.last(cmd_names(ctx.skip_file)) == "unlock" end)
    wait_until(fn -> md(ctx).locked == false and md(ctx).preset == "p0.milk" end)
    refute_received {:audio, :controller, _, _}

    paused(ctx)
    # The viewport is started again after `released`, before `exit`.
    assert_receive {:viewport_start, cmds}, @timeout
    assert List.last(cmds) == "release"
    assert_receive {:fake_renderer, :start, _opts}
    assert_receive {:audio, :pcm_tap, @key, false}, @timeout
    wait_until(fn -> md(ctx).phase == nil end)
    assert List.last(cmd_names(ctx.skip_file)) == "exit"
    assert %{last: %{outcome: :requested, phase: :exiting}, failures: 0} = md(ctx)
    assert %{lifecycle: %{status: :running}} = status(ctx)
  end

  test "the renderer's argv carries the connector, mode, pack, ring and ladder", ctx do
    ctx = ctx |> start_ui() |> presenting()
    %{os_pid: os_pid} = :sys.get_state(renderer(ctx))
    argv = "/proc/#{os_pid}/cmdline" |> File.read!() |> String.split(<<0>>, trim: true)

    # The viewport's own connector (vc4-hdmi is HDMI port 0), and its size
    # with no refresh pinned, so the renderer keeps Emerge's timing.
    for {flag, value} <- [
          {"--connector", "HDMI-A-1"},
          {"--mode", "1280x720"},
          {"--pack-dir", ctx.pack_dir},
          {"--pcm-ring", @ring},
          {"--ladder", "640x360,480x270"}
        ] do
      assert [^value | _] = argv |> Enum.drop_while(&(&1 != flag)) |> tl()
    end
  end

  test "the PCM tap is leased to State", ctx do
    ctx = ctx |> start_ui() |> presenting()
    state = ctx.state
    assert_received {:audio, :pcm_tap_owner, ^state}
  end

  test "Up/Down leave the mode and hand the display back", ctx do
    ctx = ctx |> start_ui() |> presenting()
    key(ctx, :down)
    assert_receive {:audio, :update_config, @key, %{display_mode: "Party QR"}}, @timeout
    assert_receive {:fake_renderer, :start, _opts}, @timeout
    wait_until(fn -> md(ctx).phase == nil end)
    assert %{mode: :party_qr, screen: :party_off} = status(ctx)
  end

  test "pausing before the renderer prepared just stops it; the viewport stays", ctx do
    ctx = start_ui(ctx, fake: %{hold_prepared: true})
    vp = viewport(ctx)
    ctx |> milkdrop_mode() |> playing()
    wait_until(fn -> md(ctx).phase == :preparing end)

    paused(ctx)
    wait_until(fn -> md(ctx).phase == nil end)
    assert cmd_names(ctx.skip_file) == ["exit"]
    assert %{last: %{outcome: :requested, phase: :exiting}} = md(ctx)
    assert viewport(ctx) == vp
    refute_received {:fake_renderer, :stop, _}
    refute_received {:fake_renderer, :start, _}
    assert_received {:audio, :pcm_tap, @key, false}
  end

  # ── Failures ─────────────────────────────────────────────────────────

  test "a renderer crash restarts the viewport at once (no backoff)", ctx do
    ctx = ctx |> start_ui() |> presenting()
    Renderer.command(renderer(ctx), %{cmd: "crash", status: 3})

    assert_receive {:fake_renderer, :start, _opts}, @timeout
    assert_receive {:audio, :pcm_tap, @key, false}, @timeout
    wait_until(fn -> md(ctx).phase == nil end)
    assert %{last: %{outcome: {:crashed, 3}, phase: :presenting}, failures: 1} = md(ctx)
    assert %{lifecycle: %{status: :running}, screen: {:visualizer, false}} = status(ctx)
  end

  test "a killed port owner counts as a crash too", ctx do
    ctx = ctx |> start_ui() |> presenting()
    Process.exit(renderer(ctx), :kill)

    assert_receive {:fake_renderer, :start, _opts}, @timeout
    wait_until(fn -> md(ctx).phase == nil end)
    assert %{last: %{outcome: {:crashed, {:down, :killed}}}} = md(ctx)
  end

  # A renderer that outlives its port may still hold DRM master: the
  # viewport waits until the reaper has it gone.
  test "after a killed port owner the viewport waits for the renderer to be reaped", ctx do
    ctx = ctx |> start_ui(fake: %{ignore_eof: true}, kill_grace_ms: 500) |> presenting()
    %{os_pid: os_pid} = :sys.get_state(renderer(ctx))

    Process.exit(renderer(ctx), :kill)
    wait_until(fn -> md(ctx).phase == :reaping end)
    assert File.exists?("/proc/#{os_pid}")
    refute_received {:fake_renderer, :start, _opts}

    assert_receive {:fake_renderer, :start, _opts}, @timeout
    refute File.exists?("/proc/#{os_pid}")
    refute File.exists?(ctx.skip_file <> ".eof")

    assert %{phase: nil, last: %{outcome: {:crashed, {:down, :killed}}, phase: :presenting}} =
             md(ctx)

    assert %{lifecycle: %{status: :running}} = status(ctx)
  end

  test "a timed-out release of a renderer ignoring EOF restarts the viewport once it is reaped",
       ctx do
    ctx =
      start_ui(ctx,
        fake: %{ignore: ["release"], ignore_eof: true},
        timeouts: %{releasing: 200},
        kill_grace_ms: 500
      )

    ctx = presenting(ctx)
    %{os_pid: os_pid} = :sys.get_state(renderer(ctx))

    paused(ctx)
    wait_until(fn -> md(ctx).phase == :reaping end)
    assert File.exists?("/proc/#{os_pid}")
    assert_receive {:fake_renderer, :start, _opts}, @timeout
    refute File.exists?("/proc/#{os_pid}")
    assert_received {:audio, :pcm_tap, @key, false}
    assert %{last: %{outcome: {:crashed, {:timeout, :releasing}}}, failures: 1} = md(ctx)
  end

  test "a renderer never confirmed gone still gets the display back, bounded", ctx do
    log =
      capture_log(fn ->
        ctx =
          start_ui(ctx,
            fake: %{ignore_eof: true},
            timeouts: %{reaping: 300},
            kill_grace_ms: 60_000
          )

        ctx = presenting(ctx)
        %{os_pid: os_pid} = :sys.get_state(renderer(ctx))

        Process.exit(renderer(ctx), :kill)
        wait_until(fn -> md(ctx).phase == :reaping end)
        assert_receive {:fake_renderer, :start, _opts}, @timeout
        assert File.exists?("/proc/#{os_pid}")
        wait_until(fn -> md(ctx).phase == nil end)
        assert %{last: %{outcome: {:crashed, {:down, :killed}}}} = md(ctx)
      end)

    assert log =~ "not confirmed gone in time"
  end

  test "three failures latch MilkDrop off until the mode is chosen again", ctx do
    log =
      capture_log(fn ->
        ctx =
          start_ui(ctx, fake: %{take_exit: 4}, model_opts: [milkdrop_retry_ms: 1])

        ctx |> milkdrop_mode() |> playing()

        for _ <- 1..3, do: assert_receive({:fake_renderer, :start, _opts}, @timeout)
        wait_until(fn -> md(ctx).latch == :crashed end)
        assert %{phase: nil, yield: false, failures: 3} = md(ctx)
        assert %{mode: :milkdrop, screen: {:visualizer, false}} = status(ctx)

        # No fourth attempt.
        flush_stops()
        refute_receive {:fake_renderer, :stop, _}, 300

        # Choosing MilkDrop again is a new session.
        File.rm!(Path.join(ctx.pack_dir, "fake.json"))
        milkdrop_mode(ctx)
        wait_until(fn -> md(ctx).phase == :presenting end)
        assert md(ctx).latch == nil
      end)

    assert log =~ "MilkDrop off until the mode is chosen again: 3 renderer failures"
  end

  test "a timed-out release kills the renderer and restarts the viewport", ctx do
    ctx = start_ui(ctx, fake: %{ignore: ["release"]}, timeouts: %{releasing: 200})
    ctx = presenting(ctx)
    %{os_pid: os_pid} = :sys.get_state(renderer(ctx))

    log =
      capture_log(fn ->
        paused(ctx)
        assert_receive {:fake_renderer, :start, _opts}, @timeout
        wait_until(fn -> md(ctx).phase == nil end)
      end)

    assert log =~ "handover failed ({:timeout, :releasing})"
    assert %{last: %{outcome: {:crashed, {:timeout, :releasing}}}, failures: 1} = md(ctx)
    wait_until(fn -> not File.exists?("/proc/#{os_pid}") end)
    assert_received {:audio, :pcm_tap, @key, false}
  end

  test "a take the renderer reports failed hands the display back at once", ctx do
    ctx = start_ui(ctx, fake: %{take_error: "master_timeout"})
    ctx |> milkdrop_mode() |> playing()
    assert_receive {:fake_renderer, :stop, _vp}, @timeout
    assert_receive {:fake_renderer, :start, _opts}, @timeout
    wait_until(fn -> md(ctx).phase == nil end)
    assert %{last: %{outcome: {:crashed, {:take_failed, "master_timeout"}}}} = md(ctx)
  end

  test "a thermal exit shows the bars until the mode is chosen again", ctx do
    ctx = ctx |> start_ui() |> presenting()
    Renderer.command(renderer(ctx), %{cmd: "thermal"})

    assert_receive {:fake_renderer, :start, _opts}, @timeout
    wait_until(fn -> md(ctx).latch == :thermal end)
    assert %{last: %{outcome: :thermal}, failures: 0} = md(ctx)
    assert %{screen: {:visualizer, false}, viz: :full} = status(ctx)

    milkdrop_mode(ctx)
    wait_until(fn -> md(ctx).phase == :presenting end)
  end

  # ── The pack ─────────────────────────────────────────────────────────

  test "no pack yet: it is asked for, and the preparing screen shows its progress", ctx do
    ctx = start_ui(ctx, pack: :absent, ensured: {:downloading, 0})
    assert_received :pack_status
    milkdrop_mode(ctx)
    assert_receive :pack_ensure, @timeout
    assert_pushed(&("Preparing visualizer…" in &1))

    Phoenix.PubSub.broadcast(
      ctx.pubsub,
      UniversalProxy.MilkDrop.pack_topic(),
      {:milkdrop_pack, {:downloading, 40}}
    )

    assert_pushed(&("Preparing visualizer… 40%" in &1))
    playing(ctx)
    assert %{screen: {:milkdrop_preparing, 40}} = status(ctx)

    Phoenix.PubSub.broadcast(
      ctx.pubsub,
      UniversalProxy.MilkDrop.pack_topic(),
      {:milkdrop_pack, {:ready, @version, ctx.pack_dir}}
    )

    assert_receive {:audio, :pcm_tap, @key, true}, @timeout
    wait_until(fn -> md(ctx).phase == :presenting end)
  end

  test "a Pack restarted mid-download is asked for the pack again", ctx do
    ctx = start_ui(ctx, pack: :absent, ensured: {:downloading, 0})
    milkdrop_mode(ctx)
    assert_receive :pack_ensure, @timeout

    Phoenix.PubSub.broadcast(
      ctx.pubsub,
      UniversalProxy.MilkDrop.pack_topic(),
      {:milkdrop_pack, {:downloading, 40}}
    )

    assert_pushed(&("Preparing visualizer… 40%" in &1))

    # The crashed Pack's download died with it; the new one starts absent.
    Phoenix.PubSub.broadcast(
      ctx.pubsub,
      UniversalProxy.MilkDrop.pack_topic(),
      {:milkdrop_pack_started, :absent}
    )

    assert_receive :pack_ensure, @timeout
    assert %{screen: {:milkdrop_preparing, nil}, milkdrop: %{pack: :absent}} = status(ctx)
  end

  test "a pack error shows a short notice, then the bars", ctx do
    ctx =
      start_ui(ctx,
        pack: {:error, :no_pack_pinned},
        model_opts: [milkdrop_notice_ms: 100]
      )

    ctx |> milkdrop_mode() |> playing()
    assert_receive :pack_ensure, @timeout
    assert_pushed(&("Visualizer unavailable" in &1))
    assert_pushed(&("Visualizer unavailable" not in &1))
    assert %{screen: {:visualizer, false}, milkdrop: %{phase: nil}} = status(ctx)
    refute_received {:audio, :pcm_tap, _, _}
  end

  # ── The flag ─────────────────────────────────────────────────────────

  test "with MilkDrop off nothing changes", ctx do
    ctx = start_ui(ctx, milkdrop: false)
    refute_received :pack_status
    refute "MilkDrop" in Mode.options()

    assert GenServer.call(ctx.state, {:set_mode, :milkdrop}) == :ok
    playing(ctx)

    Phoenix.PubSub.broadcast(
      ctx.pubsub,
      UniversalProxy.MilkDrop.pack_topic(),
      {:milkdrop_pack, {:ready, @version, ctx.pack_dir}}
    )

    status = status(ctx)
    assert %{mode: :now_playing, screen: {:now_playing, false}} = status
    refute Map.has_key?(status, :milkdrop)
    refute_received :pack_ensure
    refute_received {:audio, :pcm_tap, _, _}
    refute_received {:fake_renderer, :stop, _}
  end
end
