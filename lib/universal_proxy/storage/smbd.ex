defmodule UniversalProxy.Storage.Smbd do
  @moduledoc """
  Generates the hardened `smb.conf`, provisions the SMB account, and
  supervises `smbd` for the opt-in USB backup share.

  Five parts, all seamed for host tests:

    * `share_name/1` (and `share_suffix/1`) — pure: the per-drive share
      name (`usb_backup_<suffix>`), so a share is named for the medium it
      serves rather than one global name every stick collides on. See
      `share_suffix/1` for the derivation.
    * `config/1` — pure: the complete `smb.conf` text for one share
      (`[usb_backup]` by default, or the `:share_name` a caller passes
      in).
    * `prepare_runtime/1` — creates the writable dirs and writes the
      config (the rootfs and `/etc/samba` are read-only squashfs, so
      everything lives under `/data/samba` + `/run/samba`).
    * `provision_user/2` — `smbpasswd -s -a <user>` with the password fed
      on **stdin only**, idempotent via a stored SHA-256.
    * `child_spec/1` — a `restart: :temporary` `MuonTrap.Daemon`
      spec for `smbd -F` (`Storage.Server` owns the restart decision).

  ## State layout

  `smbd` needs writable state that the squashfs rootfs cannot provide:

    * `/data/samba` (persistent) — `smb.conf`, `private/passdb.tdb` (the
      account database, mode 0700), `state/`, `cache/`.
    * `/run/samba` (volatile) — lock dir, pid dir, `ncalrpc/`.

  Both roots are overridable (`:data_dir` / `:run_dir`) so tests can point
  them at a tmp dir; `config/1` derives every in-file path from the same
  two values, keeping the generated config and `prepare_runtime/1`
  symmetric.

  ## Password handling

  The SMB password is never passed in `argv` (visible to any process via
  `/proc/<pid>/cmdline`), never logged, and never embedded in a returned
  error term: `smbpasswd` output is scrubbed of the password before it
  reaches an error tuple. By default, provisioning is skipped when
  `SHA-256(username <> ":" <> password)` matches the hash recorded after
  the last successful run — but that hash cannot be trusted across a hard
  reboot: `passdb.tdb` lives on the same storage a firmware flash or power
  loss can tear mid-write, which can lose or corrupt the account while the
  recorded hash survives untouched. `UniversalProxy.Storage.Server` forces
  provisioning (`force: true`) at every share start rather than trusting
  the hash, because `smbpasswd -a` on an already-correct account is
  idempotent and sub-second — cheap enough to always pay. The hash is
  still written after every successful run regardless of `:force`; it
  now serves only as a rotation marker and diagnostic, not a gate on
  whether `smbpasswd` runs for a caller that forces.
  """

  require Logger

  alias UniversalProxy.Storage.Settings

  @default_data_dir "/data/samba"
  @default_run_dir "/run/samba"
  @default_username "backup"
  @share_name "usb_backup"
  @default_share_folder "/"

  # First existing candidate wins (Bluez.bluealsad_path/1 pattern). Samba4
  # installs smbd in sbin and smbpasswd in bin; /usr/local/* covers hosts
  # that build it themselves.
  @smbd_candidates ["/usr/sbin/smbd", "/usr/local/sbin/smbd"]
  @smbpasswd_candidates ["/usr/bin/smbpasswd", "/usr/local/bin/smbpasswd"]

  @provision_timeout 15_000

  # A noisy or wedged `smbpasswd` must not accumulate output for the whole
  # `:timeout` budget — that is unbounded memory on-device. Only the last
  # `@collected_output_max` bytes can ever matter anyway: `redact/2` slices
  # the eventual error to 500 chars.
  @collected_output_max 1_000

  @type config_params :: %{
          required(:mount_point) => String.t(),
          required(:username) => String.t(),
          required(:netbios_name) => String.t(),
          optional(:share_folder) => String.t(),
          optional(:share_name) => String.t(),
          optional(:data_dir) => String.t(),
          optional(:run_dir) => String.t()
        }

  # The share-suffix regex the design settles on: a conservative,
  # SMB-safe charset (no `-`, `_`, or anything Windows/legacy SMB clients
  # could mishandle in a share name), 2-16 characters so a bare vid+pid
  # fallback (8 chars) and a truncated serial both fit comfortably.
  @suffix_re ~r/^[a-z0-9]{2,16}$/
  @suffix_min 2
  @suffix_max 6

  # -- (0) Share naming --

  @doc """
  The per-drive share name: `#{@share_name}_<suffix>` (see
  `share_suffix/1`).

  Stable for one physical medium across replugs and ports (same inputs,
  same output), and always matches `#{inspect(@suffix_re)}` after the
  `#{@share_name}_` prefix — safe to drop straight into `config/1`'s
  `:share_name`.

  ## Examples

      iex> Smbd.share_name(%{serial: "1C6F654CED3DED51E92C01E4", vendor_id: 0x0BDA, product_id: 0x0316})
      "usb_backup_2c01e4"

      iex> Smbd.share_name(%{serial: nil, vendor_id: 0x0930, product_id: 0x6545})
      "usb_backup_09306545"
  """
  @spec share_name(map()) :: String.t()
  def share_name(drive), do: @share_name <> "_" <> share_suffix(drive)

  @doc """
  The SMB-safe per-drive suffix `share_name/1` appends, mirroring
  `Storage.Server`'s drive-key stability semantics (the same USB serial —
  or, absent one, the same vendor/product id pair — that makes a drive
  key name one physical medium rather than every stick of that model).

  With a `:serial` (a `Storage.Probe`-shaped drive map's raw string):
  the last #{@suffix_max} characters, lowercased, then sanitized to
  `[a-z0-9]` by dropping every other character. If that leaves fewer than
  #{@suffix_min} characters (a serial that is all punctuation, or empty),
  or there is no serial at all, this falls back to the drive's
  `:vendor_id`/`:product_id` (integers, as `Storage.Probe` reports them):
  lowercase 4-digit hex, concatenated — always 8 characters, so it can
  never itself be too short.

  Always matches `#{inspect(@suffix_re)}`.

  ## Examples

      iex> Smbd.share_suffix(%{serial: "1C6F654CED3DED51E92C01E4", vendor_id: 0x0BDA, product_id: 0x0316})
      "2c01e4"

      iex> Smbd.share_suffix(%{serial: "SN-A", vendor_id: 0x0781, product_id: 0x55AF})
      "sna"

      iex> Smbd.share_suffix(%{serial: "!!!!!!", vendor_id: 0x0930, product_id: 0x6545})
      "09306545"

      iex> Smbd.share_suffix(%{serial: nil, vendor_id: 0x0930, product_id: 0x6545})
      "09306545"
  """
  @spec share_suffix(map()) :: String.t()
  def share_suffix(%{serial: serial} = drive) when is_binary(serial) do
    serial_suffix(serial) || vidpid_suffix(drive)
  end

  def share_suffix(drive), do: vidpid_suffix(drive)

  # `nil` (not `""`) when sanitizing leaves too little to be a stable,
  # readable suffix on its own — the caller falls back to vid+pid, which
  # is always #{@suffix_max + 2} characters and therefore always long
  # enough.
  defp serial_suffix(serial) do
    suffix =
      serial
      |> String.trim()
      |> last_chars(@suffix_max)
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]/, "")

    if String.length(suffix) >= @suffix_min, do: suffix
  end

  defp last_chars(string, n) do
    length = String.length(string)
    if length <= n, do: string, else: String.slice(string, length - n, n)
  end

  defp vidpid_suffix(drive) do
    hex_id(Map.get(drive, :vendor_id)) <> hex_id(Map.get(drive, :product_id))
  end

  defp hex_id(id) when is_integer(id) and id >= 0 do
    id |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0")
  end

  defp hex_id(_id), do: "0000"

  # -- (a) Pure config generation --

  @doc """
  Build the complete hardened `smb.conf` for the USB backup share.

  Required keys: `:mount_point` (where the drive is mounted), `:username`
  (the Unix and SMB account), `:netbios_name` (server identity shown to
  clients). Optional `:share_folder` (default `"/"`) maps the share at a
  subdirectory of the drive rather than its root, so the share's `path`
  becomes `<mount_point>/<share_folder>`; `:share_name` (default
  `#{@share_name}`, kept for callers that predate per-drive naming —
  `UniversalProxy.Storage.Server` always derives and passes one via
  `share_name/1`) names the `[…]` section itself, so a share is per-drive
  rather than one global name every stick collides on; `:data_dir`
  (default `#{@default_data_dir}`) and `:run_dir` (default
  `#{@default_run_dir}`) relocate Samba's state.

  The folder is joined, not validated: `UniversalProxy.Storage.Server`
  owns validating that it is a sandboxed, existing directory before it
  ever reaches here.

  Hardening in force: SMB2.1 floor (no SMB1), mandatory signing,
  encryption offered, anonymous/guest access refused outright, printing
  and usershares off, symlink following off, share files owner+group only.
  """
  @spec config(config_params()) :: String.t()
  def config(%{mount_point: mount_point, username: username, netbios_name: netbios_name} = params) do
    data_dir = Map.get(params, :data_dir, @default_data_dir)
    run_dir = Map.get(params, :run_dir, @default_run_dir)

    username = sanitize(username)
    share_path = share_path(mount_point, Map.get(params, :share_folder, @default_share_folder))
    share_name = params |> Map.get(:share_name, @share_name) |> sanitize()

    """
    # Generated by UniversalProxy.Storage.Smbd — regenerated on every start,
    # edits are lost.
    [global]
    server string = #{sanitize(netbios_name)}
    netbios name = #{sanitize(netbios_name)}
    server min protocol = SMB2_10
    server signing = required
    server smb encrypt = desired
    restrict anonymous = 2
    disable netbios = yes
    smb ports = 445
    map to guest = never
    guest ok = no
    load printers = no
    disable spoolss = yes
    printcap name = /dev/null
    usershare max shares = 0
    unix password sync = no
    # A single-share standalone server has no use for DFS referrals; off
    # means clients never send DFS-form paths, which is what the kernel
    # CIFS client backing HA OS's backup mount does when it connects via
    # a hostname smbd doesn't consider its own (fails with
    # "Hostname ... is not ours" under strict DFS path parsing) — see
    # `host msdfs` in smb.conf(5).
    host msdfs = no
    # Standalone (non-domain) default idmap: silences the "idmap range not
    # specified for domain '*'" startup warning and makes SID->uid mapping
    # for the local account deterministic.
    idmap config * : backend = tdb
    idmap config * : range = 3000-7999
    passdb backend = tdbsam:#{Path.join([data_dir, "private", "passdb.tdb"])}
    private dir = #{Path.join(data_dir, "private")}
    state directory = #{Path.join(data_dir, "state")}
    cache directory = #{Path.join(data_dir, "cache")}
    lock directory = #{run_dir}
    pid directory = #{run_dir}
    ncalrpc dir = #{Path.join(run_dir, "ncalrpc")}
    log level = 1

    [#{share_name}]
    path = #{share_path}
    valid users = #{username}
    force user = #{username}
    read only = no
    follow symlinks = no
    wide links = no
    browseable = yes
    create mask = 0660
    directory mask = 0770
    """
  end

  # `"/"` (and anything that normalises to it) shares the drive root; any
  # other value is joined on as a relative path, so a stored leading slash
  # cannot turn into an absolute path that escapes the mount point.
  #
  # Invariant this module relies on and does not itself enforce: `folder`
  # reaches here only after `UniversalProxy.Storage.Server`'s sandbox
  # (`path_segments/1`) has rejected every segment that is `.`, `..`,
  # empty, or contains a control byte — so the `sanitize/1` call below,
  # which strips CR/LF, is defense-in-depth against a value that should
  # already be free of them, not the boundary that makes the emitted path
  # safe. Free-text fields (`netbios_name`, `username`) are genuinely
  # transformed by `sanitize/1` because nothing upstream validates them the
  # same way; `folder` is emitted verbatim in that sense — a stripped
  # CR/LF here would only ever fire on a value the server should have
  # already refused.
  defp share_path(mount_point, folder) do
    mount_point = sanitize(mount_point)

    case folder |> to_string() |> sanitize() |> String.trim() |> String.trim_leading("/") do
      "" -> mount_point
      relative -> Path.join(mount_point, relative)
    end
  end

  # An embedded newline in an interpolated value would append arbitrary
  # directives to the generated config — strip line breaks, they are never
  # legitimate in a name or path.
  defp sanitize(value) when is_binary(value), do: String.replace(value, ~r/[\r\n]/, "")

  # -- (b) Runtime dirs + config file --

  @doc """
  Create Samba's writable dirs and write `smb.conf`. Idempotent.

  Options:

    * `:data_dir` (default `#{@default_data_dir}`), `:run_dir` (default
      `#{@default_run_dir}`) — the two state roots.
    * `:conf` — config path (default `<data_dir>/smb.conf`).
    * `:config` — config text to write, or `:params` — a `config/1` map
      (`:data_dir`/`:run_dir` are merged in from the options above). One
      of the two is required.

  `private/` is mode 0700 (it holds the account database) and `smb.conf`
  0600. Never raises; returns `{:ok, conf_path}` or `{:error, reason}`.
  """
  @spec prepare_runtime(keyword()) :: {:ok, String.t()} | {:error, term()}
  def prepare_runtime(opts \\ []) do
    data_dir = Keyword.get(opts, :data_dir, @default_data_dir)
    run_dir = Keyword.get(opts, :run_dir, @default_run_dir)
    private_dir = Path.join(data_dir, "private")
    conf = conf_path(opts)

    with {:ok, content} <- resolve_config(opts, data_dir, run_dir),
         :ok <- mkdir_p(data_dir),
         :ok <- mkdir_p(private_dir),
         :ok <- chmod(private_dir, 0o700),
         :ok <- mkdir_p(Path.join(data_dir, "state")),
         :ok <- mkdir_p(Path.join(data_dir, "cache")),
         :ok <- mkdir_p(run_dir),
         :ok <- mkdir_p(Path.join(run_dir, "ncalrpc")),
         :ok <- write(conf, content),
         :ok <- chmod(conf, 0o600) do
      {:ok, conf}
    end
  end

  @doc "Path of the generated config: `:conf`, else `<data_dir>/smb.conf`."
  @spec conf_path(keyword()) :: String.t()
  def conf_path(opts) do
    Keyword.get_lazy(opts, :conf, fn ->
      Path.join(Keyword.get(opts, :data_dir, @default_data_dir), "smb.conf")
    end)
  end

  defp resolve_config(opts, data_dir, run_dir) do
    case {Keyword.fetch(opts, :config), Keyword.fetch(opts, :params)} do
      {{:ok, content}, _} when is_binary(content) ->
        {:ok, content}

      {:error, {:ok, params}} when is_map(params) ->
        {:ok, config(Map.merge(params, %{data_dir: data_dir, run_dir: run_dir}))}

      _ ->
        {:error, :missing_config}
    end
  end

  defp mkdir_p(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, path, reason}}
    end
  end

  defp chmod(path, mode) do
    case File.chmod(path, mode) do
      :ok -> :ok
      {:error, reason} -> {:error, {:chmod_failed, path, reason}}
    end
  end

  defp write(path, content) do
    case File.write(path, content) do
      :ok -> :ok
      {:error, reason} -> {:error, {:write_failed, path, reason}}
    end
  end

  # -- (c) Account provisioning --

  @doc """
  Ensure the SMB account exists with `password`, feeding it to
  `smbpasswd -s -a` on stdin only.

  Idempotent by default: `SHA-256(username <> ":" <> password)` is
  compared against the hash recorded after the last successful run and
  the command is skipped when they match (`{:ok, :unchanged}`). Pass
  `force: true` to bypass that check and always run `smbpasswd` — see
  the moduledoc for why `UniversalProxy.Storage.Server` does this on
  every share start rather than trusting the hash. The hash is written
  after a successful run either way.

  Options:

    * `:username` (default `"#{@default_username}"`).
    * `:force` (default `false`) — skip the hash check and always run
      `smbpasswd`.
    * `:conf` / `:data_dir` — config path passed as `-c`.
    * `:smbpasswd_paths` — binary candidates, first existing wins.
    * `:get_hash_fun` / `:put_hash_fun` — the persistence seam, arity 0/1
      (default: `UniversalProxy.Storage.Settings`). `:get_hash_fun`
      swallows the "settings not running" exit (and unpersistable
      credentials) and reports no recorded hash, so provisioning re-runs
      rather than being skipped.
    * `:timeout` (default #{@provision_timeout} ms).

  The password never reaches `argv`, the log, or the returned error term.
  """
  @spec provision_user(String.t(), keyword()) ::
          {:ok, :provisioned | :unchanged} | {:error, term()}
  def provision_user(password, opts \\ []) when is_binary(password) do
    username = Keyword.get(opts, :username, @default_username)
    force? = Keyword.get(opts, :force, false)
    hash = provision_hash(username, password)

    if not force? and hash == recorded_hash(opts) do
      {:ok, :unchanged}
    else
      case run_smbpasswd(username, password, opts) do
        :ok ->
          record_hash(hash, opts)
          {:ok, :provisioned}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "The idempotence hash for a username/password pair (lowercase hex)."
  @spec provision_hash(String.t(), String.t()) :: String.t()
  def provision_hash(username, password) do
    :crypto.hash(:sha256, username <> ":" <> password) |> Base.encode16(case: :lower)
  end

  defp recorded_hash(opts) do
    fun = Keyword.get(opts, :get_hash_fun, &default_get_hash/0)
    fun.()
  end

  defp default_get_hash do
    case Settings.credentials() do
      %{provisioned_hash: hash} -> hash
      # Credentials that could not be persisted ({:error, :not_persisted}):
      # no recorded marker to compare against.
      _other -> nil
    end
  catch
    # Settings not started (host, or before the subtree comes up): treat as
    # "never provisioned" so the run happens instead of being skipped.
    :exit, _ -> nil
  end

  defp record_hash(hash, opts) do
    fun = Keyword.get(opts, :put_hash_fun, &default_put_hash/1)

    case fun.(hash) do
      :ok ->
        :ok

      other ->
        # The account IS provisioned; only the skip-marker is missing, so the
        # next call re-runs smbpasswd (harmless: -a on an existing account
        # just resets the password).
        Logger.warning("smbd: could not persist provisioning marker: #{inspect(other)}")
        :ok
    end
  end

  defp default_put_hash(hash) do
    Settings.put_provisioned_hash(hash)
  catch
    :exit, reason -> {:error, reason}
  end

  defp run_smbpasswd(username, password, opts) do
    bin = smbpasswd_path(opts)

    if File.exists?(bin) do
      feed_password(bin, ["-c", conf_path(opts), "-s", "-a", username], password, opts)
    else
      {:error, {:missing_binary, bin}}
    end
  end

  # Erlang ports have no way to half-close stdin, but `smbpasswd -s` reads
  # exactly two newline-terminated lines and never waits for EOF, so
  # writing both and waiting for :exit_status is sufficient. A shell
  # pipeline would be the alternative and is rejected: it puts the
  # password in another process's argv.
  defp feed_password(bin, args, password, opts) do
    timeout = Keyword.get(opts, :timeout, @provision_timeout)
    port = Port.open({:spawn_executable, String.to_charlist(bin)}, port_opts(args))
    Port.command(port, password <> "\n" <> password <> "\n")
    deadline = System.monotonic_time(:millisecond) + timeout
    collect(port, password, deadline, "", "")
  rescue
    e -> {:error, {:spawn_failed, bin, Exception.message(e)}}
  end

  defp port_opts(args), do: [:binary, :exit_status, :stderr_to_stdout, {:args, args}]

  # `deadline` is computed once, at entry (`feed_password/4`), from the
  # configured `:timeout` — not re-armed here. Handing the full timeout to
  # every `receive` would let a hung `smbpasswd` that keeps dribbling
  # output reset the clock on each chunk and never time out at all.
  #
  # Two independent bounds on `acc`, both required:
  #
  #   * the password is redacted out of *each chunk* before it is ever
  #     appended, not once at the end — so an unredacted copy of it is
  #     never retained even transiently. A chunk boundary can split the
  #     password in half, so `carry` holds back the last
  #     `byte_size(password) - 1` raw bytes of the previous chunk and
  #     re-scans them together with the next one: the only overlap wide
  #     enough for a straddling match to complete once more data arrives.
  #     `String.replace/3` never touches bytes outside a full match, so
  #     bytes that end up in `carry` are exactly the bytes that would have
  #     been there anyway had no match reached them.
  #   * `acc` itself is a rolling tail capped at `@collected_output_max`
  #     bytes, oldest bytes dropped first — a flooding or wedged
  #     `smbpasswd` must not grow it for the whole `:timeout` budget.
  defp collect(port, password, deadline, acc, carry) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        window = String.replace(carry <> data, password, "[redacted]")
        {kept, next_carry} = split_carry(window, byte_size(password))
        collect(port, password, deadline, append_capped(acc, kept), next_carry)

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, status}} ->
        # `carry` alone can never hold the whole password (it is at most
        # `byte_size(password) - 1` bytes), but it is folded back in and
        # redacted again here as the same defense-in-depth `redact/2`
        # already is: it should be a no-op for input this loop already
        # scrubbed.
        {:error, {:smbpasswd_failed, status, redact(acc <> carry, password)}}
    after
      remaining ->
        safe_close(port)
        {:error, :timeout}
    end
  end

  # `window` has already had every fully-contained password occurrence
  # replaced. Splitting off its last `password_size - 1` bytes defers
  # exactly the span a straddling match could still occupy; committing the
  # rest is safe because a match cannot start any later than that and still
  # need more data to complete.
  defp split_carry(window, password_size) do
    carry_len = max(password_size - 1, 0)
    window_size = byte_size(window)

    if window_size <= carry_len do
      {"", window}
    else
      {binary_part(window, 0, window_size - carry_len),
       binary_part(window, window_size - carry_len, carry_len)}
    end
  end

  defp append_capped(acc, chunk) do
    combined = acc <> chunk
    size = byte_size(combined)

    if size > @collected_output_max do
      binary_part(combined, size - @collected_output_max, @collected_output_max)
    else
      combined
    end
  end

  # smbpasswd does not echo the password, but an error path that does must
  # not turn an error tuple into a secret leak.
  defp redact(output, password) do
    output
    |> String.replace(password, "[redacted]")
    |> String.slice(0, 500)
  end

  defp safe_close(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # -- (d) Daemon --

  @doc """
  `MuonTrap.Daemon` child spec running `smbd` in the foreground so
  MuonTrap owns (and can reliably kill) the process.

  `restart: :temporary`, deliberately: `UniversalProxy.Storage.Server`
  owns this daemon's lifecycle. It monitors the child it starts and brings
  a dead one back through a convergence pass, which re-checks the drive's
  opt-in, the live mount and the sandboxed share folder first. A
  supervisor restart would instead resurrect `smbd` under a **new** pid
  behind the Server's back, leaving it tracking a dead one — a share
  reported `:off` while a real `smbd` still held port 445 and the mount
  point (which is what breaks the next eject or format).

  Options: `:conf` / `:data_dir` (config path), `:smbd_paths` (candidates,
  first existing wins), `:name` (registered name, default this module).
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    Supervisor.child_spec(
      {MuonTrap.Daemon,
       [
         smbd_path(opts),
         ["-F", "--debug-stdout", "-s", conf_path(opts)],
         [
           name: Keyword.get(opts, :name, __MODULE__),
           stderr_to_stdout: true,
           log_output: :info,
           log_prefix: "smbd: "
         ]
       ]},
      id: :smbd,
      restart: :temporary
    )
  end

  @doc "Whether any `smbd` candidate exists — the capability gate."
  @spec available?(keyword()) :: boolean()
  def available?(opts \\ []) do
    Enum.any?(candidates(opts, :smbd_paths, @smbd_candidates), &File.exists?/1)
  end

  @doc "Resolved `smbd` binary; the first candidate when none exists."
  @spec smbd_path(keyword()) :: String.t()
  def smbd_path(opts), do: resolve(candidates(opts, :smbd_paths, @smbd_candidates))

  @doc "Resolved `smbpasswd` binary; the first candidate when none exists."
  @spec smbpasswd_path(keyword()) :: String.t()
  def smbpasswd_path(opts) do
    resolve(candidates(opts, :smbpasswd_paths, @smbpasswd_candidates))
  end

  defp candidates(opts, key, default) do
    case Keyword.get(opts, key, default) do
      [_ | _] = list -> list
      _ -> default
    end
  end

  # First existing wins; otherwise the first candidate keeps the child spec
  # well-formed and lets MuonTrap surface the missing binary at start.
  defp resolve(candidates), do: Enum.find(candidates, &File.exists?/1) || hd(candidates)
end
