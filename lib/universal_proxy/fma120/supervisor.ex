defmodule UniversalProxy.FMA120.Supervisor do
  @moduledoc """
  Groups the FMA120 `WorkerSupervisor` and `Server` under `:one_for_all`.

  If `FMA120.Server` crashes, the `WorkerSupervisor` (and all its device
  workers) are also torn down, preventing orphaned workers from holding
  `ttyACM*` ports open while the restarted server rebuilds its inventory.

  Wired into `application.ex` during Phase 4.
  """

  use Supervisor

  alias UniversalProxy.FMA120

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {DynamicSupervisor, name: FMA120.WorkerSupervisor, strategy: :one_for_one},
      FMA120.Server
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
