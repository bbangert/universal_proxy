defmodule UniversalProxy.Audio.ServerTest do
  # async: false — the test shares one named EnumerateStub Agent and
  # subscribes the test PID to global PubSub topics. Concurrent tests
  # would see each other's broadcasts.
  use ExUnit.Case, async: false

  alias UniversalProxy.Audio.{Server, Store}

  @pubsub UniversalProxy.PubSub
  @store_table :audio_server_store_test

  @hp_key {"bcm2835 Headphones", nil, nil}
  @hdmi_key {"vc4-hdmi", nil, nil}

  defmodule EnumerateStub do
    @moduledoc false
    use Agent

    def start_link(initial \\ %{}) do
      Agent.start_link(fn -> initial end, name: __MODULE__)
    end

    def set(outputs), do: Agent.update(__MODULE__, fn _ -> outputs end)

    @doc false
    def safe, do: Agent.get(__MODULE__, & &1)
  end

  defmodule PlayerStub do
    @moduledoc """
    Stand-in for Audio.Player used by the player-lifecycle describe
    block below. Records lifecycle and call events into a named Agent
    so tests can assert Server-side forwarding without spawning a real
    `sendspin_player` binary. Matches Audio.Player's `child_spec`
    shape so `DynamicSupervisor.start_child` works.
    """
    use GenServer, restart: :temporary

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    # Guards mirror the real `Audio.Player.set_volume/2` and
    # `set_muted/2` so a regression that lets caller-supplied strings
    # or out-of-range integers through Server's forwarding path
    # surfaces as a `FunctionClauseError` here too, instead of being
    # silently accepted by the stub.
    def set_volume(pid, value) when is_integer(value) and value in 0..100,
      do: GenServer.call(pid, {:set_volume, value})

    def set_muted(pid, value) when is_boolean(value),
      do: GenServer.call(pid, {:set_muted, value})

    @impl true
    def init(opts) do
      # Trap exits — must match Audio.Player so DynamicSupervisor's
      # `:shutdown` signal triggers terminate/2. Without this we'd
      # die instantly and the test couldn't observe the terminate
      # event.
      Process.flag(:trap_exit, true)
      key = Keyword.fetch!(opts, :key)
      mdns_port = Keyword.fetch!(opts, :mdns_port)
      config = Keyword.fetch!(opts, :config)
      # Record the full config so rename tests can verify that the
      # respawned player received the NEW friendly_name (a regression
      # that restarted with stale config would otherwise pass).
      record({:started, key, mdns_port, config})
      {:ok, %{key: key}}
    end

    @impl true
    def handle_call({:set_volume, v}, _from, state) do
      record({:set_volume, state.key, v})
      {:reply, :ok, state}
    end

    def handle_call({:set_muted, v}, _from, state) do
      record({:set_muted, state.key, v})
      {:reply, :ok, state}
    end

    @impl true
    def terminate(_reason, state) do
      record({:terminated, state.key})
      :ok
    end

    defp record(event) do
      # Full module path required — Elixir's auto-alias does NOT pick
      # up sibling nested modules from `PlayerStub`'s position, so a
      # bare `PlayerStubCalls` would resolve to `Elixir.PlayerStubCalls`
      # (a top-level atom) and fail with `:noproc`. The Agent is
      # registered under the full nested name.
      #
      # Guarded against `:exit` because `terminate/2` may fire after
      # the supervisor has already begun tearing down the Agent.
      try do
        Agent.update(
          UniversalProxy.Audio.ServerTest.PlayerStubCalls,
          fn calls -> [event | calls] end
        )
      catch
        :exit, _ -> :ok
      end
    end
  end

  defmodule PlayerStubCalls do
    @moduledoc false
    use Agent

    def start_link(_opts \\ []) do
      Agent.start_link(fn -> [] end, name: __MODULE__)
    end

    def calls, do: __MODULE__ |> Agent.get(& &1) |> Enum.reverse()
  end

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "audio_server_test_#{System.unique_integer([:positive])}.dets"
      )

    on_exit(fn -> File.rm(path) end)

    start_supervised!({EnumerateStub, %{}})

    store =
      start_supervised!({Store, name: nil, table: @store_table, dets_path: path}, id: :store)

    server =
      start_supervised!(
        {
          Server,
          # These tests focus on Server orchestration of state + PubSub.
          # Phase 3's player spawning is exercised separately by
          # `UniversalProxy.Audio.PlayerTest`; `player_supervisor: nil`
          # short-circuits the DynamicSupervisor.start_child path so we
          # don't fork real `sendspin_player` binaries here.
          name: nil,
          store: store,
          enumerate_module: EnumerateStub,
          start_timer: false,
          player_supervisor: nil,
          mdns_discovery: nil
        },
        id: :server
      )

    :ok = Phoenix.PubSub.subscribe(@pubsub, "sendspin:output_added")
    :ok = Phoenix.PubSub.subscribe(@pubsub, "sendspin:output_removed")
    :ok = Phoenix.PubSub.subscribe(@pubsub, "sendspin:state")

    {:ok, server: server, store: store}
  end

  describe "hotplug add" do
    test "broadcasts :sendspin_output_added and persists DETS row", %{
      server: server,
      store: store
    } do
      EnumerateStub.set(%{
        @hp_key => %{
          card_index: 0,
          alsa_device: "plughw:0,0",
          card_name: "bcm2835 Headphones"
        }
      })

      :ok = Server.check_now(server)

      assert_receive {:sendspin_output_added, output}
      assert output.key == @hp_key
      assert output.alsa_device == "plughw:0,0"
      assert output.card_name == "bcm2835 Headphones"
      assert output.friendly_name == "bcm2835 Headphones"
      assert output.enabled == true
      assert output.volume == 50
      assert output.muted == false
      assert is_binary(output.client_id)

      assert {:ok, cfg} = Store.get_config(store, @hp_key)
      assert cfg.friendly_name == "bcm2835 Headphones"
      assert cfg.client_id == output.client_id
    end

    test "does not re-broadcast for outputs already known to the server", %{server: server} do
      EnumerateStub.set(%{
        @hp_key => %{
          card_index: 0,
          alsa_device: "plughw:0,0",
          card_name: "bcm2835 Headphones"
        }
      })

      :ok = Server.check_now(server)
      assert_receive {:sendspin_output_added, _}

      :ok = Server.check_now(server)
      refute_receive {:sendspin_output_added, _}, 200
    end
  end

  describe "hotplug remove" do
    test "broadcasts :sendspin_output_removed but keeps the DETS row", %{
      server: server,
      store: store
    } do
      EnumerateStub.set(%{
        @hp_key => %{
          card_index: 0,
          alsa_device: "plughw:0,0",
          card_name: "bcm2835 Headphones"
        }
      })

      :ok = Server.check_now(server)
      assert_receive {:sendspin_output_added, _}

      EnumerateStub.set(%{})
      :ok = Server.check_now(server)

      assert_receive {:sendspin_output_removed, %{key: @hp_key}}
      # DETS row survives unplug so user config sticks across reboot
      assert {:ok, %{friendly_name: "bcm2835 Headphones"}} = Store.get_config(store, @hp_key)
    end
  end

  describe "list_outputs/1 + get_output/2" do
    test "returns merged maps sorted by friendly_name", %{server: server} do
      EnumerateStub.set(%{
        @hp_key => %{
          card_index: 0,
          alsa_device: "plughw:0,0",
          card_name: "bcm2835 Headphones"
        },
        @hdmi_key => %{
          card_index: 1,
          alsa_device: "plughw:1,0",
          card_name: "vc4-hdmi"
        }
      })

      :ok = Server.check_now(server)
      # Two `:sendspin_output_added` messages arrive in any order
      # (refresh_outputs/1 iterates `MapSet.difference/2` which is
      # unordered). These two `assert_receive` calls drain the mailbox;
      # the actual ordering assertion lives in `list_outputs/1`, which
      # the Server sorts by friendly_name.
      assert_receive {:sendspin_output_added, _}
      assert_receive {:sendspin_output_added, _}

      [first, second] = Server.list_outputs(server)
      assert first.card_name == "bcm2835 Headphones"
      assert second.card_name == "vc4-hdmi"

      assert {:ok, hp} = Server.get_output(server, @hp_key)
      assert hp.card_name == "bcm2835 Headphones"

      assert :error = Server.get_output(server, {"nope", nil, nil})
    end
  end

  describe "update_config/3" do
    setup %{server: server} do
      EnumerateStub.set(%{
        @hp_key => %{
          card_index: 0,
          alsa_device: "plughw:0,0",
          card_name: "bcm2835 Headphones"
        }
      })

      :ok = Server.check_now(server)
      assert_receive {:sendspin_output_added, _}
      :ok
    end

    test "persists allowed fields and broadcasts :sendspin_state", %{
      server: server,
      store: store
    } do
      :ok =
        Server.update_config(server, @hp_key, %{
          friendly_name: "Living Room",
          volume: 75,
          muted: true,
          # silently dropped
          enabled: false
        })

      assert_receive {:sendspin_state, @hp_key, partial}
      assert partial == %{friendly_name: "Living Room", volume: 75, muted: true}

      {:ok, persisted} = Store.get_config(store, @hp_key)
      assert persisted.friendly_name == "Living Room"
      assert persisted.volume == 75
      assert persisted.muted == true
      # :enabled NOT modified via update_config
      assert persisted.enabled == true
    end

    test "returns {:error, :not_found} for unknown output", %{server: server} do
      assert {:error, :not_found} =
               Server.update_config(server, {"missing", nil, nil}, %{friendly_name: "x"})
    end
  end

  describe "set_enabled/3" do
    test "persists, broadcasts, and survives in get_output/2", %{server: server, store: store} do
      EnumerateStub.set(%{
        @hp_key => %{
          card_index: 0,
          alsa_device: "plughw:0,0",
          card_name: "bcm2835 Headphones"
        }
      })

      :ok = Server.check_now(server)
      assert_receive {:sendspin_output_added, _}

      :ok = Server.set_enabled(server, @hp_key, false)

      assert_receive {:sendspin_state, @hp_key, %{enabled: false}}
      assert {:ok, %{enabled: false}} = Store.get_config(store, @hp_key)
      assert {:ok, %{enabled: false}} = Server.get_output(server, @hp_key)
    end
  end

  describe "player lifecycle (PlayerStub + real DynamicSupervisor)" do
    # These tests need real DynamicSupervisor + a Player stand-in
    # because the parent `setup` block passes `player_supervisor: nil`
    # to skip player spawning. We override per-test here.
    setup do
      path =
        Path.join(
          System.tmp_dir!(),
          "audio_server_lifecycle_#{System.unique_integer([:positive])}.dets"
        )

      on_exit(fn -> File.rm(path) end)

      start_supervised!(PlayerStubCalls, id: :player_stub_calls)

      player_sup =
        start_supervised!(
          {DynamicSupervisor, strategy: :one_for_one, name: nil},
          id: :lifecycle_player_sup
        )

      store =
        start_supervised!({Store, name: nil, table: :lifecycle_store, dets_path: path},
          id: :lifecycle_store
        )

      lifecycle_server =
        start_supervised!(
          {Server,
           name: nil,
           store: store,
           enumerate_module: EnumerateStub,
           start_timer: false,
           player_supervisor: player_sup,
           player_module: PlayerStub,
           mdns_discovery: nil},
          id: :lifecycle_server
        )

      EnumerateStub.set(%{
        @hp_key => %{
          card_index: 0,
          alsa_device: "plughw:0,0",
          card_name: "bcm2835 Headphones"
        }
      })

      :ok = Server.check_now(lifecycle_server)
      assert_receive {:sendspin_output_added, _}

      {:ok, server: lifecycle_server, store: store, player_sup: player_sup}
    end

    test "spawns PlayerStub on enabled hotplug add", %{player_sup: sup} do
      children = DynamicSupervisor.which_children(sup)
      assert length(children) == 1

      calls = PlayerStubCalls.calls()
      assert Enum.any?(calls, &match?({:started, @hp_key, 8928, _config}, &1))
    end

    test "update_config with volume forwards to set_volume", %{server: server} do
      :ok = Server.update_config(server, @hp_key, %{volume: 77})
      assert_receive {:sendspin_state, @hp_key, %{volume: 77}}

      # Cast/call flush — set_volume is a synchronous GenServer.call,
      # so by the time update_config returns it must have completed.
      calls = PlayerStubCalls.calls()
      assert {:set_volume, @hp_key, 77} in calls
    end

    test "update_config forwards normalized (not raw) values to the player", %{server: server} do
      # `Player.set_volume/2` is guarded `is_integer(value) and value in 0..100`.
      # If Server forwarded the caller-supplied `update` map unchanged,
      # callers like `%{volume: "77"}` or `%{volume: 101}` would raise
      # `FunctionClauseError` inside `Player.set_volume/2`, which
      # propagates through Server's own handle_call and crashes the
      # audio subsystem. Server now forwards `merged.volume` (post
      # `Store.merge_defaults`/`clamp_volume`) instead — always an
      # integer in 0..100.
      #
      # String input → Store.clamp_volume/1 default of 50.
      :ok = Server.update_config(server, @hp_key, %{volume: "77"})
      assert {:set_volume, @hp_key, 50} in PlayerStubCalls.calls()

      # Out-of-range integer → clamped to 100.
      :ok = Server.update_config(server, @hp_key, %{volume: 999})
      assert {:set_volume, @hp_key, 100} in PlayerStubCalls.calls()

      # Negative integer → clamped to 0.
      :ok = Server.update_config(server, @hp_key, %{volume: -5})
      assert {:set_volume, @hp_key, 0} in PlayerStubCalls.calls()
    end

    test "renaming an output restarts the player so --name / mDNS TXT update", %{
      server: server,
      player_sup: sup
    } do
      # `--name` and the mDNS TXT `name=` are baked at spawn — there's
      # no `set_name` stdin command — so the only way to propagate a
      # rename is to stop+start the player. Verify the lifecycle
      # records a terminate + a new start carrying the NEW config (a
      # regression that restarted with the stale config would still
      # show "terminated + started" but with the old friendly_name).
      [{:undefined, old_pid, _, _}] = DynamicSupervisor.which_children(sup)

      :ok = Server.update_config(server, @hp_key, %{friendly_name: "Living Room"})

      calls = PlayerStubCalls.calls()
      assert {:terminated, @hp_key} in calls

      # The most recent :started entry must carry the renamed config.
      latest_start =
        calls
        |> Enum.reverse()
        |> Enum.find(&match?({:started, @hp_key, _, _}, &1))

      assert {:started, @hp_key, _port, %{friendly_name: "Living Room"}} = latest_start

      [{:undefined, new_pid, _, _}] = DynamicSupervisor.which_children(sup)
      assert new_pid != old_pid
      assert :sys.get_state(server).outputs[@hp_key].friendly_name == "Living Room"
    end

    test "renaming a disabled output does NOT spawn a player", %{
      server: server,
      player_sup: sup
    } do
      # First disable the output. PlayerStub.terminate fires.
      :ok = Server.set_enabled(server, @hp_key, false)
      assert_receive {:sendspin_state, @hp_key, %{enabled: false}}
      assert DynamicSupervisor.which_children(sup) == []
      starts_before = Enum.count(PlayerStubCalls.calls(), &match?({:started, _, _, _}, &1))

      # Renaming a disabled output must not respawn — that would
      # broadcast mDNS again and stream audio the user explicitly
      # turned off.
      :ok = Server.update_config(server, @hp_key, %{friendly_name: "Living Room"})

      assert DynamicSupervisor.which_children(sup) == []
      starts_after = Enum.count(PlayerStubCalls.calls(), &match?({:started, _, _, _}, &1))
      assert starts_after == starts_before

      # Persistence still happens though — re-enable should pick up
      # the new name.
      assert :sys.get_state(server).outputs[@hp_key].friendly_name == "Living Room"
    end

    test "broadcasts normalized values, not raw caller input", %{server: server} do
      # Caller passes a string volume that `Store.clamp_volume/1`
      # rejects → falls back to default 50. The broadcast must carry
      # the normalized integer, not the raw `"77"`, so PubSub
      # subscribers (LiveView in Phase 4) never have to re-validate.
      :ok = Server.update_config(server, @hp_key, %{volume: "77"})

      assert_receive {:sendspin_state, @hp_key, %{volume: 50}}
      refute_receive {:sendspin_state, @hp_key, %{volume: "77"}}, 100
    end

    test "update_config with muted forwards to set_muted", %{server: server} do
      :ok = Server.update_config(server, @hp_key, %{muted: true})
      assert_receive {:sendspin_state, @hp_key, %{muted: true}}

      calls = PlayerStubCalls.calls()
      assert {:set_muted, @hp_key, true} in calls
    end

    test "set_enabled(false) terminates the player", %{server: server, player_sup: sup} do
      :ok = Server.set_enabled(server, @hp_key, false)
      assert_receive {:sendspin_state, @hp_key, %{enabled: false}}

      assert DynamicSupervisor.which_children(sup) == []
      assert {:terminated, @hp_key} in PlayerStubCalls.calls()

      # Orderly :shutdown exit must NOT pollute unusable_ports.
      # `maybe_mark_port_unusable/3` has explicit clauses for `:normal`
      # / `:shutdown` / `{:shutdown, _}` — a regression there would
      # mark the port unusable on every set_enabled toggle and the
      # allocator would slowly climb.
      assert :sys.get_state(server).unusable_ports == MapSet.new()
    end

    test "persists binary-emitted volume events to DETS (MA-side slider, etc)",
         %{server: server, store: store} do
      # When Music Assistant moves its slider, the binary emits a
      # `{"event":"volume","value":N}` line that Player broadcasts on
      # `sendspin:state`. Server subscribes to that topic and must
      # persist the new value so the next respawn or reboot restores
      # the actual last-known volume — not whatever BEAM last wrote.
      # Caught on Pi-3 validation when audio resumed after `kill -9`
      # at a different volume than MA's slider position.
      Phoenix.PubSub.broadcast(
        @pubsub,
        "sendspin:state",
        {:sendspin_state, @hp_key, %{event: "volume", value: 37}}
      )

      # `:sys.get_state/1` is a synchronous GenServer call — it queues
      # in Server's mailbox AFTER the broadcast message and only
      # returns once Server has processed everything in front of it,
      # including Store.save_config from the handle_info path. No
      # fixed sleep needed.
      :sys.get_state(server)

      assert {:ok, %{volume: 37}} = Store.get_config(store, @hp_key)
      assert :sys.get_state(server).outputs[@hp_key].volume == 37
    end

    test "persists binary-emitted mute events to DETS", %{server: server, store: store} do
      Phoenix.PubSub.broadcast(
        @pubsub,
        "sendspin:state",
        {:sendspin_state, @hp_key, %{event: "mute", value: true}}
      )

      :sys.get_state(server)

      assert {:ok, %{muted: true}} = Store.get_config(store, @hp_key)
      assert :sys.get_state(server).outputs[@hp_key].muted == true
    end

    test "exposes binary-emitted connection state to list_outputs late subscribers",
         %{server: server} do
      # Late-subscriber bug regression: a LiveView that mounts *after*
      # the binary emits `connected` would otherwise show "Stopped" /
      # "Idle" until the next event landed. Server now caches the
      # derived state and merges it into list_outputs.
      [out] = Server.list_outputs(server)
      assert out.connection == :unknown
      assert out.stream == nil

      Phoenix.PubSub.broadcast(
        @pubsub,
        "sendspin:state",
        {:sendspin_state, @hp_key, %{event: "connected"}}
      )

      Phoenix.PubSub.broadcast(
        @pubsub,
        "sendspin:state",
        {:sendspin_state, @hp_key,
         %{event: "stream_start", codec: "opus", sample_rate: 48_000, bit_depth: 16, channels: 2}}
      )

      :sys.get_state(server)

      [out] = Server.list_outputs(server)
      assert out.connection == :connected
      assert out.stream == %{codec: "opus", sample_rate: 48_000, bit_depth: 16, channels: 2}

      # `disconnected` clears the stream and flips the connection flag.
      Phoenix.PubSub.broadcast(
        @pubsub,
        "sendspin:state",
        {:sendspin_state, @hp_key, %{event: "disconnected"}}
      )

      :sys.get_state(server)

      [out] = Server.list_outputs(server)
      assert out.connection == :disconnected
      assert out.stream == nil
    end

    test "respawns the player on the next poll when it dies unexpectedly", %{
      server: server,
      player_sup: sup
    } do
      # Simulates the production case where the OS binary is killed
      # (kill -9) — Player exits with {:binary_exited, _}, Server's
      # :DOWN handler clears state.players[key], but state.outputs[key]
      # remains. Without `respawn_missing_players/1` the next hotplug
      # poll's add/remove diff would be empty and the player would
      # never come back. Caught on real Pi hardware during Phase 3
      # validation.
      [{:undefined, old_pid, _, _}] = DynamicSupervisor.which_children(sup)
      ref = Process.monitor(old_pid)
      :ok = GenServer.stop(old_pid, :killed_for_test, 1_000)
      assert_receive {:DOWN, ^ref, :process, ^old_pid, _}, 1_000

      # Test process's DOWN doesn't imply Server's DOWN has been
      # processed. `:sys.get_state/1` flushes Server's mailbox —
      # returns only after Server has run its own :DOWN handler.
      assert :sys.get_state(server).players == %{}
      assert DynamicSupervisor.which_children(sup) == []

      # Now drive a poll — convergence should respawn.
      :ok = Server.check_now(server)

      [{:undefined, new_pid, _, _}] = DynamicSupervisor.which_children(sup)
      assert new_pid != old_pid
    end

    test "set_enabled(true) after disable respawns the player", %{server: server, player_sup: sup} do
      :ok = Server.set_enabled(server, @hp_key, false)
      assert_receive {:sendspin_state, @hp_key, %{enabled: false}}
      assert DynamicSupervisor.which_children(sup) == []

      :ok = Server.set_enabled(server, @hp_key, true)
      assert_receive {:sendspin_state, @hp_key, %{enabled: true}}

      assert length(DynamicSupervisor.which_children(sup)) == 1
      # Two `:started` events recorded (initial + after re-enable).
      starts = Enum.count(PlayerStubCalls.calls(), &match?({:started, @hp_key, _, _}, &1))
      assert starts == 2
    end
  end

  describe "binary_missing tracking" do
    @binary_missing_topic "binary_missing_attempts"

    defmodule BinaryMissingPlayer do
      @moduledoc false
      use GenServer, restart: :temporary

      def start_link(opts) do
        # Broadcast attempts so the test can observe retries (the
        # flag clears mid-flight then re-fills on the failed retry,
        # so end-state inspection alone can't tell whether a retry
        # actually happened).
        Phoenix.PubSub.broadcast(
          UniversalProxy.PubSub,
          "binary_missing_attempts",
          {:binary_missing_attempt, Keyword.fetch!(opts, :key)}
        )

        GenServer.start_link(__MODULE__, [])
      end

      @impl true
      def init(_), do: {:stop, {:binary_missing, "/tmp/never_built/sendspin_player"}}
    end

    setup do
      path =
        Path.join(
          System.tmp_dir!(),
          "audio_server_missing_#{System.unique_integer([:positive])}.dets"
        )

      on_exit(fn -> File.rm(path) end)

      player_sup =
        start_supervised!(
          {DynamicSupervisor, strategy: :one_for_one, name: nil},
          id: :missing_player_sup
        )

      store =
        start_supervised!({Store, name: nil, table: :missing_store, dets_path: path},
          id: :missing_store
        )

      server =
        start_supervised!(
          {Server,
           name: nil,
           store: store,
           enumerate_module: EnumerateStub,
           start_timer: false,
           player_supervisor: player_sup,
           player_module: BinaryMissingPlayer,
           mdns_discovery: nil},
          id: :missing_server
        )

      EnumerateStub.set(%{
        @hp_key => %{
          card_index: 0,
          alsa_device: "plughw:0,0",
          card_name: "bcm2835 Headphones"
        }
      })

      :ok = Phoenix.PubSub.subscribe(@pubsub, @binary_missing_topic)

      :ok = Server.check_now(server)
      assert_receive {:sendspin_output_added, _}
      # Drain the initial-spawn attempt notification.
      assert_receive {:binary_missing_attempt, @hp_key}, 500

      {:ok, server: server, player_sup: player_sup}
    end

    test "marks keys with :binary_missing once and skips them on subsequent polls",
         %{server: server, player_sup: sup} do
      # Setup already drained the first attempt notification.
      # `binary_missing` is set and no player exists.
      assert DynamicSupervisor.which_children(sup) == []
      assert MapSet.member?(:sys.get_state(server).binary_missing, @hp_key)

      # Subsequent polls must NOT attempt the spawn again. No new
      # `:binary_missing_attempt` messages should arrive.
      :ok = Server.check_now(server)
      :ok = Server.check_now(server)
      refute_receive {:binary_missing_attempt, _}, 200
      assert DynamicSupervisor.which_children(sup) == []
      assert MapSet.member?(:sys.get_state(server).binary_missing, @hp_key)
    end

    test "set_enabled(true) clears the flag so the user can retry", %{
      server: server
    } do
      assert MapSet.member?(:sys.get_state(server).binary_missing, @hp_key)

      :ok = Server.set_enabled(server, @hp_key, false)
      assert_receive {:sendspin_state, @hp_key, %{enabled: false}}
      # Disabling must not attempt a spawn.
      refute_receive {:binary_missing_attempt, _}, 100

      :ok = Server.set_enabled(server, @hp_key, true)
      assert_receive {:sendspin_state, @hp_key, %{enabled: true}}

      # The retry attempt is the observable proof that
      # `binary_missing` was cleared. The flag re-fills synchronously
      # when the retry fails, so end-state inspection alone can't
      # distinguish "never cleared" from "cleared+re-filled".
      assert_receive {:binary_missing_attempt, @hp_key}, 500
    end

    test "hotplug remove clears the flag for that key", %{server: server} do
      assert MapSet.member?(:sys.get_state(server).binary_missing, @hp_key)

      EnumerateStub.set(%{})
      :ok = Server.check_now(server)
      assert_receive {:sendspin_output_removed, %{key: @hp_key}}

      refute MapSet.member?(:sys.get_state(server).binary_missing, @hp_key)
    end
  end

  describe "unusable_ports tracking" do
    defmodule SelfCrashingPlayer do
      @moduledoc false
      use GenServer, restart: :temporary

      def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

      @impl true
      def init(opts) do
        Process.flag(:trap_exit, true)
        port = Keyword.fetch!(opts, :mdns_port)
        # Drop a marker so the test can verify which port we got
        # allocated. {:continue, :die} crashes us immediately AFTER
        # init returns — emulates a binary that fails to bind its
        # port.
        send(self(), :__bind_failed__)
        {:ok, %{port: port}, {:continue, :die}}
      end

      @impl true
      def handle_continue(:die, state),
        do: {:stop, :simulated_port_bind_failure, state}
    end

    setup do
      path =
        Path.join(
          System.tmp_dir!(),
          "audio_server_unusable_#{System.unique_integer([:positive])}.dets"
        )

      on_exit(fn -> File.rm(path) end)

      player_sup =
        start_supervised!(
          {DynamicSupervisor, strategy: :one_for_one, name: nil},
          id: :unusable_player_sup
        )

      store =
        start_supervised!({Store, name: nil, table: :unusable_store, dets_path: path},
          id: :unusable_store
        )

      server =
        start_supervised!(
          {Server,
           name: nil,
           store: store,
           enumerate_module: EnumerateStub,
           start_timer: false,
           player_supervisor: player_sup,
           player_module: SelfCrashingPlayer,
           mdns_discovery: nil},
          id: :unusable_server
        )

      EnumerateStub.set(%{
        @hp_key => %{
          card_index: 0,
          alsa_device: "plughw:0,0",
          card_name: "bcm2835 Headphones"
        }
      })

      {:ok, server: server, player_sup: player_sup}
    end

    test "abnormal player exit marks its port unusable and the allocator skips it",
         %{server: server} do
      # First poll: allocator picks port 8928 (base), starts
      # SelfCrashingPlayer which immediately dies → Server's :DOWN
      # handler runs `maybe_mark_port_unusable` with reason
      # `:simulated_port_bind_failure`.
      :ok = await_player_crash(server, 8928)

      # Next poll: respawn_missing_players tries again. Allocator must
      # skip 8928 (just marked unusable) and pick the next free port.
      # SelfCrashingPlayer dies on the new port too, so we accumulate.
      :ok = await_player_crash(server, 8929)

      state = :sys.get_state(server)
      assert MapSet.member?(state.unusable_ports, 8928)
      assert MapSet.member?(state.unusable_ports, 8929)
    end

    test "allocator returns nil when port range is exhausted; spawn is skipped",
         %{server: server, player_sup: sup} do
      # Saturate the unusable_ports set so the allocator has no
      # candidate left in [port_base, 65_535]. Before this fix the
      # unbounded `Stream.iterate` would happily return 65_536 → the
      # binary would fail to bind every time → permanent respawn loop
      # with invalid `--mdns-port`.
      saturated =
        Map.update!(:sys.get_state(server), :unusable_ports, fn _ ->
          MapSet.new(8928..65_535)
        end)

      :sys.replace_state(server, fn _ -> saturated end)

      # `check_now` triggers respawn convergence. Allocator returns nil
      # → start_player logs + skips → no child appears. No crash, no
      # invalid port number leaving the BEAM.
      :ok = Server.check_now(server)

      assert DynamicSupervisor.which_children(sup) == []
      assert :sys.get_state(server).players == %{}
    end

    # Drives `check_now` and waits for the spawned SelfCrashingPlayer
    # to die. The player's `handle_continue` may race with
    # `:sys.get_state` — by the time we read state, the player may
    # already be gone (or not). Poll for `state.players` to be empty
    # and the new port to land in `unusable_ports` before letting the
    # test assert.
    defp await_player_crash(server, expected_port) do
      :ok = Server.check_now(server)

      eventually(
        fn ->
          state = :sys.get_state(server)
          state.players == %{} and MapSet.member?(state.unusable_ports, expected_port)
        end,
        1_000
      )

      :ok
    end

    defp eventually(check, timeout_ms) do
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      do_eventually(check, deadline)
    end

    defp do_eventually(check, deadline) do
      if check.() do
        :ok
      else
        if System.monotonic_time(:millisecond) > deadline do
          flunk("eventually/2 condition did not hold within timeout")
        else
          Process.sleep(10)
          do_eventually(check, deadline)
        end
      end
    end
  end
end
