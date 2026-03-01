defmodule UniversalProxy.ESPHome.Infrared.Supervisor do
  @moduledoc """
  Groups the infrared WorkerSupervisor and Server under `:one_for_all`.

  If `Infrared.Server` crashes, the WorkerSupervisor (and all its children)
  are also terminated, preventing orphaned workers from holding UART ports
  open while the restarted server re-builds its inventory.
  """

  use Supervisor

  alias UniversalProxy.ESPHome.Infrared

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {DynamicSupervisor, name: Infrared.WorkerSupervisor, strategy: :one_for_one},
      Infrared.Server
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
