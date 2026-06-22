defmodule UniversalProxy.Bluez.Improv.Supervisor do
  @moduledoc """
  Supervises the Improv provisioning processes as a `:one_for_all` group.

  The children are mutually dependent — the `Improv` manager registers and drives
  the `GattServer` + `Advert` D-Bus exporters (off-loop via the `Task.Supervisor`)
  — so a crash of any one must restart all of them together. Under the parent
  `UniversalProxy.Bluez` supervisor's `:rest_for_one`, the manager (started last)
  crashing would otherwise leave `GattServer`/`Advert` running: the cleartext GATT
  app + advertisement would stay exported with no session timers or disarm logic.

  Restarting the whole group instead drops the exporters' own `rebus` connections,
  which makes `bluetoothd` auto-unregister the GATT application + advertisement,
  and the manager re-evaluates connectivity from a clean slate.

  Mounted as a single child of `UniversalProxy.Bluez` (last, in `:rest_for_one`
  order) so a `bluetoothd`/`Client` restart still rebuilds the whole group.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      # Runs the re-entrant Register{Application,Advertisement} calls off the
      # GenServer loops (they call back into our own handlers).
      {Task.Supervisor, name: UniversalProxy.Bluez.Improv.TaskSupervisor},
      # Exporters first — the manager registers and drives them on arm.
      UniversalProxy.Bluez.Improv.GattServer,
      UniversalProxy.Bluez.Improv.Advert,
      UniversalProxy.Bluez.Improv
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
