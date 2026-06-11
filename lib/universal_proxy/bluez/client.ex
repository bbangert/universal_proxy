defmodule UniversalProxy.Bluez.Client do
  @moduledoc """
  Persistent `rebus` D-Bus client to `org.bluez`. Holds the system-bus
  connection open (BlueZ ties discovery to the calling connection, so a
  long-lived owner is required), powers on the adapter, sets an LE discovery
  filter, starts discovery, and turns BlueZ device signals into
  advertisements for `UniversalProxy.ESPHome.BluetoothScanner`.

  Flow:

    1. `Rebus.connect(:system)` → the system bus at `/run/dbus/system_bus_socket`
       (the socket `UniversalProxy.Bluez`'s `dbus-daemon` listens on).
    2. `Adapter1.Powered = true`, `Adapter1.SetDiscoveryFilter({Transport: le,
       DuplicateData: true})`, `Adapter1.StartDiscovery`.
    3. Subscribe to all signals; handle `InterfacesAdded` (new device, full
       props) and `PropertiesChanged` (RSSI/data updates, partial props) for
       `org.bluez.Device1` objects under the adapter.
    4. Merge each device's props in a cache, hand them to
       `UniversalProxy.Bluez.Advert.reconstruct/1`, and fan the reconstructed
       advert out via `BluetoothScanner.on_advertisement/1`.

  Defensive by design: D-Bus body shapes are parsed with `try`/`rescue` so a
  surprising shape logs and is skipped rather than crashing the client (which
  would restart the whole BlueZ subtree).
  """

  use GenServer
  require Logger

  alias UniversalProxy.Bluez.Advert
  alias UniversalProxy.ESPHome.BluetoothScanner

  @adapter_path "/org/bluez/hci0"
  @adapter_iface "org.bluez.Adapter1"
  @device_iface "org.bluez.Device1"
  @props_iface "org.freedesktop.DBus.Properties"
  @om_iface "org.freedesktop.DBus.ObjectManager"
  @bluez "org.bluez"

  # bluetoothd may not have claimed org.bluez/hci0 the instant we start.
  @setup_retries 20
  @setup_retry_ms 500

  # Forward an advert immediately when its advertising payload changes (sensor
  # data), but coalesce RSSI-only churn to at most one forward per device per
  # this interval. BlueZ emits a PropertiesChanged for every received advert
  # (RSSI always differs), so without this the espex→HA forward path runs on
  # every PDU; this restores a blue_heron-like "once per window" cadence while
  # keeping data-change latency at zero.
  @rssi_heartbeat_ms 10_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    case Rebus.connect(:system) do
      {:ok, conn} ->
        ref = Rebus.add_signal_handler(conn)
        # rebus registers a *local* handler but does not install bus-side match
        # rules, so org.bluez's signals would never be routed to us. Tell the
        # daemon which signals to deliver.
        add_signal_matches(conn)
        # devices: %{object_path => merged props map (unwrapped)}
        {:ok, %{conn: conn, sig_ref: ref, devices: %{}}, {:continue, {:setup, @setup_retries}}}

      {:error, reason} ->
        # Let the supervisor retry; the bus may not be up yet.
        {:stop, {:dbus_connect_failed, reason}}
    end
  end

  @impl GenServer
  def handle_continue({:setup, retries}, state) do
    case adapter_present?(state.conn) do
      true ->
        power_on(state.conn)
        set_le_filter(state.conn)
        start_discovery(state.conn)
        seed_existing(state)
        Logger.info("Bluez.Client: discovery started on #{@adapter_path}")
        {:noreply, state}

      false when retries > 0 ->
        Process.sleep(@setup_retry_ms)
        {:noreply, state, {:continue, {:setup, retries - 1}}}

      false ->
        Logger.error("Bluez.Client: #{@adapter_path} never appeared on org.bluez")
        {:stop, :no_adapter, state}
    end
  end

  @impl GenServer
  # Signals arrive as {handler_ref, %Rebus.Message{type: :signal, ...}}.
  def handle_info({ref, %Rebus.Message{type: :signal} = msg}, %{sig_ref: ref} = state) do
    {:noreply, handle_signal(msg, state)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ── signal dispatch ────────────────────────────────────────────────────

  defp handle_signal(
         %Rebus.Message{header_fields: %{member: "InterfacesAdded"}, body: body},
         state
       ) do
    try do
      [path, interfaces] = body

      case List.keyfind(interfaces, @device_iface, 0) do
        {_iface, props_list} -> upsert_device(state, path, unwrap_props(props_list))
        nil -> state
      end
    rescue
      e ->
        Logger.warning("Bluez.Client: bad InterfacesAdded shape: #{inspect(e)}")
        state
    end
  end

  defp handle_signal(
         %Rebus.Message{header_fields: %{member: "PropertiesChanged", path: path}, body: body},
         state
       ) do
    try do
      [iface, changed, _invalidated] = body

      if iface == @device_iface and String.starts_with?(path, @adapter_path <> "/dev_") do
        upsert_device(state, path, unwrap_props(changed))
      else
        state
      end
    rescue
      e ->
        Logger.warning("Bluez.Client: bad PropertiesChanged shape: #{inspect(e)}")
        state
    end
  end

  defp handle_signal(
         %Rebus.Message{header_fields: %{member: "InterfacesRemoved"}, body: body},
         state
       ) do
    case body do
      [path | _] -> %{state | devices: Map.delete(state.devices, path)}
      _ -> state
    end
  end

  defp handle_signal(_msg, state), do: state

  # Merge new/changed props into the device cache, reconstruct, then emit only
  # on a payload change or once per heartbeat interval (see @rssi_heartbeat_ms).
  # Cache value: %{props: merged props, last_raw: last-emitted AD bytes,
  # last_emit: monotonic ms of last emit}.
  defp upsert_device(state, path, new_props) do
    entry = Map.get(state.devices, path, %{props: %{}, last_raw: nil, last_emit: nil})
    merged = Map.merge(entry.props, new_props)

    {last_raw, last_emit} =
      case Advert.reconstruct(merged) do
        {:ok, advert} ->
          if emit?(advert.raw_data, entry.last_raw, entry.last_emit) do
            emit(advert)
            {advert.raw_data, System.monotonic_time(:millisecond)}
          else
            {entry.last_raw, entry.last_emit}
          end

        :skip ->
          {entry.last_raw, entry.last_emit}
      end

    new_entry = %{props: merged, last_raw: last_raw, last_emit: last_emit}
    %{state | devices: Map.put(state.devices, path, new_entry)}
  end

  # Emit on first sight, whenever the advertising payload changes, or when the
  # heartbeat interval has elapsed (keeps RSSI/last-seen fresh for HA without
  # forwarding every PDU).
  defp emit?(_raw, nil, _last_emit), do: true
  defp emit?(raw, last_raw, _last_emit) when raw != last_raw, do: true

  defp emit?(_raw, _last_raw, last_emit) do
    System.monotonic_time(:millisecond) - last_emit >= @rssi_heartbeat_ms
  end

  defp emit(%{address: address, rss: rss, address_type: address_type, raw_data: raw_data}) do
    BluetoothScanner.on_advertisement(%{
      address: address,
      rss: rss,
      address_type: address_type,
      raw_data: raw_data
    })
  end

  # ── org.bluez method calls ─────────────────────────────────────────────

  # Install bus-side match rules so the daemon routes org.bluez's signals to
  # this connection. ObjectManager covers InterfacesAdded/Removed (device
  # appear/disappear); PropertiesChanged (scoped to Device1 via arg0) carries
  # RSSI/data updates.
  defp add_signal_matches(conn) do
    rules = [
      "type='signal',interface='org.freedesktop.DBus.ObjectManager'",
      "type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',arg0='#{@device_iface}'"
    ]

    Enum.each(rules, fn rule ->
      Rebus.Connection.send(
        conn,
        Rebus.Message.new!(:method_call,
          destination: "org.freedesktop.DBus",
          path: "/org/freedesktop/DBus",
          interface: "org.freedesktop.DBus",
          member: "AddMatch",
          signature: "s",
          body: [rule]
        )
      )
    end)
  end

  defp adapter_present?(conn) do
    case get_managed_objects(conn) do
      {:ok, objects} -> List.keymember?(objects, @adapter_path, 0)
      _ -> false
    end
  end

  defp power_on(conn) do
    # Properties.Set(ssv): interface, name, value-variant.
    call(conn, @adapter_path, @props_iface, "Set", "ssv", [
      @adapter_iface,
      "Powered",
      {"b", true}
    ])
  end

  defp set_le_filter(conn) do
    # SetDiscoveryFilter(a{sv}). DuplicateData=false lets BlueZ coalesce
    # identical re-broadcasts and only emit PropertiesChanged when a device's
    # advertising data actually changes (plus periodic RSSI) — the same intent
    # as blue_heron's controller-side filter_duplicates. true (report every
    # PDU) is a firehose that drove the BEAM hot decoding/forwarding every
    # repeat; sensor freshness is preserved because a data change still emits.
    filter = [{"Transport", {"s", "le"}}, {"DuplicateData", {"b", false}}]
    call(conn, @adapter_path, @adapter_iface, "SetDiscoveryFilter", "a{sv}", [filter])
  end

  defp start_discovery(conn) do
    call(conn, @adapter_path, @adapter_iface, "StartDiscovery", "", [])
  end

  # Pull devices that org.bluez already knows about (from before we started)
  # so cached sensors don't wait for their next advert.
  defp seed_existing(state) do
    case get_managed_objects(state.conn) do
      {:ok, objects} ->
        Enum.reduce(objects, state, fn
          {path, ifaces}, acc ->
            case List.keyfind(ifaces, @device_iface, 0) do
              {_i, props} -> upsert_device(acc, path, unwrap_props(props))
              nil -> acc
            end

          _, acc ->
            acc
        end)

      _ ->
        state
    end
  end

  defp get_managed_objects(conn) do
    case call(conn, "/", @om_iface, "GetManagedObjects", "", []) do
      {:ok, [objects]} -> {:ok, objects}
      other -> other
    end
  end

  # Issue a method call and return {:ok, body} | {:error, reason}.
  defp call(conn, path, interface, member, signature, body) do
    opts = [
      destination: @bluez,
      path: path,
      interface: interface,
      member: member,
      body: body
    ]

    opts = if signature == "", do: opts, else: Keyword.put(opts, :signature, signature)

    case Rebus.Connection.send(conn, Rebus.Message.new!(:method_call, opts)) do
      %Rebus.Message{type: :method_return, body: reply_body} ->
        {:ok, reply_body}

      %Rebus.Message{type: :error, header_fields: hf, body: eb} ->
        Logger.warning("Bluez.Client: #{member} error #{inspect(hf[:error_name])} #{inspect(eb)}")
        {:error, hf[:error_name]}
    end
  rescue
    e ->
      Logger.warning("Bluez.Client: #{member} raised #{inspect(e)}")
      {:error, e}
  end

  # ── variant unwrapping ─────────────────────────────────────────────────

  # a{sv} props_list = [{key, {sig, value}}] -> %{key => unwrapped value}.
  defp unwrap_props(props_list) when is_list(props_list) do
    Map.new(props_list, fn {key, variant} -> {key, unwrap(key, variant)} end)
  end

  # ManufacturerData (a{qv}): [{company_id, {"ay", bytes}}] -> %{id => binary}.
  defp unwrap("ManufacturerData", {_sig, entries}) when is_list(entries) do
    Map.new(entries, fn {id, {_s, bytes}} -> {id, to_binary(bytes)} end)
  end

  # ServiceData (a{sv}): [{uuid, {"ay", bytes}}] -> %{uuid => binary}.
  defp unwrap("ServiceData", {_sig, entries}) when is_list(entries) do
    Map.new(entries, fn {uuid, {_s, bytes}} -> {uuid, to_binary(bytes)} end)
  end

  # Everything else: a plain variant {sig, value}; an "ay" value is a byte
  # list we leave as-is unless a consumer wants a binary (Advert handles the
  # data fields above; Name/UUIDs/RSSI/TxPower are plain).
  defp unwrap(_key, {_sig, value}), do: value
  defp unwrap(_key, value), do: value

  defp to_binary(bytes) when is_list(bytes), do: :erlang.list_to_binary(bytes)
  defp to_binary(bytes) when is_binary(bytes), do: bytes
end
