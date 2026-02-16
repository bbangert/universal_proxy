defmodule UniversalProxy.UART.Supervisor do
  @moduledoc """
  Top-level supervisor for the UART subsystem.

  Starts the `DynamicSupervisor` that manages individual `Circuits.UART`
  GenServer processes, followed by the `UniversalProxy.UART.Server` registry
  GenServer. Uses `:rest_for_one` so that if the DynamicSupervisor restarts,
  the Server (which holds references to those children) also restarts.
  """

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {DynamicSupervisor, name: UniversalProxy.UART.PortSupervisor, strategy: :one_for_one},
      UniversalProxy.UART.Store,
      UniversalProxy.UART.Server
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
