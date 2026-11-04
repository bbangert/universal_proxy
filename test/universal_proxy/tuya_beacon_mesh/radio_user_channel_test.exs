defmodule UniversalProxy.TuyaBeaconMesh.RadioUserChannelTest do
  # The Radio over Transport.UserChannel, driving FakeHciUser. The
  # fallback to the real Bluez transport uses the global FakeBluez.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias UniversalProxy.Bluetooth.HeldRadios
  alias UniversalProxy.TuyaBeaconMesh.{Carrier, FakeBluez, FakeHciUser, Inventory, P2, Radio}
  alias UniversalProxy.TuyaBeaconMesh.Radio.Transport
  alias UniversalProxy.TuyaMesh.KeyLeak

  @mac "B8:FB:B3:1B:3B:44"
  @addr 0xB8FBB31B3B44
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

  @bring_up [
    {:reset, 5_000},
    {:read_bd_addr, 2_000},
    {:read_local_version, 2_000},
    {:le_read_local_supported_features, 2_000},
    {:set_event_mask, 0x20001FFFFFFFFFFF, 2_000},
    {:le_set_event_mask, 0x1F, 2_000},
    {:le_set_scan_parameters, [type: :passive, interval_ms: 30, window_ms: 30], 2_000},
    {:le_set_advertising_parameters, [type: :adv_ind, min_interval_ms: 20, max_interval_ms: 30],
     2_000},
    {:le_set_scan_enable, true, false, 2_000}
  ]

  defmodule StubTransport do
    @moduledoc false
    # Up unless started with `stub_fail: true`; reports `transport: :stub`.
    @behaviour UniversalProxy.TuyaBeaconMesh.Radio.Transport

    @impl true
    def init(opts) do
      send(opts[:test_pid], {:stub, :init})
      {:ok, %{test: opts[:test_pid], fail: Keyword.get(opts, :stub_fail, false)}}
    end

    @impl true
    def fallback?(:stub_down), do: true

    @impl true
    def setup(%{fail: true} = state, _reset?), do: {:error, :stub_down, state, []}
    def setup(state, _reset?), do: {:ok, state, []}
    @impl true
    def teardown(state), do: state
    @impl true
    def terminate(_reason, _state), do: :ok
    @impl true
    def transmit(state, _ad), do: {:ok, 1, state}
    @impl true
    def stop_transmit(state, _instance), do: {:ok, state}
    @impl true
    def health_check(_state), do: :ok
    @impl true
    def handle_info(_msg, _state), do: :unhandled
    @impl true
    def status(_state),
      do: %{lease_held: true, discovering: true, listening: true, transport: :stub}
  end

  defmodule LastTransport do
    @moduledoc false
    # Always up; reports `transport: :last`.
    @behaviour UniversalProxy.TuyaBeaconMesh.Radio.Transport

    @impl true
    def init(opts) do
      send(opts[:test_pid], {:last, :init})
      {:ok, %{}}
    end

    @impl true
    def setup(state, _reset?), do: {:ok, state, []}
    @impl true
    def teardown(state), do: state
    @impl true
    def terminate(_reason, _state), do: :ok
    @impl true
    def transmit(state, _ad), do: {:ok, 1, state}
    @impl true
    def stop_transmit(state, _instance), do: {:ok, state}
    @impl true
    def health_check(_state), do: :ok
    @impl true
    def handle_info(_msg, _state), do: :unhandled
    @impl true
    def status(_state),
      do: %{lease_held: true, discovering: true, listening: true, transport: :last}
  end

  defp captured do
    f = hd(@capture["frames"])
    {String.to_integer(f["addr"], 16), Base.decode16!(f["frame"]), f["rssi"]}
  end

  defp frame(sn), do: P2.build(1, 0x05, 0x8001, 0x0002, sn, <<1, 2, 3>>, @key, @key)

  defp start_radio(opts \\ [], control \\ %{}) do
    control = start_supervised!({Agent, fn -> control end}, id: :control)
    name = :"radio_uc_#{System.unique_integer([:positive])}"

    defaults = [
      transport: [Transport.UserChannel],
      hci_user: FakeHciUser,
      hci_user_opts: [test: self(), control: control],
      test_pid: self(),
      name: name,
      retry_ms: 20,
      adapter_address: @mac
    ]

    pid = start_supervised!({Radio, Keyword.merge(defaults, opts)})
    %{radio: name, pid: pid, control: control}
  end

  defp set(ctx, key, value), do: Agent.update(ctx.control, &Map.put(&1, key, value))
  defp clear(ctx, key), do: Agent.update(ctx.control, &Map.delete(&1, key))

  defp status!(ctx) do
    {:ok, status} = Radio.status(server: ctx.radio)
    status
  end

  # The channel the Radio bound (after its start call).
  defp bound!(ctx) do
    radio = ctx.pid
    assert_receive {:hci, nil, {:start, @addr, ^radio}}, 1_000
    assert_receive {:hci, server, :index}
    server
  end

  defp ready!(ctx) do
    server = bound!(ctx)
    wait_until(fn -> status!(ctx).ready end)
    assert calls(server) == @bring_up
    Map.put(ctx, :server, server)
  end

  # Everything `server` was asked so far, in order.
  defp calls(server) do
    receive do
      {:hci, ^server, call} -> [call | calls(server)]
    after
      0 -> []
    end
  end

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) > deadline -> flunk("condition not met in time")
      true -> Process.sleep(5) && do_wait(fun, deadline)
    end
  end

  describe "bring-up" do
    test "binds by MAC, then resets and configures the controller in order" do
      ctx = ready!(start_radio())

      assert %{
               ready: true,
               transport: :user_channel,
               fallback_reason: nil,
               lease_held: true,
               discovering: true,
               listening: true,
               hci_index: 0,
               controller: %{manufacturer: 93, lmp_subversion: 0xD922}
             } = status!(ctx)
    end

    @tag :capture_log
    test "a controller with another BD_ADDR is let go at once and never used" do
      ctx = start_radio([], %{bd_addr: 0x112233445566})
      server = bound!(ctx)

      assert_receive {:hci, ^server, :closed}
      assert [{:reset, _}, {:read_bd_addr, _}] = calls(server)

      assert %{ready: false, last_error: {:wrong_adapter, "11:22:33:44:55:66"}} = status!(ctx)
      # Retried by MAC.
      assert_receive {:hci, nil, {:start, @addr, _}}
    end

    @tag :capture_log
    test "a failed init step fails setup; the retry resets the channel it kept" do
      ctx = start_radio([], %{le_set_event_mask: {:error, {:status, 0x12}}})
      server = bound!(ctx)

      wait_until(fn -> match?(%{last_error: {:init, :le_event_mask, _}}, status!(ctx)) end)
      assert %{ready: false, last_error: {:init, :le_event_mask, {:status, 0x12}}} = status!(ctx)

      clear(ctx, :le_set_event_mask)
      wait_until(fn -> status!(ctx).ready end)
      # Same channel: no second bind.
      refute_received {:hci, nil, {:start, _, _}}
      assert {:le_set_scan_enable, true, false, 2_000} in calls(server)
    end
  end

  describe "transmit" do
    test "a frame is Set Advertising Data, Enable, and Disable when its window ends" do
      ctx = ready!(start_radio())
      f = frame(41)
      ad = Carrier.ad_bytes(f)

      :ok = Radio.send_frame(f, 40, server: ctx.radio)
      assert %{tx: %{instance: 0}, last_tx_sn: 41} = status!(ctx)
      wait_until(fn -> status!(ctx).tx == nil end)

      assert calls(ctx.server) == [
               {:le_set_advertising_data, ad, 2_000},
               {:le_set_advertising_enable, true, 2_000},
               {:le_set_advertising_enable, false, 2_000}
             ]
    end

    test "an HCI status is a controller fault; an accepted frame clears the count" do
      ctx = ready!(start_radio())
      set(ctx, :le_set_advertising_enable, {:error, {:status, 0x0C}})

      log =
        capture_log(fn ->
          assert {:error, {:advertise, {:status, 0x0C}}} =
                   Radio.send_frame(frame(1), 40, server: ctx.radio)
        end)

      assert log =~ "advertise failed"
      assert %{ready: true, advertise_failures: 1, last_tx_sn: nil} = status!(ctx)

      clear(ctx, :le_set_advertising_enable)
      :ok = Radio.send_frame(frame(2), 40, server: ctx.radio)
      assert %{advertise_failures: 0, last_tx_sn: 2} = status!(ctx)
    end

    @tag :capture_log
    test "a command timing out in flight is a fault, and the closed channel is re-bound by MAC" do
      ctx = ready!(start_radio())
      set(ctx, :le_set_advertising_enable, {:close, {:error, :timeout}, :command_timeout})

      assert {:error, {:advertise, :timeout}} = Radio.send_frame(frame(1), 40, server: ctx.radio)
      clear(ctx, :le_set_advertising_enable)

      # {:closed, :command_timeout} → lost → re-bound.
      radio = ctx.pid
      assert_receive {:hci, nil, {:start, @addr, ^radio}}, 500
      wait_until(fn -> status!(ctx).ready end)
      assert %{advertise_failures: 1, wedges: 0} = status!(ctx)
    end

    @tag :capture_log
    test "a closed channel during a transmit is uncertain and re-runs setup" do
      ctx = ready!(start_radio(retry_ms: 60_000))
      set(ctx, :le_set_advertising_data, {:error, :closed})

      assert {:error, {:uncertain, :closed}} = Radio.send_frame(frame(1), 40, server: ctx.radio)

      assert %{ready: false, last_error: {:advertise, :closed}, advertise_failures: 0} =
               status!(ctx)
    end
  end

  describe "stopping a frame" do
    @tag :capture_log
    test "an HCI status while disabling counts as a controller fault" do
      ctx = ready!(start_radio(wedge_failures: 1, wedge_retry_ms: 60_000))
      set(ctx, {:le_set_advertising_enable, false}, {:error, {:status, 0x0C}})
      :ok = Radio.send_frame(frame(1), 20, server: ctx.radio)

      wait_until(fn -> not status!(ctx).ready end)

      assert %{last_error: {:controller_wedged, {:status, 0x0C}}, wedges: 1, wedge_streak: 1} =
               status!(ctx)
    end

    @tag :capture_log
    test "below the wedge threshold it is counted, and setup re-runs" do
      ctx = ready!(start_radio(retry_ms: 60_000))
      set(ctx, {:le_set_advertising_enable, false}, {:error, :timeout})
      :ok = Radio.send_frame(frame(1), 20, server: ctx.radio)

      wait_until(fn -> not status!(ctx).ready end)

      assert %{last_error: {:stop_advertising, :timeout}, advertise_failures: 1, wedges: 0} =
               status!(ctx)
    end
  end

  describe "reports" do
    test "advertising reports become frames through the Carrier, other AD ignored" do
      ctx = ready!(start_radio())
      :ok = Radio.subscribe(self(), :all, server: ctx.radio)
      {addr, f, rssi} = captured()
      mac = Base.encode16(<<addr::48>>)

      report = %{address: addr, rssi: rssi, data: Carrier.ad_bytes(f)}
      :ok = FakeHciUser.emit(ctx.server, {:adv_report, report})
      assert_receive {:tuya_report, %{mac: ^mac, address: ^addr, frame: ^f, rssi: ^rssi}}

      # A name-only advert and a malformed one carry no frame.
      for data <- [<<5, 9, "bulb">>, <<0x1B, 3, 1, 2>>] do
        :ok = FakeHciUser.emit(ctx.server, {:adv_report, %{report | data: data}})
      end

      _ = status!(ctx)
      refute_received {:tuya_report, _}
    end

    test "messages from a channel that isn't the current one are ignored" do
      ctx = ready!(start_radio())
      :ok = Radio.subscribe(self(), :all, server: ctx.radio)
      {addr, f, rssi} = captured()
      report = %{address: addr, rssi: rssi, data: Carrier.ad_bytes(f)}

      send(ctx.pid, {:bluez_hci_user, self(), {:adv_report, report}})
      send(ctx.pid, {:bluez_hci_user, self(), {:closed, :epipe}})
      send(ctx.pid, {:bluez_hci_user, self(), {:hardware_error, 1}})

      assert %{ready: true, advertise_failures: 0, lease_held: true} = status!(ctx)
      refute_received {:tuya_report, _}
    end

    test "dropped reports are logged at most once a minute" do
      ctx = ready!(start_radio())

      log =
        capture_log(fn ->
          :ok = FakeHciUser.emit(ctx.server, {:reports_dropped, 10})
          :ok = FakeHciUser.emit(ctx.server, {:reports_dropped, 5})
          assert %{ready: true} = status!(ctx)
        end)

      assert log =~ "dropped 10 advertising reports"
      refute log =~ "dropped 5"
    end
  end

  describe "recovery" do
    @tag :capture_log
    test "hardware errors and command stalls are faults; the wedge is cleared by an HCI Reset" do
      ctx = ready!(start_radio(wedge_failures: 2, wedge_retry_ms: 20))

      :ok = FakeHciUser.emit(ctx.server, {:hardware_error, 0x01})
      assert %{ready: true, advertise_failures: 1} = status!(ctx)

      log =
        capture_log(fn ->
          :ok = FakeHciUser.emit(ctx.server, :command_stall)
          assert %{ready: false, last_error: {:controller_wedged, :command_stall}} = status!(ctx)
          wait_until(fn -> status!(ctx).ready end)
        end)

      assert log =~ "controller wedged"
      assert log =~ "resetting it in 20 ms"
      # Scanning stopped by the teardown; the same channel reset and re-set.
      assert [{:le_set_scan_enable, false, false, 1_000} | @bring_up] = calls(ctx.server)
      refute_received {:hci, nil, {:start, _, _}}
      assert %{recoveries: 1, wedges: 1} = status!(ctx)
    end

    @tag :capture_log
    test "an unplug (closed) is a loss; setup re-binds by MAC" do
      ctx = ready!(start_radio())
      :ok = FakeHciUser.emit(ctx.server, {:closed, :epipe})
      ctx = ready!(ctx)
      assert %{ready: true, recoveries: 0, transport: :user_channel} = status!(ctx)
    end

    @tag :capture_log
    test "a wedged controller whose channel closed is re-bound as the recovery" do
      ctx = ready!(start_radio(wedge_failures: 1, wedge_retry_ms: 100))

      log =
        capture_log(fn ->
          :ok = FakeHciUser.emit(ctx.server, {:hardware_error, 0x02})
          :ok = FakeHciUser.emit(ctx.server, {:closed, :epipe})
          ready!(ctx)
        end)

      assert log =~ "controller wedged"
      assert %{recoveries: 1, last_recovery_at: %DateTime{}} = status!(ctx)
    end

    @tag :capture_log
    test "the channel's process going down is a loss" do
      ctx = ready!(start_radio())
      Process.exit(ctx.server, :kill)
      ready!(ctx)
    end

    @tag :capture_log
    test "a failing health check (Read BD_ADDR) re-runs setup" do
      ctx = ready!(start_radio(health_check_ms: 20))
      set(ctx, :read_bd_addr, {:error, {:status, 0x01}})

      server = ctx.server
      assert_receive {:hci, ^server, {:read_bd_addr, 2_000}}, 500
      assert_receive {:hci, ^server, {:le_set_scan_enable, false, false, 1_000}}, 500
      assert_receive {:hci, ^server, {:reset, 5_000}}, 500
      clear(ctx, :read_bd_addr)
      wait_until(fn -> status!(ctx).ready end)
    end

    test "stopping resets the controller and closes the channel" do
      ctx = ready!(start_radio())
      :ok = Radio.send_frame(frame(1), 60_000, server: ctx.radio)
      stop_supervised!({Radio, 0})

      assert [
               {:le_set_advertising_data, _, _},
               {:le_set_advertising_enable, true, _},
               {:le_set_advertising_enable, false, _},
               {:reset, 1_000},
               :closed
             ] = calls(ctx.server)
    end
  end

  describe "transport fallback" do
    @tag :capture_log
    test "an absent adapter breaks a run of bind failures" do
      ctx =
        ready!(
          start_radio(transport: [Transport.UserChannel, StubTransport], fallback_failures: 2)
        )

      busy = {:error, {:bind, :ebusy}}
      absent = {:error, {:resolve, :not_found}}
      set(ctx, :start, [busy, absent, busy, absent, busy])
      :ok = FakeHciUser.emit(ctx.server, {:closed, :epipe})

      wait_until(fn -> status!(ctx).ready end, 5_000)
      refute_received {:stub, :init}
      assert %{transport: :user_channel, fallback_reason: nil} = status!(ctx)
    end

    @tag :capture_log
    test "BlueZ takes the index the MAC sits under now, not the one the Radio started with" do
      FakeBluez.ensure_started()
      FakeBluez.reset()
      FakeBluez.set_address(3, @mac)

      adapters = fn ->
        [
          %{path: "/org/bluez/hci0", address: "11:22:33:44:55:66"},
          %{path: "/org/bluez/hci3", address: @mac}
        ]
      end

      ctx =
        start_radio(
          [
            transport: [Transport.UserChannel, Transport.Bluez],
            fallback_failures: 1,
            adapter_index: 0,
            adapters_fun: adapters,
            bluez_radio: FakeBluez.Radio,
            mgmt: FakeBluez.Mgmt,
            rebus: FakeBluez.Rebus,
            dbus: FakeBluez.DBus,
            receiver: FakeBluez.Receiver
          ],
          %{index: 3}
        )

      ctx = ready!(ctx)
      assert %{transport: :user_channel, hci_index: 3} = status!(ctx)

      # Re-enumerated as hci3 behind the Radio's back, then the channel fails.
      set(ctx, :start, {:error, {:bind, :ebusy}})
      :ok = FakeHciUser.emit(ctx.server, {:closed, :epipe})
      wait_until(fn -> match?(%{transport: :bluez, ready: true}, status!(ctx)) end)

      assert %{hci_index: 3, fallback_reason: {:bind, :ebusy}} = status!(ctx)
      paths = for {:dbus_path, path, _member} <- FakeBluez.calls(), uniq: true, do: path
      assert paths == ["/org/bluez/hci3"]
    end

    @tag :capture_log
    test "the handoff to the next transport shows in the status until it is ready" do
      ctx =
        start_radio([transport: [Transport.UserChannel, StubTransport], retry_ms: 200], %{
          start: {:error, {:bind, :eperm}}
        })

      wait_until(fn -> status!(ctx).transport == :stub end)
      assert %{ready: false, transport_handoff: true} = status!(ctx)
      wait_until(fn -> status!(ctx).ready end)
      assert %{transport_handoff: false} = status!(ctx)
    end

    @tag :capture_log
    test "the handoff is bounded" do
      ctx =
        start_radio(
          [transport: [Transport.UserChannel, StubTransport], stub_fail: true, handoff_ms: 50],
          %{start: {:error, {:bind, :eperm}}}
        )

      wait_until(fn -> status!(ctx).transport == :stub end)
      wait_until(fn -> not status!(ctx).transport_handoff end)
      assert %{ready: false} = status!(ctx)
    end

    test "the memory resumes a second fallback, for the same chain only" do
      mac = "02:00:00:00:00:02"
      on_exit(fn -> :persistent_term.erase({Radio, :fallback, mac}) end)
      chain = [Transport.UserChannel, StubTransport, LastTransport]

      opts = [
        transport: chain,
        stub_fail: true,
        adapter_address: mac,
        fallback_memory_ms: 60_000
      ]

      log =
        capture_log(fn ->
          ctx = start_radio(opts, %{start: {:error, {:bind, :eperm}}})
          wait_until(fn -> match?(%{transport: :last, ready: true}, status!(ctx)) end)
          assert %{fallback_reason: :stub_down} = status!(ctx)
          stop_supervised!({Radio, 0})
          stop_supervised!(:control)
          flush_inits()

          # Restarted: straight onto the last transport, with its reason.
          ctx = start_radio(opts)
          wait_until(fn -> status!(ctx).ready end)
          assert %{transport: :last, fallback_reason: :stub_down} = status!(ctx)
          refute_received {:hci, nil, {:start, _, _}}
          refute_received {:stub, :init}
          stop_supervised!({Radio, 0})
          stop_supervised!(:control)

          # Another chain doesn't use it.
          ctx = start_radio(Keyword.put(opts, :transport, [Transport.UserChannel, LastTransport]))
          wait_until(fn -> status!(ctx).ready end)
          assert %{transport: :user_channel, fallback_reason: nil} = status!(ctx)
        end)

      assert log =~ "fell back to LastTransport 0 s ago (:stub_down); starting on it"
    end

    defp flush_inits do
      receive do
        {tag, _} when tag in [:hci, :stub, :last] -> flush_inits()
        {:hci, _, _} -> flush_inits()
      after
        0 -> :ok
      end
    end

    test "with a memory, a fallback outlives the Radio" do
      mac = "02:00:00:00:00:01"

      on_exit(fn -> :persistent_term.erase({Radio, :fallback, mac}) end)
      opts = [transport: [Transport.UserChannel, StubTransport], adapter_address: mac]
      address = mac |> String.replace(":", "") |> String.to_integer(16)

      log =
        capture_log(fn ->
          ctx =
            start_radio(opts ++ [fallback_memory_ms: 60_000], %{start: {:error, {:bind, :eperm}}})

          wait_until(fn -> status!(ctx).transport == :stub end)
          stop_supervised!({Radio, 0})
          stop_supervised!(:control)

          ctx = start_radio(opts ++ [fallback_memory_ms: 60_000])
          wait_until(fn -> status!(ctx).ready end)
          assert %{transport: :stub, fallback_reason: {:bind, :eperm}} = status!(ctx)
          stop_supervised!({Radio, 0})
          stop_supervised!(:control)

          # Without one, the next Radio tries the user channel again.
          ctx = start_radio(opts)
          wait_until(fn -> status!(ctx).ready end)
          assert %{transport: :user_channel} = status!(ctx)
        end)

      assert log =~ "fell back to StubTransport 0 s ago ({:bind, :eperm}); starting on it"
      # One bind from the first Radio, none from the second, one from the third.
      assert_received {:hci, nil, {:start, ^address, _}}
      assert_received {:hci, nil, {:start, ^address, _}}
      refute_received {:hci, nil, {:start, ^address, _}}
    end

    @tag :capture_log
    test "without an adapter address the next transport is used from the start" do
      ctx = start_radio(adapter_address: nil, transport: [Transport.UserChannel, StubTransport])
      assert_receive {:stub, :init}
      wait_until(fn -> status!(ctx).ready end)
      assert %{transport: :stub, fallback_reason: :no_adapter_address} = status!(ctx)
    end

    test "a bind failure during bring-up falls back for the Radio's lifetime" do
      log =
        capture_log(fn ->
          ctx =
            start_radio([transport: [Transport.UserChannel, StubTransport]], %{
              start: {:error, {:bind, :eperm}}
            })

          wait_until(fn -> status!(ctx).ready end)
          assert %{transport: :stub, fallback_reason: {:bind, :eperm}} = status!(ctx)
        end)

      assert log =~ "UserChannel failed ({:bind, :eperm}); falling back to StubTransport"
    end

    @tag :capture_log
    test "a controller bluetoothd is still configuring is retried, not fallen back from" do
      mac = "02:00:00:00:00:03"
      on_exit(fn -> :persistent_term.erase({Radio, :fallback, mac}) end)
      busy = {:error, {:power_off, :busy}}

      ctx =
        start_radio(
          [
            transport: [Transport.UserChannel, StubTransport],
            adapter_address: mac,
            fallback_memory_ms: 60_000
          ],
          %{start: [busy, busy, busy]}
        )

      wait_until(fn -> status!(ctx).ready end)
      assert %{transport: :user_channel, fallback_reason: nil} = status!(ctx)
      refute_received {:stub, :init}
      assert :persistent_term.get({Radio, :fallback, mac}, nil) == nil
    end

    @tag :capture_log
    test "a controller that stays busy falls back after a run of attempts" do
      ctx =
        start_radio([transport: [Transport.UserChannel, StubTransport], fallback_failures: 3], %{
          start: {:error, {:power_off, :busy}}
        })

      for _ <- 1..3, do: assert_receive({:hci, nil, {:start, @addr, _}}, 1_000)
      wait_until(fn -> status!(ctx).ready end)
      assert %{transport: :stub, fallback_reason: {:power_off, :busy}} = status!(ctx)
      refute_received {:hci, nil, {:start, _, _}}
    end

    @tag :capture_log
    test "an absent adapter is retried, not fallen back from" do
      ctx =
        start_radio([transport: [Transport.UserChannel, StubTransport]], %{
          start: {:error, {:resolve, :not_found}}
        })

      assert_receive {:hci, nil, {:start, @addr, _}}
      assert_receive {:hci, nil, {:start, @addr, _}}, 500
      refute_received {:stub, :init}
      assert %{ready: false, last_error: {:resolve, :not_found}} = status!(ctx)

      clear(ctx, :start)
      wait_until(fn -> status!(ctx).ready end)
      assert %{transport: :user_channel, fallback_reason: nil} = status!(ctx)
    end

    @tag :capture_log
    test "once it worked, only a run of recovery failures falls back" do
      ctx =
        ready!(
          start_radio(transport: [Transport.UserChannel, StubTransport], fallback_failures: 3)
        )

      set(ctx, :start, {:error, {:bind, :ebusy}})
      :ok = FakeHciUser.emit(ctx.server, {:closed, :epipe})

      for _ <- 1..3, do: assert_receive({:hci, nil, {:start, @addr, _}}, 1_000)
      assert_receive {:stub, :init}, 1_000
      wait_until(fn -> status!(ctx).ready end)
      assert %{transport: :stub, fallback_reason: {:bind, :ebusy}} = status!(ctx)
    end

    @tag :capture_log
    test "forced to the user channel, it never falls back" do
      ctx = start_radio([transport: Transport.UserChannel], %{start: {:error, {:bind, :ebusy}}})

      for _ <- 1..3, do: assert_receive({:hci, nil, {:start, @addr, _}}, 1_000)
      assert %{ready: false, transport: :user_channel, fallback_reason: nil} = status!(ctx)
    end

    test "falls back to the real Bluez transport, which takes the adapter after the release" do
      FakeBluez.ensure_started()
      FakeBluez.reset()
      FakeBluez.set_address(0, @mac)

      capture_log(fn ->
        ctx =
          start_radio(
            [
              transport: [Transport.UserChannel, Transport.Bluez],
              bluez_radio: FakeBluez.Radio,
              mgmt: FakeBluez.Mgmt,
              rebus: FakeBluez.Rebus,
              dbus: FakeBluez.DBus,
              receiver: FakeBluez.Receiver
            ],
            %{le_read_local_supported_features: {:error, {:status, 0x01}}}
          )

        server = bound!(ctx)
        assert_receive {:hci, ^server, :closed}
        wait_until(fn -> status!(ctx).ready end)

        assert %{
                 transport: :bluez,
                 fallback_reason: {:init, :le_features, {:status, 0x01}},
                 lease_held: true,
                 discovering: true
               } = status!(ctx)

        :ok = Radio.send_frame(frame(1), 40, server: ctx.radio)
        assert [_ad] = for({:advertise, data, _} <- FakeBluez.calls(), do: data)
      end)
    end
  end

  describe "held radio" do
    setup do
      n = System.unique_integer([:positive])
      registry = :"uc_held_#{n}"
      pubsub = :"uc_held_pubsub_#{n}"
      start_supervised!({HeldRadios, registry: registry})
      start_supervised!({Phoenix.PubSub, name: pubsub})
      :ok = Phoenix.PubSub.subscribe(pubsub, HeldRadios.topic())
      {:ok, held: [registry: registry, pubsub: pubsub]}
    end

    defp held(ctx), do: HeldRadios.list(registry: ctx.held[:registry])

    test "bound to the right controller, the Radio holds its MAC under the index", ctx do
      radio = ready!(start_radio(held_radios: ctx.held, adapter_address: String.downcase(@mac)))
      pid = radio.pid

      assert_receive {:bluetooth_held_changed}
      assert held(ctx) == [%{address: @mac, index: 0, holder: :tuya_mesh, pid: pid}]
      KeyLeak.refute_keys(held(ctx))

      # Stopping hands the controller back and drops the hold.
      stop_supervised!({Radio, 0})
      assert_receive {:bluetooth_held_changed}
      assert held(ctx) == []
    end

    @tag :capture_log
    test "another controller under the index is never recorded as held", ctx do
      radio = start_radio([held_radios: ctx.held], %{bd_addr: 0x112233445566})
      server = bound!(radio)

      assert_receive {:hci, ^server, :closed}
      refute_received {:bluetooth_held_changed}
      assert held(ctx) == []
    end

    @tag :capture_log
    test "a setup failing after BD_ADDR that closes the channel drops the hold", ctx do
      # A timed-out step closes the channel; no retry within the test.
      radio =
        start_radio([held_radios: ctx.held, retry_ms: 60_000], %{
          read_local_version: [{:error, :timeout}]
        })

      server = bound!(radio)
      assert_receive {:hci, ^server, :closed}, 1_000
      assert %{ready: false} = status!(radio)
      assert held(ctx) == []
    end

    @tag :capture_log
    test "falling back after a post-BD_ADDR failure drops the hold", ctx do
      radio =
        start_radio(
          [held_radios: ctx.held, transport: [Transport.UserChannel, StubTransport]],
          %{le_read_local_supported_features: {:error, {:status, 0x01}}}
        )

      server = bound!(radio)
      assert_receive {:stub, :init}, 1_000
      assert_receive {:hci, ^server, :closed}, 1_000
      wait_until(fn -> status!(radio).transport == :stub end)
      assert held(ctx) == []
    end

    @tag :capture_log
    test "an unplug drops the hold until the channel is bound again", ctx do
      radio = ready!(start_radio(held_radios: ctx.held))
      assert_receive {:bluetooth_held_changed}

      set(radio, :start, {:error, {:resolve, :not_found}})
      :ok = FakeHciUser.emit(radio.server, {:closed, :epipe})
      assert_receive {:bluetooth_held_changed}, 1_000
      assert held(ctx) == []

      clear(radio, :start)
      ready!(radio)
      assert [%{address: @mac}] = held(ctx)
    end

    @tag :capture_log
    test "a crashed Radio holds nothing", ctx do
      radio = ready!(start_radio(held_radios: ctx.held))
      pid = radio.pid
      assert [%{pid: ^pid}] = held(ctx)

      Process.exit(pid, :kill)
      assert Enum.all?(held(ctx), &(&1.pid != pid))
    end
  end

  test "no key material in the status, the server state or the logs" do
    inv = Inventory.decode!(KeyLeak.json())
    bulb = hd(inv.bulbs)

    log =
      capture_log(fn ->
        ctx = ready!(start_radio(wedge_failures: 1, wedge_retry_ms: 20))
        :ok = Radio.subscribe(self(), :all, server: ctx.radio)

        f =
          P2.build(1, 0x05, 0x8001, bulb.node_id, 7, <<1, 1, 1>>, bulb.local_key, inv.beacon_key)

        :ok = Radio.send_frame(f, 60_000, server: ctx.radio)

        reply =
          P2.build(1, 0x05, bulb.node_id, 0x8001, 8, <<1, 1, 1>>, bulb.local_key, inv.beacon_key)

        report = %{address: 0xDC23530FB34A, rssi: -50, data: Carrier.ad_bytes(reply)}
        :ok = FakeHciUser.emit(ctx.server, {:adv_report, report})
        assert_receive {:tuya_report, _}

        KeyLeak.refute_keys(status!(ctx))
        KeyLeak.refute_keys(:sys.get_status(ctx.pid))

        :ok = FakeHciUser.emit(ctx.server, {:hardware_error, 0x03})
        :ok = FakeHciUser.emit(ctx.server, {:reports_dropped, 3})
        :ok = FakeHciUser.emit(ctx.server, {:closed, :epipe})
        ready!(ctx)
        KeyLeak.refute_keys(status!(ctx))
        KeyLeak.refute_keys(:sys.get_status(ctx.pid))
      end)

    assert log =~ "controller wedged"
    KeyLeak.refute_keys(log)
  end
end
