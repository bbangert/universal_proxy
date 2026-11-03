defmodule UniversalProxy.TuyaBeaconMesh.RadioTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias UniversalProxy.TuyaBeaconMesh.{Carrier, FakeBluez, P2, Radio}

  @key "jngwRugsvwtGN00a"
  @capture Path.join([
             __DIR__,
             "..",
             "..",
             "fixtures",
             "tuya_beacon_mesh",
             "p2_frames_2026-10-25.json"
           ])
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

  defp phone_frame(sn), do: P2.build(1, 0x05, 0x8001, 0x0002, sn, <<1, 2, 3>>, @key, @key)

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
       transport: UniversalProxy.TuyaBeaconMesh.Radio.Transport.Bluez,
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
    wait_until(&ready?/0)
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

  # Every lease ever taken has been released (once): the radio is stopped
  # first so no setup attempt runs between the two counts.
  defp assert_leases_balanced(adapter_index \\ 0) do
    stop_supervised!({Radio, adapter_index})
    acquired = for {:acquire, ref} <- FakeBluez.calls(), do: ref
    released = for {:release, ref} <- FakeBluez.calls(), do: ref
    assert Enum.sort(acquired) == Enum.sort(Enum.uniq(released))
    assert length(released) == length(Enum.uniq(released))
  end

  # Ends the advert on air as its timer would.
  defp finish_tx do
    %{tx_current: %{token: token}} = :sys.get_state(Radio)
    send(Process.whereis(Radio), {:tx_done, token})
    {:ok, _} = Radio.status()
  end

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

      assert %{
               advertise_failures: 0,
               wedges: 0,
               wedge_streak: 0,
               recoveries: 0,
               last_wedge_at: nil,
               last_recovery_at: nil,
               controller_reset_needed: false
             } = status

      assert {:dbus, "SetDiscoveryFilter", [filter]} =
               List.keyfind(FakeBluez.calls(), "SetDiscoveryFilter", 1)

      assert {"DuplicateData", {"b", true}} in filter
      assert {"Transport", {"s", "le"}} in filter
      assert {:dbus, "StartDiscovery", []} in FakeBluez.calls()
    end

    test "fan-out to :all, dedupe of exact and hop-variant copies" do
      :ok = Radio.subscribe(self(), :all)
      frame = device_frame()
      FakeBluez.inject(report(0xDC23530FB34A, frame))
      assert_receive {:tuya_report, %{mac: "DC23530FB34A", frame: ^frame, rssi: -55}}

      FakeBluez.inject(report(0xDC23530FB34A, frame))
      FakeBluez.inject(report(0xDC23530FB34A, hop_variant(frame)))
      FakeBluez.inject(report(0xDC23530FB34B, hop_variant(frame)))
      # The B copy arrives after the A copies, so they were dropped.
      assert_receive {:tuya_report, %{mac: "DC23530FB34B"}}
      refute_received {:tuya_report, %{mac: "DC23530FB34A"}}
    end

    test ":unpaired filter only passes unpaired adverts" do
      :ok = Radio.subscribe(self(), :unpaired)
      FakeBluez.inject(report(0xDC23530FB34A, device_frame()))
      frame = unpaired_frame()
      FakeBluez.inject(report(0xDC23530FB34A, frame))
      assert_receive {:tuya_report, %{frame: received}}
      assert received == frame
      refute_received {:tuya_report, _}
    end

    test "{:mac, mac} filter matches only that advertiser" do
      :ok = Radio.subscribe(self(), {:mac, "dc:23:53:0f:b3:4a"})
      FakeBluez.inject(report(0xDC23530FB34B, device_frame(1)))
      FakeBluez.inject(report(0xDC23530FB34A, device_frame(2)))
      assert_receive {:tuya_report, %{mac: "DC23530FB34A"}}
      refute_received {:tuya_report, _}
    end

    test "unsubscribe, resubscribe with a new filter, and a dead subscriber" do
      :ok = Radio.subscribe(self(), :all)
      :ok = Radio.subscribe(self(), :unpaired)
      assert {:ok, %{subscribers: 1}} = Radio.status()

      FakeBluez.inject(report(0xDC23530FB34A, device_frame(1)))
      :ok = Radio.unsubscribe(self())
      :ok = Radio.unsubscribe(self())
      FakeBluez.inject(report(0xDC23530FB34A, unpaired_frame()))
      assert {:ok, %{subscribers: 0}} = Radio.status()
      refute_received {:tuya_report, _}

      sub = spawn(fn -> Process.sleep(:infinity) end)
      :ok = Radio.subscribe(sub, :all)
      assert {:ok, %{subscribers: 1}} = Radio.status()
      Process.exit(sub, :kill)
      wait_until(fn -> match?({:ok, %{subscribers: 0}}, Radio.status()) end)
    end

    test "TX serialises; a :control send drops queued :normal frames" do
      a = device_frame(1)
      b = device_frame(2)
      c = device_frame(3)

      :ok = Radio.send_frame(a, 60_000)
      :ok = Radio.send_frame(b, 60_000)
      :ok = Radio.send_frame(c, 60_000, class: :control)
      assert {:ok, %{tx: %{class: :normal}, queued: 1}} = Radio.status()

      # A's time runs out, then C; B was dropped by the control send.
      finish_tx()
      assert {:ok, %{tx: %{class: :control}, queued: 0}} = Radio.status()
      assert advertises() == [Carrier.ad_bytes(a), Carrier.ad_bytes(c)]

      # Two :control sends queued together keep both.
      d = device_frame(4)
      e = device_frame(5)
      :ok = Radio.send_frame(d, 60_000, class: :control)
      :ok = Radio.send_frame(e, 60_000, class: :control)
      assert {:ok, %{queued: 2}} = Radio.status()
      finish_tx()
      finish_tx()
      assert Enum.take(advertises(), -2) == [Carrier.ad_bytes(d), Carrier.ad_bytes(e)]
      assert [flags: [:connectable]] = FakeBluez.calls() |> List.keyfind(:advertise, 0) |> elem(2)
    end

    test "clear_tx drops what's on air and queued, and forgets last_tx_sn" do
      assert {:ok, %{last_tx_sn: nil}} = Radio.status()

      :ok = Radio.send_frame(phone_frame(42), 60_000)
      :ok = Radio.send_frame(phone_frame(43), 60_000)
      assert {:ok, %{last_tx_sn: 42, queued: 1}} = Radio.status()

      assert :ok = Radio.clear_tx()
      assert {:ok, %{last_tx_sn: nil, tx: nil, queued: 0}} = Radio.status()
      assert {:stop, 5} in FakeBluez.calls()
    end

    test "an advert comes off air when its time is up" do
      :ok = Radio.send_frame(device_frame(1), 30)
      assert {:ok, %{tx: %{instance: 5}}} = Radio.status()
      wait_until(fn -> match?({:ok, %{tx: nil}}, Radio.status()) end)
      assert {:stop, 5} in FakeBluez.calls()
      assert FakeBluez.instances() == %{}
    end

    test "the queue is bounded and coalesces by key, keeping send order" do
      :ok = Radio.send_frame(device_frame(1), 60_000)

      for sn <- 2..8, do: :ok = Radio.send_frame(device_frame(sn), 60_000, coalesce: {:x, sn})
      :ok = Radio.send_frame(device_frame(9), 60_000, coalesce: :b)
      assert {:ok, %{queued: 8}} = Radio.status()

      assert {:error, :queue_full} = Radio.send_frame(device_frame(10), 60_000)

      # Replacing a queued frame is allowed when full; it goes to the back.
      :ok = Radio.send_frame(device_frame(11), 60_000, coalesce: {:x, 2})
      assert {:ok, %{queued: 8}} = Radio.status()

      for _ <- 1..8, do: finish_tx()
      wait_until(fn -> length(advertises()) == 9 end)

      sns =
        for ad <- advertises() do
          [<<_, _::binary-4, sn::16, _::binary>>] = Carrier.frames(ad)
          sn
        end

      assert sns == [1, 3, 4, 5, 6, 7, 8, 9, 11]
    end

    test "an advertise refused for this frame is reported, a queued one is skipped" do
      FakeBluez.fail(:advertise, :busy)

      log =
        capture_log(fn ->
          assert {:error, {:advertise, :busy}} = Radio.send_frame(device_frame(1), 60_000)
        end)

      assert log =~ "advertise failed (:busy)"
      assert ready?()

      FakeBluez.succeed(:advertise)
      :ok = Radio.send_frame(device_frame(2), 60_000)
      :ok = Radio.send_frame(device_frame(3), 60_000)
      :ok = Radio.send_frame(device_frame(4), 60_000)

      FakeBluez.fail(:advertise, :rejected)

      capture_log(fn ->
        finish_tx()
        Radio.status()
      end)

      FakeBluez.succeed(:advertise)

      # 3 and 4 were refused and dropped; nothing is on air until the next send.
      assert {:ok, %{tx: nil, queued: 0, ready: true}} = Radio.status()
      :ok = Radio.send_frame(device_frame(5), 60_000)
      assert length(advertises()) == 2
    end

    test "a stale tx_done for a reused instance doesn't cut the next advert short" do
      radio = Process.whereis(Radio)
      :ok = Radio.send_frame(device_frame(1), 300)

      # Mailbox order: stop_tx, send B (same instance 5), then A's timer.
      :sys.suspend(radio)
      stop = Task.async(fn -> Radio.stop_tx() end)
      wait_until(fn -> Process.info(radio, :message_queue_len) == {:message_queue_len, 1} end)
      send_b = Task.async(fn -> Radio.send_frame(device_frame(2), 60_000) end)
      wait_until(fn -> Process.info(radio, :message_queue_len) == {:message_queue_len, 2} end)
      wait_until(fn -> Process.info(radio, :message_queue_len) == {:message_queue_len, 3} end)
      :sys.resume(radio)

      assert :ok = Task.await(stop)
      assert :ok = Task.await(send_b)
      assert {:ok, %{tx: %{instance: 5}}} = Radio.status()
      assert FakeBluez.count(:stop) == 1

      # An instance-number message is not ours either.
      send(radio, {:tx_done, 5})
      assert {:ok, %{tx: %{instance: 5}}} = Radio.status()
    end

    test "own transmissions relayed back are dropped as echoes until disabled" do
      :ok = Radio.subscribe(self(), :all)
      frame = device_frame()
      :ok = Radio.send_frame(frame, 30)

      FakeBluez.inject(report(0xDC23530FB34A, hop_variant(frame)))
      FakeBluez.inject(report(0xDC23530FB34B, device_frame(99)))
      assert_receive {:tuya_report, %{mac: "DC23530FB34B"}}
      refute_received {:tuya_report, %{mac: "DC23530FB34A"}}

      :ok = Radio.set_drop_echoes(false)
      FakeBluez.inject(report(0xDC23530FB34A, hop_variant(frame)))
      assert_receive {:tuya_report, %{mac: "DC23530FB34A"}}
    end

    test "bad frames, classes and filters are rejected" do
      assert {:error, :bad_frame} = Radio.send_frame(<<1, 2, 3>>, 10)
      assert {:error, :bad_class} = Radio.send_frame(device_frame(), 10, class: :Control)
      assert {:error, :bad_filter} = Radio.subscribe(self(), {:mac, "xyz"})
      assert {:error, :bad_filter} = Radio.subscribe(self(), :everything)
      assert advertises() == []
    end

    test "server: addresses every call; a missing radio is :not_running" do
      for fun <- [
            &Radio.status/1,
            &Radio.stop_tx/1,
            &Radio.set_drop_echoes(true, &1),
            &Radio.subscribe(self(), :all, &1),
            &Radio.unsubscribe(self(), &1),
            &Radio.send_frame(device_frame(), 10, &1)
          ] do
        assert {:error, :not_running} = fun.(server: :no_such_radio)
        assert fun.(server: Radio) != {:error, :not_running}
      end
    end
  end

  describe "runtime loss" do
    setup :start_radio

    @tag :capture_log
    test "a lost lease goes not-ready, then re-acquires", %{radio: radio} do
      :ok = Radio.subscribe(self(), :all)
      :ok = Radio.send_frame(device_frame(1), 5_000)
      :ok = Radio.send_frame(device_frame(2), 5_000)
      :ok = FakeBluez.end_lease()

      wait_until(fn -> FakeBluez.count(:acquire) == 2 end)
      wait_until(&ready?/0)
      assert {:ok, %{lease_held: true, tx: nil, queued: 0}} = Radio.status()
      assert Process.whereis(Radio) == radio

      FakeBluez.inject(report(0xDC23530FB34A, device_frame(9)))
      assert_receive {:tuya_report, %{mac: "DC23530FB34A"}}

      # The ended lease is not released again; the new one is on stop.
      [ended, current] = for {:acquire, ref} <- FakeBluez.calls(), do: ref
      refute {:release, ended} in FakeBluez.calls()
      stop_supervised!({Radio, 0})
      assert for({:release, ref} <- FakeBluez.calls(), do: ref) == [current]
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
      assert_leases_balanced()
    end

    @tag :capture_log
    test "a dead D-Bus connection is replaced", %{radio: radio} do
      :ok = FakeBluez.kill_conn()
      wait_until(fn -> FakeBluez.count(:connect) == 2 end)
      wait_until(&ready?/0)
      assert Process.whereis(Radio) == radio
      assert FakeBluez.count(:acquire) == 2
      assert_leases_balanced()
    end

    @tag :capture_log
    test "Bluez.Radio going down ends the lease and setup waits for it" do
      :ok = FakeBluez.kill_bluez_radio()
      wait_until(fn -> FakeBluez.count(:acquire) == 2 end)
      wait_until(&ready?/0)

      # The first lease died with Bluez.Radio: only the second is released.
      [_gone, current] = for {:acquire, ref} <- FakeBluez.calls(), do: ref
      stop_supervised!({Radio, 0})
      assert for({:release, ref} <- FakeBluez.calls(), do: ref) == [current]
    end

    @tag :capture_log
    test "an advertise that loses Mgmt or the lease is uncertain and re-runs setup" do
      for {reason, n} <- Enum.with_index([:lease_expired, :not_lease_holder, :not_running]) do
        wait_until(&ready?/0)
        acquired = FakeBluez.count(:acquire)
        FakeBluez.fail(:advertise, reason)

        log =
          capture_log(fn ->
            assert {:error, {:uncertain, ^reason}} =
                     Radio.send_frame(device_frame(2 * n + 1), 10)
          end)

        assert log =~ "not ready ({:advertise, #{inspect(reason)}})"

        # Setup is re-run (a new lease), not just this frame dropped.
        FakeBluez.succeed(:advertise)
        wait_until(fn -> FakeBluez.count(:acquire) > acquired end)
        wait_until(&ready?/0)
        assert :ok = Radio.send_frame(device_frame(2 * n + 2), 10)
        :ok = Radio.stop_tx()
      end

      assert_leases_balanced()
    end

    @tag :capture_log
    test "a queued frame whose advertise loses the lease drops the queue and re-runs setup" do
      :ok = Radio.send_frame(device_frame(1), 60_000)
      :ok = Radio.send_frame(device_frame(2), 60_000)
      :ok = Radio.send_frame(device_frame(3), 60_000)
      FakeBluez.fail(:advertise, :lease_expired)
      finish_tx()

      assert length(advertises()) == 1
      FakeBluez.succeed(:advertise)
      wait_until(fn -> FakeBluez.count(:acquire) == 2 end)
      wait_until(&ready?/0)
      assert {:ok, %{tx: nil, queued: 0}} = Radio.status()
      assert_leases_balanced()
    end

    @tag :capture_log
    test "an advert that won't come off air re-runs setup" do
      :ok = Radio.send_frame(device_frame(1), 60_000)
      FakeBluez.fail(:stop_advertising, :busy)

      log = capture_log(fn -> :ok = Radio.stop_tx() end)
      assert log =~ "not ready ({:stop_advertising, :busy})"

      # Releasing the lease took the stuck instance down with it.
      assert FakeBluez.count(:release) == 1
      assert FakeBluez.instances() == %{}

      FakeBluez.succeed(:stop_advertising)
      wait_until(&ready?/0)
      assert_leases_balanced()
    end

    @tag :capture_log
    test "a receiver that won't stop is killed so its name is free again" do
      [{:receiver_started, rx}] =
        Enum.filter(FakeBluez.calls(), &match?({:receiver_started, _}, &1))

      stop_supervised!({Radio, 0})
      FakeBluez.reset()
      FakeBluez.fail(:receiver_stop, :hang)
      refute Process.alive?(rx)

      start_supervised!(radio_spec(receiver_stop_ms: 50))
      wait_until(&ready?/0)

      [{:receiver_started, hung}] =
        Enum.filter(FakeBluez.calls(), &match?({:receiver_started, _}, &1))

      :ok = FakeBluez.end_lease()
      wait_until(fn -> FakeBluez.count(:receiver_started) == 2 end)
      wait_until(&ready?/0)
      refute Process.alive?(hung)
      FakeBluez.succeed(:receiver_stop)
    end

    test "stopping takes the advert off air, stops discovery and releases the lease" do
      bluez_radio = FakeBluez.radio_pid()
      :ok = Radio.send_frame(device_frame(1), 5_000)
      stop_supervised!({Radio, 0})

      calls = FakeBluez.calls()
      assert {:stop, 5} in calls
      assert {:dbus, "StopDiscovery", []} in calls
      assert FakeBluez.count(:release) == 1
      assert FakeBluez.instances() == %{}
      # Shared infrastructure is not ours to stop.
      assert Process.alive?(bluez_radio)
    end
  end

  describe "health check" do
    defp start_discoveries,
      do: Enum.count(FakeBluez.calls(), &match?({:dbus, "StartDiscovery", _}, &1))

    defp health_reads,
      do: Enum.count(FakeBluez.calls(), &match?({:dbus, "Get", _}, &1))

    test "discovery that ended behind the radio's back is restarted" do
      radio = start_supervised!(radio_spec(health_check_ms: 30))
      wait_until(&ready?/0)
      wait_until(fn -> health_reads() >= 1 end)
      assert start_discoveries() == 1
      :ok = Radio.subscribe(self(), :all)

      log =
        capture_log(fn ->
          :ok = FakeBluez.stop_discovering()
          wait_until(fn -> start_discoveries() == 2 end)
          wait_until(&ready?/0)
        end)

      assert log =~ "not ready ({:health, :not_discovering})"
      assert Process.whereis(Radio) == radio
      assert FakeBluez.discovering?()
      assert FakeBluez.count(:release) == 1

      # Healthy again: checks keep passing without re-running setup.
      reads = health_reads()
      wait_until(fn -> health_reads() >= reads + 2 end)
      assert start_discoveries() == 2

      FakeBluez.inject(report(0xDC23530FB34A, device_frame(9)))
      assert_receive {:tuya_report, %{mac: "DC23530FB34A"}}
      assert_leases_balanced()
    end

    test "a live receiver that stopped listening re-runs setup, logged once" do
      radio = start_supervised!(radio_spec(health_check_ms: 30))
      wait_until(&ready?/0)

      log =
        capture_log(fn ->
          FakeBluez.fail(:listening, true)
          wait_until(fn -> FakeBluez.count(:receiver_started) >= 3 end)
          FakeBluez.succeed(:listening)
          wait_until(&ready?/0)
          reads = health_reads()
          wait_until(fn -> health_reads() >= reads + 1 end)
        end)

      assert length(String.split(log, "{:health, :receiver_not_listening}")) == 2
      assert Process.whereis(Radio) == radio
      assert {:ok, %{ready: true, listening: true}} = Radio.status()
      assert_leases_balanced()
    end

    @tag :capture_log
    test "an adapter that went away fails the check" do
      start_supervised!(radio_spec(health_check_ms: 30))
      wait_until(&ready?/0)

      FakeBluez.fail({:dbus, "Get"}, "org.freedesktop.DBus.Error.UnknownObject")

      wait_until(fn ->
        match?(
          {:ok,
           %{last_error: {:health, {:discovering, "org.freedesktop.DBus.Error.UnknownObject"}}}},
          Radio.status()
        )
      end)

      FakeBluez.succeed({:dbus, "Get"})
      wait_until(&ready?/0)
    end

    @tag :capture_log
    test "one check is pending at a time, across setups, and none after stop" do
      start_supervised!(radio_spec(health_check_ms: 60_000))
      wait_until(&ready?/0)

      timers =
        for _ <- 1..3 do
          %{health: {_token, timer}} = :sys.get_state(Radio)
          acquired = FakeBluez.count(:acquire)
          :ok = FakeBluez.end_lease()
          wait_until(fn -> FakeBluez.count(:acquire) > acquired end)
          wait_until(&ready?/0)
          timer
        end

      for timer <- timers, do: assert(Process.read_timer(timer) == false)
      %{health: {_token, current}} = :sys.get_state(Radio)
      assert is_integer(Process.read_timer(current))

      stop_supervised!({Radio, 0})
      assert Process.read_timer(current) == false
    end

    @tag :capture_log
    test "not checked while not ready" do
      FakeBluez.fail(:mgmt, :not_running)
      start_supervised!(radio_spec(health_check_ms: 10))
      wait_until(fn -> match?({:ok, %{last_error: {:mgmt, :not_running}}}, Radio.status()) end)
      Process.sleep(50)
      assert health_reads() == 0
      assert %{health: nil} = :sys.get_state(Radio)
    end
  end

  describe "adapter power" do
    test "powers its own adapter before starting discovery" do
      start_supervised!(radio_spec(adapter_index: 2))
      wait_until(&ready?/0)

      calls = FakeBluez.calls()
      power = Enum.find_index(calls, &match?({:dbus, "Set", _}, &1))
      filter = Enum.find_index(calls, &match?({:dbus, "SetDiscoveryFilter", _}, &1))

      assert {:dbus, "Set", ["org.bluez.Adapter1", "Powered", {"b", true}]} =
               Enum.at(calls, power)

      assert power < filter
      assert {:dbus_path, "/org/bluez/hci2", "Set"} in calls
      refute Enum.any?(calls, &match?({:dbus_path, "/org/bluez/hci0", _}, &1))
    end

    @tag :capture_log
    test "an adapter that won't power on is retried, and discovery waits for it" do
      FakeBluez.fail({:dbus, "Set"}, "org.bluez.Error.Blocked")
      start_supervised!(radio_spec())

      wait_until(fn ->
        match?({:ok, %{last_error: {:power, "org.bluez.Error.Blocked"}}}, Radio.status())
      end)

      refute Enum.any?(FakeBluez.calls(), &match?({:dbus, "StartDiscovery", _}, &1))

      FakeBluez.succeed({:dbus, "Set"})
      wait_until(&ready?/0)
      assert_leases_balanced()
    end
  end

  describe "adapter fence" do
    @mesh "AA:BB:CC:DD:EE:01"
    @intruder "11:22:33:44:55:66"

    defp touched_adapter?(calls) do
      Enum.any?(calls, fn
        {:acquire, _} -> true
        {:advertise, _, _} -> true
        {:dbus, member, _} -> member in ["Set", "SetDiscoveryFilter", "StartDiscovery"]
        _ -> false
      end)
    end

    test "checks the address before touching the adapter, in any case" do
      FakeBluez.set_address(1, String.downcase(@mesh))
      start_supervised!(radio_spec(adapter_index: 1, adapter_address: @mesh))
      wait_until(&ready?/0)

      calls = FakeBluez.calls()
      check = Enum.find_index(calls, &(&1 == {:dbus, "Get", ["org.bluez.Adapter1", "Address"]}))
      first_touch = Enum.find_index(calls, &touched_adapter?([&1]))
      assert check < first_touch
      assert {:ok, %{adapter_address: @mesh}} = Radio.status()
    end

    @tag :capture_log
    test "an index reused by another adapter is never powered, scanned or advertised on" do
      FakeBluez.set_address(1, @intruder)
      start_supervised!(radio_spec(adapter_index: 1, adapter_address: @mesh))

      wait_until(fn -> FakeBluez.count(:dbus) >= 3 end)

      assert {:ok, %{ready: false, last_error: {:wrong_adapter, @intruder}}} = Radio.status()
      assert {:error, :not_ready} = Radio.send_frame(device_frame(), 10)
      refute touched_adapter?(FakeBluez.calls())

      # A missing adapter is refused the same way.
      FakeBluez.set_address(1, nil)

      wait_until(fn ->
        match?({:ok, %{last_error: {:adapter_address, _}}}, Radio.status())
      end)

      refute touched_adapter?(FakeBluez.calls())

      # The right adapter back under that index: setup completes.
      FakeBluez.set_address(1, @mesh)
      wait_until(&ready?/0)
    end

    @tag :capture_log
    test "an adapter swapped under a ready radio is dropped at the next health check" do
      FakeBluez.set_address(1, @mesh)

      start_supervised!(radio_spec(adapter_index: 1, adapter_address: @mesh, health_check_ms: 20))

      wait_until(&ready?/0)
      FakeBluez.set_address(1, @intruder)

      wait_until(fn ->
        match?({:ok, %{ready: false, last_error: {:wrong_adapter, @intruder}}}, Radio.status())
      end)

      # Two more refused setups, and nothing touched the adapter meanwhile.
      checks = address_checks()
      wait_until(fn -> address_checks() >= checks + 2 end)
      refute touched_adapter?(Enum.drop(FakeBluez.calls(), length(calls_upto_checks(checks))))
      assert {:error, :not_ready} = Radio.send_frame(device_frame(), 10)
    end

    defp address_check?(call), do: call == {:dbus, "Get", ["org.bluez.Adapter1", "Address"]}

    defp address_checks, do: Enum.count(FakeBluez.calls(), &address_check?/1)

    # The calls up to and including the `n`th address check.
    defp calls_upto_checks(n) do
      FakeBluez.calls()
      |> Enum.reduce_while({[], 0}, fn call, {acc, seen} ->
        seen = if address_check?(call), do: seen + 1, else: seen
        if seen > n, do: {:halt, {acc, seen}}, else: {:cont, {[call | acc], seen}}
      end)
      |> elem(0)
    end

    test "without :adapter_address the address is never read" do
      start_supervised!(radio_spec())
      wait_until(&ready?/0)
      refute {:dbus, "Get", ["org.bluez.Adapter1", "Address"]} in FakeBluez.calls()
    end
  end

  describe "wedged controller" do
    @mesh "AA:BB:CC:DD:EE:01"
    @intruder "11:22:33:44:55:66"
    @powered_off {:dbus, "Set", ["org.bluez.Adapter1", "Powered", {"b", false}]}

    # Every `Powered` Set, as {object_path, value}, in call order.
    defp power_sets(calls) do
      calls
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.flat_map(fn
        [{:dbus, "Set", ["org.bluez.Adapter1", "Powered", {"b", on?}]}, {:dbus_path, path, "Set"}] ->
          [{path, on?}]

        _other ->
          []
      end)
    end

    defp fail_frames(sns) do
      for sn <- sns do
        assert {:error, {:advertise, :failed}} = Radio.send_frame(device_frame(sn), 10)
      end
    end

    defp wedge(sns), do: capture_log(fn -> fail_frames(sns) end)

    defp status! do
      {:ok, status} = Radio.status()
      status
    end

    defp calls_since(mark), do: Enum.drop(FakeBluez.calls(), mark)

    # The wedge's retry is pending, due in at most `ms`.
    defp assert_retry_in(ms) do
      %{retry_timer: timer, ready: false} = :sys.get_state(Radio)
      left = Process.read_timer(timer)
      assert left > ms - 5_000 and left <= ms
    end

    defp retry_now do
      send(Process.whereis(Radio), :retry_setup)
      wait_until(&ready?/0)
    end

    test "consecutive controller faults wedge it; re-setup power-cycles the fenced adapter" do
      FakeBluez.set_address(1, @mesh)

      start_supervised!(radio_spec(adapter_index: 1, adapter_address: @mesh, wedge_retry_ms: 300))

      wait_until(&ready?/0)
      assert power_sets(FakeBluez.calls()) == [{"/org/bluez/hci1", true}]

      FakeBluez.fail(:advertise, :failed)
      log = wedge(1..2)
      assert log =~ "advertise failed (:failed)"
      assert %{ready: true, advertise_failures: 2, wedges: 0} = status!()

      log = wedge([3])
      assert log =~ "controller wedged"
      mark = length(FakeBluez.calls())

      status = status!()

      assert %{
               ready: false,
               last_error: {:controller_wedged, :failed},
               lease_held: false,
               advertise_failures: 0,
               wedges: 1,
               wedge_streak: 1,
               recoveries: 0,
               controller_reset_needed: false
             } = status

      assert %DateTime{} = status.last_wedge_at

      # Recovering: refused before reaching Mgmt, so callers back off.
      assert {:error, :not_ready} = Radio.send_frame(device_frame(4), 10)
      assert advertises() == []

      FakeBluez.succeed(:advertise)
      capture_log(fn -> wait_until(&ready?/0) end)

      new = calls_since(mark)

      assert power_sets(new) == [
               {"/org/bluez/hci1", false},
               {"/org/bluez/hci1", true},
               {"/org/bluez/hci1", true}
             ]

      check = Enum.find_index(new, &(&1 == {:dbus, "Get", ["org.bluez.Adapter1", "Address"]}))
      off = Enum.find_index(new, &(&1 == @powered_off))
      acquire = Enum.find_index(new, &match?({:acquire, _}, &1))
      assert check < off and off < acquire
      refute Enum.any?(FakeBluez.calls(), &match?({:dbus_path, "/org/bluez/hci0", _}, &1))

      status = status!()
      assert %{last_error: nil, recoveries: 1, wedge_streak: 1} = status
      assert %DateTime{} = status.last_recovery_at

      # The first accepted advertise proves it recovered.
      assert :ok = Radio.send_frame(device_frame(5), 10)
      assert %{wedge_streak: 0, wedges: 1, controller_reset_needed: false} = status!()
      assert_leases_balanced(1)
    end

    @tag :capture_log
    test "an index taken over by another adapter is never power-cycled" do
      FakeBluez.set_address(1, @mesh)

      start_supervised!(radio_spec(adapter_index: 1, adapter_address: @mesh, wedge_retry_ms: 20))

      wait_until(&ready?/0)
      FakeBluez.set_address(1, @intruder)
      FakeBluez.fail(:advertise, :failed)
      wedge(1..3)
      mark = length(FakeBluez.calls())

      wait_until(fn ->
        match?(%{last_error: {:wrong_adapter, @intruder}}, status!()) and
          length(calls_since(mark)) > 6
      end)

      assert power_sets(calls_since(mark)) == []
      assert %{recoveries: 0} = status!()

      # Its own adapter back: that one is cycled.
      FakeBluez.set_address(1, @mesh)
      wait_until(&ready?/0)
      assert [{"/org/bluez/hci1", false} | _] = power_sets(calls_since(mark))
      assert %{recoveries: 1} = status!()
    end

    @tag :capture_log
    test "a power-cycle that fails is retried before the lease is taken" do
      start_supervised!(radio_spec(wedge_retry_ms: 20))
      wait_until(&ready?/0)
      acquired = FakeBluez.count(:acquire)
      FakeBluez.fail(:advertise, :failed)
      FakeBluez.fail({:dbus, "Set"}, "org.bluez.Error.Busy")
      wedge(1..3)

      wait_until(fn ->
        match?(%{last_error: {:power_cycle, "org.bluez.Error.Busy"}}, status!())
      end)

      assert FakeBluez.count(:acquire) == acquired

      FakeBluez.succeed({:dbus, "Set"})
      wait_until(&ready?/0)
      assert %{recoveries: 1} = status!()
      assert_leases_balanced()
    end

    @tag :capture_log
    test "an accepted advertise in between resets the count" do
      start_supervised!(radio_spec())
      wait_until(&ready?/0)
      FakeBluez.fail(:advertise, :failed)
      fail_frames(1..2)

      FakeBluez.succeed(:advertise)
      assert :ok = Radio.send_frame(device_frame(3), 10)
      :ok = Radio.stop_tx()
      assert %{advertise_failures: 0} = status!()

      FakeBluez.fail(:advertise, :failed)
      fail_frames(4..5)
      assert %{ready: true, advertise_failures: 2, wedges: 0} = status!()
    end

    @tag :capture_log
    test "refusals of the frame neither count nor reset the count" do
      start_supervised!(radio_spec())
      wait_until(&ready?/0)

      for {reason, sn} <-
            Enum.with_index([
              :busy,
              :rotation_busy,
              :rejected,
              :invalid_params,
              :no_free_instance
            ]) do
        FakeBluez.fail(:advertise, reason)
        assert {:error, {:advertise, ^reason}} = Radio.send_frame(device_frame(sn), 10)
      end

      assert %{ready: true, advertise_failures: 0} = status!()

      FakeBluez.fail(:advertise, :failed)
      fail_frames(10..11)
      FakeBluez.fail(:advertise, :busy)
      assert {:error, {:advertise, :busy}} = Radio.send_frame(device_frame(12), 10)
      assert %{ready: true, advertise_failures: 2} = status!()

      FakeBluez.fail(:advertise, :timeout)
      assert {:error, {:advertise, :timeout}} = Radio.send_frame(device_frame(13), 10)
      assert %{ready: false, last_error: {:controller_wedged, :timeout}} = status!()
    end

    @tag :capture_log
    test "failures spread over more than the window wedge it too" do
      start_supervised!(radio_spec(wedge_failures: 100, wedge_window_ms: 50))
      wait_until(&ready?/0)
      FakeBluez.fail(:advertise, :failed)
      fail_frames([1])
      Process.sleep(60)
      fail_frames([2])
      assert %{ready: false, last_error: {:controller_wedged, :failed}, wedges: 1} = status!()
    end

    @tag :capture_log
    test "queued frames refused by a wedged controller drop the queue" do
      start_supervised!(radio_spec())
      wait_until(&ready?/0)

      for sn <- 1..4, do: :ok = Radio.send_frame(device_frame(sn), 60_000)
      FakeBluez.fail(:advertise, :failed)
      finish_tx()

      # Frames 2, 3 and 4 were each refused: the third wedged it.
      assert length(advertises()) == 1

      assert %{ready: false, last_error: {:controller_wedged, :failed}, tx: nil, queued: 0} =
               status!()

      assert {:error, :not_ready} = Radio.send_frame(device_frame(5), 10)
    end

    test "recovery backs off, escalates, and starts over once advertising works" do
      start_supervised!(radio_spec(wedge_retry_ms: 40_000, max_wedge_retry_ms: 100_000))
      wait_until(&ready?/0)
      FakeBluez.fail(:advertise, :failed)

      log = wedge(1..3)
      assert log =~ "controller wedged"
      refute log =~ "transport needs a reset"
      assert_retry_in(40_000)
      capture_log(&retry_now/0)
      assert %{recoveries: 1, wedge_streak: 1, controller_reset_needed: false} = status!()

      # Still failing right after the power-cycle: escalated.
      log = wedge(4..6)
      assert log =~ "still wedged"
      assert log =~ "transport needs a reset"
      assert_retry_in(80_000)
      assert %{wedges: 2, wedge_streak: 2, controller_reset_needed: true} = status!()
      capture_log(&retry_now/0)
      assert %{recoveries: 2, controller_reset_needed: true} = status!()

      log = wedge(7..9)
      assert log =~ "wedged 3 times in a row"
      assert_retry_in(100_000)
      capture_log(&retry_now/0)

      FakeBluez.succeed(:advertise)
      capture_log(fn -> assert :ok = Radio.send_frame(device_frame(10), 10) end)
      :ok = Radio.stop_tx()

      assert %{wedges: 3, recoveries: 3, wedge_streak: 0, controller_reset_needed: false} =
               status!()

      # A later wedge starts the ladder (and the backoff) over.
      FakeBluez.fail(:advertise, :failed)
      log = wedge(11..13)
      refute log =~ "still wedged"
      assert_retry_in(40_000)
    end
  end

  describe "not ready" do
    test "stays up, logs once, refuses sends and recovers when the lease frees" do
      holder = start_supervised!({Task, fn -> Process.sleep(:infinity) end})
      FakeBluez.fail(:acquire, {:held_by, holder})

      log =
        capture_log(fn ->
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

      assert {:ok, %{ready: false, last_error: {:discovery, "org.bluez.Error.Failed"}}} =
               Radio.status()

      assert FakeBluez.count(:receiver_started) == 0
      # The connection is reused across retries, not leaked.
      assert FakeBluez.count(:connect) == 1
      assert_leases_balanced()
    end

    @tag :capture_log
    test "discovery already in progress counts as started" do
      FakeBluez.fail({:dbus, "StartDiscovery"}, "org.bluez.Error.InProgress")
      start_supervised!(radio_spec())
      wait_until(&ready?/0)
      assert {:ok, %{discovering: true}} = Radio.status()
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
      assert_leases_balanced()
    end

    test "the child spec allows time for a clean teardown" do
      assert %{shutdown: 10_000, id: {Radio, 3}} = Radio.child_spec(adapter_index: 3)
    end
  end
end
