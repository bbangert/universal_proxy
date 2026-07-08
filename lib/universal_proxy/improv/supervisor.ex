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

  ## Mounting contract

  Improv is a *consumer* of the `Bluez` subtree, not part of it: mount this
  supervisor in `Bluez`'s `extra_children:` slot, appended **last**. Under the
  `Bluez` parent's `:rest_for_one` strategy that position means a
  `bluetoothd`/`Bluez.Client` restart rebuilds the whole Improv group (whose
  exporters hold now-stale D-Bus registrations), while an Improv fault never
  disturbs anything before it — proxy scanning/GATT or audio stacks. The app
  does this in `UniversalProxy.Bluetooth.bluez_spec/0`, which is also where the
  host passes the manager's opts (`pubsub:`, `network_type:`, `ifname:`, …) and
  the advert branding (`name_prefix:` / `local_name:`).
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  # `opts` are the Improv manager's opts (`pubsub:`, `network_type:`,
  # `ifname:`, …) plus the advert branding (`name_prefix:` / `local_name:`),
  # passed in this supervisor's child spec (see bluez_spec/0).
  def init(opts) do
    {advert_opts, manager_opts} = Keyword.split(opts, [:local_name, :name_prefix])

    children = [
      # Runs the re-entrant Register{Application,Advertisement} calls off the
      # GenServer loops (they call back into our own handlers).
      {Task.Supervisor, name: UniversalProxy.Improv.TaskSupervisor},
      # Exporters first — the manager registers and drives them on arm.
      UniversalProxy.Improv.GattServer,
      {UniversalProxy.Improv.Advert, advert_opts},
      {UniversalProxy.Improv, manager_opts}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
