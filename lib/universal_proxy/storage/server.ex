defmodule UniversalProxy.Storage.Server do
  @moduledoc """
  Orchestrates the USB backup drive: detection, mount, and the opt-in
  `smbd` share.

  ## One convergence path

  Every state change goes through `converge/1`. It runs from `init/1`, from
  the debounced hotplug handler, from the poll fallback, and after each
  public mutation, and each pass:

    1. lists drives through `Storage.Probe`,
    2. sniffs the filesystem of the **first** drive: the `:read_head_fun`
       seam reads its first #{4096} bytes (and each partition's),
       `Probe.fs_type/1` classifies them, `Probe.first_data_partition/1`
       picks the target,
    3. binds an adopted mount (see below) to the drive that owns its
       device, or unmounts it when no attached drive does,
    4. stops the share and unmounts when the mounted drive has gone away,
    5. mounts the target partition when nothing is mounted — unless the
       kernel already has something at the mount point, which is adopted
       rather than stacked under a second mount,
    6. reads the mounted drive's stored `share_folder` and its capacity,
    7. starts or stops `smbd` so that it runs **iff** the drive's
       `share_enabled?` is set AND a drive is mounted AND an `smbd` binary
       exists AND the stored `share_folder` still passes the sandbox
       against the live mount (see `validated_share_folder/1`).

  Convergence is idempotent, so no step ever retries in place: a failure
  is logged, the state goes degraded, and the next pass tries again. On
  target there is no poll (hotplug is uevent-driven), so a pass that
  leaves work undone — a target partition that failed to mount, a share
  that failed to start — arms one `:retry_converge` timer
  (#{30_000} ms, never stacked) rather than waiting for the next
  physical event.

  Only the first drive is sniffed and mounted: multi-drive support is out
  of scope, and reading the head of every partition of every attached disk
  would wake drives for nothing. Drives past the first are reported with
  `fs_type: nil` ("not sniffed", distinct from `:unknown`).

  ## The active drive is position 0

  "First drive" is a position, not an identity: `first_drive/2` — the one
  key check `eject/2` and `format/3` share — accepts the head of `drives`,
  and the UI reads the same position for its primary row, its "only the
  first drive is used" notice and its share binding. `Probe` sorts by
  device name, so that position is **not** stable across a hotplug: an
  `nvme0n1` enclosure attached behind a mounted `/dev/sda` sorts ahead of
  it.

  So while a mount is live, the drive that owns it is moved to position 0
  on every pass (`active_drive_first/2`) regardless of sort order. A
  destructive action can then only ever name the mounted drive, and the
  mount target, the sniffed drive and the UI's primary all stay the same
  drive for as long as the mount lasts. Only when nothing is mounted does
  probe order choose, and what it chooses is the next mount target.

  ## PubSub

  The full state map is broadcast on `"storage:state"` as
  `{:storage_state, payload}` whenever it changes (mount, unmount, share
  start/stop, capacity, drive set):

      %{
        drives: [drive_map()],
        mount: nil | %{device:, fs_type:, mode:, point:, stale?:},
        share: :off | :running | :error,
        share_folder: String.t(),
        capacity: nil | %{total_bytes:, used_bytes:, free_bytes:, used_pct:}
      }

  `share_folder` is the mounted drive's stored share mapping — `"/"` for
  the drive root, otherwise a drive-relative path (`"backups/ha"`). It is
  `"/"` whenever nothing is mounted, and it is read from
  `Storage.Settings` on every pass rather than held as the source of
  truth, so a change made through `set_share_folder/3` is always
  broadcast.

  `stale?: true` means a busy filesystem survived both a plain and a lazy
  `umount` — the kernel will finish the detach on its own, but until then
  the mount point cannot be trusted. Only the removal path can produce
  it: see the umount semantics below.

  ## Two umount semantics

  A lazy `umount` (`umount -l`) detaches the name but leaves the kernel
  holding the filesystem until the last user drops it, so it is **not**
  a flush and **not** a safe-to-unplug or safe-to-mkfs signal. The two
  callers therefore get different unmounts:

    * `eject/2` and `format/3` use `do_unmount/1`, a plain `umount` with
      no fallback. A busy filesystem is refused (`{:error, :busy}` /
      `{:error, {:umount_failed, _}}`) with the mount left exactly as it
      was — telling the user to unplug, or handing `mkfs` a device the
      kernel still has open, is what the refusal prevents.
    * `reconcile_removal/1` uses `force_unmount/1`, which retries lazily
      and marks the mount stale if even that fails. The drive is already
      physically gone: there is nothing left to flush and nothing for the
      user to unplug, so detaching the name is the best available
      outcome.

  ## Adopting a mount this process did not make

  The kernel's mount table outlives this process: the `:one_for_all`
  supervisor restarts the Server (and the application can restart the
  subtree) while `/run/usb-backup` stays mounted. `mount` does not fail on
  an already-mounted point, it **stacks** — so a fresh Server that
  believed nothing was mounted would either overmount the live filesystem
  (an "unmount" then pops one layer while the drive is still held) or hand
  `fsck.ext4` a mounted filesystem.

  So `init/1` reads the OS mount table (`:mounts_path`, default
  `/proc/self/mounts`) and adopts any entry for the mount point —
  `device`, `fs_type` and read-only/read-write `mode` all come from the
  table. The drive identity cannot: `Probe` has not run yet, so
  `mounted_ref` stays `nil` until the first convergence binds it to the
  drive owning that device. An adopted mount whose device belongs to no
  attached drive is a drive that left while this process was down, and it
  takes the removal path (`force_unmount/1`).

  The same table read guards every mount: a point the kernel says is
  already mounted is adopted, never mounted on top of.

  ## Who restarts `smbd`

  The daemon child spec is `restart: :temporary`
  (`Storage.Smbd.child_spec/1`) and this server monitors the pid it
  started. A `smbd` that dies on its own therefore stays dead until the
  `{:DOWN, …}` handler marks the share `:error` and runs a convergence
  pass, which decides afresh whether the share should run at all
  (opt-in, mount, validated folder) — the same gate a first start goes
  through.

  A supervisor restart would instead bring `smbd` back under a **new**
  pid, leaving this server's stored pid stale: `terminate_child` would
  answer `:not_found`, the state would say `:off`, and a live `smbd`
  would keep port 445 open and the mount point busy — breaking the next
  eject or format. `stop_share/1` additionally sweeps
  `DynamicSupervisor.which_children/1`, because nothing else runs under
  that supervisor: any child left there is an `smbd` this server has lost
  track of.

  ## Untrusted paths

  `set_share_folder/3`, `list_folders/2` and `create_folder/3` take paths
  straight from the UI, so both the folder browser and the share mapping
  are sandboxed to the mount point: see `sandboxed_path/2` for the
  two-guard strategy (segment rejection *before* expansion, prefix check
  *after*).

  A *stored* mapping is untrusted too, and for a second reason: it is
  persisted, while the drive it points into is not — the directory can be
  deleted or replaced by a symlink between one share start and the next.
  So the same sandbox runs again on every share start, and a mapping that
  no longer passes leaves the share `:error` rather than falling back to
  the drive root.

  `format/3` takes a **drive key**, never a device path: the device handed
  to `mkfs` is resolved from this server's own state (see
  `format_target/2`), so no caller can name one.

  ## Drive keys

  Per-drive settings are keyed `{slot_sub, vendor_id, product_id}` with
  the ids as lowercase 4-digit hex **strings** — that is the key shape
  `Storage.Settings` declares and persists (note it differs from
  `Audio.Store`, whose ids are integers). A drive whose `slot_sub` could
  not be derived gets `key: nil` and can never have its share enabled:
  there is nothing stable to persist the opt-in against.

  ## Failure posture

  No `Probe`/`Mount`/`Smbd`/`Settings` result can crash this server: every
  call goes through `safe/3`, which logs and substitutes a degraded
  default. That deliberately collapses "subsystem missing" and "subsystem
  wedged" into one degraded state, the same tradeoff the public-API
  `catch :exit` idiom makes (see CLAUDE.md).

  ## Test seams (`start_link/1` options)

    * `:probe`, `:mount`, `:smbd` — the module for each side effect
      (defaults `Storage.Probe`, `Storage.Mount`, `Storage.Smbd`), plus
      `:probe_opts`, `:mount_opts`, `:smbd_opts` passed through to them.
    * `:settings` — the `Storage.Settings` server reference.
    * `:daemon_supervisor` — the `DynamicSupervisor` smbd runs under.
    * `:read_head_fun` — `(device_path -> {:ok, binary} | {:error, term})`.
    * `:netbios_name_fun` — `(-> String.t() | nil)`.
    * `:mounts_path` — the OS mount table to rehydrate and guard against
      (default `#{"/proc/self/mounts"}`); a file a test can rewrite
      mid-run to simulate the kernel's view changing.
    * `:pubsub`, `:poll_interval`, `:debounce_ms`, `:retry_interval`.
    * `:subscribe_uevents?` — `false` skips the uevent subscription so the
      poll fallback is exercised. Needed because `nerves_uevent` (a
      `nerves_runtime` dependency) *does* start its PropertyTable on the
      host, so the subscription succeeds there even though no kernel event
      is ever published.
    * `:start_timer` — `false` disables the initial convergence, the poll
      fallback and the retry timer; tests drive convergence with
      `check_now/1`.
  """

  use GenServer

  require Logger

  alias UniversalProxy.Audio.Input.DeviceInfo
  alias UniversalProxy.Storage.{Mount, Probe, Settings, Smbd}

  @pubsub UniversalProxy.PubSub
  @topic "storage:state"

  @default_daemon_supervisor UniversalProxy.Storage.DaemonSupervisor

  # Host/dev poll fallback, used only when kernel uevents are unavailable.
  @poll_interval 5_000
  # Delay between a `block` uevent and the convergence it triggers: gives
  # the kernel a beat to publish the partition children, and coalesces the
  # burst of uevents one stick emits into a single pass.
  @debounce_ms 1_000
  # Self-heal interval for a pass that left work undone. Long enough not
  # to be a retry loop, short enough that a transient mount or smbd
  # failure doesn't wedge the subsystem until the next replug.
  @retry_interval 30_000

  # Superblock magics all live inside the first 4 KiB (Probe.fs_type/1).
  @head_bytes 4096

  # The kernel's own view of what is mounted where. Read at init (to adopt
  # a mount that outlived this process) and before every mount (so a point
  # that is already mounted is never stacked under a second one).
  @default_mounts_path "/proc/self/mounts"

  # mkfs.ext4 with `lazy_itable_init=0` writes every inode table up
  # front, which on a large slow stick is minutes. The Server is
  # deliberately blocked for the duration — nothing else may touch the
  # device mid-format — so the call timeout has to cover it.
  @format_timeout 600_000

  # The share can be mapped at a subdirectory of the drive. `"/"` is the
  # drive root and the default for every drive.
  @root_folder "/"

  # Windows' reserved filename characters, which the design adopts as the
  # new-folder rule so a name created here is usable from every SMB
  # client. `/` in the set is also what keeps a name from being a path.
  @forbidden_name_chars ["\\", "/", ":", "*", "?", "\"", "<", ">", "|"]
  @max_name_bytes 64

  # NetBIOS names are 15 characters, full stop; a longer one is a config
  # error smbd complains about. Node names are `universal-proxy-<mac6>`,
  # so fall back to the distinguishing tail rather than a truncation that
  # would read the same on every device.
  @netbios_max 15
  @netbios_fallback "universal-proxy"

  @type drive_key :: {String.t(), String.t() | nil, String.t() | nil}

  @type mount_info :: %{
          device: String.t(),
          fs_type: Probe.fs_type(),
          mode: Mount.mode(),
          point: String.t() | nil,
          stale?: boolean()
        }

  @type share :: :off | :running | :error

  @type payload :: %{
          drives: [map()],
          mount: mount_info() | nil,
          share: share(),
          share_folder: String.t(),
          capacity: Mount.capacity() | nil
        }

  defstruct probe: Probe,
            mount: Mount,
            smbd: Smbd,
            settings: Settings,
            daemon_supervisor: @default_daemon_supervisor,
            probe_opts: [],
            mount_opts: [],
            smbd_opts: [],
            read_head_fun: nil,
            netbios_name_fun: nil,
            mounts_path: @default_mounts_path,
            pubsub: @pubsub,
            poll_interval: @poll_interval,
            debounce_ms: @debounce_ms,
            retry_interval: @retry_interval,
            subscribe_uevents?: true,
            auto?: true,
            hotplug_pending: false,
            retry_timer: nil,
            drives: [],
            mounted: nil,
            # `{drive_name, drive_key}` of the mounted drive — the identity
            # removal is detected against. The name alone would collide
            # when a different stick reclaims "sda"; the key alone is nil
            # for a drive with no derivable bus path.
            mounted_ref: nil,
            # Drive refs the user safely ejected. Suppresses remounting
            # until the drive physically leaves (or is formatted), which is
            # what makes eject stick across the next convergence.
            ejected: MapSet.new(),
            share: :off,
            share_pid: nil,
            # Monitor of `share_pid`. The pid alone cannot be trusted as
            # "the share is up": only a monitor tells this server when the
            # daemon dies, and only demonitoring on a deliberate stop
            # keeps that from reading back as a crash.
            share_monitor: nil,
            # Mirror of the mounted drive's stored `share_folder`, refreshed
            # from `Storage.Settings` on every convergence pass.
            share_folder: @root_folder,
            capacity: nil

  # -- Client API --

  def start_link(opts \\ []) do
    gen_opts =
      case Keyword.get(opts, :name, __MODULE__) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  The full state map — the same payload broadcast on `"storage:state"`.
  """
  @spec get_state(GenServer.server()) :: payload()
  def get_state(server \\ __MODULE__), do: GenServer.call(server, :get_state)

  @doc """
  Persist a drive's share opt-in, then converge (which starts or stops
  `smbd`). Returns the persistence result: convergence itself is
  asynchronous and reports through `"storage:state"`, so a slow
  `smbpasswd` can't time out the caller.
  """
  @spec set_share_enabled(GenServer.server(), drive_key(), boolean()) :: :ok | {:error, term()}
  def set_share_enabled(server \\ __MODULE__, {slot_sub, _vid, _pid} = key, enabled?)
      when is_binary(slot_sub) and is_boolean(enabled?) do
    GenServer.call(server, {:set_share_enabled, key, enabled?})
  end

  @doc """
  Map the drive's share at `path`: `"/"` for the drive root, otherwise a
  drive-relative path of plain segments (`"backups/ha"`) that must
  already exist inside the mount point.

  Validated and sandboxed before anything is written (`..`, empty
  segments and absolute paths are refused, and the resolved directory has
  to sit under the mount point and exist). On success the setting is
  persisted, the chosen directory is chowned to the backup account on a
  read-write ext4 mount (a pre-existing directory can belong to another
  uid, which would leave the share unwritable) and, when this drive's
  share is the running one, `smbd` is stopped so the convergence that
  follows rebuilds `smb.conf` with the new `path` and starts it again.
  Like `set_share_enabled/3` the restart is asynchronous and reports
  through `"storage:state"`, so a slow `smbpasswd` cannot time the caller
  out.

  Returns the persistence result, `{:error, :invalid_path}`,
  `{:error, :enoent}` (no such directory on the drive), or
  `{:error, :not_mounted}`.
  """
  @spec set_share_folder(GenServer.server(), drive_key(), String.t()) :: :ok | {:error, term()}
  def set_share_folder(server \\ __MODULE__, {slot_sub, _vid, _pid} = key, path)
      when is_binary(slot_sub) and is_binary(path) do
    GenServer.call(server, {:set_share_folder, key, path})
  end

  @doc """
  The subdirectories of `rel_path` on the mounted drive, sorted, with
  dot-prefixed directories omitted and non-directories filtered out.

  `rel_path` is drive-relative (`"/"` or `""` is the drive root) and
  sandboxed to the mount point exactly as `set_share_folder/3`'s is.
  Returns `{:error, :not_mounted}` when no drive is mounted,
  `{:error, :invalid_path}` for anything that would escape, and the raw
  `File.ls/1` posix error otherwise.
  """
  @spec list_folders(GenServer.server(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_folders(server \\ __MODULE__, rel_path) when is_binary(rel_path) do
    GenServer.call(server, {:list_folders, rel_path})
  end

  @doc """
  Create directory `name` inside `rel_path` on the mounted drive and
  return its drive-relative path, ready to hand to `set_share_folder/3`.

  `rel_path` is sandboxed as in `list_folders/2`. `name` must be a single
  non-empty name of at most #{@max_name_bytes} bytes, containing none of
  `#{Enum.join(@forbidden_name_chars)}` and no control characters, and be
  neither `"."` nor `".."`. On a read-write ext4 mount the new directory
  is also chowned to the backup account, otherwise smbd's `force user`
  could not write into it.

  Returns `{:ok, relative_path}`, `{:error, :eexist}` for a duplicate,
  `{:error, :invalid_name}` / `{:error, :name_too_long}`, or the same
  path errors as `list_folders/2`.
  """
  @spec create_folder(GenServer.server(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def create_folder(server \\ __MODULE__, rel_path, name)
      when is_binary(rel_path) and is_binary(name) do
    GenServer.call(server, {:create_folder, rel_path, name})
  end

  @doc """
  Stop the share and unmount the drive `drive_key` identifies, and keep
  it unmounted until it is physically removed (or formatted).
  `umount(2)` flushes, so a successful eject is the safe-to-unplug
  signal — which is why this never falls back to a lazy detach:
  `{:error, :busy}` when the filesystem will not come down, with the
  drive still mounted and the share restored by the convergence that
  follows.

  Only the active drive — the mounted one, else the first attached (see
  the moduledoc) — may be named: `{:error, :unknown_drive}` otherwise
  (`nil` matches an active drive with no derivable bus path, which is
  exactly the drive that has no key). `{:error, :not_mounted}` when that
  drive has no mount.

  A format in flight needs no extra guard: `mkfs.ext4` runs inside
  `handle_call/3`, so this call sits in the mailbox until the format (and
  the convergence that remounts after it) is done. Serialization is the
  guarantee — there is no window in which both act on the same device.
  """
  @spec eject(GenServer.server(), drive_key() | nil) :: :ok | {:error, term()}
  def eject(server \\ __MODULE__, drive_key)
      when is_nil(drive_key) or (is_tuple(drive_key) and tuple_size(drive_key) == 3) do
    GenServer.call(server, {:eject, drive_key})
  end

  @doc """
  Make a fresh ext4 filesystem on the drive `drive_key` identifies,
  labelled `label`: stop the share, unmount, `mkfs.ext4`, then converge
  (which mounts the new filesystem). Destroys every byte on the device.

  The target device is resolved **here**, from this server's state, not
  named by the caller: the live mount's device when the mounted drive is
  this one, else the drive's first recognised data partition, else the
  whole disk. `{:error, :unknown_drive}` when `drive_key` is not the
  active drive's key (`nil` matches an active drive with no derivable bus
  path, which is exactly the drive that has no key).

  Refuses (with the unmount's error) if the drive cannot be unmounted, so
  a busy filesystem is never handed to `mkfs`. The unmount is a plain
  one: a lazy detach would leave the kernel holding the very filesystem
  `mkfs` is about to overwrite.
  """
  @spec format(GenServer.server(), drive_key() | nil, String.t()) :: :ok | {:error, term()}
  def format(server \\ __MODULE__, drive_key, label)
      when is_binary(label) and
             (is_nil(drive_key) or (is_tuple(drive_key) and tuple_size(drive_key) == 3)) do
    GenServer.call(server, {:format, drive_key, label}, @format_timeout)
  end

  @doc """
  Apply freshly rotated Samba credentials: a share that is running was
  started with the old password, so its daemon is stopped and the
  convergence that follows reprovisions the smbd account and starts it
  again. A no-op when no share is running — the next start reads the new
  password from `Storage.Settings` anyway.

  Called by `UniversalProxy.Storage.rotate_password/0` after the rotation
  is persisted; the rotation itself does not depend on this succeeding.
  """
  @spec credentials_rotated(GenServer.server()) :: :ok
  def credentials_rotated(server \\ __MODULE__),
    do: GenServer.call(server, :credentials_rotated)

  @doc "Converge synchronously. Tests use this instead of waiting on a timer."
  @spec check_now(GenServer.server()) :: :ok
  def check_now(server \\ __MODULE__), do: GenServer.call(server, :check_now)

  @doc "The PubSub topic the state map is broadcast on."
  @spec topic() :: String.t()
  def topic, do: @topic

  # -- Server callbacks --

  @impl true
  def init(opts) do
    state = %__MODULE__{
      probe: Keyword.get(opts, :probe, Probe),
      mount: Keyword.get(opts, :mount, Mount),
      smbd: Keyword.get(opts, :smbd, Smbd),
      settings: Keyword.get(opts, :settings, Settings),
      daemon_supervisor: Keyword.get(opts, :daemon_supervisor, @default_daemon_supervisor),
      probe_opts: Keyword.get(opts, :probe_opts, []),
      mount_opts: Keyword.get(opts, :mount_opts, []),
      smbd_opts: Keyword.get(opts, :smbd_opts, []),
      read_head_fun: Keyword.get(opts, :read_head_fun, &default_read_head/1),
      netbios_name_fun: Keyword.get(opts, :netbios_name_fun, &default_netbios_name/0),
      mounts_path: Keyword.get(opts, :mounts_path, @default_mounts_path),
      pubsub: Keyword.get(opts, :pubsub, @pubsub),
      poll_interval: Keyword.get(opts, :poll_interval, @poll_interval),
      debounce_ms: Keyword.get(opts, :debounce_ms, @debounce_ms),
      retry_interval: Keyword.get(opts, :retry_interval, @retry_interval),
      subscribe_uevents?: Keyword.get(opts, :subscribe_uevents?, true),
      auto?: Keyword.get(opts, :start_timer, true)
    }

    # Before anything converges: the mount point may already be mounted by
    # a previous incarnation of this process (see the moduledoc). Adopting
    # it is what keeps the first pass from stacking a second mount on top
    # of it, or from fsck-ing a live filesystem.
    state = rehydrate_mount(state)

    # Hotplug detection, `Audio.Server`'s triplet: prefer kernel uevents,
    # fall back to a periodic poll only when `nerves_uevent` isn't running
    # (host/dev). Either way one convergence runs immediately so a drive
    # attached at boot is mounted without waiting for an event.
    if state.auto? do
      unless state.subscribe_uevents? and subscribe_uevents() do
        if is_integer(state.poll_interval) and state.poll_interval > 0 do
          :timer.send_interval(state.poll_interval, self(), :check_hotplug)
        end
      end

      {:ok, state, {:continue, :converge}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_continue(:converge, state), do: {:noreply, converge(state)}

  @impl true
  def handle_call(:get_state, _from, state), do: {:reply, payload(state), state}

  def handle_call(:check_now, _from, state), do: {:reply, :ok, converge(state)}

  def handle_call({:set_share_enabled, key, enabled?}, _from, state) do
    result =
      safe(
        fn -> Settings.put_drive(state.settings, key, %{share_enabled?: enabled?}) end,
        {:error, :settings_unavailable},
        "Settings.put_drive"
      )

    {:reply, result, state, {:continue, :converge}}
  end

  def handle_call({:set_share_folder, key, path}, _from, state) do
    case resolve_share_folder(state, path) do
      {:ok, absolute, folder} ->
        result =
          safe(
            fn -> Settings.put_drive(state.settings, key, %{share_folder: folder}) end,
            {:error, :settings_unavailable},
            "Settings.put_drive"
          )

        state =
          if result == :ok do
            # The chosen directory may predate this device (or have been
            # made by another machine), in which case it belongs to some
            # other uid and smbd's `force user` could not write into it —
            # same reason `create_folder/3` chowns what it creates.
            take_ownership(state, absolute)
            stop_share_for(state, key)
          else
            state
          end

        {:reply, result, state, {:continue, :converge}}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:list_folders, rel_path}, _from, state) do
    {:reply, do_list_folders(state, rel_path), state}
  end

  def handle_call({:create_folder, rel_path, name}, _from, state) do
    {:reply, do_create_folder(state, rel_path, name), state}
  end

  def handle_call({:eject, key}, _from, state) do
    case first_drive(state, key) do
      {:ok, _drive} ->
        do_eject(state)

      {:error, :unknown_drive} = error ->
        Logger.warning("Storage: refusing to eject #{inspect(key)}: not the attached drive's key")

        {:reply, error, state}
    end
  end

  def handle_call({:format, key, label}, _from, state) do
    case format_target(state, key) do
      {:ok, device} ->
        # A drive with no mount at all is legitimate here (unknown
        # filesystem, or already ejected) — only a live mount has to come
        # down first. The target is resolved before the unmount, while the
        # mount record still says which device it is.
        {state, unmount_result} =
          if state.mounted,
            do: state |> stop_share() |> do_unmount(),
            else: {stop_share(state), :ok}

        case unmount_result do
          :ok ->
            result = format_device(state, device, label)
            # An explicit format overrides an earlier eject: the user asked
            # for this drive to be prepared, so convergence must mount it
            # again.
            {:reply, result, %{state | ejected: MapSet.new()}, {:continue, :converge}}

          error ->
            Logger.error(
              "Storage: refusing to format #{device}, unmount failed: #{inspect(error)}"
            )

            {:reply, {:error, {:umount_failed, error}}, state, {:continue, :converge}}
        end

      {:error, :unknown_drive} = error ->
        Logger.warning(
          "Storage: refusing to format #{inspect(key)}: not the attached drive's key"
        )

        {:reply, error, state}
    end
  end

  def handle_call(:credentials_rotated, _from, %{share: :running} = state) do
    Logger.info("Storage: Samba password rotated; restarting smbd to reprovision it")
    {:reply, :ok, stop_share(state), {:continue, :converge}}
  end

  def handle_call(:credentials_rotated, _from, state) do
    {:reply, :ok, state, {:continue, :converge}}
  end

  @impl true
  def handle_info(:check_hotplug, state) do
    {:noreply, converge(%{state | hotplug_pending: false})}
  end

  def handle_info(:retry_converge, state) do
    {:noreply, converge(%{state | retry_timer: nil})}
  end

  # The `smbd` child died on its own — its spec is `restart: :temporary`,
  # so nothing else brings it back (see the moduledoc). The share is
  # marked `:error` and that is published straight away, because the
  # convergence that follows only broadcasts when the payload *changes*: a
  # restart that fails would otherwise leave every subscriber still
  # showing `:running`. Convergence then decides whether to start it
  # again, through the same opt-in/mount/folder gate as a first start.
  def handle_info({:DOWN, ref, :process, pid, reason}, %{share_monitor: ref} = state) do
    Logger.warning("Storage: smbd (#{inspect(pid)}) exited: #{inspect(reason)}")

    state = %{state | share: :error, share_pid: nil, share_monitor: nil}
    broadcast(state)

    {:noreply, converge(state)}
  end

  # Kernel uevent (via NervesUEvent's PropertyTable). Only `block`
  # subsystem changes can move the drive set; everything else is ignored.
  def handle_info(%PropertyTable.Event{property: path}, state) do
    if "block" in path do
      {:noreply, schedule_hotplug(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Convergence --

  defp converge(state) do
    before = payload(state)

    state =
      state
      |> refresh_drives()
      |> bind_adopted_mount()
      |> reconcile_removal()
      |> reconcile_mount()
      |> refresh_share_folder()
      |> refresh_capacity()
      |> reconcile_share()

    if payload(state) != before, do: broadcast(state)

    schedule_retry(state)
  end

  defp refresh_drives(state) do
    drives =
      safe(fn -> state.probe.list_drives(state.probe_opts) end, [], "Probe.list_drives")
      |> List.wrap()
      |> active_drive_first(state)
      |> Enum.with_index()
      |> Enum.map(fn {drive, index} -> annotate(state, drive, index) end)

    present = MapSet.new(drives, &drive_ref/1)

    # An ejected drive that has physically left is forgotten, so plugging
    # it back in mounts it again.
    %{state | drives: drives, ejected: MapSet.intersection(state.ejected, present)}
  end

  # Position 0 *is* the active-drive marker (see `first_drive/2` and the
  # moduledoc), and `Probe` sorts by device name — so an `nvme0n1`
  # enclosure attached behind a mounted `/dev/sda` would sort ahead of it
  # and silently move the marker: `eject`/`format` would start accepting
  # the newcomer's key while operating on the sda mount. While a mount is
  # live it therefore owns position 0, whatever the sort says. With nothing
  # mounted there is no active drive and probe order picks the next mount
  # target.
  defp active_drive_first(drives, state) do
    if mounted?(state) do
      {active, others} = Enum.split_with(drives, &active_drive?(state, &1))
      active ++ others
    else
      drives
    end
  end

  # The bound identity when there is one; an adopted mount has none until
  # `bind_adopted_mount/1` runs (which is after this), so fall back to the
  # drive that owns the mounted device — the same test that binding uses.
  defp active_drive?(%{mounted_ref: ref}, drive) when not is_nil(ref),
    do: drive_ref(drive) == ref

  defp active_drive?(%{mounted: %{device: device}}, drive) when is_binary(device),
    do: owns_device?(drive, device)

  defp active_drive?(_state, _drive), do: false

  defp annotate(state, drive, 0) do
    partitions =
      drive
      |> Map.get(:partitions, [])
      |> Enum.map(fn partition ->
        Map.put(partition, :fs_type, sniff(state, partition.dev_path))
      end)

    drive
    |> Map.put(:key, drive_key(drive))
    |> Map.put(:fs_type, sniff(state, drive.dev_path))
    |> Map.put(:partitions, partitions)
  end

  defp annotate(_state, drive, _index) do
    # `nil` is "not sniffed", not "unrecognised" — Probe treats both as
    # non-data, but the UI can tell them apart.
    drive |> Map.put(:key, drive_key(drive)) |> Map.put(:fs_type, nil)
  end

  defp sniff(state, dev_path) do
    case safe(fn -> state.read_head_fun.(dev_path) end, {:error, :read_head_crashed}, "read_head") do
      {:ok, bytes} when is_binary(bytes) ->
        safe(fn -> state.probe.fs_type(bytes) end, :unknown, "Probe.fs_type")

      {:error, reason} ->
        Logger.debug("Storage: could not read #{dev_path} for fs sniff: #{inspect(reason)}")
        :unknown

      _other ->
        :unknown
    end
  end

  defp reconcile_removal(%{mounted_ref: nil} = state), do: state

  defp reconcile_removal(state) do
    present = MapSet.new(state.drives, &drive_ref/1)

    if MapSet.member?(present, state.mounted_ref) do
      state
    else
      Logger.info(
        "Storage: mounted drive #{inspect(state.mounted_ref)} disappeared; " <>
          "stopping the share and unmounting"
      )

      # Share first: smbd holds the mount point open, so unmounting under
      # a live daemon is what produces a busy filesystem.
      {state, _result} = state |> stop_share() |> force_unmount()
      state
    end
  end

  defp reconcile_mount(state) do
    if mounted?(state) do
      state
    else
      case target(state) do
        nil -> state
        {drive, partition} -> mount_or_adopt(state, drive, partition)
      end
    end
  end

  # Never stack a mount. `mount` succeeds on an already-mounted point and
  # hides what is under it, so an overmount would make the next `umount`
  # pop one layer while the drive stayed held (and "safe to unplug" would
  # be a lie), and the `fsck.ext4` on the way in would run against a live
  # filesystem. Whatever the kernel says is mounted here therefore wins
  # and is adopted as-is — which also covers the stale-marker case, where
  # `mounted` says "detached" while the kernel is still holding it.
  defp mount_or_adopt(state, drive, partition) do
    case os_mount(state) do
      nil ->
        do_mount(state, drive, partition)

      existing ->
        Logger.info(
          "Storage: #{existing.point} already holds #{existing.device}; adopting that mount " <>
            "instead of mounting #{partition.dev_path} on top of it"
        )

        bind_adopted_mount(%{state | mounted: existing, mounted_ref: nil})
    end
  end

  # A stale mount counts as "not mounted" for mounting purposes: the lazy
  # umount has detached the point, so a fresh mount can take it over and
  # replace the stale record.
  defp mounted?(%{mounted: nil}), do: false
  defp mounted?(%{mounted: %{stale?: true}}), do: false
  defp mounted?(_state), do: true

  defp target(state) do
    with [drive | _rest] <- state.drives,
         false <- MapSet.member?(state.ejected, drive_ref(drive)),
         partition when is_map(partition) <-
           safe(
             fn -> state.probe.first_data_partition(drive) end,
             nil,
             "Probe.first_data_partition"
           ) do
      {drive, partition}
    else
      _ -> nil
    end
  end

  defp do_mount(state, drive, partition) do
    result =
      safe(
        fn -> state.mount.mount(partition.dev_path, partition.fs_type, state.mount_opts) end,
        {:error, :mount_crashed},
        "Mount.mount"
      )

    case result do
      {:ok, mode} ->
        Logger.info(
          "Storage: mounted #{partition.dev_path} (#{partition.fs_type}, #{mode}) " <>
            "at #{mount_point(state)}"
        )

        %{
          state
          | mounted: %{
              device: partition.dev_path,
              fs_type: partition.fs_type,
              mode: mode,
              point: mount_point(state),
              stale?: false
            },
            mounted_ref: drive_ref(drive)
        }

      error ->
        # State is left untouched on purpose: a stale-mount marker from an
        # earlier failed unmount is still the truth about the mount point.
        Logger.warning(
          "Storage: mount of #{partition.dev_path} " <>
            "(#{inspect(partition.fs_type)}) failed: #{inspect(error)}"
        )

        state
    end
  end

  defp do_eject(%{mounted: nil} = state), do: {:reply, {:error, :not_mounted}, state}

  defp do_eject(state) do
    ref = state.mounted_ref

    case state |> stop_share() |> do_unmount() do
      {state, :ok} ->
        {:reply, :ok, %{state | ejected: put_ref(state.ejected, ref)}, {:continue, :converge}}

      {state, _error} ->
        Logger.warning(
          "Storage: eject refused, #{mount_point(state)} is busy; the drive stays mounted"
        )

        # No eject marker: the filesystem is still mounted, so the
        # convergence that follows must keep it mounted and restart the
        # share this stopped on the way in.
        {:reply, {:error, :busy}, state, {:continue, :converge}}
    end
  end

  # A plain `umount` and nothing else — the only outcome that means the
  # filesystem is flushed and released. State is untouched on failure: the
  # drive is still mounted, and it is the caller's job to say so.
  defp do_unmount(%{mounted: nil} = state), do: {state, {:error, :not_mounted}}

  defp do_unmount(state) do
    case umount(state, []) do
      :ok ->
        {unmounted(state), :ok}

      error ->
        Logger.warning("Storage: umount failed (#{inspect(error)})")
        {state, error}
    end
  end

  # Removal cleanup only (see the moduledoc): the drive is gone, so a lazy
  # detach is the right answer for a filesystem that is still busy, and a
  # mount that survives even that is marked stale for the next pass.
  defp force_unmount(state) do
    case do_unmount(state) do
      {state, :ok} ->
        {state, :ok}

      {state, _error} ->
        Logger.warning("Storage: the drive is gone; retrying lazily")

        case umount(state, lazy: true) do
          :ok ->
            Logger.info("Storage: the lazy umount detached the removed drive's mount")
            {unmounted(state), :ok}

          lazy_error ->
            Logger.error(
              "Storage: lazy umount failed too (#{inspect(lazy_error)}); marking the mount stale"
            )

            state = %{
              state
              | mounted: %{state.mounted | stale?: true},
                mounted_ref: nil,
                capacity: nil
            }

            {state, lazy_error}
        end
    end
  end

  defp unmounted(state), do: %{state | mounted: nil, mounted_ref: nil, capacity: nil}

  defp umount(state, extra) do
    safe(
      fn -> state.mount.umount(Keyword.merge(state.mount_opts, extra)) end,
      {:error, :umount_crashed},
      "Mount.umount"
    )
  end

  # -- The OS mount table --

  # Adopt whatever the kernel already has at the mount point, before the
  # first convergence: this process can be restarted while the mount
  # survives (see the moduledoc), and `mounted: nil` would then stack a
  # second mount on top of it. `mounted_ref` is deliberately left nil —
  # `Probe` has not run yet, so which drive this is cannot be known here.
  defp rehydrate_mount(state) do
    case os_mount(state) do
      nil ->
        state

      mount ->
        Logger.info(
          "Storage: adopting the existing mount of #{mount.device} at #{mount.point} " <>
            "(#{mount.fs_type}, #{mount.mode})"
        )

        %{state | mounted: mount}
    end
  end

  # An adopted mount has no drive identity until a pass with drives in
  # hand binds it — `refresh_drives/1` runs first, so this is that pass.
  # A device no attached drive owns is a drive that left while this
  # process was down: nothing to flush and nothing to unplug, which is
  # exactly `force_unmount/1`'s case. Stale mounts are skipped: their ref
  # is nil because a lazy umount detached them, not because they were
  # adopted, and re-unmounting one every pass would be a retry loop.
  defp bind_adopted_mount(%{mounted: %{stale?: false, device: device}, mounted_ref: nil} = state)
       when is_binary(device) do
    case Enum.find(state.drives, &owns_device?(&1, device)) do
      nil ->
        Logger.info("Storage: the mount of #{device} belongs to no attached drive; unmounting it")

        {state, _result} = state |> stop_share() |> force_unmount()
        state

      drive ->
        %{state | mounted_ref: drive_ref(drive)}
    end
  end

  defp bind_adopted_mount(state), do: state

  defp owns_device?(drive, device) do
    Map.get(drive, :dev_path) == device or
      drive
      |> Map.get(:partitions, [])
      |> List.wrap()
      |> Enum.any?(&(is_map(&1) and Map.get(&1, :dev_path) == device))
  end

  # The mount table's entry for this server's mount point, shaped as a
  # `mount_info()`, or nil when the kernel has nothing mounted there.
  defp os_mount(state) do
    with point when is_binary(point) and point != "" <- mount_point(state),
         {:ok, table} <- read_mounts(state) do
      mount_table_entry(table, point)
    else
      _other -> nil
    end
  end

  defp read_mounts(state) do
    safe(fn -> File.read(state.mounts_path) end, {:error, :mounts_unreadable}, "read mounts")
  end

  # `/proc/self/mounts` lines are
  # `<device> <point> <fs> <options> <freq> <passno>`, with space, tab,
  # newline and backslash octal-escaped in the first two fields. The
  # **last** entry for a point is the effective one: a stacked mount
  # shadows everything under it, and shadowed layers stay listed.
  defp mount_table_entry(table, point) do
    table
    |> String.split("\n", trim: true)
    |> Enum.reduce(nil, fn line, acc ->
      case String.split(line, " ") do
        [device, entry_point, fs, options | _rest] ->
          if unescape_mount_field(entry_point) == point do
            %{
              device: unescape_mount_field(device),
              fs_type: table_fs_type(fs),
              mode: table_mode(options),
              point: point,
              stale?: false
            }
          else
            acc
          end

        _other ->
          acc
      end
    end)
  end

  defp unescape_mount_field(field) do
    field
    |> String.replace("\\040", " ")
    |> String.replace("\\011", "\t")
    |> String.replace("\\012", "\n")
    |> String.replace("\\134", "\\")
  end

  # The table names the kernel driver, `Probe.fs_type/1` names the same
  # four by their superblock. Anything else at this mount point is a
  # filesystem this subsystem did not put there, and `:unknown` is what
  # keeps it from being treated as a backup volume.
  defp table_fs_type("ext4"), do: :ext4
  defp table_fs_type("exfat"), do: :exfat
  defp table_fs_type("ntfs3"), do: :ntfs3
  defp table_fs_type("vfat"), do: :vfat
  defp table_fs_type(_other), do: :unknown

  defp table_mode(options) do
    if "ro" in String.split(options, ","), do: :read_only, else: :read_write
  end

  # Which device `mkfs` is pointed at is decided here, from this server's
  # own state, so a caller can never name one. The live mount wins: making
  # a whole-disk filesystem while one of its partitions is mounted would
  # take the partition table (and the mount) with it. Failing that, the
  # first recognised data partition, and only a drive with neither gets the
  # whole disk — an unpartitioned superfloppy, or a stick whose partitions
  # are all unrecognised, both of which the user formats to make usable.
  # Only the active drive is ever mounted, so only its key is accepted.
  defp format_target(state, key) do
    with {:ok, drive} <- first_drive(state, key) do
      {:ok, format_device_path(state, drive)}
    end
  end

  # The one key check both destructive actions share. Position 0 is the
  # active drive — `active_drive_first/2` keeps the mounted drive there, so
  # a newly attached drive that merely sorts earlier can never claim it.
  defp first_drive(state, key) do
    case state.drives do
      [%{key: ^key} = drive | _rest] -> {:ok, drive}
      _other -> {:error, :unknown_drive}
    end
  end

  defp format_device_path(state, drive) do
    if is_map(state.mounted) and state.mounted_ref == drive_ref(drive) and
         is_binary(state.mounted.device) do
      state.mounted.device
    else
      case safe(
             fn -> state.probe.first_data_partition(drive) end,
             nil,
             "Probe.first_data_partition"
           ) do
        %{dev_path: dev_path} when is_binary(dev_path) -> dev_path
        _other -> drive.dev_path
      end
    end
  end

  defp format_device(state, device, label) do
    opts = Keyword.put(state.mount_opts, :confirm, true)

    case safe(
           fn -> state.mount.format_ext4(device, label, opts) end,
           {:error, :format_crashed},
           "Mount.format_ext4"
         ) do
      :ok ->
        Logger.info("Storage: formatted #{device} as ext4 (label #{label})")
        :ok

      error ->
        Logger.error("Storage: format of #{device} failed: #{inspect(error)}")
        error
    end
  end

  defp refresh_capacity(state) do
    if mounted?(state) do
      case safe(
             fn -> state.mount.capacity(state.mount_opts) end,
             {:error, :capacity_crashed},
             "Mount.capacity"
           ) do
        {:ok, capacity} ->
          %{state | capacity: capacity}

        error ->
          # Debug, not warning: on the host poll fallback this would
          # otherwise log every few seconds for an absent `df`.
          Logger.debug("Storage: capacity read failed: #{inspect(error)}")
          %{state | capacity: nil}
      end
    else
      %{state | capacity: nil}
    end
  end

  # -- Share folder --

  defp refresh_share_folder(state) do
    %{state | share_folder: stored_share_folder(state)}
  end

  defp stored_share_folder(%{mounted_ref: {_name, {slot_sub, _vid, _pid} = key}} = state)
       when is_binary(slot_sub) do
    case safe(fn -> Settings.get_drive(state.settings, key) end, nil, "Settings.get_drive") do
      %{share_folder: folder} when is_binary(folder) -> folder
      _other -> @root_folder
    end
  end

  # Nothing mounted, or a drive with no stable key to persist against:
  # the share can only ever be the drive root.
  defp stored_share_folder(_state), do: @root_folder

  # `{:ok, absolute, relative}` — the absolute form is what a caller chowns
  # or hands to `smb.conf`; the relative form is what gets persisted.
  defp resolve_share_folder(state, path) do
    with {:ok, absolute, relative} <- sandboxed_path(state, path) do
      if File.dir?(absolute) do
        {:ok, absolute, if(relative == "", do: @root_folder, else: relative)}
      else
        {:error, :enoent}
      end
    end
  end

  # The stored mapping is validated again on every share start, not just
  # when it is chosen. It is persisted while the drive it points into is
  # not: between two starts the directory can be deleted, or replaced by a
  # symlink pointing off the drive, by anyone who can plug the stick into
  # another machine. A mapping that no longer passes leaves the share off
  # and `:error` (the next convergence retries — the directory may come
  # back); it must never fall back to the drive root, which would export
  # more of the drive than was ever mapped.
  defp validated_share_folder(state) do
    case resolve_share_folder(state, state.share_folder) do
      {:ok, _absolute, folder} -> {:ok, folder}
      {:error, reason} -> {:error, {:invalid_share_folder, state.share_folder, reason}}
    end
  end

  # Only the mounted drive has a live share, and only its `smb.conf`
  # embeds the folder — stopping smbd here is what makes the convergence
  # that follows rebuild the config and start it against the new path.
  defp stop_share_for(%{share: :running} = state, key) do
    if mounted_key(state) == key do
      Logger.info("Storage: share folder changed; restarting smbd")
      stop_share(state)
    else
      state
    end
  end

  defp stop_share_for(state, _key), do: state

  defp mounted_key(%{mounted_ref: {_name, key}}), do: key
  defp mounted_key(_state), do: nil

  # -- Folder browsing --

  defp do_list_folders(state, rel_path) do
    with {:ok, absolute, _relative} <- sandboxed_path(state, rel_path),
         {:ok, entries} <- File.ls(absolute) do
      {:ok,
       entries
       |> Enum.reject(&String.starts_with?(&1, "."))
       |> Enum.filter(&real_dir?(absolute, &1))
       |> Enum.sort()}
    end
  end

  defp do_create_folder(state, rel_path, name) do
    with :ok <- validate_name(name),
         {:ok, _parent, relative} <- sandboxed_path(state, rel_path),
         # Re-sandboxed rather than joined onto the parent's absolute path:
         # the guard is cheap and the name is untrusted input.
         {:ok, absolute, created} <- sandboxed_path(state, join_relative(relative, name)),
         :ok <- File.mkdir(absolute) do
      take_ownership(state, absolute)
      {:ok, created}
    end
  end

  defp join_relative("", name), do: name
  defp join_relative(relative, name), do: relative <> "/" <> name

  defp validate_name(name) do
    cond do
      # Samba serves names as UTF-8 and the UI renders them: a name that
      # is not valid UTF-8 has no correct representation anywhere, and
      # checking it first keeps the rest of the rules on solid ground.
      not String.valid?(name) -> {:error, :invalid_name}
      String.trim(name) == "" -> {:error, :invalid_name}
      byte_size(name) > @max_name_bytes -> {:error, :name_too_long}
      name in [".", ".."] -> {:error, :invalid_name}
      String.contains?(name, @forbidden_name_chars) -> {:error, :invalid_name}
      # A newline would inject directives into `smb.conf` if the name ever
      # became the share folder (Smbd.config/1 strips them too — this is
      # the other half of that belt). Byte-wise, not by regex: a name that
      # is not valid UTF-8 must be rejected, never raise.
      control_bytes?(name) -> {:error, :invalid_name}
      true -> :ok
    end
  end

  defp control_bytes?(name) do
    name |> :binary.bin_to_list() |> Enum.any?(&(&1 < 32 or &1 == 127))
  end

  # ext4 carries real Unix ownership and `Mount.mount/3` chowns the mount
  # point to the backup account, but a directory created by this (root)
  # process is owned by root, so smbd's `force user` could not write into
  # it. exFAT/NTFS3/vfat synthesise ownership from the mount options and
  # need nothing. A failure leaves a directory the share cannot write to:
  # worth a warning, not worth failing the creation the user asked for.
  defp take_ownership(%{mounted: %{fs_type: :ext4, mode: :read_write}} = state, path) do
    case safe(
           fn -> state.mount.chown_backup(path, state.mount_opts) end,
           {:error, :chown_crashed},
           "Mount.chown_backup"
         ) do
      :ok ->
        :ok

      error ->
        Logger.warning(
          "Storage: chown of #{path} to the backup account failed (#{inspect(error)}); " <>
            "the share will not be able to write into it"
        )

        :ok
    end
  end

  defp take_ownership(_state, _path), do: :ok

  # -- Path sandbox --

  # Every path here comes from the UI and is untrusted. Two independent
  # guards, in this order, because neither is sufficient alone:
  #
  #   1. segment inspection **before** any expansion — `Path.expand/1`
  #      silently collapses `a/../..` into an ancestor, so by the time it
  #      has run the traversal intent is gone;
  #   2. expansion **then** a prefix check — the resolved path has to be
  #      the mount point itself or something below it, which catches
  #      whatever segment inspection did not (`.` runs, doubled slashes,
  #      an empty or relative mount point).
  #
  # Neither guard sees through a symlink, and the drive's contents are
  # attacker-controlled (anyone who can plug a stick in can put a link to
  # `/` on it), so every component is additionally required not to be one.
  # That is cheaper and tighter than a `realpath` resolution, and it is
  # what keeps the share from ever being mapped outside the drive —
  # `follow symlinks = no` in `Smbd.config/1` governs links *inside* the
  # share tree, not the share's own `path`.
  #
  # Returns `{:ok, absolute, relative}` — `relative` is the normalised
  # drive-relative form (`""` for the drive root).
  defp sandboxed_path(state, rel_path) do
    with {:ok, segments} <- path_segments(rel_path),
         {:ok, point} <- mounted_point(state) do
      root = Path.expand(point)
      absolute = Path.expand(Path.join([root | segments]))

      with true <- absolute == root or String.starts_with?(absolute, root <> "/"),
           :ok <- reject_symlinks(root, segments) do
        {:ok, absolute, Enum.join(segments, "/")}
      else
        _ -> {:error, :invalid_path}
      end
    end
  end

  defp path_segments(path) do
    trimmed = path |> String.trim() |> String.trim_trailing("/")

    cond do
      trimmed == "" ->
        {:ok, []}

      # `"/"` is the only absolute form allowed, and it normalised to `""`
      # above; anything else absolute is a caller reaching outside the drive.
      String.starts_with?(trimmed, "/") ->
        {:error, :invalid_path}

      true ->
        segments = String.split(trimmed, "/")

        if Enum.any?(segments, &(&1 == "" or &1 in [".", ".."])),
          do: {:error, :invalid_path},
          else: {:ok, segments}
    end
  end

  # A component that does not exist yet is fine — `File.ls/1` or
  # `File.mkdir/1` reports that, with the real posix reason.
  defp reject_symlinks(root, segments) do
    Enum.reduce_while(segments, {:ok, root}, fn segment, {:ok, parent} ->
      path = Path.join(parent, segment)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :symlink}} -> {:halt, {:error, :invalid_path}}
        _other -> {:cont, {:ok, path}}
      end
    end)
    |> case do
      {:ok, _path} -> :ok
      error -> error
    end
  end

  # `File.dir?/1` follows symlinks; the folder chooser must not offer a
  # link the sandbox would then refuse (nor leak the names behind one).
  defp real_dir?(parent, name) do
    case File.lstat(Path.join(parent, name)) do
      {:ok, %File.Stat{type: :directory}} -> true
      _other -> false
    end
  end

  defp mounted_point(state) do
    if mounted?(state) and is_binary(state.mounted.point) and state.mounted.point != "" do
      {:ok, state.mounted.point}
    else
      {:error, :not_mounted}
    end
  end

  # -- Share reconciliation --

  defp reconcile_share(state) do
    desired? = share_desired?(state)

    cond do
      desired? and state.share != :running ->
        start_share(state)

      # Called on every pass where the share is unwanted, not only on the
      # `:running -> :off` edge: `stop_share/1` is idempotent, and its
      # sweep is what makes "no share" mean "no smbd process" even if one
      # ever escaped this server's tracking.
      not desired? ->
        stop_share(state)

      true ->
        state
    end
  end

  defp share_desired?(state) do
    mounted?(state) and share_enabled?(state) and smbd_available?(state)
  end

  defp share_enabled?(%{mounted_ref: {_name, {slot_sub, _vid, _pid} = key}} = state)
       when is_binary(slot_sub) do
    safe(
      fn -> Settings.share_enabled?(state.settings, key) end,
      false,
      "Settings.share_enabled?"
    ) == true
  end

  # No stable key (no derivable USB bus path) means no opt-in can be
  # persisted for this drive, so the share stays off.
  defp share_enabled?(_state), do: false

  defp smbd_available?(state) do
    safe(fn -> state.smbd.available?(state.smbd_opts) end, false, "Smbd.available?") == true
  end

  defp start_share(state) do
    with {:ok, _folder} <- validated_share_folder(state),
         {:ok, credentials} <- credentials(state),
         :ok <- prepare_runtime(state, credentials),
         :ok <- provision_user(state, credentials),
         {:ok, pid} <- start_daemon(state) do
      Logger.info("Storage: smbd started for #{mount_point(state)}")
      # Monitored, not linked: the DynamicSupervisor is the child's parent,
      # and `restart: :temporary` means this server is the only thing that
      # will ever bring it back.
      %{state | share: :running, share_pid: pid, share_monitor: Process.monitor(pid)}
    else
      {:error, reason} ->
        Logger.error(
          "Storage: smbd share start failed: #{inspect(reason)}; " <>
            "retrying at the next convergence"
        )

        %{state | share: :error, share_pid: nil, share_monitor: nil}
    end
  end

  # Two steps, and the second is not redundant: the monitored child is
  # terminated by pid, then any child still under the daemon supervisor is
  # swept. Nothing else runs under that supervisor, so a survivor is an
  # `smbd` this server lost track of — and it would keep port 445 open and
  # the mount point busy, which is what breaks the next eject or format.
  defp stop_share(state) do
    state = demonitor_share(state)
    terminated? = terminate_share_child(state)
    swept = sweep_daemon_children(state)

    if terminated? or swept > 0, do: Logger.info("Storage: smbd stopped")

    %{state | share: :off, share_pid: nil, share_monitor: nil}
  end

  # `:flush` drops a `{:DOWN, …}` that is already in the mailbox: a
  # deliberate stop must not read back as a crash and trigger a restart.
  defp demonitor_share(%{share_monitor: nil} = state), do: state

  defp demonitor_share(state) do
    Process.demonitor(state.share_monitor, [:flush])
    %{state | share_monitor: nil}
  end

  defp terminate_share_child(%{share_pid: nil}), do: false

  defp terminate_share_child(state) do
    safe(
      fn -> DynamicSupervisor.terminate_child(state.daemon_supervisor, state.share_pid) end,
      :ok,
      "DynamicSupervisor.terminate_child"
    ) == :ok
  end

  defp sweep_daemon_children(state) do
    children =
      safe(
        fn -> DynamicSupervisor.which_children(state.daemon_supervisor) end,
        [],
        "DynamicSupervisor.which_children"
      )

    for {_id, pid, _type, _modules} <- List.wrap(children), is_pid(pid), reduce: 0 do
      swept ->
        Logger.warning(
          "Storage: terminating an smbd child this server did not track (#{inspect(pid)})"
        )

        _ =
          safe(
            fn -> DynamicSupervisor.terminate_child(state.daemon_supervisor, pid) end,
            :ok,
            "DynamicSupervisor.terminate_child"
          )

        swept + 1
    end
  end

  # The credentials record holds the SMB password: never log or inspect it.
  # A `{:error, :not_persisted}` reply (credentials that would not survive
  # a reboot) lands in the same branch as an unreachable store: the share
  # must not be provisioned with a password only this boot knows.
  defp credentials(state) do
    case safe(fn -> Settings.credentials(state.settings) end, nil, "Settings.credentials") do
      %{username: username, password: password}
      when is_binary(username) and is_binary(password) ->
        {:ok, %{username: username, password: password}}

      _other ->
        {:error, :credentials_unavailable}
    end
  end

  defp prepare_runtime(state, credentials) do
    params = %{
      mount_point: mount_point(state),
      share_folder: state.share_folder,
      username: credentials.username,
      netbios_name: netbios_name(state)
    }

    case safe(
           fn -> state.smbd.prepare_runtime(Keyword.put(state.smbd_opts, :params, params)) end,
           {:error, :prepare_runtime_crashed},
           "Smbd.prepare_runtime"
         ) do
      {:ok, _conf} -> :ok
      error -> {:error, {:prepare_runtime, error}}
    end
  end

  defp provision_user(state, credentials) do
    opts =
      state.smbd_opts
      |> Keyword.put(:username, credentials.username)
      |> Keyword.put(:get_hash_fun, fn -> provisioned_hash(state) end)
      |> Keyword.put(:put_hash_fun, fn hash -> put_provisioned_hash(state, hash) end)

    case safe(
           fn -> state.smbd.provision_user(credentials.password, opts) end,
           {:error, :provision_crashed},
           "Smbd.provision_user"
         ) do
      {:ok, _outcome} -> :ok
      error -> {:error, {:provision_user, error}}
    end
  end

  defp provisioned_hash(state) do
    case safe(fn -> Settings.credentials(state.settings) end, nil, "Settings.credentials") do
      %{provisioned_hash: hash} -> hash
      _other -> nil
    end
  end

  defp put_provisioned_hash(state, hash) do
    safe(
      fn -> Settings.put_provisioned_hash(state.settings, hash) end,
      {:error, :settings_unavailable},
      "Settings.put_provisioned_hash"
    )
  end

  defp start_daemon(state) do
    case safe(fn -> state.smbd.child_spec(state.smbd_opts) end, nil, "Smbd.child_spec") do
      nil ->
        {:error, :child_spec_unavailable}

      spec ->
        case safe(
               fn -> DynamicSupervisor.start_child(state.daemon_supervisor, spec) end,
               {:error, :start_child_crashed},
               "DynamicSupervisor.start_child"
             ) do
          {:ok, pid} -> {:ok, pid}
          {:ok, pid, _info} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          error -> {:error, {:start_child, error}}
        end
    end
  end

  # -- Timers --

  defp schedule_hotplug(%{hotplug_pending: true} = state), do: state

  defp schedule_hotplug(state) do
    Process.send_after(self(), :check_hotplug, state.debounce_ms)
    %{state | hotplug_pending: true}
  end

  # One armed retry at most, re-armed from scratch after every pass, and
  # only while something is actually outstanding.
  defp schedule_retry(state) do
    state = cancel_retry(state)

    if state.auto? and work_pending?(state) and is_integer(state.retry_interval) and
         state.retry_interval > 0 do
      %{state | retry_timer: Process.send_after(self(), :retry_converge, state.retry_interval)}
    else
      state
    end
  end

  defp cancel_retry(%{retry_timer: nil} = state), do: state

  defp cancel_retry(state) do
    _ = Process.cancel_timer(state.retry_timer)
    %{state | retry_timer: nil}
  end

  defp work_pending?(state) do
    (not mounted?(state) and target(state) != nil) or
      (share_desired?(state) and state.share != :running)
  end

  # Subscribe to kernel uevents (all `devices`; `handle_info` filters for
  # the `block` subsystem). Returns false when `nerves_uevent` isn't
  # running (host/dev) so the caller falls back to the poll timer. The
  # subscribe call is itself the readiness check — no whereis/subscribe
  # TOCTOU race: an unstarted PropertyTable raises `ArgumentError`, a
  # process that dies mid-call exits, and both mean "not available".
  defp subscribe_uevents do
    NervesUEvent.subscribe(["devices"])
    true
  rescue
    ArgumentError -> false
  catch
    :exit, _ -> false
  end

  # -- PubSub --

  defp payload(state) do
    %{
      drives: state.drives,
      mount: state.mounted,
      share: state.share,
      share_folder: state.share_folder,
      capacity: state.capacity
    }
  end

  defp broadcast(state) do
    safe(
      fn -> Phoenix.PubSub.broadcast(state.pubsub, @topic, {:storage_state, payload(state)}) end,
      :ok,
      "PubSub.broadcast"
    )
  end

  # -- Helpers --

  defp drive_ref(drive), do: {Map.get(drive, :name), Map.get(drive, :key) || drive_key(drive)}

  defp put_ref(set, nil), do: set
  defp put_ref(set, ref), do: MapSet.put(set, ref)

  defp drive_key(%{slot_sub: slot_sub, vendor_id: vendor_id, product_id: product_id})
       when is_binary(slot_sub) do
    {slot_sub, hex_id(vendor_id), hex_id(product_id)}
  end

  defp drive_key(_drive), do: nil

  defp hex_id(id) when is_integer(id) and id >= 0 do
    id |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0")
  end

  defp hex_id(_id), do: nil

  defp mount_point(state) do
    safe(fn -> state.mount.mount_point(state.mount_opts) end, nil, "Mount.mount_point")
  end

  defp netbios_name(state) do
    case safe(fn -> state.netbios_name_fun.() end, nil, "netbios_name_fun") do
      name when is_binary(name) -> shorten_netbios(String.trim(name))
      _other -> @netbios_fallback
    end
  end

  defp shorten_netbios(""), do: @netbios_fallback

  defp shorten_netbios(name) when byte_size(name) <= @netbios_max, do: name

  defp shorten_netbios(name) do
    # `universal-proxy-ab12cd` -> `up-ab12cd`: keep the device-unique
    # suffix, since a plain truncation reads identically on every device.
    case String.split(name, "-") do
      [_ | _] = segments ->
        suffix = List.last(segments)
        candidate = "up-" <> suffix

        if candidate != "up-" and byte_size(candidate) <= @netbios_max,
          do: candidate,
          else: binary_part(name, 0, @netbios_max)

      _ ->
        binary_part(name, 0, @netbios_max)
    end
  end

  defp default_netbios_name, do: DeviceInfo.node_name() || @netbios_fallback

  # Raw read of the first #{@head_bytes} bytes for the superblock sniff.
  # `:raw` keeps it off the file-server process, and a block device that
  # vanished mid-read must come back as an error, never an exception.
  defp default_read_head(device_path) do
    case File.open(device_path, [:read, :binary, :raw]) do
      {:ok, fd} ->
        try do
          case :file.read(fd, @head_bytes) do
            {:ok, bytes} -> {:ok, bytes}
            :eof -> {:ok, <<>>}
            {:error, reason} -> {:error, reason}
          end
        after
          File.close(fd)
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Single funnel for every seam call: a raising or exiting stub, an
  # absent optional module, or a wedged store degrades to `default`
  # instead of taking the subsystem down.
  defp safe(fun, default, label) do
    fun.()
  rescue
    e ->
      Logger.warning("Storage.Server: #{label} raised: #{Exception.message(e)}")
      default
  catch
    :exit, reason ->
      Logger.warning("Storage.Server: #{label} exited: #{inspect(reason)}")
      default
  end
end
