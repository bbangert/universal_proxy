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

    def set_volume(pid, value), do: GenServer.call(pid, {:set_volume, value})
    def set_muted(pid, value), do: GenServer.call(pid, {:set_muted, value})

    @impl true
    def init(opts) do
      # Trap exits — must match Audio.Player so DynamicSupervisor's
      # `:shutdown` signal triggers terminate/2. Without this we'd
      # die instantly and the test couldn't observe the terminate
      # event.
      Process.flag(:trap_exit, true)
      key = Keyword.fetch!(opts, :key)
      record({:started, key, Keyword.fetch!(opts, :mdns_port)})
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
      assert {:started, @hp_key, 8928} in calls
    end

    test "update_config with volume forwards to set_volume", %{server: server} do
      :ok = Server.update_config(server, @hp_key, %{volume: 77})
      assert_receive {:sendspin_state, @hp_key, %{volume: 77}}

      # Cast/call flush — set_volume is a synchronous GenServer.call,
      # so by the time update_config returns it must have completed.
      calls = PlayerStubCalls.calls()
      assert {:set_volume, @hp_key, 77} in calls
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
    end

    test "set_enabled(true) after disable respawns the player", %{server: server, player_sup: sup} do
      :ok = Server.set_enabled(server, @hp_key, false)
      assert_receive {:sendspin_state, @hp_key, %{enabled: false}}
      assert DynamicSupervisor.which_children(sup) == []

      :ok = Server.set_enabled(server, @hp_key, true)
      assert_receive {:sendspin_state, @hp_key, %{enabled: true}}

      assert length(DynamicSupervisor.which_children(sup)) == 1
      # Two `:started` events recorded (initial + after re-enable).
      starts = Enum.count(PlayerStubCalls.calls(), &match?({:started, @hp_key, _}, &1))
      assert starts == 2
    end
  end
end
