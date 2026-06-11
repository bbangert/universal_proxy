defmodule UniversalProxy.Bluez.Client do
  @moduledoc """
  Persistent `rebus` D-Bus client + service to `org.bluez`, driving **passive**
  BLE scanning via the BlueZ `AdvertisementMonitor` API and turning device
  signals into advertisements for `UniversalProxy.ESPHome.BluetoothScanner`.

  Passive (vs `StartDiscovery`, which is active and makes scannable peripherals
  burn battery answering our scan requests) requires us to *export* a D-Bus
  object that BlueZ calls back into — so this process is both a client and a
  service (via the forked rebus's `set_method_handler/2`).

  Flow:

    1. `Rebus.connect(:system)` and `set_method_handler(self())`; install bus
       match rules for org.bluez device signals.
    2. Power the adapter on, then `AdvertisementMonitorManager1.RegisterMonitor`
       our root object. BlueZ enumerates our monitor via
       `ObjectManager.GetManagedObjects` and calls `Activate`/`DeviceFound` on
       it; the monitor's `or_patterns` (FLAGS \\x02/\\x06/\\x1a) match
       effectively all advertisers (the habluetooth "match all" recipe — BlueZ
       requires ≥1 pattern).
    3. Matched devices surface as `InterfacesAdded`/`PropertiesChanged` signals
       (same as before); each is merged into a per-device prop cache, handed to
       `UniversalProxy.Bluez.Advert`, and — gated to payload-changes + a
       heartbeat — fanned out via `BluetoothScanner.on_advertisement/1`.

  RegisterMonitor is issued from a Task: BlueZ calls `GetManagedObjects` back on
  us *before* RegisterMonitor returns, so the GenServer must stay free to
  service that inbound call (otherwise deadlock).

  Defensive: inbound bodies are parsed under `try`/`rescue` so a surprising
  shape logs and is skipped rather than crashing the BlueZ subtree.
  """

  use GenServer
  require Logger

  alias UniversalProxy.Bluez.Advert
  alias UniversalProxy.ESPHome.BluetoothScanner

  @adapter_path "/org/bluez/hci0"
  @adapter_iface "org.bluez.Adapter1"
  @device_iface "org.bluez.Device1"
  @advmon_mgr_iface "org.bluez.AdvertisementMonitorManager1"
  @advmon_iface "org.bluez.AdvertisementMonitor1"
  @props_iface "org.freedesktop.DBus.Properties"
  @om_iface "org.freedesktop.DBus.ObjectManager"
  @introspect_iface "org.freedesktop.DBus.Introspectable"
  @bluez "org.bluez"

  # Our exported ObjectManager root + the single monitor object beneath it.
  @root_path "/org/universalproxy/advmon"
  @monitor_path "/org/universalproxy/advmon/monitor0"

  # bluetoothd may not have claimed org.bluez/hci0 the instant we start.
  @setup_retries 20
  @setup_retry_ms 500

  # Forward an advert immediately when its advertising payload changes (sensor
  # data), but coalesce RSSI-only churn to at most one forward per device per
  # this interval — restores a blue_heron-like "once per window" cadence while
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
        # Receive inbound method calls (BlueZ → our monitor object) too.
        Rebus.set_method_handler(conn, self())
        # rebus installs no bus-side match rules, so org.bluez's device signals
        # wouldn't reach us; ask the daemon to route them.
        add_signal_matches(conn)
        {:ok, %{conn: conn, sig_ref: ref, devices: %{}}, {:continue, {:setup, @setup_retries}}}

      {:error, reason} ->
        {:stop, {:dbus_connect_failed, reason}}
    end
  end

  @impl GenServer
  def handle_continue({:setup, retries}, state) do
    case adapter_present?(state.conn) do
      true ->
        power_on(state.conn)
        state = seed_existing(state)
        # Register from a Task: BlueZ calls GetManagedObjects back on us before
        # RegisterMonitor returns, so this process must stay free to answer it.
        conn = state.conn
        me = self()
        Task.start(fn -> Kernel.send(me, {:monitor_registered, register_monitor(conn)}) end)
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
  # org.bluez device signals arrive as {handler_ref, %Message{type: :signal}}.
  def handle_info({ref, %Rebus.Message{type: :signal} = msg}, %{sig_ref: ref} = state) do
    {:noreply, handle_signal(msg, state)}
  end

  # Inbound method calls from BlueZ into our exported monitor/ObjectManager.
  def handle_info({:dbus_call, %Rebus.Message{} = msg}, state) do
    dispatch_method_call(msg, state)
    {:noreply, state}
  end

  def handle_info({:monitor_registered, :ok}, state) do
    Logger.info("Bluez.Client: passive AdvertisementMonitor registered on #{@adapter_path}")
    {:noreply, state}
  end

  def handle_info({:monitor_registered, {:error, reason}}, state) do
    Logger.error("Bluez.Client: RegisterMonitor failed: #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ── inbound method-call dispatch (we are the service BlueZ calls) ────────

  defp dispatch_method_call(%Rebus.Message{header_fields: hf} = msg, state) do
    conn = state.conn

    case {hf[:interface], hf[:member]} do
      {@om_iface, "GetManagedObjects"} ->
        Rebus.reply(conn, msg, [managed_objects()], "a{oa{sa{sv}}}")

      {@props_iface, "GetAll"} ->
        Rebus.reply(conn, msg, [monitor_props()], "a{sv}")

      {@props_iface, "Get"} ->
        prop = msg.body |> Enum.at(1)

        case List.keyfind(monitor_props(), prop, 0) do
          {_p, variant} -> Rebus.reply(conn, msg, [variant], "v")
          nil -> Rebus.reply_error(conn, msg, "org.freedesktop.DBus.Error.UnknownProperty", prop)
        end

      {@advmon_iface, "Activate"} ->
        Logger.info("Bluez.Client: AdvertisementMonitor activated (passive scanning)")
        Rebus.reply(conn, msg)

      {@advmon_iface, member} when member in ["Release", "DeviceFound", "DeviceLost"] ->
        # We learn device data from InterfacesAdded/PropertiesChanged, so these
        # are just acknowledged.
        Rebus.reply(conn, msg)

      {@introspect_iface, "Introspect"} ->
        Rebus.reply(conn, msg, [introspect_xml(hf[:path])], "s")

      {iface, member} ->
        Rebus.reply_error(
          conn,
          msg,
          "org.freedesktop.DBus.Error.UnknownMethod",
          "#{iface}.#{member}"
        )
    end
  rescue
    e -> Logger.warning("Bluez.Client: inbound call handling raised #{inspect(e)}")
  end

  # The single advertisement monitor we expose. `or_patterns` matching the
  # common Flags values is BlueZ's documented "match all devices" workaround
  # (passive scanning requires ≥1 pattern); RSSISamplingPeriod=0 reports every
  # received advert (forwarding is throttled downstream by emit?/3).
  defp monitor_props do
    [
      {"Type", {"s", "or_patterns"}},
      {"RSSISamplingPeriod", {"q", 0}},
      {"Patterns", {"a(yyay)", [[0, 0x01, [0x02]], [0, 0x01, [0x06]], [0, 0x01, [0x1A]]]}}
    ]
  end

  defp managed_objects do
    [{@monitor_path, [{@advmon_iface, monitor_props()}]}]
  end

  defp introspect_xml(path) do
    interfaces =
      cond do
        path == @root_path -> ~s(<interface name="#{@om_iface}"/>)
        path == @monitor_path -> ~s(<interface name="#{@advmon_iface}"/>)
        true -> ""
      end

    ~s(<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">\n<node>#{interfaces}</node>)
  end

  defp register_monitor(conn) do
    msg =
      Rebus.Message.new!(:method_call,
        destination: @bluez,
        path: @adapter_path,
        interface: @advmon_mgr_iface,
        member: "RegisterMonitor",
        signature: "o",
        body: [@root_path]
      )

    case Rebus.Connection.send(conn, msg) do
      %Rebus.Message{type: :method_return} -> :ok
      %Rebus.Message{type: :error, header_fields: hf} -> {:error, hf[:error_name]}
    end
  rescue
    e -> {:error, e}
  end

  # ── org.bluez device signal handling (advert source) ────────────────────

  defp handle_signal(
         %Rebus.Message{header_fields: %{member: "InterfacesAdded"}, body: body},
         state
       ) do
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

  defp handle_signal(
         %Rebus.Message{header_fields: %{member: "PropertiesChanged", path: path}, body: body},
         state
       ) do
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
  # on a payload change or once per heartbeat. Cache value: %{props:, last_raw:,
  # last_emit:}.
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

    %{
      state
      | devices:
          Map.put(state.devices, path, %{props: merged, last_raw: last_raw, last_emit: last_emit})
    }
  end

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

  # ── outbound org.bluez calls + helpers ──────────────────────────────────

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
    call(conn, @adapter_path, @props_iface, "Set", "ssv", [@adapter_iface, "Powered", {"b", true}])
  end

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

  # Outbound method call → {:ok, body} | {:error, reason}.
  defp call(conn, path, interface, member, signature, body) do
    opts = [destination: @bluez, path: path, interface: interface, member: member, body: body]
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

  # ── variant unwrapping ──────────────────────────────────────────────────

  defp unwrap_props(props_list) when is_list(props_list) do
    Map.new(props_list, fn {key, variant} -> {key, unwrap(key, variant)} end)
  end

  defp unwrap("ManufacturerData", {_sig, entries}) when is_list(entries) do
    Map.new(entries, fn {id, {_s, bytes}} -> {id, to_binary(bytes)} end)
  end

  defp unwrap("ServiceData", {_sig, entries}) when is_list(entries) do
    Map.new(entries, fn {uuid, {_s, bytes}} -> {uuid, to_binary(bytes)} end)
  end

  defp unwrap(_key, {_sig, value}), do: value
  defp unwrap(_key, value), do: value

  defp to_binary(bytes) when is_list(bytes), do: :erlang.list_to_binary(bytes)
  defp to_binary(bytes) when is_binary(bytes), do: bytes
end
