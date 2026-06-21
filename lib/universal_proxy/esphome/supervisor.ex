defmodule UniversalProxy.ESPHome.Supervisor do
  @moduledoc """
  Supervisor that wires our hardware adapters into the `Espex` ESPHome
  Native API server.

  Children, started in `:rest_for_one` order:

    1. `ZWaveProxy` — GenServer that owns the Z-Wave UART port and
       implements the `Espex.ZWaveProxy` behaviour
    2. `Infrared.Supervisor` — DynamicSupervisor + `Infrared.Server`
       (the `Espex.InfraredProxy` adapter)
    3. `Espex` — the library supervisor: registry, server, TCP acceptor,
       and (optionally) mDNS advertiser

  `ConfigStore` lives one level up in the application supervisor so a
  `restart/0` of this tree does not close and reopen the DETS file.
  """

  use Supervisor

  alias UniversalProxy.ESPHome.{
    BluetoothProxy,
    BluetoothScanner,
    Clients,
    ConfigStore,
    EntityProvider,
    Infrared,
    PskStore,
    SerialProxy,
    ZWaveProxy
  }

  alias UniversalProxy.Hardware
  alias UniversalProxy.UART.Store, as: UARTStore

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc """
  Restart the ESPHome supervisor tree.

  Closes all UART ports opened by serial-proxy connections, then terminates
  and restarts this supervisor under the application supervisor. Active
  client connections are dropped so they reconnect with the updated device
  info (refreshed `serial_proxies`, etc.).
  """
  @spec restart() :: {:ok, pid()} | {:error, term()}
  def restart do
    try do
      UniversalProxy.UART.Server.close_all_ports()
    catch
      :exit, _ -> :ok
    end

    Supervisor.terminate_child(UniversalProxy.Supervisor, __MODULE__)
    Supervisor.restart_child(UniversalProxy.Supervisor, __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    zwave_port_path = resolve_zwave_port()

    # Seed the persisted PSK into device_config so a previously
    # HA-provisioned key survives restart/reboot. accepts_key_provisioning
    # is opened only while keyless: once a key exists, no LAN client can
    # re-provision (espex's own documented idiom).
    psk = PskStore.load_psk()

    device_config =
      ConfigStore.device_config_opts()
      |> Keyword.merge(psk: psk, accepts_key_provisioning: psk == nil)

    espex_opts =
      [
        device_config: device_config,
        serial_proxy: SerialProxy,
        zwave_proxy: ZWaveProxy,
        infrared_proxy: Infrared.Server,
        mdns: Espex.Mdns.MdnsLite,
        psk_store: PskStore,
        connection_listener: Clients,
        entity_provider: EntityProvider
      ] ++ bluetooth_opts()

    children = [
      {ZWaveProxy, port_path: zwave_port_path},
      Infrared.Supervisor,
      # Must start BEFORE Espex (rest_for_one): Espex calls
      # EntityProvider.list_entities/0 at connection-accept time, and a
      # provider crash should restart Espex so clients re-read entities.
      # Pushes go to the default Espex.Server name (espex_opts sets no
      # :server_name).
      {EntityProvider, server: Espex.Server},
      {Espex, espex_opts}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  # Wire the BLE adapters (passive scanner + active GATT proxy) into espex
  # ONLY on BT-capable targets — and on those, only as far as the user's
  # Bluetooth settings allow. Off target (or BT disabled) both keys are
  # omitted entirely, so espex leaves the bluetooth feature flags at 0.
  #
  # Boot ordering: `UniversalProxy.Bluetooth` (the registry, settings
  # store, and Bluez lifecycle) starts BEFORE this supervisor (see
  # `application.ex`), so the settings read here sees the persisted state
  # on first boot. The adapters stay defensive regardless:
  # `BluetoothScanner.subscribe/1` rescues an un-started Registry's
  # `ArgumentError` and `BluetoothProxy` handles a not-running `Bluez.Gatt`.
  defp bluetooth_opts do
    bluetooth_opts(UniversalProxy.Bluetooth.supported?(), bluetooth_settings())
  end

  @doc """
  The espex adapter wiring for a given BT support level + settings — pure,
  so the enabled × active_connections matrix is host-testable.

    * unsupported target or `enabled: false` → no adapters (flags 0)
    * `active_connections: false` → scanner only (HA sees a passive-only
      proxy: no ACTIVE_CONNECTIONS / REMOTE_CACHING / PAIRING flags)
    * both on → scanner + GATT proxy (full flag set, 0x7F)
  """
  @spec bluetooth_opts(boolean(), %{
          required(:enabled) => boolean(),
          required(:active_connections) => boolean(),
          optional(atom()) => term()
        }) :: keyword()
  def bluetooth_opts(false, _settings), do: []
  def bluetooth_opts(true, %{enabled: false}), do: []

  def bluetooth_opts(true, %{active_connections: false}),
    do: [bluetooth_scanner: BluetoothScanner]

  def bluetooth_opts(true, _settings),
    do: [bluetooth_scanner: BluetoothScanner, bluetooth_proxy: BluetoothProxy]

  # Defensive read: if the settings store isn't up (it always is on BT
  # targets by boot order, but stay safe), fall back to the defaults.
  defp bluetooth_settings do
    UniversalProxy.Bluetooth.Settings.get()
  catch
    :exit, _ -> UniversalProxy.Bluetooth.Settings.defaults()
  end

  # Resolve the tty path of the Z-Wave-classified port. Two sources
  # cooperate:
  #
  #   1. `Hardware.list_ports/0` already auto-classifies the Nabu Casa
  #      Connect ZWA-2 by VID/PID (`0x10C4:0xEA60`), so the common case
  #      needs no saved config.
  #   2. A user-saved `:zwave` override on a generic port still wins.
  defp resolve_zwave_port do
    case Enum.find(Hardware.list_ports(), &(&1.connected and &1.kind == :zwave)) do
      nil ->
        # Fallback for pre-existing saved configs that target a port
        # whose adapter isn't currently classified as Z-Wave by
        # Hardware (e.g. a CP2102N on a non-ZWA-2 device).
        key_to_tty = Hardware.live_port_keys()

        case Enum.find(UARTStore.all_configs(), fn cfg ->
               cfg[:port_type] == :zwave and
                 Map.has_key?(key_to_tty, {cfg[:slot_sub], cfg[:vendor_id], cfg[:product_id]})
             end) do
          nil -> nil
          cfg -> Map.get(key_to_tty, {cfg[:slot_sub], cfg[:vendor_id], cfg[:product_id]})
        end

      port ->
        port.tty_name
    end
  end
end
