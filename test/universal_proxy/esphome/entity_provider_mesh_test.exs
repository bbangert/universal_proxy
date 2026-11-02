defmodule UniversalProxy.ESPHome.EntityProviderMeshTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Espex.DeviceConfig.Device
  alias Espex.Proto
  alias UniversalProxy.ESPHome.EntityProvider, as: EP
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
               status: %{bulbs: []}
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
      mesh_status: get.(:status)
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
      mesh_debounce_ms: 10,
      sources: sources,
      update_device_config: fn server, opts ->
        send(test, {:espex, :update_device_config, server, opts})
        :ok
      end,
      disconnect_clients: fn server ->
        send(test, {:espex, :disconnect_clients, server})
        :ok
      end
    ]

    start_supervised!({EP, Keyword.merge(defaults, opts)})
  end

  # The triggers sent before this are handled once :sys.get_state/1 returns
  # (which arms the debounce); then wait for the armed sync to have run.
  defp settle(pid, tries \\ 100) do
    case :sys.get_state(pid) do
      %{mesh_timer: nil} = state ->
        state

      _armed when tries > 0 ->
        Process.sleep(5)
        settle(pid, tries - 1)
    end
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

    test "no Bluetooth: no mesh entities, nothing read" do
      sources = [mesh_inventory: fn -> raise "must not be read" end]
      pid = start_provider(sources, supported?: false)

      assert GenServer.call(pid, :list_entities) == EP.advertisements(EP.specs(), false)
      assert EP.mesh_devices(pid) == {:ok, []}
    end

    test "an unreadable Store at start advertises no mesh, without crashing" do
      {sources, _put} = start_inputs(%{inventory: {:error, :unavailable}})
      pid = start_provider(sources)
      assert EP.mesh_devices(pid) == {:ok, []}
    end
  end

  describe "commands" do
    test "a mesh light command is acknowledged and changes nothing" do
      {sources, _put} = start_inputs()
      pid = start_provider(sources)
      before = :sys.get_state(pid)

      key = Entities.key_for("tuya_dc23530fb34a_light")
      GenServer.cast(pid, {:command, %Proto.LightCommandRequest{key: key, has_state: true}})
      GenServer.cast(pid, {:command, %Proto.LightCommandRequest{key: 123, has_state: true}})

      assert :sys.get_state(pid) == before
    end

    test "the light command routes to the mesh target" do
      state = %{keys: %{42 => {:tuya_mesh, {:bulb, @mac1, :light}}}}
      cmd = %Proto.LightCommandRequest{key: 42}
      assert {:noreply, ^state} = EP.handle_cast({:command, cmd}, state)
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
      settle(pid)

      refute_received :disconnected
      # Still switched, so the next Espex start takes the new sub-devices.
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

      assert %{mesh_live: %{@mac1 => %{reachable: true}}} = settle(pid)
    end
  end
end
