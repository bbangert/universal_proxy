defmodule UniversalProxy.Display.StateMilkDropTest do
  # The MilkDrop handover in Display.State, against a fake viewport
  # (`FakeRenderer`) and the fake renderer binary (a Python script).
  use ExUnit.Case, async: true

  @moduletag :capture_log
  @moduletag :tmp_dir
  @moduletag :python3

  import ExUnit.CaptureLog

  alias UniversalProxy.Display
  alias UniversalProxy.Display.FakeRenderer
  alias UniversalProxy.Display.MilkDrop, as: Renderer
  alias UniversalProxy.Display.Mode
  alias UniversalProxy.Display.State
  alias UniversalProxy.Display.Supervisor, as: DisplaySupervisor
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
    sysfs_dir = Path.join(context.tmp_dir, "sys")
    pack_dir = Path.join(context.tmp_dir, "pack")
    File.mkdir_p!(dri_dir)
    File.mkdir_p!(pack_dir)
    # card1 drives the HDMI connectors (as vc4 does on a Pi 4); card0 has none.
    File.write!(Path.join(dri_dir, "card0"), "")
    File.write!(Path.join(dri_dir, "card1"), "")
    Enum.each(~w(card0 card1 card1-HDMI-A-1), &File.mkdir_p!(Path.join(sysfs_dir, &1)))
    skip_file = Path.join(context.tmp_dir, "skip.txt")
    on_exit(fn -> Enum.each(renderer_os_pids(skip_file), &kill_os_pid/1) end)
    %{sup: sup, dri_dir: dri_dir, sysfs_dir: sysfs_dir, pack_dir: pack_dir, skip_file: skip_file}
  end

  # Starts State with the UI and MilkDrop on (unless `milkdrop: false`),
  # the fake viewport running, fake audio/CEC/pack funs reporting to the
  # test. `:fake` is the fake renderer's fake.json. `supervised: true` runs
  # it in its own `Display.Supervisor` subtree (the reaper under the
  # subtree's Task.Supervisor), and each viewport start also reports the
  # renderers still running then as `{:viewport_renderers, os_pids}`.
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
             ensured: Keyword.get(opts, :ensured, Keyword.get(opts, :pack, ready)),
             viewport_fails: 0
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

        case Agent.get(world, & &1.ensured) do
          answer when is_function(answer, 0) -> answer.()
          answer -> answer
        end
      end
    }

    cec = %{
      list_adapters: fn -> [@adapter] end,
      claim_keys: fn _dev, _pid -> :ok end,
      release_keys: fn _dev -> :ok end
    }

    skip_file = ctx.skip_file
    supervised? = Keyword.get(opts, :supervised, false)
    name = :"#{inspect(__MODULE__)}.#{ctx.test}"

    on_start = fn ->
      send(test, {:viewport_start, cmd_names(skip_file)})
      if supervised?, do: send(test, {:viewport_renderers, renderer_os_pids(skip_file)})
    end

    # The next `viewport_fails` viewport starts fail (`:always`: all of them).
    start_error = fn ->
      Agent.get_and_update(world, fn
        %{viewport_fails: :always} = w ->
          {{:error, :no_display}, w}

        %{viewport_fails: n} = w when n > 0 ->
          {{:error, :no_display}, %{w | viewport_fails: n - 1}}

        w ->
          {:ok, w}
      end)
    end

    state_opts = [
      name: name,
      ui: true,
      renderer: FakeRenderer,
      viewport_supervisor: ctx.sup,
      dri_dir: ctx.dri_dir,
      sysfs_drm_dir: ctx.sysfs_dir,
      viewport_opts: [test_pid: test, on_start: on_start, start_error: start_error],
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
      milkdrop_opts:
        Keyword.merge(
          [
            binary: @fake_binary,
            skip_file: skip_file,
            settings: Store.defaults(),
            skipped: %{},
            store: :"#{inspect(__MODULE__)}.NoStore",
            user_dir: nil,
            kill_grace_ms: Keyword.get(opts, :kill_grace_ms, 300)
          ],
          Keyword.get(opts, :milkdrop_opts, [])
        ) ++ if(supervised?, do: [], else: [task_supervisor: tasks]),
      milkdrop_timeouts: Keyword.get(opts, :timeouts, %{})
    ]

    state =
      if supervised? do
        start_supervised!(
          {DisplaySupervisor,
           [
             enabled: true,
             name: :"#{name}.Supervisor",
             state_name: name,
             viewport_supervisor: :"#{name}.ViewportSupervisor",
             milkdrop_task_supervisor: :"#{name}.MilkDropTaskSupervisor"
           ] ++ Keyword.drop(state_opts, [:name, :viewport_supervisor])}
        )

        name
      else
        start_supervised!({State, state_opts})
      end

    _ = :sys.get_state(state)
    assert_receive {:fake_renderer, :start, viewport_opts}
    assert_receive {:viewport_start, []}
    Map.merge(ctx, %{state: state, pubsub: pubsub, world: world, viewport_opts: viewport_opts})
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

  defp cmds(skip_file) do
    case File.read(skip_file <> ".cmds") do
      {:ok, body} -> body |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      {:error, _} -> []
    end
  end

  defp sent_commands(ctx),
    do: Enum.filter(cmds(ctx.skip_file), &(&1["cmd"] in ["set_rotate", "set_high_frequency"]))

  defp sent_settings(ctx), do: length(sent_commands(ctx))

  defp settings_changed(ctx, changes) do
    Phoenix.PubSub.broadcast(
      ctx.pubsub,
      UniversalProxy.MilkDrop.settings_topic(),
      {:milkdrop_settings, Map.merge(Store.defaults(), changes)}
    )
  end

  defp library_changed(ctx) do
    Phoenix.PubSub.broadcast(
      ctx.pubsub,
      UniversalProxy.MilkDrop.user_presets_topic(),
      {:milkdrop_user_presets,
       %{added: ["user/a.milk"], replaced: [], removed: [], updated: [], textures: []}}
    )
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

  test "a settings change reaches the presenting renderer at once", ctx do
    ctx = ctx |> start_ui() |> presenting()

    settings_changed(ctx, %{rotate_s: 45, include_high_frequency: true})

    wait_until(fn ->
      Enum.take(cmds(ctx.skip_file), -3) == [
        %{"cmd" => "set_rotate", "value" => 45},
        %{"cmd" => "set_high_frequency", "value" => true},
        %{"cmd" => "set_min_fps", "value" => 20}
      ]
    end)

    # Turning fast-flashing presets off again applies just as fast.
    settings_changed(ctx, %{rotate_s: 45, include_high_frequency: false})

    wait_until(fn ->
      List.last(cmds(ctx.skip_file)) == %{"cmd" => "set_high_frequency", "value" => false}
    end)
  end

  test "only the settings that changed are sent: a rotation-only change leaves the filter alone",
       ctx do
    ctx = ctx |> start_ui() |> presenting()

    settings_changed(ctx, %{rotate_s: 45, include_high_frequency: true})
    wait_until(fn -> sent_settings(ctx) == 2 end)

    # A rotation-only change, then a repeat of everything (a lock the
    # renderer persisted broadcasts the same values again).
    settings_changed(ctx, %{rotate_s: 60, include_high_frequency: true})
    settings_changed(ctx, %{rotate_s: 60, include_high_frequency: true, locked: "a/b.milk"})
    wait_until(fn -> sent_settings(ctx) == 3 end)
    _ = :sys.get_state(ctx.state)

    assert sent_commands(ctx) == [
             %{"cmd" => "set_rotate", "value" => 45},
             %{"cmd" => "set_high_frequency", "value" => true},
             %{"cmd" => "set_rotate", "value" => 60}
           ]

    # Turning the filter back on (excluding them) still goes out at once.
    settings_changed(ctx, %{rotate_s: 60, include_high_frequency: false})

    wait_until(fn ->
      List.last(cmds(ctx.skip_file)) == %{"cmd" => "set_high_frequency", "value" => false}
    end)
  end

  test "a minimum frame rate change is sent only when it changes", ctx do
    ctx = ctx |> start_ui() |> presenting()
    min_fps_cmds = fn -> Enum.filter(cmds(ctx.skip_file), &(&1["cmd"] == "set_min_fps")) end

    settings_changed(ctx, %{min_fps: 30})
    wait_until(fn -> min_fps_cmds.() == [%{"cmd" => "set_min_fps", "value" => 30}] end)

    # Other settings changing, or the same value again, send nothing.
    settings_changed(ctx, %{min_fps: 30, rotate_s: 60})
    settings_changed(ctx, %{min_fps: 30, rotate_s: 60, locked: "a/b.milk"})

    wait_until(fn ->
      List.last(cmds(ctx.skip_file)) == %{"cmd" => "set_rotate", "value" => 60}
    end)

    _ = :sys.get_state(ctx.state)
    assert length(min_fps_cmds.()) == 1

    settings_changed(ctx, %{min_fps: 25, rotate_s: 60})

    wait_until(fn ->
      min_fps_cmds.() == [
        %{"cmd" => "set_min_fps", "value" => 30},
        %{"cmd" => "set_min_fps", "value" => 25}
      ]
    end)
  end

  test "settings changed before a session aren't sent: the renderer reads them at start", ctx do
    ctx = start_ui(ctx)
    settings_changed(ctx, %{include_high_frequency: true})
    _ = :sys.get_state(ctx.state)

    ctx = presenting(ctx)

    refute Enum.any?(
             cmd_names(ctx.skip_file),
             &(&1 in ["set_rotate", "set_high_frequency", "set_min_fps"])
           )
  end

  test "an upload library change reaches the presenting renderer as reload_user", ctx do
    ctx = start_ui(ctx)

    # Before a session there is nothing to tell: the renderer reads the
    # library at start.
    library_changed(ctx)
    _ = :sys.get_state(ctx.state)
    ctx = presenting(ctx)
    refute "reload_user" in cmd_names(ctx.skip_file)

    library_changed(ctx)
    wait_until(fn -> List.last(cmd_names(ctx.skip_file)) == "reload_user" end)
    library_changed(ctx)
    wait_until(fn -> Enum.count(cmd_names(ctx.skip_file), &(&1 == "reload_user")) == 2 end)

    # A restarted library may have repaired its manifest.
    Phoenix.PubSub.broadcast(
      ctx.pubsub,
      UniversalProxy.MilkDrop.user_presets_topic(),
      {:milkdrop_user_presets_started, %{bytes: 0, presets: 0, textures: 0}}
    )

    wait_until(fn -> Enum.count(cmd_names(ctx.skip_file), &(&1 == "reload_user")) == 3 end)
  end

  # ── Preset selection, play and now-playing ───────────────────────────

  defp selection_changed(ctx, changes) do
    Phoenix.PubSub.broadcast(
      ctx.pubsub,
      UniversalProxy.MilkDrop.selection_topic(),
      {:milkdrop_selection, Map.merge(Store.empty_selection(), changes)}
    )
  end

  defp reloads(ctx), do: Enum.count(cmd_names(ctx.skip_file), &(&1 == "reload_selection"))

  defp play(ctx, id, lock? \\ false), do: Display.milkdrop_play(ctx.state, id, lock?)

  test "a selection reaches the renderer once per generation, and only during a session", ctx do
    selection_file = Path.join(ctx.tmp_dir, "selection.json")
    started = %{Store.empty_selection() | gen: 7, favourites: ["a.milk"]}
    ctx = start_ui(ctx, milkdrop_opts: [selection_file: selection_file, selection: started])

    # Before a session there is nothing to tell: the renderer reads the
    # Store's at start.
    selection_changed(ctx, %{gen: 8})
    _ = :sys.get_state(ctx.state)
    ctx = presenting(ctx)

    # It reports the generation it started with, which isn't sent again.
    wait_until(fn -> match?(%{selection: %{gen: 7, eligible: 10}}, md(ctx)) end)
    selection_changed(ctx, %{gen: 7})
    _ = :sys.get_state(ctx.state)
    assert reloads(ctx) == 0

    selection_changed(ctx, %{gen: 9, hidden: ["p0.milk"]})
    wait_until(fn -> md(ctx).selection.gen == 9 end)
    assert %{eligible: 9, playlist_fallback: false} = md(ctx).selection

    selection_changed(ctx, %{gen: 9, hidden: ["p0.milk"]})
    selection_changed(ctx, %{gen: 10, playlist: ["zzz.milk"], playlist_enabled: true})
    wait_until(fn -> md(ctx).selection.gen == 10 end)
    assert %{eligible: 10, playlist_fallback: true} = md(ctx).selection
    assert reloads(ctx) == 2

    assert %{"gen" => 10, "playlist" => ["zzz.milk"], "playlist_enabled" => true} =
             Jason.decode!(File.read!(selection_file))
  end

  test "play answers once the preset shows; a refusal with its reason", ctx do
    ctx = ctx |> start_ui(fake: %{refuse: %{"bad.milk" => "high_frequency"}}) |> presenting()

    assert play(ctx, "user/up.milk", true) == :ok
    assert %{preset: "user/up.milk", locked: true, pending_play: nil} = md(ctx)

    assert play(ctx, "bad.milk") == {:error, {:refused, :high_frequency}}
    assert %{preset: "user/up.milk", pending_play: nil} = md(ctx)

    assert %{"cmd" => "play", "preset" => "bad.milk", "lock" => false} =
             List.last(cmds(ctx.skip_file))
  end

  test "play without a session is answered at once; with a lock, the lock is saved", ctx do
    store =
      start_supervised!(
        {Store, name: nil, table: :"#{ctx.test}", dets_path: Path.join(ctx.tmp_dir, "s.dets")}
      )

    ctx = start_ui(ctx)
    opts = [display: ctx.state, store: store]

    assert UniversalProxy.MilkDrop.play("a.milk", false, opts) == {:error, :not_presenting}
    assert Store.settings(store).locked == nil
    assert UniversalProxy.MilkDrop.play("a.milk", true, opts) == {:error, :not_presenting}
    assert Store.settings(store).locked == "a.milk"
    assert UniversalProxy.MilkDrop.play("bad\nid", true, opts) == {:error, :invalid_id}

    assert UniversalProxy.MilkDrop.play("a.milk", false, display: :"#{ctx.test}.Gone") ==
             {:error, :not_presenting}

    refute "play" in cmd_names(ctx.skip_file)
  end

  test "an unanswered play times out; a renderer that never answers is unresponsive", ctx do
    ctx = ctx |> start_ui(fake: %{ignore: ["play"]}, timeouts: %{play: 300}) |> presenting()

    assert play(ctx, "a.milk") == {:error, :timeout}

    # Still in flight: a newer play waits behind it, and is superseded.
    first = Task.async(fn -> play(ctx, "a.milk") end)
    wait_until(fn -> md(ctx).pending_play == "a.milk" end)
    second = Task.async(fn -> play(ctx, "b.milk") end)
    assert Task.await(first) == {:error, :superseded}

    # Two play timeouts without an answer: plays are refused from then on.
    assert Task.await(second) == {:error, :unresponsive}
    assert play(ctx, "c.milk") == {:error, :unresponsive}
    assert Enum.count(cmd_names(ctx.skip_file), &(&1 == "play")) == 1
  end

  test "an answer after its caller timed out is not taken for a later play", ctx do
    ctx =
      ctx
      |> start_ui(fake: %{play_delays: [700]}, timeouts: %{play: 500})
      |> presenting()

    assert play(ctx, "a.milk", true) == {:error, :timeout}
    # Written only once the first is answered (locked: true), and answered
    # by its own preset event.
    assert play(ctx, "a.milk", false) == :ok
    assert %{preset: "a.milk", locked: false, pending_play: nil} = md(ctx)

    assert Enum.filter(cmds(ctx.skip_file), &(&1["cmd"] == "play")) == [
             %{"cmd" => "play", "preset" => "a.milk", "lock" => true},
             %{"cmd" => "play", "preset" => "a.milk", "lock" => false}
           ]
  end

  test "next and prev wait for the play in flight", ctx do
    ctx = ctx |> start_ui(fake: %{play_delays: [300]}) |> presenting()

    pending = Task.async(fn -> play(ctx, "x.milk") end)
    wait_until(fn -> md(ctx).pending_play == "x.milk" end)
    key(ctx, :right)
    _ = :sys.get_state(ctx.state)
    refute "next" in cmd_names(ctx.skip_file)

    assert Task.await(pending) == :ok
    wait_until(fn -> md(ctx).preset == "p1.milk" end)
    assert Enum.take(cmd_names(ctx.skip_file), -2) == ["play", "next"]
  end

  test "after a play, lock and unlock name the preset it showed", ctx do
    ctx = ctx |> start_ui() |> presenting()
    assert play(ctx, "x.milk") == :ok
    key(ctx, :select)
    wait_until(fn -> md(ctx).locked == true end)
    assert md(ctx).preset == "x.milk"
  end

  test "a repeat play of the same id waits for the earlier one's answer", ctx do
    ctx = ctx |> start_ui(fake: %{play_delays: [300]}) |> presenting()

    first = Task.async(fn -> play(ctx, "a.milk", true) end)
    wait_until(fn -> md(ctx).pending_play == "a.milk" end)
    second = Task.async(fn -> play(ctx, "a.milk", false) end)
    assert Task.await(first) == {:error, :superseded}

    # Not answered by the first command's `preset` (locked: true).
    assert Task.await(second) == :ok
    assert %{preset: "a.milk", locked: false, pending_play: nil} = md(ctx)

    assert Enum.filter(cmds(ctx.skip_file), &(&1["cmd"] == "play")) == [
             %{"cmd" => "play", "preset" => "a.milk", "lock" => true},
             %{"cmd" => "play", "preset" => "a.milk", "lock" => false}
           ]
  end

  test "a selection the renderer didn't get is sent again until it is", ctx do
    selection_file = Path.join(ctx.tmp_dir, "selection.json")

    ctx =
      ctx
      |> start_ui(
        milkdrop_opts: [selection_file: selection_file],
        timeouts: %{selection_retry: 50}
      )
      |> presenting()

    wait_until(fn -> match?(%{selection: %{gen: 0}}, md(ctx)) end)
    # The adapter's temporary file can't be created for now.
    File.mkdir_p!(selection_file <> ".tmp")

    capture_log(fn ->
      selection_changed(ctx, %{gen: 3, favourites: ["a.milk"]})
      wait_until(fn -> md(ctx).selection_retries >= 2 end)
    end)

    assert reloads(ctx) == 0
    File.rmdir!(selection_file <> ".tmp")
    wait_until(fn -> md(ctx).selection.gen == 3 end)
    assert reloads(ctx) == 1
    assert md(ctx).selection_retries == 0
    assert %{"gen" => 3, "favourites" => ["a.milk"]} = Jason.decode!(File.read!(selection_file))
  end

  test "an older selection's late answer doesn't acknowledge the one being retried", ctx do
    selection_file = Path.join(ctx.tmp_dir, "selection.json")

    ctx =
      ctx
      |> start_ui(
        milkdrop_opts: [selection_file: selection_file],
        timeouts: %{selection_retry: 600}
      )
      |> presenting()

    wait_until(fn -> match?(%{selection: %{gen: 0}}, md(ctx)) end)
    File.mkdir_p!(selection_file <> ".tmp")

    capture_log(fn ->
      selection_changed(ctx, %{gen: 2})
      wait_until(fn -> md(ctx).selection_retries == 1 end)
    end)

    # gen 1's answer arrives late.
    Renderer.command(renderer(ctx), %{
      cmd: "emit",
      line:
        ~s({"event":"selection","gen":1,"eligible":10,"playlist_fallback":false,"hidden_fallback":false})
    })

    wait_until(fn -> md(ctx).selection.gen == 1 end)
    assert md(ctx).selection_retries == 1

    File.rmdir!(selection_file <> ".tmp")
    wait_until(fn -> md(ctx).selection.gen == 2 end)
    assert md(ctx).selection_retries == 0
  end

  test "a retiring session's late lock doesn't overwrite one saved after it", ctx do
    store =
      start_supervised!(
        {Store,
         name: nil,
         table: :"#{ctx.test}",
         dets_path: Path.join(ctx.tmp_dir, "s.dets"),
         in_flight_grace_ms: 0}
      )

    ctx =
      ctx
      |> start_ui(fake: %{play_delays: [800]}, milkdrop_opts: [store: store])
      |> presenting()

    opts = [display: ctx.state, store: store]
    pending = Task.async(fn -> UniversalProxy.MilkDrop.play("a.milk", true, opts) end)
    wait_until(fn -> md(ctx).pending_play == "a.milk" end)
    paused(ctx)
    assert Task.await(pending) == {:error, :not_presenting}

    assert UniversalProxy.MilkDrop.play("b.milk", true, opts) == {:error, :not_presenting}
    assert Store.settings(store).locked == "b.milk"

    # The renderer answers the play (locked: true) before `released`, so
    # its lock write has been tried once the session is over.
    wait_until(fn -> md(ctx).phase == nil end)
    assert Store.settings(store).locked == "b.milk"
  end

  test "a stale selection retry doesn't fire the one armed after it", ctx do
    selection_file = Path.join(ctx.tmp_dir, "selection.json")

    ctx =
      ctx
      |> start_ui(
        milkdrop_opts: [selection_file: selection_file],
        timeouts: %{selection_retry: 60_000}
      )
      |> presenting()

    wait_until(fn -> match?(%{selection: %{gen: 0}}, md(ctx)) end)
    File.mkdir_p!(selection_file <> ".tmp")

    capture_log(fn ->
      selection_changed(ctx, %{gen: 2})
      wait_until(fn -> md(ctx).selection_retries == 1 end)
    end)

    %{md: %{selection_retry: armed}} = :sys.get_state(ctx.state)
    # A message from a retry cancelled before this one was armed.
    send(ctx.state, {:milkdrop_selection_retry, make_ref()})
    assert %{md: %{selection_retry: ^armed}} = :sys.get_state(ctx.state)

    # The armed one's own message does resend.
    File.rmdir!(selection_file <> ".tmp")
    send(ctx.state, {:milkdrop_selection_retry, armed.ref})
    wait_until(fn -> md(ctx).selection.gen == 2 end)
    Process.cancel_timer(armed.timer)
  end

  test "a play pending when the session is reclaimed or ends is answered not_presenting", ctx do
    ctx = ctx |> start_ui(fake: %{ignore: ["play"]}) |> presenting()

    pending = Task.async(fn -> play(ctx, "a.milk") end)
    wait_until(fn -> md(ctx).pending_play == "a.milk" end)
    paused(ctx)
    assert Task.await(pending) == {:error, :not_presenting}
    wait_until(fn -> md(ctx).phase == nil end)

    playing(ctx)
    wait_until(fn -> md(ctx).phase == :presenting end)
    pending = Task.async(fn -> play(ctx, "b.milk") end)
    wait_until(fn -> md(ctx).pending_play == "b.milk" end)
    Renderer.command(renderer(ctx), %{cmd: "crash", status: 3})
    assert Task.await(pending) == {:error, :not_presenting}
  end

  test "now-playing is broadcast while presenting and goes idle when the session ends", ctx do
    ctx = start_ui(ctx, fake: %{startup_preset: "s.milk"})
    Phoenix.PubSub.subscribe(ctx.pubsub, UniversalProxy.MilkDrop.now_playing_topic())
    assert Display.milkdrop_now_playing(ctx.state) == State.idle_now_playing()
    ctx = presenting(ctx)

    assert_receive {:milkdrop_now_playing,
                    %{
                      preset: "s.milk",
                      locked: false,
                      selection: %{
                        gen: 0,
                        eligible: 10,
                        playlist_fallback: false,
                        hidden_fallback: false
                      }
                    }},
                   @timeout

    assert play(ctx, "x.milk", true) == :ok
    assert_receive {:milkdrop_now_playing, %{preset: "x.milk", locked: true}}, @timeout

    assert %{preset: "x.milk", locked: true} =
             UniversalProxy.MilkDrop.now_playing(display: ctx.state)

    # Nothing changed, nothing sent.
    Renderer.command(renderer(ctx), %{cmd: "stats", ms: 1_000_000})
    _ = :sys.get_state(ctx.state)
    refute_received {:milkdrop_now_playing, _}

    paused(ctx)
    assert_receive {:milkdrop_now_playing, now}, @timeout
    assert now == State.idle_now_playing()
    wait_until(fn -> md(ctx).phase == nil end)
    refute_received {:milkdrop_now_playing, _}
    assert Display.milkdrop_now_playing(ctx.state) == State.idle_now_playing()
    assert Display.milkdrop_now_playing(:"#{ctx.test}.Gone") == State.idle_now_playing()
  end

  test "a viewport that fails to start after the release gets the renderer's exit only once it runs",
       ctx do
    ctx = ctx |> start_ui(model_opts: [restart_ms: 200]) |> presenting()
    pid = renderer(ctx)
    Agent.update(ctx.world, &%{&1 | viewport_fails: 1})

    log =
      capture_log(fn ->
        paused(ctx)
        assert_receive {:viewport_start, cmds}, @timeout
        assert List.last(cmds) == "release"
        wait_until(fn -> md(ctx).phase == :recovering end)
      end)

    assert log =~ "the viewport did not start after MilkDrop released the display"
    assert %{lifecycle: %{status: :backoff}, viewport: nil} = status(ctx)
    assert md(ctx).renderer == pid
    refute "exit" in cmd_names(ctx.skip_file)
    refute_received {:audio, :pcm_tap, @key, false}

    # The retry runs the viewport; only then does the renderer exit. `cmds`
    # is the log as of the viewport's start, so it can't race the exit that
    # the viewport's running triggers.
    assert_receive {:viewport_start, cmds}, @timeout
    assert List.last(cmds) == "release"
    assert Enum.filter(cmds, &(&1 in ["take", "exit"])) == ["take"]
    assert_receive {:audio, :pcm_tap, @key, false}, @timeout
    wait_until(fn -> md(ctx).phase == nil end)
    assert List.last(cmd_names(ctx.skip_file)) == "exit"
    assert %{last: %{outcome: :requested, phase: :exiting}, failures: 0} = md(ctx)
    assert %{lifecycle: %{status: :running}} = status(ctx)
  end

  test "a viewport that never comes back after the release ends the session once the recovery budget is spent",
       ctx do
    ctx = ctx |> start_ui(timeouts: %{recovering: 300}) |> presenting()
    %{os_pid: os_pid} = :sys.get_state(renderer(ctx))
    Agent.update(ctx.world, &%{&1 | viewport_fails: :always})

    log =
      capture_log(fn ->
        paused(ctx)
        wait_until(fn -> md(ctx).phase == :recovering end)
        refute "exit" in cmd_names(ctx.skip_file)
        assert_receive {:audio, :pcm_tap, @key, false}, @timeout
        wait_until(fn -> md(ctx).phase == nil end)
      end)

    assert log =~ "did not come back within 300 ms of MilkDrop's release"
    assert Enum.take(cmd_names(ctx.skip_file), -2) == ["release", "exit"]
    assert %{last: %{outcome: :requested, phase: :exiting}, failures: 0, latch: nil} = md(ctx)
    assert %{lifecycle: %{status: :backoff}, viewport: nil} = status(ctx)
    wait_until(fn -> not File.exists?("/proc/#{os_pid}") end)
  end

  test "the renderer's argv carries the connector, mode, pack, ring and ladder", ctx do
    ctx = ctx |> start_ui() |> presenting()
    %{os_pid: os_pid} = :sys.get_state(renderer(ctx))
    argv = "/proc/#{os_pid}/cmdline" |> File.read!() |> String.split(<<0>>, trim: true)

    # The viewport's own card and connector (vc4-hdmi is HDMI port 0), and
    # its size with no refresh pinned, so the renderer keeps Emerge's timing.
    for {flag, value} <- [
          {"--card", Path.join(ctx.dri_dir, "card1")},
          {"--connector", "HDMI-A-1"},
          {"--mode", "1280x720"},
          {"--pack-dir", ctx.pack_dir},
          {"--pcm-ring", @ring},
          {"--ladder", "640x360,480x270"}
        ] do
      assert [^value | _] = argv |> Enum.drop_while(&(&1 != flag)) |> tl()
    end
  end

  test "the viewport is pinned to the card that has its connector", ctx do
    ctx = start_ui(ctx)
    assert ctx.viewport_opts[:card] == Path.join(ctx.dri_dir, "card1")
    assert ctx.viewport_opts[:connector] == "HDMI-A-1"
  end

  test "with no card for the viewport's connector nothing yields: the bars show", ctx do
    File.rm_rf!(Path.join(ctx.sysfs_dir, "card1-HDMI-A-1"))

    log =
      capture_log(fn ->
        ctx = ctx |> start_ui() |> milkdrop_mode() |> playing()
        refute Keyword.has_key?(ctx.viewport_opts, :card)

        assert %{screen: {:visualizer, false}, milkdrop: %{phase: nil, yield: false}} =
                 status(ctx)

        refute_received {:audio, :pcm_tap, _, _}
        refute_received {:fake_renderer, :stop, _}
      end)

    assert log =~ "no DRM card has the viewport's HDMI-A-1"
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

  # The renderer ignores EOF and its grace period outlasts the test: only
  # the display subtree's restart can have it killed in time.
  test "a killed State's replacement starts the viewport only once the renderer is gone", ctx do
    ctx =
      ctx
      |> start_ui(supervised: true, fake: %{ignore_eof: true}, kill_grace_ms: 60_000)
      |> presenting()

    old = Process.whereis(ctx.state)
    %{os_pid: os_pid} = :sys.get_state(renderer(ctx))
    assert_received {:viewport_renderers, []}
    assert renderer_os_pids(ctx.skip_file) == [os_pid]

    Process.exit(old, :kill)

    assert_receive {:viewport_renderers, running}, @timeout
    assert running == []
    assert_receive {:fake_renderer, :start, _opts}
    refute Process.whereis(ctx.state) in [nil, old]
    refute File.exists?(ctx.skip_file <> ".eof")
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

  test "a hung renderer is killed and counts as a crash: the viewport restarts", ctx do
    ctx = ctx |> start_ui(milkdrop_opts: [loading_timeout_ms: 200]) |> presenting()
    %{os_pid: os_pid} = :sys.get_state(renderer(ctx))
    Renderer.command(renderer(ctx), %{cmd: "hang_loading", preset: "loop.milk"})

    assert_receive {:fake_renderer, :start, _opts}, @timeout
    assert_receive {:audio, :pcm_tap, @key, false}, @timeout
    wait_until(fn -> md(ctx).phase == nil end)
    # A SIGKILLed child can linger as a zombie until the port reaps it.
    wait_until(fn -> not File.exists?("/proc/#{os_pid}") end)
    assert %{last: %{outcome: {:crashed, :hang}, phase: :presenting}, failures: 1} = md(ctx)
    assert %{lifecycle: %{status: :running}, screen: {:visualizer, false}} = status(ctx)
  end

  test "three hangs latch MilkDrop off until the mode is chosen again", ctx do
    log =
      capture_log(fn ->
        ctx =
          start_ui(ctx,
            fake: %{take_hang_loading: "loop.milk"},
            milkdrop_opts: [loading_timeout_ms: 100],
            model_opts: [milkdrop_retry_ms: 1]
          )

        ctx |> milkdrop_mode() |> playing()

        for _ <- 1..3, do: assert_receive({:fake_renderer, :start, _opts}, @timeout)
        wait_until(fn -> md(ctx).latch == :crashed end)
        assert %{phase: nil, yield: false, failures: 3} = md(ctx)
        assert %{mode: :milkdrop, screen: {:visualizer, false}} = status(ctx)
      end)

    assert log =~ "3 renderer failures in 10 min (last: {:crashed, :hang})"
  end

  # The renderer's watchdog keeps its production deadlines (10 s / 30 s),
  # so State's shorter step timeout fires first, as on a device.
  describe "a step timeout on a hung preset" do
    setup ctx do
      store =
        start_supervised!(
          {Store,
           name: nil,
           table: :"#{inspect(__MODULE__)}.StepTimeout",
           dets_path: Path.join(ctx.tmp_dir, "settings.dets"),
           in_flight_grace_ms: 0}
        )

      %{store: store}
    end

    @tag capture_log: true
    test "skips the warm-up a take is stuck on", ctx do
      ctx =
        start_ui(ctx,
          fake: %{take_hang_loading: "loop.milk"},
          timeouts: %{taking: 300},
          milkdrop_opts: [store: ctx.store]
        )

      ctx |> milkdrop_mode() |> playing()
      wait_until(fn -> md(ctx).last != nil end)
      assert %{outcome: {:crashed, {:timeout, :taking}}} = md(ctx).last
      assert Store.skipped(ctx.store, @version) == %{"loop.milk" => "hang"}
    end

    @tag capture_log: true
    test "skips the first preset when the start never gets to prepared", ctx do
      ctx =
        start_ui(ctx,
          fake: %{startup_preset: "first.milk", hold_prepared: true},
          timeouts: %{preparing: 300},
          milkdrop_opts: [store: ctx.store]
        )

      ctx |> milkdrop_mode() |> playing()
      wait_until(fn -> md(ctx).last != nil end)
      assert %{outcome: {:crashed, {:timeout, :preparing}}} = md(ctx).last
      assert Store.skipped(ctx.store, @version) == %{"first.milk" => "hang"}
    end

    @tag capture_log: true
    test "skips a warm-up still unanswered when release times out", ctx do
      ctx =
        start_ui(ctx, timeouts: %{releasing: 300}, milkdrop_opts: [store: ctx.store])
        |> presenting()

      Renderer.command(renderer(ctx), %{cmd: "hang_loading", preset: "loop.milk"})
      wait_until(fn -> :sys.get_state(renderer(ctx)).loading == "loop.milk" end)
      paused(ctx)

      wait_until(fn -> md(ctx).last != nil end)
      assert %{outcome: {:crashed, {:timeout, :releasing}}} = md(ctx).last
      assert Store.skipped(ctx.store, @version) == %{"loop.milk" => "hang"}
    end

    @tag capture_log: true
    test "a take timeout with no warm-up pending skips nothing", ctx do
      ctx =
        start_ui(ctx,
          fake: %{startup_preset: "first.milk", ignore: ["take"]},
          timeouts: %{taking: 300},
          milkdrop_opts: [store: ctx.store]
        )

      ctx |> milkdrop_mode() |> playing()
      wait_until(fn -> md(ctx).last != nil end)
      assert %{outcome: {:crashed, {:timeout, :taking}}} = md(ctx).last
      assert Store.skipped(ctx.store, @version) == %{}
    end
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

  test "an ensure answer from a Pack that died is dropped once a new Pack announced", ctx do
    test = self()

    ensured = fn ->
      send(test, {:ensure_waiting, self()})

      receive do
        {:answer, answer} -> answer
      end
    end

    ctx = start_ui(ctx, pack: :absent, ensured: ensured)
    milkdrop_mode(ctx)
    assert_receive {:ensure_waiting, task}, @timeout
    task_ref = Process.monitor(task)

    ready = {:ready, @version, ctx.pack_dir}

    Phoenix.PubSub.broadcast(
      ctx.pubsub,
      UniversalProxy.MilkDrop.pack_topic(),
      {:milkdrop_pack_started, ready}
    )

    wait_until(fn -> md(ctx).pack == ready end)

    # The call into the old Pack fails only now, after the new one is ready.
    send(task, {:answer, {:error, :not_running}})
    assert_receive {:DOWN, ^task_ref, :process, ^task, :normal}, @timeout
    _ = :sys.get_state(ctx.state)
    assert md(ctx).pack == ready

    playing(ctx)
    assert_receive {:audio, :pcm_tap, @key, true}, @timeout
    wait_until(fn -> md(ctx).phase == :presenting end)
  end

  test "a pack retrying keeps the preparing screen, then yields once ready", ctx do
    retrying = {:retrying, {:transport, :nxdomain}, 5_000}
    ctx = start_ui(ctx, pack: :absent, ensured: retrying, model_opts: [milkdrop_notice_ms: 100])
    ctx |> milkdrop_mode() |> playing()
    assert_receive :pack_ensure, @timeout

    Phoenix.PubSub.broadcast(
      ctx.pubsub,
      UniversalProxy.MilkDrop.pack_topic(),
      {:milkdrop_pack, retrying}
    )

    wait_until(fn -> md(ctx).pack == retrying end)
    assert %{screen: {:milkdrop_preparing, nil}} = status(ctx)
    assert_pushed(&("Preparing visualizer…" in &1))
    refute_received {:audio, :pcm_tap, _, _}

    # Pack retries on its own: no second ensure, and the yield follows.
    Phoenix.PubSub.broadcast(
      ctx.pubsub,
      UniversalProxy.MilkDrop.pack_topic(),
      {:milkdrop_pack, {:ready, @version, ctx.pack_dir}}
    )

    assert_receive {:audio, :pcm_tap, @key, true}, @timeout
    wait_until(fn -> md(ctx).phase == :presenting end)
    refute_received :pack_ensure
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
