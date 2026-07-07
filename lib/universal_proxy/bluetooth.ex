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
    4. `UniversalProxy.Bluetooth.Manager` — keeps `Bluez`
       running (always — the `enabled` setting gates espex wiring, not the
       stack) and performs radio switches, publishing the selected radio
       MAC (`:persistent_term`) **before** each subtree (re)start.

  `Bluez` brings up `dbus-daemon` + `bluetoothd` so the
  kernel-attached controller is managed by BlueZ over D-Bus; the `rebus`
  client + advertisement reconstruction that call
  `UniversalProxy.ESPHome.BluetoothScanner.on_advertisement/1` attach
  inside that subtree.

  ## Public API (consumed by the Bluetooth LiveView)

  The functions in this module are safe on every target and in every
  lifecycle state: on non-BT targets (or while the subtree is down) the
  readers return a disabled-shaped status and the setters return clean
  errors instead of raising — same defensive posture as the espex adapters.

  Tradeoff to know: the `catch :exit, _` wrappers convert BOTH the
  process-not-running exit AND a call **timeout** into the same
  "subsystem off" default, so a wedged server renders as a disabled
  subsystem rather than raising. Deliberate (benign UI degradation over
  crash cascades) and project-wide — see CLAUDE.md "Public-API
  `catch :exit` idiom". New wrappers must follow the idiom knowingly.

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

  BT scope (`@bluetooth_targets`) = every target running a custom
  BlueZ-enabled system. The onboard-BT Pis (rpi0/rpi0_2/rpi3/rpi4/rpi5)
  carry a SoC radio; rpi/rpi2/x86_64 have none but accept USB BT dongles
  (btusb is in every custom system). Only rpi3 is hardware-validated; the
  rest are UNVERIFIED — rpi0/rpi0_2 share rpi3's miniuart-bt serdev path,
  rpi4/rpi5 device-trees are unverified, and rpi/rpi2/x86_64 are USB-dongle
  only (no onboard radio → the benign retry loop below until one is
  plugged). See the bluetooth-dbus-migration handoff.

  ## When the controller never appears

  On a board whose BT bring-up fails (broken DT, no onboard radio, no USB
  dongle yet), `Bluez.Client` gives up after ~10 s
  (`:no_adapter`) and the `Bluez` subtree restarts. The loop is benign by
  configuration: both the `Bluez` supervisor and the DynamicSupervisor it
  runs under carry explicit `max_restarts: 10, max_seconds: 60` budgets,
  sized so the ~10 s `:no_adapter` cycle AND a faster-failing variant
  (e.g. `:dbus_connect_failed` from init) stay below the intensity
  threshold — while a genuinely hot crash loop still escalates within a
  minute. The app stays healthy, and a USB BT dongle (btusb is in the
  custom systems) hot-plugged later is picked up by the next cycle.
  """

  alias UniversalProxy.Bluetooth.{AudioManager, Manager, RadioMonitor, Settings, Stats}

  @bluetooth_targets [:rpi, :rpi0, :rpi0_2, :rpi2, :rpi3, :rpi4, :rpi5, :x86_64]

  # Compile-time constant: `Mix.target/0` is unavailable at runtime in a
  # Nerves release, so bake the predicate in. Single source of truth for
  # gating both this subtree and the espex `bluetooth_scanner:` wiring.
  @bluetooth_supported Mix.target() in @bluetooth_targets

  @state_topic "bluetooth:state"
  @radios_topic "bluetooth:radios"
  @stats_topic "bluetooth:stats"

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

  @doc "PubSub topic carrying `{:bluetooth_stats, stats}` broadcasts (1 s tick)."
  @spec stats_topic() :: String.t()
  def stats_topic, do: @stats_topic

  @doc """
  The `Bluez` child spec with every app-side callback wired
  in — the single place the app plugs itself into the (espex-agnostic)
  Bluez subtree. `Manager`'s `bluez_child:` default starts exactly this.

    * adverts fan out to HA via `BluetoothScanner.on_advertisement/1`;
    * GATT events are translated to espex messages by
      `BluetoothProxy.gatt_event/2`;
    * connection-slot changes tick `Stats`;
    * the app's own children mount in the `extra_children:` slot (after
      `BlueAlsa`): the AudioManager pair (BT-headphone control plane)
      first — preserving the restart-ordering semantics it had as a
      hardcoded child — then `UniversalProxy.Improv.Supervisor` LAST, so
      an Improv fault never disturbs the proxy scanning/GATT or audio
      stacks while a bluetoothd/Client restart (`:rest_for_one`) still
      rebuilds the whole group. Improv gets the app's PubSub +
      connectivity probe here.
  """
  @spec bluez_spec() :: Supervisor.child_spec() | {module(), keyword()}
  def bluez_spec do
    {Bluez,
     client: [
       on_advertisement: &UniversalProxy.ESPHome.BluetoothScanner.on_advertisement/1,
       pubsub: UniversalProxy.PubSub
     ],
     gatt: [
       on_gatt_event: &UniversalProxy.ESPHome.BluetoothProxy.gatt_event/2,
       on_connections_changed: &Stats.connections_changed/0
     ],
     blue_alsa: [pubsub: UniversalProxy.PubSub],
     extra_children: [
       {Task.Supervisor, name: AudioManager.TaskSupervisor},
       AudioManager,
       {UniversalProxy.Improv.Supervisor,
        [
          pubsub: UniversalProxy.PubSub,
          network_type: &UniversalProxy.System.network_type/0
        ]}
     ]}
  end

  @doc """
  Current Bluetooth status for the web tab:

      %{enabled: boolean(), proxying?: boolean(), paused?: boolean(),
        adapter: %{hci: String.t(), address: String.t() | nil, name: String.t() | nil} | nil,
        active_connections: %{allowed?: boolean(), used: n, limit: n}}

  `paused?` marks the role-paused state (roles assigned, none `:proxy` —
  see `Settings.proxy_paused?/1`); it forces `proxying?` false.

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
        paused?: false,
        adapter: nil,
        active_connections: %{allowed?: false, used: 0, limit: 0}
      }
  end

  @doc """
  Live statistics for the web tab (last computed tick):

      %{ads_per_s: n, devices_15min: n, connections: %{used: n, limit: n}}

  Zeros on non-BT targets or while the subsystem is down.
  """
  @spec stats() :: map()
  def stats do
    Stats.current()
  catch
    :exit, _ -> %{ads_per_s: 0, devices_15min: 0, connections: %{used: 0, limit: 0}}
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
  Per-radio role assignment for the web tab, as

      %{proxy: String.t() | nil, audio: [String.t()]}

  `proxy` is the proxy-role radio MAC (or the legacy auto fallback, which may
  be `nil`); `audio` is the list of audio-role radio MACs. Any radio not in
  either is `:off`. Safe on non-BT targets / while Settings is down (returns
  the empty-role shape). Read-only; role changes go through `set_role/2`.
  """
  @spec roles() :: %{proxy: String.t() | nil, audio: [String.t()]}
  def roles do
    settings = Settings.get()
    %{proxy: Settings.proxy_adapter(settings), audio: Settings.audio_adapters(settings)}
  catch
    :exit, _ -> %{proxy: nil, audio: []}
  end

  @doc """
  Master Bluetooth switch — purely an espex-wiring gate. The BlueZ stack
  (and its radios) keeps running either way; what changes is whether the
  scanner/GATT adapters are wired into espex, so HA sees bluetooth
  feature flags 0 and no data when disabled (nothing subscribes — the
  scan data is ignored at the Elixir layer). Persist → rebroadcast
  status → restart espex. HA connections drop and reconnect within
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

    # Validates against an enumeration snapshot — a radio unplugged between
    # this check and the restart is fine: the Manager falls back to the
    # first present controller when the persisted MAC can't be resolved.
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

  @doc """
  Assign a radio's role (`:proxy | :audio | :off`) and act on the change.

  Because BlueZ bonds are per-adapter, a radio **leaving** the `:audio` role
  would orphan its paired speakers — so this disconnects + forgets them
  (`AudioManager.forget_all_on_adapter/2`). When the change moves the
  proxy-role radio, the BlueZ subtree is restarted to re-target it; otherwise
  it just rebroadcasts status. When the change flips the role-paused state
  (`Settings.proxy_paused?/1`), the Manager's reconcile bounces espex so the
  HA-facing feature flags follow — pausing really stops the proxy, resuming
  re-advertises it.

  Note the sequence here is multi-step under one `catch :exit` (see
  CLAUDE.md's documented tradeoff): if the Manager wedges *after* the
  settings write and bond-forget committed, the caller sees
  `{:error, :unavailable}` for a change that partially happened. Accepted
  for the same reason as the base idiom — single-admin usage, benign UI
  degradation over crash cascades. Callers that want a confirm step (the UI's
  "deactivating forgets N speakers" modal) gather the affected speakers from
  `AudioManager.list_headphones/0` (filtered by `:adapter`) before calling.
  """
  @spec set_role(String.t(), Settings.role()) :: :ok | {:error, term()}
  def set_role(mac, role) when is_binary(mac) do
    normalized = String.upcase(mac)
    settings = Settings.get()
    before_proxy = Settings.proxy_adapter(settings)
    before_role = Settings.role(settings, normalized)

    with :ok <- Settings.set_role(normalized, role) do
      # Only when a radio actually LEAVES the :audio role do we forget its
      # per-adapter bonds — matching the UI's deactivate-confirm, which gates on
      # the same transition. Other transitions (e.g. :off -> :proxy) must not
      # forget (the radio holds no audio bonds to begin with, and there'd be no
      # confirmation step).
      if before_role == :audio and role != :audio do
        AudioManager.forget_all_on_adapter(normalized)
      end

      # The Manager owns the pausedness→espex reaction: its reconcile
      # detects a proxy_paused?/1 flip and bounces espex itself, serialized
      # in one process so concurrent setters can't misattribute the flip.
      if Settings.proxy_adapter(Settings.get()) != before_proxy do
        :ok = Manager.reconcile(restart: true)
      else
        :ok = Manager.reconcile()
      end

      _ = RadioMonitor.refresh()
      :ok
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  # Espex restart so device-info feature flags follow the settings — async
  # fire-and-forget under the app's Task.Supervisor (crash visibility), the
  # UART.Store precedent. NOTE for the LiveView layer: every call bounces
  # espex (drops HA connections), so debounce/disable the toggles in the UI
  # while a write is in flight — same exposure as UART/Audio config saves.
  defp restart_esphome do
    Task.Supervisor.start_child(UniversalProxy.TaskSupervisor, fn ->
      UniversalProxy.ESPHome.Supervisor.restart()
    end)
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
        # Restart budget matches the Bluez supervisor's own 10/60 s: the
        # default 3-in-5 s is exactly what a fast-failing Bluez subtree
        # (e.g. :dbus_connect_failed on every init) would trip, walking
        # the escalation chain toward a BEAM exit + Nerves reboot loop.
        {DynamicSupervisor,
         name: __MODULE__.DynamicSupervisor,
         strategy: :one_for_one,
         max_restarts: 10,
         max_seconds: 60},

        # Runtime lifecycle gate (see its @moduledoc).
        Manager,

        # Radio list for the web tab (5 s hotplug poll). Runs even while
        # Bluetooth is disabled — the tab lists radios to pick before
        # enabling. After the Manager: its in_use? mark reads the
        # Manager-owned adapter path + status.
        RadioMonitor,

        # 1 s stats tick (ads/s, devices seen, GATT slots). Sources are
        # read defensively, so it ticks zeros while the subtree is down.
        Stats
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
