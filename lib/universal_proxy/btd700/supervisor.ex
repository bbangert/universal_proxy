defmodule UniversalProxy.BTD700.Supervisor do
  @moduledoc """
  Groups the BTD700 `WorkerSupervisor` and `Server` under `:one_for_all`.

  If `BTD700.Server` crashes, the `WorkerSupervisor` (and all its device
  workers) are also torn down, preventing orphaned workers from holding
  hidraw fds open while the restarted server rebuilds its inventory.

  Wired into `application.ex` directly after `FMA120.Supervisor`.
  """

  use Supervisor

  alias UniversalProxy.BTD700

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {DynamicSupervisor, name: BTD700.WorkerSupervisor, strategy: :one_for_one},
      BTD700.Server
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
