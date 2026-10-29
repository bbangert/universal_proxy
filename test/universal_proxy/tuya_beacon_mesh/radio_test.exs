defmodule UniversalProxy.TuyaBeaconMesh.RadioTest do
  use ExUnit.Case, async: false

  alias UniversalProxy.TuyaBeaconMesh.{Carrier, FakeBluez, P2, Radio}

  @key "jngwRugsvwtGN00a"
  @capture "test/fixtures/tuya_beacon_mesh/p2_frames_2026-10-25.json"
           |> File.read!()
           |> Jason.decode!()

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

  defp radio_spec(opts \\ []) do
    {Radio,
     [
       bluez_radio: FakeBluez.Radio,
       mgmt: FakeBluez.Mgmt,
       rebus: FakeBluez.Rebus,
       dbus: FakeBluez.DBus,
       receiver: FakeBluez.Receiver,
       retry_ms: 20
     ] ++ opts}
  end

  defp start_radio(_context) do
    radio = start_supervised!(radio_spec())
    wait_until(fn -> match?({:ok, %{ready: true}}, Radio.status()) end)
    {:ok, radio: radio}
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

  defp ready?, do: match?({:ok, %{ready: true}}, Radio.status())

  setup do
    FakeBluez.ensure_started()
    FakeBluez.reset()
    :ok
  end

  describe "ready" do
    setup :start_radio

    test "status after start: lease held, discovering, listening" do
      assert {:ok, status} = Radio.status()
      assert status.ready
      assert status.last_error == nil
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

  describe "runtime loss" do
    setup :start_radio

    @tag :capture_log
    test "a lost lease goes not-ready, then re-acquires", %{radio: radio} do
      :ok = Radio.subscribe(self(), :all)
      :ok = Radio.send_frame(device_frame(1), 5_000)
      :ok = FakeBluez.end_lease()

      wait_until(fn -> FakeBluez.count(:acquire) == 2 end)
      wait_until(&ready?/0)
      assert {:ok, %{lease_held: true, tx: nil, queued: 0}} = Radio.status()
      assert Process.whereis(Radio) == radio

      FakeBluez.inject(report(0xDC23530FB34A, device_frame(9)))
      assert_receive {:tuya_report, %{mac: "DC23530FB34A"}}
    end

    @tag :capture_log
    test "a receiver crash re-runs setup instead of killing the radio", %{radio: radio} do
      :ok = Radio.subscribe(self(), :all)

      [{:receiver_started, rx}] =
        Enum.filter(FakeBluez.calls(), &match?({:receiver_started, _}, &1))

      Process.exit(rx, :kill)

      wait_until(fn -> FakeBluez.count(:receiver_started) == 2 end)
      wait_until(&ready?/0)
      assert Process.whereis(Radio) == radio
      # The old attempt's lease was released before re-acquiring.
      assert FakeBluez.count(:release) == 1

      FakeBluez.inject(report(0xDC23530FB34A, device_frame(9)))
      assert_receive {:tuya_report, %{mac: "DC23530FB34A"}}
    end

    @tag :capture_log
    test "a dead D-Bus connection is replaced", %{radio: radio} do
      :ok = FakeBluez.kill_conn()
      wait_until(fn -> FakeBluez.count(:connect) == 2 end)
      wait_until(&ready?/0)
      assert Process.whereis(Radio) == radio
      assert FakeBluez.count(:acquire) == 2
    end

    @tag :capture_log
    test "Bluez.Radio going down ends the lease and setup waits for it" do
      :ok = FakeBluez.kill_bluez_radio()
      wait_until(fn -> FakeBluez.count(:acquire) == 2 end)
      wait_until(&ready?/0)
    end

    @tag :capture_log
    test "an advertise that finds the lease gone answers :not_ready and recovers" do
      FakeBluez.fail(:advertise, :lease_expired)
      assert {:error, :not_ready} = Radio.send_frame(device_frame(1), 10)
      assert {:error, :not_ready} = Radio.send_frame(device_frame(2), 10)

      FakeBluez.succeed(:advertise)
      wait_until(&ready?/0)
      assert :ok = Radio.send_frame(device_frame(3), 10)
    end

    test "stopping takes the advert off air, stops discovery and releases the lease" do
      bluez_radio = FakeBluez.radio_pid()
      :ok = Radio.send_frame(device_frame(1), 5_000)
      stop_supervised!({Radio, 0})

      calls = FakeBluez.calls()
      assert {:stop, 5} in calls
      assert {:dbus, "StopDiscovery"} in calls
      assert FakeBluez.count(:release) == 1
      # Shared infrastructure is not ours to stop.
      assert Process.alive?(bluez_radio)
    end
  end

  describe "not ready" do
    test "stays up, logs once, refuses sends and recovers when the lease frees" do
      holder = spawn(fn -> Process.sleep(:infinity) end)
      FakeBluez.fail(:acquire, {:held_by, holder})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          start_supervised!(radio_spec())
          wait_until(fn -> FakeBluez.count(:acquire_failed) >= 3 end)
        end)

      assert length(String.split(log, "held_by")) == 2

      assert {:ok, %{ready: false, last_error: {:lease, {:held_by, ^holder}}}} = Radio.status()
      assert {:ok, %{lease_held: false, discovering: false, listening: false}} = Radio.status()
      assert {:error, :not_ready} = Radio.send_frame(device_frame(), 10)
      assert :ok = Radio.subscribe(self(), :all)

      FakeBluez.succeed(:acquire)
      wait_until(&ready?/0)
      assert {:ok, %{last_error: nil}} = Radio.status()

      FakeBluez.inject(report(0xDC23530FB34A, device_frame()))
      assert_receive {:tuya_report, %{mac: "DC23530FB34A"}}
    end

    @tag :capture_log
    test "unwinds a partial setup before every retry" do
      FakeBluez.fail({:dbus, "StartDiscovery"}, "org.bluez.Error.Failed")
      start_supervised!(radio_spec())
      wait_until(fn -> FakeBluez.count(:acquire) >= 3 end)

      # status/1 is served between attempts: every lease taken is released.
      assert {:ok, %{ready: false, last_error: {:discovery, "org.bluez.Error.Failed"}}} =
               Radio.status()

      assert FakeBluez.count(:acquire) == FakeBluez.count(:release)
      assert FakeBluez.count(:receiver_started) == 0
      # The connection is reused across retries, not leaked.
      assert FakeBluez.count(:connect) == 1

      FakeBluez.succeed({:dbus, "StartDiscovery"})
      wait_until(&ready?/0)
    end

    @tag :capture_log
    test "requires Bluez.Mgmt and Bluez.Radio to be running already" do
      FakeBluez.fail(:mgmt, :not_running)
      start_supervised!(radio_spec())
      wait_until(fn -> match?({:ok, %{last_error: {:mgmt, :not_running}}}, Radio.status()) end)

      FakeBluez.succeed(:mgmt)
      FakeBluez.fail(:bluez_radio, :not_running)

      wait_until(fn ->
        match?({:ok, %{last_error: {:bluez_radio, :not_running}}}, Radio.status())
      end)

      assert FakeBluez.count(:acquire) == 0

      FakeBluez.succeed(:bluez_radio)
      wait_until(&ready?/0)
    end

    @tag :capture_log
    test "a receiver that won't start is retried" do
      FakeBluez.fail(:receiver, {:invalid_option, :adapter_index})
      start_supervised!(radio_spec())

      wait_until(fn ->
        match?({:ok, %{last_error: {:receiver, {:invalid_option, _}}}}, Radio.status())
      end)

      wait_until(fn -> FakeBluez.count(:release) >= 2 end)
      FakeBluez.succeed(:receiver)
      wait_until(&ready?/0)
    end
  end
end
