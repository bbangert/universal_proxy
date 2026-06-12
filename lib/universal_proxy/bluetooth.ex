defmodule UniversalProxy.Bluetooth do
  @moduledoc """
  Bluetooth subtree: owns the BlueZ stack, the runtime enable/disable +
  radio-selection settings behind the `/bluetooth` web tab, and the
  subscriber registry that feeds advertisements to Home Assistant.

  Children, started `:rest_for_one`:

    1. a duplicate-key `Registry`
       (`UniversalProxy.ESPHome.BluetoothScanner.registry_name/0`) holding
       every subscribed ESPHome connection-handler pid. Registry-up-first
       guarantees the advert fan-out's `Registry.dispatch` never hits a
       missing table.
    2. `UniversalProxy.Bluetooth.Settings` — DETS-persisted user settings
       (enabled / active-connections / selected radio MAC).
    3. a `DynamicSupervisor` the BlueZ subtree runs under.
    4. `UniversalProxy.Bluetooth.Manager` — the runtime gate: starts/stops
       `UniversalProxy.Bluez` under the DynamicSupervisor per the `enabled`
       setting, resolving the selected radio MAC to an adapter path
       (`:persistent_term`) **before** each subtree start.

  `UniversalProxy.Bluez` brings up `dbus-daemon` + `bluetoothd` so the
  kernel-attached controller is managed by BlueZ over D-Bus; the `rebus`
  client + advertisement reconstruction that call
  `UniversalProxy.ESPHome.BluetoothScanner.on_advertisement/1` attach
  inside that subtree.

  ## Public API (consumed by the Bluetooth LiveView)

  The functions in this module are safe on every target and in every
  lifecycle state: on non-BT targets (or while the subtree is down) the
  readers return a disabled-shaped status and the setters return clean
  errors instead of raising — same defensive posture as the espex adapters.

  State changes are broadcast on `Phoenix.PubSub` (`UniversalProxy.PubSub`):

    * `state_topic()` (`"bluetooth:state"`) — `{:bluetooth_state, status}`
      on any toggle / radio switch / subtree lifecycle change.

  ## Compile-time gating

  Off-target (host, or any Nerves target outside BT scope), `child_spec/1`
  returns a normal spec whose `start_link/1` returns `:ignore`, so the
  supervisor treats this module as a no-op there. The advert fan-out
  adapter (`UniversalProxy.ESPHome.BluetoothScanner`) is itself unguarded
  so it can be unit-tested on the host against a registry started in the
  test — as are `Settings`, `Manager`, and `Radios`.

  BT scope (`@bluetooth_targets`) = every Pi running a custom
  BlueZ-enabled system. Only rpi3 is hardware-validated; the others share
  its design (rpi0/rpi0_2: same miniuart-bt serdev path; rpi4/rpi5:
  device-tree UNVERIFIED — see the bluetooth-dbus-migration handoff).

  ## When the controller never appears

  On a board whose BT bring-up fails (broken DT, no onboard radio, no USB
  dongle yet), `UniversalProxy.Bluez.Client` gives up after ~10 s
  (`:no_adapter`) and the `Bluez` subtree restarts. Each cycle takes
  longer than the DynamicSupervisor's intensity window, so this is a benign
  endless retry loop, not an escalating crash: the app stays healthy, and
  a USB BT dongle (btusb is in the custom systems) hot-plugged later is
  picked up by the next cycle.
  """

  alias UniversalProxy.Bluetooth.Manager

  @bluetooth_targets [:rpi0, :rpi0_2, :rpi3, :rpi4, :rpi5]

  # Compile-time constant: `Mix.target/0` is unavailable at runtime in a
  # Nerves release, so bake the predicate in. Single source of truth for
  # gating both this subtree and the espex `bluetooth_scanner:` wiring.
  @bluetooth_supported Mix.target() in @bluetooth_targets

  @state_topic "bluetooth:state"

  @doc """
  Whether this build targets BT-capable hardware (compile-time constant).

  `UniversalProxy.ESPHome.Supervisor` reads this to decide whether to wire
  the `bluetooth_scanner:` adapter into espex, so `:rpi3` is not hardcoded
  in two places.
  """
  @spec supported?() :: boolean()
  def supported?, do: @bluetooth_supported

  @doc "PubSub topic carrying `{:bluetooth_state, status}` broadcasts."
  @spec state_topic() :: String.t()
  def state_topic, do: @state_topic

  @doc """
  Current Bluetooth status for the web tab:

      %{enabled: boolean(), proxying?: boolean(),
        adapter: %{hci: String.t(), address: String.t() | nil, name: String.t() | nil} | nil,
        active_connections: %{allowed?: boolean(), used: n, limit: n}}

  Safe on any target: when the Manager isn't running (non-BT target, early
  boot) this returns a disabled-shaped map instead of raising.
  """
  @spec status() :: map()
  def status do
    Manager.status()
  catch
    :exit, _ ->
      %{
        enabled: false,
        proxying?: false,
        adapter: nil,
        active_connections: %{allowed?: false, used: 0, limit: 0}
      }
  end

  if @bluetooth_supported do
    use Supervisor

    # Aliased inside the guard: on non-BT targets this branch is compiled
    # out, so a top-level alias would be flagged unused under
    # --warnings-as-errors (CI compiles MIX_TARGET=host).
    alias UniversalProxy.Bluetooth.Settings
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

        # Persisted user settings. Before the Manager, which reads them to
        # decide whether to bring the BlueZ stack up.
        Settings,

        # The BlueZ subtree (dbus-daemon + bluetoothd + scanner/GATT
        # clients) runs under here, started/stopped by the Manager.
        {DynamicSupervisor, name: __MODULE__.DynamicSupervisor, strategy: :one_for_one},

        # Runtime lifecycle gate (see its @moduledoc).
        Manager
      ]

      # rest_for_one: a registry restart cascades into everything below so
      # any advert dispatcher re-runs against the fresh table; a
      # Manager-only restart leaves the registry — and its subscribers —
      # untouched.
      Supervisor.init(children, strategy: :rest_for_one)
    end
  else
    @doc false
    def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

    @doc false
    def start_link(_opts), do: :ignore
  end
end
