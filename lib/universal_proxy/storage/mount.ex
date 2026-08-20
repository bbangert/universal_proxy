defmodule UniversalProxy.Storage.Mount do
  @moduledoc """
  Mount, unmount, format, and measure the USB backup drive.

  Every external touchpoint — the four binaries, `df`, the mount point,
  and the post-mount chown — is injectable through options, so the whole
  module is exercised on the host against fake executables. Nothing here
  raises: a missing or failing command comes back as
  `{:error, {:command_failed, cmd, status, output}}`.

  ## Why the mount point is `/run/usb-backup`

  `UniversalProxy.System.factory_reset/1` `File.rm_rf`s every entry under
  `/data`. A drive mounted below `/data` would therefore have its entire
  contents deleted by a factory reset — `rm_rf` descends straight through
  a mount point. `/run` is a writable tmpfs on Nerves (the `Bluez`
  `/run/dbus` precedent) and starts empty every boot, which is exactly
  what a mount point wants.

  ## Why the filesystem type is always explicit

  The target busybox ships no `blkid`, so busybox `mount` has nothing to
  probe with and cannot guess a type. Every mount therefore passes
  `-t <fs>`, with the type coming from
  `UniversalProxy.Storage.Probe.fs_type/1`'s superblock sniff. Note the
  in-kernel NTFS driver registers itself as `ntfs3`, not `ntfs`.

  ## Why nothing shells out to `sync`

  Same busybox: there is no `sync` binary to call. There is no need for
  one either — `umount(2)` flushes the filesystem's dirty pages before it
  returns, so a successful `umount/1` is itself the safe-to-unplug
  signal.

  ## Why uid/gid 1000 are hard-coded

  The Buildroot users table provisions exactly one unprivileged `backup`
  user, at uid/gid 1000, and smbd serves the share as that account. The
  numbers are a fixed property of the image, not configuration. ext4
  carries real Unix ownership, so the mount point is chowned to 1000:1000
  after a successful read-write mount; exFAT, NTFS3, and vfat have no
  ownership metadata at all, so ownership is synthesised at mount time
  with `uid=`/`gid=`/`umask=` options instead.

  ## Options

  All functions accept these, defaulting to the on-target paths:

    * `:mount_bin` — `"/bin/mount"`
    * `:umount_bin` — `"/bin/umount"`
    * `:fsck_bin` — `"/sbin/fsck.ext4"`
    * `:mkfs_bin` — `"/sbin/mkfs.ext4"`
    * `:df_bin` — `"/bin/df"`
    * `:mount_point` — `"/run/usb-backup"`
    * `:chown_fun` — 3-arity `(path, uid, gid -> :ok | {:error, term()})`
      test seam, defaults to `File.chown/2` followed by `File.chgrp/2`
  """

  require Logger

  @default_bins [
    mount_bin: "/bin/mount",
    umount_bin: "/bin/umount",
    fsck_bin: "/sbin/fsck.ext4",
    mkfs_bin: "/sbin/mkfs.ext4",
    df_bin: "/bin/df"
  ]

  @default_mount_point "/run/usb-backup"

  @backup_uid 1000
  @backup_gid 1000

  # A backup volume holds data only: no device nodes, no setuid bits, no
  # executables. `noatime` additionally keeps reads from waking a
  # spun-down disk.
  @rw_options "rw,noatime,nodev,nosuid,noexec"
  @ro_options "ro,noatime,nodev,nosuid,noexec"

  # Ownership for the filesystems that have none of their own.
  @foreign_owner_options "uid=#{@backup_uid},gid=#{@backup_gid},umask=0077"

  @supported_fs [:ext4, :exfat, :ntfs3, :vfat]

  @type fs_type :: :ext4 | :exfat | :ntfs3 | :vfat
  @type mode :: :read_write | :read_only

  @typedoc """
  A non-zero exit status, or the `errno` atom (`:enoent`, `:eacces`, …)
  when the binary could not be executed at all.
  """
  @type exit_status :: non_neg_integer() | atom()

  @type command_error :: {:error, {:command_failed, String.t(), exit_status(), String.t()}}

  @type capacity :: %{
          total_bytes: non_neg_integer(),
          used_bytes: non_neg_integer(),
          free_bytes: non_neg_integer(),
          used_pct: non_neg_integer()
        }

  @doc """
  The mount point these functions operate on.
  """
  @spec mount_point(keyword()) :: String.t()
  def mount_point(opts \\ []), do: Keyword.get(opts, :mount_point, @default_mount_point)

  @doc """
  Mount `device` at the mount point as `fs_type`.

  ext4 volumes are checked with `fsck.ext4 -p` first; exit status 1 means
  "errors found and fixed", which is a successful repair, so only status
  2 and above abort the mount.

  Returns `{:ok, :read_write}`, or `{:ok, :read_only}` when only the
  read-only retry succeeded (a dirty NTFS volume or a write-protected
  stick). A failed chown is logged and does not fail the mount: the data
  is readable either way, only the share would be unwritable.
  """
  @spec mount(String.t(), fs_type(), keyword()) ::
          {:ok, mode()} | command_error() | {:error, term()}
  def mount(device, fs_type, opts \\ [])

  def mount(device, fs_type, opts) when fs_type in @supported_fs do
    point = mount_point(opts)

    with :ok <- ensure_mount_point(point),
         :ok <- fsck(device, fs_type, opts),
         {:ok, mode} <- mount_rw_or_ro(device, fs_type, point, opts) do
      take_ownership(fs_type, mode, point, opts)
      {:ok, mode}
    end
  end

  def mount(_device, fs_type, _opts), do: {:error, {:unsupported_fs_type, fs_type}}

  @doc """
  Unmount the mount point.

  Pass `lazy: true` to add `-l`, which detaches a busy mount and lets the
  kernel finish once the last reference goes away.
  """
  @spec umount(keyword()) :: :ok | command_error()
  def umount(opts \\ []) do
    args =
      if Keyword.get(opts, :lazy, false), do: ["-l", mount_point(opts)], else: [mount_point(opts)]

    run(bin(opts, :umount_bin), args)
  end

  @doc """
  Make a fresh ext4 filesystem on `device`, labelled `label`.

  Destroys everything on the device, so it refuses with
  `{:error, :not_confirmed}` unless the caller passes `confirm: true` —
  an accidental call cannot wipe a drive.

  `-m 1` keeps only 1% reserved for root (this volume is bulk storage,
  not a rootfs) and `lazy_itable_init=0` writes the inode tables up front
  so the drive is not still being initialised in the background when the
  user unplugs it.
  """
  @spec format_ext4(String.t(), String.t(), keyword()) ::
          :ok | {:error, :not_confirmed} | command_error()
  def format_ext4(device, label, opts \\ []) do
    if Keyword.get(opts, :confirm, false) == true do
      # The drive is normally mounted at this point. A failure here is the
      # expected "not mounted" case, so it is deliberately ignored; mkfs
      # itself refuses a mounted device, which is the real guard.
      _ = umount(opts)

      run(bin(opts, :mkfs_bin), [
        "-F",
        "-L",
        label,
        "-m",
        "1",
        "-E",
        "lazy_itable_init=0",
        device
      ])
    else
      {:error, :not_confirmed}
    end
  end

  @doc """
  Give the backup account (uid/gid #{@backup_uid}) ownership of `path`.

  The same chown `mount/3` applies to the mount point after a read-write
  ext4 mount, exposed for directories created **inside** an already-mounted
  ext4 volume: ext4 carries real Unix ownership, so a directory created by
  the (root) firmware process is not writable by the account smbd forces
  the share to. Meaningless on exFAT/NTFS3/vfat, whose ownership is
  synthesised from the mount options — callers gate on the filesystem.

  Honours the `:chown_fun` seam.
  """
  @spec chown_backup(String.t(), keyword()) :: :ok | {:error, term()}
  def chown_backup(path, opts \\ []), do: chown(path, opts)

  @doc """
  Byte-exact usage of the mounted filesystem, via `df -B1`.
  """
  @spec capacity(keyword()) :: {:ok, capacity()} | command_error() | {:error, term()}
  def capacity(opts \\ []) do
    df = bin(opts, :df_bin)
    args = ["-B1", mount_point(opts)]

    case cmd(df, args) do
      {:ok, 0, out} -> parse_df(out)
      {:ok, status, out} -> failure(df, args, status, out)
      {:error, _reason} = error -> error
    end
  end

  # -- Mount steps --

  defp ensure_mount_point(point) do
    case File.mkdir_p(point) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mount_point_unavailable, point, reason}}
    end
  end

  defp fsck(device, :ext4, opts) do
    fsck = bin(opts, :fsck_bin)
    args = ["-p", device]

    case cmd(fsck, args) do
      # 0 = clean, 1 = errors found and corrected. From 2 up, fsck could
      # not repair the volume unattended, so mounting it risks the data.
      {:ok, status, _out} when status in [0, 1] -> :ok
      {:ok, status, out} -> failure(fsck, args, status, out)
      {:error, _reason} = error -> error
    end
  end

  defp fsck(_device, _fs_type, _opts), do: :ok

  defp mount_rw_or_ro(device, fs_type, point, opts) do
    case do_mount(device, fs_type, point, @rw_options, opts) do
      :ok ->
        {:ok, :read_write}

      {:error, _reason} = rw_error ->
        case do_mount(device, fs_type, point, @ro_options, opts) do
          # The read-write attempt's error is the informative one (wrong
          # type, no such device); the retry's is a near-copy of it.
          :ok -> {:ok, :read_only}
          {:error, _reason} -> rw_error
        end
    end
  end

  defp do_mount(device, fs_type, point, base_options, opts) do
    mount = bin(opts, :mount_bin)

    run(mount, ["-t", fs_name(fs_type), "-o", options(fs_type, base_options), device, point])
  end

  defp fs_name(:ext4), do: "ext4"
  defp fs_name(:exfat), do: "exfat"
  defp fs_name(:ntfs3), do: "ntfs3"
  defp fs_name(:vfat), do: "vfat"

  defp options(:ext4, base), do: base
  defp options(_no_unix_ownership, base), do: base <> "," <> @foreign_owner_options

  # The chown lands on the mounted filesystem's root inode, so it has to
  # happen after the mount, not on the empty directory underneath. A
  # read-only mount cannot be chowned and does not need to be.
  defp take_ownership(:ext4, :read_write, point, opts) do
    case chown(point, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Storage.Mount: chown #{point} to #{@backup_uid}:#{@backup_gid} failed " <>
            "(#{inspect(reason)}); the share will be read-only for the backup user"
        )

        :ok
    end
  end

  defp take_ownership(_fs_type, _mode, _point, _opts), do: :ok

  defp chown(point, opts) do
    fun = Keyword.get(opts, :chown_fun, &default_chown/3)
    fun.(point, @backup_uid, @backup_gid)
  end

  # There is no `File.chown/3`: owner and group are two calls.
  defp default_chown(point, uid, gid) do
    with :ok <- File.chown(point, uid), do: File.chgrp(point, gid)
  end

  # -- df parsing --

  # `UniversalProxy.System.parse_df_output/1` reads the same second line
  # of the same `df -B1` output, but returns a display string
  # ("8.2 MB / 116 GB") and discards the free and percentage columns, so
  # the numeric shape is parsed here instead.
  defp parse_df(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.at(1, "")
    |> String.split(~r/\s+/, trim: true)
    |> case do
      [_fs, total, used, avail, pct | _mount] -> build_capacity(out, total, used, avail, pct)
      _ -> {:error, {:unexpected_df_output, out}}
    end
  end

  defp build_capacity(out, total, used, avail, pct) do
    with {total_bytes, ""} <- Integer.parse(total),
         {used_bytes, ""} <- Integer.parse(used),
         {free_bytes, ""} <- Integer.parse(avail) do
      {:ok,
       %{
         total_bytes: total_bytes,
         used_bytes: used_bytes,
         free_bytes: free_bytes,
         used_pct: used_pct(pct, total_bytes, used_bytes)
       }}
    else
      _ -> {:error, {:unexpected_df_output, out}}
    end
  end

  # df computes Use% against used + available, excluding the reserved
  # blocks, so it is not used/total. Report what df reports, and only
  # compute a substitute when the column is unreadable.
  defp used_pct(pct, total_bytes, used_bytes) do
    case Integer.parse(String.trim_trailing(pct, "%")) do
      {parsed, _rest} -> parsed
      :error when total_bytes > 0 -> round(used_bytes / total_bytes * 100)
      :error -> 0
    end
  end

  # -- Command plumbing --

  defp bin(opts, key), do: Keyword.get(opts, key, Keyword.fetch!(@default_bins, key))

  defp run(executable, args) do
    case cmd(executable, args) do
      {:ok, 0, _out} -> :ok
      {:ok, status, out} -> failure(executable, args, status, out)
      {:error, _reason} = error -> error
    end
  end

  # Arguments always travel as argv elements — never a shell string — so
  # a volume label or device name can hold spaces or shell metacharacters
  # without being interpreted.
  defp cmd(executable, args) do
    {out, status} = System.cmd(executable, args, stderr_to_stdout: true)
    {:ok, status, out}
  rescue
    e in [ErlangError, ArgumentError] ->
      failure(executable, args, errno(e), Exception.message(e))
  end

  defp errno(%ErlangError{original: reason}) when is_atom(reason), do: reason
  defp errno(_exception), do: :error

  defp failure(executable, args, status, out) do
    {:error, {:command_failed, Enum.join([executable | args], " "), status, String.trim(out)}}
  end
end
