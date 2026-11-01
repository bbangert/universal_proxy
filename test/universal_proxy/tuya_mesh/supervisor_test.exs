defmodule UniversalProxy.TuyaMesh.SupervisorTest do
  # FakeBluez and the Radio/Lights names are global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias UniversalProxy.TuyaBeaconMesh.{Carrier, Dp, FakeBluez, Inventory, Lights, P2, Radio}
  alias UniversalProxy.TuyaMesh.{Mesh, Resolver, Store}

  @moduletag :tmp_dir
  @moduletag :capture_log

  @fixture Path.join([
             __DIR__,
             "..",
             "..",
             "fixtures",
             "tuya_beacon_mesh",
             "example_inventory.json"
           ])

  @beacon_key "00112233445566778899aabbccddeeff"
  @mesh_mac "AA:BB:CC:DD:EE:01"
  @proxy_mac "AA:BB:CC:DD:EE:02"
  @mac2 0xDC23530FB34A

  setup %{tmp_dir: tmp_dir} do
    n = System.unique_integer([:positive])

    store =
      start_supervised!(
        {Store,
         name: nil,
         enabled: true,
         table: :"tuya_sup_#{n}",
         dets_path: Path.join(tmp_dir, "m.dets")}
      )

    pubsub = :"tuya_pubsub_#{n}"
    start_supervised!({Phoenix.PubSub, name: pubsub})
    Phoenix.PubSub.subscribe(pubsub, Resolver.topic())

    adapters =
      start_supervised!({Agent, fn -> [adapter(@mesh_mac, 1), adapter(@proxy_mac, 0)] end})

    names = %{
      sup: :"tuya_sup_#{n}",
      dynsup: :"tuya_dynsup_#{n}",
      resolver: :"tuya_resolver_#{n}"
    }

    {:ok, store: store, pubsub: pubsub, adapters: adapters, names: names}
  end

  defp adapter(mac, index),
    do: %{path: "/org/bluez/hci#{index}", address: mac, name: nil, powered: true}

  defp set_adapters(ctx, list), do: Agent.update(ctx.adapters, fn _ -> list end)

  defp inventory, do: @fixture |> File.read!() |> Inventory.decode!()

  # A stand-in mesh: an Agent holding the index it was started for.
  defp fake_mesh(index) do
    %{id: :mesh, start: {Agent, :start_link, [fn -> index end]}, restart: :temporary}
  end

  defp start_mesh_sup(ctx, opts \\ []) do
    adapters = ctx.adapters

    defaults = [
      name: ctx.names.sup,
      dynsup: ctx.names.dynsup,
      resolver: ctx.names.resolver,
      tuya_adapter: @mesh_mac,
      store: ctx.store,
      pubsub: ctx.pubsub,
      adapters_fun: fn -> Agent.get(adapters, & &1) end,
      mesh_spec_fun: &fake_mesh/1,
      radio: :"no_radio_#{System.unique_integer([:positive])}",
      lights: :"no_lights_#{System.unique_integer([:positive])}",
      retry_ms: 20,
      restart_ms: 20,
      tick_ms: 20
    ]

    sup = start_supervised!({UniversalProxy.TuyaMesh.Supervisor, Keyword.merge(defaults, opts)})
    # The first evaluation runs in handle_continue: a call returns after it.
    _ = Resolver.status(ctx.names.resolver)
    sup
  end

  defp status(ctx), do: Resolver.status(ctx.names.resolver)

  defp mesh_index(ctx) do
    case DynamicSupervisor.which_children(ctx.names.dynsup) do
      [{_, pid, _, _}] when is_pid(pid) -> Agent.get(pid, & &1)
      [] -> nil
    end
  end

  defp mesh_pid(ctx) do
    case DynamicSupervisor.which_children(ctx.names.dynsup) do
      [{_, pid, _, _}] -> pid
      [] -> nil
    end
  end

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) > deadline -> flunk("condition not met in time")
      true -> Process.sleep(10) && do_wait(fun, deadline)
    end
  end

  describe "start conditions" do
    test "no role: idle, nothing started, no retry", ctx do
      {:ok, _} = Store.replace(inventory(), [], ctx.store)
      start_mesh_sup(ctx, tuya_adapter: nil)

      assert %{state: :idle, reason: :no_role, role_mac: nil} = status(ctx)
      Process.sleep(60)
      assert mesh_pid(ctx) == nil
    end

    test "no inventory: idle until an upload, then started", ctx do
      start_mesh_sup(ctx)
      assert %{state: :idle, reason: :no_inventory, bulbs: []} = status(ctx)
      assert_receive {:tuya_mesh_status, %{reason: :no_inventory}}
      assert mesh_pid(ctx) == nil

      assert {:ok, :new_mesh} = Resolver.replace(inventory(), [], ctx.names.resolver)
      assert mesh_index(ctx) == 1
      assert %{state: :running, reason: nil, adapter_index: 1, role_mac: @mesh_mac} = status(ctx)
      assert_receive {:tuya_mesh_status, %{state: :running, bulbs: [_, _]}}
    end

    test "an adapter that hasn't appeared yet is retried", ctx do
      {:ok, _} = Store.replace(inventory(), [], ctx.store)
      set_adapters(ctx, [adapter(@proxy_mac, 0)])
      start_mesh_sup(ctx)

      assert %{state: :idle, reason: :adapter_missing} = status(ctx)

      set_adapters(ctx, [adapter(@proxy_mac, 0), adapter(@mesh_mac, 4)])
      wait_until(fn -> mesh_index(ctx) == 4 end)
      assert %{state: :running, adapter_index: 4} = status(ctx)
    end

    test "the mesh MAC alone (no other radio) stays idle, and starts once another appears", ctx do
      {:ok, _} = Store.replace(inventory(), [], ctx.store)
      # Case differs from the role MAC: matching ignores it.
      set_adapters(ctx, [adapter(String.downcase(@mesh_mac), 0)])
      start_mesh_sup(ctx)

      assert %{state: :idle, reason: :lone_radio} = status(ctx)
      Process.sleep(60)
      assert mesh_pid(ctx) == nil

      set_adapters(ctx, [adapter(@mesh_mac, 0), adapter(@proxy_mac, 1)])
      wait_until(fn -> mesh_index(ctx) == 0 end)
    end

    test "all conditions met: started on the resolved index", ctx do
      {:ok, _} = Store.replace(inventory(), [], ctx.store)
      start_mesh_sup(ctx)

      assert mesh_index(ctx) == 1
      assert %{state: :running, adapter_index: 1, bulbs: bulbs, groups: [group]} = status(ctx)
      assert [%{label: "path light 2", reachable: false, last_seen: nil}, _] = bulbs
      assert group.name == "path and post"
    end

    test "an invalid stored inventory leaves it idle", ctx do
      {:ok, _} = Store.replace(inventory(), [], ctx.store)
      :ok = :dets.insert(:sys.get_state(ctx.store).table, {:inventory, %{"bulbs" => []}})
      start_mesh_sup(ctx)
      assert %{state: :idle, reason: :invalid_inventory} = status(ctx)
    end
  end

  describe "lifecycle" do
    setup ctx do
      {:ok, _} = Store.replace(inventory(), [], ctx.store)
      start_mesh_sup(ctx)
      assert mesh_index(ctx) == 1
      :ok
    end

    test "a mesh that stops on its own is restarted later", ctx do
      pid = mesh_pid(ctx)

      log =
        capture_log(fn ->
          Agent.stop(pid, :boom)
          wait_until(fn -> mesh_pid(ctx) not in [nil, pid] end)
        end)

      assert log =~ "mesh stopped on its own"
      assert %{state: :running} = status(ctx)
    end

    test "replace and clear stop the mesh around the change", ctx do
      pid = mesh_pid(ctx)
      ref = Process.monitor(pid)

      assert {:ok, :same_mesh} = Resolver.replace(inventory(), [], ctx.names.resolver)
      assert_received {:DOWN, ^ref, :process, ^pid, _}
      new_pid = mesh_pid(ctx)
      assert is_pid(new_pid) and new_pid != pid

      assert :ok = Resolver.clear(ctx.names.resolver)
      assert mesh_pid(ctx) == nil
      assert %{state: :idle, reason: :no_inventory, bulbs: []} = status(ctx)
      assert Store.load(ctx.store) == {:error, :no_inventory}
    end

    test "a dongle that comes back under another index moves the mesh", ctx do
      set_adapters(ctx, [adapter(@proxy_mac, 0), adapter(@mesh_mac, 7)])
      wait_until(fn -> mesh_index(ctx) == 7 end)
    end

    test "a missing adapter while running is left to the Radio", ctx do
      pid = mesh_pid(ctx)
      set_adapters(ctx, [adapter(@proxy_mac, 0)])
      Process.sleep(200)
      assert mesh_pid(ctx) == pid
    end
  end

  describe "with the real mesh (FakeBluez)" do
    setup ctx do
      FakeBluez.ensure_started()
      FakeBluez.reset()
      {:ok, _} = Store.replace(inventory(), [], ctx.store)
      store = ctx.store

      spec = fn index ->
        Mesh.child_spec(
          adapter_index: index,
          radio: [
            bluez_radio: FakeBluez.Radio,
            mgmt: FakeBluez.Mgmt,
            rebus: FakeBluez.Rebus,
            dbus: FakeBluez.DBus,
            receiver: FakeBluez.Receiver,
            retry_ms: 20
          ],
          lights: [inventory: fn -> Store.load(store) end, on_persist: &Store.persist(&1, store)]
        )
      end

      start_mesh_sup(ctx, mesh_spec_fun: spec, radio: Radio, lights: Lights, tick_ms: 50)
      wait_until(fn -> match?(%{radio: %{ready: true}, lights_running: true}, status(ctx)) end)
      :ok
    end

    test "Radio on the resolved adapter, powered; Lights persists through the Store", ctx do
      assert {:ok, %{adapter_index: 1, ready: true}} = Radio.status()
      assert {:dbus_path, "/org/bluez/hci1", "Set"} in FakeBluez.calls()

      assert :ok = Lights.set("path light 2", on: true)
      assert {:ok, %Inventory{seq: 132}} = Store.load(ctx.store)

      # A crashed Lights resumes from the stored cursor, never behind it.
      lights = Process.whereis(Lights)
      Process.exit(lights, :kill)
      wait_until(fn -> Process.whereis(Lights) not in [nil, lights] end)
      assert {:ok, %Inventory{seq: 132}} = Lights.inventory()
    end

    test "bulb reports update the status and are broadcast", ctx do
      assert %{bulbs: [%{reachable: false} | _]} = status(ctx)
      inject_report(2, 5, [{1, :bool, true}])

      assert_receive {:tuya_mesh_status,
                      %{bulbs: [%{label: "path light 2", reachable: true} = bulb, _]}},
                     2_000

      assert %DateTime{} = bulb.last_seen
    end

    test "an upload restarts Radio and Lights on the new inventory", ctx do
      radio = Process.whereis(Radio)
      new = inventory() |> Map.put(:seq, 1_000)
      assert {:ok, :same_mesh} = Resolver.replace(new, [], ctx.names.resolver)
      wait_until(fn -> match?(%{radio: %{ready: true}, lights_running: true}, status(ctx)) end)
      assert Process.whereis(Radio) != radio
      assert {:ok, %Inventory{seq: 1_000}} = Lights.inventory()
    end
  end

  defp inject_report(node, sn, dps) do
    {:ok, payload} = Dp.encode(dps)
    frame = P2.build(1, 7, node, 0x8001, sn, payload, @beacon_key, @beacon_key)
    FakeBluez.inject(%{address: @mac2, data: Carrier.ad_bytes(frame), rssi: -40})
  end
end
