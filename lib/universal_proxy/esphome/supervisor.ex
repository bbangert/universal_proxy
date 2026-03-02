defmodule UniversalProxy.ESPHome.Supervisor do
  @moduledoc """
  Top-level supervisor for the ESPHome Native API subsystem.

  Starts children in order with `:rest_for_one` strategy:

  1. `Server` -- holds device config and tracks connections (must be up first)
  2. `ZWave.Server` -- manages the Z-Wave UART port and frame parsing
  3. `Infrared.Supervisor` -- groups the IR WorkerSupervisor and Server
     under `:one_for_all` so both restart together
  4. `ThousandIsland` -- TCP server that accepts connections and spawns
     `Connection` handler processes for each client

  If any server crashes, everything below restarts too (since Connection
  handlers depend on them for device config, Z-Wave, and IR subscriptions).
  """

  use Supervisor

  alias UniversalProxy.ESPHome.{Connection, DeviceConfig, Infrared, Server, ZWave}
  alias UniversalProxy.UART.Store, as: UARTStore

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc """
  Restart the ESPHome supervisor tree.

  Closes all UART ports opened by connection handlers, then terminates and
  restarts this supervisor under the application supervisor. This forces all
  active client connections to drop and reconnect, re-reading the updated
  device info (including serial_proxies).
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
    config = DeviceConfig.new()
    zwave_port_path = resolve_zwave_port()

    children = [
      Server,
      {ZWave.Server, port_path: zwave_port_path},
      Infrared.Supervisor,
      {ThousandIsland,
       port: config.port,
       handler_module: Connection,
       transport_module: ThousandIsland.Transports.TCP,
       transport_options: [nodelay: true],
       num_acceptors: 10}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp resolve_zwave_port do
    configs = UARTStore.all_configs()
    enumerated = Circuits.UART.enumerate()

    serial_to_path =
      enumerated
      |> Enum.filter(fn {_path, info} -> present?(info[:serial_number]) end)
      |> Enum.into(%{}, fn {path, info} -> {info[:serial_number], path} end)

    zwave_config =
      Enum.find(configs, fn config ->
        config[:port_type] == :zwave and Map.has_key?(serial_to_path, config[:serial_number])
      end)

    case zwave_config do
      nil -> nil
      config -> Map.get(serial_to_path, config[:serial_number])
    end
  rescue
    _ -> nil
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(s) when is_binary(s), do: String.trim(s) != ""
  defp present?(_), do: false
end
