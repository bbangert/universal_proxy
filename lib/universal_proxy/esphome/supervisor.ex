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

  alias UniversalProxy.ESPHome.{ConfigStore, Infrared, SerialProxy, ZWaveProxy}
  alias UniversalProxy.UART.Enumerate, as: UARTEnumerate
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

    children = [
      {ZWaveProxy, port_path: zwave_port_path},
      Infrared.Supervisor,
      {Espex,
       device_config: device_config,
       serial_proxy: SerialProxy,
       zwave_proxy: ZWaveProxy,
       infrared_proxy: Infrared.Server,
       mdns: Espex.Mdns.MdnsLite}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp resolve_zwave_port do
    serial_to_path = UARTEnumerate.serial_to_path(UARTEnumerate.safe())

    config =
      Enum.find(UARTStore.all_configs(), fn cfg ->
        cfg[:port_type] == :zwave and Map.has_key?(serial_to_path, cfg[:serial_number])
      end)

    case config do
      nil -> nil
      cfg -> Map.get(serial_to_path, cfg[:serial_number])
    end
  end
end
