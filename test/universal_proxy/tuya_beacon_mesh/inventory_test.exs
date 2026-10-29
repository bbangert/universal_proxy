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

  test "decodes the example inventory fixture" do
    json = File.read!(@fixture)
    assert {:ok, inv} = Inventory.decode(json)
    assert inv.beacon_key == "00112233445566778899aabbccddeeff"
    assert inv.seq == 100
    assert length(inv.bulbs) == 2
    assert hd(inv.bulbs).mac == "DC23530FB34A"
    assert hd(inv.bulbs).label == "path light 2"
    assert hd(inv.groups).local_id == 1
    assert hd(inv.groups).members == ["DC23530FB34A", "DC23533FCD62"]
  end

  test "rejects duplicate node ids and missing keys" do
    base = Inventory.decode!(File.read!(@fixture))

    bad =
      Inventory.to_map(base)
      |> update_in(["bulbs"], fn [a, b] -> [a, Map.put(b, "nodeId", a["nodeId"])] end)

    assert {:error, {:duplicate_node_id, 2, "DC23533FCD62"}} = Inventory.decode(bad)
    assert {:error, :missing_beacon_key} = Inventory.decode(%{"bulbs" => []})
    assert {:error, :no_bulbs} = Inventory.decode(%{"beaconKey" => String.duplicate("a", 32)})
  end

  test "normalises MAC formatting and atom keys" do
    assert {:ok, inv} =
             Inventory.decode(%{
               beacon_key: "00112233445566778899aabbccddeeff",
               bulbs: [
                 %{
                   mac: "dc:23:53:0f:b3:4a",
                   local_key: "abcdefghijklmnop",
                   node_id: 2
                 }
               ]
             })

    assert hd(inv.bulbs).mac == "DC23530FB34A"
  end
end
