defmodule UniversalProxy.ESPHome.Supervisor do
  @moduledoc """
  Top-level supervisor for the ESPHome Native API subsystem.

  Starts children in order with `:rest_for_one` strategy:

  1. `Server` -- holds device config and tracks connections (must be up first)
  2. `ThousandIsland` -- TCP server that accepts connections and spawns
     `Connection` handler processes for each client

  If the Server crashes, ThousandIsland also restarts (since Connection
  handlers depend on the Server for device config).
  """

  use Supervisor

  alias UniversalProxy.ESPHome.{Connection, Server}

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
    config = UniversalProxy.ESPHome.DeviceConfig.new()

    children = [
      Server,
      {ThousandIsland,
       port: config.port,
       handler_module: Connection,
       transport_module: ThousandIsland.Transports.TCP,
       transport_options: [nodelay: true],
       num_acceptors: 10}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
