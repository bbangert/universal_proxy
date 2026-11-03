defmodule UniversalProxy.TuyaBeaconMesh.RadioTransportTest do
  # The Radio's core against a transport that is neither BlueZ nor HCI:
  # frame windows, wedge counting, recovery and fan-out don't depend on
  # how the controller is reached.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias UniversalProxy.TuyaBeaconMesh.{Carrier, P2, Radio}

  @key "jngwRugsvwtGN00a"

  defmodule FakeTransport do
    @moduledoc false
    # Reports every callback to the test pid as `{:transport, call}`.
    # Results are read from the `:control` Agent (`setup`, `transmit`,
    # `stop_transmit`, `health_check`: a value to return instead of
    # success). Messages `{:fake, events}` sent to the Radio come back as
    # those events.
    @behaviour UniversalProxy.TuyaBeaconMesh.Radio.Transport

    @impl true
    def init(opts) do
      case Keyword.fetch(opts, :fail_init) do
        {:ok, reason} ->
          {:error, reason}

        :error ->
          send(opts[:test], {:transport, {:init, opts[:adapter_index], opts[:adapter_address]}})

          {:ok,
           %{
             test: Keyword.fetch!(opts, :test),
             control: Keyword.fetch!(opts, :control),
             index: Keyword.fetch!(opts, :adapter_index),
             address: Keyword.fetch!(opts, :adapter_address),
             up: false,
             next_instance: 1
           }}
      end
    end

    @impl true
    def setup(state, reset?) do
      tell(state, {:setup, reset?})
      events = if reset?, do: [{:controller_reset, :hci_reset}], else: []

      case control(state, :setup) do
        nil -> {:ok, %{state | up: true}, events}
        reason -> {:error, reason, state, events}
      end
    end

    @impl true
    def teardown(state) do
      tell(state, :teardown)
      %{state | up: false}
    end

    @impl true
    def terminate(reason, state) do
      tell(state, {:terminate, reason})
      :ok
    end

    @impl true
    def transmit(state, ad_bytes) do
      case control(state, :transmit) do
        nil ->
          instance = state.next_instance
          tell(state, {:transmit, instance, ad_bytes})
          {:ok, instance, %{state | next_instance: instance + 1}}

        error ->
          tell(state, {:transmit_refused, error})
          {:error, error, state}
      end
    end

    @impl true
    def stop_transmit(state, instance) do
      tell(state, {:stop_transmit, instance})

      case control(state, :stop_transmit) do
        nil -> {:ok, state}
        reason -> {:error, reason, state}
      end
    end

    @impl true
    def health_check(state) do
      tell(state, :health_check)

      case control(state, :health_check) do
        nil -> :ok
        reason -> {:error, reason}
      end
    end

    @impl true
    def handle_info({:fake, events}, state), do: {:ok, events, state}
    def handle_info(_msg, _state), do: :unhandled

    @impl true
    def status(state), do: %{lease_held: state.up, discovering: state.up, listening: state.up}

    defp tell(state, call), do: send(state.test, {:transport, call})
    defp control(state, key), do: Agent.get(state.control, &Map.get(&1, key))
  end

  defp frame(sn), do: P2.build(1, 0x05, 0x8001, 0x0002, sn, <<1, 2, 3>>, @key, @key)

  defp device_frame(sn), do: P2.build(1, 0x05, 0x6506, 0xFFFF, sn, <<1, 2, 3>>, @key, @key)

  defp hop_variant(frame) do
    <<hdr, rest::binary>> = P2.normalize(frame)
    <<hdr + 1, rest::binary>>
  end

  defp start_radio(opts \\ [], control \\ %{}) do
    # Supervised before the radio, so it outlives the radio's terminate.
    control = start_supervised!({Agent, fn -> control end}, id: :control)
    name = :"radio_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {Radio,
         Keyword.merge(
           [
             transport: FakeTransport,
             test: self(),
             control: control,
             name: name,
             retry_ms: 20,
             adapter_address: "aa:bb:cc:dd:ee:01"
           ],
           opts
         )}
      )

    %{radio: name, pid: pid, control: control}
  end

  defp set(ctx, key, value), do: Agent.update(ctx.control, &Map.put(&1, key, value))
  defp clear(ctx, key), do: Agent.update(ctx.control, &Map.delete(&1, key))

  defp status!(ctx) do
    {:ok, status} = Radio.status(server: ctx.radio)
    status
  end

  defp events(ctx, events) do
    send(ctx.pid, {:fake, events})
    status!(ctx)
  end

  defp ready!(ctx) do
    assert_receive {:transport, {:setup, _reset?}}
    wait_until(fn -> status!(ctx).ready end)
    ctx
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

  test "init gets the normalised adapter; a refusing transport stops the start" do
    ctx = ready!(start_radio())
    assert_received {:transport, {:init, 0, "AA:BB:CC:DD:EE:01"}}
    assert %{adapter_address: "AA:BB:CC:DD:EE:01", adapter_index: 0} = status!(ctx)

    {:ok, control} = Agent.start_link(fn -> %{} end)

    assert {:error, {{:transport_init, :nope}, _child}} =
             start_supervised(
               {Radio,
                [
                  transport: FakeTransport,
                  test: self(),
                  control: control,
                  fail_init: :nope,
                  name: :radio_refused
                ]},
               id: :refused
             )
  end

  test "status merges the transport's fields" do
    ctx = ready!(start_radio())

    assert %{ready: true, lease_held: true, discovering: true, listening: true, tx: nil} =
             status!(ctx)
  end

  describe "frame windows" do
    test "the core opens and closes each window, one frame at a time, in order" do
      ctx = ready!(start_radio())
      a = frame(41)
      b = frame(42)

      :ok = Radio.send_frame(a, 40, server: ctx.radio)
      :ok = Radio.send_frame(b, 40, server: ctx.radio)
      ad_a = Carrier.ad_bytes(a)
      ad_b = Carrier.ad_bytes(b)

      assert_receive {:transport, {:transmit, 1, ^ad_a}}
      assert %{tx: %{class: :normal, instance: 1}, queued: 1, last_tx_sn: 41} = status!(ctx)
      refute_received {:transport, {:transmit, _, _}}

      assert_receive {:transport, {:stop_transmit, 1}}, 500
      assert_receive {:transport, {:transmit, 2, ^ad_b}}
      assert %{last_tx_sn: 42} = status!(ctx)
      assert_receive {:transport, {:stop_transmit, 2}}, 500
      wait_until(fn -> status!(ctx).tx == nil end)
    end

    test "a refused frame is reported and the next queued one is tried" do
      ctx = ready!(start_radio())
      set(ctx, :transmit, {:refused, :busy})

      log =
        capture_log(fn ->
          assert {:error, {:advertise, :busy}} = Radio.send_frame(frame(1), 40, server: ctx.radio)
        end)

      assert log =~ "advertise failed (:busy)"
      assert %{ready: true, advertise_failures: 0, last_tx_sn: nil} = status!(ctx)
    end

    test "an uncertain transmit re-runs setup" do
      ctx = ready!(start_radio())
      set(ctx, :transmit, {:uncertain, :gone})

      capture_log(fn ->
        assert {:error, {:uncertain, :gone}} = Radio.send_frame(frame(1), 40, server: ctx.radio)
      end)

      assert_receive {:transport, :teardown}
      assert %{ready: false, last_error: {:advertise, :gone}} = status!(ctx)
      clear(ctx, :transmit)
      assert_receive {:transport, {:setup, false}}
      wait_until(fn -> status!(ctx).ready end)
    end

    test "an advert that won't come off air re-runs setup" do
      ctx = ready!(start_radio())
      set(ctx, :stop_transmit, :stuck)
      :ok = Radio.send_frame(frame(1), 60_000, server: ctx.radio)

      capture_log(fn -> :ok = Radio.stop_tx(server: ctx.radio) end)
      assert %{ready: false, last_error: {:stop_advertising, :stuck}} = status!(ctx)
    end
  end

  describe "wedge counting" do
    @tag :capture_log
    test "fault events count like controller-fault refusals and wedge it" do
      ctx = ready!(start_radio(wedge_retry_ms: 30))

      events(ctx, [{:fault, :hardware_error}])
      set(ctx, :transmit, {:fault, :cmd_timeout})

      assert {:error, {:advertise, :cmd_timeout}} =
               Radio.send_frame(frame(1), 40, server: ctx.radio)

      assert %{ready: true, advertise_failures: 2} = status!(ctx)

      events(ctx, [{:fault, :hardware_error}])

      assert %{
               ready: false,
               last_error: {:controller_wedged, :hardware_error},
               wedges: 1,
               wedge_streak: 1
             } = status!(ctx)

      assert_receive {:transport, :teardown}

      # The next setup asks for a reset; the reset it reports counts.
      clear(ctx, :transmit)
      assert_receive {:transport, {:setup, true}}, 500
      wait_until(fn -> status!(ctx).ready end)
      assert %{recoveries: 1, wedge_streak: 1, last_recovery_at: %DateTime{}} = status!(ctx)

      :ok = Radio.send_frame(frame(2), 40, server: ctx.radio)
      assert %{wedge_streak: 0, controller_reset_needed: false} = status!(ctx)
    end

    test "a reset that ran isn't asked for again when a later step failed" do
      ctx = ready!(start_radio(wedge_retry_ms: 30, wedge_failures: 1))
      set(ctx, :setup, :later_step)

      log =
        capture_log(fn ->
          events(ctx, [{:fault, :hardware_error}])
          assert_receive {:transport, {:setup, true}}, 500
          assert_receive {:transport, {:setup, false}}, 500
        end)

      refute log =~ "power-cycled"
      assert %{recoveries: 1, last_error: :later_step} = status!(ctx)
    end

    @tag :capture_log
    test "faults while not ready are ignored" do
      ctx = start_radio([retry_ms: 60_000], %{setup: :down})
      assert_receive {:transport, {:setup, false}}
      assert %{ready: false, last_error: :down} = status!(ctx)

      events(ctx, [{:fault, :hardware_error}, {:fault, :hardware_error}, {:fault, :x}])
      assert %{ready: false, wedges: 0, advertise_failures: 0} = status!(ctx)
      # Held not ready: no retry (60 s away) and no wedge-driven setup.
      refute_receive {:transport, {:setup, _}}, 100
    end
  end

  describe "losses and health" do
    @tag :capture_log
    test "a lost event tears down and retries setup, keeping subscriptions" do
      ctx = ready!(start_radio())
      :ok = Radio.subscribe(self(), :all, server: ctx.radio)
      :ok = Radio.send_frame(frame(1), 60_000, server: ctx.radio)
      :ok = Radio.send_frame(frame(2), 60_000, server: ctx.radio)

      events(ctx, [{:lost, :socket_closed}])
      assert_receive {:transport, {:stop_transmit, 1}}
      assert_receive {:transport, :teardown}
      assert {:error, :not_ready} = Radio.send_frame(frame(3), 40, server: ctx.radio)

      assert_receive {:transport, {:setup, false}}
      wait_until(fn -> status!(ctx).ready end)
      assert %{subscribers: 1, queued: 0, tx: nil} = status!(ctx)
    end

    @tag :capture_log
    test "a failed health check re-runs setup" do
      ctx = ready!(start_radio(health_check_ms: 20))
      assert_receive {:transport, :health_check}
      set(ctx, :health_check, :scan_stopped)
      assert_receive {:transport, :teardown}, 500
      assert_receive {:transport, {:setup, false}}
    end

    test "messages the transport doesn't handle are ignored" do
      ctx = ready!(start_radio())
      send(ctx.pid, {:EXIT, self(), :whatever})
      send(ctx.pid, :something)
      assert %{ready: true} = status!(ctx)
    end

    test "stop takes the advert off air and terminates the transport" do
      ctx = ready!(start_radio())
      :ok = Radio.send_frame(frame(1), 60_000, server: ctx.radio)
      stop_supervised!({Radio, 0})
      assert_receive {:transport, {:stop_transmit, 1}}
      assert_receive {:transport, {:terminate, :shutdown}}
    end
  end

  describe "reports" do
    test "fan out with dedupe and echo dropping" do
      ctx = ready!(start_radio())
      :ok = Radio.subscribe(self(), {:mac, "DC23530FB34A"}, server: ctx.radio)
      f = device_frame(7)

      events(ctx, [
        {:report, 0xDC23530FB34A, f, -60},
        {:report, 0xDC23530FB34A, hop_variant(f), -61},
        {:report, 0xDC23530FB34B, device_frame(8), -62}
      ])

      assert_received {:tuya_report, %{mac: "DC23530FB34A", frame: ^f, rssi: -60}}
      refute_received {:tuya_report, _}

      own = frame(9)
      :ok = Radio.send_frame(own, 40, server: ctx.radio)
      events(ctx, [{:report, 0xDC23530FB34A, hop_variant(own), -60}])
      refute_received {:tuya_report, _}
    end
  end
end
