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
  require Logger

  @dbus_daemon "/usr/bin/dbus-daemon"
  @bluetoothd "/usr/libexec/bluetooth/bluetoothd"
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
      # device signals into advertisements for the ESPHome scanner. Last in
      # rest_for_one order so it (re)connects only once bluetoothd is up.
      __MODULE__.Client
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
end
