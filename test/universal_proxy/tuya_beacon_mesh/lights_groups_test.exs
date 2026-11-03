defmodule UniversalProxy.TuyaBeaconMesh.LightsGroupsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias UniversalProxy.TuyaBeaconMesh.{Carrier, Crypto, FakeBluez, Inventory, Lights, P2, Radio}
  alias UniversalProxy.TuyaMesh
  alias UniversalProxy.TuyaMesh.{KeyLeak, Store}

  @fixture Path.join([
             __DIR__,
             "..",
             "..",
             "fixtures",
             "tuya_beacon_mesh",
             "example_inventory.json"
           ])

  @beacon_key "00112233445566778899aabbccddeeff"
  @local2 "abcdefghijklmnop"
  @local3 "ponmlkjihgfedcba"
  @mac2 "DC23530FB34A"
  @mac3 "DC23533FCD62"
  @addr2 0xDC23530FB34A
  @addr3 0xDC23533FCD62

  setup context do
    FakeBluez.ensure_started()
    FakeBluez.reset()
    start_supervised!(radio_spec())

    table = :ets.new(:lights_groups_persist, [:public, :set])
    :ets.insert(table, [{:writes, 0}])

    opts =
      [
        inventory: inventory(Map.get(context, :inventory)),
        radio: Radio,
        on_persist: persist_to(table),
        group_confirm_ms: Map.get(context, :confirm_ms, 60_000),
        group_retry_ms: Map.get(context, :retry_ms, 1_000)
      ]

    start_supervised!({Lights, opts})
    {:ok, _} = Radio.status()
    {:ok, _} = Lights.all()
    {:ok, table: table}
  end

  describe "create_group" do
    test "takes the lowest free id, persists, then asks each member to join", %{table: table} do
      assert {:ok, 2} = Lights.create_group("  porch  ", ["path light 2", @mac3])

      # Persisted before anything was sent, trimmed name, members by MAC.
      assert %Inventory{groups: [_, %{local_id: 2, name: "porch", members: [@mac2, @mac3]}]} =
               last_persisted(table)

      assert {:ok, %{groups: [%{local_id: 1}, %{local_id: 2, deleted: false} = g]}} =
               Lights.groups()

      assert g.sync == %{
               @mac2 => %{op: :add, state: :pending},
               @mac3 => %{op: :add, state: :pending}
             }

      # Two in flight: one on air, one queued behind it.
      wait_until(fn -> length(advertises()) == 1 end)
      finish_tx()

      assert [{2, <<0xA1, 2>>}, {3, <<0xA1, 2>>}] = Enum.map(advertises(), &open_unicast/1)
      # The group now resolves by name and takes group commands.
      assert :ok = Lights.group_set("porch", on: true)
    end

    test "skips ids in use, reported by a bulb or with unfinished changes" do
      # Node 2 reports holding 2 and 3 (e.g. set by the Tuya app).
      inject_report(2, 1, <<0xA3, 2, 3>>, @addr2)
      wait_until(fn -> match?({:ok, %{groups: [2, 3]}}, Lights.status(@mac2)) end)

      assert {:ok, 4} = Lights.create_group("a", [])
      assert {:ok, 5} = Lights.create_group("b", ["post spot 1"])

      # A deleted group's id stays taken while its removal is unconfirmed.
      assert :ok = Lights.delete_group(5)
      assert {:ok, 6} = Lights.create_group("c", [])

      # Once confirmed, it is free again, and the new group starts clean.
      inject_report(3, 1, <<0xA3, 1>>, @addr3)
      wait_until(fn -> match?({:ok, %{groups: [%{}, %{}, %{}]}}, Lights.groups()) end)
      assert {:ok, 5} = Lights.create_group("d", [])
      assert {:ok, %{groups: groups}} = Lights.groups()
      assert %{local_id: 5, name: "d", sync: sync} = Enum.find(groups, &(&1.local_id == 5))
      assert sync == %{}
    end

    @tag inventory: :full
    test "every id taken is :no_free_group_id", %{table: table} do
      assert {:error, :no_free_group_id} = Lights.create_group("one more", [])
      assert writes(table) == 0
    end

    test "names: non-blank, at most 64 characters, unique", %{table: table} do
      for bad <- ["", "   ", nil, 7, String.duplicate("x", 65), <<0xFF>>] do
        assert {:error, :bad_group_name} = Lights.create_group(bad, []), inspect(bad)
      end

      assert {:error, :duplicate_group_name} = Lights.create_group("path and post", [])
      assert {:error, :duplicate_group_name} = Lights.create_group(" path and post ", [])
      assert {:ok, _} = Lights.create_group(String.duplicate("x", 64), [])

      assert {:error, :unknown_bulb} = Lights.create_group("x", ["nobody"])
      assert {:error, :bad_members} = Lights.create_group("x", :all)
      assert {:error, :bad_members} = Lights.create_group("x", [@mac2 | @mac3])
      assert writes(table) == 1
    end
  end

  describe "slot limit" do
    test "a bulb already in 8 groups is refused before anything is written or sent", %{
      table: table
    } do
      inject_report(2, 1, <<0xA3, 1, 3, 4, 5, 6, 7, 8, 9>>, @addr2)

      wait_until(fn ->
        match?({:ok, %{groups: [_, _, _, _, _, _, _, _]}}, Lights.status(@mac2))
      end)

      assert {:error, {:group_slots_full, @mac2}} =
               Lights.create_group("ninth", ["post spot 1", "path light 2"])

      assert {:ok, gid} = Lights.create_group("ninth", ["post spot 1"])
      # Its frame takes a lease (a write) once the call returned.
      wait_until(fn -> length(advertises()) == 1 end)
      writes = writes(table)
      sent = length(advertises())
      assert {:error, {:group_slots_full, @mac2}} = Lights.add_member(gid, @mac2)
      assert writes(table) == writes
      Process.sleep(50)
      assert length(advertises()) == sent

      # A group it already holds is no new slot.
      assert :ok = Lights.add_member(1, @mac2)
      assert {:ok, %{slots: %{@mac2 => 8, @mac3 => 2}}} = Lights.groups()
    end

    test "an unconfirmed removal still counts as held" do
      inject_report(2, 1, <<0xA3, 1, 3, 4, 5, 6, 7, 8>>, @addr2)
      wait_until(fn -> match?({:ok, %{groups: [_, _, _, _, _, _, _]}}, Lights.status(@mac2)) end)

      assert {:ok, 2} = Lights.create_group("eighth", ["path light 2"])
      assert :ok = Lights.remove_member(2, @mac2)
      assert {:ok, %{slots: %{@mac2 => 8}}} = Lights.groups()
      assert {:error, {:group_slots_full, @mac2}} = Lights.create_group("ninth", [@mac2])
    end
  end

  describe "confirmation" do
    @tag confirm_ms: 150
    test "an A3 list confirms; silence is unconfirmed; a late list still confirms" do
      assert {:ok, 2} = Lights.create_group("porch", [@mac2, @mac3])
      wait_until(fn -> length(advertises()) == 1 end)

      # A list that doesn't show the group confirms nothing.
      inject_report(2, 1, <<0xA3, 1>>, @addr2)
      inject_report(2, 2, <<0xA3, 1, 2>>, @addr2)
      wait_until(fn -> sync(2, @mac2) == %{op: :add, state: :confirmed} end)
      assert sync(2, @mac3) == %{op: :add, state: :pending}

      wait_until(fn -> sync(2, @mac3) == %{op: :add, state: :unconfirmed} end)
      # The confirmed one stays confirmed.
      assert sync(2, @mac2).state == :confirmed

      inject_report(3, 1, <<0xA3, 2, 1>>, @addr3)
      wait_until(fn -> sync(2, @mac3) == %{op: :add, state: :confirmed} end)
    end

    test "a list from another bulb, or one held for re-anchoring, confirms nothing" do
      assert {:ok, 2} = Lights.create_group("porch", [@mac2])
      wait_until(fn -> length(advertises()) == 1 end)

      inject_report(3, 1, <<0xA3, 2>>, @addr3)
      # Bulb 2's tracker sits at 10; 9 is stale and ignored.
      inject_report(2, 10, <<0x01>>, @addr2)
      inject_report(2, 9, <<0xA3, 2>>, @addr2)
      wait_until(fn -> match?({:ok, %{last_event: {:group_list, [2]}}}, Lights.status(@mac3)) end)
      Process.sleep(30)
      assert sync(2, @mac2).state == :pending
    end

    test "remove_member asks the bulb to leave; a list without the group confirms", %{
      table: table
    } do
      assert :ok = Lights.remove_member("path and post", "post spot 1")
      assert %Inventory{groups: [%{members: [@mac2]}]} = last_persisted(table)
      wait_until(fn -> length(advertises()) == 1 end)
      assert [{3, <<0xA2, 1>>}] = Enum.map(advertises(), &open_unicast/1)

      inject_report(3, 1, <<0xA3, 1>>, @addr3)
      Process.sleep(30)
      assert sync(1, @mac3) == %{op: :remove, state: :pending}

      inject_report(3, 2, <<0xA3, 0>>, @addr3)
      wait_until(fn -> sync(1, @mac3) == %{op: :remove, state: :confirmed} end)

      {:ok, solo} = Lights.create_group("solo", [@mac2])
      assert {:error, :not_member} = Lights.remove_member(solo, @mac3)
      assert {:error, :unknown_bulb} = Lights.remove_member(1, "nobody")
      assert {:error, :unknown_group} = Lights.remove_member(9, @mac2)
    end

    @tag confirm_ms: 100
    test "repeating a change re-sends it" do
      assert {:ok, 2} = Lights.create_group("porch", [@mac2])
      wait_until(fn -> sync(2, @mac2).state == :unconfirmed end)
      :ok = Radio.stop_tx()

      before = length(advertises())
      assert :ok = Lights.add_member(2, @mac2)
      assert sync(2, @mac2).state == :pending
      wait_until(fn -> length(advertises()) == before + 1 end)
      assert {2, <<0xA1, 2>>} = advertises() |> List.last() |> open_unicast()
    end
  end

  describe "pacing and retries" do
    @tag retry_ms: 20
    @tag :capture_log
    test "a refused frame is retried until the radio takes it" do
      FakeBluez.fail(:advertise, :busy)
      assert {:ok, 2} = Lights.create_group("porch", [@mac2])
      Process.sleep(60)
      assert sync(2, @mac2).state == :pending
      FakeBluez.succeed(:advertise)

      wait_until(fn -> Enum.any?(advertises(), &(open_unicast(&1) == {2, <<0xA1, 2>>})) end)
      assert sync(2, @mac2).state == :pending
    end

    @tag retry_ms: 1
    @tag :capture_log
    test "a frame that can't be sent after 8 attempts is unconfirmed" do
      FakeBluez.fail(:advertise, :busy)
      assert {:ok, 2} = Lights.create_group("porch", [@mac2])
      wait_until(fn -> sync(2, @mac2).state == :unconfirmed end)
      FakeBluez.succeed(:advertise)
    end

    test "at most two changes wait for their lists at a time" do
      assert {:ok, 2} = Lights.create_group("a", [@mac2, @mac3])
      assert {:ok, 3} = Lights.create_group("b", [@mac2])
      wait_until(fn -> length(advertises()) == 1 end)
      assert {:ok, %{queued: 1}} = Radio.status()

      # The third goes once a list settles one of the first two.
      inject_report(2, 1, <<0xA3, 1, 2>>, @addr2)
      wait_until(fn -> match?({:ok, %{queued: 2}}, Radio.status()) end)
    end
  end

  describe "delete_group" do
    test "asks every holder to leave; tracked until all confirm", %{table: table} do
      # Bulb 3 isn't a member of 1 but reports holding it.
      :ok = Lights.remove_member(1, @mac3)
      wait_until(fn -> length(advertises()) == 1 end)
      inject_report(3, 1, <<0xA3, 1>>, @addr3)
      wait_until(fn -> match?({:ok, %{groups: [1]}}, Lights.status(@mac3)) end)
      :ok = Radio.stop_tx()

      before = length(advertises())
      assert :ok = Lights.delete_group("path and post")
      assert %Inventory{groups: []} = last_persisted(table)
      assert {:error, :unknown_group} = Lights.group_set(1, on: true)

      wait_until(fn -> length(advertises()) == before + 1 end)
      finish_tx()
      sent = advertises() |> Enum.drop(before) |> Enum.map(&open_unicast/1)
      assert Enum.sort(sent) == [{2, <<0xA2, 1>>}, {3, <<0xA2, 1>>}]

      assert {:ok, %{groups: [%{local_id: 1, deleted: true, members: [], sync: sync}]}} =
               Lights.groups()

      assert sync[@mac2] == %{op: :remove, state: :pending}

      inject_report(2, 1, <<0xA3>>, @addr2)
      wait_until(fn -> sync(1, @mac2).state == :confirmed end)
      inject_report(3, 2, <<0xA3>>, @addr3)
      wait_until(fn -> match?({:ok, %{groups: []}}, Lights.groups()) end)
    end

    test "dismiss: true also sends the broadcast dismiss to FF gg" do
      # The dismiss isn't confirmable, so it doesn't wait behind the two.
      assert :ok = Lights.delete_group(1, dismiss: true)
      wait_until(fn -> length(advertises()) == 1 end)
      assert {:ok, %{queued: 2}} = Radio.status()
      finish_tx()
      finish_tx()

      dismiss = advertises() |> List.last() |> Carrier.frames() |> hd()
      assert <<_, 0x80, 0x01, 0xFF, 0x01, _::binary>> = dismiss
      assert open_payload(dismiss, @beacon_key, @beacon_key) == <<0xA2, 1>>
    end

    test "a tracked removal of a deleted group can be re-sent by its id" do
      :ok = Lights.delete_group(1)
      assert :ok = Lights.remove_member(1, @mac2)
      assert {:error, {:bad_option, :dismiss}} = Lights.delete_group(1, dismiss: :yes)
      assert {:error, :unknown_group} = Lights.delete_group(1)
    end
  end

  describe "review fixes" do
    test "deleting a group whose removals all confirmed leaves nothing tracked" do
      :ok = Lights.remove_member(1, @mac2)
      :ok = Lights.remove_member(1, @mac3)
      inject_report(2, 1, <<0xA3>>, @addr2)
      inject_report(3, 1, <<0xA3>>, @addr3)

      wait_until(fn ->
        sync(1, @mac2).state == :confirmed and sync(1, @mac3).state == :confirmed
      end)

      assert :ok = Lights.delete_group(1)
      assert {:ok, %{groups: []}} = Lights.groups()
    end

    @tag retry_ms: 1
    @tag :capture_log
    test "a removal that was never sent still makes its bulb a holder on delete" do
      FakeBluez.fail(:advertise, :busy)
      :ok = Lights.remove_member(1, @mac3)
      wait_until(fn -> sync(1, @mac3) == %{op: :remove, state: :unconfirmed} end)
      FakeBluez.succeed(:advertise)

      assert :ok = Lights.delete_group(1)
      wait_until(fn -> length(advertises()) == 1 end)
      finish_tx()
      sent = Enum.map(advertises(), &open_unicast/1)
      assert Enum.sort(sent) == [{2, <<0xA2, 1>>}, {3, <<0xA2, 1>>}]
    end

    @tag retry_ms: 5
    @tag :capture_log
    test "a change replacing a retrying one gets its own attempts" do
      FakeBluez.fail(:advertise, :busy)
      {:ok, 2} = Lights.create_group("porch", [@mac2])
      wait_until(fn -> :sys.get_state(Lights).group_attempts == 7 end)

      :ok = Lights.remove_member(2, @mac2)
      # Sent at once (and refused): its first attempt, not the add's eighth.
      assert :sys.get_state(Lights).group_attempts == 1
      assert sync(2, @mac2) == %{op: :remove, state: :pending}

      wait_until(fn -> sync(2, @mac2).state == :unconfirmed end)
      FakeBluez.succeed(:advertise)
    end

    test "a same-mesh reload drops unsent changes it contradicts; sent ones stay tracked" do
      {:ok, 2} = Lights.create_group("a", [@mac2, @mac3])
      {:ok, 3} = Lights.create_group("b", [@mac2])
      wait_until(fn -> length(advertises()) == 1 end)
      assert sync(3, @mac2) == %{op: :add, state: :pending}

      # The reloaded inventory has neither new group.
      assert :ok = Lights.reload(fixture())
      assert sync(3, @mac2) == nil

      # Settling an in-flight join frees a slot: the dropped join stays unsent.
      inject_report(2, 1, <<0xA3, 1, 2>>, @addr2)
      wait_until(fn -> sync(2, @mac2).state == :confirmed end)
      finish_tx()
      Process.sleep(30)
      refute Enum.any?(advertises(), &(open_unicast(&1) == {2, <<0xA1, 3>>}))

      # Bulb 3 was sent the join to group 2, so it may hold it: removable.
      assert :ok = Lights.remove_member(2, @mac3)
      assert sync(2, @mac3) == %{op: :remove, state: :pending}
    end
  end

  describe "what a bulb may hold, across same-mesh reloads" do
    test "a bulb's A3 list survives a reload, unless it was re-paired (new keys)" do
      inject_report(2, 1, <<0xA3, 1, 5>>, @addr2)
      wait_until(fn -> match?({:ok, %{groups: [1, 5]}}, Lights.status(@mac2)) end)

      assert :ok = Lights.reload(fixture())
      assert {:ok, %{groups: [1, 5]}} = Lights.status(@mac2)

      assert :ok = Lights.reload(repaired())
      assert {:ok, %{groups: nil}} = Lights.status(@mac2)
    end

    test "a confirmed join keeps its id reserved after a reload dropped the group" do
      {:ok, 2} = Lights.create_group("a", [@mac2])
      inject_report(2, 1, <<0xA3, 1, 2>>, @addr2)
      wait_until(fn -> sync(2, @mac2).state == :confirmed end)

      # Even without the bulb's list (re-paired keys), the join reserves 2.
      assert :ok = Lights.reload(repaired())
      assert {:ok, %{groups: nil}} = Lights.status(@mac2)
      assert {:ok, 3} = Lights.create_group("b", [])
    end

    @tag inventory: :seven
    test "a retained join counts as a slot" do
      {:ok, 8} = Lights.create_group("eighth", [@mac2])
      wait_until(fn -> length(advertises()) == 1 end)

      # The reload drops group 8; its join was sent and may have landed.
      assert :ok = Lights.reload(inventory(:seven))
      assert {:ok, %{slots: %{@mac2 => 8}}} = Lights.groups()
      assert {:error, {:group_slots_full, @mac2}} = Lights.create_group("ninth", [@mac2])
    end

    test "a group a reload dropped stays tracked until its bulbs are known to have left" do
      {:ok, 2} = Lights.create_group("a", [@mac2])
      wait_until(fn -> length(advertises()) == 1 end)
      assert :ok = Lights.reload(fixture())

      # Confirming the join must not forget the group: the bulb holds it.
      inject_report(2, 1, <<0xA3, 1, 2>>, @addr2)
      wait_until(fn -> sync(2, @mac2) == %{op: :add, state: :confirmed} end)
      assert {:ok, %{groups: [_, %{local_id: 2, deleted: true}]}} = Lights.groups()

      :ok = Radio.stop_tx()
      assert :ok = Lights.remove_member(2, @mac2)
      wait_until(fn -> Enum.any?(advertises(), &(open_unicast(&1) == {2, <<0xA2, 2>>})) end)

      inject_report(2, 2, <<0xA3, 1>>, @addr2)
      wait_until(fn -> match?({:ok, %{groups: [%{local_id: 1}]}}, Lights.groups()) end)
    end

    test "a confirmed join a newer list no longer shows is unconfirmed again" do
      {:ok, 2} = Lights.create_group("a", [@mac2])
      inject_report(2, 1, <<0xA3, 1, 2>>, @addr2)
      wait_until(fn -> sync(2, @mac2).state == :confirmed end)

      inject_report(2, 2, <<0xA3, 1>>, @addr2)
      wait_until(fn -> sync(2, @mac2) == %{op: :add, state: :unconfirmed} end)
    end

    @tag retry_ms: 5
    @tag :capture_log
    test "a reload that drops the retrying head gives the next job a fresh budget" do
      FakeBluez.fail(:advertise, :busy)
      {:ok, 2} = Lights.create_group("a", [@mac2])
      {:ok, 3} = Lights.create_group("b", [@mac3])
      wait_until(fn -> :sys.get_state(Lights).group_attempts == 7 end)

      # Group 2 is gone from the reload, group 3 stays.
      b = %{"localId" => 3, "name" => "b", "members" => [@mac3]}
      assert :ok = Lights.reload(Map.update!(fixture(), "groups", &(&1 ++ [b])))

      # The surviving join was tried at once, as its own first attempt.
      assert %{group_attempts: 1, group_jobs: [{3, @mac3}]} = :sys.get_state(Lights)
      assert sync(3, @mac3) == %{op: :add, state: :pending}
      assert sync(2, @mac2) == nil
      FakeBluez.succeed(:advertise)
    end
  end

  describe "rename_group" do
    test "is local: persisted, nothing sent", %{table: table} do
      assert :ok = Lights.rename_group(1, " garden ")
      assert %Inventory{groups: [%{local_id: 1, name: "garden"}]} = last_persisted(table)
      assert :ok = Lights.group_set("garden", on: true)
      wait_until(fn -> length(advertises()) == 1 end)
      assert [<<_, 0x80, 0x01, 0xFF, 0x01, _::binary>>] = Carrier.frames(hd(advertises()))

      # Same name: no write.
      writes = writes(table)
      assert :ok = Lights.rename_group("garden", "garden")
      assert writes(table) == writes

      {:ok, 2} = Lights.create_group("other", [])
      assert {:error, :duplicate_group_name} = Lights.rename_group(2, "garden")
      assert {:error, :bad_group_name} = Lights.rename_group(2, " ")
      assert {:error, :unknown_group} = Lights.rename_group(9, "x")
    end
  end

  describe "persistence failure" do
    test "leaves the inventory, the groups and the radio as they were", %{table: table} do
      {:ok, before_inv} = Lights.inventory()
      {:ok, before_groups} = Lights.groups()
      :ets.insert(table, {:fail, {:error, :enospc}})

      log =
        capture_log(fn ->
          assert {:error, :persist_failed} = Lights.create_group("porch", [@mac2])
          assert {:error, :persist_failed} = Lights.remove_member(1, @mac3)
          assert {:error, :persist_failed} = Lights.delete_group(1, dismiss: true)
          assert {:error, :persist_failed} = Lights.rename_group(1, "garden")
        end)

      assert log =~ "on_persist failed"
      KeyLeak.refute_keys(log)

      assert {:ok, ^before_inv} = Lights.inventory()
      assert {:ok, ^before_groups} = Lights.groups()
      assert {:error, :unknown_group} = Lights.group_set("garden", on: true)
      Process.sleep(30)
      assert advertises() == []
      assert writes(table) == 0
    end

    test "a failed add leaves the member out and sends nothing", %{table: table} do
      :ok = Lights.remove_member(1, @mac3)
      wait_until(fn -> length(advertises()) == 1 end)
      {:ok, before_inv} = Lights.inventory()
      :ets.insert(table, {:fail, :nope})

      capture_log(fn ->
        assert {:error, :persist_failed} = Lights.add_member(1, @mac3)
      end)

      assert {:ok, ^before_inv} = Lights.inventory()
      assert sync(1, @mac3).op == :remove
      Process.sleep(30)
      assert length(advertises()) == 1
    end
  end

  describe "with the host Store and facade" do
    @tag :tmp_dir
    test "group edits persist through Store.persist, which allocates ids and broadcasts", %{
      tmp_dir: tmp_dir
    } do
      pubsub = :"lights_groups_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub})

      store =
        start_supervised!(
          {Store,
           name: nil,
           enabled: true,
           pubsub: pubsub,
           table: :"lights_groups_store_#{System.unique_integer([:positive])}",
           dets_path: Path.join(tmp_dir, "mesh.dets")}
        )

      {:ok, _} = Store.replace(Inventory.decode!(fixture()), [], store)
      Phoenix.PubSub.subscribe(pubsub, Store.topic())

      stop_supervised!(Lights)

      start_supervised!(
        {Lights,
         inventory: fn -> Store.load(store) end,
         radio: Radio,
         on_persist: &Store.persist(&1, store),
         on_tighten: &Store.tighten(&1, &2, store)}
      )

      facade = [lights: Lights]
      assert {:ok, 2} = TuyaMesh.create_group("porch", ["path light 2"], facade)
      assert_receive {:tuya_mesh_store, :inventory_changed}
      assert %{{:group, 1} => 3, {:group, 2} => 4} = Store.device_ids(store)

      assert {:ok, %{groups: [_, %{local_id: 2, sync: %{@mac2 => %{state: :pending}}}]}} =
               TuyaMesh.group_sync(facade)

      assert :ok = TuyaMesh.rename_group("porch", "garden", facade)
      assert :ok = TuyaMesh.add_member("garden", @mac3, facade)
      assert :ok = TuyaMesh.remove_member("garden", @mac2, facade)

      assert {:ok, %Inventory{groups: [_, %{name: "garden", members: [@mac3]}]}} =
               Store.load(store)

      assert %{{:group, 2} => 4} = Store.device_ids(store)

      assert :ok = TuyaMesh.delete_group(2, [dismiss: false] ++ facade)
      assert {:ok, %Inventory{groups: [%{local_id: 1}]}} = Store.load(store)
      refute Map.has_key?(Store.device_ids(store), {:group, 2})
    end
  end

  describe "key material" do
    @tag confirm_ms: 50
    test "group operations log and report no keys" do
      log =
        capture_log(fn ->
          {:ok, 2} = Lights.create_group("porch", [@mac2, @mac3])
          :ok = Lights.delete_group(1, dismiss: true)
          wait_until(fn -> sync(2, @mac2).state == :unconfirmed end)
          {:ok, view} = Lights.groups()
          KeyLeak.refute_keys(view)
          KeyLeak.refute_keys(:sys.get_status(Lights))
        end)

      KeyLeak.refute_keys(log)
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────

  defp radio_spec do
    {Radio,
     adapter_index: 1,
     retry_ms: 20,
     bluez_radio: FakeBluez.Radio,
     mgmt: FakeBluez.Mgmt,
     rebus: FakeBluez.Rebus,
     dbus: FakeBluez.DBus,
     receiver: FakeBluez.Receiver}
  end

  defp fixture, do: @fixture |> File.read!() |> Jason.decode!()

  defp inventory(nil), do: fixture()

  # "path light 2" in groups 1..7, so it has one slot left.
  defp inventory(:seven) do
    groups = for id <- 1..7, do: %{"localId" => id, "name" => "s#{id}", "members" => [@mac2]}
    Map.put(fixture(), "groups", groups)
  end

  # Every allocatable id in use.
  defp inventory(:full) do
    groups = for id <- 1..254, do: %{"localId" => id, "name" => "g#{id}", "members" => []}
    Map.put(fixture(), "groups", groups)
  end

  defp persist_to(table) do
    fn inv ->
      case :ets.lookup(table, :fail) do
        [{:fail, result}] ->
          result

        [] ->
          :ets.insert(table, {:inv, inv})
          :ets.update_counter(table, :writes, 1)
          :ok
      end
    end
  end

  # The fixture with "path light 2" re-paired: a new localKey.
  defp repaired, do: put_in(fixture(), ["bulbs", Access.at(0), "localKey"], "qrstuvwxyzabcdef")

  defp writes(table), do: :ets.lookup_element(table, :writes, 2)
  defp last_persisted(table), do: :ets.lookup_element(table, :inv, 2)

  defp sync(gid, mac) do
    {:ok, %{groups: groups}} = Lights.groups()

    case Enum.find(groups, &(&1.local_id == gid)) do
      %{sync: %{^mac => sync}} -> sync
      _ -> nil
    end
  end

  # A group list (or any report) from `node`, relayed by `address`.
  defp inject_report(node, sn, payload, address) do
    frame = P2.build(1, 2, node, 0x8001, sn, payload, @beacon_key, @beacon_key)
    FakeBluez.inject(%{address: address, data: Carrier.ad_bytes(frame), rssi: -40})
  end

  # {node id, trimmed payload} of a unicast frame to one of the two bulbs.
  defp open_unicast(ad) do
    [<<_hdr, _src::binary-2, dst::16-big, _::binary>> = frame] = Carrier.frames(ad)
    key = if dst == 2, do: @local2, else: @local3
    {dst, open_payload(frame, @beacon_key, key)}
  end

  defp open_payload(frame, mask, key) do
    <<_hdr, _head::binary-7, _payload_crc, masked::binary-16, _crc>> = frame
    cipher = :crypto.exor(masked, Crypto.key_bytes(mask))

    cipher
    |> Crypto.xxtea_decrypt(Crypto.key_bytes(key))
    |> String.trim_trailing(<<0>>)
  end

  defp finish_tx do
    before = length(advertises())
    %{tx_current: %{token: token}} = :sys.get_state(Radio)
    send(Process.whereis(Radio), {:tx_done, token})
    wait_until(fn -> length(advertises()) > before end)
  end

  defp advertises, do: for({:advertise, data, _opts} <- FakeBluez.calls(), do: data)

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
end
