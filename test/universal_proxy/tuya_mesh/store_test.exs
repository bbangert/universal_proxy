defmodule UniversalProxy.TuyaMesh.StoreTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias UniversalProxy.TuyaBeaconMesh.Inventory
  alias UniversalProxy.TuyaMesh.Store

  @moduletag :tmp_dir

  @fixture Path.join([
             __DIR__,
             "..",
             "..",
             "fixtures",
             "tuya_beacon_mesh",
             "example_inventory.json"
           ])

  @beacon_key "00112233445566778899aabbccddeeff"
  @other_key "ffeeddccbbaa99887766554433221100"
  @local_keys ["abcdefghijklmnop", "ponmlkjihgfedcba"]
  @mac2 "DC23530FB34A"
  @mac3 "DC23533FCD62"

  setup %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "tuya_mesh.dets")
    table = :"tuya_mesh_#{System.unique_integer([:positive])}"
    store = start_store(path, table)
    {:ok, store: store, path: path, table: table}
  end

  defp start_store(path, table, opts \\ []) do
    start_supervised!(
      {Store, [name: nil, enabled: true, table: table, dets_path: path] ++ opts},
      id: Keyword.get(opts, :id, Store)
    )
  end

  defp restart_store(%{path: path, table: table}) do
    stop_supervised!(Store)
    start_store(path, table)
  end

  defp raw, do: @fixture |> File.read!() |> Jason.decode!()

  defp inventory(overrides \\ %{}), do: raw() |> Map.merge(overrides) |> Inventory.decode!()

  defp other_mesh(overrides \\ %{}),
    do: inventory(Map.merge(%{"beaconKey" => @other_key}, overrides))

  defp refute_secrets(term) do
    text = inspect(term, limit: :infinity, printable_limit: :infinity)

    for secret <- [@beacon_key, @other_key | @local_keys] do
      refute text =~ secret
      refute text =~ String.upcase(secret)
    end
  end

  describe "opening" do
    test "restricts the file to 0600", %{path: path} do
      assert %File.Stat{mode: mode} = File.stat!(path)
      assert Bitwise.band(mode, 0o777) == 0o600
    end

    test "a chmod that fails stops init and closes the table", %{tmp_dir: tmp_dir} do
      table = :"tuya_mesh_chmod_#{System.unique_integer([:positive])}"

      log =
        capture_log(fn ->
          assert {:error, {{:chmod_failed, :eperm}, _spec}} =
                   start_supervised(
                     {Store,
                      name: nil,
                      enabled: true,
                      table: table,
                      dets_path: Path.join(tmp_dir, "unchmodable.dets"),
                      chmod_fun: fn _path, _mode -> {:error, :eperm} end},
                     id: :unchmodable
                   )
        end)

      assert log =~ "could not be restricted to 0600"
      assert :dets.info(table) == :undefined
    end

    test "is a no-op off BT targets" do
      assert Store.start_link(enabled: false) == :ignore
    end

    test "the API degrades when the store is down" do
      down = :"no_store_#{System.unique_integer([:positive])}"
      assert Store.load(down) == {:error, :unavailable}
      assert Store.persist(inventory(), down) == {:error, :unavailable}
      assert Store.replace(inventory(), [], down) == {:error, :unavailable}
      assert Store.device_ids(down) == %{}
      assert Store.settings(down) == Store.default_settings()
    end
  end

  describe "inventory" do
    test "round-trips through replace and load, across a restart", ctx do
      inv = inventory()
      assert Store.load(ctx.store) == {:error, :no_inventory}
      assert {:ok, :new_mesh} = Store.replace(inv, [], ctx.store)
      assert {:ok, ^inv} = Store.load(ctx.store)

      store = restart_store(ctx)
      assert {:ok, ^inv} = Store.load(store)
    end

    test "load re-validates what is stored", ctx do
      assert {:ok, _} = Store.replace(inventory(), [], ctx.store)
      bad = Map.put(raw(), "bulbs", [])
      :ok = :dets.insert(ctx.table, {:inventory, bad})

      log = capture_log(fn -> assert {:error, {:invalid, :no_bulbs}} = Store.load(ctx.store) end)
      assert log =~ "stored inventory is invalid"
    end

    test "replace refuses an invalid inventory without echoing it", ctx do
      bad =
        Map.update!(raw(), "bulbs", fn [b | rest] -> [Map.put(b, "localKey", "short") | rest] end)

      assert {:error, {:invalid, {:bad_local_key, @mac2}}} =
               error = Store.replace(bad, [], ctx.store)

      refute_secrets(error)
      assert Store.load(ctx.store) == {:error, :no_inventory}
    end

    test "clear removes the inventory", ctx do
      assert {:ok, _} = Store.replace(inventory(), [], ctx.store)
      assert :ok = Store.clear(ctx.store)
      assert Store.load(ctx.store) == {:error, :no_inventory}
      assert :ok = Store.clear(ctx.store)
    end
  end

  describe "persist (the Lights on_persist)" do
    setup ctx do
      {:ok, _} = Store.replace(inventory(), [], ctx.store)
      :ok
    end

    test "writes an advanced seq durably before answering :ok", ctx do
      assert :ok = Store.persist(%{inventory() | seq: 132}, ctx.store)
      store = restart_store(ctx)
      assert {:ok, %Inventory{seq: 132}} = Store.load(store)
    end

    test "every write answers :ok only once written and synced", ctx do
      store =
        start_store(Path.join(ctx.tmp_dir, "failing.dets"), :"failing_#{System.unique_integer()}",
          id: :failing,
          write_fun: fn _table, _inserts, _deletes -> {:error, :sync_failed} end
        )

      log =
        capture_log(fn ->
          assert {:error, :write_failed} = Store.replace(inventory(), [], store)
        end)

      assert log =~ "write failed"
    end

    test "may change groups but refuses a stale writer", ctx do
      inv = inventory()
      assert :ok = Store.persist(%{inv | seq: 100}, ctx.store)
      assert :ok = Store.persist(%{inv | seq: 200, groups: []}, ctx.store)

      assert {:error, :seq_behind} = Store.persist(%{inv | seq: 150, groups: []}, ctx.store)

      assert {:error, :bulbs_changed} =
               Store.persist(%{inv | seq: 300, bulbs: tl(inv.bulbs), groups: []}, ctx.store)

      assert {:error, :mesh_changed} = Store.persist(%{other_mesh() | seq: 300}, ctx.store)
      assert {:ok, %Inventory{seq: 200, groups: []}} = Store.load(ctx.store)

      :ok = Store.clear(ctx.store)
      assert {:error, :no_inventory} = Store.persist(inv, ctx.store)
    end

    test "a seq that wrapped past 65535 counts as ahead", ctx do
      inv = inventory()
      assert :ok = Store.persist(%{inv | seq: 32_000}, ctx.store)
      assert :ok = Store.persist(%{inv | seq: 63_000}, ctx.store)
      assert :ok = Store.persist(%{inv | seq: 10}, ctx.store)
      assert {:ok, %Inventory{seq: 10}} = Store.load(ctx.store)
    end
  end

  describe "replace and mesh identity" do
    test "classify and preview tell the meshes apart and diff the bulbs", ctx do
      assert Store.classify(inventory(), ctx.store) == :empty
      {:ok, _} = Store.replace(inventory(), [], ctx.store)

      # Same key in its other spelling is the same mesh.
      assert Store.classify(inventory(%{"beaconKey" => String.upcase(@beacon_key)}), ctx.store) ==
               :same_mesh

      [_b2, b3] = raw()["bulbs"]
      new_bulb = %{"mac" => "AABBCCDDEEFF", "localKey" => "qrstuvwxyzabcdef", "nodeId" => 9}
      changed = other_mesh(%{"bulbs" => [b3, new_bulb], "groups" => []})

      assert Store.classify(changed, ctx.store) == :new_mesh
      assert {:ok, preview} = Store.preview(changed, ctx.store)

      assert preview == %{
               mesh: :new_mesh,
               bulbs: %{
                 added: [%{mac: "AABBCCDDEEFF", label: nil}],
                 removed: [%{mac: @mac2, label: "path light 2"}]
               },
               groups: %{added: [], removed: [%{local_id: 1, name: "path and post"}]}
             }

      refute_secrets(preview)
    end

    test "the same mesh never moves the seq back", ctx do
      {:ok, :new_mesh} = Store.replace(inventory(), [], ctx.store)
      :ok = Store.persist(%{inventory() | seq: 500}, ctx.store)

      # An older dump keeps the stored cursor; a newer one advances it.
      assert {:ok, :same_mesh} = Store.replace(inventory(), [], ctx.store)
      assert {:ok, %Inventory{seq: 500}} = Store.load(ctx.store)
      assert {:ok, :same_mesh} = Store.replace(inventory(%{"seq" => 900}), [], ctx.store)
      assert {:ok, %Inventory{seq: 900}} = Store.load(ctx.store)
    end

    test "a different mesh needs allow_new_mesh and takes the dump's seq", ctx do
      {:ok, _} = Store.replace(inventory(), [], ctx.store)
      :ok = Store.persist(%{inventory() | seq: 500}, ctx.store)

      assert {:error, :new_mesh} = Store.replace(other_mesh(%{"seq" => 7}), [], ctx.store)
      assert {:ok, %Inventory{seq: 500}} = Store.load(ctx.store)

      assert {:ok, :new_mesh} =
               Store.replace(other_mesh(%{"seq" => 7}), [allow_new_mesh: true], ctx.store)

      assert {:ok, %Inventory{seq: 7} = stored} = Store.load(ctx.store)
      assert stored.beacon_key == @other_key
    end

    test "a mesh that left the store comes back no lower than its last seq", ctx do
      {:ok, _} = Store.replace(inventory(), [], ctx.store)
      :ok = Store.persist(%{inventory() | seq: 500}, ctx.store)

      # Cleared, then re-uploaded from the old dump.
      :ok = Store.clear(ctx.store)
      assert {:ok, :same_mesh} = Store.replace(inventory(), [], ctx.store)
      assert {:ok, %Inventory{seq: 500}} = Store.load(ctx.store)

      # Displaced by another mesh, then back.
      {:ok, :new_mesh} = Store.replace(other_mesh(), [allow_new_mesh: true], ctx.store)
      assert {:ok, :same_mesh} = Store.replace(inventory(), [allow_new_mesh: true], ctx.store)
      assert {:ok, %Inventory{seq: 500}} = Store.load(ctx.store)

      # The floors hold fingerprints only.
      refute_secrets(:dets.lookup(ctx.table, :seq_floors))
    end
  end

  describe "device ids" do
    test "allocated for every bulb and group, from 1, persisted", ctx do
      {:ok, _} = Store.replace(inventory(), [], ctx.store)

      assert Store.device_ids(ctx.store) == %{
               {:bulb, @mac2} => 1,
               {:bulb, @mac3} => 2,
               {:group, 1} => 3
             }

      store = restart_store(ctx)
      assert map_size(Store.device_ids(store)) == 3
    end

    test "are never reused, even across clear", ctx do
      {:ok, _} = Store.replace(inventory(), [], ctx.store)
      assert {:ok, %{{:group, 9} => 4}} = Store.allocate_device_ids([{:group, 9}], ctx.store)

      # Keys that have an id keep it.
      assert {:ok, %{{:bulb, @mac2} => 1, {:group, 9} => 4}} =
               Store.allocate_device_ids([{:bulb, @mac2}, {:group, 9}], ctx.store)

      :ok = Store.clear(ctx.store)
      ids = Store.device_ids(ctx.store)
      # Groups leave with the inventory (their ids get reused for other
      # groups); bulbs are hardware and keep theirs.
      assert ids == %{{:bulb, @mac2} => 1, {:bulb, @mac3} => 2}

      store = restart_store(ctx)
      {:ok, _} = Store.replace(inventory(), [], store)
      ids = Store.device_ids(store)
      assert ids[{:bulb, @mac2}] == 1
      # The re-created group 1 is a new object: a fresh id, not 3 (or 4).
      assert ids[{:group, 1}] == 5
      refute 0 in Map.values(ids)
    end

    test "a bulb that left keeps its id for when it returns", ctx do
      [b2, b3] = raw()["bulbs"]
      {:ok, _} = Store.replace(inventory(), [], ctx.store)
      {:ok, _} = Store.replace(inventory(%{"bulbs" => [b3], "groups" => []}), [], ctx.store)
      {:ok, _} = Store.replace(inventory(%{"bulbs" => [b2, b3], "groups" => []}), [], ctx.store)
      assert Store.device_ids(ctx.store)[{:bulb, @mac2}] == 1
    end

    test "rejects malformed keys", ctx do
      assert {:error, :bad_device_key} = Store.allocate_device_ids([{:group, 255}], ctx.store)
      assert {:error, :bad_device_key} = Store.allocate_device_ids([:bulb], ctx.store)
    end
  end

  describe "settings" do
    test "defaults, validated updates, persisted", ctx do
      assert Store.settings(ctx.store) == %{min_mireds: 154, max_mireds: 370, invert: false}
      assert :ok = Store.put_settings(%{invert: true, max_mireds: 400}, ctx.store)
      assert {:error, :invalid_settings} = Store.put_settings(%{min_mireds: 500}, ctx.store)
      assert {:error, :invalid_settings} = Store.put_settings(%{invert: "yes"}, ctx.store)

      store = restart_store(ctx)
      assert Store.settings(store) == %{min_mireds: 154, max_mireds: 400, invert: true}
    end
  end

  describe "redaction" do
    test "format_status keeps keys out of messages, logs and crash reasons" do
      inv = inventory()
      map = Inventory.to_map(inv)
      call = {:"$gen_call", {self(), make_ref()}, {:replace, inv, [allow_new_mesh: true]}}
      stack = [{Store, :handle_call, [{:persist, map}, nil, %{}], [line: 1]}]

      status =
        Store.format_status(%{
          state: %{table: :t},
          message: call,
          queue: [{:"$gen_call", {self(), make_ref()}, {:persist, map}}],
          log: [{:in, {:"$gen_call", {self(), make_ref()}, {:preview, map}}}],
          reason:
            {%FunctionClauseError{module: Store, function: :x, arity: 1, args: [map]}, stack}
        })

      refute_secrets(status)

      assert {:"$gen_call", _from, {:replace, :redacted, [allow_new_mesh: true]}} =
               status.message

      assert {{:exception, FunctionClauseError}, [{Store, :handle_call, 3, _}]} = status.reason
    end

    test ":sys.get_status shows no keys", ctx do
      {:ok, _} = Store.replace(inventory(), [], ctx.store)
      refute_secrets(:sys.get_status(ctx.store))
    end
  end
end
