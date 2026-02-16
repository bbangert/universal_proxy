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
