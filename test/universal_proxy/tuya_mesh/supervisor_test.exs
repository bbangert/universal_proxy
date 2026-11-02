defmodule UniversalProxy.TuyaMesh.SupervisorTest do
  # FakeBluez and the Radio/Lights names are global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias UniversalProxy.TuyaBeaconMesh.{Carrier, Dp, FakeBluez, Inventory, Lights, P2, Radio}
  alias UniversalProxy.TuyaMesh.{FakeLights, FakeRadio, Mesh, Presence, Resolver, Store}

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
  @bulb2 "DC23530FB34A"
  @bulb3 "DC23533FCD62"

  setup %{tmp_dir: tmp_dir} do
    n = System.unique_integer([:positive])

    pubsub = :"tuya_pubsub_#{n}"
    start_supervised!(pubsub_spec(pubsub))
    Phoenix.PubSub.subscribe(pubsub, Resolver.topic())

    store =
      start_supervised!(
        {Store,
         name: nil,
         enabled: true,
         pubsub: pubsub,
         table: :"tuya_sup_#{n}",
         dets_path: Path.join(tmp_dir, "m.dets")}
      )

    adapters =
      start_supervised!({Agent, fn -> [adapter(@mesh_mac, 1), adapter(@proxy_mac, 0)] end})

    names = %{
      sup: :"tuya_sup_#{n}",
      dynsup: :"tuya_dynsup_#{n}",
      resolver: :"tuya_resolver_#{n}"
    }

    {:ok, store: store, pubsub: pubsub, adapters: adapters, names: names}
  end

  defp pubsub_spec(pubsub), do: Supervisor.child_spec({Phoenix.PubSub, name: pubsub}, id: :pubsub)

  defp adapter(mac, index),
    do: %{path: "/org/bluez/hci#{index}", address: mac, name: nil, powered: true}

  defp set_adapters(ctx, list), do: Agent.update(ctx.adapters, fn _ -> list end)

  defp inventory, do: @fixture |> File.read!() |> Inventory.decode!()

  # A stand-in mesh: an Agent holding the index and MAC it was started for.
  defp fake_mesh(index, mac) do
    %{id: :mesh, start: {Agent, :start_link, [fn -> {index, mac} end]}, restart: :temporary}
  end

  defp adapters_changed(ctx),
    do:
      Phoenix.PubSub.broadcast(
        ctx.pubsub,
        Bluez.Client.adapters_topic(),
        {:bluetooth_adapters_changed}
      )

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
      mesh_spec_fun: &fake_mesh/2,
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
      [{_, pid, _, _}] when is_pid(pid) -> Agent.get(pid, &elem(&1, 0))
      [] -> nil
    end
  end

  # nil also while the subtree restarts (the DynamicSupervisor is down).
  defp mesh_pid(ctx) do
    case DynamicSupervisor.which_children(ctx.names.dynsup) do
      [{_, pid, _, _}] -> pid
      [] -> nil
    end
  catch
    :exit, _ -> nil
  end

  defp safe_keys(pubsub, pid) do
    Registry.keys(pubsub, pid)
  rescue
    ArgumentError -> []
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

    test "all conditions met: started on the resolved index, fenced by the MAC", ctx do
      {:ok, _} = Store.replace(inventory(), [], ctx.store)
      start_mesh_sup(ctx, tuya_adapter: String.downcase(@mesh_mac))

      assert mesh_index(ctx) == 1
      assert Agent.get(mesh_pid(ctx), & &1) == {1, @mesh_mac}
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

    test "a dongle that comes back under another index moves the mesh (poll)", ctx do
      set_adapters(ctx, [adapter(@proxy_mac, 0), adapter(@mesh_mac, 7)])
      wait_until(fn -> mesh_index(ctx) == 7 end)
    end

    test "an empty adapter list (daemon not answering) changes nothing", ctx do
      pid = mesh_pid(ctx)
      set_adapters(ctx, [])
      adapters_changed(ctx)
      Process.sleep(200)
      assert mesh_pid(ctx) == pid
    end

    test "the Resolver stops the mesh before it exits", ctx do
      test_pid = self()
      resolver = ctx.names.resolver
      sup = UniversalProxy.TuyaMesh.Supervisor
      stop_supervised!(sup)

      probe = fn _index, _mac ->
        %{
          id: :mesh,
          start: {GenServer, :start_link, [__MODULE__.ProbeMesh, {test_pid, resolver}]},
          restart: :temporary
        }
      end

      start_mesh_sup(ctx, mesh_spec_fun: probe)
      assert is_pid(mesh_pid(ctx))

      # A stop of the Resolver alone (the start of a :one_for_all restart)...
      GenServer.stop(resolver, :boom)
      assert_receive {:mesh_stopped, resolver_alive?: true}

      # ...and a shutdown of the whole subtree.
      wait_until(fn -> is_pid(mesh_pid(ctx)) end)
      stop_supervised!(sup)
      assert_receive {:mesh_stopped, resolver_alive?: true}
    end
  end

  describe "adapter changes while running" do
    setup ctx do
      {:ok, _} = Store.replace(inventory(), [], ctx.store)
      # No tick in these tests: only the adapter-change event can react.
      start_mesh_sup(ctx, tick_ms: 60_000)
      assert mesh_index(ctx) == 1
      :ok
    end

    test "the mesh adapter leaving stops the mesh at once", ctx do
      set_adapters(ctx, [adapter(@proxy_mac, 0)])
      adapters_changed(ctx)

      wait_until(fn -> mesh_pid(ctx) == nil end, 500)
      assert %{state: :idle, reason: :adapter_missing} = status(ctx)

      # Back (under a new index): restarted there.
      set_adapters(ctx, [adapter(@proxy_mac, 0), adapter(@mesh_mac, 2)])
      adapters_changed(ctx)
      wait_until(fn -> mesh_index(ctx) == 2 end, 500)
    end

    test "another adapter taking the mesh's index never gets the mesh", ctx do
      set_adapters(ctx, [adapter(@proxy_mac, 0), adapter("11:22:33:44:55:66", 1)])
      adapters_changed(ctx)

      wait_until(fn -> mesh_pid(ctx) == nil end, 500)
      Process.sleep(100)
      assert mesh_pid(ctx) == nil
      assert %{state: :idle, reason: :adapter_missing} = status(ctx)
    end
  end

  describe "subscriptions and inventory changes" do
    setup ctx do
      {:ok, _} = Store.replace(inventory(), [], ctx.store)
      # No tick: only events can make the Resolver react.
      start_mesh_sup(ctx, tick_ms: 60_000)
      assert mesh_index(ctx) == 1
      :ok
    end

    test "a PubSub restart doesn't lose the adapter subscription", ctx do
      resolver = Process.whereis(ctx.names.resolver)
      # This process subscribed too (setup), so the registry is linked to it.
      Process.flag(:trap_exit, true)
      stop_supervised!(:pubsub)
      start_supervised!(pubsub_spec(ctx.pubsub))

      wait_until(fn ->
        Bluez.Client.adapters_topic() in safe_keys(ctx.pubsub, resolver) and
          Store.topic() in safe_keys(ctx.pubsub, resolver)
      end)

      # Subscribed once, not twice.
      assert Enum.count(safe_keys(ctx.pubsub, resolver), &(&1 == Store.topic())) == 1

      set_adapters(ctx, [adapter(@proxy_mac, 0)])
      adapters_changed(ctx)
      wait_until(fn -> mesh_pid(ctx) == nil end, 500)
      assert Process.whereis(ctx.names.resolver) == resolver
    end

    test "a group removed while the PubSub was down shows up after recovery", ctx do
      assert %{groups: [%{local_id: 1}]} = status(ctx)
      Process.flag(:trap_exit, true)
      stop_supervised!(:pubsub)

      # The Store's broadcast for this is lost: nothing is listening.
      :ok = Store.persist(%{inventory() | seq: 132, groups: []}, ctx.store)

      start_supervised!(pubsub_spec(ctx.pubsub))
      wait_until(fn -> match?(%{groups: []}, status(ctx)) end)
    end

    test "a load and a whole evaluation leave no key in either :sys status", ctx do
      alias UniversalProxy.TuyaMesh.KeyLeak

      resolver = Process.whereis(ctx.names.resolver)
      :ok = :sys.log(ctx.store, true)
      :ok = :sys.log(resolver, true)

      assert {:ok, %Inventory{}} = Store.load(ctx.store)
      # A group change makes the Resolver re-read; an adapter loss and its
      # return make it stop the mesh and evaluate (and load) again.
      :ok = Store.persist(%{inventory() | seq: 132, groups: []}, ctx.store)
      wait_until(fn -> match?(%{groups: []}, status(ctx)) end)
      set_adapters(ctx, [adapter(@proxy_mac, 0)])
      adapters_changed(ctx)
      wait_until(fn -> mesh_pid(ctx) == nil end)
      set_adapters(ctx, [adapter(@proxy_mac, 0), adapter(@mesh_mac, 1)])
      adapters_changed(ctx)
      wait_until(fn -> mesh_index(ctx) == 1 end)

      KeyLeak.refute_keys(:sys.get_status(ctx.store))
      KeyLeak.refute_keys(:sys.get_status(resolver))
    end

    test "a persisted group removal reaches the status and its broadcast", ctx do
      assert %{groups: [%{local_id: 1}]} = status(ctx)
      Phoenix.PubSub.subscribe(ctx.pubsub, Store.topic())

      # Seq-only: no re-read.
      :ok = Store.persist(%{inventory() | seq: 132}, ctx.store)
      refute_receive {:tuya_mesh_store, _}, 100

      # A Lights persist after a group delete.
      :ok = Store.persist(%{inventory() | seq: 132, groups: []}, ctx.store)
      assert_receive {:tuya_mesh_store, :inventory_changed}
      assert_receive {:tuya_mesh_status, %{groups: [], bulbs: [_, _]}}
      assert %{groups: []} = status(ctx)
    end
  end

  describe "subscription recovery on a tick" do
    setup ctx do
      {:ok, _} = Store.replace(inventory(), [], ctx.store)
      # Every tick re-checks the adapter, so the catch-up and the periodic
      # check land in the same tick.
      start_mesh_sup(ctx, tick_ms: 20, index_check_ticks: 1)
      assert mesh_index(ctx) == 1
      :ok
    end

    test "finding the adapter gone stops the mesh and leaves the Resolver idle", ctx do
      resolver = Process.whereis(ctx.names.resolver)
      Process.flag(:trap_exit, true)

      # No :DOWN path: only a tick may notice the lost subscriptions.
      :sys.replace_state(resolver, &%{&1 | pubsub_mon: nil})

      log =
        capture_log(fn ->
          stop_supervised!(:pubsub)
          # A few ticks fail to resubscribe while it is down.
          Process.sleep(80)

          :ok = :sys.suspend(resolver)
          start_supervised!(pubsub_spec(ctx.pubsub))
          set_adapters(ctx, [adapter(@proxy_mac, 0)])
          :ok = :sys.resume(resolver)

          wait_until(fn -> mesh_pid(ctx) == nil end)
          Process.sleep(100)
        end)

      assert Process.whereis(ctx.names.resolver) == resolver
      assert %{state: :idle, reason: :adapter_missing} = status(ctx)
      refute log =~ "terminating"
      refute log =~ "raised"
    end
  end

  describe "key redaction" do
    @local_keys ["abcdefghijklmnop", "ponmlkjihgfedcba"]

    defp refute_keys(text) do
      raw = Base.decode16!(@beacon_key, case: :lower)

      for secret <- [@beacon_key, String.upcase(@beacon_key) | @local_keys] do
        refute text =~ secret
      end

      refute text =~ raw
      refute text =~ inspect(raw)
      refute text =~ raw |> :binary.bin_to_list() |> Enum.join(", ")
    end

    # Raises a FunctionClauseError whose arguments and top stack frame hold
    # the inventory (as a crash in a key-handling callback would).
    def explode(%{"never" => _}), do: :ok

    test "a crash while handling an upload leaves no key in any report", ctx do
      once = start_supervised!({Agent, fn -> true end}, id: :once)
      inv = inventory()

      spec = fn index, mac ->
        if Agent.get_and_update(once, &{&1, false}),
          do: apply(__MODULE__, :explode, [Inventory.to_map(inv)]),
          else: fake_mesh(index, mac)
      end

      start_mesh_sup(ctx, mesh_spec_fun: spec)

      log =
        capture_log(fn ->
          catch_exit(Resolver.replace(inv, [], ctx.names.resolver))
          # The restarted Resolver starts the mesh.
          wait_until(fn -> is_pid(mesh_pid(ctx)) end)
        end)

      assert log =~ "TuyaMesh.Resolver: FunctionClauseError raised"
      refute_keys(log)
    end

    test "JSON and snake_case uploads: a crash mid-request with more queued leaks no key",
         ctx do
      alias UniversalProxy.TuyaMesh.KeyLeak

      once = start_supervised!({Agent, fn -> true end}, id: :once)

      spec = fn index, mac ->
        if Agent.get_and_update(once, &{&1, false}) do
          Process.sleep(150)
          apply(__MODULE__, :explode, [KeyLeak.snake_map()])
        else
          fake_mesh(index, mac)
        end
      end

      start_mesh_sup(ctx, mesh_spec_fun: spec)
      resolver = ctx.names.resolver

      log =
        capture_log(fn ->
          spawn(fn -> catch_exit(Resolver.replace(KeyLeak.json(), [], resolver)) end)
          Process.sleep(30)
          spawn(fn -> catch_exit(Resolver.replace(KeyLeak.snake_map(), [], resolver)) end)
          Process.sleep(30)
          spawn(fn -> catch_exit(Resolver.replace(KeyLeak.json(), [], resolver)) end)
          wait_until(fn -> is_pid(mesh_pid(ctx)) end)
          Process.sleep(100)
        end)

      assert log =~ "TuyaMesh.Resolver: FunctionClauseError raised"
      KeyLeak.refute_keys(log)

      # And its :sys status and debug log after more of them.
      :ok = :sys.log(resolver, true)
      {:ok, _} = Resolver.replace(KeyLeak.snake_map(), [], resolver)
      {:ok, _} = Resolver.replace(KeyLeak.json(), [], resolver)
      KeyLeak.refute_keys(:sys.get_status(resolver))
    end

    test "format_status keeps keys out of messages, logs and reasons" do
      inv = inventory()
      map = Inventory.to_map(inv)
      call = {:"$gen_call", {self(), make_ref()}, {:replace, inv, []}}

      status =
        Resolver.format_status(%{
          state: %{mac: @mesh_mac, inventory: %{bulbs: [], groups: []}},
          message: call,
          queue: [call],
          log: [{:in, call}, {:noreply, %{inventory: inv}}],
          reason:
            {%FunctionClauseError{module: Mesh, function: :x, arity: 1, args: [map]},
             [{Mesh, :x, [map], []}]}
        })

      refute_keys(inspect(status, limit: :infinity, printable_limit: :infinity))
      assert {:"$gen_call", _from, {:replace, :redacted, []}} = status.message
      assert {{:exception, FunctionClauseError}, [{Mesh, :x, 1, []}]} = status.reason
      assert status.state.mac == @mesh_mac
    end
  end

  describe "last seen and reachability" do
    setup ctx do
      {:ok, _} = Store.replace(inventory(), [], ctx.store)
      n = System.unique_integer([:positive])
      lights = :"fake_lights_#{n}"
      radio = :"fake_radio_#{n}"
      start_supervised!({FakeLights, name: lights, macs: [@bulb2, @bulb3]}, id: :fake_lights)
      start_supervised!({FakeRadio, name: radio}, id: :fake_radio)
      start_mesh_sup(ctx, lights: lights, radio: radio)
      {:ok, lights: lights}
    end

    defp bulb(ctx, mac), do: Enum.find(status(ctx).bulbs, &(&1.mac == mac))
    defp now_ms, do: System.monotonic_time(:millisecond)
    defp resolver_pid(ctx), do: Process.whereis(ctx.names.resolver)

    defp presence(ctx, snapshot), do: presence(ctx, 1, snapshot)

    # From pinger `pinger` of the running mesh.
    defp presence(ctx, pinger, snapshot),
      do: presence(ctx, mesh_generation(ctx), pinger, snapshot)

    defp presence(ctx, mesh_generation, pinger, snapshot) do
      send(resolver_pid(ctx), {:tuya_mesh_presence, {mesh_generation, pinger}, snapshot})
      # A call returns once the message before it was handled.
      status(ctx)
    end

    defp mesh_generation(ctx), do: :sys.get_state(resolver_pid(ctx)).mesh_generation

    defp p(fields),
      do:
        Map.merge(
          %{last_ms: nil, misses: 0, missed_at: nil, interval_ms: 120_000, pinging: false},
          fields
        )

    test "a Lights restart and a same-mesh upload keep last seen; a removed bulb drops out",
         ctx do
      :ok = FakeLights.report(ctx.lights, @bulb2, now_ms())
      wait_until(fn -> match?(%{last_seen: %DateTime{}, reachable: true}, bulb(ctx, @bulb2)) end)
      seen = bulb(ctx, @bulb2).last_seen

      # A restarted Lights: every bulb unheard.
      :ok = FakeLights.put(ctx.lights, :bulbs, %{@bulb2 => nil, @bulb3 => nil})
      Process.sleep(60)
      assert %{last_seen: ^seen, reachable: true} = bulb(ctx, @bulb2)

      assert {:ok, :same_mesh} = Resolver.replace(inventory(), [], ctx.names.resolver)
      Process.sleep(60)
      assert %{last_seen: ^seen} = bulb(ctx, @bulb2)

      # Removed, then back: nothing kept for it.
      without = %{
        inventory()
        | bulbs: Enum.reject(inventory().bulbs, &(&1.mac == @bulb2)),
          groups: []
      }

      assert {:ok, :same_mesh} = Resolver.replace(without, [], ctx.names.resolver)
      assert bulb(ctx, @bulb2) == nil
      assert {:ok, :same_mesh} = Resolver.replace(inventory(), [], ctx.names.resolver)
      assert %{last_seen: nil, reachable: false} = bulb(ctx, @bulb2)
    end

    test "a new mesh forgets what the old one heard", ctx do
      :ok = FakeLights.report(ctx.lights, @bulb2, now_ms())
      wait_until(fn -> match?(%{last_seen: %DateTime{}}, bulb(ctx, @bulb2)) end)
      :ok = FakeLights.put(ctx.lights, :bulbs, %{@bulb2 => nil, @bulb3 => nil})

      key = "ffeeddccbbaa99887766554433221100"

      other = %{
        inventory()
        | beacon_key: key,
          bulbs: Enum.map(inventory().bulbs, &%{&1 | beacon_key: key})
      }

      assert {:ok, :new_mesh} =
               Resolver.replace(other, [allow_new_mesh: true], ctx.names.resolver)

      assert %{last_seen: nil} = bulb(ctx, @bulb2)
    end

    test "a stale report within 2.5 pinger intervals stays reachable", ctx do
      last = now_ms() - 140_000
      :ok = FakeLights.report(ctx.lights, @bulb2, last)
      wait_until(fn -> match?(%{last_seen: %DateTime{}}, bulb(ctx, @bulb2)) end)

      # No pinger yet: the plain 2 min window.
      assert %{reachable: false, checking: false} = bulb(ctx, @bulb2)

      # The pinger's 60 s cycle: a 150 s window.
      presence(ctx, %{@bulb2 => p(%{last_ms: last, interval_ms: 60_000})})
      assert %{reachable: true} = bulb(ctx, @bulb2)

      # Checks every 40 s: back to 2 min, but no verdict yet.
      presence(ctx, %{@bulb2 => p(%{last_ms: last, interval_ms: 40_000})})
      assert %{reachable: false, checking: true} = bulb(ctx, @bulb2)
    end

    test "not reachable only after two missed pings in a row, until a reply", ctx do
      t0 = now_ms()
      :ok = FakeLights.report(ctx.lights, @bulb2, t0)
      wait_until(fn -> match?(%{reachable: true}, bulb(ctx, @bulb2)) end)

      presence(ctx, %{@bulb2 => p(%{last_ms: t0, misses: 1, missed_at: t0 + 1})})
      assert %{reachable: true} = bulb(ctx, @bulb2)

      presence(ctx, %{@bulb2 => p(%{last_ms: t0, misses: 2, missed_at: t0 + 2})})
      assert %{reachable: false, checking: false} = bulb(ctx, @bulb2)

      # A restarted pinger knows nothing: the verdict stands.
      restarted = 2
      presence(ctx, restarted, %{@bulb2 => p(%{})})
      assert %{reachable: false, checking: false} = bulb(ctx, @bulb2)
      presence(ctx, restarted, %{@bulb2 => p(%{misses: 1, missed_at: t0 + 3})})
      assert %{reachable: false} = bulb(ctx, @bulb2)

      # Any report after the last missed ping clears it.
      :ok = FakeLights.report(ctx.lights, @bulb2, t0 + 4)
      wait_until(fn -> match?(%{reachable: true}, bulb(ctx, @bulb2)) end)
      presence(ctx, restarted, %{@bulb2 => p(%{last_ms: t0 + 4})})
      assert %{reachable: true} = bulb(ctx, @bulb2)

      # And counting starts over.
      presence(ctx, restarted, %{@bulb2 => p(%{last_ms: t0 + 4, misses: 1, missed_at: t0 + 5})})
      assert %{reachable: true} = bulb(ctx, @bulb2)
    end

    test "misses add up across a pinger restart, and a mesh restart", ctx do
      t0 = now_ms()
      :ok = FakeLights.report(ctx.lights, @bulb2, t0)
      wait_until(fn -> match?(%{reachable: true}, bulb(ctx, @bulb2)) end)

      presence(ctx, %{@bulb2 => p(%{last_ms: t0, misses: 1, missed_at: t0 + 1})})
      assert %{reachable: true} = bulb(ctx, @bulb2)

      # The new pinger's first miss is the second in a row.
      second = 2
      presence(ctx, second, %{@bulb2 => p(%{last_ms: t0, misses: 1, missed_at: t0 + 2})})
      assert %{reachable: false} = bulb(ctx, @bulb2)

      # A late snapshot from the pinger before is stale: dropped.
      presence(ctx, 1, %{@bulb2 => p(%{last_ms: t0 + 3})})
      assert %{reachable: false} = bulb(ctx, @bulb2)

      # A reply clears it; one miss, a mesh restart, one more: two again.
      :ok = FakeLights.report(ctx.lights, @bulb2, t0 + 4)
      wait_until(fn -> match?(%{reachable: true}, bulb(ctx, @bulb2)) end)
      presence(ctx, second, %{@bulb2 => p(%{last_ms: t0 + 4, misses: 1, missed_at: t0 + 5})})
      assert %{reachable: true} = bulb(ctx, @bulb2)

      assert {:ok, :same_mesh} = Resolver.replace(inventory(), [], ctx.names.resolver)
      presence(ctx, 1, %{@bulb2 => p(%{last_ms: t0 + 4, misses: 1, missed_at: t0 + 6})})
      assert %{reachable: false} = bulb(ctx, @bulb2)
    end

    test "A → B → A: each change of mesh forgets what the other heard", ctx do
      key = "ffeeddccbbaa99887766554433221100"
      a = inventory()
      b = %{a | beacon_key: key, bulbs: Enum.map(a.bulbs, &%{&1 | beacon_key: key})}

      for inv <- [b, a] do
        :ok = FakeLights.report(ctx.lights, @bulb2, now_ms())
        wait_until(fn -> match?(%{last_seen: %DateTime{}}, bulb(ctx, @bulb2)) end)
        # The new mesh's Lights hasn't heard it.
        :ok = FakeLights.put(ctx.lights, :bulbs, %{@bulb2 => nil, @bulb3 => nil})

        assert {:ok, _kind} =
                 Resolver.replace(inv, [allow_new_mesh: true], ctx.names.resolver)

        assert %{last_seen: nil} = bulb(ctx, @bulb2)
      end
    end

    test "a delayed snapshot from a replaced pinger is dropped, even its first", ctx do
      t0 = now_ms()
      presence(ctx, 5, %{@bulb2 => p(%{misses: 2, missed_at: t0})})
      assert %{reachable: false, last_seen: nil} = bulb(ctx, @bulb2)

      # Pinger 3 started before 5 but was never heard from until now.
      presence(ctx, 3, %{@bulb2 => p(%{last_ms: t0 + 1})})
      assert %{reachable: false, last_seen: nil} = bulb(ctx, @bulb2)
    end

    test "an old mesh's snapshot arriving after a change of mesh is dropped", ctx do
      old = mesh_generation(ctx)
      key = "ffeeddccbbaa99887766554433221100"

      other = %{
        inventory()
        | beacon_key: key,
          bulbs: Enum.map(inventory().bulbs, &%{&1 | beacon_key: key})
      }

      assert {:ok, :new_mesh} =
               Resolver.replace(other, [allow_new_mesh: true], ctx.names.resolver)

      assert mesh_generation(ctx) > old

      presence(ctx, old, 9, %{@bulb3 => p(%{last_ms: now_ms()})})
      assert %{last_seen: nil} = bulb(ctx, @bulb3)
    end

    test "checking needs Lights answering and the live pinger to have reported the bulb", ctx do
      # A pinger with nothing to report (Lights gave it nothing).
      presence(ctx, %{})
      assert %{checking: false} = bulb(ctx, @bulb3)

      presence(ctx, %{@bulb3 => p(%{})})
      assert %{checking: true} = bulb(ctx, @bulb3)

      # A newer pinger that hasn't reported it yet.
      presence(ctx, 2, %{@bulb2 => p(%{})})
      assert %{checking: false} = bulb(ctx, @bulb3)
      presence(ctx, 2, %{@bulb3 => p(%{})})
      assert %{checking: true} = bulb(ctx, @bulb3)

      # Lights not answering (stopped, or :ignore on a bad inventory).
      :ok = FakeLights.put(ctx.lights, :all_reply, {:error, :not_running})
      wait_until(fn -> match?(%{lights_running: false}, status(ctx)) end)
      assert %{checking: false} = bulb(ctx, @bulb3)
    end

    test "never heard, with the pinger running and the radio ready: checking", ctx do
      assert %{reachable: false, checking: false} = bulb(ctx, @bulb3)
      presence(ctx, %{@bulb3 => p(%{pinging: true})})
      assert %{reachable: false, checking: true, last_seen: nil} = bulb(ctx, @bulb3)

      presence(ctx, %{@bulb3 => p(%{misses: 2, missed_at: now_ms()})})
      assert %{reachable: false, checking: false} = bulb(ctx, @bulb3)
    end

    test "idle: nothing reachable or checking, last seen kept", ctx do
      :ok = FakeLights.report(ctx.lights, @bulb2, now_ms())
      wait_until(fn -> match?(%{reachable: true}, bulb(ctx, @bulb2)) end)

      set_adapters(ctx, [adapter(@proxy_mac, 0)])
      adapters_changed(ctx)
      wait_until(fn -> status(ctx).state == :idle end)
      assert %{reachable: false, checking: false, last_seen: %DateTime{}} = bulb(ctx, @bulb2)

      # A snapshot arriving now (from the stopped mesh) is dropped.
      presence(ctx, %{@bulb3 => p(%{last_ms: now_ms()})})
      assert %{last_seen: nil} = bulb(ctx, @bulb3)
    end
  end

  defmodule PushingMesh do
    @moduledoc false
    # A stand-in mesh whose stop makes Lights forget (as a stopping Lights
    # does) and may push one last snapshot to the Resolver.
    use GenServer

    @impl GenServer
    def init(arg) do
      Process.flag(:trap_exit, true)
      {:ok, arg}
    end

    @impl GenServer
    def terminate(_reason, %{lights: lights, resolver: resolver, push: push, generation: gen}) do
      UniversalProxy.TuyaMesh.FakeLights.put(lights, :bulbs, %{
        "DC23530FB34A" => nil,
        "DC23533FCD62" => nil
      })

      if push, do: send(Process.whereis(resolver), {:tuya_mesh_presence, {gen, 1}, push.()})
    end
  end

  describe "the pinger's frame log" do
    setup ctx do
      {:ok, _} = Store.replace(inventory(), [], ctx.store)
      test_pid = self()

      # A stand-in mesh that reports the Presence options it was given.
      spec = fn index, mac, presence ->
        send(test_pid, {:presence_opts, presence})
        fake_mesh(index, mac)
      end

      {:ok, spec: spec}
    end

    defp frames(ctx), do: :sys.get_state(Process.whereis(ctx.names.resolver)).frames

    test "is handed to every mesh's Presence, the same table across meshes", ctx do
      start_mesh_sup(ctx, mesh_spec_fun: ctx.spec)
      assert_receive {:presence_opts, first}
      assert first[:frames] == frames(ctx)

      assert {:ok, :same_mesh} = Resolver.replace(inventory(), [], ctx.names.resolver)
      assert_receive {:presence_opts, second}
      assert second[:frames] == first[:frames]
      assert second[:mesh_generation] > first[:mesh_generation]
    end

    test "survives a Resolver that stops; one killed leaves it marked unknown", ctx do
      start_mesh_sup(ctx, mesh_spec_fun: ctx.spec)
      assert :ets.lookup(frames(ctx), :unknown_until) == []
      :ets.insert(frames(ctx), {1, 123, :followup})

      # A clean stop (e.g. the Bluez subtree restarting): handed on.
      :ok = stop_supervised(UniversalProxy.TuyaMesh.Supervisor)
      start_mesh_sup(ctx, mesh_spec_fun: ctx.spec)
      assert :ets.lookup(frames(ctx), 1) == [{1, 123, :followup}]
      assert :ets.lookup(frames(ctx), :unknown_until) == []

      # Killed: its successor can't know the last hour.
      resolver = Process.whereis(ctx.names.resolver)
      Process.exit(resolver, :kill)
      wait_until(fn -> Process.whereis(ctx.names.resolver) not in [nil, resolver] end)
      assert [{:unknown_until, _}] = :ets.lookup(frames(ctx), :unknown_until)
    end
  end

  describe "a change keeps what was heard just before it" do
    setup ctx do
      {:ok, _} = Store.replace(inventory(), [], ctx.store)
      n = System.unique_integer([:positive])
      lights = :"fake_lights_#{n}"
      radio = :"fake_radio_#{n}"
      start_supervised!({FakeLights, name: lights, macs: [@bulb2, @bulb3]}, id: :fake_lights)
      start_supervised!({FakeRadio, name: radio}, id: :fake_radio)
      {:ok, lights: lights, radio: radio}
    end

    defp start_pushing(ctx, push) do
      arg = %{lights: ctx.lights, resolver: ctx.names.resolver, push: push}

      spec = fn _index, _mac, presence ->
        arg = Map.put(arg, :generation, presence[:mesh_generation])
        %{id: :mesh, start: {GenServer, :start_link, [PushingMesh, arg]}, restart: :temporary}
      end

      # No tick: only the change itself reads Lights.
      start_mesh_sup(ctx,
        mesh_spec_fun: spec,
        lights: ctx.lights,
        radio: ctx.radio,
        tick_ms: 60_000
      )
    end

    defp seen(ctx, mac), do: Enum.find(status(ctx).bulbs, &(&1.mac == mac)).last_seen

    test "a report Lights holds when an upload stops it", ctx do
      start_pushing(ctx, nil)
      :ok = FakeLights.report(ctx.lights, @bulb2, System.monotonic_time(:millisecond))
      assert seen(ctx, @bulb2) == nil

      assert {:ok, :same_mesh} = Resolver.replace(inventory(), [], ctx.names.resolver)
      assert %DateTime{} = seen(ctx, @bulb2)
    end

    test "a snapshot the pinger pushed as the mesh stopped", ctx do
      now = System.monotonic_time(:millisecond)

      start_pushing(ctx, fn ->
        %{
          "DC23533FCD62" => %{
            last_ms: now,
            misses: 0,
            missed_at: nil,
            interval_ms: 120_000,
            pinging: false
          }
        }
      end)

      assert {:ok, :same_mesh} = Resolver.replace(inventory(), [], ctx.names.resolver)
      assert %DateTime{} = seen(ctx, @bulb3)
    end
  end

  describe "mesh wiring" do
    test "Lights persists and tightens through the Store; the Radio is fenced by MAC" do
      assert {:ok, {_flags, [radio, lights, presence]}} =
               Mesh.init(adapter_index: 2, adapter_address: @mesh_mac, presence: [notify: self()])

      %{start: {Presence, :start_link, [presence_opts]}} = presence
      assert presence_opts[:lights] == Lights
      assert presence_opts[:radio] == Radio
      assert presence_opts[:notify] == self()

      %{start: {Radio, :start_link, [radio_opts]}} = radio
      assert radio_opts[:adapter_index] == 2
      assert radio_opts[:adapter_address] == @mesh_mac

      %{start: {Lights, :start_link, [lights_opts]}} = lights
      assert lights_opts[:on_persist] == (&Store.persist/1)
      assert lights_opts[:on_tighten] == (&Store.tighten/2)
      assert lights_opts[:inventory] == (&Store.load/0)
      # The Store's upload bound is derived from this lease cap.
      assert lights_opts[:max_lease] == Store.lights_max_lease()
    end
  end

  # The Lights here takes `on_tighten:` whether or not it knows the option.
  describe "with the real mesh (FakeBluez)" do
    setup ctx do
      FakeBluez.ensure_started()
      FakeBluez.reset()
      FakeBluez.set_address(1, @mesh_mac)
      {:ok, _} = Store.replace(inventory(), [], ctx.store)
      store = ctx.store

      spec = fn index, mac ->
        Mesh.child_spec(
          adapter_index: index,
          adapter_address: mac,
          radio: [
            bluez_radio: FakeBluez.Radio,
            mgmt: FakeBluez.Mgmt,
            rebus: FakeBluez.Rebus,
            dbus: FakeBluez.DBus,
            receiver: FakeBluez.Receiver,
            retry_ms: 20
          ],
          lights: [
            inventory: fn -> Store.load(store) end,
            on_persist: &Store.persist(&1, store),
            on_tighten: &Store.tighten(&1, &2, store)
          ]
        )
      end

      start_mesh_sup(ctx, mesh_spec_fun: spec, radio: Radio, lights: Lights, tick_ms: 50)
      wait_until(fn -> match?(%{radio: %{ready: true}, lights_running: true}, status(ctx)) end)
      :ok
    end

    test "Radio on the resolved adapter, powered; Lights persists through the Store", ctx do
      assert {:ok, %{adapter_index: 1, adapter_address: @mesh_mac, ready: true}} = Radio.status()
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

    test "a replacement pinger starts settling before its first attempt", ctx do
      restarts = [
        fn -> Process.exit(Process.whereis(Presence), :kill) end,
        fn -> {:ok, :same_mesh} = Resolver.replace(inventory(), [], ctx.names.resolver) end
      ]

      for restart <- restarts do
        old = Process.whereis(Presence)
        restart.()
        wait_until(fn -> Process.whereis(Presence) not in [nil, old] end)
        state = :sys.get_state(Presence)
        # Settling: no attempt before a Lights read, an idle Radio and a gap.
        assert state.settling in [:lights, :radio]
      end
    end

    test "a pinger crash restarts only the pinger", ctx do
      radio = Process.whereis(Radio)
      lights = Process.whereis(Lights)
      presence = Process.whereis(Presence)
      assert is_pid(presence)

      Process.exit(presence, :kill)
      wait_until(fn -> Process.whereis(Presence) not in [nil, presence] end)
      assert Process.whereis(Radio) == radio
      assert Process.whereis(Lights) == lights
      assert %{state: :running, lights_running: true} = status(ctx)
    end

    test "an upload restarts Radio and Lights on the new inventory", ctx do
      radio = Process.whereis(Radio)
      new = inventory() |> Map.put(:seq, 350)
      assert {:ok, :same_mesh} = Resolver.replace(new, [], ctx.names.resolver)
      wait_until(fn -> match?(%{radio: %{ready: true}, lights_running: true}, status(ctx)) end)
      assert Process.whereis(Radio) != radio
      assert {:ok, %Inventory{seq: 350}} = Lights.inventory()
    end
  end

  defmodule ProbeMesh do
    @moduledoc false
    # Reports, when stopped, whether the Resolver was still registered.
    use GenServer

    @impl GenServer
    def init(arg) do
      Process.flag(:trap_exit, true)
      {:ok, arg}
    end

    @impl GenServer
    def terminate(_reason, {test_pid, resolver}) do
      send(test_pid, {:mesh_stopped, resolver_alive?: Process.whereis(resolver) != nil})
    end
  end

  defp inject_report(node, sn, dps) do
    {:ok, payload} = Dp.encode(dps)
    frame = P2.build(1, 7, node, 0x8001, sn, payload, @beacon_key, @beacon_key)
    FakeBluez.inject(%{address: @mac2, data: Carrier.ad_bytes(frame), rssi: -40})
  end
end
