defmodule UniversalProxy.Storage.SmbdTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias UniversalProxy.Storage.Smbd

  doctest Smbd

  @params %{
    mount_point: "/run/usb-backup",
    username: "backup",
    netbios_name: "universal-proxy-a1b2c3"
  }

  describe "share_suffix/1 (mirrors the drive-key stability semantics)" do
    test "a normal serial: last 6 characters, lowercased" do
      assert Smbd.share_suffix(%{
               serial: "1C6F654CED3DED51E92C01E4",
               vendor_id: 0x0BDA,
               product_id: 0x0316
             }) ==
               "2c01e4"
    end

    test "a serial shorter than the tail window uses the whole (sanitized) thing" do
      assert Smbd.share_suffix(%{serial: "AB", vendor_id: 0x0930, product_id: 0x6545}) == "ab"
    end

    test "punctuation in the tail is dropped, not just lowercased" do
      assert Smbd.share_suffix(%{serial: "SN-A", vendor_id: 0x0781, product_id: 0x55AF}) == "sna"
    end

    test "a serial that sanitizes to fewer than 2 characters falls back to vid+pid" do
      assert Smbd.share_suffix(%{serial: "!", vendor_id: 0x0930, product_id: 0x6545}) ==
               "09306545"

      assert Smbd.share_suffix(%{serial: "!!!!!!", vendor_id: 0x0930, product_id: 0x6545}) ==
               "09306545"

      assert Smbd.share_suffix(%{serial: "", vendor_id: 0x0930, product_id: 0x6545}) == "09306545"
    end

    test "no serial at all falls back to lowercase hex vid <> pid" do
      assert Smbd.share_suffix(%{serial: nil, vendor_id: 0x0930, product_id: 0x6545}) ==
               "09306545"
    end

    test "the vid+pid fallback zero-pads below 4 hex digits" do
      assert Smbd.share_suffix(%{serial: nil, vendor_id: 0x1, product_id: 0x2}) == "00010002"
    end

    test "same serial, same suffix regardless of port (slot_sub) or repeated calls" do
      drive = %{serial: "SN-SDA-0001", vendor_id: 0x0BDA, product_id: 0x0316}
      moved = Map.put(drive, :slot_sub, "1-1.9")

      assert Smbd.share_suffix(drive) == Smbd.share_suffix(moved)
      assert Smbd.share_suffix(drive) == Smbd.share_suffix(drive)
    end

    test "every derived suffix matches the SMB-safe regex" do
      cases = [
        %{serial: "1C6F654CED3DED51E92C01E4", vendor_id: 0x0BDA, product_id: 0x0316},
        %{serial: "SN-SDA-0001", vendor_id: 0x0BDA, product_id: 0x0316},
        %{serial: "AB", vendor_id: 0x0930, product_id: 0x6545},
        %{serial: "!!!!!!", vendor_id: 0x0930, product_id: 0x6545},
        %{serial: nil, vendor_id: 0x0930, product_id: 0x6545},
        %{serial: nil, vendor_id: 0x0, product_id: 0x0},
        %{serial: "ünïçödé!", vendor_id: 0x1234, product_id: 0x5678}
      ]

      for drive <- cases do
        suffix = Smbd.share_suffix(drive)

        assert Regex.match?(~r/^[a-z0-9]{2,16}$/, suffix),
               "#{inspect(suffix)} (from #{inspect(drive)})"
      end
    end
  end

  describe "share_name/1" do
    test "prefixes the suffix with usb_backup_" do
      assert Smbd.share_name(%{
               serial: "1C6F654CED3DED51E92C01E4",
               vendor_id: 0x0BDA,
               product_id: 0x0316
             }) ==
               "usb_backup_2c01e4"
    end

    test "the serial-less fallback name" do
      assert Smbd.share_name(%{serial: nil, vendor_id: 0x0930, product_id: 0x6545}) ==
               "usb_backup_09306545"
    end
  end

  describe "config/1 [global] hardening (security-regression tripwire)" do
    setup do
      {:ok, conf: Smbd.config(@params)}
    end

    test "SMB2.1 protocol floor — no SMB1 dialect", %{conf: conf} do
      assert conf =~ "server min protocol = SMB2_10"
    end

    test "signing is mandatory", %{conf: conf} do
      assert conf =~ "server signing = required"
    end

    test "encryption is offered", %{conf: conf} do
      assert conf =~ "server smb encrypt = desired"
    end

    test "anonymous access fully restricted", %{conf: conf} do
      assert conf =~ "restrict anonymous = 2"
    end

    test "netbios protocol disabled", %{conf: conf} do
      assert conf =~ "disable netbios = yes"
    end

    test "listens on 445 only", %{conf: conf} do
      assert conf =~ "smb ports = 445"
    end

    test "failed auth never maps to guest", %{conf: conf} do
      assert conf =~ "map to guest = never"
    end

    test "guest access refused", %{conf: conf} do
      assert conf =~ "guest ok = no"
    end

    test "printer sharing off", %{conf: conf} do
      assert conf =~ "load printers = no"
    end

    test "spoolss off", %{conf: conf} do
      assert conf =~ "disable spoolss = yes"
    end

    test "printcap neutered", %{conf: conf} do
      assert conf =~ "printcap name = /dev/null"
    end

    test "usershares disabled", %{conf: conf} do
      assert conf =~ "usershare max shares = 0"
    end

    test "no unix password sync", %{conf: conf} do
      assert conf =~ "unix password sync = no"
    end

    test "DFS off — a single-share standalone server sends no DFS referrals", %{conf: conf} do
      assert conf =~ "host msdfs = no"
    end

    test "standalone idmap backend and range pinned", %{conf: conf} do
      assert conf =~ "idmap config * : backend = tdb"
      assert conf =~ "idmap config * : range = 3000-7999"
    end

    test "tdbsam passdb under the data dir", %{conf: conf} do
      assert conf =~ "passdb backend = tdbsam:/data/samba/private/passdb.tdb"
    end

    test "log level is low", %{conf: conf} do
      assert conf =~ "log level = 1"
    end

    test "server identity from netbios_name", %{conf: conf} do
      assert conf =~ "server string = universal-proxy-a1b2c3"
      assert conf =~ "netbios name = universal-proxy-a1b2c3"
    end
  end

  describe "config/1 state paths" do
    test "default roots" do
      conf = Smbd.config(@params)

      assert conf =~ "private dir = /data/samba/private"
      assert conf =~ "state directory = /data/samba/state"
      assert conf =~ "cache directory = /data/samba/cache"
      assert conf =~ "lock directory = /run/samba"
      assert conf =~ "pid directory = /run/samba"
      assert conf =~ "ncalrpc dir = /run/samba/ncalrpc"
    end

    test "overridden roots relocate every derived path" do
      conf =
        Smbd.config(Map.merge(@params, %{data_dir: "/tmp/d/samba", run_dir: "/tmp/r/samba"}))

      assert conf =~ "passdb backend = tdbsam:/tmp/d/samba/private/passdb.tdb"
      assert conf =~ "private dir = /tmp/d/samba/private"
      assert conf =~ "state directory = /tmp/d/samba/state"
      assert conf =~ "cache directory = /tmp/d/samba/cache"
      assert conf =~ "lock directory = /tmp/r/samba"
      assert conf =~ "pid directory = /tmp/r/samba"
      assert conf =~ "ncalrpc dir = /tmp/r/samba/ncalrpc"
      refute conf =~ "/data/samba"
    end
  end

  describe "config/1 [usb_backup] share" do
    setup do
      {:ok, conf: Smbd.config(@params)}
    end

    test "single share section named usb_backup by default (no :share_name given)", %{
      conf: conf
    } do
      assert conf =~ "[usb_backup]"
      sections = conf |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "["))
      assert sections == 2
    end

    # Golden: `Storage.Server` always passes the derived per-drive name, but
    # `config/1` itself stays backward compatible for a caller that omits it.
    test "an explicit :share_name names the section instead" do
      conf = Smbd.config(Map.put(@params, :share_name, "usb_backup_2c01e4"))

      assert conf =~ "[usb_backup_2c01e4]"
      refute conf =~ "[usb_backup]"
      sections = conf |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "["))
      assert sections == 2
    end

    test "a newline in :share_name cannot inject a directive" do
      conf = Smbd.config(Map.put(@params, :share_name, "usb_backup_x\nguest ok = yes"))

      refute "guest ok = yes" in String.split(conf, "\n")
      assert conf =~ "guest ok = no"
    end

    test "path is the mount point when no folder is mapped", %{conf: conf} do
      assert conf =~ "path = /run/usb-backup"
    end

    test "an explicit root folder is the mount point unchanged" do
      conf = Smbd.config(Map.put(@params, :share_folder, "/"))

      assert conf =~ "path = /run/usb-backup"
    end

    test "a mapped folder is joined onto the mount point" do
      conf = Smbd.config(Map.put(@params, :share_folder, "backups/ha"))

      assert conf =~ "path = /run/usb-backup/backups/ha"
    end

    test "a stored leading slash cannot make the share path absolute" do
      conf = Smbd.config(Map.put(@params, :share_folder, "/backups"))

      assert conf =~ "path = /run/usb-backup/backups"
    end

    test "a newline in the folder cannot inject a directive" do
      conf = Smbd.config(Map.put(@params, :share_folder, "backups\nguest ok = yes"))

      refute "guest ok = yes" in String.split(conf, "\n")
      assert conf =~ "guest ok = no"
    end

    test "only the provisioned account may connect", %{conf: conf} do
      assert conf =~ "valid users = backup"
    end

    test "files are forced to the unprivileged account", %{conf: conf} do
      assert conf =~ "force user = backup"
    end

    test "writable", %{conf: conf} do
      assert conf =~ "read only = no"
    end

    test "symlink escape blocked", %{conf: conf} do
      assert conf =~ "follow symlinks = no"
      assert conf =~ "wide links = no"
    end

    test "browseable", %{conf: conf} do
      assert conf =~ "browseable = yes"
    end

    test "owner+group only masks", %{conf: conf} do
      assert conf =~ "create mask = 0660"
      assert conf =~ "directory mask = 0770"
    end

    test "mount point and username interpolate" do
      conf =
        Smbd.config(%{
          mount_point: "/mnt/other",
          username: "smbuser",
          netbios_name: "node"
        })

      assert conf =~ "path = /mnt/other"
      assert conf =~ "valid users = smbuser"
      assert conf =~ "force user = smbuser"
    end

    test "embedded newlines cannot inject directives" do
      conf = Smbd.config(%{@params | netbios_name: "node\nguest ok = yes"})

      # The injected text survives only as part of a value on one line, never
      # as a directive line of its own.
      refute "guest ok = yes" in String.split(conf, "\n")
      assert conf =~ "guest ok = no"
    end
  end

  describe "prepare_runtime/1" do
    @tag :tmp_dir
    test "creates the state dirs and writes the config", %{tmp_dir: tmp_dir} do
      data_dir = Path.join(tmp_dir, "samba")
      run_dir = Path.join(tmp_dir, "run-samba")

      assert {:ok, conf} =
               Smbd.prepare_runtime(data_dir: data_dir, run_dir: run_dir, params: @params)

      assert conf == Path.join(data_dir, "smb.conf")
      assert File.dir?(data_dir)
      assert File.dir?(Path.join(data_dir, "private"))
      assert File.dir?(run_dir)
      assert File.dir?(Path.join(run_dir, "ncalrpc"))
      assert File.read!(conf) =~ "[usb_backup]"
      # Built from :params, so the config's paths follow the overridden roots.
      assert File.read!(conf) =~ "private dir = #{Path.join(data_dir, "private")}"
      assert File.read!(conf) =~ "ncalrpc dir = #{Path.join(run_dir, "ncalrpc")}"
    end

    @tag :tmp_dir
    test "private dir is 0700 and smb.conf 0600", %{tmp_dir: tmp_dir} do
      data_dir = Path.join(tmp_dir, "samba")

      assert {:ok, conf} =
               Smbd.prepare_runtime(
                 data_dir: data_dir,
                 run_dir: Path.join(tmp_dir, "run-samba"),
                 params: @params
               )

      assert (File.stat!(Path.join(data_dir, "private")).mode &&& 0o777) == 0o700
      assert (File.stat!(conf).mode &&& 0o777) == 0o600
    end

    @tag :tmp_dir
    test "accepts pre-built config text at an explicit :conf path", %{tmp_dir: tmp_dir} do
      conf_path = Path.join(tmp_dir, "custom.conf")

      assert {:ok, ^conf_path} =
               Smbd.prepare_runtime(
                 data_dir: Path.join(tmp_dir, "samba"),
                 run_dir: Path.join(tmp_dir, "run-samba"),
                 conf: conf_path,
                 config: "[global]\n"
               )

      assert File.read!(conf_path) == "[global]\n"
    end

    @tag :tmp_dir
    test "is idempotent", %{tmp_dir: tmp_dir} do
      opts = [
        data_dir: Path.join(tmp_dir, "samba"),
        run_dir: Path.join(tmp_dir, "run-samba"),
        params: @params
      ]

      assert {:ok, conf} = Smbd.prepare_runtime(opts)
      assert {:ok, ^conf} = Smbd.prepare_runtime(opts)
    end

    test "errors without config text or params" do
      assert {:error, :missing_config} = Smbd.prepare_runtime([])
    end

    @tag :tmp_dir
    test "returns an error tuple instead of raising on an unwritable root", %{tmp_dir: tmp_dir} do
      blocker = Path.join(tmp_dir, "blocker")
      File.write!(blocker, "not a dir")

      assert {:error, {:mkdir_failed, _path, _reason}} =
               Smbd.prepare_runtime(
                 data_dir: Path.join(blocker, "samba"),
                 run_dir: Path.join(tmp_dir, "run-samba"),
                 params: @params
               )
    end
  end

  describe "provision_user/2" do
    @describetag :tmp_dir

    @password "SEKRET-PASSWORD-12345678"

    setup %{tmp_dir: tmp_dir} do
      argv_log = Path.join(tmp_dir, "argv.log")
      stdin_log = Path.join(tmp_dir, "stdin.log")
      {:ok, fake: fake_smbpasswd(tmp_dir, argv_log, stdin_log), argv: argv_log, stdin: stdin_log}
    end

    test "feeds the password twice on stdin and never in argv", ctx do
      hash_holder = start_hash_holder()

      assert {:ok, :provisioned} =
               Smbd.provision_user(@password, provision_opts(ctx, hash_holder))

      assert File.read!(ctx.stdin) == @password <> "\n" <> @password <> "\n"

      argv = File.read!(ctx.argv)
      refute argv =~ @password
      assert argv =~ "-s"
      assert argv =~ "-a"
      assert argv =~ "backup"
      assert argv =~ "-c"
      assert argv =~ Path.join(ctx.tmp_dir, "smb.conf")
    end

    test "records the hash and skips a second identical call", ctx do
      hash_holder = start_hash_holder()
      opts = provision_opts(ctx, hash_holder)

      assert {:ok, :provisioned} = Smbd.provision_user(@password, opts)
      assert Agent.get(hash_holder, & &1) == Smbd.provision_hash("backup", @password)

      File.rm!(ctx.argv)
      File.rm!(ctx.stdin)

      assert {:ok, :unchanged} = Smbd.provision_user(@password, opts)
      refute File.exists?(ctx.argv)
      refute File.exists?(ctx.stdin)
    end

    test "force: true re-runs smbpasswd even when the hash matches", ctx do
      hash_holder = start_hash_holder()
      opts = provision_opts(ctx, hash_holder)

      assert {:ok, :provisioned} = Smbd.provision_user(@password, opts)
      recorded = Agent.get(hash_holder, & &1)

      File.rm!(ctx.argv)
      File.rm!(ctx.stdin)

      test_pid = self()

      observing_opts =
        Keyword.put(opts, :put_hash_fun, fn hash ->
          Agent.update(hash_holder, fn _ -> hash end)
          send(test_pid, {:hash_recorded, hash})
          :ok
        end)

      assert {:ok, :provisioned} =
               Smbd.provision_user(@password, Keyword.put(observing_opts, :force, true))

      assert File.read!(ctx.stdin) == @password <> "\n" <> @password <> "\n"
      # The hash marker is unchanged (same username/password), but assert
      # it was actually (re)recorded by the forced run — not merely left
      # alone by a forced path that skipped record_hash/2 — by observing
      # the call itself rather than the value it would have left behind
      # either way.
      assert_receive {:hash_recorded, ^recorded}
    end

    test "a changed password re-runs smbpasswd", ctx do
      hash_holder = start_hash_holder()
      opts = provision_opts(ctx, hash_holder)

      assert {:ok, :provisioned} = Smbd.provision_user(@password, opts)
      File.rm!(ctx.stdin)

      assert {:ok, :provisioned} = Smbd.provision_user("DIFFERENT-PASSWORD", opts)
      assert File.read!(ctx.stdin) == "DIFFERENT-PASSWORD\nDIFFERENT-PASSWORD\n"
    end

    test "a different username re-runs even with the same password", ctx do
      hash_holder = start_hash_holder()
      opts = provision_opts(ctx, hash_holder)

      assert {:ok, :provisioned} = Smbd.provision_user(@password, opts)
      assert {:ok, :provisioned} = Smbd.provision_user(@password, [username: "other"] ++ opts)
    end

    test "failure redacts the password out of the error tuple", ctx do
      hash_holder = start_hash_holder()
      # Echoes stdin back to stdout and fails — the leak this must scrub.
      leaky = leaky_smbpasswd(ctx.tmp_dir)
      opts = Keyword.put(provision_opts(ctx, hash_holder), :smbpasswd_paths, [leaky])

      assert {:error, {:smbpasswd_failed, 1, output}} = Smbd.provision_user(@password, opts)
      refute output =~ @password
      assert output =~ "[redacted]"
      refute inspect({:smbpasswd_failed, 1, output}) =~ @password
      # A failed run must not record the skip marker.
      assert Agent.get(hash_holder, & &1) == nil
    end

    test "missing binary is an error, not a raise", ctx do
      hash_holder = start_hash_holder()

      opts =
        Keyword.put(provision_opts(ctx, hash_holder), :smbpasswd_paths, ["/nonexistent/smbpasswd"])

      assert {:error, {:missing_binary, "/nonexistent/smbpasswd"}} =
               Smbd.provision_user(@password, opts)
    end

    test "a hung smbpasswd times out", ctx do
      hash_holder = start_hash_holder()
      hung = hung_smbpasswd(ctx.tmp_dir)

      opts =
        provision_opts(ctx, hash_holder)
        |> Keyword.put(:smbpasswd_paths, [hung])
        |> Keyword.put(:timeout, 200)

      assert {:error, :timeout} = Smbd.provision_user(@password, opts)
    end

    # The timeout is a total budget from entry, not a per-chunk one: a
    # `smbpasswd` that keeps dribbling output (still alive, just never
    # finishing) must not have the clock reset on every chunk it emits.
    test "a smbpasswd that dribbles output forever times out at ~ the configured total", ctx do
      hash_holder = start_hash_holder()
      dribbling = dribbling_smbpasswd(ctx.tmp_dir)

      opts =
        provision_opts(ctx, hash_holder)
        |> Keyword.put(:smbpasswd_paths, [dribbling])
        |> Keyword.put(:timeout, 200)

      {elapsed_us, result} = :timer.tc(fn -> Smbd.provision_user(@password, opts) end)
      elapsed_ms = div(elapsed_us, 1000)

      assert result == {:error, :timeout}

      # The fake keeps writing for ~1_000ms (20 chunks, 50ms apart) before
      # it ever exits on its own: a per-chunk timeout bug would ride every
      # chunk's reset and only expire once the output stops, well past
      # 1_000ms. The fix must land close to the configured 200ms instead.
      assert elapsed_ms < 700
    end

    # A noisy or wedged smbpasswd must not be allowed to grow the
    # collected buffer for the whole `:timeout` budget — that is
    # unbounded memory on-device. `yes | head` floods megabytes of
    # output far faster than a real smbpasswd ever would, so a
    # regression back to unbounded accumulation would show up here as
    # either a large returned output or a multi-second stall, not just as
    # an OOM under real load.
    test "a flood of output does not grow the collected buffer or stall", ctx do
      hash_holder = start_hash_holder()
      flooding = flooding_smbpasswd(ctx.tmp_dir)

      opts =
        provision_opts(ctx, hash_holder)
        |> Keyword.put(:smbpasswd_paths, [flooding])
        |> Keyword.put(:timeout, 5_000)

      {elapsed_us, result} = :timer.tc(fn -> Smbd.provision_user(@password, opts) end)

      assert {:error, {:smbpasswd_failed, 1, output}} = result
      # Bounded regardless of how many megabytes the fake wrote: the
      # rolling collection window, then the existing 500-char error cap.
      assert byte_size(output) <= 500
      assert div(elapsed_us, 1000) < 3_000
    end

    # The password is redacted out of each chunk as it arrives, not once
    # at the end — but a chunk boundary can split the password in half.
    # Sleeping between the two writes forces the port to deliver them as
    # two separate `{:data, ...}` messages instead of coalescing into one,
    # driving the seam the carry-and-rescan logic exists for.
    test "a password split across a chunk boundary is still fully redacted", ctx do
      hash_holder = start_hash_holder()
      seam = seam_smbpasswd(ctx.tmp_dir)
      opts = Keyword.put(provision_opts(ctx, hash_holder), :smbpasswd_paths, [seam])

      assert {:error, {:smbpasswd_failed, 1, output}} = Smbd.provision_user(@password, opts)
      refute output =~ @password
      assert output =~ "[redacted]"
    end
  end

  describe "child_spec/1" do
    test "MuonTrap.Daemon spec with :smbd id and foreground smbd" do
      spec = Smbd.child_spec(conf: "/data/samba/smb.conf", smbd_paths: ["/nope/smbd"])

      assert spec.id == :smbd
      # `Storage.Server` owns the restart decision: it monitors the child
      # it starts and brings it back through a convergence pass. A
      # supervisor restart would resurrect smbd under a pid the Server
      # never learns, leaving it tracking a dead one.
      assert spec.restart == :temporary
      assert {MuonTrap.Daemon, :start_link, [bin, args, daemon_opts]} = spec.start
      assert bin == "/nope/smbd"
      assert "-F" in args
      assert "--debug-stdout" in args
      assert ["-s", "/data/samba/smb.conf"] in Enum.chunk_every(args, 2, 1)
      assert daemon_opts[:log_output] == :info
      assert daemon_opts[:log_prefix] == "smbd: "
      assert daemon_opts[:stderr_to_stdout] == true
    end

    @tag :tmp_dir
    test "resolves the first existing candidate", %{tmp_dir: tmp_dir} do
      real = Path.join(tmp_dir, "smbd")
      File.write!(real, "")

      spec = Smbd.child_spec(smbd_paths: ["/nope/smbd", real])

      assert {MuonTrap.Daemon, :start_link, [^real, _args, _opts]} = spec.start
    end

    test "defaults the config path to <data_dir>/smb.conf" do
      spec = Smbd.child_spec(data_dir: "/tmp/samba", smbd_paths: ["/nope/smbd"])

      assert {MuonTrap.Daemon, :start_link, [_bin, args, _opts]} = spec.start
      assert "/tmp/samba/smb.conf" in args
    end
  end

  describe "available?/1" do
    @tag :tmp_dir
    test "true when a candidate exists", %{tmp_dir: tmp_dir} do
      bin = Path.join(tmp_dir, "smbd")
      File.write!(bin, "")

      assert Smbd.available?(smbd_paths: ["/nope/smbd", bin])
    end

    test "false for bogus candidates" do
      refute Smbd.available?(smbd_paths: ["/nope/smbd", "/also/nope/smbd"])
    end
  end

  # -- Fake binaries + helpers --

  defp provision_opts(ctx, hash_holder) do
    [
      smbpasswd_paths: [ctx.fake],
      conf: Path.join(ctx.tmp_dir, "smb.conf"),
      get_hash_fun: fn -> Agent.get(hash_holder, & &1) end,
      put_hash_fun: fn hash -> Agent.update(hash_holder, fn _ -> hash end) end
    ]
  end

  defp start_hash_holder do
    start_supervised!(%{id: :hash_holder, start: {Agent, :start_link, [fn -> nil end]}})
  end

  # Emulates `smbpasswd -s`: reads exactly two newline-terminated lines and
  # exits without waiting for EOF on stdin (an Erlang port cannot half-close
  # it, so a `cat`-style fake would hang forever).
  defp fake_smbpasswd(dir, argv_log, stdin_log) do
    write_script(dir, "smbpasswd", """
    #!/bin/sh
    echo "$@" > #{argv_log}
    read -r first
    read -r second
    printf '%s\\n%s\\n' "$first" "$second" > #{stdin_log}
    exit 0
    """)
  end

  defp leaky_smbpasswd(dir) do
    write_script(dir, "smbpasswd-leaky", """
    #!/bin/sh
    read -r first
    echo "smbpasswd: rejected input: $first"
    exit 1
    """)
  end

  defp hung_smbpasswd(dir) do
    write_script(dir, "smbpasswd-hung", """
    #!/bin/sh
    sleep 30
    """)
  end

  # Never blocks in a plain read (which would just hang the port write, not
  # exercise the timeout loop's chunking): emits output every ~50ms for
  # ~1_000ms total, then exits on its own — long enough to prove a fixed
  # deadline fires well before the dribbling stops, short enough to keep a
  # buggy run's worst case bounded.
  defp dribbling_smbpasswd(dir) do
    write_script(dir, "smbpasswd-dribbling", """
    #!/bin/sh
    i=0
    while [ "$i" -lt 20 ]; do
      echo "still working"
      sleep 0.05
      i=$((i + 1))
    done
    """)
  end

  # `yes`/`head` are compiled utilities, fast enough to produce megabytes
  # of output well inside a test timeout — a shell loop doing the same
  # would be slow enough to look like the very stall this guards against.
  defp flooding_smbpasswd(dir) do
    write_script(dir, "smbpasswd-flooding", """
    #!/bin/sh
    read -r first
    read -r second
    yes "0123456789012345678901234567890123456789" | head -c 2000000
    exit 1
    """)
  end

  # Echoes the fed-in password back split across two writes with a real
  # sleep between them, so the boundary lands in the middle of the
  # password (`@password` is 24 bytes; "SEKRET-PASSW" | "ORD-12345678"),
  # not on a chunk edge that happens to be safe. `awk`'s `printf` (unlike
  # `cut`, which appends its own trailing newline per line) writes exactly
  # the requested substring with nothing extra, so the two halves are
  # contiguous in the output stream — a stray separator here would make
  # the password never actually appear intact, which would pass this test
  # for the wrong reason.
  defp seam_smbpasswd(dir) do
    write_script(dir, "smbpasswd-seam", """
    #!/bin/sh
    read -r first
    read -r second
    printf '%s' "$first" | awk '{printf "%s", substr($0,1,12)}'
    sleep 0.2
    printf '%s' "$first" | awk '{printf "%s", substr($0,13)}'
    exit 1
    """)
  end

  defp write_script(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, body)
    File.chmod!(path, 0o755)
    path
  end
end
