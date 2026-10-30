defmodule UniversalProxy.TuyaBeaconMesh.InventoryTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.TuyaBeaconMesh.Inventory

  @fixture Path.join([
             __DIR__,
             "..",
             "..",
             "fixtures",
             "tuya_beacon_mesh",
             "example_inventory.json"
           ])

  @mesh_key "00112233445566778899aabbccddeeff"

  defp base, do: @fixture |> File.read!() |> Jason.decode!()

  defp with_bulb(index, fun), do: update_in(base(), ["bulbs", Access.at(index)], fun)

  test "decodes the example inventory fixture" do
    json = File.read!(@fixture)
    assert {:ok, inv} = Inventory.decode(json)
    assert inv.beacon_key == @mesh_key
    assert inv.seq == 100
    assert length(inv.bulbs) == 2
    assert hd(inv.bulbs).mac == "DC23530FB34A"
    assert hd(inv.bulbs).label == "path light 2"
    assert hd(inv.bulbs).beacon_key == @mesh_key
    assert hd(inv.groups).local_id == 1
    assert hd(inv.groups).members == ["DC23530FB34A", "DC23533FCD62"]
  end

  test "rejects duplicate node ids and missing keys" do
    bad = with_bulb(1, &Map.put(&1, "nodeId", 2))

    assert {:error, {:duplicate_node_id, 2, "DC23533FCD62"}} = Inventory.decode(bad)
    assert {:error, :missing_beacon_key} = Inventory.decode(%{"bulbs" => []})
    assert {:error, :no_bulbs} = Inventory.decode(%{"beaconKey" => @mesh_key})
  end

  test "normalises MAC formatting and atom keys" do
    assert {:ok, inv} =
             Inventory.decode(%{
               beacon_key: @mesh_key,
               bulbs: [%{mac: "dc:23:53:0f:b3:4a", local_key: "abcdefghijklmnop", node_id: 2}]
             })

    assert hd(inv.bulbs).mac == "DC23530FB34A"
  end

  describe "keys" do
    test "a 32-char key must be hex, a 16-char one printable ASCII" do
      not_hex = "00112233445566778899aabbccddeeZZ"

      assert {:error, :bad_beacon_key} = Inventory.decode(Map.put(base(), "beaconKey", not_hex))

      assert {:error, {:bad_local_key, "DC23530FB34A"}} =
               Inventory.decode(with_bulb(0, &Map.put(&1, "localKey", not_hex)))

      assert {:error, {:bad_bulb_beacon_key, "DC23530FB34A"}} =
               Inventory.decode(with_bulb(0, &Map.put(&1, "beaconKey", not_hex)))

      # 16 bytes, but 8 two-byte UTF-8 characters.
      multibyte = String.duplicate("é", 8)
      assert byte_size(multibyte) == 16

      assert {:error, {:bad_local_key, _}} =
               Inventory.decode(with_bulb(0, &Map.put(&1, "localKey", multibyte)))

      assert {:error, {:bad_local_key, _}} =
               Inventory.decode(with_bulb(0, &Map.put(&1, "localKey", "short")))

      assert {:error, {:missing_local_key, _}} =
               Inventory.decode(with_bulb(0, &Map.delete(&1, "localKey")))

      assert {:error, :bad_beacon_key} = Inventory.decode(Map.put(base(), "beaconKey", 42))
    end

    test "mixed-case hex and a per-bulb beaconKey are accepted" do
      upper = String.upcase(@mesh_key)
      own = "ffeeddccbbaa99887766554433221100"

      assert {:ok, inv} =
               base()
               |> Map.put("beaconKey", upper)
               |> put_in(["bulbs", Access.at(1), "beaconKey"], own)
               |> Inventory.decode()

      assert [%{beacon_key: ^upper}, %{beacon_key: ^own}] = inv.bulbs
    end

    test "Inspect leaves every key out" do
      inv = Inventory.decode!(File.read!(@fixture))
      text = inspect(inv)

      refute text =~ @mesh_key
      refute text =~ "abcdefghijklmnop"
      refute text =~ "ponmlkjihgfedcba"
      assert text =~ "DC23530FB34A"
    end
  end

  describe "node ids, labels and groups" do
    test "node ids must be unicast addresses" do
      for bad <- [0x8000, 0x8001, 0xFF01, 0xFFFF, 70_000, -1, "x", "2x", 1.5] do
        assert {:error, {:bad_node_id, "DC23530FB34A"}} =
                 Inventory.decode(with_bulb(0, &Map.put(&1, "nodeId", bad))),
               "accepted #{inspect(bad)}"
      end

      assert {:ok, %{bulbs: [%{node_id: 0x7FFF} | _]}} =
               Inventory.decode(with_bulb(0, &Map.put(&1, "nodeId", "32767")))

      assert {:error, {:missing_node_id, _}} =
               Inventory.decode(with_bulb(0, &Map.delete(&1, "nodeId")))
    end

    test "duplicate MACs and labels are rejected" do
      assert {:error, {:duplicate_mac, "DC23530FB34A"}} =
               Inventory.decode(with_bulb(1, &Map.put(&1, "mac", "dc:23:53:0f:b3:4a")))

      assert {:error, {:duplicate_label, "DC23533FCD62"}} =
               Inventory.decode(with_bulb(1, &Map.put(&1, "label", "path light 2")))

      assert {:error, :bad_mac} = Inventory.decode(with_bulb(1, &Map.put(&1, "mac", "nope")))
      assert {:error, :bad_bulb} = Inventory.decode(Map.put(base(), "bulbs", ["x"]))
    end

    test "a label that is another bulb's MAC is rejected, in either order" do
      # Bulb 0 is DC23530FB34A, bulb 1 is DC23533FCD62 (example inventory).
      assert {:error, {:label_is_other_mac, "DC23530FB34A"}} =
               Inventory.decode(with_bulb(0, &Map.put(&1, "label", "dc:23:53:3f:cd:62")))

      assert {:error, {:label_is_other_mac, "DC23533FCD62"}} =
               Inventory.decode(with_bulb(1, &Map.put(&1, "label", "DC23530FB34A")))

      # A bulb labelled with its own MAC still addresses only itself.
      assert {:ok, _inv} = Inventory.decode(with_bulb(1, &Map.put(&1, "label", "DC23533FCD62")))
    end

    test "groups: ids, names, members" do
      group = %{"localId" => 2, "name" => "post", "members" => ["DC23533FCD62"]}
      groups = fn extra -> Map.put(base(), "groups", base()["groups"] ++ [extra]) end

      assert {:ok, %{groups: [_, %{local_id: 2}]}} = Inventory.decode(groups.(group))

      assert {:error, {:duplicate_group_id, 1}} =
               Inventory.decode(groups.(%{group | "localId" => 1}))

      assert {:error, {:duplicate_group_name, 2}} =
               Inventory.decode(groups.(%{group | "name" => "path and post"}))

      # FF FF is broadcast.
      assert {:error, :bad_group} = Inventory.decode(groups.(%{group | "localId" => 255}))
      assert {:error, :bad_group} = Inventory.decode(groups.(%{group | "localId" => "2"}))
      assert {:error, :bad_group} = Inventory.decode(groups.(%{group | "members" => "x"}))
      assert {:error, :bad_group} = Inventory.decode(groups.("x"))
      assert {:error, :bad_groups} = Inventory.decode(Map.put(base(), "groups", %{}))

      assert {:error, {:unknown_group_member, 2, "AABBCCDDEEFF"}} =
               Inventory.decode(groups.(%{group | "members" => ["aa:bb:cc:dd:ee:ff"]}))

      assert {:error, {:bad_group_member, 2, 1}} =
               Inventory.decode(groups.(%{group | "members" => ["DC23533FCD62", 7]}))

      # Repeated members collapse.
      assert {:ok, %{groups: [_, %{members: ["DC23533FCD62"]}]}} =
               Inventory.decode(groups.(%{group | "members" => ["DC23533FCD62", "dc23533fcd62"]}))
    end
  end

  describe "errors carry no input" do
    test "a group member that is a whole bulb object is reported by position" do
      [bulb | _] = base()["bulbs"]
      bulb = Map.put(bulb, "beaconKey", @mesh_key)
      group = %{"localId" => 2, "name" => "post", "members" => ["DC23533FCD62", bulb]}
      inv = Map.put(base(), "groups", base()["groups"] ++ [group])

      assert {:error, {:bad_group_member, 2, 1} = reason} = Inventory.decode(inv)
      refute inspect(reason) =~ "abcdefghijklmnop"

      error = assert_raise ArgumentError, fn -> Inventory.decode!(inv) end
      refute Exception.message(error) =~ "abcdefghijklmnop"
      refute Exception.message(error) =~ @mesh_key
    end

    test "no error tuple echoes a key placed in a name or member field" do
      secret = "ponmlkjihgfedcba"

      inputs = [
        with_bulb(1, &Map.put(&1, "label", "path light 2")),
        with_bulb(0, &Map.put(&1, "label", %{"k" => secret})),
        Map.put(base(), "groups", [
          %{"localId" => 1, "name" => secret},
          %{"localId" => 2, "name" => secret}
        ]),
        Map.put(base(), "groups", [%{"localId" => 1, "name" => [secret]}]),
        Map.put(base(), "groups", [%{"localId" => 1, "members" => [secret]}]),
        # 12 hex digits inside a 16-char key are not a MAC.
        Map.put(base(), "groups", [%{"localId" => 1, "members" => ["a1b2c3d4e5f6wxyz"]}]),
        with_bulb(0, &Map.put(&1, "mac", "a1b2c3d4e5f6wxyz")),
        Map.put(base(), "groups", [%{"localId" => 1, "members" => [%{"localKey" => secret}]}])
      ]

      for input <- inputs do
        assert {:error, reason} = Inventory.decode(input)
        refute inspect(reason) =~ secret, "leaked in #{inspect(reason)}"
        refute inspect(reason) =~ "A1B2C3D4E5F6", "leaked in #{inspect(reason)}"
      end
    end
  end

  describe "present values" do
    test "a present false or null is validated, not read as absent" do
      for bad <- [false, nil, true, -1, 65_536, "5"] do
        assert {:error, :bad_seq} = Inventory.decode(Map.put(base(), "seq", bad)),
               "accepted seq #{inspect(bad)}"
      end

      # A false "seq" is not skipped in favour of a later alias.
      assert {:error, :bad_seq} =
               base() |> Map.put("seq", false) |> Map.put("seq_reserved", 7) |> Inventory.decode()

      assert {:error, :bad_seq} = Inventory.decode(%{seq: false, beacon_key: @mesh_key})
      assert {:ok, %{seq: 0}} = Inventory.decode(Map.delete(base(), "seq"))
    end

    test "false in any other field is rejected" do
      assert {:error, :bad_beacon_key} = Inventory.decode(Map.put(base(), "beaconKey", false))
      assert {:error, :bad_beacon_key} = Inventory.decode(Map.put(base(), "beaconKey", nil))
      assert {:error, :bad_bulbs} = Inventory.decode(Map.put(base(), "bulbs", false))
      assert {:error, :bad_groups} = Inventory.decode(Map.put(base(), "groups", false))
      assert {:error, :bad_mac} = Inventory.decode(with_bulb(0, &Map.put(&1, "mac", false)))

      assert {:error, {:bad_local_key, "DC23530FB34A"}} =
               Inventory.decode(with_bulb(0, &Map.put(&1, "localKey", false)))

      assert {:error, {:bad_node_id, "DC23530FB34A"}} =
               Inventory.decode(with_bulb(0, &Map.put(&1, "nodeId", false)))

      assert {:error, {:bad_bulb_beacon_key, "DC23530FB34A"}} =
               Inventory.decode(with_bulb(0, &Map.put(&1, "beaconKey", false)))

      assert {:error, {:bad_label, "DC23530FB34A"}} =
               Inventory.decode(with_bulb(0, &Map.put(&1, "label", false)))

      group = %{"localId" => 1, "name" => "g", "members" => []}
      groups = &Map.put(base(), "groups", [&1])

      assert {:error, :bad_group} = Inventory.decode(groups.(%{group | "localId" => false}))
      assert {:error, :bad_group} = Inventory.decode(groups.(%{group | "members" => false}))

      assert {:error, {:bad_group_name, 1}} =
               Inventory.decode(groups.(%{group | "name" => false}))

      assert {:error, {:bad_group_member, 1, 0}} =
               Inventory.decode(groups.(%{group | "members" => [false]}))
    end

    test "null reads as absent for the optional fields" do
      assert {:ok, %{bulbs: [%{label: nil, beacon_key: @mesh_key} | _], groups: []}} =
               base()
               |> Map.put("groups", nil)
               |> put_in(["bulbs", Access.at(0), "label"], nil)
               |> put_in(["bulbs", Access.at(0), "beaconKey"], nil)
               |> Inventory.decode()

      assert {:ok, %{groups: [%{name: nil, members: []}]}} =
               Inventory.decode(
                 Map.put(base(), "groups", [%{"localId" => 1, "name" => nil, "members" => nil}])
               )
    end
  end

  describe "input" do
    test "bad JSON, non-maps and oversized dumps" do
      assert {:error, {:invalid_json, _position}} = Inventory.decode(~s({"beaconKey": ))
      assert {:error, :not_a_map} = Inventory.decode([1, 2])
      assert {:error, :not_a_map} = Inventory.decode(nil)

      huge = Jason.encode!(Map.put(base(), "pad", String.duplicate("x", 70_000)))
      assert {:error, :too_large} = Inventory.decode(huge)

      assert_raise ArgumentError, ~r/bad inventory/, fn -> Inventory.decode!("[]") end
    end

    test "an invalid-JSON error carries no part of the input" do
      json = ~s({"beaconKey": "#{@mesh_key}", "bulbs": [)
      assert {:error, reason} = Inventory.decode(json)
      refute inspect(reason) =~ @mesh_key
    end

    test "a decoded inventory round-trips and is re-validated" do
      inv = Inventory.decode!(File.read!(@fixture))

      assert {:ok, ^inv} = Inventory.decode(inv)
      assert {:ok, ^inv} = inv |> Inventory.to_map() |> Inventory.decode()

      [b1, b2] = inv.bulbs
      twins = %{inv | bulbs: [b1, %{b2 | node_id: b1.node_id}]}
      assert {:error, {:duplicate_node_id, 2, _}} = Inventory.decode(twins)

      bad_key = %{inv | bulbs: [%{b1 | local_key: "not a key"}, b2]}
      assert {:error, {:bad_local_key, _}} = Inventory.decode(bad_key)
    end
  end
end
