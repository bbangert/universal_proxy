defmodule UniversalProxy.Display.ModelTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Display.{Model, Progress}

  @key {"vc4-hdmi", nil, nil}
  @binding %{key: @key, client_id: "c0ffee", cec_dev: "/dev/cec0"}
  @party %{url: "https://ma.example/party", name: "Party"}

  # Folds events into the model; returns the model and every effect, in order.
  defp run(model, events) do
    Enum.reduce(events, {model, []}, fn event, {m, acc} ->
      {m, effects} = Model.handle(m, event, 0)
      {m, acc ++ effects}
    end)
  end

  defp run!(model, events), do: model |> run(events) |> elem(0)

  defp group(state), do: {:display_event, 1_000, %{event: "group", playback_state: state}}

  # Bound to the HDMI output, viewport up, nothing playing.
  defp ready(opts \\ []) do
    run!(Model.new(opts), [
      {:bound, @binding, nil},
      {:snapshot, 0, %{}},
      {:display_available, true},
      {:viewport, :started}
    ])
  end

  defp playing(opts \\ []), do: run!(ready(opts), [{:stream, :start}])

  defp schedules(effects, timer),
    do: for({:schedule, ^timer, gen, ms} <- effects, do: {gen, ms})

  describe "progress across a group pause/resume (no new metadata)" do
    defp at(model, events),
      do: Enum.reduce(events, model, fn {now, e}, m -> elem(Model.handle(m, e, now), 0) end)

    defp elapsed(model, now),
      do: Progress.at(model.metadata, now, model.playback == :playing).elapsed_ms

    test "a pause freezes where it got to; a resume continues from there" do
      metadata = %{
        event: "metadata",
        title: "Song",
        received_at: 0,
        progress: %{
          track_progress: 10_000,
          track_duration: 200_000,
          playback_speed: 1000,
          progress_age_ms: 0
        }
      }

      m =
        at(ready(), [
          {0, {:display_event, 1, metadata}},
          {0, {:display_event, 2, %{event: "group", playback_state: "playing"}}}
        ])

      assert elapsed(m, 10_000) == 20_000

      paused = at(m, [{10_000, {:display_event, 3, %{event: "group", playback_state: "paused"}}}])
      assert elapsed(paused, 10_000) == 20_000
      assert elapsed(paused, 40_000) == 20_000

      resumed =
        at(paused, [{40_000, {:display_event, 4, %{event: "group", playback_state: "playing"}}}])

      assert elapsed(resumed, 45_000) == 25_000

      # New metadata replaces the anchor.
      fresh = %{
        metadata
        | received_at: 50_000,
          progress: %{metadata.progress | track_progress: 1_000}
      }

      assert elapsed(at(resumed, [{50_000, {:display_event, 5, fresh}}]), 50_000) == 1_000
    end

    test "fresh metadata keeps its own timing when playback starts" do
      metadata = %{
        event: "metadata",
        received_at: 0,
        progress: %{
          track_progress: 10_000,
          track_duration: 200_000,
          playback_speed: 1000,
          progress_age_ms: 500
        }
      }

      m = at(ready(), [{0, {:display_event, 1, metadata}}, {0, {:stream, :start}}])
      assert elapsed(m, 0) == 10_500
      assert elapsed(m, 1_000) == 11_500
    end

    test "a late snapshot of a pause the player re-timed shows the frozen position" do
      # What Audio.Player caches after a group pause: position re-based, speed 0.
      snapshot = %{
        metadata: %{
          received_at: 10_000,
          progress: %{
            track_progress: 20_000,
            track_duration: 200_000,
            playback_speed: 0,
            progress_age_ms: 0
          }
        },
        group: %{playback_state: "paused"}
      }

      m = at(Model.new(), [{0, {:bound, @binding, nil}}, {60_000, {:snapshot, 9, snapshot}}])
      assert m.playback == :paused
      assert elapsed(m, 90_000) == 20_000
    end

    test "stream end/start re-anchor too" do
      metadata = %{
        event: "metadata",
        received_at: 0,
        progress: %{track_progress: 0, track_duration: 0, playback_speed: 1000}
      }

      m = at(ready(), [{0, {:display_event, 1, metadata}}, {0, {:stream, :start}}])
      m = at(m, [{5_000, {:stream, :end}}])
      assert elapsed(m, 9_000) == 5_000
      m = at(m, [{9_000, {:stream, :start}}])
      assert elapsed(m, 10_000) == 6_000
    end
  end

  describe "screen/1 priority (P5)" do
    for {label, fields, screen} <- [
          {"Off beats a party while playing", [mode: :off, playback: :playing, party: @party],
           :blank},
          {"a blanked screen", [blanked: true, playback: :paused], :blank},
          {"Party QR mode with a party", [mode: :party_qr, party: @party, playback: :playing],
           :party_qr},
          {"Party QR mode without one", [mode: :party_qr], :party_off},
          {"playing with a party: overlay", [playback: :playing, party: @party],
           {:now_playing, true}},
          {"playing, overlay hidden", [playback: :playing, party: @party, overlay_hidden: true],
           {:now_playing, false}},
          {"playing the visualizer", [mode: :visualizer, playback: :playing],
           {:visualizer, false}},
          {"idle with a party: the QR", [playback: :paused, party: @party], :party_qr},
          {"paused", [playback: :paused], {:now_playing, false}},
          {"stopped in Visualizer", [mode: :visualizer], {:visualizer, false}}
        ] do
      test label do
        model = struct(Model.new(), unquote(Macro.escape(fields)))
        assert Model.screen(model) == unquote(Macro.escape(screen))
      end
    end
  end

  describe "remote keys (P4)" do
    for {label, setup, key, expect_effects, expect_fields} <- [
          {"Left moves focus left", [], :left, [], [focus: :prev]},
          {"Right moves focus right", [], :right, [], [focus: :next]},
          {"Left stops at the first control", [focus: :prev], :left, [], [focus: :prev]},
          {"Right stops at the last control", [focus: :next], :right, [], [focus: :next]},
          {"Up cycles back to Party QR", [], :up,
           [{:persist_mode, :party_qr}, {:push_mode, :party_qr}], [mode: :party_qr]},
          {"Down cycles to Visualizer", [], :down,
           [{:persist_mode, :visualizer}, {:push_mode, :visualizer}], [mode: :visualizer]},
          {"Select on play/pause pauses while playing", [], :select, [{:controller, :pause}], []},
          {"Select on previous", [focus: :prev], :select, [{:controller, :previous}], []},
          {"Select on next", [focus: :next], :select, [{:controller, :next}], []},
          {"Play", [], :play, [{:controller, :play}], []},
          {"Pause", [], :pause, [{:controller, :pause}], []},
          {"Play/Pause toggles", [], :play_pause, [{:controller, :pause}], []},
          {"Stop", [], :stop, [{:controller, :stop}], []},
          {"Forward is next", [], :forward, [{:controller, :next}], []},
          {"Backward is previous", [], :backward, [{:controller, :previous}], []},
          {"Exit hides the party overlay", [party: @party], :exit, [], [overlay_hidden: true]},
          {"Exit returns to Now Playing", [mode: :visualizer], :exit,
           [{:persist_mode, :now_playing}, {:push_mode, :now_playing}], [mode: :now_playing]},
          {"Exit on Now Playing does nothing", [], :exit, [], [mode: :now_playing]},
          {"Unmapped keys do nothing", [], :red, [], []}
        ] do
      test label do
        model = struct(playing(), unquote(Macro.escape(setup)))
        {model, effects} = Model.handle(model, {:key, unquote(key)}, 0)

        for effect <- unquote(Macro.escape(expect_effects)), do: assert(effect in effects)

        if unquote(Macro.escape(expect_effects)) == [] do
          refute Enum.any?(effects, &match?({:controller, _}, &1))
          refute Enum.any?(effects, &match?({:persist_mode, _}, &1))
        end

        for {field, value} <- unquote(Macro.escape(expect_fields)),
            do: assert(Map.fetch!(model, field) == value)
      end
    end

    test "Select and Play/Pause play while paused" do
      model = run!(playing(), [group("paused")])
      assert {_, [{:controller, :play} | _]} = Model.handle(model, {:key, :select}, 0)
      assert {_, [{:controller, :play} | _]} = Model.handle(model, {:key, :play_pause}, 0)
    end

    test "a key restarts the idle timer" do
      model = run!(ready(), [group("paused")])
      gen = model.idle_gen
      {model, effects} = Model.handle(model, {:key, :right}, 0)
      assert [{new_gen, 120_000}] = schedules(effects, :idle)
      assert new_gen > gen and model.idle_gen == new_gen
    end

    test "with no output bound, transport keys send nothing" do
      model = run!(Model.new(), [{:stream, :start}])
      {_model, effects} = Model.handle(model, {:key, :play}, 0)
      refute Enum.any?(effects, &match?({:controller, _}, &1))
    end
  end

  describe "idle blanking (D3)" do
    test "nothing playing schedules the idle timer; it blanks with a black frame" do
      model = ready(idle_ms: 5_000)
      assert {:idle, gen} = model.idle

      {model, effects} = Model.handle(model, {:timer, :idle, gen}, 0)
      assert model.blanked
      assert Model.screen(model) == :blank
      assert {:display, :off} in effects
      assert :render in effects
      assert effects |> schedules(:idle) == []
    end

    test "the idle delay is idle_ms, or party_idle_ms while a party QR is the screen" do
      {_model, effects} = run(Model.new(idle_ms: 5_000), [{:bound, @binding, nil}])
      assert [{_gen, 5_000}] = schedules(effects, :idle)

      {_model, effects} = Model.handle(ready(party_idle_ms: 9_000), {:party, @party}, 0)
      assert [{_gen, 9_000}] = schedules(effects, :idle)
    end

    test "a stale timer is ignored" do
      model = ready()
      {model, _} = Model.handle(model, {:key, :right}, 0)
      {model, effects} = Model.handle(model, {:timer, :idle, model.idle_gen - 1}, 0)
      refute model.blanked
      assert effects == []
    end

    test "no idle timer while playing; stopping starts one, never blanking at once" do
      model = playing()
      assert model.idle == nil
      {model, effects} = Model.handle(model, {:stream, :end}, 0)
      refute model.blanked
      assert [{_gen, 120_000}] = schedules(effects, :idle)
      refute {:display, :off} in effects
    end

    for {label, event} <- [
          {"playback starting", {:stream, :start}},
          {"the group playing",
           {:display_event, 9_999, %{event: "group", playback_state: "playing"}}},
          {"a party turning on", {:party, @party}},
          {"an HA mode change", {:set_mode, :visualizer}}
        ] do
      test "#{label} wakes a blanked screen" do
        model = blanked()
        {model, effects} = Model.handle(model, unquote(Macro.escape(event)), 0)
        refute model.blanked
        assert {:display, :on} in effects
      end
    end

    test "a remote key wakes a blanked screen and is consumed" do
      {model, effects} = Model.handle(blanked(), {:key, :play}, 0)
      refute model.blanked
      assert {:display, :on} in effects
      refute Enum.any?(effects, &match?({:controller, _}, &1))
      assert model.focus == :play_pause
    end

    defp blanked do
      model = ready()
      {_kind, gen} = model.idle
      model = run!(model, [{:timer, :idle, gen}])
      assert model.blanked
      model
    end
  end

  describe "Off (explicit)" do
    test "blanks, releases the remote and survives every automatic wake" do
      {model, effects} = Model.handle(playing(), {:set_mode, :off}, 0)
      assert {:display, :off} in effects
      assert {:release_keys, "/dev/cec0"} in effects
      assert {:persist_mode, :off} in effects
      assert {:push_mode, :off} in effects

      for event <- [{:stream, :start}, {:party, @party}, {:key, :select}, group("playing")] do
        {model, effects} = Model.handle(model, event, 0)
        assert Model.screen(model) == :blank
        refute {:display, :on} in effects
        refute Enum.any?(effects, &match?({:controller, _}, &1))
      end
    end

    test "a mode other than Off brings it back and reclaims the keys" do
      model = run!(playing(), [{:set_mode, :off}])
      {model, effects} = Model.handle(model, {:set_mode, :now_playing}, 0)
      assert {:display, :on} in effects
      assert {:claim_keys, "/dev/cec0"} in effects
      assert Model.screen(model) == {:now_playing, false}
    end

    test "never turns the display on, whatever happens" do
      :rand.seed(:exsss, {1, 2, 3})

      events = [
        {:stream, :start},
        {:stream, :end},
        {:party, @party},
        {:party, :off},
        {:key, :select},
        {:key, :up},
        {:key, :exit},
        group("playing"),
        group("paused"),
        {:tv_presence, :present},
        {:display_available, true},
        {:viewport, :started},
        {:viewport, :down, :boom},
        :hdmi_link_up
      ]

      for _ <- 1..200 do
        sequence = for _ <- 1..15, do: Enum.random(events)
        {model, _} = Model.handle(playing(), {:set_mode, :off}, 0)
        {model, effects} = run(model, sequence)
        refute {:display, :on} in effects
        assert model.power == :off
      end
    end
  end

  describe "HA mode changes" do
    test "an unchanged mode is still echoed but not persisted" do
      {_model, effects} = Model.handle(playing(), {:set_mode, :now_playing}, 0)
      assert {:push_mode, :now_playing} in effects
      refute Enum.any?(effects, &match?({:persist_mode, _}, &1))
    end
  end

  describe "party overlay" do
    test "shows while playing with a party, hides on Exit, comes back for a new party" do
      model = run!(playing(), [{:party, @party}])
      assert Model.screen(model) == {:now_playing, true}

      model = run!(model, [{:key, :exit}])
      assert Model.screen(model) == {:now_playing, false}

      model = run!(model, [{:party, %{@party | url: "https://ma.example/other"}}])
      assert Model.screen(model) == {:now_playing, true}
    end

    test "party off removes it" do
      model = run!(playing(), [{:party, @party}, {:party, :off}])
      assert Model.screen(model) == {:now_playing, false}
    end
  end

  describe "player state" do
    test "events at or below the snapshot's seq are dropped" do
      model =
        run!(Model.new(), [
          {:bound, @binding, nil},
          {:snapshot, 5, %{metadata: %{event: "metadata", title: "Snap"}}},
          {:display_event, 4, %{event: "metadata", title: "Old"}},
          {:display_event, 5, %{event: "metadata", title: "Same"}}
        ])

      assert model.metadata.title == "Snap"

      model = run!(model, [{:display_event, 6, %{event: "metadata", title: "New"}}])
      assert model.metadata.title == "New"
    end

    test "a cleared group (lost server connection) stops playback" do
      {model, effects} =
        Model.handle(playing(), {:display_event, 2_000, %{event: "group_clear"}}, 0)

      assert model.group == nil and model.playback == :stopped
      assert [{_gen, 120_000}] = schedules(effects, :idle)
      assert {:viz, nil} in effects
    end

    test "the snapshot's group sets playback" do
      model =
        run!(Model.new(), [
          {:bound, @binding, nil},
          {:snapshot, 3, %{group: %{event: "group", playback_state: "playing"}}}
        ])

      assert model.playback == :playing
    end

    test "a fresh player clears the old one's state and re-seeds" do
      model = run!(playing(), [{:display_event, 50, %{event: "metadata", title: "T"}}])
      {model, effects} = Model.handle(model, {:player, :started}, 0)
      assert model.seq == 0 and model.metadata == nil and model.playback == :stopped
      assert {:snapshot, @key} in effects

      model = run!(model, [{:display_event, 1, %{event: "metadata", title: "New"}}])
      assert model.metadata.title == "New"
    end

    test "a stopped player clears now playing" do
      model = run!(playing(), [{:display_event, 2, %{event: "metadata", title: "T"}}])
      model = run!(model, [{:player, :stopped}])
      assert model.metadata == nil and model.playback == :stopped
    end

    test "artwork other than slot 0 is ignored" do
      model =
        run!(ready(), [
          {:display_event, 1, %{event: "artwork", slot: 1, path: "/a.jpg"}},
          {:display_event, 2, %{event: "artwork", slot: 0, path: "/b.jpg"}},
          {:display_event, 3, %{event: "artwork_clear", slot: 1}}
        ])

      assert model.artwork.path == "/b.jpg"
    end
  end

  describe "binding and the persisted mode (P2)" do
    test "a new binding asks for a snapshot and claims its adapter's keys" do
      {_model, effects} = Model.handle(Model.new(), {:bound, @binding, nil}, 0)
      assert {:snapshot, @key} in effects
      assert {:claim_keys, "/dev/cec0"} in effects
    end

    test "the persisted mode is adopted and pushed" do
      {model, effects} = Model.handle(Model.new(), {:bound, @binding, :off}, 0)
      assert model.mode == :off
      assert {:push_mode, :off} in effects
      refute Enum.any?(effects, &match?({:claim_keys, _}, &1))
    end

    test "a mode picked before the output was bound wins and is persisted" do
      model = run!(Model.new(), [{:set_mode, :visualizer}])
      {model, effects} = Model.handle(model, {:bound, @binding, :off}, 0)
      assert model.mode == :visualizer
      assert {:persist_mode, :visualizer} in effects
    end

    test "a new adapter moves the claim" do
      model = ready()

      {_model, effects} =
        Model.handle(model, {:bound, %{@binding | cec_dev: "/dev/cec1"}, nil}, 0)

      assert effects == [{:release_keys, "/dev/cec0"}, {:claim_keys, "/dev/cec1"}]
    end

    test "another adapter forgets the previous TV's presence; the same one keeps it" do
      model = run!(ready(), [{:tv_presence, :present}])
      kept = run!(model, [{:bound, %{@binding | client_id: "other"}, nil}])
      assert kept.tv_presence == :present

      moved = run!(model, [{:bound, %{@binding | cec_dev: "/dev/cec1"}, nil}])
      assert moved.tv_presence == :unknown
      assert run!(model, [{:bound, nil, nil}]).tv_presence == :unknown
    end

    test "losing the output clears now playing and releases the keys" do
      model = run!(playing(), [{:display_event, 2, %{event: "metadata", title: "T"}}])
      {model, effects} = Model.handle(model, {:bound, nil, nil}, 0)
      assert model.metadata == nil and model.playback == :stopped
      assert {:release_keys, "/dev/cec0"} in effects
    end
  end

  describe "visualizer" do
    test "a strip while playing Now Playing, full in Visualizer, none otherwise" do
      {model, effects} = Model.handle(ready(), {:stream, :start}, 0)
      assert {:viz, :strip} in effects

      {model, effects} = Model.handle(model, {:set_mode, :visualizer}, 0)
      assert {:viz, :full} in effects

      {model, effects} = Model.handle(model, group("paused"), 0)
      assert {:viz, nil} in effects

      {_model, effects} = Model.handle(model, {:set_mode, :party_qr}, 0)
      refute Enum.any?(effects, &match?({:viz, _}, &1))
    end

    test "none without a running viewport" do
      model = run!(Model.new(), [{:bound, @binding, nil}, {:stream, :start}])
      assert Model.viz_wanted(model) == nil
    end
  end

  describe "viewport lifecycle" do
    defp starting(opts \\ []) do
      model = Model.new(Keyword.merge([restart_ms: 1_000, restart_max_ms: 8_000], opts))
      {model, effects} = Model.handle(model, {:display_available, true}, 0)

      assert [{:start_viewport, [api: :auto]}] =
               Enum.filter(effects, &match?({:start_viewport, _}, &1))

      model
    end

    test "no display: headless, nothing started" do
      {model, effects} = Model.handle(Model.new(), {:display_available, false}, 0)
      assert model.viewport.status == :headless
      refute Enum.any?(effects, &match?({:start_viewport, _}, &1))
    end

    test "started: renders, applies power and schedules the stable timer" do
      {model, effects} = Model.handle(starting(stable_ms: 60_000), {:viewport, :started}, 0)
      assert model.viewport.status == :running
      assert :render in effects
      assert {:display, :on} in effects
      assert [{gen, 60_000}] = schedules(effects, :stable)
      assert gen == model.viewport.gen
    end

    test "the reported output size is kept and redraws once per change" do
      {model, effects} = Model.handle(ready(), {:viewport_size, {1920, 1080}}, 0)
      assert model.size == {1920, 1080}
      assert :render in effects

      assert {^model, []} = Model.handle(model, {:viewport_size, {1920, 1080}}, 0)
      assert {^model, []} = Model.handle(model, {:viewport_size, {0, 1080}}, 0)
    end

    test "start errors back off 1 s doubling to the cap; the retry timer starts again" do
      delays =
        Enum.map_reduce(1..5, starting(), fn _, model ->
          {model, effects} = Model.handle(model, {:viewport, :start_failed, :no_output}, 0)
          [{gen, ms}] = schedules(effects, :retry)
          {model, retry} = Model.handle(model, {:timer, :retry, gen}, 0)
          assert [{:start_viewport, _}] = retry
          {ms, model}
        end)
        |> elem(0)

      assert delays == [1_000, 2_000, 4_000, 8_000, 8_000]
    end

    test "the HDMI link coming back retries at once with the delay reset" do
      {model, _} = Model.handle(starting(), {:viewport, :start_failed, :no_output}, 0)
      {model, _} = Model.handle(model, {:timer, :retry, model.viewport.gen}, 0)
      {model, _} = Model.handle(model, {:viewport, :start_failed, :no_output}, 0)
      assert model.viewport.delay_ms == 2_000
      stale = model.viewport.gen

      {model, effects} = Model.handle(model, :hdmi_link_up, 0)
      assert [{:start_viewport, _}] = effects
      assert model.viewport.delay_ms == nil

      # The pending retry is stale now.
      assert {_, []} = Model.handle(model, {:timer, :retry, stale}, 0)
    end

    test "three identical crashes step down to raster 720p" do
      model = run!(starting(), [{:viewport, :started}])

      model =
        Enum.reduce(1..2, model, fn _, model ->
          {model, _} = Model.handle(model, {:viewport, :down, {:gl_lost, :x}}, 0)
          {model, _} = Model.handle(model, {:timer, :retry, model.viewport.gen}, 0)
          run!(model, [{:viewport, :started}])
        end)

      assert model.viewport.rung == 0
      {model, effects} = Model.handle(model, {:viewport, :down, {:gl_lost, :y}}, 0)
      assert model.viewport.rung == 1
      [{gen, 1_000}] = schedules(effects, :retry)

      {_model, effects} = Model.handle(model, {:timer, :retry, gen}, 0)
      assert [{:start_viewport, [api: :raster, mode: {1280, 720}]}] = effects
    end

    test "different crashes don't add up, a clean exit isn't a crash" do
      model = run!(starting(), [{:viewport, :started}])
      {model, _} = Model.handle(model, {:viewport, :down, :a}, 0)
      model = run!(model, [{:timer, :retry, model.viewport.gen}, {:viewport, :started}])
      {model, _} = Model.handle(model, {:viewport, :down, :b}, 0)
      assert model.viewport.crashes == 1 and model.viewport.crash_key == :b

      model = run!(model, [{:timer, :retry, model.viewport.gen}, {:viewport, :started}])
      {model, _} = Model.handle(model, {:viewport, :down, {:shutdown, :closed}}, 0)
      assert model.viewport.crashes == 1 and model.viewport.status == :backoff
    end

    test "staying up resets the crash count" do
      model = run!(starting(), [{:viewport, :started}])
      {model, _} = Model.handle(model, {:viewport, :down, :a}, 0)
      model = run!(model, [{:timer, :retry, model.viewport.gen}, {:viewport, :started}])
      model = run!(model, [{:timer, :stable, model.viewport.gen}])
      assert model.viewport.crashes == 0 and model.viewport.delay_ms == nil
    end

    test "after the last rung it fails, retrying at the maximum delay" do
      model = run!(starting(crash_limit: 1, ladder: [[api: :auto]]), [{:viewport, :started}])
      {model, effects} = Model.handle(model, {:viewport, :down, :boom}, 0)
      assert model.viewport.status == :failed
      assert [{_gen, 8_000}] = schedules(effects, :retry)
    end

    test "starts on the bound output's own connector, and follows it to another port" do
      model =
        run!(Model.new(), [
          {:bound, Map.put(@binding, :hdmi_port, 0), nil},
          {:display_available, true}
        ])

      assert model.viewport.port == 0
      model = run!(model, [{:viewport, :started}])

      {model, effects} =
        Model.handle(
          model,
          {:bound, Map.merge(@binding, %{key: {"vc4-hdmi-1", nil, nil}, hdmi_port: 1}), nil},
          0
        )

      assert [:stop_viewport, {:start_viewport, rung}] =
               Enum.filter(effects, &(&1 == :stop_viewport or match?({:start_viewport, _}, &1)))

      assert rung[:connector] == "HDMI-A-2"
      assert model.viewport.status == :starting

      # Same port again: nothing moves.
      model = run!(model, [{:viewport, :started}])
      {_model, effects} = Model.handle(model, {:bound, %{model.binding | cec_dev: nil}, nil}, 0)
      refute :stop_viewport in effects
    end

    test "a crash takes the visualizer off" do
      model = playing()
      assert model.viz == :strip
      {_model, effects} = Model.handle(model, {:viewport, :down, :boom}, 0)
      assert {:viz, nil} in effects
    end
  end

  describe "MilkDrop" do
    @pack {:ready, "2026.11.1", "/data/milkdrop/2026.11.1"}

    # On HDMI port 0, so the viewport's connector is known (and its card
    # reported).
    @md_binding Map.put(@binding, :hdmi_port, 0)
    @card "/dev/dri/card1"

    # Bound, viewport up, pack ready, mode MilkDrop, nothing playing.
    defp md_ready(opts \\ []) do
      run!(md_viewport(opts), [{:pack, @pack}, {:set_mode, :milkdrop}])
    end

    defp md_viewport(opts) do
      run!(Model.new([milkdrop: true] ++ opts), [
        {:bound, @md_binding, nil},
        {:snapshot, 0, %{}},
        {:display_available, true},
        {:viewport_card, @card},
        {:viewport, :started}
      ])
    end

    # Playing with the renderer asked for (not yet yielded).
    defp md_yielding(opts \\ []) do
      {m, effects} = run(md_ready(opts), [{:stream, :start}])
      assert {:yield, :milkdrop} in effects
      m
    end

    defp md_yielded(opts \\ []), do: run!(md_yielding(opts), [{:milkdrop, :yielded}])

    defp starts(effects), do: for({:start_viewport, rung} <- effects, do: rung)

    test "playing with the pack ready yields once; the bars show until yielded" do
      {m, effects} = run(md_ready(), [{:stream, :start}])
      assert Enum.count(effects, &(&1 == {:yield, :milkdrop})) == 1
      assert m.milkdrop.yield and m.milkdrop.active
      assert Model.milkdrop_yield?(m)
      assert Model.screen(m) == {:visualizer, false}
      assert m.viz == :full

      {_m, effects} = run(m, [{:display_event, 5, %{event: "metadata", title: "Song"}}])
      refute {:yield, :milkdrop} in effects
    end

    test "no yield while paused, without the pack, a player, or a running viewport" do
      {_m, effects} = run(md_ready(), [{:key, :play}])
      refute {:yield, :milkdrop} in effects

      {m, effects} = run(md_ready(), [{:pack, {:downloading, 3}}, {:stream, :start}])
      refute {:yield, :milkdrop} in effects
      assert Model.screen(m) == {:milkdrop_preparing, 3}

      no_player = run!(md_ready(), [{:bound, %{@binding | client_id: nil}, nil}])
      {_m, effects} = run(no_player, [{:stream, :start}])
      refute {:yield, :milkdrop} in effects

      {m, effects} = run(md_ready(), [{:viewport, :down, :boom}, {:stream, :start}])
      refute {:yield, :milkdrop} in effects
      # Once the viewport is back, the yield follows.
      {_m, effects} = run(m, [{:timer, :retry, m.viewport.gen}, {:viewport, :started}])
      assert {:yield, :milkdrop} in effects
    end

    test "yielded: the viewport lifecycle stands still, no bars, no restart" do
      m = md_yielding()
      {m, effects} = run(m, [{:milkdrop, :yielded}])
      assert m.viewport.status == :yielded
      assert Model.screen(m) == :milkdrop
      assert {:viz, nil} in effects

      {m, effects} =
        run(m, [
          :hdmi_link_up,
          {:display_available, true},
          {:timer, :retry, m.viewport.gen},
          {:timer, :stable, m.viewport.gen},
          {:viewport, :down, :boom}
        ])

      assert starts(effects) == []
      assert m.viewport.status == :yielded
    end

    test "reclaim on pause: released restarts the viewport at once; the end is quiet" do
      m = md_yielded()
      {m, effects} = run(m, [{:display_event, 9, %{event: "group", playback_state: "paused"}}])
      assert :reclaim in effects
      refute m.milkdrop.yield
      assert m.milkdrop.active

      # Playing again before the session ended waits for it.
      {m, effects} = run(m, [{:stream, :start}])
      refute {:yield, :milkdrop} in effects
      assert m.viewport.status == :yielded

      {m, effects} = run(m, [{:milkdrop, :released}])
      assert [[connector: "HDMI-A-1", api: :auto]] = starts(effects)
      assert m.viewport.status == :starting

      {m, _effects} = run(m, [{:viewport, :started}])
      {m, effects} = run(m, [{:milkdrop, :ended, :requested}])
      assert starts(effects) == []
      refute Enum.any?(effects, &match?({:schedule, :milkdrop_retry, _, _}, &1))
      # Still playing: the next session starts now that the last one ended.
      assert {:yield, :milkdrop} in effects
      assert m.milkdrop.crashes == []
    end

    test "a crash while yielded restarts the viewport at once and holds the next yield" do
      m = md_yielded(milkdrop_retry_ms: 7_000)
      {m, effects} = run(m, [{:milkdrop, :ended, {:crashed, 1}}])
      assert [_rung] = starts(effects)
      assert [{gen, 7_000}] = schedules(effects, :milkdrop_retry)
      refute m.milkdrop.yield or m.milkdrop.active

      {m, effects} = run(m, [{:viewport, :started}])
      refute {:yield, :milkdrop} in effects
      assert Model.screen(m) == {:visualizer, false}
      assert m.viz == :full

      {_m, effects} = run(m, [{:timer, :milkdrop_retry, gen - 1}])
      refute {:yield, :milkdrop} in effects
      {_m, effects} = run(m, [{:timer, :milkdrop_retry, gen}])
      assert {:yield, :milkdrop} in effects
    end

    test "a failure before the viewport yielded leaves it running" do
      {m, effects} = run(md_yielding(), [{:milkdrop, :ended, {:crashed, :prepare_timeout}}])
      assert starts(effects) == []
      assert m.viewport.status == :running
      assert [_] = schedules(effects, :milkdrop_retry)
    end

    defp crash_cycle(m, now) do
      {m, _} = Model.handle(m, {:milkdrop, :yielded}, now)
      {m, _} = Model.handle(m, {:milkdrop, :ended, {:crashed, :boom}}, now)
      {m, _} = Model.handle(m, {:viewport, :started}, now)

      case m.milkdrop.hold do
        nil -> m
        gen -> m |> Model.handle({:timer, :milkdrop_retry, gen}, now) |> elem(0)
      end
    end

    test "three failures in ten minutes latch it off until an explicit mode change" do
      m = md_yielding()
      m = Enum.reduce([0, 1_000, 2_000], m, &crash_cycle(&2, &1))
      assert m.milkdrop.latch == :crashed
      refute m.milkdrop.yield
      assert Model.screen(m) == {:visualizer, false}
      assert m.viz == :full

      {_m, effects} = run(m, [{:timer, :milkdrop_retry, m.milkdrop.gen}, {:stream, :start}])
      refute {:yield, :milkdrop} in effects

      {m, effects} = run(m, [{:set_mode, :milkdrop}])
      assert {:yield, :milkdrop} in effects
      assert m.milkdrop.latch == nil and m.milkdrop.crashes == []
    end

    test "failures further apart than the window don't latch" do
      m = md_yielding()
      m = Enum.reduce([0, 400_000, 800_000, 1_200_000], m, &crash_cycle(&2, &1))
      assert m.milkdrop.latch == nil
      assert length(m.milkdrop.crashes) == 2
      assert m.milkdrop.yield
    end

    test "a thermal exit shows the bars until the next mode change" do
      {m, effects} = run(md_yielded(), [{:milkdrop, :ended, :thermal}])
      assert [_rung] = starts(effects)
      {m, _effects} = run(m, [{:viewport, :started}])
      assert m.milkdrop.latch == :thermal
      assert Model.screen(m) == {:visualizer, false}
      assert m.viz == :full

      {m, effects} = run(m, [{:key, :up}])
      assert m.mode == :visualizer
      refute {:yield, :milkdrop} in effects
      {m, effects} = run(m, [{:key, :down}])
      assert m.mode == :milkdrop
      assert {:yield, :milkdrop} in effects
      assert m.milkdrop.latch == nil
    end

    test "a missing pack is ensured once, with the preparing screen and its progress" do
      m = run!(md_viewport([]), [{:pack, :absent}])
      {m, effects} = run(m, [{:set_mode, :milkdrop}])
      assert Enum.count(effects, &(&1 == :ensure_pack)) == 1
      assert Model.screen(m) == {:milkdrop_preparing, nil}

      {m, effects} = run(m, [{:stream, :start}, {:key, :play}])
      refute :ensure_pack in effects
      refute {:yield, :milkdrop} in effects
      assert Model.screen(m) == {:milkdrop_preparing, nil}
      assert m.viz == nil

      {m, effects} = run(m, [{:pack, {:downloading, 42}}])
      assert :render in effects
      assert Model.screen(m) == {:milkdrop_preparing, 42}

      {m, effects} = run(m, [{:pack, @pack}])
      assert {:yield, :milkdrop} in effects
      assert Model.screen(m) == {:visualizer, false}
    end

    test "a restarted Pack (its download gone) is asked for the pack again" do
      m = run!(md_viewport([]), [{:pack, :absent}])
      {m, effects} = run(m, [{:set_mode, :milkdrop}, {:pack, {:downloading, 40}}])
      assert Enum.count(effects, &(&1 == :ensure_pack)) == 1
      assert Model.screen(m) == {:milkdrop_preparing, 40}

      {m, effects} = run(m, [{:pack_restarted, :absent}])
      assert :ensure_pack in effects
      assert m.pack == :absent
      assert Model.screen(m) == {:milkdrop_preparing, nil}

      # A restarted Pack that finds the pack extracted just reports it.
      {m, effects} = run(m, [{:pack_restarted, @pack}, {:stream, :start}])
      refute :ensure_pack in effects
      assert {:yield, :milkdrop} in effects
      assert m.pack == @pack
    end

    test "the viewport's connector follows the bound HDMI port" do
      assert Model.viewport_connector(md_ready()) == "HDMI-A-1"
      m = md_viewport(milkdrop: true)
      m = run!(m, [{:bound, %{@md_binding | key: {"vc4-hdmi-1", nil, nil}, hdmi_port: 1}, nil}])
      m = run!(m, [{:viewport, :started}])
      assert Model.viewport_connector(m) == "HDMI-A-2"
      assert Model.viewport_connector(ready()) == nil
    end

    test "no yield while the viewport's connector is unknown: the bars show" do
      m = run!(ready(milkdrop: true), [{:pack, @pack}, {:set_mode, :milkdrop}])
      {m, effects} = run(m, [{:stream, :start}])
      refute {:yield, :milkdrop} in effects
      refute m.milkdrop.active
      assert Model.screen(m) == {:visualizer, false}
      assert m.viz == :full
    end

    test "no yield while the viewport's DRM card is unknown: the bars show" do
      m =
        run!(Model.new(milkdrop: true), [
          {:bound, @md_binding, nil},
          {:snapshot, 0, %{}},
          {:display_available, true},
          {:viewport_card, nil},
          {:viewport, :started},
          {:pack, @pack},
          {:set_mode, :milkdrop}
        ])

      assert Model.viewport_connector(m) == "HDMI-A-1"
      assert Model.viewport_card(m) == nil
      {m, effects} = run(m, [{:stream, :start}])
      refute {:yield, :milkdrop} in effects
      assert Model.screen(m) == {:visualizer, false}

      # Reported for the next viewport: the yield follows.
      {m, effects} = run(m, [{:viewport_card, @card}])
      assert {:yield, :milkdrop} in effects
      assert Model.viewport_card(m) == @card
    end

    test "a persisted MilkDrop mode with no pack yet asks for it" do
      m = run!(Model.new(milkdrop: true), [{:pack, :absent}])
      {m, effects} = run(m, [{:bound, @binding, :milkdrop}])
      assert m.mode == :milkdrop
      assert :ensure_pack in effects
    end

    test "a pack error shows a short notice, then the bars; picking MilkDrop retries" do
      m = run!(ready(milkdrop: true, milkdrop_notice_ms: 3_000), [{:pack, {:downloading, 10}}])
      m = run!(m, [{:set_mode, :milkdrop}])
      {m, effects} = run(m, [{:pack, {:error, :checksum_mismatch}}])
      assert [{gen, 3_000}] = schedules(effects, :milkdrop_notice)
      assert Model.screen(m) == :milkdrop_error

      {m, _effects} = run(m, [{:timer, :milkdrop_notice, gen - 1}])
      assert Model.screen(m) == :milkdrop_error
      {m, effects} = run(m, [{:timer, :milkdrop_notice, gen}])
      assert :render in effects
      assert Model.screen(m) == {:visualizer, false}

      {m, effects} = run(m, [{:set_mode, :milkdrop}])
      assert :ensure_pack in effects
      assert [_] = schedules(effects, :milkdrop_notice)
      assert Model.screen(m) == :milkdrop_error

      # The same error again (the retry failed the same way): no new notice.
      {_m, effects} = run(m, [{:pack, {:error, :checksum_mismatch}}])
      assert schedules(effects, :milkdrop_notice) == []
    end

    test "a pack retrying shows the preparing screen, no notice, then yields once ready" do
      m = run!(md_viewport([]), [{:pack, :absent}, {:set_mode, :milkdrop}, {:stream, :start}])

      {m, effects} = run(m, [{:pack, {:retrying, {:transport, :nxdomain}, 5_000}}])
      assert schedules(effects, :milkdrop_notice) == []
      refute :ensure_pack in effects
      refute {:yield, :milkdrop} in effects
      assert Model.screen(m) == {:milkdrop_preparing, nil}

      {m, effects} =
        run(m, [{:pack, {:downloading, 0}}, {:pack, {:retrying, {:http_status, 503}, 15_000}}])

      assert schedules(effects, :milkdrop_notice) == []
      assert Model.screen(m) == {:milkdrop_preparing, nil}

      {m, effects} = run(m, [{:pack, @pack}])
      assert {:yield, :milkdrop} in effects
      assert Model.screen(m) == {:visualizer, false}
    end

    test "picking MilkDrop while the pack waits to retry retries now, without a notice" do
      m = run!(ready(milkdrop: true), [{:pack, {:retrying, :network_down, 60_000}}])

      {m, effects} = run(m, [{:set_mode, :milkdrop}])
      assert :ensure_pack in effects
      assert schedules(effects, :milkdrop_notice) == []
      assert Model.screen(m) == {:milkdrop_preparing, nil}
    end

    test "a pack error outside the MilkDrop mode shows nothing" do
      {m, effects} = run(ready(milkdrop: true), [{:pack, {:error, :no_pack_pinned}}])
      assert schedules(effects, :milkdrop_notice) == []
      assert Model.screen(m) == {:now_playing, false}
    end

    test "while the renderer is wanted, Left/Right/Select drive it" do
      for m <- [md_yielding(), md_yielded()],
          {key, cmd} <- [left: :prev, right: :next, select: :toggle_lock] do
        {after_key, effects} = run(m, [{:key, key}])
        assert effects == [{:milkdrop_cmd, cmd}]
        assert after_key.focus == m.focus
      end
    end

    test "Up/Down and Exit change the mode and reclaim; transport keys work as usual" do
      {m, effects} = run(md_yielded(), [{:key, :down}])
      assert m.mode == :party_qr
      assert :reclaim in effects
      assert {:persist_mode, :party_qr} in effects

      {m, effects} = run(md_yielded(), [{:key, :exit}])
      assert m.mode == :now_playing
      assert :reclaim in effects

      {_m, effects} = run(md_yielded(), [{:key, :play_pause}])
      assert {:controller, :pause} in effects
      {_m, effects} = run(md_yielded(), [{:key, :forward}])
      assert {:controller, :next} in effects
    end

    test "keys are the visualizer's while the renderer is not wanted" do
      {m, effects} = run(md_ready(), [{:key, :left}])
      refute Enum.any?(effects, &match?({:milkdrop_cmd, _}, &1))
      assert m.focus == :prev
    end

    test "no party overlay while yielded (P6)" do
      m = md_yielding()
      m = run!(m, [{:party, @party}])
      assert Model.screen(m) == {:visualizer, true}
      assert Model.screen(run!(m, [{:milkdrop, :yielded}])) == :milkdrop
    end

    test "a mode change while the pack downloads stops the preparing screen" do
      m = run!(md_ready(), [{:pack, {:downloading, 50}}])
      assert Model.screen(m) == {:milkdrop_preparing, 50}
      assert Model.screen(run!(m, [{:key, :up}])) == {:visualizer, false}
    end

    test "Up/Down step through MilkDrop only with the option" do
      assert run!(ready(milkdrop: true), [{:key, :down}, {:key, :down}]).mode == :milkdrop
      assert run!(ready(), [{:key, :down}, {:key, :down}]).mode == :party_qr
    end

    test "with the option off nothing MilkDrop happens" do
      m = ready()
      {m, effects} = run(m, [{:pack, @pack}, {:set_mode, :milkdrop}, {:stream, :start}])
      assert m.mode == :now_playing
      assert {:push_mode, :now_playing} in effects

      refute Enum.any?(
               effects,
               &(match?({:yield, _}, &1) or &1 in [:reclaim, :ensure_pack] or
                   match?({:persist_mode, _}, &1))
             )

      {m, _effects} = run(Model.new(), [{:bound, @binding, :milkdrop}])
      assert m.mode == :now_playing
    end
  end

  test "TV presence keeps its last known value through :unknown" do
    model = run!(ready(), [{:tv_presence, :present}, {:tv_presence, :unknown}])
    assert model.tv_presence == :present
  end
end
