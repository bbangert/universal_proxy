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

  alias UniversalProxy.ESPHome.{BluetoothScanner, ConfigStore, Infrared, SerialProxy, ZWaveProxy}
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
    device_config = ConfigStore.device_config_opts()

    espex_opts =
      [
        device_config: device_config,
        serial_proxy: SerialProxy,
        zwave_proxy: ZWaveProxy,
        infrared_proxy: Infrared.Server,
        mdns: Espex.Mdns.MdnsLite
      ] ++ bluetooth_scanner_opt()

    children = [
      {ZWaveProxy, port_path: zwave_port_path},
      Infrared.Supervisor,
      {Espex, espex_opts}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  # Wire the passive BLE scanner adapter into espex ONLY on BT-capable
  # targets. `UniversalProxy.Bluetooth.supported?/0` is the single gate (a
  # compile-time constant) so `:rpi3` isn't hardcoded here as well. Off
  # target the key is omitted entirely, so espex leaves the scanner feature
  # disabled and the bluetooth_proxy feature flags stay 0.
  #
  # Boot ordering: this supervisor starts (see `application.ex`) BEFORE
  # `target_children()`, where the `UniversalProxy.Bluetooth` subtree — and
  # thus the scanner registry the adapter dispatches over — lives. That is
  # safe: `BluetoothScanner.subscribe/1` guards the early-boot window with
  # `catch :exit`, and a client can only subscribe long after boot (once HA
  # connects and sends `SubscribeBluetoothLEAdvertisementsRequest`).
  defp bluetooth_scanner_opt do
    if UniversalProxy.Bluetooth.supported?() do
      [bluetooth_scanner: BluetoothScanner]
    else
      []
    end
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
