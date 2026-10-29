defmodule UniversalProxy.TuyaBeaconMesh.RadioTest do
  use ExUnit.Case, async: false

  alias UniversalProxy.TuyaBeaconMesh.{Carrier, FakeBluez, P2, Radio}

  @key "jngwRugsvwtGN00a"
  @capture "test/fixtures/tuya_beacon_mesh/p2_frames_2026-10-25.json" |> File.read!() |> Jason.decode!()

  defp h(hex), do: Base.decode16!(hex, case: :mixed)

  defp unpaired_frame do
    f = Enum.find(@capture["frames"], &(&1["hdr"] in 0x88..0x8B))
    h(f["frame"])
  end

  defp device_frame(sn \\ 7) do
    P2.build(1, 0x05, 0x6506, 0xFFFF, sn, <<1, 2, 3>>, @key, @key)
  end

  # The same frame as a bulb would relay it: hop bits 1 instead of 0
  # (our own builds carry hop 3, so start from the normalised frame).
  defp hop_variant(frame) do
    <<hdr, rest::binary>> = P2.normalize(frame)
    <<hdr + 1, rest::binary>>
  end

  defp report(address, frame) do
    %{address: address, data: Carrier.ad_bytes(frame), rssi: -55}
  end

  defp advertises do
    for {:advertise, data, _opts} <- FakeBluez.calls(), do: data
  end

  setup do
    FakeBluez.ensure_started()
    FakeBluez.reset()

    {:ok, radio} =
      Radio.start_link(
        bluez_radio: FakeBluez.Radio,
        mgmt: FakeBluez.Mgmt,
        rebus: FakeBluez.Rebus,
        dbus: FakeBluez.DBus,
        receiver: FakeBluez.Receiver
      )

    on_exit(fn ->
      if Process.alive?(radio), do: GenServer.stop(radio)
    end)

    {:ok, radio: radio}
  end

  test "status after start: lease held, discovering, listening" do
    assert {:ok, status} = Radio.status()
    assert status.adapter_index == 0
    assert status.lease_held
    assert status.discovering
    assert status.listening
    assert status.subscribers == 0
    assert status.tx == nil
    assert {:dbus, "SetDiscoveryFilter"} in FakeBluez.calls()
    assert {:dbus, "StartDiscovery"} in FakeBluez.calls()
  end

  test "fan-out to :all, dedupe of exact and hop-variant copies" do
    :ok = Radio.subscribe(self(), :all)
    frame = device_frame()
    FakeBluez.inject(report(0xDC23530FB34A, frame))
    assert_receive {:tuya_report, %{mac: "DC23530FB34A", frame: ^frame, rssi: -55}}

    FakeBluez.inject(report(0xDC23530FB34A, frame))
    FakeBluez.inject(report(0xDC23530FB34A, hop_variant(frame)))
    FakeBluez.inject(report(0xDC23530FB34B, hop_variant(frame)))
    refute_receive {:tuya_report, %{mac: "DC23530FB34A"}}, 150
    assert_receive {:tuya_report, %{mac: "DC23530FB34B"}}
  end

  test ":unpaired filter only passes unpaired adverts" do
    :ok = Radio.subscribe(self(), :unpaired)
    FakeBluez.inject(report(0xDC23530FB34A, device_frame()))
    refute_receive {:tuya_report, _}, 150

    frame = unpaired_frame()
    FakeBluez.inject(report(0xDC23530FB34A, frame))
    assert_receive {:tuya_report, %{frame: ^frame}}
  end

  test "{:mac, mac} filter matches only that advertiser" do
    :ok = Radio.subscribe(self(), {:mac, "dc:23:53:0f:b3:4a"})
    FakeBluez.inject(report(0xDC23530FB34B, device_frame()))
    refute_receive {:tuya_report, _}, 150
    FakeBluez.inject(report(0xDC23530FB34A, device_frame()))
    assert_receive {:tuya_report, %{mac: "DC23530FB34A"}}
  end

  test "TX serialises; a :control send drops queued :normal frames" do
    a = device_frame(1)
    b = device_frame(2)
    c = device_frame(3)

    :ok = Radio.send_frame(a, 300)
    :ok = Radio.send_frame(b, 10)
    :ok = Radio.send_frame(c, 10, class: :control)
    assert {:ok, %{tx: %{class: :normal}, queued: 1}} = Radio.status()

    # A runs its 300 ms, then C; B was dropped by the control send.
    Process.sleep(450)
    assert advertises() == [Carrier.ad_bytes(a), Carrier.ad_bytes(c)]
    assert {:ok, %{tx: nil, queued: 0}} = Radio.status()
  end

  test "own transmissions relayed back are dropped as echoes until disabled" do
    :ok = Radio.subscribe(self(), :all)
    frame = device_frame()
    :ok = Radio.send_frame(frame, 30)
    Process.sleep(60)

    FakeBluez.inject(report(0xDC23530FB34A, hop_variant(frame)))
    refute_receive {:tuya_report, _}, 150

    :ok = Radio.set_drop_echoes(false)
    FakeBluez.inject(report(0xDC23530FB34A, hop_variant(frame)))
    assert_receive {:tuya_report, %{mac: "DC23530FB34A"}}
  end

  test "bad frames and bad filters are rejected" do
    assert {:error, :bad_frame} = Radio.send_frame(<<1, 2, 3>>, 10)
    assert {:error, :bad_filter} = Radio.subscribe(self(), {:mac, "xyz"})
    assert {:error, :bad_filter} = Radio.subscribe(self(), :everything)
  end
end
