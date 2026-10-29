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

    radio = start_supervised!(radio_spec())

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
    inject_dp_report(5)

    wait_until(fn -> match?({:ok, %{dps: %{1 => true}}}, Lights.status("path light 2")) end)

    assert {:ok, %{dps: %{1 => true}, last_event: {:dp_report, 7}}} =
             Lights.status("path light 2")
  end

  describe "radio restarts" do
    @tag :capture_log
    test "resubscribes after the Radio restarts and applies reports again" do
      stop_supervised!(Lights)
      start_supervised!({Lights, inventory: File.read!(@fixture), resubscribe_ms: 20})
      {:ok, _} = Lights.all()
      assert {:ok, %{subscribers: 1}} = Radio.status()

      old = Process.whereis(Radio)
      Process.exit(old, :kill)
      wait_until(fn -> match?(pid when is_pid(pid) and pid != old, Process.whereis(Radio)) end)
      wait_until(fn -> match?({:ok, %{subscribers: 1}}, Radio.status()) end)

      inject_dp_report(5)
      wait_until(fn -> match?({:ok, %{dps: %{1 => true}}}, Lights.status("path light 2")) end)
    end

    test "starts without a Radio and subscribes once one appears" do
      stop_supervised!(Lights)
      stop_supervised!({Radio, 1})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          start_supervised!({Lights, inventory: File.read!(@fixture), resubscribe_ms: 20})
          {:ok, _} = Lights.all()
          Process.sleep(100)
        end)

      # One line for the outage, not one per retry.
      assert length(String.split(log, "radio unavailable")) == 2

      start_supervised!(radio_spec())
      wait_until(fn -> match?({:ok, %{subscribers: 1}}, Radio.status()) end)
    end
  end

  describe "reload" do
    test "an older dump of the same mesh never pulls seq back", %{persisted: persisted} do
      assert set_sn("path light 2", on: true) == 100

      # The fixture still says seq 100; 100..131 are already reserved.
      assert :ok = Lights.reload(File.read!(@fixture))
      assert [{:inv, %{seq: 132}}] = :ets.lookup(persisted, :inv)

      assert set_sn("path light 2", on: false) == 132
    end

    test "a newer dump of the same mesh moves seq forward", %{persisted: persisted} do
      assert :ok = Lights.reload(fixture(%{"seq" => 5_000}))
      assert [{:inv, %{seq: 5_000}}] = :ets.lookup(persisted, :inv)

      assert set_sn("path light 2", on: true) == 5_000
    end

    test "the in-memory cursor wins across the 16-bit wrap" do
      # 65_530 is *behind* 100 in serial order: no change.
      assert :ok = Lights.reload(fixture(%{"seq" => 65_530}))
      assert {:ok, %{seq: 100}} = Lights.inventory()

      # A different mesh can start there; its cursor then wraps.
      mesh = %{"beaconKey" => "ffeeddccbbaa99887766554433221100"}
      assert :ok = Lights.reload(fixture(Map.put(mesh, "seq", 65_530)))
      assert set_sn("path light 2", on: true) == 65_530

      # Cursor is now 26 (65_530 + 32, wrapped); 65_000 is behind it.
      assert :ok = Lights.reload(fixture(Map.put(mesh, "seq", 65_000)))
      assert {:ok, %{seq: 26}} = Lights.inventory()
    end

    test "a different mesh takes the dump's seq as-is", %{persisted: persisted} do
      assert set_sn("path light 2", on: true) == 100

      other = fixture(%{"beaconKey" => "ffeeddccbbaa99887766554433221100", "seq" => 10})
      assert :ok = Lights.reload(other)
      assert [{:inv, %{seq: 10}}] = :ets.lookup(persisted, :inv)

      assert set_sn("path light 2", on: true) == 10
    end

    test "the same key spelled in another case is the same mesh" do
      assert set_sn("path light 2", on: true) == 100
      assert :ok = Lights.reload(fixture(%{"beaconKey" => String.upcase(@beacon_key)}))
      assert {:ok, %{seq: 132}} = Lights.inventory()
    end
  end

  defp radio_spec do
    {Radio,
     adapter_index: 1,
     bluez_radio: FakeBluez.Radio,
     mgmt: FakeBluez.Mgmt,
     rebus: FakeBluez.Rebus,
     dbus: FakeBluez.DBus,
     receiver: FakeBluez.Receiver}
  end

  # A DP report (dp 1 = true) from "path light 2" (node 2).
  defp inject_dp_report(sn) do
    {:ok, tlv} = UniversalProxy.TuyaBeaconMesh.Dp.encode([{1, :bool, true}])
    report_frame = P2.build(1, 7, 2, 0x8001, sn, tlv, @beacon_key, @beacon_key)

    FakeBluez.inject(%{
      address: 0xDC23530FB34A,
      data: Carrier.ad_bytes(report_frame),
      rssi: -40
    })
  end

  defp fixture(overrides) do
    @fixture |> File.read!() |> Jason.decode!() |> Map.merge(overrides)
  end

  # Sets via Lights and returns the SN of the frame it advertised, then
  # clears the radio so the next send goes on air at once.
  defp set_sn(who, dps) do
    before = length(advertises())
    assert :ok = Lights.set(who, dps)
    wait_until(fn -> length(advertises()) > before end)
    :ok = Radio.stop_tx()

    [<<_hdr, _src::binary-2, _dst::binary-2, sn::16-big, _::binary>>] =
      advertises() |> List.last() |> Carrier.frames()

    sn
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
      true -> Process.sleep(25) && do_wait(fun, deadline)
    end
  end
end
