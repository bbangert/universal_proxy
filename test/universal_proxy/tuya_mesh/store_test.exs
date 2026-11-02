defmodule UniversalProxy.TuyaMesh.StoreTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias UniversalProxy.TuyaBeaconMesh.{Inventory, Seq}
  alias UniversalProxy.TuyaMesh.Store

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
          write_fun: fn _table, _records -> {:error, :sync_failed} end
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
               groups: %{added: [], removed: [%{local_id: 1, name: "path and post"}]},
               revision: 1,
               seq: %{outcome: :taken, reason: nil, local: nil, dump: 100}
             }

      refute_secrets(preview)
    end

    test "a new mesh's groups are all new, even with the same local ids", ctx do
      {:ok, _} = Store.replace(inventory(), [], ctx.store)
      group = %{local_id: 1, name: "path and post"}

      # Same mesh: group 1 is kept.
      assert {:ok, %{groups: %{added: [], removed: []}}} =
               Store.preview(inventory(%{"seq" => 900}), ctx.store)

      # Another mesh with an identical group 1: it goes and comes back new.
      assert {:ok, %{mesh: :new_mesh, bulbs: bulbs, groups: groups}} =
               Store.preview(other_mesh(), ctx.store)

      assert groups == %{added: [group], removed: [group]}
      assert bulbs == %{added: [], removed: []}
    end

    test "the same mesh never moves the seq back", ctx do
      {:ok, :new_mesh} = Store.replace(inventory(), [], ctx.store)
      :ok = Store.persist(%{inventory() | seq: 500}, ctx.store)

      # An older dump keeps the stored cursor; a newer one advances it.
      assert {:ok, :same_mesh} = Store.replace(inventory(), [], ctx.store)
      assert {:ok, %Inventory{seq: 500}} = Store.load(ctx.store)
      assert {:ok, :same_mesh} = Store.replace(inventory(%{"seq" => 750}), [], ctx.store)
      assert {:ok, %Inventory{seq: 750}} = Store.load(ctx.store)
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

  describe "upload seq" do
    defp upload(ctx, seq, opts \\ []) do
      inv = inventory(%{"seq" => seq})
      {:ok, %{seq: outcome}} = Store.preview(inv, ctx.store)
      {:ok, _kind} = Store.replace(inv, opts, ctx.store)
      {:ok, %Inventory{seq: stored}} = Store.load(ctx.store)
      {outcome.outcome, stored}
    end

    defp stored_at(ctx, seq) do
      :ok = Store.clear(ctx.store, force: true)
      :ok = :dets.delete(ctx.table, :seq_floors)
      {:taken, ^seq} = upload(ctx, seq)
    end

    test "the bound keeps a stale dump's jump, plus a crashed lease, within max_jump" do
      assert Seq.max_jump() - Store.lights_max_lease() - 1 == 299
    end

    test "a stale dump of the same mesh never moves the cursor back", ctx do
      stored_at(ctx, 40_000)
      inv = inventory(%{"seq" => 0})

      # 0 reads as 25_536 ahead in serial terms: kept, adoptable only on request.
      assert {:ok, %{seq: %{outcome: :kept_local, reason: :beyond_bound, local: 40_000, dump: 0}}} =
               Store.preview(inv, ctx.store)

      assert {:ok, %{seq: %{reason: :behind}}} =
               Store.preview(inventory(%{"seq" => 39_999}), ctx.store)

      log = capture_log(fn -> assert {:ok, :same_mesh} = Store.replace(inv, [], ctx.store) end)
      assert log =~ "keeping the device's"
      assert {:ok, %Inventory{seq: 40_000}} = Store.load(ctx.store)
    end

    test "only a bounded advance is taken; behind or far ahead keeps the local cursor", ctx do
      stored_at(ctx, 40_000)
      assert upload(ctx, 40_000) == {:same, 40_000}
      assert upload(ctx, 40_299) == {:taken, 40_299}
      capture_log(fn -> assert upload(ctx, 40_599) == {:kept_local, 40_299} end)
      capture_log(fn -> assert upload(ctx, 40_298) == {:kept_local, 40_299} end)
      # 20_000 ahead: a plain serial comparison would take it.
      capture_log(fn -> assert upload(ctx, 60_299) == {:kept_local, 40_299} end)

      assert {:ok, %{seq: %{reason: :beyond_bound}}} =
               Store.preview(inventory(%{"seq" => 40_599}), ctx.store)
    end

    test "around the wrap; a stale dump after a near-full wrap stays out", ctx do
      stored_at(ctx, 65_400)
      assert upload(ctx, 100) == {:taken, 100}
      capture_log(fn -> assert upload(ctx, 65_400) == {:kept_local, 100} end)

      stored_at(ctx, 65_535)
      assert upload(ctx, 0) == {:taken, 0}
      capture_log(fn -> assert upload(ctx, 65_535) == {:kept_local, 0} end)

      # 64000 against an old dump at 1000: 2_536 "ahead", past the bound.
      stored_at(ctx, 64_000)
      capture_log(fn -> assert upload(ctx, 1_000) == {:kept_local, 64_000} end)
    end

    test "a floor is a local cursor too", ctx do
      stored_at(ctx, 40_000)
      :ok = Store.clear(ctx.store)
      capture_log(fn -> assert upload(ctx, 0) == {:kept_local, 40_000} end)
    end

    test "the bound is an option, and can only be lowered", %{tmp_dir: tmp_dir} = ctx do
      store =
        start_store(
          Path.join(tmp_dir, "b.dets"),
          :"tuya_bound_#{System.unique_integer([:positive])}",
          id: :bounded,
          max_dump_advance: 10
        )

      ctx = %{ctx | store: store}
      assert upload(ctx, 40_000) == {:taken, 40_000}
      assert upload(ctx, 40_010) == {:taken, 40_010}
      capture_log(fn -> assert upload(ctx, 40_021) == {:kept_local, 40_010} end)

      assert {:error, _} =
               start_supervised(
                 {Store,
                  name: nil,
                  enabled: true,
                  table: :"tuya_bound_#{System.unique_integer([:positive])}",
                  dets_path: Path.join(tmp_dir, "c.dets"),
                  max_dump_advance: 300},
                 id: :too_far
               )
    end

    test "a genuinely newer dump is adopted when asked", ctx do
      # The Tuya app moved the bulbs from 1000 to 6000 while we were offline.
      stored_at(ctx, 1_000)
      capture_log(fn -> assert upload(ctx, 6_000) == {:kept_local, 1_000} end)

      log =
        capture_log(fn ->
          assert upload(ctx, 6_000, adopt_dump_seq: true) == {:kept_local, 6_000}
        end)

      assert log =~ "adopting"
    end

    test "adopting a dump behind, or equal to, the local cursor is refused", ctx do
      stored_at(ctx, 6_000)

      for seq <- [5_999, 6_000, 6_000 + 32_768] do
        assert {:error, {:seq_not_ahead, %{local: 6_000, dump: ^seq}}} =
                 Store.replace(inventory(%{"seq" => seq}), [adopt_dump_seq: true], ctx.store)
      end

      assert {:ok, %Inventory{seq: 6_000}} = Store.load(ctx.store)
    end

    test "clear, re-upload and adopt recovers a cursor the app moved on", ctx do
      stored_at(ctx, 1_000)
      :ok = Store.clear(ctx.store)
      capture_log(fn -> assert upload(ctx, 6_000) == {:kept_local, 1_000} end)

      :ok = Store.clear(ctx.store)
      capture_log(fn -> upload(ctx, 6_000, adopt_dump_seq: true) end)
      assert {:ok, %Inventory{seq: 6_000}} = Store.load(ctx.store)

      # The floor moved with it: a later stale dump stays out.
      :ok = Store.clear(ctx.store)
      capture_log(fn -> assert upload(ctx, 1_000) == {:kept_local, 6_000} end)
    end
  end

  describe "an invalid stored record" do
    # Valid key and seq, but no bulbs: not servable, floor recoverable.
    defp put_raw(ctx, raw), do: :ok = :dets.insert(ctx.table, {:inventory, raw})

    test "clear deletes it, keeps its seq floor and drops its group ids", ctx do
      {:ok, _} = Store.replace(inventory(), [], ctx.store)
      put_raw(ctx, Map.merge(raw(), %{"seq" => 700, "bulbs" => []}))
      capture_log(fn -> assert {:error, {:invalid, _}} = Store.load(ctx.store) end)

      assert :ok = Store.clear(ctx.store)
      assert Store.load(ctx.store) == {:error, :no_inventory}
      refute Map.has_key?(Store.device_ids(ctx.store), {:group, 1})

      assert {:ok, :same_mesh} = Store.replace(inventory(), [], ctx.store)
      assert {:ok, %Inventory{seq: 700}} = Store.load(ctx.store)
    end

    test "clear refuses to drop a floor it can't recover, unless forced", ctx do
      put_raw(ctx, %{"seq" => "garbage", "beaconKey" => "short"})

      assert {:error, :seq_unrecoverable} = Store.clear(ctx.store)
      capture_log(fn -> assert {:error, {:invalid, _}} = Store.load(ctx.store) end)

      log = capture_log(fn -> assert :ok = Store.clear(ctx.store, force: true) end)
      assert log =~ "seq is lost"
      assert Store.load(ctx.store) == {:error, :no_inventory}
    end

    test "replace over it salvages the floor too", ctx do
      put_raw(ctx, Map.merge(raw(), %{"seq" => 700, "bulbs" => []}))
      assert Store.classify(inventory(), ctx.store) == :empty
      assert {:ok, :same_mesh} = Store.replace(inventory(), [], ctx.store)
      assert {:ok, %Inventory{seq: 700}} = Store.load(ctx.store)
    end
  end

  describe "tighten (the Lights on_tighten)" do
    setup ctx do
      {:ok, _} = Store.replace(inventory(), [], ctx.store)
      # Lights persisted its lease end (100 + 32).
      :ok = Store.persist(%{inventory() | seq: 132}, ctx.store)
      {:ok, ids: Store.device_ids(ctx.store)}
    end

    test "moves the stored cursor back to the exact next on a lease match", ctx do
      assert :ok = Store.tighten(%{inventory() | seq: 105}, 132, ctx.store)
      store = restart_store(ctx)
      assert {:ok, %Inventory{seq: 105}} = Store.load(store)
      assert Store.device_ids(store) == ctx.ids
    end

    test "is refused once the stored cursor moved on", ctx do
      # A newer dump moved it forward while Lights still ran.
      {:ok, :same_mesh} = Store.replace(inventory(%{"seq" => 400}), [], ctx.store)

      assert {:error, :stale_tighten} = Store.tighten(%{inventory() | seq: 105}, 132, ctx.store)
      assert {:ok, %Inventory{seq: 400}} = Store.load(ctx.store)
    end

    test "is refused for another mesh or a changed inventory", ctx do
      inv = inventory()

      assert {:error, :mesh_changed} = Store.tighten(%{other_mesh() | seq: 105}, 132, ctx.store)

      assert {:error, :inventory_changed} =
               Store.tighten(%{inv | seq: 105, groups: []}, 132, ctx.store)

      assert {:error, :inventory_changed} =
               Store.tighten(%{inv | seq: 105, bulbs: tl(inv.bulbs), groups: []}, 132, ctx.store)

      assert {:error, :bad_lease} = Store.tighten(%{inv | seq: 105}, -1, ctx.store)
      assert {:ok, %Inventory{seq: 132}} = Store.load(ctx.store)

      :ok = Store.clear(ctx.store)
      assert {:error, :no_inventory} = Store.tighten(%{inv | seq: 105}, 132, ctx.store)
    end

    test "the floor after tighten + clear is the tightened cursor", ctx do
      :ok = Store.tighten(%{inventory() | seq: 105}, 132, ctx.store)
      :ok = Store.clear(ctx.store)

      # An old dump comes back no lower than 105 (every SN sent is below it).
      assert {:ok, :same_mesh} = Store.replace(inventory(%{"seq" => 0}), [], ctx.store)
      assert {:ok, %Inventory{seq: 105}} = Store.load(ctx.store)
    end
  end

  describe "device ids" do
    test "seq-only persists and same-mesh replaces keep group ids", ctx do
      {:ok, _} = Store.replace(inventory(), [], ctx.store)
      ids = Store.device_ids(ctx.store)

      for seq <- [132, 164, 164, 196] do
        :ok = Store.persist(%{inventory() | seq: seq}, ctx.store)
        assert Store.device_ids(ctx.store) == ids
      end

      # A same-mesh replace keeps the groups that remain.
      {:ok, :same_mesh} = Store.replace(inventory(%{"seq" => 900}), [], ctx.store)
      assert Store.device_ids(ctx.store) == ids

      # A persist that drops the group drops only its id.
      :ok = Store.persist(%{inventory() | seq: 900, groups: []}, ctx.store)
      assert Store.device_ids(ctx.store) == Map.delete(ids, {:group, 1})
    end

    test "a new mesh never inherits the old mesh's group ids", ctx do
      {:ok, _} = Store.replace(inventory(), [], ctx.store)
      assert %{{:group, 1} => 3} = Store.device_ids(ctx.store)

      # Same bulbs (by MAC) and the same local group id 1, different mesh.
      {:ok, :new_mesh} = Store.replace(other_mesh(), [allow_new_mesh: true], ctx.store)

      assert Store.device_ids(ctx.store) == %{
               {:bulb, @mac2} => 1,
               {:bulb, @mac3} => 2,
               {:group, 1} => 4
             }

      # The same mesh keeps its group ids.
      {:ok, :same_mesh} = Store.replace(other_mesh(), [], ctx.store)
      assert %{{:group, 1} => 4} = Store.device_ids(ctx.store)
    end

    test "are written in the same insert as their inventory", ctx do
      test_pid = self()
      n = System.unique_integer([:positive])

      store =
        start_store(Path.join(ctx.tmp_dir, "spy.dets"), :"spy_#{n}",
          id: :spy,
          write_fun: fn table, records ->
            send(test_pid, {:write, Enum.map(records, &elem(&1, 0))})
            with :ok <- :dets.insert(table, records), do: :dets.sync(table)
          end
        )

      {:ok, _} = Store.replace(inventory(), [], store)
      assert_received {:write, keys}
      assert [:inventory, :device_ids, :next_device_id | _] = keys
      refute_received {:write, _}

      :ok = Store.clear(store)
      assert_received {:write, [:inventory, :device_ids, :seq_floors, :revision]}
      refute_received {:write, _}
    end

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

  describe "inventory_summary" do
    test "key-free bulbs and groups with their sub-device ids", ctx do
      assert {:ok, %{bulbs: [], groups: [], device_ids: %{}}} =
               Store.inventory_summary(ctx.store)

      {:ok, _} = Store.replace(inventory(), [], ctx.store)
      assert {:ok, summary} = Store.inventory_summary(ctx.store)

      assert summary.bulbs == [
               %{mac: @mac2, label: "path light 2"},
               %{mac: @mac3, label: "post spot 1"}
             ]

      assert summary.groups == [%{local_id: 1, name: "path and post"}]
      assert summary.device_ids == Store.device_ids(ctx.store)
      assert map_size(summary.device_ids) == 3
      refute_secrets(summary)
    end

    test "unavailable or invalid is an error, not an empty inventory", ctx do
      down = :"down_#{System.unique_integer([:positive])}"
      assert {:error, :unavailable} = Store.inventory_summary(down)

      :ok = :dets.insert(ctx.table, {:inventory, %{"beaconKey" => "nope"}})
      assert {:error, :invalid_inventory} = Store.inventory_summary(ctx.store)
    end
  end

  describe "revision" do
    defp revision(store) do
      {:ok, %{revision: revision}} = Store.preview(inventory(), store)
      revision
    end

    test "bumps on uploads, group changes and clears; not on seq-only writes", ctx do
      assert revision(ctx.store) == 0

      {:ok, _} = Store.replace(inventory(), [], ctx.store)
      assert revision(ctx.store) == 1

      :ok = Store.persist(%{inventory() | seq: 132}, ctx.store)
      :ok = Store.tighten(%{inventory() | seq: 101}, 132, ctx.store)
      {:ok, _} = Store.allocate_device_ids([{:group, 7}], ctx.store)
      :ok = Store.put_settings(%{min_mireds: 200}, ctx.store)
      assert revision(ctx.store) == 1

      :ok = Store.persist(%{inventory() | seq: 140, groups: []}, ctx.store)
      assert revision(ctx.store) == 2

      {:ok, _} = Store.replace(inventory(), [], ctx.store)
      assert revision(ctx.store) == 3

      :ok = Store.clear(ctx.store)
      assert revision(ctx.store) == 4
      # Nothing to clear: no write.
      :ok = Store.clear(ctx.store)
      assert revision(ctx.store) == 4

      # Persisted.
      assert revision(restart_store(ctx)) == 4
    end

    test "replace with a stale expected_revision writes nothing and returns a fresh preview",
         ctx do
      {:ok, %{revision: seen}} = Store.preview(inventory(), ctx.store)
      # Another writer lands between the preview and the replace.
      {:ok, _} = Store.replace(other_mesh(%{"seq" => 7}), [], ctx.store)

      assert {:error, {:stale_preview, fresh}} =
               Store.replace(
                 inventory(),
                 [allow_new_mesh: true, expected_revision: seen],
                 ctx.store
               )

      assert %{mesh: :new_mesh, revision: 1} = fresh
      refute_secrets(fresh)
      assert {:ok, %Inventory{seq: 7}} = Store.load(ctx.store)

      assert {:ok, :new_mesh} =
               Store.replace(
                 inventory(),
                 [allow_new_mesh: true, expected_revision: fresh.revision],
                 ctx.store
               )

      assert {:ok, %Inventory{seq: 100}} = Store.load(ctx.store)
    end
  end

  describe "inventory change notifications" do
    test "on uploads, group changes and clears; not on seq-only writes", ctx do
      pubsub = :"store_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub})
      Phoenix.PubSub.subscribe(pubsub, Store.topic())

      store =
        start_store(Path.join(ctx.tmp_dir, "n.dets"), :"n_#{System.unique_integer()}",
          id: :notifying,
          pubsub: pubsub
        )

      {:ok, _} = Store.replace(inventory(), [], store)
      assert_receive {:tuya_mesh_store, :inventory_changed}

      :ok = Store.persist(%{inventory() | seq: 132}, store)
      :ok = Store.tighten(%{inventory() | seq: 101}, 132, store)
      refute_receive {:tuya_mesh_store, _}, 50

      :ok = Store.persist(%{inventory() | seq: 140, groups: []}, store)
      assert_receive {:tuya_mesh_store, :inventory_changed}

      :ok = Store.clear(store)
      assert_receive {:tuya_mesh_store, :inventory_changed}
      :ok = Store.clear(store)
      refute_receive {:tuya_mesh_store, _}, 50
    end

    test "settings changes, once written", ctx do
      pubsub = :"store_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub})
      Phoenix.PubSub.subscribe(pubsub, Store.topic())

      store =
        start_store(Path.join(ctx.tmp_dir, "s.dets"), :"s_#{System.unique_integer()}",
          id: :settings_notifying,
          pubsub: pubsub
        )

      :ok = Store.put_settings(%{max_mireds: 400}, store)
      assert_receive {:tuya_mesh_store, :settings_changed}

      # Unchanged or invalid: nothing written, nothing sent.
      :ok = Store.put_settings(%{max_mireds: 400}, store)
      {:error, :invalid_settings} = Store.put_settings(%{min_mireds: 999}, store)
      refute_receive {:tuya_mesh_store, _}, 50
    end
  end

  describe "redaction of every inventory representation" do
    alias UniversalProxy.TuyaMesh.KeyLeak

    test "JSON and snake_case requests stay out of :sys status and debug logs", ctx do
      :ok = :sys.log(ctx.store, true)

      assert {:ok, _} = Store.replace(KeyLeak.json(), [], ctx.store)
      assert :same_mesh = Store.classify(KeyLeak.snake_map(), ctx.store)
      assert {:ok, _} = Store.preview(KeyLeak.snake_map(), ctx.store)
      _ = Store.persist(KeyLeak.json(), ctx.store)
      _ = Store.tighten(KeyLeak.snake_map(), 100, ctx.store)
      # Replies are logged too: load answers with the whole inventory.
      assert {:ok, %Inventory{beacon_key: "0011" <> _}} = Store.load(ctx.store)

      KeyLeak.refute_keys(:sys.get_status(ctx.store))
    end

    test "a crash mid-request, with requests queued, leaks no key", ctx do
      store =
        start_store(Path.join(ctx.tmp_dir, "q.dets"), :"q_#{System.unique_integer()}",
          id: :queued,
          write_fun: fn _table, records ->
            Process.sleep(150)
            apply(__MODULE__, :explode, [records])
          end
        )

      log =
        capture_log(fn ->
          spawn(fn -> catch_exit(GenServer.call(store, {:replace, KeyLeak.json(), []})) end)
          Process.sleep(30)

          # Queued behind the crashing call.
          for request <- [{:replace, KeyLeak.snake_map(), []}, {:classify, KeyLeak.json()}] do
            spawn(fn -> catch_exit(GenServer.call(store, request)) end)
          end

          Process.sleep(400)
        end)

      assert log =~ "TuyaMesh.Store: FunctionClauseError raised"
      KeyLeak.refute_keys(log)
    end

    test "format_status redacts by request shape and by representation" do
      json = KeyLeak.json()
      snake = KeyLeak.snake_map()
      from = {self(), make_ref()}

      status =
        Store.format_status(%{
          state: %{table: :t},
          message: {:"$gen_call", from, {:persist, json, {:tighten, 132}}},
          queue: [
            {:"$gen_call", from, {:replace, snake, [allow_new_mesh: true]}},
            {:"$gen_call", from, {:preview, json}},
            # Shapes the store doesn't know still lose what looks like keys.
            {:unknown, json, snake, String.to_charlist(json)}
          ],
          log: [{:in, {:"$gen_call", from, {:classify, snake}}}],
          reason: {{:badmatch, json}, [{Store, :x, [snake], []}]}
        })

      KeyLeak.refute_keys(status)
      assert {:"$gen_call", _, {:persist, :redacted, {:tighten, 132}}} = status.message
      assert [{:"$gen_call", _, {:replace, :redacted, [allow_new_mesh: true]}} | _] = status.queue
    end
  end

  describe "redaction" do
    # Fails with the records (keys and all) as its arguments, as a BIF
    # refusing them would.
    def explode(%{never: _}), do: :ok

    test "a crash in a call leaves no key in the reports", ctx do
      store =
        start_store(Path.join(ctx.tmp_dir, "x.dets"), :"x_#{System.unique_integer()}",
          id: :exploding,
          write_fun: fn _table, records -> apply(__MODULE__, :explode, [records]) end
        )

      log =
        capture_log(fn ->
          catch_exit(GenServer.call(store, {:replace, inventory(), []}))
          Process.sleep(50)
        end)

      assert log =~ "TuyaMesh.Store: FunctionClauseError raised"
      refute_secrets(log)
    end

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
