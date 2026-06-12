defmodule UniversalProxy.Bluez.Client do
  @moduledoc """
  Persistent `rebus` D-Bus client + service to `org.bluez`, driving BLE
  scanning and turning device signals into advertisements for
  `UniversalProxy.ESPHome.BluetoothScanner`.

  Supports both scanner modes Home Assistant can request (`set_mode/1`,
  called via `BluetoothScanner.set_scanner_mode/1`):

    * `:passive` (default) — a BlueZ `AdvertisementMonitor`. We never send
      scan requests, so scannable peripherals don't burn battery answering
      us. Requires *exporting* a D-Bus object BlueZ calls back into, so this
      process is both a client and a service (via the forked rebus's
      `set_method_handler/2`).
    * `:active` — `Adapter1.StartDiscovery` with an LE filter. BlueZ sends
      scan requests, so SCAN_RSP data (e.g. device names) is collected —
      parity with ESP32 proxies' active mode.

  Device data arrives the same way in both modes
  (`InterfacesAdded`/`PropertiesChanged` on `Device1` objects), so the
  advert pipeline downstream is mode-agnostic.

  Flow:

    1. `Rebus.connect(:system)`, `set_method_handler(self())`, monitor the
       connection, and install bus match rules for org.bluez device signals.
    2. Power the adapter on, then engage `configured_mode/0`: either
       `AdvertisementMonitorManager1.RegisterMonitor` our root object (BlueZ
       enumerates the monitor via `ObjectManager.GetManagedObjects` and calls
       `Activate`/`DeviceFound` on it; the monitor's `or_patterns` (FLAGS
       \\x02/\\x06/\\x1a) match effectively all advertisers — the habluetooth
       "match all" recipe), or `SetDiscoveryFilter` + `StartDiscovery`.
    3. Matched devices surface as `InterfacesAdded`/`PropertiesChanged` signals;
       props are unwrapped (`UniversalProxy.Bluez.Variant`) and fed to
       `UniversalProxy.Bluez.DeviceCache`, which reconstructs + emit-gates and
       returns the adverts to fan out via `BluetoothScanner.on_advertisement/1`.

  Mode transitions:

    * Run in a Task — BlueZ calls `GetManagedObjects` back on us before
      `RegisterMonitor` returns, so the GenServer must stay free to answer —
      and are serialized: at most one in flight, identified by a generation
      ref so a stale Task result can't corrupt state. A `set_mode/1` arriving
      mid-transition parks in a one-slot pending queue keyed by target mode:
      callers asking for the same target coalesce (all get `:ok` when it
      lands); a different target displaces them with `{:error, :superseded}`
      (latest target wins).
    * Transitions engage the new mode BEFORE disengaging the old one
      (monitor and discovery can legally coexist in BlueZ): a failed engage
      leaves the previous mode still scanning rather than going dark.
      Disengage is best-effort, and self-healing lives in engage's
      idempotency: whatever drifted, re-engaging treats
      `AlreadyExists`/`InProgress` as success, so the next transition always
      converges on the target mode.
    * The configured mode persists in `:persistent_term` across Client
      restarts: a bluetoothd/connection crash re-engages what HA chose
      rather than silently reverting to passive.

  Resilience:

    * The rebus connection is monitored; if it dies (e.g. a malformed bus
      frame `:stop`s it) the Client stops and the supervisor restarts it,
      re-establishing the connection.
    * Setup retries via `send_after` (not `Process.sleep`) so the GenServer
      stays responsive while waiting for `bluetoothd` to claim org.bluez.
  """

  use GenServer
  require Logger

  alias UniversalProxy.Bluez.{DBus, DeviceCache, DevicePath, Variant}
  alias UniversalProxy.ESPHome.BluetoothScanner

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

  # set_mode/1 callers wait for the whole transition — and a caller parked
  # behind an in-flight transition waits for that one too. Budget two
  # back-to-back worst cases (each: engage RegisterMonitor 10 s + best-effort
  # disengage 5 s) plus margin; normal transitions complete in milliseconds.
  @set_mode_timeout_ms 32_000

  # :persistent_term key for the HA-configured scanner mode. Survives Client
  # restarts (within a boot) so re-init re-engages what HA chose.
  @mode_key {__MODULE__, :configured_mode}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Switch the scanner between `:passive` (AdvertisementMonitor) and `:active`
  (StartDiscovery) at runtime. Returns once the BlueZ transition completes.

  A caller whose transition is already in flight always gets that
  transition's own result. Only callers parked *behind* an in-flight
  transition can get `{:error, :superseded}` — when a newer `set_mode/1`
  asking for a different mode displaces them (same-mode callers coalesce
  and succeed together).

  Callers must `catch :exit` for the not-running/timeout cases (see
  `UniversalProxy.ESPHome.BluetoothScanner.set_scanner_mode/1`).
  """
  @spec set_mode(:passive | :active) :: :ok | {:error, term()}
  def set_mode(mode) when mode in [:passive, :active] do
    GenServer.call(__MODULE__, {:set_mode, mode}, @set_mode_timeout_ms)
  end

  @doc """
  The HA-configured scanner mode (`:passive` default). Pure
  `:persistent_term` read — safe on any target, with or without the Client
  running (host tests, early boot).
  """
  @spec configured_mode() :: :passive | :active
  def configured_mode, do: :persistent_term.get(@mode_key, :passive)

  @doc """
  `org.bluez.Adapter1` properties for every adapter object the daemon
  exposes: `[%{path:, address:, name:, powered:}]`. Used by
  `UniversalProxy.Bluetooth.RadioMonitor` to overlay live daemon state on
  the sysfs radio list. Returns `[]` when this Client isn't running (BT
  subtree down, host) or the daemon can't answer.
  """
  @spec adapters_info() :: [
          %{
            path: String.t(),
            address: String.t() | nil,
            name: String.t() | nil,
            powered: boolean()
          }
        ]
  def adapters_info do
    GenServer.call(__MODULE__, :adapters_info)
  catch
    :exit, _ -> []
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

        state = %{
          conn: conn,
          conn_ref: conn_ref,
          sig_ref: ref,
          cache: DeviceCache.new(),
          # mode = last successfully applied mode; engaged = what BlueZ is
          # actually doing for us right now (:none until setup engages).
          mode: nil,
          engaged: :none,
          # transition = generation ref of the in-flight Task (nil = idle);
          # pending = one-slot queue parked behind it: {target, [from]} —
          # same-target callers coalesce, a new target displaces them.
          transition: nil,
          pending: nil
        }

        {:ok, state, {:continue, {:setup, @setup_retries}}}

      {:error, reason} ->
        {:stop, {:dbus_connect_failed, reason}}
    end
  end

  @impl GenServer
  def handle_continue({:setup, retries}, state), do: attempt_setup(state, retries)

  @impl GenServer
  def handle_call(:adapters_info, _from, state) do
    reply =
      case get_managed_objects(state.conn) do
        {:ok, objects} ->
          for {path, ifaces} <- objects,
              {_iface, props} <- [List.keyfind(ifaces, @adapter_iface, 0)] do
            unwrapped = Variant.unwrap_props(props)

            %{
              path: path,
              address: unwrapped["Address"],
              name: unwrapped["Name"],
              powered: unwrapped["Powered"] == true
            }
          end

        {:error, _} ->
          []
      end

    {:reply, reply, state}
  end

  def handle_call({:set_mode, target}, from, state) do
    cond do
      # A transition is running: park behind it. Same-target callers pile
      # into one pending slot and all succeed together; a different target
      # displaces them (latest target wins).
      state.transition != nil ->
        pending =
          case state.pending do
            {^target, froms} ->
              {target, [from | froms]}

            {_other_target, froms} ->
              Enum.each(froms, &GenServer.reply(&1, {:error, :superseded}))
              {target, [from]}

            nil ->
              {target, [from]}
          end

        {:noreply, %{state | pending: pending}}

      # Already there (and actually engaged — a failed initial setup leaves
      # engaged: :none, which falls through and retries).
      state.mode == target and state.engaged != :none ->
        {:reply, :ok, state}

      true ->
        {:noreply, start_transition(state, target, [from])}
    end
  end

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

  # Current transition finished — commit the outcome, answer the callers,
  # then run whatever parked behind it.
  def handle_info({:mode_transition, ref, target, froms, result}, %{transition: ref} = state) do
    state = %{state | transition: nil}

    state =
      case result do
        {:ok, engaged} ->
          :persistent_term.put(@mode_key, target)
          Enum.each(froms, &GenServer.reply(&1, :ok))
          Logger.info("Bluez.Client: scanner mode #{target} engaged (#{engaged})")
          %{state | mode: target, engaged: engaged}

        {:error, reason, engaged} ->
          Enum.each(froms, &GenServer.reply(&1, {:error, reason}))
          Logger.error("Bluez.Client: scanner mode #{target} failed: #{inspect(reason)}")
          %{state | engaged: engaged}
      end

    {:noreply, run_pending(state)}
  end

  # Stale transition result (generation ref mismatch — superseded while its
  # Task ran). Never commit it; just make sure its callers aren't left hanging.
  def handle_info({:mode_transition, _ref, _target, froms, _result}, state) do
    Enum.each(froms, &GenServer.reply(&1, {:error, :superseded}))
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ── setup ────────────────────────────────────────────────────────────────

  defp attempt_setup(state, retries) do
    cond do
      adapter_present?(state.conn) ->
        power_on(state.conn)
        power_off_others(state.conn)
        state = seed_existing(state)
        # An early set_mode/1 may already have a transition in flight (its
        # D-Bus calls work as soon as the adapter answers) — don't race it;
        # it engages the caller's mode and run_pending takes over from there.
        state =
          if state.transition == nil,
            do: start_transition(state, configured_mode(), []),
            else: state

        {:noreply, state}

      retries > 0 ->
        Process.send_after(self(), {:setup_retry, retries - 1}, @setup_retry_ms)
        {:noreply, state}

      true ->
        Logger.error("Bluez.Client: #{adapter_path()} never appeared on org.bluez")
        {:stop, :no_adapter, state}
    end
  end

  # ── scanner mode transitions ─────────────────────────────────────────────

  # Kick a Task that moves BlueZ from `state.engaged` to `target`, replying
  # to every caller in `froms` ([] for setup-initiated engages). Runs off
  # the GenServer loop because RegisterMonitor re-enters us (BlueZ calls
  # GetManagedObjects back before it returns). The generation ref ties the
  # Task's result to this transition; handle_info ignores stale ones.
  defp start_transition(state, target, froms) do
    me = self()
    conn = state.conn
    engaged = state.engaged
    ref = make_ref()

    Task.start(fn ->
      # The completion message must ALWAYS arrive — a Task that dies without
      # sending it leaves `transition` stuck non-nil and every future
      # set_mode/1 parking until timeout. apply_mode/3 shouldn't raise
      # (DBus.call normalizes errors), but don't bet the state machine on it.
      result =
        try do
          apply_mode(conn, engaged, target)
        rescue
          e -> {:error, e, engaged}
        catch
          kind, reason -> {:error, {kind, reason}, engaged}
        end

      send(me, {:mode_transition, ref, target, froms, result})
    end)

    %{state | transition: ref}
  end

  # After a transition: serve the parked set_mode callers, if any.
  defp run_pending(%{pending: nil} = state), do: state

  defp run_pending(%{pending: {target, froms}} = state) do
    state = %{state | pending: nil}

    if state.mode == target and state.engaged != :none do
      Enum.each(froms, &GenServer.reply(&1, :ok))
      state
    else
      start_transition(state, target, froms)
    end
  end

  # Runs in the Task. Engage-first: monitor + discovery can legally coexist
  # in BlueZ, so bring the new mode up before tearing the old one down. A
  # failed engage then leaves the previous mode still scanning — engaged
  # unchanged, so the eventual teardown still targets the right strategy —
  # instead of going dark. Disengage stays best-effort (engage idempotency
  # below self-heals any drift on the next transition).
  # Returns {:ok, engaged} | {:error, reason, engaged}.
  defp apply_mode(conn, engaged, target) do
    case engage(conn, target) do
      :ok ->
        new_engaged = engaged_for(target)
        if engaged != new_engaged, do: disengage(conn, engaged)
        {:ok, new_engaged}

      {:error, reason} ->
        {:error, reason, engaged}
    end
  end

  defp engaged_for(:passive), do: :monitor
  defp engaged_for(:active), do: :discovery

  defp disengage(_conn, :none), do: :ok

  defp disengage(conn, :monitor) do
    case call(conn, adapter_path(), @advmon_mgr_iface, "UnregisterMonitor", "o", [@root_path]) do
      {:ok, _} -> :ok
      # Wasn't registered (engage failed earlier) — already disengaged.
      {:error, "org.bluez.Error.DoesNotExist"} -> :ok
      {:error, reason} -> Logger.warning("Bluez.Client: UnregisterMonitor: #{inspect(reason)}")
    end
  end

  defp disengage(conn, :discovery) do
    case call(conn, adapter_path(), @adapter_iface, "StopDiscovery", "", []) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("Bluez.Client: StopDiscovery: #{inspect(reason)}")
    end
  end

  defp engage(conn, :passive) do
    case register_monitor(conn) do
      :ok -> :ok
      # Already registered (a drifted earlier state) — goal reached.
      {:error, "org.bluez.Error.AlreadyExists"} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp engage(conn, :active) do
    # DuplicateData=false lets BlueZ coalesce identical re-broadcasts and only
    # signal when a device's advertising data actually changes (plus periodic
    # RSSI) — DeviceCache still emit-gates downstream.
    filter = [{"Transport", {"s", "le"}}, {"DuplicateData", {"b", false}}]

    with {:ok, _} <-
           call(conn, adapter_path(), @adapter_iface, "SetDiscoveryFilter", "a{sv}", [filter]),
         {:ok, _} <- start_discovery(conn) do
      :ok
    end
  end

  defp start_discovery(conn) do
    case call(conn, adapter_path(), @adapter_iface, "StartDiscovery", "", []) do
      # Already discovering (a drifted earlier state) — goal reached.
      {:error, "org.bluez.Error.InProgress"} -> {:ok, []}
      other -> other
    end
  end

  defp register_monitor(conn) do
    msg =
      Rebus.Message.new!(:method_call,
        destination: @bluez,
        path: adapter_path(),
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

    with true <- String.starts_with?(path, adapter_path() <> "/dev_"),
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

    if iface == @device_iface and String.starts_with?(path, adapter_path() <> "/dev_") do
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
        if String.starts_with?(path, adapter_path() <> "/dev_"),
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
      {:ok, objects} -> List.keymember?(objects, adapter_path(), 0)
      _ -> false
    end
  end

  defp power_on(conn) do
    call(conn, adapter_path(), @props_iface, "Set", "ssv", [
      @adapter_iface,
      "Powered",
      {"b", true}
    ])
  end

  # Best-effort: power every adapter we are NOT driving down so a
  # deselected radio stops radiating after a radio switch (bluetoothd's
  # AutoEnable may have powered it). Failures are ignored — a radio left
  # powered is cosmetic, and the next subtree start retries anyway.
  defp power_off_others(conn) do
    with {:ok, objects} <- get_managed_objects(conn) do
      for {path, ifaces} <- objects,
          path != adapter_path(),
          List.keymember?(ifaces, @adapter_iface, 0) do
        call(conn, path, @props_iface, "Set", "ssv", [@adapter_iface, "Powered", {"b", false}])
      end
    end

    :ok
  end

  # The adapter object path the whole subtree drives — resolved by
  # UniversalProxy.Bluetooth.Manager before this subtree (re)starts and
  # published via :persistent_term, so it's stable for this process's
  # lifetime. Read per use (a persistent_term read is ~free) rather than
  # cached in state.
  defp adapter_path, do: DevicePath.adapter_path()

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
