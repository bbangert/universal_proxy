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

    1. `Rebus.connect(:system)`, `set_method_handler(self())`, monitor the
       connection, and install bus match rules for org.bluez device signals.
    2. Power the adapter on, then `AdvertisementMonitorManager1.RegisterMonitor`
       our root object. BlueZ enumerates our monitor via
       `ObjectManager.GetManagedObjects` and calls `Activate`/`DeviceFound` on
       it; the monitor's `or_patterns` (FLAGS \\x02/\\x06/\\x1a) match
       effectively all advertisers (the habluetooth "match all" recipe).
    3. Matched devices surface as `InterfacesAdded`/`PropertiesChanged` signals;
       props are unwrapped (`UniversalProxy.Bluez.Variant`) and fed to
       `UniversalProxy.Bluez.DeviceCache`, which reconstructs + emit-gates and
       returns the adverts to fan out via `BluetoothScanner.on_advertisement/1`.

  Resilience:

    * RegisterMonitor runs in a Task (BlueZ calls `GetManagedObjects` back
      before RegisterMonitor returns — the GenServer must stay free to answer),
      and the Task catches `:exit` (a `GenServer.call` timeout) so a wedged
      BlueZ surfaces as a logged error, not a silent dropped Task.
    * The rebus connection is monitored; if it dies (e.g. a malformed bus
      frame `:stop`s it) the Client stops and the supervisor restarts it,
      re-establishing the connection.
    * Setup retries via `send_after` (not `Process.sleep`) so the GenServer
      stays responsive while waiting for `bluetoothd` to claim org.bluez.
  """

  use GenServer
  require Logger

  alias UniversalProxy.Bluez.{DBus, DeviceCache, Variant}
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

  # Timeout for the (Task-issued) RegisterMonitor call to BlueZ.
  @register_timeout_ms 10_000

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
        # Restart (and reconnect) if the connection dies.
        conn_ref = Process.monitor(conn)
        # rebus installs no bus-side match rules, so org.bluez's device signals
        # wouldn't reach us; ask the daemon to route them.
        add_signal_matches(conn)

        state = %{conn: conn, conn_ref: conn_ref, sig_ref: ref, cache: DeviceCache.new()}
        {:ok, state, {:continue, {:setup, @setup_retries}}}

      {:error, reason} ->
        {:stop, {:dbus_connect_failed, reason}}
    end
  end

  @impl GenServer
  def handle_continue({:setup, retries}, state), do: attempt_setup(state, retries)

  @impl GenServer
  # Connection died (e.g. malformed frame stopped it). Stop so the supervisor
  # restarts us and we reconnect; rebus connections are :temporary and don't
  # restart themselves.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{conn_ref: ref} = state) do
    {:stop, {:dbus_connection_down, reason}, state}
  end

  # Non-blocking setup retry (adapter not yet present).
  def handle_info({:setup_retry, retries}, state), do: attempt_setup(state, retries)

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

  # ── setup ────────────────────────────────────────────────────────────────

  defp attempt_setup(state, retries) do
    cond do
      adapter_present?(state.conn) ->
        power_on(state.conn)
        state = seed_existing(state)
        register_monitor_async(state.conn)
        {:noreply, state}

      retries > 0 ->
        Process.send_after(self(), {:setup_retry, retries - 1}, @setup_retry_ms)
        {:noreply, state}

      true ->
        Logger.error("Bluez.Client: #{@adapter_path} never appeared on org.bluez")
        {:stop, :no_adapter, state}
    end
  end

  # Register from a Task: BlueZ calls GetManagedObjects back on us before
  # RegisterMonitor returns, so this process must stay free to answer it.
  defp register_monitor_async(conn) do
    me = self()
    Task.start(fn -> Kernel.send(me, {:monitor_registered, register_monitor(conn)}) end)
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

    case GenServer.call(conn, {:send, msg}, @register_timeout_ms) do
      %Rebus.Message{type: :method_return} -> :ok
      %Rebus.Message{type: :error, header_fields: hf} -> {:error, hf[:error_name]}
    end
  rescue
    e -> {:error, e}
  catch
    # GenServer.call timeout / dead connection raise an exit, not an exception.
    :exit, reason -> {:error, {:exit, reason}}
  end

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
    e ->
      Logger.warning("Bluez.Client: inbound call handling raised #{inspect(e)}")
      # Always answer a reply-expecting call so BlueZ doesn't block until its
      # timeout; reply_error/4 no-ops for NO_REPLY_EXPECTED notifications.
      Rebus.reply_error(
        state.conn,
        msg,
        "org.freedesktop.DBus.Error.Failed",
        Exception.message(e)
      )
  end

  # The single advertisement monitor we expose. `or_patterns` matching the
  # common Flags values is BlueZ's documented "match all devices" workaround
  # (passive scanning requires ≥1 pattern); RSSISamplingPeriod=0 reports every
  # received advert (forwarding is throttled downstream by DeviceCache).
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

  # ── org.bluez device signal handling (advert source) ────────────────────

  defp handle_signal(
         %Rebus.Message{header_fields: %{member: "InterfacesAdded"}, body: body},
         state
       ) do
    [path, interfaces] = body

    with true <- String.starts_with?(path, @adapter_path <> "/dev_"),
         {_iface, props_list} <- List.keyfind(interfaces, @device_iface, 0) do
      ingest(state, path, Variant.unwrap_props(props_list))
    else
      # Not a Device1 under our adapter — ignore (matches PropertiesChanged).
      _ -> state
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
      ingest(state, path, Variant.unwrap_props(changed))
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
      [path | _] ->
        if String.starts_with?(path, @adapter_path <> "/dev_"),
          do: %{state | cache: DeviceCache.remove(state.cache, path)},
          else: state

      _ ->
        state
    end
  end

  defp handle_signal(_msg, state), do: state

  # Merge props into the cache and emit whatever adverts it returns.
  defp ingest(state, path, props) do
    {cache, adverts} =
      DeviceCache.upsert(state.cache, path, props, System.monotonic_time(:millisecond))

    Enum.each(adverts, &emit/1)
    %{state | cache: cache}
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
    # Scope to org.bluez so we only receive the daemon's signals, not
    # ObjectManager/PropertiesChanged from unrelated bus peers.
    rules = [
      "type='signal',sender='#{@bluez}',interface='org.freedesktop.DBus.ObjectManager'",
      "type='signal',sender='#{@bluez}',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',arg0='#{@device_iface}'"
    ]

    Enum.each(rules, &DBus.add_match(conn, &1))
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
              {_i, props} -> ingest(acc, path, Variant.unwrap_props(props))
              nil -> acc
            end

          _, acc ->
            acc
        end)

      _ ->
        state
    end
  end

  defp get_managed_objects(conn), do: DBus.get_managed_objects(conn)

  # Outbound method call → {:ok, body} | {:error, reason}. Extracted to
  # UniversalProxy.Bluez.DBus so the GATT client shares it.
  defp call(conn, path, interface, member, signature, body) do
    DBus.call(conn, path, interface, member, signature, body)
  end
end
