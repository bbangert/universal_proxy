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

  alias UniversalProxy.Bluetooth.{Manager, RadioMonitor, Settings}

  @bluetooth_targets [:rpi0, :rpi0_2, :rpi3, :rpi4, :rpi5]

  # Compile-time constant: `Mix.target/0` is unavailable at runtime in a
  # Nerves release, so bake the predicate in. Single source of truth for
  # gating both this subtree and the espex `bluetooth_scanner:` wiring.
  @bluetooth_supported Mix.target() in @bluetooth_targets

  @state_topic "bluetooth:state"
  @radios_topic "bluetooth:radios"

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

  @doc "PubSub topic carrying `{:bluetooth_radios, radios}` broadcasts."
  @spec radios_topic() :: String.t()
  def radios_topic, do: @radios_topic

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

  @doc """
  The known radios (cached, ≤ 5 s old):

      [%{hci:, address:, name:, chip:, bus:, detail:, bt_version:,
         ble?:, bredr?:, in_use?:}]

  `[]` on non-BT targets or before the monitor is up.
  """
  @spec list_radios() :: [map()]
  def list_radios do
    RadioMonitor.list()
  catch
    :exit, _ -> []
  end

  @doc """
  Re-enumerate radios right now (the UI's Rescan button); broadcasts on
  `radios_topic()` if anything changed and returns the fresh list.
  """
  @spec refresh_radios() :: [map()]
  def refresh_radios do
    RadioMonitor.refresh()
  catch
    :exit, _ -> []
  end

  @doc """
  Master Bluetooth switch: persist, start/stop the BlueZ subtree, then
  restart espex so the bluetooth feature flags HA sees follow the setting
  (flags 0 when disabled). HA connections drop and reconnect within
  seconds — the same accepted behavior as UART config writes.
  """
  @spec set_enabled(boolean()) :: :ok | {:error, term()}
  def set_enabled(enabled) when is_boolean(enabled) do
    with :ok <- Settings.set_enabled(enabled) do
      :ok = Manager.reconcile()
      _ = RadioMonitor.refresh()
      restart_esphome()
      :ok
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc """
  Allow/forbid HA opening active (GATT) connections. The BlueZ subtree is
  untouched (Gatt idles harmlessly when espex isn't wired to it); only the
  espex adapter wiring — and therefore the feature flags — changes, so HA
  drops to a passive-only scanner when off.
  """
  @spec set_active_connections(boolean()) :: :ok | {:error, term()}
  def set_active_connections(allowed) when is_boolean(allowed) do
    with :ok <- Settings.set_active_connections(allowed) do
      # No lifecycle change — reconcile only rebroadcasts the status map.
      :ok = Manager.reconcile()
      restart_esphome()
      :ok
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc """
  Switch the BlueZ stack to the radio with the given MAC (`nil` = auto:
  first/onboard controller). Persist, then stop/start the BlueZ subtree
  pointed at the new adapter — active BLE connections drop by design and
  the scanner re-engages on the new radio. No espex restart: the feature
  flags don't depend on which radio is in use.

  `{:error, :unknown_radio}` if no enumerated radio has that MAC.
  """
  @spec select_radio(String.t() | nil) :: :ok | {:error, term()}
  def select_radio(nil) do
    with :ok <- Settings.set_adapter(nil) do
      :ok = Manager.reconcile(restart: true)
      _ = RadioMonitor.refresh()
      :ok
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def select_radio(mac) when is_binary(mac) do
    normalized = String.upcase(mac)

    if Enum.any?(list_radios(), &(&1.address == normalized)) do
      with :ok <- Settings.set_adapter(normalized) do
        :ok = Manager.reconcile(restart: true)
        _ = RadioMonitor.refresh()
        :ok
      end
    else
      {:error, :unknown_radio}
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  # Espex restart so device-info feature flags follow the settings —
  # async fire-and-forget, the UART.Store precedent.
  defp restart_esphome do
    Task.start(fn -> UniversalProxy.ESPHome.Supervisor.restart() end)
  end

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

        # Persisted user settings. Before the Manager, which reads them to
        # decide whether to bring the BlueZ stack up.
        Settings,

        # The BlueZ subtree (dbus-daemon + bluetoothd + scanner/GATT
        # clients) runs under here, started/stopped by the Manager.
        {DynamicSupervisor, name: __MODULE__.DynamicSupervisor, strategy: :one_for_one},

        # Runtime lifecycle gate (see its @moduledoc).
        Manager,

        # Radio list for the web tab (5 s hotplug poll). Runs even while
        # Bluetooth is disabled — the tab lists radios to pick before
        # enabling. After the Manager: its in_use? mark reads the
        # Manager-owned adapter path + status.
        RadioMonitor
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
