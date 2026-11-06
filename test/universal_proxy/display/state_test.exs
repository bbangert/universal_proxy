defmodule UniversalProxy.Display.StateTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log
  @moduletag :tmp_dir

  alias UniversalProxy.Display
  alias UniversalProxy.Display.FakeRenderer
  alias UniversalProxy.Display.Spec
  alias UniversalProxy.Display.State

  @key {"vc4-hdmi", nil, nil}
  @output %{key: @key, client_id: "c0", card_index: 1, display_roles: true}
  @adapter %{dev: "/dev/cec0", card_index: 1, phys_addr: "1.0.0.0", tv_presence: :present}

  # ── Fixtures ─────────────────────────────────────────────────────────

  setup context do
    sup = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    dri_dir = Path.join(context.tmp_dir, "dri")
    File.mkdir_p!(dri_dir)
    if Map.get(context, :card, true), do: File.write!(Path.join(dri_dir, "card0"), "")
    %{sup: sup, dri_dir: dri_dir}
  end

  defp start_manual(context) do
    start_supervised!(
      {State,
       name: :"#{inspect(__MODULE__)}.#{context.test}",
       ui: false,
       renderer: FakeRenderer,
       viewport_supervisor: context.sup,
       dri_dir: context.dri_dir,
       viewport_opts: [test_pid: self(), layer_cache_mb: 48],
       spec: Spec.now_playing(title: "Placeholder")}
    )
  end

  # Starts State with the UI on, fake audio/CEC funs reporting to the test
  # and outputs/adapters read from an Agent the test can change.
  defp start_ui(context, opts \\ []) do
    test = self()
    pubsub = :"#{inspect(__MODULE__)}.#{context.test}.PubSub"
    start_supervised!({Phoenix.PubSub, name: pubsub})
    tasks = start_supervised!(Task.Supervisor)

    world =
      start_supervised!(
        {Agent,
         fn ->
           %{
             outputs: Keyword.get(opts, :outputs, [@output]),
             adapters: Keyword.get(opts, :adapters, [@adapter]),
             snapshot: Keyword.get(opts, :snapshot, {0, %{}})
           }
         end}
      )

    audio = %{
      list_outputs: fn -> Agent.get(world, & &1.outputs) end,
      display_snapshot: fn key ->
        send(test, {:audio, :snapshot, key})
        Agent.get(world, & &1.snapshot)
      end,
      controller: fn key, cmd ->
        send(test, {:audio, :controller, key, cmd})
        :ok
      end,
      viz_enable: fn key, on? ->
        send(test, {:audio, :viz_enable, key, on?})
        :ok
      end,
      update_config: fn key, params -> send(test, {:audio, :update_config, key, params}) end
    }

    audio = Map.merge(audio, Keyword.get(opts, :audio, %{}))

    cec = %{
      list_adapters: fn -> Agent.get(world, & &1.adapters) end,
      claim_keys: fn dev, pid ->
        send(test, {:cec, :claim, dev, pid})
        :ok
      end,
      release_keys: fn dev ->
        send(test, {:cec, :release, dev})
        :ok
      end
    }

    state =
      start_supervised!({
        State,
        # No burn-in drift step during a test.
        name: :"#{inspect(__MODULE__)}.#{context.test}",
        ui: true,
        renderer: FakeRenderer,
        viewport_supervisor: context.sup,
        dri_dir: context.dri_dir,
        viewport_opts: [test_pid: test],
        view_opts: [bars: 8, drift_period_ms: 1_000_000_000_000],
        model_opts:
          Keyword.merge(
            [idle_ms: 60_000, restart_ms: 1, restart_max_ms: 4, stable_ms: 60_000],
            Keyword.get(opts, :model_opts, [])
          ),
        pubsub: pubsub,
        task_supervisor: tasks,
        audio: audio,
        cec: cec
      })

    # Past the start-up continue.
    _ = :sys.get_state(state)
    %{state: state, pubsub: pubsub, world: world}
  end

  defp broadcast(%{pubsub: pubsub}, topic, message),
    do: Phoenix.PubSub.broadcast(pubsub, topic, message)

  defp model(%{state: state}), do: :sys.get_state(state).model

  defp texts({:text, _attrs, s}), do: [s]

  defp texts({_tag, _attrs, children}) when is_list(children),
    do: Enum.flat_map(children, &texts/1)

  defp texts(_node), do: []

  defp flush_pushes(viewport) do
    receive do
      {:fake_renderer, :push, ^viewport, _spec} -> flush_pushes(viewport)
    after
      50 -> :ok
    end
  end

  # The next viewport start's options.
  defp started! do
    assert_receive {:fake_renderer, :start, opts}
    opts
  end

  defp viewport!(ctx) do
    started!()
    GenServer.call(ctx.state, :viewport)
  end

  defp playing(ctx) do
    broadcast(ctx, "sendspin:state", {:sendspin_state, @key, %{event: "stream_start"}})
    _ = model(ctx)
    ctx
  end

  # ── With the UI off ──────────────────────────────────────────────────

  describe "with the UI off" do
    test "starts nothing, claims nothing and refuses modes", context do
      state = start_manual(context)
      refute_receive {:fake_renderer, :start, _}
      assert GenServer.call(state, :viewport) == nil
      assert GenServer.call(state, {:set_mode, :off}) == {:error, :disabled}
      assert GenServer.call(state, :mode) == nil
      assert %{running: true, ui: false} = GenServer.call(state, :status)
    end

    test "start_viewport merges options and replaces a running viewport", context do
      state = start_manual(context)
      assert {:ok, first} = GenServer.call(state, {:start_viewport, [api: :raster]})
      assert_receive {:fake_renderer, :start, opts}
      assert opts[:api] == :raster
      assert opts[:layer_cache_mb] == 48

      assert {:ok, second} = GenServer.call(state, {:start_viewport, [layer_cache_mb: 8]})
      assert_receive {:fake_renderer, :stop, ^first}
      assert_receive {:fake_renderer, :start, opts}
      assert opts[:layer_cache_mb] == 8
      refute Process.alive?(first)
      assert GenServer.call(state, :viewport) == second
    end

    test "show/1 pushes to the viewport and seeds the next one", context do
      state = start_manual(context)
      spec = Spec.now_playing(title: "Next")

      GenServer.cast(state, {:show, spec})
      {:ok, viewport} = GenServer.call(state, {:start_viewport, []})
      assert_receive {:fake_renderer, :start, opts}
      assert opts[:spec] == spec

      other = Spec.now_playing(title: "Other")
      GenServer.cast(state, {:show, other})
      assert_receive {:fake_renderer, :push, ^viewport, ^other}
    end

    test "stop_viewport stops it; an exited viewport is forgotten", context do
      state = start_manual(context)
      {:ok, viewport} = GenServer.call(state, {:start_viewport, []})
      assert :ok = GenServer.call(state, :stop_viewport)
      assert_receive {:fake_renderer, :stop, ^viewport}
      assert GenServer.call(state, :viewport) == nil

      {:ok, viewport} = GenServer.call(state, {:start_viewport, []})
      Agent.stop(viewport, :boom)
      assert GenServer.call(state, :status).viewport == nil
    end
  end

  # ── With the UI on ───────────────────────────────────────────────────

  describe "start-up with the UI on" do
    test "binds, seeds, claims the paired adapter's keys and starts the viewport", context do
      ctx = start_ui(context, snapshot: {7, %{metadata: %{event: "metadata", title: "Seeded"}}})
      state = ctx.state

      assert_receive {:audio, :snapshot, @key}
      assert_receive {:cec, :claim, "/dev/cec0", ^state}
      opts = started!()
      assert opts[:api] == :auto
      assert opts[:owner] == state
      assert "Seeded" in texts(opts[:spec])

      assert %{
               ui: true,
               mode: :now_playing,
               tv_presence: :present,
               binding: %{key: @key, cec_dev: "/dev/cec0"},
               lifecycle: %{status: :running}
             } = GenServer.call(state, :status)

      assert GenServer.call(state, {:start_viewport, []}) == {:error, :ui_active}
    end

    @tag card: false
    test "runs headless without a DRM card", context do
      ctx = start_ui(context)
      refute_receive {:fake_renderer, :start, _}
      assert %{lifecycle: %{status: :headless}} = GenServer.call(ctx.state, :status)
      assert_received {:cec, :claim, "/dev/cec0", _}
    end

    test "adopts the persisted mode; Off claims no keys", context do
      ctx = start_ui(context, outputs: [Map.put(@output, :display_mode, "Off")])
      assert GenServer.call(ctx.state, :mode) == :off
      refute_received {:cec, :claim, _, _}
      assert started!()[:spec] == Spec.blank()
    end
  end

  describe "modes" do
    test "set_mode persists, broadcasts and redraws", context do
      ctx = start_ui(context)
      Phoenix.PubSub.subscribe(ctx.pubsub, Display.topic())
      viewport = viewport!(ctx)

      assert GenServer.call(ctx.state, {:set_mode, :party_qr}) == :ok
      assert_receive {:display_mode, :party_qr}
      assert_receive {:audio, :update_config, @key, %{display_mode: "Party QR"}}
      assert_receive {:fake_renderer, :push, ^viewport, spec}
      assert "Party Mode is off" in texts(spec)

      assert GenServer.call(ctx.state, {:set_mode, :off}) == :ok
      assert_receive {:fake_renderer, :set_display, ^viewport, :off}
      assert_receive {:cec, :release, "/dev/cec0"}
    end
  end

  describe "output size" do
    test "the viewport's reported size re-lays the screen out", context do
      ctx = start_ui(context)
      viewport = viewport!(ctx)

      send(ctx.state, {:viewport_size, viewport, {1920, 1080}})
      assert_receive {:fake_renderer, :push, ^viewport, spec}
      assert {:column, attrs, _} = spec
      assert attrs[:padding] == {54, 96, 54, 96}
      assert GenServer.call(ctx.state, :status).size == {1920, 1080}

      # Another process's (a stale viewport's) report is ignored.
      send(ctx.state, {:viewport_size, self(), {1280, 720}})
      assert GenServer.call(ctx.state, :status).size == {1920, 1080}
    end
  end

  describe "progress clock" do
    test "a playing track's progress redraws about once a second; pausing stops that",
         context do
      ctx = start_ui(context)
      viewport = viewport!(ctx)
      playing(ctx)

      metadata = %{
        event: "metadata",
        title: "Song",
        received_at: System.monotonic_time(:millisecond) - 10_000,
        progress: %{
          track_progress: 0,
          track_duration: 100_000,
          playback_speed: 1000,
          progress_age_ms: 0
        }
      }

      flush_pushes(viewport)
      broadcast(ctx, "sendspin:display", {:sendspin_display, @key, 1, metadata})
      assert_receive {:fake_renderer, :push, ^viewport, spec}
      assert "Song" in texts(spec) and "0:10" in texts(spec)
      assert %{clock: {_ref, _due}} = :sys.get_state(ctx.state)

      flush_pushes(viewport)
      assert_receive {:fake_renderer, :push, ^viewport, spec}, 1_500
      assert "0:11" in texts(spec) or "0:12" in texts(spec)

      broadcast(
        ctx,
        "sendspin:display",
        {:sendspin_display, @key, 2, %{event: "group", playback_state: "paused"}}
      )

      # Paused: no more per-second redraws; only the burn-in drift wakes it.
      flush_pushes(viewport)
      refute_receive {:fake_renderer, :push, ^viewport, _spec}, 1_200
      assert %{clock: {_ref, due}} = :sys.get_state(ctx.state)
      assert due - System.monotonic_time(:millisecond) > 60_000
    end
  end

  describe "player events" do
    test "display events for the bound output redraw; others are ignored", context do
      ctx = start_ui(context)
      viewport = viewport!(ctx)

      broadcast(
        ctx,
        "sendspin:display",
        {:sendspin_display, {"other", nil, nil}, 1, %{event: "metadata", title: "Nope"}}
      )

      broadcast(
        ctx,
        "sendspin:display",
        {:sendspin_display, @key, 1, %{event: "metadata", title: "Song"}}
      )

      assert_receive {:fake_renderer, :push, ^viewport, spec}
      assert "Song" in texts(spec)
      refute "Nope" in texts(spec)
    end

    test "playing turns the visualizer strip on, pausing turns it off", context do
      ctx = start_ui(context)
      viewport = viewport!(ctx)
      playing(ctx)

      assert_receive {:audio, :viz_enable, @key, true}

      assert_receive {:fake_renderer, :set_viz, ^viewport,
                      %{topic: "sendspin:viz:c0", key: @key, mode: :strip}}

      broadcast(
        ctx,
        "sendspin:display",
        {:sendspin_display, @key, 1, %{event: "group", playback_state: "paused"}}
      )

      assert_receive {:audio, :viz_enable, @key, false}
      assert_receive {:fake_renderer, :set_viz, ^viewport, nil}
    end

    test "a new player is re-seeded", context do
      ctx = start_ui(context)
      assert_receive {:audio, :snapshot, @key}
      broadcast(ctx, "sendspin:state", {:sendspin_state, @key, %{event: "listening"}})
      assert_receive {:audio, :snapshot, @key}
    end

    test "the output going away releases the keys", context do
      ctx = start_ui(context)
      Agent.update(ctx.world, &%{&1 | outputs: []})
      broadcast(ctx, "sendspin:output_removed", {:sendspin_output_removed, %{key: @key}})
      assert_receive {:cec, :release, "/dev/cec0"}
      assert %{binding: nil} = GenServer.call(ctx.state, :status)
    end
  end

  describe "TV presence" do
    test "a binding made after start-up takes its adapter's known presence", context do
      ctx = start_ui(context, outputs: [])
      assert %{binding: nil, tv_presence: :unknown} = GenServer.call(ctx.state, :status)

      Agent.update(ctx.world, &%{&1 | outputs: [@output]})
      broadcast(ctx, "sendspin:output_added", {:sendspin_output_added, @output})

      assert %{binding: %{cec_dev: "/dev/cec0"}, tv_presence: :present} =
               GenServer.call(ctx.state, :status)
    end

    test "moving to another adapter drops the previous TV's presence", context do
      cec1 = %{@adapter | dev: "/dev/cec1", card_index: 2, tv_presence: :unknown}
      ctx = start_ui(context, adapters: [@adapter, cec1])
      assert %{tv_presence: :present} = GenServer.call(ctx.state, :status)

      other = %{@output | key: {"vc4-hdmi-1", nil, nil}, client_id: "c1", card_index: 2}
      Agent.update(ctx.world, &%{&1 | outputs: [Map.delete(@output, :display_roles), other]})
      broadcast(ctx, "sendspin:state", {:sendspin_state, other.key, %{event: "listening"}})

      assert %{binding: %{cec_dev: "/dev/cec1"}, tv_presence: :unknown} =
               GenServer.call(ctx.state, :status)
    end
  end

  describe "remote keys" do
    test "keys on the claimed adapter drive the player through a task", context do
      ctx = context |> start_ui() |> playing()
      send(ctx.state, {:cec_key, "/dev/cec0", :select})
      assert_receive {:audio, :controller, @key, :pause}

      send(ctx.state, {:cec_key, "/dev/cec9", :next})
      send(ctx.state, {:cec_key, "/dev/cec0", :forward})
      assert_receive {:audio, :controller, @key, :next}
      refute_received {:audio, :controller, _, _}
    end

    test "claims again on every adapter update (a restarted Cec.Server forgot)", context do
      ctx = start_ui(context)
      assert_receive {:cec, :claim, "/dev/cec0", _}
      broadcast(ctx, "cec:events", {:cec_adapters, [@adapter]})
      assert_receive {:cec, :claim, "/dev/cec0", _}
    end
  end

  describe "idle blanking" do
    test "the idle timer blanks with a black frame; playback wakes it", context do
      ctx = start_ui(context)
      viewport = viewport!(ctx)
      {:idle, gen} = model(ctx).idle

      send(ctx.state, {:display_timer, :idle, gen - 1})
      refute_receive {:fake_renderer, :set_display, _, :off}

      send(ctx.state, {:display_timer, :idle, gen})
      assert_receive {:fake_renderer, :set_display, ^viewport, :off}
      assert_receive {:fake_renderer, :push, ^viewport, spec}
      assert spec == Spec.blank()

      playing(ctx)
      assert_receive {:fake_renderer, :set_display, ^viewport, :on}
    end

    test "a remote key wakes the screen and is consumed", context do
      ctx = start_ui(context)
      viewport = viewport!(ctx)
      {:idle, gen} = model(ctx).idle
      send(ctx.state, {:display_timer, :idle, gen})
      assert_receive {:fake_renderer, :set_display, ^viewport, :off}

      send(ctx.state, {:cec_key, "/dev/cec0", :play})
      assert_receive {:fake_renderer, :set_display, ^viewport, :on}
      refute_receive {:audio, :controller, _, _}
    end
  end

  describe "viewport lifecycle" do
    test "a crashed viewport is restarted after the backoff", context do
      ctx = start_ui(context)
      Agent.stop(viewport!(ctx), :boom)
      assert started!()[:api] == :auto
    end

    test "three identical crashes fall back to raster 720p", context do
      ctx = start_ui(context)
      for _ <- 1..3, do: Agent.stop(viewport!(ctx), :gl_lost)

      opts = started!()
      assert opts[:api] == :raster
      assert opts[:mode] == {1280, 720}
    end

    test "a TV coming back (valid physical address) retries at once", context do
      ctx = start_ui(context, model_opts: [restart_ms: 60_000, restart_max_ms: 60_000])
      Agent.stop(viewport!(ctx), :boom)
      refute_receive {:fake_renderer, :start, _}

      broadcast(ctx, "cec:events", {:cec_adapters, [%{@adapter | phys_addr: "f.f.f.f"}]})
      refute_receive {:fake_renderer, :start, _}

      broadcast(ctx, "cec:events", {:cec_adapters, [@adapter]})
      assert_receive {:fake_renderer, :start, _}
    end
  end

  describe "ordering" do
    test "audio calls run one at a time, in order, without blocking State", context do
      test = self()

      update_config = fn key, params ->
        if params.display_mode == "Visualizer", do: Process.sleep(150)
        send(test, {:audio, :update_config, key, params})
      end

      ctx = start_ui(context, audio: %{update_config: update_config})

      :ok = GenServer.call(ctx.state, {:set_mode, :visualizer})
      :ok = GenServer.call(ctx.state, {:set_mode, :off})
      # Still responsive while the first call is in flight.
      assert %{mode: :off} = GenServer.call(ctx.state, :status)

      assert_receive {:audio, :update_config, @key, %{display_mode: mode}}, 1_000
      assert mode == "Visualizer"
      assert_receive {:audio, :update_config, @key, %{display_mode: "Off"}}, 1_000
    end

    test "a rebind while playing ends with the new output's visualizer on", context do
      ctx =
        start_ui(context, snapshot: {3, %{group: %{event: "group", playback_state: "playing"}}})

      started!()
      playing(ctx)
      assert_receive {:fake_renderer, :set_viz, _, %{topic: "sendspin:viz:c0"}}

      # No HDMI port, so the viewport stays where it is.
      other = %{@output | key: {"usb-dac", 1, 2}, client_id: "c1", card_index: 5}
      Agent.update(ctx.world, &%{&1 | outputs: [Map.delete(@output, :display_roles), other]})
      broadcast(ctx, "sendspin:output_added", {:sendspin_output_added, other})
      _ = model(ctx)

      assert model(ctx).viz == :strip
      assert last_set_viz() == %{topic: "sendspin:viz:c1", key: other.key, mode: :strip}
    end

    test "a binding move turns the old player's visualizer off, the new one's on", context do
      ctx =
        start_ui(context, snapshot: {3, %{group: %{event: "group", playback_state: "playing"}}})

      started!()
      playing(ctx)
      assert_receive {:audio, :viz_enable, @key, true}

      other = %{@output | key: {"usb-dac", 1, 2}, client_id: "c1", card_index: 5}
      Agent.update(ctx.world, &%{&1 | outputs: [Map.delete(@output, :display_roles), other]})
      broadcast(ctx, "sendspin:output_added", {:sendspin_output_added, other})

      assert_receive {:audio, :viz_enable, @key, false}
      assert_receive {:audio, :viz_enable, {"usb-dac", 1, 2}, true}
      refute_receive {:audio, :viz_enable, _, _}
    end
  end

  describe "connector" do
    test "the viewport drives the bound output's connector and follows a rebind", context do
      ctx = start_ui(context)
      assert started!()[:connector] == "HDMI-A-1"
      first = GenServer.call(ctx.state, :viewport)

      other = %{@output | key: {"vc4-hdmi-1", nil, nil}, client_id: "c1"}
      Agent.update(ctx.world, &%{&1 | outputs: [Map.delete(@output, :display_roles), other]})
      broadcast(ctx, "sendspin:output_added", {:sendspin_output_added, other})

      assert_receive {:fake_renderer, :stop, ^first}
      assert started!()[:connector] == "HDMI-A-2"
      assert %{lifecycle: %{status: :running, port: 1}} = GenServer.call(ctx.state, :status)
    end
  end

  defp last_set_viz(last \\ :none) do
    receive do
      {:fake_renderer, :set_viz, _viewport, viz} -> last_set_viz(viz)
    after
      100 -> last
    end
  end

  test "a party (the Phase 6 event) shows as the idle screen", context do
    ctx = start_ui(context)
    viewport = viewport!(ctx)
    send(ctx.state, {:display_party, %{url: "https://ma/party", name: "Party!"}})
    assert_receive {:fake_renderer, :push, ^viewport, spec}
    assert "Party!" in texts(spec)
  end

  describe "facade while the subsystem is off" do
    test "returns defaults instead of exiting" do
      assert Display.start_viewport() == {:error, :not_running}
      assert Display.stop_viewport() == :ok
      assert Display.show(Spec.now_playing()) == :ok
      assert Display.viewport() == nil
      assert Display.status() == %{running: false}
      assert Display.mode() == nil
      assert Display.set_mode(:off) == {:error, :not_running}
      assert Display.set_mode("Bogus") == {:error, :invalid_mode}
      refute Display.ui?()
    end
  end
end
