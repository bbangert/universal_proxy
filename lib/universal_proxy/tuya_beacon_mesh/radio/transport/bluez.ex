defmodule UniversalProxy.TuyaBeaconMesh.Radio.Transport.Bluez do
  @moduledoc """
  `UniversalProxy.TuyaBeaconMesh.Radio.Transport` over `bluetoothd` and
  the kernel's Mgmt interface: LE discovery over D-Bus, a raw HCI advert
  receiver, and one Mgmt advertising instance per frame under a
  `Bluez.Radio` lease.

  `Bluez.Radio` and `Bluez.Mgmt` must already be running: they are shared
  infrastructure the host supervises, and the Radio never starts or links
  them. Setup:

    * opens its own system-bus connection (kept across retries) and, when
      `:adapter_address` is given, checks that `/org/bluez/hci<index>` is
      still that adapter (`Adapter1.Address`). An index is reused when a
      dongle is unplugged and another takes its place, so a mismatch fails
      setup with `{:wrong_adapter, address}` before anything below touches
      the adapter (no lease, no power, no discovery, no advert);
    * with a reset asked for (after a wedge), power-cycles the adapter
      (`Adapter1.Powered` false, then true): right after the fence and
      before the lease is taken. The kernel closes the controller on
      power-off and re-initialises it on power-on, which clears its
      advertising state. `Bluez.Mgmt` exposes no separate HCI Reset, so
      there is no stronger in-band step;
    * checks the adapter through `Bluez.Mgmt` (*Read Advertising
      Features*), subscribes to `Bluez.Radio`'s lease-end notices and
      acquires the `:mgmt` lease for the adapter — the Radio is the
      lease holder, so only it may advertise;
    * powers the adapter (`Adapter1.Powered = true`: `Bluez.Client` powers
      only the adapter it claims, and a dedicated mesh adapter is never
      claimed) and starts LE discovery with `DuplicateData: true` on it;
    * starts a linked `Bluez.AdvertReceiver` whose `on_report:` callback
      forwards only AD 0x03 26-byte frames to the Radio.

  Losses reported as `{:lost, reason}`: the lease ends, `Bluez.Radio` or
  the D-Bus connection goes down, or the receiver exits. Some losses leave
  every process alive (an adapter removed or a `bluetoothd` restart ends
  discovery while the connection, lease and receiver survive), so the
  health check verifies that the receiver is `listening?`, that the
  adapter's `Adapter1.Discovering` is true and (with `:adapter_address`)
  that the index still names that adapter.

  Adverts are connectable, at the 20/30 ms interval, with no kernel
  `duration_ms:` (on a controller without hardware offload `Bluez.Mgmt`
  refuses a finite duration while another instance is registered, see its
  "Software rotation" section), so the Radio's own timer ends them.
  Advertise errors map to: `:uncertain` for those meaning the lease or
  `Bluez.Mgmt` is gone (`:lease_expired`, `:not_lease_holder`,
  `:not_running`), `:fault` for MGMT `:failed` and `:timeout` (HCI command
  errors the kernel has no specific status for, and HCI command timeouts),
  `:refused` for anything else.

  The `Bluez.*` modules are injectable (`:bluez_radio`, `:mgmt`,
  `:rebus`, `:dbus`, `:receiver` options) so the Radio is testable
  off-board; `:receiver_stop_ms` (default #{2_000}) is how long a stopping
  receiver may take before it is killed.
  """

  @behaviour UniversalProxy.TuyaBeaconMesh.Radio.Transport

  alias UniversalProxy.TuyaBeaconMesh.{Carrier, Radio}

  @receiver_stop_ms 2_000
  # Kept short: the health check runs in the Radio's loop.
  @health_call_ms 2_000
  @props_iface "org.freedesktop.DBus.Properties"
  @adapter_iface "org.bluez.Adapter1"

  # They don't prove the frame stayed off air (Mgmt can crash mid-request,
  # and reports :lease_expired for an instance that already went on air).
  @uncertain_advertise_errors [:lease_expired, :not_lease_holder, :not_running]
  @fault_advertise_errors [:failed, :timeout]

  @impl true
  def init(opts) do
    {:ok,
     %{
       adapter_index: Keyword.get(opts, :adapter_index, 0),
       adapter_address: Keyword.get(opts, :adapter_address),
       bluez_radio: Keyword.get(opts, :bluez_radio, Bluez.Radio),
       mgmt: Keyword.get(opts, :mgmt, Bluez.Mgmt),
       rebus: Keyword.get(opts, :rebus, Bluez.Rebus),
       dbus: Keyword.get(opts, :dbus, Bluez.DBus),
       receiver: Keyword.get(opts, :receiver, Bluez.AdvertReceiver),
       receiver_stop_ms: Keyword.get(opts, :receiver_stop_ms, @receiver_stop_ms),
       radio_mon: nil,
       lease: nil,
       conn: nil,
       conn_mon: nil,
       rx: nil,
       rx_name: nil,
       discovering: false
     }}
  end

  # Each step records what it got in the state it returns (also on error),
  # so teardown/1 can undo exactly that much. A reset that went through is
  # reported even when a later step fails, so it isn't repeated.
  @impl true
  def setup(state, reset?) do
    with {:ok, state} <- connect(state),
         {:ok, state} <- check_adapter(state),
         {:ok, state, events} <- reset_controller(state, reset?) do
      case bring_up(state) do
        {:ok, state} -> {:ok, state, events}
        {:error, reason, state} -> {:error, reason, state, events}
      end
    else
      {:error, reason, state} -> {:error, reason, state, []}
    end
  end

  defp bring_up(state) do
    with {:ok, state} <- probe_mgmt(state),
         {:ok, state} <- watch_bluez_radio(state),
         {:ok, state} <- acquire(state),
         {:ok, state} <- power_on(state),
         {:ok, state} <- start_discovery(state) do
      start_receiver(state)
    end
  end

  # Takes everything setup got back down, except the D-Bus connection and
  # the Bluez.Radio subscription, which are reused by the next attempt.
  # Releasing the lease removes every instance sent under it.
  @impl true
  def teardown(state) do
    state = state |> stop_receiver() |> stop_discovery()
    if state.lease != nil, do: state.bluez_radio.release(state.lease)
    %{state | lease: nil}
  end

  # The D-Bus connection closes, and the Bluez.Radio monitor goes, with the
  # Radio process.
  @impl true
  def terminate(_reason, state) do
    _ = teardown(state)
    :ok
  end

  @impl true
  def transmit(state, ad_bytes) do
    case state.mgmt.advertise(state.lease, ad_bytes, flags: [:connectable]) do
      {:ok, instance} ->
        {:ok, instance, state}

      {:error, reason} when reason in @uncertain_advertise_errors ->
        {:error, {:uncertain, reason}, state}

      {:error, reason} when reason in @fault_advertise_errors ->
        {:error, {:fault, reason}, state}

      {:error, reason} ->
        {:error, {:refused, reason}, state}
    end
  end

  # Without a lease (it ended) Mgmt has already removed the instance.
  @impl true
  def stop_transmit(%{lease: nil} = state, _instance), do: {:ok, state}

  def stop_transmit(state, instance) do
    case state.mgmt.stop_advertising(state.lease, instance) do
      :ok -> {:ok, state}
      {:error, :unknown_instance} -> {:ok, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  @impl true
  def health_check(state) do
    if state.receiver.listening?(state.rx_name) do
      with :ok <- check_discovering(state), do: verify_address(state)
    else
      {:error, :receiver_not_listening}
    end
  end

  @impl true
  def status(state) do
    %{
      lease_held: state.lease != nil and state.bluez_radio.valid?(state.lease),
      discovering: state.discovering,
      listening: state.rx_name != nil and state.receiver.listening?(state.rx_name)
    }
  end

  @impl true
  def handle_info({__MODULE__, :report, address, frame, rssi}, state),
    do: {:ok, [{:report, address, frame, rssi}], state}

  # Bluez.Radio notifies every subscriber of every lease end; only ours
  # matters. Mgmt has already taken its adverts off air.
  def handle_info({:radio_lease_ended, ref}, %{lease: %{ref: ref}} = state),
    do: {:ok, [{:lost, :lease_ended}], %{state | lease: nil}}

  def handle_info({:DOWN, mon, :process, _pid, reason}, %{radio_mon: mon} = state)
      when mon != nil do
    {:ok, [{:lost, {:bluez_radio_down, reason}}], %{state | radio_mon: nil, lease: nil}}
  end

  # BlueZ drops a client's discovery session when its connection closes.
  def handle_info({:DOWN, mon, :process, _pid, reason}, %{conn_mon: mon} = state)
      when mon != nil do
    {:ok, [{:lost, {:dbus_down, reason}}],
     %{state | conn: nil, conn_mon: nil, discovering: false}}
  end

  def handle_info({:EXIT, rx, reason}, %{rx: rx} = state) when is_pid(rx),
    do: {:ok, [{:lost, {:receiver_exit, reason}}], %{state | rx: nil, rx_name: nil}}

  def handle_info(_msg, _state), do: :unhandled

  # ── Setup steps ──────────────────────────────────────────────────────

  # The connection is bound to the Radio process (rebus closes it when it
  # exits) but not linked, so it is monitored instead.
  defp connect(%{conn: nil} = state) do
    case rebus_connect(state) do
      {:ok, conn} when is_pid(conn) ->
        {:ok, %{state | conn: conn, conn_mon: Process.monitor(conn)}}

      other ->
        {:error, {:dbus_connect, other}, state}
    end
  end

  defp connect(state), do: {:ok, state}

  # Bluez.Rebus.connect/1 exits when its ConnectionSupervisor isn't up.
  defp rebus_connect(state) do
    state.rebus.connect(:system)
  catch
    :exit, reason -> {:exit, reason}
  end

  defp check_adapter(state) do
    case verify_address(state) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp verify_address(%{adapter_address: nil}), do: :ok

  defp verify_address(state) do
    case get_property(state, "Address") do
      {:ok, [{_sig, address}]} when is_binary(address) ->
        if String.upcase(address) == state.adapter_address,
          do: :ok,
          else: {:error, {:wrong_adapter, String.upcase(address)}}

      {:ok, _other} ->
        {:error, {:adapter_address, :unexpected_reply}}

      {:error, reason} ->
        {:error, {:adapter_address, reason}}
    end
  end

  defp check_discovering(state) do
    case get_property(state, "Discovering") do
      {:ok, [{_sig, true}]} -> :ok
      {:ok, _other} -> {:error, :not_discovering}
      {:error, reason} -> {:error, {:discovering, reason}}
    end
  end

  defp get_property(state, name) do
    state.dbus.call(
      state.conn,
      adapter_path(state),
      @props_iface,
      "Get",
      "ss",
      [@adapter_iface, name],
      @health_call_ms
    )
  end

  # Runs after the adapter fence, with no lease held, and counts only once
  # both halves went through. BlueZ answers a Powered Set only once the
  # kernel has finished closing (or opening) the controller.
  defp reset_controller(state, false), do: {:ok, state, []}

  defp reset_controller(state, true) do
    with {:off, {:ok, _}} <- {:off, set_powered(state, false)},
         {:on, {:ok, _}} <- {:on, set_powered(state, true)} do
      {:ok, state, [{:controller_reset, :power_cycle}]}
    else
      {:off, {:error, reason}} -> {:error, {:power_cycle, reason}, state}
      {:on, {:error, reason}} -> {:error, {:power, reason}, state}
    end
  end

  defp probe_mgmt(state) do
    case state.mgmt.read_advertising_features(state.adapter_index) do
      {:ok, _features} -> {:ok, state}
      {:error, reason} -> {:error, {:mgmt, reason}, state}
    end
  end

  # Subscribed before acquiring, so a lease end can't slip in between.
  defp watch_bluez_radio(%{radio_mon: nil} = state) do
    case state.bluez_radio.subscribe() do
      {:ok, pid} -> {:ok, %{state | radio_mon: Process.monitor(pid)}}
      {:error, reason} -> {:error, {:bluez_radio, reason}, state}
    end
  end

  defp watch_bluez_radio(state), do: {:ok, state}

  defp acquire(state) do
    case state.bluez_radio.acquire(adapter_index: state.adapter_index) do
      {:ok, lease} -> {:ok, %{state | lease: lease}}
      {:error, reason} -> {:error, {:lease, reason}, state}
    end
  end

  # Idempotent: setting Powered on a powered adapter is a no-op. It is not
  # undone on teardown, since the adapter is dedicated to the mesh.
  defp power_on(state) do
    case set_powered(state, true) do
      {:ok, _} -> {:ok, state}
      {:error, reason} -> {:error, {:power, reason}, state}
    end
  end

  defp set_powered(state, on?) do
    body = [@adapter_iface, "Powered", {"b", on?}]
    state.dbus.call(state.conn, adapter_path(state), @props_iface, "Set", "ssv", body)
  end

  defp start_discovery(state) do
    filter = [{"Transport", {"s", "le"}}, {"DuplicateData", {"b", true}}]

    with {:ok, _} <- adapter_call(state, "SetDiscoveryFilter", "a{sv}", [filter]),
         {:ok, _} <- start_discovery_call(state) do
      {:ok, %{state | discovering: true}}
    else
      {:error, reason} -> {:error, {:discovery, reason}, state}
    end
  end

  defp start_discovery_call(state) do
    case adapter_call(state, "StartDiscovery", "", []) do
      # Already discovering for this connection: goal reached.
      {:error, "org.bluez.Error.InProgress"} -> {:ok, []}
      other -> other
    end
  end

  defp stop_discovery(%{discovering: true, conn: conn} = state) when conn != nil do
    _ = adapter_call(state, "StopDiscovery", "", [])
    %{state | discovering: false}
  end

  defp stop_discovery(state), do: %{state | discovering: false}

  defp adapter_call(state, member, signature, body) do
    state.dbus.call(state.conn, adapter_path(state), @adapter_iface, member, signature, body)
  end

  defp adapter_path(state), do: "/org/bluez/hci#{state.adapter_index}"

  defp start_receiver(state) do
    radio = self()

    on_report = fn report ->
      for frame <- Carrier.frames(report.data) do
        send(radio, {__MODULE__, :report, report.address, frame, report.rssi})
      end
    end

    name = Module.concat(Radio, "Rx#{state.adapter_index}")

    # `{:already_started, pid}` is not ours (not linked, not stopped on
    # teardown): an error like any other, retried.
    case state.receiver.start_link(
           name: name,
           adapter_index: state.adapter_index,
           on_report: on_report
         ) do
      {:ok, pid} -> {:ok, %{state | rx: pid, rx_name: name}}
      {:error, reason} -> {:error, {:receiver, reason}, state}
    end
  end

  # Unlinked first, so stopping it doesn't come back as an {:EXIT, ...}.
  # One that won't stop in time is killed: left alive it would keep the
  # registered Rx name and fail every later setup with already_started.
  defp stop_receiver(%{rx: rx} = state) when is_pid(rx) do
    Process.unlink(rx)

    try do
      GenServer.stop(rx, :normal, state.receiver_stop_ms)
    catch
      :exit, _reason -> kill_receiver(rx)
    end

    %{state | rx: nil, rx_name: nil}
  end

  defp stop_receiver(state), do: %{state | rx: nil, rx_name: nil}

  defp kill_receiver(rx) do
    ref = Process.monitor(rx)
    Process.exit(rx, :kill)

    receive do
      {:DOWN, ^ref, :process, ^rx, _reason} -> :ok
    after
      1_000 -> :ok
    end

    Process.demonitor(ref, [:flush])
  end
end
