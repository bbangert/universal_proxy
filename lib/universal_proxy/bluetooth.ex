defmodule UniversalProxy.Bluetooth do
  @moduledoc """
  Bluetooth subtree: owns the BlueZ stack and the subscriber registry that
  feeds advertisements to Home Assistant.

  Children, started `:rest_for_one` (registry first):

    1. a duplicate-key `Registry`
       (`UniversalProxy.ESPHome.BluetoothScanner.registry_name/0`) holding
       every subscribed ESPHome connection-handler pid. Registry-up-first
       guarantees the advert fan-out's `Registry.dispatch` never hits a
       missing table.
    2. `UniversalProxy.Bluez` — brings up `dbus-daemon` + `bluetoothd` so the
       kernel-attached controller (`hci0`) is managed by BlueZ over D-Bus.
       The `rebus` client + advertisement reconstruction that call
       `UniversalProxy.ESPHome.BluetoothScanner.on_advertisement/1` attach
       inside that subtree (Stage B).

  ## Migration off blue_heron

  This replaces the vendored `blue_heron` raw-HCI stack on rpi3, which has
  been removed as a dependency. The two cannot coexist — both drive the same
  physical chip, and `blue_heron`'s raw mini-UART access knocks the kernel's
  `hci0` off the mgmt interface (see `UniversalProxy.Bluez`). It also
  crash-loops at boot without a transport, so it can't simply be left idle.

  Compile-time guarded: off-target (host, or any Nerves target outside BT
  scope), `child_spec/1` returns a normal spec whose `start_link/1` returns
  `:ignore`, so the supervisor treats this module as a no-op there. The advert
  fan-out adapter (`UniversalProxy.ESPHome.BluetoothScanner`) is itself
  unguarded so it can be unit-tested on the host against a registry started in
  the test.

  BT scope = `:rpi3` only for now (`@bluetooth_targets`).
  """

  @bluetooth_targets [:rpi3]

  # Compile-time constant: `Mix.target/0` is unavailable at runtime in a
  # Nerves release, so bake the predicate in. Single source of truth for
  # gating both this subtree and the espex `bluetooth_scanner:` wiring.
  @bluetooth_supported Mix.target() in @bluetooth_targets

  @doc """
  Whether this build targets BT-capable hardware (compile-time constant).

  `UniversalProxy.ESPHome.Supervisor` reads this to decide whether to wire
  the `bluetooth_scanner:` adapter into espex, so `:rpi3` is not hardcoded
  in two places.
  """
  @spec supported?() :: boolean()
  def supported?, do: @bluetooth_supported

  if @bluetooth_supported do
    use Supervisor

    # Aliased inside the guard: on non-BT targets this branch is compiled
    # out, so a top-level alias would be flagged unused under
    # --warnings-as-errors (CI compiles MIX_TARGET=host).
    alias UniversalProxy.ESPHome.BluetoothScanner

    def start_link(opts \\ []) do
      Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
    end

    @impl Supervisor
    def init(_opts) do
      children = [
        # Subscriber registry FIRST so the advert fan-out's dispatch always
        # finds a live table. Duplicate keys: N connections fan out under the
        # single `:subscribers` key.
        {Registry, keys: :duplicate, name: BluetoothScanner.registry_name()},

        # BlueZ stack (dbus-daemon + bluetoothd). The rebus client that turns
        # on discovery and reconstructs adverts into
        # `BluetoothScanner.on_advertisement/1` lives inside this subtree.
        UniversalProxy.Bluez
      ]

      # rest_for_one: a registry restart cascades into the BlueZ subtree so
      # any advert dispatcher re-runs against the fresh table; a BlueZ restart
      # leaves the registry — and its subscribers — untouched.
      Supervisor.init(children, strategy: :rest_for_one)
    end
  else
    @doc false
    def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

    @doc false
    def start_link(_opts), do: :ignore
  end
end
