defmodule UniversalProxy.Improv.Supervisor do
  @moduledoc """
  Supervises the Improv provisioning processes as a `:one_for_all` group.

  The children are mutually dependent — the `Improv` manager registers and drives
  the `GattServer` + `Advert` D-Bus exporters (off-loop via the `Task.Supervisor`)
  — so a crash of any one must restart all of them together. Under the parent
  `Bluez` supervisor's `:rest_for_one`, the manager (started last)
  crashing would otherwise leave `GattServer`/`Advert` running: the cleartext GATT
  app + advertisement would stay exported with no session timers or disarm logic.

  Restarting the whole group instead drops the exporters' own `rebus` connections,
  which makes `bluetoothd` auto-unregister the GATT application + advertisement,
  and the manager re-evaluates connectivity from a clean slate.

  Improv is a *consumer* of the Bluez subtree, not part of it: the app mounts
  this supervisor via the `extra_children:` slot of
  `UniversalProxy.Bluetooth.bluez_spec/0`, appended LAST so an Improv fault
  never disturbs the proxy scanning/GATT or audio stacks, while a
  `bluetoothd`/`Client` restart (`:rest_for_one`) still rebuilds the whole group.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  # `opts` are the Improv manager's opts (`pubsub:`, `network_type:`, …),
  # passed in this supervisor's child spec (see bluez_spec/0).
  def init(opts) do
    children = [
      # Runs the re-entrant Register{Application,Advertisement} calls off the
      # GenServer loops (they call back into our own handlers).
      {Task.Supervisor, name: UniversalProxy.Improv.TaskSupervisor},
      # Exporters first — the manager registers and drives them on arm.
      UniversalProxy.Improv.GattServer,
      UniversalProxy.Improv.Advert,
      {UniversalProxy.Improv, opts}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
