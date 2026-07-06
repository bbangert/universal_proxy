defmodule UniversalProxy.Bluez do
  @moduledoc """
  Brings up the Linux BlueZ stack so the kernel-attached controller (`hci0`)
  is managed by `bluetoothd` over D-Bus. This is the replacement for the
  vendored `blue_heron` raw-HCI stack on rpi3 (see the bluetooth-dbus
  migration handoff).

  Children, started `:rest_for_one`:

    1. `dbus-daemon --system` (`MuonTrap.Daemon`) — owns the system bus at
       `/run/dbus/system_bus_socket`.
    2. `Bluez.BusReady` — a one-line gate that blocks until the bus socket
       exists, so `bluetoothd` never races the bus. `:rest_for_one` re-runs
       it (and `bluetoothd`) if `dbus-daemon` restarts.
    3. `bluetoothd` (`MuonTrap.Daemon`) — claims `org.bluez`, drives `hci0`
       via the kernel mgmt socket. The `rebus` client + advertisement
       reconstruction (Stage B) attach on top of this.
    4. `bluealsad` (`MuonTrap.Daemon`) — bluez-alsa's A2DP-source daemon.
       Claims `org.bluealsa`, and for every connected A2DP headset exposes an
       ALSA PCM `bluealsa:DEV=MAC,PROFILE=a2dp` that sendspin opens directly.
       Placed **after the proxy scanning/GATT clients** (Client/Agent/Gatt) so
       it comes up once `org.bluez` exists and so a `bluealsad` crash never
       restarts the **proxy scanning/GATT stack** — audio is secondary to the
       BT proxy's scanning, which must survive an audio-daemon fault. The audio
       children that follow it (`BlueAlsa`, `AudioManager`) *do* restart with it
       under `:rest_for_one`, which is intended — they're the same audio path.
       (The plan said "before Client"; that would put it ahead of the scanning
       stack and tear scanning down on a crash, contradicting the rationale.)

  ## Why this can't coexist with `blue_heron`

  Both stacks drive the **same** physical Broadcom chip. `blue_heron` opens
  the raw mini-UART (`/dev/ttyS0`) and resets/configures the chip directly;
  the kernel's `hci_uart` serdev driver has *also* bound that chip as `hci0`.
  Verified on rpi3: with `blue_heron` running, its raw HCI traffic knocks
  `hci0` off the kernel mgmt interface (`bluetoothd` then sees 0 controllers).
  So `blue_heron` has been removed as a dependency on rpi3 (it also crash-loops
  at boot with no transport configured); `UniversalProxy.Bluetooth` starts this
  supervisor instead.

  ## Read-only rootfs

  `/`, `/etc`, `/var` are a read-only squashfs; only `/tmp`, `/run`, and
  `/root` (= `/data`) are writable. `bluetoothd` stores adapter state under
  `/var/lib/bluetooth`, which a `rootfs_overlay` symlink redirects to
  `/data/bluetooth`; `dbus-daemon` needs `/run/dbus`. `prepare_runtime/0`
  creates those (and a machine-id) before the daemons launch.
  """

  use Supervisor

  @dbus_daemon "/usr/bin/dbus-daemon"
  @bluetoothd "/usr/libexec/bluetooth/bluetoothd"
  # bluez-alsa renamed the daemon `bluealsa` -> `bluealsad` in v4.0. Buildroot
  # may carry either, so resolve at start; prefer the v4 name.
  @bluealsad_candidates ["/usr/bin/bluealsad", "/usr/bin/bluealsa"]
  @run_dir "/run/dbus"
  @socket_path "/run/dbus/system_bus_socket"
  @machine_id_path "/run/dbus/machine-id"
  # `/var/lib/bluetooth` is a rootfs_overlay symlink to this writable path.
  @bluetooth_state_dir "/data/bluetooth"

  @doc "System-bus socket path the rebus client (Stage B) connects to."
  @spec socket_path() :: String.t()
  def socket_path, do: @socket_path

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    prepare_runtime()

    children = [
      # System bus. --nofork so MuonTrap's port owns the process; --nopidfile
      # because /var/run is read-only and we don't read a pidfile anyway.
      # Both daemons are MuonTrap.Daemon, so each needs a distinct child :id
      # (the default id is the module, which collides).
      Supervisor.child_spec(
        {MuonTrap.Daemon,
         [
           @dbus_daemon,
           ["--system", "--nofork", "--nopidfile"],
           [name: __MODULE__.Dbus, log_output: :info, log_prefix: "dbus-daemon: "]
         ]},
        id: :dbus_daemon
      ),

      # Gate: bluetoothd must not start before the bus socket exists.
      __MODULE__.BusReady,

      # The BlueZ daemon. -n keeps it in the foreground (MuonTrap tracks it);
      # -E enables experimental interfaces, required for
      # org.bluez.AdvertisementMonitorManager1 (passive scanning). stderr
      # carries its logs, surfaced via RingLogger for bring-up.
      Supervisor.child_spec(
        {MuonTrap.Daemon,
         [
           @bluetoothd,
           ["-n", "-E"],
           [
             name: __MODULE__.Bluetoothd,
             env: [{"DBUS_SYSTEM_BUS_ADDRESS", "unix:path=#{@socket_path}"}],
             stderr_to_stdout: true,
             log_output: :info,
             log_prefix: "bluetoothd: "
           ]
         ]},
        id: :bluetoothd
      ),

      # Persistent rebus client: owns the discovery session and turns BlueZ
      # device signals into advertisements for the ESPHome scanner. After
      # bluetoothd in rest_for_one order so it (re)connects only once
      # bluetoothd is up.
      __MODULE__.Client,

      # Default org.bluez pairing agent (Phase 2): bluetoothd routes the IO
      # for Gatt's Device1.Pair() calls here. Before Gatt in rest_for_one
      # order — Gatt depends on it (weakly: its casts no-op when the Agent
      # is down), never the other way around.
      __MODULE__.Agent,

      # Active connections + GATT (Phase 1): every BlueZ call the GATT
      # client makes runs under this Task.Supervisor so its GenServer loop
      # never blocks on D-Bus (Device1.Connect alone can take ~25 s).
      {Task.Supervisor, name: __MODULE__.Gatt.task_supervisor()},

      # The GATT client itself (its own rebus connection, separate from
      # Client). Last so a bluetoothd/Client restart also rebuilds it —
      # its device objects and connection state die with bluetoothd.
      __MODULE__.Gatt,

      # bluez-alsa A2DP-source daemon. No `-i`: manages all controllers; role
      # separation (which adapter may pair/connect headsets) is enforced at the
      # pairing layer (Bluetooth.AudioManager), not here. Runs without
      # `--keep-alive`/codec flags for now — those get tuned during hardware
      # bring-up (1.5) once the exact bluez-alsa version/flag set is confirmed,
      # so an unrecognized flag can't crash-loop the daemon at boot. Placed
      # after the proxy scanning/GATT clients: a crash here never restarts the
      # proxy scanning stack (only the audio children that follow — BlueAlsa,
      # AudioManager — restart with it under :rest_for_one). See @moduledoc.
      Supervisor.child_spec(
        {MuonTrap.Daemon,
         [
           bluealsad_path(),
           ["-p", "a2dp-source"],
           [
             name: __MODULE__.BlueAlsad,
             env: [{"DBUS_SYSTEM_BUS_ADDRESS", "unix:path=#{@socket_path}"}],
             stderr_to_stdout: true,
             log_output: :info,
             log_prefix: "bluealsad: "
           ]
         ]},
        id: :bluealsad
      ),

      # org.bluealsa D-Bus client: learns which A2DP-playback PCMs are ready to
      # open (Bluetooth.AudioSink shapes these into Sendspin outputs). Connects
      # to the system bus (dbus-daemon), not to bluealsad, so it tolerates
      # bluealsad being down. After the scanning/GATT clients: a crash here must
      # not restart the proxy scanning stack — audio is secondary to the BT proxy.
      __MODULE__.BlueAlsa,

      # Bluetooth headphone control plane. It's an org.bluez D-Bus client like
      # Client/Gatt (hence it lives in this subtree, after them, so its bus
      # connection and adapter lookups are always available), but it drives the
      # *audio*-role adapters rather than the proxy adapter. Its Connect calls
      # (up to ~25 s) run under this Task.Supervisor so the GenServer loop never
      # blocks. Both sit after the scanning/GATT clients so a fault here never
      # disturbs the proxy scanning stack, and a bluetoothd/Client restart
      # re-runs reconnect-on-boot.
      {Task.Supervisor, name: UniversalProxy.Bluetooth.AudioManager.TaskSupervisor},
      UniversalProxy.Bluetooth.AudioManager,

      # Improv-over-BLE Wi-Fi provisioning. Its own :one_for_all sub-supervisor
      # (GattServer + Advert + manager + Task.Supervisor) so the mutually-dependent
      # processes restart as a unit — a manager crash can't leave the cleartext
      # GATT app/advert exported without the session timers/disarm logic (see
      # Improv.Supervisor). Placed LAST here so an Improv fault never disturbs the
      # proxy scanning/GATT or audio stacks, while a bluetoothd/Client restart
      # (earlier, :rest_for_one) still rebuilds the whole group.
      UniversalProxy.Bluez.Improv.Supervisor
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  Create the writable dirs the daemons need before they launch. Idempotent;
  safe to call on every (re)start of this supervisor.
  """
  @spec prepare_runtime() :: :ok
  def prepare_runtime do
    File.mkdir_p!(@run_dir)
    # A previous incarnation's socket file survives its dbus-daemon
    # (runtime stop/start via Bluetooth.Manager) — and a stale file makes
    # BusReady wave clients through to ECONNREFUSED before the NEW daemon
    # has bound it. Hardware-found on the first enable→disable→enable
    # round-trip. Remove it so socket existence again implies a listener.
    _ = File.rm(@socket_path)
    File.mkdir_p!(@bluetooth_state_dir)
    # bluetoothd stores pairing/link keys + the adapter identity here; keep it
    # owner-only rather than the default world-readable 0755.
    File.chmod!(@bluetooth_state_dir, 0o700)
    ensure_machine_id()
    :ok
  end

  # dbus tolerates a generated/ephemeral machine-id, but write a stable one to
  # the writable run dir so every component on the bus agrees. 32 lowercase hex
  # chars, no dashes — the D-Bus machine-id format.
  defp ensure_machine_id do
    unless File.exists?(@machine_id_path) do
      id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
      File.write!(@machine_id_path, id <> "\n")
    end
  end

  @doc false
  @spec dbus_daemon_path() :: String.t()
  def dbus_daemon_path, do: @dbus_daemon

  @doc false
  @spec bluetoothd_path() :: String.t()
  def bluetoothd_path, do: @bluetoothd

  @doc """
  Resolve the bluez-alsa daemon binary. Prefers the v4 name (`bluealsad`),
  falling back to the v3 name (`bluealsa`); returns the v4 name if neither is
  present on disk (e.g. host where it isn't installed) so the child spec is
  still well-formed — MuonTrap surfaces the missing-binary error at start.
  """
  @spec bluealsad_path() :: String.t()
  def bluealsad_path do
    Enum.find(@bluealsad_candidates, &File.exists?/1) || hd(@bluealsad_candidates)
  end
end
