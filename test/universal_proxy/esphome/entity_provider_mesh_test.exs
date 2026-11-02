defmodule UniversalProxy.ESPHome.EntityProviderMeshTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  import ExUnit.CaptureLog

  alias Espex.DeviceConfig.Device
  alias Espex.Proto
  alias UniversalProxy.ESPHome.EntityProvider, as: EP
  alias UniversalProxy.ESPHome.EntityProvider.MeshSync
  alias UniversalProxy.TuyaMesh.{Entities, Store}

  @mac1 "DC23530FB34A"
  @mac2 "DC23533FCD62"
  @role "AA:BB:CC:DD:EE:FF"

  defp summary(overrides \\ %{}) do
    Map.merge(
      %{
        bulbs: [%{mac: @mac1, label: "path light 2"}, %{mac: @mac2, label: "post spot 1"}],
        groups: [%{local_id: 1, name: "path and post"}],
        device_ids: %{{:bulb, @mac1} => 1, {:bulb, @mac2} => 2, {:group, 1} => 3}
      },
      overrides
    )
  end

  # Mesh inputs backed by an Agent the test rewrites between syncs.
  defp start_inputs(initial \\ %{}) do
    agent =
      start_supervised!(
        {Agent,
         fn ->
           Map.merge(
             %{
               role: {:ok, @role},
               inventory: {:ok, summary()},
               settings: Store.default_settings(),
               status: %{bulbs: []},
               ids: %{{:bulb, @mac1} => 1, {:bulb, @mac2} => 2, {:group, 1} => 3},
               synced: true,
               light_states: []
             },
             initial
           )
         end}
      )

    put = fn key, value -> Agent.update(agent, &Map.put(&1, key, value)) end
    get = fn key -> fn -> Agent.get(agent, &Map.fetch!(&1, key)) end end

    sources = [
      mesh_role: get.(:role),
      mesh_inventory: get.(:inventory),
      mesh_settings: get.(:settings),
      mesh_status: get.(:status),
      mesh_device_ids: get.(:ids),
      mesh_time_synced: get.(:synced),
      mesh_light_states: get.(:light_states)
    ]

    {sources, put}
  end

  defp start_provider(sources, opts \\ []) do
    test = self()

    defaults = [
      name: :"ep_mesh_#{System.unique_integer([:positive])}",
      server: :"ep_mesh_server_#{System.unique_integer([:positive])}",
      poll: false,
      subscribe: false,
      supported?: true,
      # Timers never fire on their own here: tests fire them (settle/1,
      # fire/2), so every step is deterministic.
      mesh_debounce_ms: 60_000,
      mesh_retry_ms: 60_000,
      mesh_check_ms: 60_000,
      sources: sources,
      espex_devices: fn _server -> exit(:noproc) end,
      update_device_config: fn server, opts ->
        send(test, {:espex, :update_device_config, server, opts})
        :ok
      end,
      disconnect_clients: fn server ->
        send(test, {:espex, :disconnect_clients, server})
        :ok
      end,
      mesh_push: fn _server, struct -> send(test, {:mesh_push, struct}) end
    ]

    start_supervised!({EP, Keyword.merge(defaults, opts)})
  end

  # Handles every message sent before it, then runs the armed read (the
  # debounce or a retry) at once.
  defp settle(pid), do: fire(pid, :read)

  # Fires the armed `kind` timer now (a no-op when none is armed).
  defp fire(pid, kind) do
    %{mesh: mesh} = :sys.get_state(pid)

    case {kind, mesh} do
      {:read, %{read_timer: token}} when is_reference(token) ->
        send(pid, {:mesh_read, token})

      {:apply, %{apply_timer: token}} when is_reference(token) ->
        send(pid, {:mesh_apply, token})

      {:resubscribe, %{sub_timer: token}} when is_reference(token) ->
        send(pid, {:mesh_resubscribe, token})

      _none ->
        :ok
    end

    :sys.get_state(pid)
  end

  defp espex_calls(acc \\ []) do
    receive do
      {:espex, call, _server, _opts} -> espex_calls([call | acc])
      {:espex, call, _server} -> espex_calls([call | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "advertisement" do
    test "mesh entities follow the static ones, each on its sub-device" do
      {sources, _put} = start_inputs()
      pid = start_provider(sources)

      ads = GenServer.call(pid, :list_entities)
      static = EP.advertisements(EP.specs(), true)

      assert Enum.take(ads, length(static)) == static
      mesh = Enum.drop(ads, length(static))
      assert length(mesh) == 7
      assert Enum.all?(mesh, &(&1.device_id in [1, 2, 3]))

      assert %Proto.ListEntitiesLightResponse{device_id: 3, name: "Light"} =
               Enum.find(mesh, &(&1.object_id == "tuya_group_1_light"))
    end

    test "the sub-devices are served for the Espex start" do
      {sources, _put} = start_inputs()
      pid = start_provider(sources)

      assert {:ok, [%Device{id: 1, name: "path light 2"}, %Device{id: 2}, %Device{id: 3}]} =
               EP.mesh_devices(pid)

      assert EP.mesh_devices(:"not_running_#{System.unique_integer([:positive])}") == :error
    end

    test "initial states carry connectivity and last seen from the latest status" do
      seen = ~U[2026-11-02 10:00:00Z]

      {sources, _put} =
        start_inputs(%{
          status: %{bulbs: [%{mac: @mac1, reachable: true, last_seen: seen}]}
        })

      pid = start_provider(sources)
      key = Entities.key_for("tuya_dc23530fb34a_connectivity")

      states = GenServer.call(pid, :initial_states)

      assert %Proto.BinarySensorStateResponse{state: true, device_id: 1} =
               Enum.find(states, &(&1.key == key))

      send(pid, {:tuya_mesh_status, %{bulbs: [%{mac: @mac1, reachable: false, last_seen: seen}]}})

      states = GenServer.call(pid, :initial_states)

      assert %Proto.BinarySensorStateResponse{state: false} =
               Enum.find(states, &(&1.key == key))
    end

    test "connectivity and last seen are pushed live, with device_id, only on change" do
      {sources, _put} = start_inputs()
      pid = start_provider(sources)
      seen = ~U[2026-11-02 10:00:00Z]
      status = %{bulbs: [%{mac: @mac1, reachable: true, last_seen: seen}]}

      send(pid, {:tuya_mesh_status, status})
      conn = Entities.key_for("tuya_dc23530fb34a_connectivity")
      last = Entities.key_for("tuya_dc23530fb34a_last_seen")

      assert_receive {:mesh_push,
                      %Proto.BinarySensorStateResponse{key: ^conn, device_id: 1, state: true}}

      assert_receive {:mesh_push,
                      %Proto.TextSensorStateResponse{
                        key: ^last,
                        device_id: 1,
                        state: "2026-11-02T10:00:00+00:00",
                        missing_state: false
                      }}

      send(pid, {:tuya_mesh_status, status})
      _ = :sys.get_state(pid)
      refute_received {:mesh_push, _}
    end

    test "last seen stays hidden until the clock has synchronised" do
      {sources, put} = start_inputs(%{synced: false})
      pid = start_provider(sources)
      seen = ~U[2026-11-02 10:00:00Z]
      last = Entities.key_for("tuya_dc23530fb34a_last_seen")

      send(pid, {:tuya_mesh_status, %{bulbs: [%{mac: @mac1, reachable: true, last_seen: seen}]}})

      assert_receive {:mesh_push,
                      %Proto.TextSensorStateResponse{key: ^last, missing_state: true, state: ""}}

      assert %Proto.TextSensorStateResponse{missing_state: true} =
               Enum.find(GenServer.call(pid, :initial_states), &(&1.key == last))

      # Synchronised: the next check tick shows it.
      put.(:synced, true)
      send(pid, :mesh_check)

      assert_receive {:mesh_push,
                      %Proto.TextSensorStateResponse{key: ^last, missing_state: false}}
    end

    test "a status built before the sync never shows its 1970 date" do
      {sources, put} = start_inputs(%{synced: false})
      pid = start_provider(sources)
      last = Entities.key_for("tuya_dc23530fb34a_last_seen")
      heard = System.monotonic_time(:millisecond)

      # Built before the sync: the wall clock it used said 1970.
      status = %{
        bulbs: [
          %{mac: @mac1, reachable: true, last_seen: ~U[1970-01-01 00:00:05Z], last_seen_ms: heard}
        ]
      }

      send(pid, {:tuya_mesh_status, status})
      assert_receive {:mesh_push, %Proto.TextSensorStateResponse{key: ^last, missing_state: true}}

      # The clock syncs; no new status arrives before the check tick.
      put.(:synced, true)
      send(pid, :mesh_check)

      assert_receive {:mesh_push,
                      %Proto.TextSensorStateResponse{
                        key: ^last,
                        missing_state: false,
                        state: shown
                      }}

      refute shown =~ "1970"
      assert shown =~ "#{Date.utc_today().year}"
    end

    test "a catch-up after a PubSub outage pushes what changed meanwhile" do
      pubsub = :"ep_mesh_catchup_pubsub_#{System.unique_integer([:positive])}"

      {sources, put} =
        start_inputs(%{status: %{bulbs: [%{mac: @mac1, reachable: true, last_seen: nil}]}})

      pid = start_provider(sources, subscribe: true, pubsub: pubsub)
      conn = Entities.key_for("tuya_dc23530fb34a_connectivity")

      # Unreachable while nothing was subscribed.
      put.(:status, %{bulbs: [%{mac: @mac1, reachable: false, last_seen: nil}]})
      start_supervised!({Phoenix.PubSub, name: pubsub})
      fire(pid, :resubscribe)

      assert_receive {:mesh_push,
                      %Proto.BinarySensorStateResponse{key: ^conn, device_id: 1, state: false}}
    end

    test "no live push for a bulb whose sub-device changed" do
      {sources, _put} = start_inputs(%{ids: %{{:bulb, @mac1} => 99, {:bulb, @mac2} => 2}})
      pid = start_provider(sources)

      send(pid, {:tuya_mesh_status, %{bulbs: [%{mac: @mac1, reachable: true, last_seen: nil}]}})
      _ = :sys.get_state(pid)
      refute_received {:mesh_push, _}
    end

    test "initial states carry the Commander's light states for current light entities" do
      light = Entities.key_for("tuya_dc23530fb34a_light")
      current = %Proto.LightStateResponse{key: light, device_id: 1, state: true}

      {sources, _put} =
        start_inputs(%{
          light_states: [
            current,
            %Proto.LightStateResponse{key: light, device_id: 99, state: true},
            %Proto.LightStateResponse{key: 12_345, device_id: 1, state: true}
          ]
        })

      pid = start_provider(sources)
      lights = for %Proto.LightStateResponse{} = r <- GenServer.call(pid, :initial_states), do: r
      assert lights == [current]
    end

    test "no Bluetooth: no mesh entities, nothing read" do
      sources = [mesh_inventory: fn -> raise "must not be read" end]
      pid = start_provider(sources, supported?: false)

      assert GenServer.call(pid, :list_entities) == EP.advertisements(EP.specs(), false)
      assert EP.mesh_devices(pid) == {:ok, []}
    end

    test "an unreadable Store at start is unknown, never an empty mesh" do
      {sources, _put} = start_inputs(%{inventory: {:error, :unavailable}})

      capture_log(fn ->
        pid = start_provider(sources)
        # Espex keeps its boot devices; HA's connection is refused.
        assert EP.mesh_devices(pid) == {:error, :unknown}
        assert GenServer.call(pid, :list_entities) == :defer
      end)
    end

    test "after the defer window an unknown mesh stops locking HA out" do
      {sources, _put} = start_inputs(%{inventory: {:error, :unavailable}})

      capture_log(fn ->
        pid = start_provider(sources, mesh_defer_ms: 0)
        assert GenServer.call(pid, :list_entities) == EP.advertisements(EP.specs(), true)
        assert EP.mesh_devices(pid) == {:error, :unknown}
      end)
    end

    test "unknown at start falls back to the last good build of this boot" do
      server = :"ep_mesh_lastgood_#{System.unique_integer([:positive])}"
      {sources, put} = start_inputs()
      first = start_provider(sources, server: server)
      {:ok, devices} = EP.mesh_devices(first)
      ads = GenServer.call(first, :list_entities)
      stop_supervised!(EP)

      put.(:inventory, {:error, :unavailable})

      capture_log(fn ->
        second = start_provider(sources, server: server)
        assert EP.mesh_devices(second) == {:ok, devices}
        assert GenServer.call(second, :list_entities) == ads
      end)

      # And for the Espex start, before any provider runs.
      unknown = %{
        supported?: true,
        role: fn -> {:ok, @role} end,
        inventory: fn -> {:error, :unavailable} end,
        settings: fn -> Store.default_settings() end
      }

      assert MeshSync.boot_devices(server, unknown) == devices
      assert MeshSync.boot_devices(:"never_#{System.unique_integer([:positive])}", unknown) == []
    end
  end

  describe "commands" do
    test "a mesh light command goes to the Commander with its device id and settings" do
      {sources, _put} = start_inputs()
      test = self()
      pid = start_provider(sources, mesh_command: &send(test, {:routed, &1}))

      bulb = %Proto.LightCommandRequest{
        key: Entities.key_for("tuya_dc23530fb34a_light"),
        has_state: true,
        state: true
      }

      group = %Proto.LightCommandRequest{key: Entities.key_for("tuya_group_1_light")}
      GenServer.cast(pid, {:command, bulb})
      GenServer.cast(pid, {:command, group})

      assert_receive {:routed, %{target: {:bulb, @mac1}, device_id: 1, request: ^bulb} = cmd}
      assert cmd.key == bulb.key
      assert cmd.settings == Store.default_settings()
      assert_receive {:routed, %{target: {:group, 1}, device_id: 3, request: ^group}}
    end

    test "a request naming another sub-device than the current entity's is dropped" do
      {sources, _put} = start_inputs()
      test = self()
      pid = start_provider(sources, mesh_command: &send(test, {:routed, &1}))
      key = Entities.key_for("tuya_group_1_light")

      # 3 is the group's current sub-device; 9 an old mesh's.
      GenServer.cast(pid, {:command, %Proto.LightCommandRequest{key: key, device_id: 3}})
      assert_receive {:routed, %{target: {:group, 1}, device_id: 3}}

      GenServer.cast(pid, {:command, %Proto.LightCommandRequest{key: key, device_id: 9}})
      _ = :sys.get_state(pid)
      refute_received {:routed, _}
    end

    test "unknown keys and non-light mesh entities are not routed" do
      {sources, _put} = start_inputs()
      test = self()
      pid = start_provider(sources, mesh_command: &send(test, {:routed, &1}))
      before = :sys.get_state(pid)

      for key <- [123, Entities.key_for("tuya_dc23530fb34a_connectivity")] do
        GenServer.cast(pid, {:command, %Proto.LightCommandRequest{key: key, has_state: true}})
      end

      assert :sys.get_state(pid) == before
      refute_received {:routed, _}
    end

    test "routing never waits on the Commander" do
      {sources, _put} = start_inputs()
      # Unsubscribed: other tests' Store broadcasts would land in its mailbox.
      commander =
        start_supervised!({UniversalProxy.TuyaMesh.Commander, name: nil, subscribe: false})

      :ok = :sys.suspend(commander)

      pid =
        start_provider(sources,
          mesh_command: &UniversalProxy.TuyaMesh.Commander.command(&1, commander)
        )

      key = Entities.key_for("tuya_dc23530fb34a_light")
      GenServer.cast(pid, {:command, %Proto.LightCommandRequest{key: key, has_state: true}})

      # The provider keeps serving while the Commander can't take anything.
      assert {:ok, _devices} = EP.mesh_devices(pid)

      assert {:messages, [{:"$gen_cast", {:command, %{target: {:bulb, @mac1}}}}]} =
               Process.info(commander, :messages)
    end

    test "an unencrypted mesh light command is not refused as privileged" do
      key = Entities.key_for("tuya_dc23530fb34a_light")
      cmd = %Proto.LightCommandRequest{key: key}

      log = capture_log(fn -> assert EP.handle_command(cmd, %{encrypted?: false}) == :ok end)
      refute log =~ "refusing"
    end

    test "an unexpected cast doesn't crash the provider" do
      {sources, _put} = start_inputs()
      pid = start_provider(sources)

      GenServer.cast(pid, :something_else)
      GenServer.cast(pid, {:not_a_command, 1, 2})
      assert {:ok, _} = EP.mesh_devices(pid)
      assert Process.alive?(pid)
    end
  end

  describe "reconnect on change" do
    test "an inventory change updates the device config then disconnects, exactly once" do
      {sources, put} = start_inputs()
      pid = start_provider(sources)
      server = :sys.get_state(pid).server

      put.(
        :inventory,
        {:ok, summary(%{groups: [], device_ids: Map.delete(summary().device_ids, {:group, 1})})}
      )

      # A burst of notifications is one sync.
      for _ <- 1..3, do: send(pid, {:tuya_mesh_store, :inventory_changed})
      settle(pid)

      assert_received {:espex, :update_device_config, ^server, [devices: devices]}
      assert Enum.map(devices, & &1.id) == [1, 2]
      assert_received {:espex, :disconnect_clients, ^server}
      assert espex_calls() == []

      # The new set is what the next connection reads.
      ads = GenServer.call(pid, :list_entities)
      refute Enum.any?(ads, &(&1.object_id == "tuya_group_1_light"))
      assert EP.mesh_devices(pid) == {:ok, devices}
    end

    test "the device config is updated before the disconnect" do
      {sources, put} = start_inputs()
      pid = start_provider(sources)

      put.(:inventory, {:ok, summary(%{bulbs: [%{mac: @mac1, label: "x"}]})})
      send(pid, {:tuya_mesh_store, :inventory_changed})
      settle(pid)

      assert espex_calls() == [:update_device_config, :disconnect_clients]
    end

    test "nothing happens when the entities and sub-devices didn't change" do
      {sources, put} = start_inputs()
      pid = start_provider(sources)

      # Same summary (a seq-only or no-op change), and live-only changes.
      send(pid, {:tuya_mesh_store, :inventory_changed})
      send(pid, {:bluetooth_state, %{}})
      send(pid, {:tuya_mesh_status, %{bulbs: [%{mac: @mac1, reachable: true, last_seen: nil}]}})
      settle(pid)
      assert espex_calls() == []

      # A group member change doesn't show in the summary either.
      put.(:status, %{bulbs: []})
      send(pid, {:tuya_mesh_store, :inventory_changed})
      settle(pid)
      assert espex_calls() == []
    end

    test "a label rename reconnects (sub-device names are static info)" do
      {sources, put} = start_inputs()
      pid = start_provider(sources)

      put.(
        :inventory,
        {:ok,
         summary(%{bulbs: [%{mac: @mac1, label: "renamed"}, %{mac: @mac2, label: "post spot 1"}]})}
      )

      send(pid, {:tuya_mesh_store, :inventory_changed})
      settle(pid)

      assert_received {:espex, :update_device_config, _,
                       [devices: [%Device{id: 1, name: "renamed"} | _]]}

      assert_received {:espex, :disconnect_clients, _}
    end

    test "a settings change reconnects (mireds are static info)" do
      {sources, put} = start_inputs()
      pid = start_provider(sources)

      put.(:settings, %{Store.default_settings() | max_mireds: 400})
      send(pid, {:tuya_mesh_store, :settings_changed})
      settle(pid)

      assert espex_calls() == [:update_device_config, :disconnect_clients]

      assert %{max_mireds: 400.0} =
               pid
               |> GenServer.call(:list_entities)
               |> Enum.find(&(&1.object_id == "tuya_group_1_light"))
    end

    test "removing the mesh role removes every mesh sub-device" do
      {sources, put} = start_inputs()
      pid = start_provider(sources)

      put.(:role, {:ok, nil})
      send(pid, {:bluetooth_state, %{}})
      settle(pid)

      assert_received {:espex, :update_device_config, _, [devices: []]}
      assert_received {:espex, :disconnect_clients, _}
      assert GenServer.call(pid, :list_entities) == EP.advertisements(EP.specs(), true)
    end

    test "unreadable inputs keep the current set (no deletion in HA)" do
      {sources, put} = start_inputs()
      pid = start_provider(sources)

      for {key, value} <- [
            inventory: {:error, :unavailable},
            inventory: {:error, :invalid_inventory},
            role: {:error, :unavailable}
          ] do
        put.(:inventory, {:ok, summary()})
        put.(:role, {:ok, @role})
        put.(key, value)
        send(pid, {:tuya_mesh_store, :inventory_changed})
        settle(pid)
        assert espex_calls() == []
        assert {:ok, [_, _, _]} = EP.mesh_devices(pid)
      end
    end

    test "Espex being down neither crashes the provider nor disconnects" do
      {sources, put} = start_inputs()
      test = self()

      pid =
        start_provider(sources,
          update_device_config: fn _server, _opts -> exit({:noproc, :test}) end,
          disconnect_clients: fn _server -> send(test, :disconnected) end
        )

      put.(:inventory, {:ok, summary(%{groups: []})})
      send(pid, {:tuya_mesh_store, :inventory_changed})
      assert %{mesh: %{pending: :update}} = settle(pid)
      assert %{mesh: %{pending: :update}} = fire(pid, :apply)

      refute_received :disconnected
      # Desired all the same, so the next Espex start takes the new sub-devices.
      assert {:ok, [_, _]} = EP.mesh_devices(pid)
    end

    test "subscribes to the Store, status and Bluetooth state topics" do
      pubsub = :"ep_mesh_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub})
      {sources, put} = start_inputs()
      pid = start_provider(sources, subscribe: true, pubsub: pubsub)

      put.(:inventory, {:ok, summary(%{groups: []})})
      Phoenix.PubSub.broadcast(pubsub, Store.topic(), {:tuya_mesh_store, :inventory_changed})
      settle(pid)
      assert espex_calls() == [:update_device_config, :disconnect_clients]

      put.(:role, {:ok, nil})

      Phoenix.PubSub.broadcast(
        pubsub,
        UniversalProxy.Bluetooth.state_topic(),
        {:bluetooth_state, %{}}
      )

      settle(pid)
      assert espex_calls() == [:update_device_config, :disconnect_clients]

      Phoenix.PubSub.broadcast(
        pubsub,
        UniversalProxy.TuyaMesh.topic(),
        {:tuya_mesh_status, %{bulbs: [%{mac: @mac1, reachable: true, last_seen: nil}]}}
      )

      assert %{mesh: %{live: %{@mac1 => %{reachable: true}}}} = settle(pid)
    end
  end

  describe "applying to Espex" do
    test "a failed update is retried with backoff; the reconnect runs once, after it worked" do
      {sources, put} = start_inputs()
      test = self()
      results = start_supervised!({Agent, fn -> [{:error, :not_ready}, :ok] end}, id: :results)

      pid =
        start_provider(sources,
          mesh_retry_ms: 5_000,
          update_device_config: fn _server, opts ->
            send(test, {:espex, :update_device_config, :s, opts})
            Agent.get_and_update(results, fn [r | rest] -> {r, rest ++ [:ok]} end)
          end
        )

      put.(:inventory, {:ok, summary(%{groups: []})})
      send(pid, {:tuya_mesh_store, :inventory_changed})

      assert %{mesh: %{pending: :update, apply_timer: token, apply_backoff_ms: 10_000}} =
               settle(pid)

      assert is_reference(token)
      assert espex_calls() == [:update_device_config]

      # A read that finds nothing new doesn't drop the pending work.
      send(pid, {:tuya_mesh_store, :inventory_changed})
      settle(pid)
      assert espex_calls() == []

      assert %{mesh: %{pending: nil, apply_timer: nil, apply_backoff_ms: 5_000}} =
               fire(pid, :apply)

      assert espex_calls() == [:update_device_config, :disconnect_clients]

      # The stale retry token does nothing.
      send(pid, {:mesh_apply, token})
      settle(pid)
      assert espex_calls() == []
    end

    test "a change while an update is pending applies the latest set" do
      {sources, put} = start_inputs()
      test = self()
      ok? = start_supervised!({Agent, fn -> false end}, id: :ok?)

      pid =
        start_provider(sources,
          update_device_config: fn _server, opts ->
            send(test, {:espex, :update_device_config, :s, opts})
            if Agent.get(ok?, & &1), do: :ok, else: {:error, :not_ready}
          end
        )

      put.(:inventory, {:ok, summary(%{groups: []})})
      send(pid, {:tuya_mesh_store, :inventory_changed})
      settle(pid)
      assert_received {:espex, :update_device_config, _, [devices: [_, _]]}

      Agent.update(ok?, fn _ -> true end)
      put.(:inventory, {:ok, summary(%{bulbs: [%{mac: @mac1, label: "x"}], groups: []})})
      send(pid, {:tuya_mesh_store, :inventory_changed})
      assert %{mesh: %{pending: nil}} = settle(pid)

      assert_received {:espex, :update_device_config, _, [devices: [%Device{name: "x"}]]}
      assert_received {:espex, :disconnect_clients, _}
    end

    test "an Espex holding other sub-devices (restarted on stale ones) gets the desired ones" do
      {sources, _put} = start_inputs()
      held = start_supervised!({Agent, fn -> [%Device{id: 1, name: "stale"}] end}, id: :held)

      pid = start_provider(sources, espex_devices: fn _server -> Agent.get(held, & &1) end)

      send(pid, :mesh_check)
      settle(pid)
      assert_received {:espex, :update_device_config, _, [devices: [_, _, _] = desired]}
      assert_received {:espex, :disconnect_clients, _}

      # Once Espex holds them, the check is quiet.
      Agent.update(held, fn _ -> desired end)
      send(pid, :mesh_check)
      settle(pid)
      assert espex_calls() == []
    end

    test "the check is quiet while Espex is down (its start takes mesh_devices/0)" do
      {sources, _put} = start_inputs()
      pid = start_provider(sources)
      send(pid, :mesh_check)
      settle(pid)
      assert espex_calls() == []
    end
  end

  describe "unknown inputs" do
    test "an unreadable Store at start is retried, and its recovery is synced" do
      {sources, put} = start_inputs(%{inventory: {:error, :unavailable}})
      pid = start_provider(sources, mesh_retry_ms: 5_000)

      assert %{mesh: %{read_timer: token, read_backoff_ms: 10_000}} = :sys.get_state(pid)
      assert is_reference(token)
      assert EP.mesh_devices(pid) == {:error, :unknown}
      assert GenServer.call(pid, :list_entities) == :defer

      # Still down: retried again, backing off.
      assert %{mesh: %{read_timer: token2, read_backoff_ms: 20_000}} = settle(pid)
      assert is_reference(token2)
      assert espex_calls() == []

      put.(:inventory, {:ok, summary()})
      assert %{mesh: %{read_timer: nil, read_backoff_ms: 5_000}} = settle(pid)
      assert {:ok, [_, _, _]} = EP.mesh_devices(pid)

      assert Enum.any?(
               GenServer.call(pid, :list_entities),
               &(&1.object_id == "tuya_group_1_light")
             )

      assert espex_calls() == [:update_device_config, :disconnect_clients]
    end

    test "unknown at start never pushes to an Espex that holds the mesh; recovery syncs" do
      {sources, put} = start_inputs(%{inventory: {:error, :unavailable}})
      boot = [%Device{id: 1, name: "path light 2"}, %Device{id: 2, name: "post spot 1"}]

      pid =
        start_provider(sources,
          mesh_retry_ms: 5_000,
          espex_devices: fn _server -> boot end
        )

      # The periodic check, the read retry and any apply retry: none of them
      # may move Espex off its boot devices or disconnect HA.
      send(pid, :mesh_check)
      settle(pid)
      fire(pid, :apply)
      send(pid, :mesh_check)
      assert %{mesh: %{source: :none, pending: nil}} = settle(pid)
      assert espex_calls() == []
      assert EP.mesh_devices(pid) == {:error, :unknown}

      # The check keeps a read retry armed.
      assert %{mesh: %{read_timer: token}} = :sys.get_state(pid)
      assert is_reference(token)

      put.(:inventory, {:ok, summary()})
      assert %{mesh: %{source: :read}} = settle(pid)
      assert_received {:espex, :update_device_config, _, [devices: [_, _, _]]}
      assert_received {:espex, :disconnect_clients, _}
    end

    test "the boot-time read is the last good build a provider with unknown inputs adopts" do
      server = :"ep_mesh_boot_#{System.unique_integer([:positive])}"
      {sources, put} = start_inputs()

      good = %{
        supported?: true,
        role: fn -> {:ok, @role} end,
        inventory: fn -> {:ok, summary()} end,
        settings: fn -> Store.default_settings() end
      }

      boot = MeshSync.boot_devices(server, good)
      assert length(boot) == 3

      put.(:inventory, {:error, :unavailable})
      pid = start_provider(sources, server: server, espex_devices: fn _ -> boot end)

      assert EP.mesh_devices(pid) == {:ok, boot}

      assert Enum.any?(
               GenServer.call(pid, :list_entities),
               &(&1.object_id == "tuya_group_1_light")
             )

      send(pid, :mesh_check)
      settle(pid)
      assert espex_calls() == []
    end

    test "an outage after a change notification is retried until it reads" do
      {sources, put} = start_inputs()
      pid = start_provider(sources)

      put.(:inventory, {:error, :unavailable})
      send(pid, {:tuya_mesh_store, :inventory_changed})
      assert %{mesh: %{read_timer: token}} = settle(pid)
      assert is_reference(token)

      put.(:inventory, {:ok, summary(%{groups: []})})
      settle(pid)
      assert_received {:espex, :update_device_config, _, [devices: [_, _]]}
      assert_received {:espex, :disconnect_clients, _}
    end
  end

  describe "subscriptions" do
    defp held_topics(pubsub, pid), do: Registry.keys(pubsub, pid) |> Enum.sort()

    defp mesh_topics,
      do:
        Enum.sort([
          Store.topic(),
          UniversalProxy.TuyaMesh.topic(),
          UniversalProxy.Bluetooth.state_topic()
        ])

    test "a PubSub down at start is retried; the subscription catches up" do
      pubsub = :"ep_mesh_late_pubsub_#{System.unique_integer([:positive])}"
      {sources, put} = start_inputs()
      pid = start_provider(sources, subscribe: true, pubsub: pubsub)

      assert %{mesh: %{sub_timer: token}} = :sys.get_state(pid)
      assert is_reference(token)

      start_supervised!({Phoenix.PubSub, name: pubsub})
      put.(:inventory, {:ok, summary(%{groups: []})})

      fire(pid, :resubscribe)
      assert held_topics(pubsub, pid) == mesh_topics()

      # The catch-up read finds what was missed meanwhile.
      settle(pid)
      assert espex_calls() == [:update_device_config, :disconnect_clients]
    end

    test "a PubSub restart resubscribes once and catches up; checks never double up" do
      pubsub = :"ep_mesh_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub}, id: :pubsub)
      {sources, put} = start_inputs()
      pid = start_provider(sources, subscribe: true, pubsub: pubsub)
      assert held_topics(pubsub, pid) == mesh_topics()

      stop_supervised!(:pubsub)
      # The monitor fires and the resubscribe fails: retried on a timer.
      assert %{mesh: %{sub_timer: token, pubsub_mon: nil}} = :sys.get_state(pid)
      assert is_reference(token)

      start_supervised!({Phoenix.PubSub, name: pubsub}, id: :pubsub)
      put.(:inventory, {:ok, summary(%{groups: []})})
      fire(pid, :resubscribe)
      assert held_topics(pubsub, pid) == mesh_topics()
      settle(pid)
      assert espex_calls() == [:update_device_config, :disconnect_clients]

      for _ <- 1..2, do: send(pid, :mesh_check)
      assert %{mesh: %{read_timer: nil}} = :sys.get_state(pid)
      assert held_topics(pubsub, pid) == mesh_topics()

      # Monitored again: a second restart is noticed too.
      assert %{mesh: %{pubsub_mon: {_pid, _mon}}} = :sys.get_state(pid)
    end

    test "extra topics (the firmware-progress one) are held and re-held the same way" do
      pubsub = :"ep_mesh_extra_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub})
      {sources, _put} = start_inputs()

      mesh =
        [
          enabled?: true,
          pubsub: pubsub,
          extra_topics: ["firmware_update"],
          sources: Map.new(sources),
          check_ms: 60_000,
          espex_devices: fn _ -> exit(:noproc) end
        ]
        |> UniversalProxy.ESPHome.EntityProvider.MeshSync.new()
        |> UniversalProxy.ESPHome.EntityProvider.MeshSync.start()

      assert "firmware_update" in Registry.keys(pubsub, self())

      assert {:ok, _} =
               UniversalProxy.ESPHome.EntityProvider.MeshSync.handle_info(:mesh_check, mesh)

      assert Enum.count(Registry.keys(pubsub, self()), &(&1 == "firmware_update")) == 1
    end
  end
end
