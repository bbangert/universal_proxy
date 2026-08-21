defmodule UniversalProxy.Storage.MountTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias UniversalProxy.Storage.Mount

  @moduletag :tmp_dir

  @df_output """
  Filesystem      1B-blocks         Used    Available Use% Mounted on
  /dev/sda1    124098838528  10737418240 113361420288   9% /run/usb-backup
  """

  setup %{tmp_dir: tmp_dir} do
    test_pid = self()

    {:ok,
     point: Path.join(tmp_dir, "mnt"),
     log: Path.join(tmp_dir, "argv.log"),
     chown_fun: fn point, uid, gid ->
       send(test_pid, {:chown, point, uid, gid})
       :ok
     end}
  end

  describe "mount/3 ext4" do
    test "fsck runs before mount, then the point is chowned", ctx do
      opts = opts(ctx, mount_bin: fake!(ctx, "mount"), fsck_bin: fake!(ctx, "fsck.ext4"))

      assert Mount.mount("/dev/sda1", :ext4, opts) == {:ok, :read_write}

      assert invocations(ctx) == [
               {"fsck.ext4", ["-p", "/dev/sda1"]},
               {"mount",
                [
                  "-t",
                  "ext4",
                  "-o",
                  "rw,noatime,nodev,nosuid,noexec",
                  "/dev/sda1",
                  ctx.point
                ]}
             ]

      assert_received {:chown, point, 1000, 1000}
      assert point == ctx.point
      assert File.dir?(ctx.point)
    end

    test "the real chown seam is exercised without raising", ctx do
      opts =
        ctx
        |> opts(mount_bin: fake!(ctx, "mount"), fsck_bin: fake!(ctx, "fsck.ext4"))
        |> Keyword.delete(:chown_fun)

      assert Mount.mount("/dev/sda1", :ext4, opts) == {:ok, :read_write}
    end

    test "a failing chown is logged but keeps the mount successful", ctx do
      opts =
        opts(ctx,
          mount_bin: fake!(ctx, "mount"),
          fsck_bin: fake!(ctx, "fsck.ext4"),
          chown_fun: fn _point, _uid, _gid -> {:error, :eperm} end
        )

      log =
        capture_log(fn -> assert Mount.mount("/dev/sda1", :ext4, opts) == {:ok, :read_write} end)

      assert log =~ "chown"
      assert log =~ ":eperm"
    end

    test "fsck exit status 1 means repaired, so the mount proceeds", ctx do
      opts =
        opts(ctx,
          mount_bin: fake!(ctx, "mount"),
          fsck_bin: fake!(ctx, "fsck.ext4", statuses: [1], stdout: "/dev/sda1: FIXED")
        )

      assert Mount.mount("/dev/sda1", :ext4, opts) == {:ok, :read_write}
      assert [{"fsck.ext4", _}, {"mount", _}] = invocations(ctx)
    end

    test "fsck exit status 4 aborts before mounting", ctx do
      opts =
        opts(ctx,
          mount_bin: fake!(ctx, "mount"),
          fsck_bin: fake!(ctx, "fsck.ext4", statuses: [4], stdout: "UNEXPECTED INCONSISTENCY")
        )

      assert {:error, {:command_failed, cmd, 4, out}} = Mount.mount("/dev/sda1", :ext4, opts)
      assert cmd =~ "fsck.ext4 -p /dev/sda1"
      assert out == "UNEXPECTED INCONSISTENCY"

      assert [{"fsck.ext4", _}] = invocations(ctx)
      refute_received {:chown, _, _, _}
    end
  end

  describe "mount/3 foreign filesystems" do
    test "exfat adds uid/gid/umask and skips fsck", ctx do
      opts = opts(ctx, mount_bin: fake!(ctx, "mount"))

      assert Mount.mount("/dev/sdb1", :exfat, opts) == {:ok, :read_write}

      assert invocations(ctx) == [
               {"mount",
                [
                  "-t",
                  "exfat",
                  "-o",
                  "rw,noatime,nodev,nosuid,noexec,uid=1000,gid=1000,umask=0077",
                  "/dev/sdb1",
                  ctx.point
                ]}
             ]

      refute_received {:chown, _, _, _}
    end

    test "ntfs3 passes the kernel driver name, vfat its own", ctx do
      opts = opts(ctx, mount_bin: fake!(ctx, "mount"))

      assert Mount.mount("/dev/sdb1", :ntfs3, opts) == {:ok, :read_write}
      assert Mount.mount("/dev/sdb2", :vfat, opts) == {:ok, :read_write}

      assert [{"mount", ["-t", "ntfs3" | _]}, {"mount", ["-t", "vfat" | _]}] = invocations(ctx)
    end

    test "a failed read-write mount is retried read-only", ctx do
      opts = opts(ctx, mount_bin: fake!(ctx, "mount", statuses: [32, 0]))

      assert Mount.mount("/dev/sdb1", :ntfs3, opts) == {:ok, :read_only}

      assert [{"mount", [_, _, "-o", rw_options | _]}, {"mount", [_, _, "-o", ro_options | _]}] =
               invocations(ctx)

      assert rw_options == "rw,noatime,nodev,nosuid,noexec,uid=1000,gid=1000,umask=0077"
      assert ro_options == "ro,noatime,nodev,nosuid,noexec,uid=1000,gid=1000,umask=0077"
    end

    test "when both attempts fail the read-write error is reported", ctx do
      opts = opts(ctx, mount_bin: fake!(ctx, "mount", statuses: [32], stdout: "mount: bad fs"))

      assert {:error, {:command_failed, cmd, 32, "mount: bad fs"}} =
               Mount.mount("/dev/sdb1", :exfat, opts)

      assert cmd =~ "-o rw,noatime"
      assert length(invocations(ctx)) == 2
    end
  end

  describe "mount/3 vfat repair" do
    test "fsck.fat -a runs before the mount when a checker is installed", ctx do
      opts = opts(ctx, mount_bin: fake!(ctx, "mount"), fsck_fat_bin: fake!(ctx, "fsck.fat"))

      assert Mount.mount("/dev/sdb1", :vfat, opts) == {:ok, :read_write}

      assert invocations(ctx) == [
               {"fsck.fat", ["-a", "/dev/sdb1"]},
               {"mount",
                [
                  "-t",
                  "vfat",
                  "-o",
                  "rw,noatime,nodev,nosuid,noexec,uid=1000,gid=1000,umask=0077",
                  "/dev/sdb1",
                  ctx.point
                ]}
             ]
    end

    test "exit status 1 means repaired, so the mount proceeds", ctx do
      opts =
        opts(ctx,
          mount_bin: fake!(ctx, "mount"),
          fsck_fat_bin: fake!(ctx, "fsck.fat", statuses: [1], stdout: "Performing changes.")
        )

      assert Mount.mount("/dev/sdb1", :vfat, opts) == {:ok, :read_write}
      assert [{"fsck.fat", _}, {"mount", _}] = invocations(ctx)
    end

    test "exit status 2 and above aborts before mounting, as the ext4 flow does", ctx do
      opts =
        opts(ctx,
          mount_bin: fake!(ctx, "mount"),
          fsck_fat_bin:
            fake!(ctx, "fsck.fat", statuses: [4], stdout: "Leaving filesystem unchanged")
        )

      assert {:error, {:command_failed, cmd, 4, out}} = Mount.mount("/dev/sdb1", :vfat, opts)
      assert cmd =~ "fsck.fat -a /dev/sdb1"
      assert out == "Leaving filesystem unchanged"

      assert [{"fsck.fat", _}] = invocations(ctx)
    end

    test "an absent checker is skipped silently and the mount still happens", ctx do
      # What every current image looks like: dosfstools does not ship
      # until the custom systems reach v0.1.9.
      opts =
        opts(ctx,
          mount_bin: fake!(ctx, "mount"),
          fsck_fat_bin: Path.join(ctx.tmp_dir, "not-installed-fsck.fat")
        )

      assert Mount.mount("/dev/sdb1", :vfat, opts) == {:ok, :read_write}
      assert [{"mount", _}] = invocations(ctx)
    end

    test "exFAT gets no repair at all — no exFAT checker is shipped", ctx do
      opts = opts(ctx, mount_bin: fake!(ctx, "mount"), fsck_fat_bin: fake!(ctx, "fsck.fat"))

      assert Mount.mount("/dev/sdb1", :exfat, opts) == {:ok, :read_write}
      assert [{"mount", _}] = invocations(ctx)
    end

    test "the ext4 checker is never handed a FAT volume", ctx do
      opts =
        opts(ctx,
          mount_bin: fake!(ctx, "mount"),
          fsck_bin: fake!(ctx, "fsck.ext4"),
          fsck_fat_bin: fake!(ctx, "fsck.fat")
        )

      assert Mount.mount("/dev/sdb1", :vfat, opts) == {:ok, :read_write}
      assert [{"fsck.fat", _}, {"mount", _}] = invocations(ctx)
    end
  end

  describe "mount/3 failure modes" do
    test "a missing binary is an error tuple, not a raise", ctx do
      opts = opts(ctx, mount_bin: Path.join(ctx.tmp_dir, "absent-mount"))

      assert {:error, {:command_failed, cmd, :enoent, _out}} =
               Mount.mount("/dev/sdb1", :vfat, opts)

      assert cmd =~ "absent-mount"
    end

    test "an uncreatable mount point never runs a command", ctx do
      File.write!(Path.join(ctx.tmp_dir, "regular-file"), "x")

      opts =
        opts(ctx,
          mount_bin: fake!(ctx, "mount"),
          mount_point: Path.join([ctx.tmp_dir, "regular-file", "mnt"])
        )

      assert {:error, {:mount_point_unavailable, _point, :enotdir}} =
               Mount.mount("/dev/sdb1", :vfat, opts)

      assert invocations(ctx) == []
    end

    test "an unrecognised filesystem is refused", ctx do
      opts = opts(ctx, mount_bin: fake!(ctx, "mount"))

      assert Mount.mount("/dev/sdb1", :unknown, opts) ==
               {:error, {:unsupported_fs_type, :unknown}}

      assert invocations(ctx) == []
    end
  end

  describe "umount/1" do
    test "unmounts the mount point", ctx do
      opts = opts(ctx, umount_bin: fake!(ctx, "umount"))

      assert Mount.umount(opts) == :ok
      assert invocations(ctx) == [{"umount", [ctx.point]}]
    end

    test "lazy: true adds -l", ctx do
      opts = opts(ctx, umount_bin: fake!(ctx, "umount"), lazy: true)

      assert Mount.umount(opts) == :ok
      assert invocations(ctx) == [{"umount", ["-l", ctx.point]}]
    end

    test "a failure is reported with status and output", ctx do
      opts =
        opts(ctx,
          umount_bin: fake!(ctx, "umount", statuses: [1], stdout: "umount: not mounted")
        )

      assert {:error, {:command_failed, cmd, 1, "umount: not mounted"}} = Mount.umount(opts)
      assert cmd =~ "umount #{ctx.point}"
    end
  end

  describe "format_ext4/3" do
    test "refuses without confirm: true", ctx do
      opts = opts(ctx, mkfs_bin: fake!(ctx, "mkfs.ext4"), umount_bin: fake!(ctx, "umount"))

      assert Mount.format_ext4("/dev/sda1", "Backup", opts) == {:error, :not_confirmed}

      assert Mount.format_ext4("/dev/sda1", "Backup", Keyword.put(opts, :confirm, "yes")) ==
               {:error, :not_confirmed}

      assert invocations(ctx) == []
    end

    test "unmounts first, then mkfs with the label as one argv element", ctx do
      opts =
        opts(ctx,
          mkfs_bin: fake!(ctx, "mkfs.ext4"),
          umount_bin: fake!(ctx, "umount"),
          confirm: true
        )

      assert Mount.format_ext4("/dev/sda1", "My Backup; rm -rf /", opts) == :ok

      assert invocations(ctx) == [
               {"umount", [ctx.point]},
               {"mkfs.ext4",
                [
                  "-F",
                  "-L",
                  "My Backup; rm -rf /",
                  "-m",
                  "1",
                  "-E",
                  "lazy_itable_init=0",
                  "/dev/sda1"
                ]}
             ]
    end

    test "a failing umount does not block the format", ctx do
      opts =
        opts(ctx,
          mkfs_bin: fake!(ctx, "mkfs.ext4"),
          umount_bin: fake!(ctx, "umount", statuses: [1], stdout: "umount: not mounted"),
          confirm: true
        )

      assert Mount.format_ext4("/dev/sda1", "Backup", opts) == :ok
      assert [{"umount", _}, {"mkfs.ext4", _}] = invocations(ctx)
    end

    test "a failing mkfs is an error tuple", ctx do
      opts =
        opts(ctx,
          mkfs_bin: fake!(ctx, "mkfs.ext4", statuses: [1], stdout: "mkfs: device is busy"),
          umount_bin: fake!(ctx, "umount"),
          confirm: true
        )

      assert {:error, {:command_failed, cmd, 1, "mkfs: device is busy"}} =
               Mount.format_ext4("/dev/sda1", "Backup", opts)

      assert cmd =~ "-L Backup"
    end
  end

  describe "capacity/1" do
    test "parses df -B1 output", ctx do
      opts = opts(ctx, df_bin: fake!(ctx, "df", stdout: String.trim_trailing(@df_output)))

      assert Mount.capacity(opts) ==
               {:ok,
                %{
                  total_bytes: 124_098_838_528,
                  used_bytes: 10_737_418_240,
                  free_bytes: 113_361_420_288,
                  used_pct: 9
                }}

      assert invocations(ctx) == [{"df", ["-B1", ctx.point]}]
    end

    test "a df failure is an error tuple", ctx do
      opts =
        opts(ctx,
          df_bin: fake!(ctx, "df", statuses: [1], stdout: "df: can't find mount point")
        )

      assert {:error, {:command_failed, cmd, 1, "df: can't find mount point"}} =
               Mount.capacity(opts)

      assert cmd =~ "df -B1 #{ctx.point}"
    end

    test "unparsable df output is an error tuple", ctx do
      opts = opts(ctx, df_bin: fake!(ctx, "df", stdout: "nothing useful"))

      assert {:error, {:unexpected_df_output, "nothing useful\n"}} = Mount.capacity(opts)
    end
  end

  # -- Fake executables ------------------------------------------------
  #
  # Same seam as `test/support/fake_sendspin_player.py`: a real
  # executable stands in for the target binary. Each fake appends its own
  # name and every argv element it received to one shared log, so tests
  # can assert both the arguments and the order commands ran in, and
  # exits with a scripted status per invocation (the last status repeats).

  # `:fsck_fat_bin` defaults to a path inside the tmp dir that no test
  # creates, so a dev box or CI runner that happens to have dosfstools
  # installed cannot make the vfat mounts here run a real `fsck.fat`.
  defp opts(ctx, extra) do
    Keyword.merge(
      [
        mount_point: ctx.point,
        chown_fun: ctx.chown_fun,
        fsck_fat_bin: Path.join(ctx.tmp_dir, "absent-fsck.fat")
      ],
      extra
    )
  end

  defp fake!(ctx, name, opts \\ []) do
    path = Path.join(ctx.tmp_dir, name)
    counter = Path.join(ctx.tmp_dir, "#{name}.count")
    statuses = Keyword.get(opts, :statuses, [0])

    File.write!(path, script(name, ctx.log, counter, statuses, Keyword.get(opts, :stdout, "")))
    File.chmod!(path, 0o755)
    path
  end

  defp script(name, log, counter, statuses, stdout) do
    cases =
      statuses
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {status, nth} -> "  #{nth}) exit #{status} ;;" end)

    """
    #!/bin/sh
    i=0
    if [ -f '#{counter}' ]; then i=$(cat '#{counter}'); fi
    i=$((i + 1))
    printf '%s' "$i" > '#{counter}'
    {
      printf 'cmd %s\\n' '#{name}'
      for a in "$@"; do printf 'arg %s\\n' "$a"; done
    } >> '#{log}'
    #{stdout_lines(stdout)}
    case "$i" in
    #{cases}
      *) exit #{List.last(statuses)} ;;
    esac
    """
  end

  defp stdout_lines(""), do: ""

  defp stdout_lines(stdout), do: "cat <<'FAKE_STDOUT'\n#{stdout}\nFAKE_STDOUT"

  defp invocations(ctx) do
    case File.read(ctx.log) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.reduce([], fn
          "cmd " <> name, acc -> [{name, []} | acc]
          "arg " <> arg, [{name, args} | rest] -> [{name, args ++ [arg]} | rest]
          _line, acc -> acc
        end)
        |> Enum.reverse()

      {:error, :enoent} ->
        []
    end
  end
end
