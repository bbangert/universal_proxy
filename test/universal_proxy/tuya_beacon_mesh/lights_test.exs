defmodule UniversalProxy.TuyaBeaconMesh.LightsTest do
  use ExUnit.Case, async: false

  alias UniversalProxy.TuyaBeaconMesh.{Carrier, FakeBluez, Lights, P2, Radio}

  @fixture Path.join([
             __DIR__,
             "..",
             "..",
             "fixtures",
             "tuya_beacon_mesh",
             "example_inventory.json"
           ])

  @beacon_key "00112233445566778899aabbccddeeff"

  setup do
    FakeBluez.ensure_started()
    FakeBluez.reset()

    radio =
      start_supervised!(
        {Radio,
         adapter_index: 1,
         bluez_radio: FakeBluez.Radio,
         mgmt: FakeBluez.Mgmt,
         rebus: FakeBluez.Rebus,
         dbus: FakeBluez.DBus,
         receiver: FakeBluez.Receiver}
      )

    persisted = :ets.new(:lights_persist, [:public, :set])

    start_supervised!(
      {Lights,
       inventory: File.read!(@fixture),
       radio: radio,
       on_persist: fn inv -> :ets.insert(persisted, {:inv, inv}) end}
    )

    # Both servers finish setup in handle_continue; these calls only return
    # once the receiver is registered and Lights has subscribed.
    {:ok, _} = Radio.status()
    {:ok, _} = Lights.all()

    {:ok, radio: radio, persisted: persisted}
  end

  test "loads inventory and resolves by label" do
    assert {:ok, bulbs} = Lights.all()
    assert Enum.any?(bulbs, &(&1.label == "path light 2" and &1.node_id == 2))
    assert {:ok, %{label: "post spot 1", node_id: 3}} = Lights.status("post spot 1")
  end

  test "set enqueues a phone-sourced frame and persists advanced seq", %{persisted: persisted} do
    assert :ok = Lights.set("path light 2", [on: true], ack: true)
    wait_until(fn -> Enum.any?(FakeBluez.calls(), &match?({:advertise, _, _}, &1)) end)

    {:advertise, data, _opts} =
      FakeBluez.calls() |> Enum.filter(&match?({:advertise, _, _}, &1)) |> List.last()

    assert [frame] = Carrier.frames(data)
    <<_hdr, src::binary-2, dst::binary-2, sn::16-big, sub_cmd, _::binary>> = frame
    assert src == <<0x80, 0x01>>
    assert dst == <<0x00, 0x02>>
    assert sn == 100
    assert sub_cmd == 0x06

    assert [{:inv, inv}] = :ets.lookup(persisted, :inv)
    assert inv.seq == 132
  end

  test "applies a DP report attributed by node id" do
    {:ok, tlv} = UniversalProxy.TuyaBeaconMesh.Dp.encode([{1, :bool, true}])
    report_frame = P2.build(1, 7, 2, 0x8001, 5, tlv, @beacon_key, @beacon_key)

    FakeBluez.inject(%{
      address: 0xDC23530FB34A,
      data: Carrier.ad_bytes(report_frame),
      rssi: -40
    })

    wait_until(fn -> match?({:ok, %{dps: %{1 => true}}}, Lights.status("path light 2")) end)

    assert {:ok, %{dps: %{1 => true}, last_event: {:dp_report, 7}}} =
             Lights.status("path light 2")
  end

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) > deadline -> flunk("condition not met in time")
      true -> Process.sleep(25) && do_wait(fun, deadline)
    end
  end
end
