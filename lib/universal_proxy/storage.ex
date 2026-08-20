defmodule UniversalProxy.Storage do
  @moduledoc """
  Public API boundary for the USB backup drive subsystem: detection,
  mount, capacity, and the opt-in `smbd` Samba share. **LiveView and espex
  must call only this module** — never `Storage.Server`, `Storage.Settings`,
  or `Storage.Smbd` directly.

  ## Architecture

      Storage                 # this module — public boundary
      Storage.Supervisor      # :one_for_all (DaemonSupervisor + Server)
        Storage.Server        # orchestrator: hotplug, mount, share convergence
        Storage.DaemonSupervisor  # DynamicSupervisor, holds the smbd child
      Storage.Settings        # DETS: per-drive opt-in + Samba credentials
                               # (top-level in application.ex, outside the
                               # :one_for_all subtree — see its @moduledoc)
      Storage.{Probe,Mount,Smbd}  # pure/seamed side-effecting helpers,
                                  # called only from Storage.Server

  ## The `catch :exit` idiom (CLAUDE.md)

  Every function here that reaches a GenServer — `Storage.Server` or
  `Storage.Settings` — wraps that call in `catch :exit, _ -> <default>`,
  per the project's public-API idiom for optional subsystems. **Read this
  carefully before trusting a default return**: the catch collapses TWO
  different situations into the same value —

    * the subsystem genuinely isn't running (crashed and not yet
      restarted, or torn down for a test), and
    * the subsystem IS running but wedged (a `GenServer.call` timeout).

  A caller cannot tell which happened from the return value alone. This
  is a deliberate tradeoff (benign UI degradation over crash cascades),
  accepted for this subsystem the same way it was accepted for FMA120 in
  the 2026-07 OTP audit (F8). The one exception is `format_drive/2`,
  which follows `FMA120.call_worker/2`'s pattern and catches
  `:exit, {:timeout, _}` **separately** from other exits — a wedged
  `mkfs.ext4` (which can legitimately run for minutes) must stay
  distinguishable from an absent subsystem, because a caller who sees
  `:timeout` should not assume the device is now in some other state.
  """

  alias UniversalProxy.Storage.{Server, Settings, Smbd}

  @typedoc """
  A drive's identity as `{slot_sub, vendor_id, product_id, serial}` — port,
  USB model ids, and the
  USB serial that makes it name one physical medium rather than every
  stick of that model (see `Storage.Server`'s moduledoc, which also
  documents what a serial-less stick loses). `nil` for a drive with no
  derivable bus path.
  """
  @type drive_key :: Server.drive_key()
  @type state :: Server.payload()

  @default_state %{drives: [], mount: nil, share: :off, share_folder: "/", capacity: nil}

  # -- Read state --

  @doc """
  The full subsystem state: drives, the current mount (if any), the
  share status, and capacity. The same payload broadcast on `topic/0`.

  Defaults to `#{inspect(@default_state)}` while the subsystem is down or
  wedged (see the moduledoc's `catch :exit` note).
  """
  @spec state() :: state()
  def state do
    Server.get_state()
  catch
    :exit, _ -> @default_state
  end

  @doc """
  The attached drives (annotated with filesystem sniff + derived key).
  `[]` while the subsystem is down/wedged or nothing is attached — the
  two are indistinguishable here by design (see `state/0`).
  """
  @spec list_drives() :: [map()]
  def list_drives, do: state().drives

  @doc """
  Whether this target can run the Samba share at all — i.e. an `smbd`
  binary is present in the rootfs. A plain `File.exists?/1` check, never
  a GenServer call, so there is nothing to `catch`: it cannot hang or
  exit, and returns `false` identically whether the target simply lacks
  the package or the subsystem hasn't started yet.
  """
  @spec supported?() :: boolean()
  def supported?, do: Smbd.available?()

  @doc """
  The generated Samba username/password, generating the password lazily
  on first read (see `Storage.Settings`). Never log or inspect the
  result: the password lives inside it.

  Returns `nil` while `Storage.Settings` is down or wedged, and also when
  a first-read generation could not be persisted (`Settings` answers
  `{:error, :not_persisted}`): a password that is not durable would stop
  matching the smbd account after the next reboot, so it is reported as
  "no credentials" rather than handed out. **`nil` is therefore not "no
  password has been generated yet"** — generation is lazy and happens on
  this very call; `nil` means the credentials could not be established.
  """
  @spec share_credentials() :: Settings.credentials() | nil
  def share_credentials do
    case Settings.credentials() do
      %{} = credentials -> credentials
      _not_persisted -> nil
    end
  catch
    :exit, _ -> nil
  end

  @doc "The PubSub topic the state map (`state/0`'s shape) is broadcast on."
  @spec topic() :: String.t()
  def topic, do: Server.topic()

  # -- Mutations --

  @doc """
  Opt a drive's Samba share in or out. Persists the setting and pokes a
  convergence pass (which starts or stops `smbd`); convergence itself is
  asynchronous and reports through `topic/0`.

  Returns `{:error, :unavailable}` while `Storage.Server` is down or
  wedged.
  """
  @spec set_share_enabled(drive_key(), boolean()) :: :ok | {:error, term()}
  def set_share_enabled(key, enabled?) when is_boolean(enabled?) do
    Server.set_share_enabled(key, enabled?)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc """
  Map the drive's SMB share at `path` — `"/"` for the drive root,
  otherwise a drive-relative path of plain segments (`"backups/ha"`) that
  already exists on the drive. Persists the setting and restarts a
  running share so the new path takes effect.

  Returns `{:error, :invalid_path}` for anything that would escape the
  drive, `{:error, :enoent}` when the directory does not exist,
  `{:error, :not_mounted}` when no drive is mounted, and
  `{:error, :unavailable}` while `Storage.Server` is down or wedged.
  """
  @spec set_share_folder(drive_key(), String.t()) :: :ok | {:error, term()}
  def set_share_folder(key, path) when is_binary(path) do
    Server.set_share_folder(key, path)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc """
  The subdirectories of `rel_path` on the mounted drive (`"/"` is the
  drive root), sorted, dot-prefixed directories omitted — the read behind
  the folder chooser.

  Returns `{:error, :not_mounted}` when nothing is mounted,
  `{:error, :invalid_path}` for a path that would escape the drive, and
  `{:error, :unavailable}` while `Storage.Server` is down or wedged.
  """
  @spec list_folders(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_folders(rel_path) when is_binary(rel_path) do
    Server.list_folders(rel_path)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc """
  Create directory `name` inside `rel_path` on the mounted drive and
  return its drive-relative path, ready to pass to
  `set_share_folder/2` — the folder chooser's "New folder" action.

  Returns `{:error, :invalid_name}` / `{:error, :name_too_long}` for a
  name the design's rule rejects, `{:error, :eexist}` for a duplicate,
  the same path errors as `list_folders/1`, and
  `{:error, :unavailable}` while `Storage.Server` is down or wedged.
  """
  @spec create_folder(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def create_folder(rel_path, name) when is_binary(rel_path) and is_binary(name) do
    Server.create_folder(rel_path, name)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc """
  Replace the stored Samba password with a fresh random value. Clearing
  the old `provisioned_hash` is what forces `Storage.Smbd` to reprovision
  the smbd account, so this also pokes a synchronous convergence pass on
  `Storage.Server` to re-run `provision_user` against the now-running
  daemon — otherwise the new password would sit in `Storage.Settings`
  unapplied until the next unrelated convergence (mount/unmount, hotplug).

  Because convergence is a no-op while the share is already `:running`,
  the poke is `Storage.Server.credentials_rotated/1` rather than a plain
  `check_now/1`: it stops the running daemon first, so the pass that
  follows reprovisions the account and starts it again with the new
  password. Without that a running share would keep serving the old
  credential until some unrelated event (mount, unmount, hotplug) restarted
  it.

  The poke is best-effort: if `Storage.Server` is down, the rotation
  itself (already durably persisted in `Storage.Settings`) still succeeds
  and is returned, and the next share start — whenever the subsystem comes
  back — provisions from the stored value. A rotation that could not be
  persisted returns `{:error, :not_persisted}` (and is not applied to the
  daemon, which would otherwise be given a password no reboot survives),
  and a `Storage.Settings` that cannot be reached at all degrades the
  whole call to `{:error, :unavailable}`.
  """
  @spec rotate_password() ::
          Settings.credentials() | {:error, :not_persisted} | {:error, :unavailable}
  def rotate_password do
    case Settings.rotate_password() do
      %{} = credentials ->
        poke_rotation()
        credentials

      {:error, _reason} = error ->
        error
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc """
  Stop the share and unmount the drive `drive_key` identifies, keeping it
  unmounted until it is physically removed (or formatted).

  Callers name the **drive**, exactly as in `format_drive/2`: only one
  drive is ever mounted, and `Storage.Server` accepts only that drive's
  key, so an eject crafted against a second drive (or against a stale
  view of which drive is first) is refused with
  `{:error, :unknown_drive}` rather than ejecting whatever happens to be
  mounted. `nil` is the key of a drive with no derivable bus path.

  Returns `{:error, :unavailable}` while `Storage.Server` is down or
  wedged, `{:error, :not_mounted}` when that drive has no mount, and
  `{:error, :busy}` when the filesystem will not unmount — in which case
  the drive is still mounted and must not be unplugged.
  """
  @spec eject(drive_key() | nil) :: :ok | {:error, term()}
  def eject(drive_key)
      when is_nil(drive_key) or (is_tuple(drive_key) and tuple_size(drive_key) == 4) do
    Server.eject(drive_key)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc """
  Make a fresh ext4 filesystem on the drive `drive_key` identifies
  (destroying everything on it), labelled `label` (default
  `#{inspect("USB_BACKUP")}`). Stops the share and unmounts first;
  refuses if the unmount fails.

  Callers name the **drive**, never a device path: `Storage.Server`
  resolves which device `mkfs` is pointed at from its own state (the live
  mount, else the drive's first data partition, else the whole disk), and
  answers `{:error, :unknown_drive}` for a key that is not the attached
  drive's. `nil` is the key of a drive with no derivable bus path.

  `Storage.Server` blocks its whole loop for the duration — `mkfs.ext4`
  on a large slow stick can take minutes — so this follows
  `FMA120.call_worker/2`'s pattern and catches the call-timeout exit
  **separately** from every other exit: `{:error, :timeout}` means the
  format may still be running (the server is wedged, not necessarily
  failed), while `{:error, :unavailable}` means the subsystem was not
  reachable at all. Conflating the two would make a caller believe a
  still-running format had failed.
  """
  @spec format_drive(drive_key() | nil, String.t()) :: :ok | {:error, term()}
  def format_drive(drive_key, label \\ "USB_BACKUP")
      when is_binary(label) and
             (is_nil(drive_key) or (is_tuple(drive_key) and tuple_size(drive_key) == 4)) do
    call_server(fn -> Server.format(drive_key, label) end)
  end

  # -- Private --

  # Best-effort: a failure here must not turn an already-successful
  # password rotation into an error return (see `rotate_password/0`).
  defp poke_rotation do
    Server.credentials_rotated()
  catch
    :exit, _ -> :ok
  end

  # Public (`@doc false`) so the timeout/unavailable split is directly
  # unit-testable, mirroring `UniversalProxy.FMA120.call_worker/2`: a
  # call-shaped timeout exit means the server may still be working (a
  # large `mkfs.ext4` legitimately runs for minutes), while any other
  # call-shaped exit means it wasn't reachable at all.
  @doc false
  def call_server(fun) do
    fun.()
  catch
    :exit, {:timeout, {GenServer, :call, _}} -> {:error, :timeout}
    :exit, {_reason, {GenServer, :call, _}} -> {:error, :unavailable}
  end
end
