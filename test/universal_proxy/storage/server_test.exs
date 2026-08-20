defmodule UniversalProxy.Storage.ServerTest do
  # async: false — the stubs share one named Recorder Agent and the test
  # subscribes to the global `"storage:state"` topic; concurrent tests
  # would see each other's events and broadcasts.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias UniversalProxy.Storage.{Server, Settings}
  alias UniversalProxy.StorageFixtures

  @pubsub UniversalProxy.PubSub
  @topic "storage:state"
  @settings_table :storage_server_test

  # Probe reports vid/pid as integers; Storage.Settings keys them as
  # lowercase 4-digit hex strings, which is what Server derives.
  @drive_key {"1-1.3", "0bda", "0316"}

  defmodule Recorder do
    @moduledoc """
    One Agent holding both the ordered event log the stubs append to and
    the response table they read. `take/2` pops a queued response so a
    test can script "fail, then fail again" sequences; `get/2` returns a
    fixed value for every call.
    """
    use Agent

    def start_link(_opts \\ []) do
      Agent.start_link(fn -> %{events: [], config: %{}} end, name: __MODULE__)
    end

    # Guarded: a stub daemon's terminate/2 can fire after the supervisor
    # has already torn the Agent down.
    def record(event) do
      Agent.update(__MODULE__, fn state -> %{state | events: [event | state.events]} end)
    catch
      :exit, _ -> :ok
    end

    def events, do: __MODULE__ |> Agent.get(& &1.events) |> Enum.reverse()

    def event_names, do: Enum.map(events(), &elem(&1, 0))

    def put(key, value) do
      Agent.update(__MODULE__, fn state -> put_in(state.config[key], value) end)
    end

    def get(key, default) do
      Agent.get(__MODULE__, fn state -> Map.get(state.config, key, default) end)
    end

    def take(key, default) do
      Agent.get_and_update(__MODULE__, fn state ->
        case Map.get(state.config, key) do
          [head | rest] -> {head, put_in(state.config[key], rest)}
          _ -> {default, state}
        end
      end)
    end
  end

  defmodule ProbeStub do
    @moduledoc """
    Only `list_drives/1` is stubbed: `fs_type/1` and
    `first_data_partition/1` are pure, so the real implementations run
    against `StorageFixtures` superblock bytes and the sniff wiring is
    exercised end to end.
    """
    alias UniversalProxy.Storage.Probe
    alias UniversalProxy.Storage.ServerTest.Recorder

    def list_drives(_opts) do
      case Recorder.get(:drives, []) do
        :raise -> raise "probe exploded"
        drives -> drives
      end
    end

    defdelegate fs_type(bytes), to: Probe
    defdelegate first_data_partition(drive), to: Probe
  end

  defmodule MountStub do
    @moduledoc false
    alias UniversalProxy.Storage.ServerTest.Recorder

    @point "/tmp/up-storage-server-test"

    def point, do: @point

    def mount_point(_opts), do: @point

    def mount(device, fs_type, _opts) do
      Recorder.record({:mount, device, fs_type})
      Recorder.take(:mount_results, {:ok, :read_write})
    end

    def umount(opts) do
      Recorder.record({:umount, Keyword.get(opts, :lazy, false)})
      Recorder.take(:umount_results, :ok)
    end

    def capacity(_opts) do
      Recorder.record({:capacity})
      Recorder.get(:capacity, {:ok, capacity()})
    end

    def chown_backup(path, _opts) do
      Recorder.record({:chown_backup, path})
      Recorder.take(:chown_results, :ok)
    end

    def format_ext4(device, label, opts) do
      Recorder.record({:format, device, label, Keyword.get(opts, :confirm)})
      Recorder.take(:format_results, :ok)
    end

    def capacity do
      %{total_bytes: 1_000, used_bytes: 100, free_bytes: 900, used_pct: 10}
    end
  end

  defmodule DaemonStub do
    @moduledoc """
    Stands in for the `MuonTrap.Daemon` running smbd. Traps exits so
    `DynamicSupervisor.terminate_child/2` reaches `terminate/2`, which is
    how tests observe that the daemon is stopped *before* the umount.
    """
    use GenServer, restart: :temporary

    alias UniversalProxy.Storage.ServerTest.Recorder

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(_opts) do
      Process.flag(:trap_exit, true)
      Recorder.record({:smbd_started})
      {:ok, %{}}
    end

    @impl true
    def terminate(_reason, state) do
      Recorder.record({:smbd_terminated})
      {:ok, state}
    end
  end

  defmodule SmbdStub do
    @moduledoc false
    alias UniversalProxy.Storage.ServerTest.{DaemonStub, Recorder}

    def available?(_opts), do: Recorder.get(:available?, true)

    def prepare_runtime(opts) do
      Recorder.record({:prepare_runtime, Keyword.fetch!(opts, :params)})
      Recorder.take(:prepare_results, {:ok, "/tmp/up-storage-server-test/smb.conf"})
    end

    def provision_user(password, opts) do
      # Exercise both persistence seams so a regression that wires them to
      # the wrong Settings server (or drops them) shows up here.
      before_hash = Keyword.fetch!(opts, :get_hash_fun).()
      put_result = Keyword.fetch!(opts, :put_hash_fun).("deadbeef")

      Recorder.record(
        {:provision_user, byte_size(password), Keyword.get(opts, :username), before_hash,
         put_result}
      )

      Recorder.take(:provision_results, {:ok, :provisioned})
    end

    def child_spec(_opts) do
      %{id: :smbd, start: {DaemonStub, :start_link, [[]]}, restart: :temporary}
    end
  end

  setup do
    start_supervised!(Recorder)

    path =
      Path.join(
        System.tmp_dir!(),
        "storage_server_test_#{System.unique_integer([:positive])}.dets"
      )

    on_exit(fn -> File.rm(path) end)

    settings =
      start_supervised!({Settings, name: nil, table: @settings_table, dets_path: path},
        id: :settings
      )

    daemon_supervisor =
      start_supervised!({DynamicSupervisor, strategy: :one_for_one}, id: :daemon_supervisor)

    :ok = Phoenix.PubSub.subscribe(@pubsub, @topic)

    {:ok, settings: settings, daemon_supervisor: daemon_supervisor}
  end

  # -- helpers --

  defp start_server(ctx, opts \\ []) do
    defaults = [
      name: nil,
      probe: ProbeStub,
      mount: MountStub,
      smbd: SmbdStub,
      settings: ctx.settings,
      daemon_supervisor: ctx.daemon_supervisor,
      read_head_fun: &read_head/1,
      netbios_name_fun: fn -> "universal-proxy-ab12cd" end,
      start_timer: false
    ]

    start_supervised!({Server, Keyword.merge(defaults, opts)}, id: :server)
  end

  defp read_head(dev_path) do
    case Map.fetch(Recorder.get(:heads, %{}), dev_path) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :enoent}
    end
  end

  defp drive(opts \\ []) do
    %{
      name: Keyword.get(opts, :name, "sda"),
      dev_path: "/dev/#{Keyword.get(opts, :name, "sda")}",
      size_bytes: 8_000_000_000,
      slot_sub: Keyword.get(opts, :slot_sub, "1-1.3"),
      vendor_id: 0x0BDA,
      product_id: 0x0316,
      partitions: [
        %{name: "sda1", dev_path: "/dev/sda1", size_bytes: 7_900_000_000}
      ]
    }
  end

  defp present!(fs_bytes \\ nil) do
    Recorder.put(:drives, [drive()])
    Recorder.put(:heads, %{"/dev/sda1" => fs_bytes || StorageFixtures.ext4_bytes()})
  end

  defp enable_share!(ctx),
    do: :ok = Settings.put_drive(ctx.settings, @drive_key, %{share_enabled?: true})

  # The folder tests touch the real filesystem under MountStub's point, so
  # every one of them starts from an empty directory.
  defp fresh_mount_root! do
    File.rm_rf!(MountStub.point())
    File.mkdir_p!(MountStub.point())
    on_exit(fn -> File.rm_rf(MountStub.point()) end)
  end

  defp in_root(path), do: Path.join(MountStub.point(), path)

  defp last_prepare_params do
    Recorder.events()
    |> Enum.filter(&match?({:prepare_runtime, _}, &1))
    |> List.last()
    |> elem(1)
  end

  # -- tests --

  describe "convergence on drive add" do
    test "an appearing drive is mounted with the sniffed filesystem", ctx do
      server = start_server(ctx)
      present!()

      :ok = Server.check_now(server)

      assert {:mount, "/dev/sda1", :ext4} in Recorder.events()

      state = Server.get_state(server)

      assert state.mount == %{
               device: "/dev/sda1",
               fs_type: :ext4,
               mode: :read_write,
               point: MountStub.point(),
               stale?: false
             }

      assert state.share == :off
      assert state.capacity == MountStub.capacity()
      assert [%{key: @drive_key, name: "sda"}] = state.drives
    end

    test "an exFAT stick is mounted as exfat", ctx do
      server = start_server(ctx)
      present!(StorageFixtures.exfat_bytes())

      :ok = Server.check_now(server)

      assert {:mount, "/dev/sda1", :exfat} in Recorder.events()
      assert Server.get_state(server).mount.fs_type == :exfat
    end

    test "a drive with no recognised filesystem is left alone", ctx do
      server = start_server(ctx)
      present!(StorageFixtures.garbage_bytes())

      :ok = Server.check_now(server)

      refute Enum.any?(Recorder.event_names(), &(&1 == :mount))
      assert Server.get_state(server).mount == nil
    end

    test "the state map is broadcast on every transition", ctx do
      server = start_server(ctx)

      # No drives: nothing changed, so nothing is broadcast.
      :ok = Server.check_now(server)
      refute_receive {:storage_state, _}, 50

      present!()
      :ok = Server.check_now(server)

      assert_receive {:storage_state, payload}
      assert payload == Server.get_state(server)

      assert %{drives: [_drive], mount: %{stale?: false}, share: :off, capacity: %{}} = payload

      # Idempotent pass: no further broadcast.
      :ok = Server.check_now(server)
      refute_receive {:storage_state, _}, 50
    end
  end

  describe "convergence on drive removal" do
    test "the share is stopped before the unmount", ctx do
      server = start_server(ctx)
      present!()
      enable_share!(ctx)
      :ok = Server.check_now(server)
      assert Server.get_state(server).share == :running

      Recorder.put(:drives, [])
      :ok = Server.check_now(server)

      names = Recorder.event_names()

      assert Enum.find_index(names, &(&1 == :smbd_terminated)) <
               Enum.find_index(names, &(&1 == :umount))

      state = Server.get_state(server)
      assert state.mount == nil
      assert state.share == :off
      assert state.capacity == nil
      assert DynamicSupervisor.which_children(ctx.daemon_supervisor) == []
    end

    test "a busy filesystem is retried lazily, then marked stale", ctx do
      server = start_server(ctx)
      present!()
      :ok = Server.check_now(server)

      busy = {:error, {:command_failed, "/bin/umount /run/usb-backup", 32, "target is busy"}}
      Recorder.put(:umount_results, [busy, busy])
      Recorder.put(:drives, [])

      log = capture_log(fn -> :ok = Server.check_now(server) end)
      assert log =~ "retrying lazily"
      assert log =~ "marking the mount stale"

      assert [{:umount, false}, {:umount, true}] =
               Enum.filter(Recorder.events(), &match?({:umount, _}, &1))

      assert Server.get_state(server).mount.stale? == true
    end

    test "a lazy umount that succeeds clears the mount", ctx do
      server = start_server(ctx)
      present!()
      :ok = Server.check_now(server)

      busy = {:error, {:command_failed, "/bin/umount /run/usb-backup", 32, "target is busy"}}
      Recorder.put(:umount_results, [busy])
      Recorder.put(:drives, [])

      capture_log(fn -> :ok = Server.check_now(server) end)

      assert Server.get_state(server).mount == nil
    end
  end

  describe "share opt-in" do
    test "enabling starts the daemon child, disabling stops it", ctx do
      server = start_server(ctx)
      present!()
      :ok = Server.check_now(server)
      assert Server.get_state(server).share == :off

      assert :ok = Server.set_share_enabled(server, @drive_key, true)

      assert Server.get_state(server).share == :running
      assert Settings.share_enabled?(ctx.settings, @drive_key)
      assert [{_id, pid, _type, _mods}] = DynamicSupervisor.which_children(ctx.daemon_supervisor)
      assert is_pid(pid)
      assert {:smbd_started} in Recorder.events()

      assert :ok = Server.set_share_enabled(server, @drive_key, false)

      assert Server.get_state(server).share == :off
      assert DynamicSupervisor.which_children(ctx.daemon_supervisor) == []
      assert {:smbd_terminated} in Recorder.events()
    end

    test "the share is prepared with the mount point, username and short netbios name", ctx do
      server = start_server(ctx)
      present!()
      enable_share!(ctx)

      :ok = Server.check_now(server)

      assert {:prepare_runtime, params} =
               Enum.find(Recorder.events(), &match?({:prepare_runtime, _}, &1))

      assert params == %{
               mount_point: MountStub.point(),
               share_folder: "/",
               username: "backup",
               netbios_name: "up-ab12cd"
             }

      # Both Settings hash seams are wired to the injected Settings server:
      # nothing recorded before the run, the marker written after it.
      assert {:provision_user, 24, "backup", nil, :ok} =
               Enum.find(Recorder.events(), &match?({:provision_user, _, _, _, _}, &1))

      assert Settings.credentials(ctx.settings).provisioned_hash == "deadbeef"
    end

    test "no daemon starts when smbd is unavailable", ctx do
      server = start_server(ctx)
      present!()
      enable_share!(ctx)
      Recorder.put(:available?, false)

      :ok = Server.check_now(server)

      assert Server.get_state(server).share == :off
      assert DynamicSupervisor.which_children(ctx.daemon_supervisor) == []
      refute Enum.any?(Recorder.event_names(), &(&1 in [:prepare_runtime, :smbd_started]))
    end

    test "a provisioning failure degrades to :error and retries next pass", ctx do
      server = start_server(ctx)
      present!()
      enable_share!(ctx)
      Recorder.put(:provision_results, [{:error, {:smbpasswd_failed, 1, "nope"}}])

      log = capture_log(fn -> :ok = Server.check_now(server) end)
      assert log =~ "smbd share start failed"

      assert Server.get_state(server).share == :error
      assert DynamicSupervisor.which_children(ctx.daemon_supervisor) == []

      :ok = Server.check_now(server)
      assert Server.get_state(server).share == :running
    end

    test "a drive with no bus path can never enable a share", ctx do
      server = start_server(ctx)
      Recorder.put(:drives, [drive(slot_sub: nil)])
      Recorder.put(:heads, %{"/dev/sda1" => StorageFixtures.ext4_bytes()})
      enable_share!(ctx)

      :ok = Server.check_now(server)

      state = Server.get_state(server)
      assert state.mount.device == "/dev/sda1"
      assert state.share == :off
      assert [%{key: nil}] = state.drives
    end
  end

  describe "format/3" do
    test "stops the share, unmounts, formats, then remounts", ctx do
      server = start_server(ctx)
      present!()
      enable_share!(ctx)
      :ok = Server.check_now(server)
      assert Server.get_state(server).share == :running

      assert :ok = Server.format(server, "/dev/sda1", "usb_backup")

      # format/3 replies before the convergence that remounts, so read the
      # state first: that call is serialized behind the continue.
      assert Server.get_state(server).mount.device == "/dev/sda1"

      names = Recorder.event_names()
      # …then a fresh mount from the convergence that follows the format.
      assert [:smbd_terminated, :umount, :format, :mount | _] =
               Enum.filter(names, &(&1 in [:smbd_terminated, :umount, :format, :mount]))
               |> Enum.drop_while(&(&1 != :smbd_terminated))

      assert {:format, "/dev/sda1", "usb_backup", true} in Recorder.events()
    end

    test "a filesystem that will not unmount is never handed to mkfs", ctx do
      server = start_server(ctx)
      present!()
      :ok = Server.check_now(server)

      busy = {:error, {:command_failed, "/bin/umount /run/usb-backup", 32, "target is busy"}}
      Recorder.put(:umount_results, [busy, busy])

      log =
        capture_log(fn ->
          assert {:error, {:umount_failed, {:error, {:command_failed, _, 32, _}}}} =
                   Server.format(server, "/dev/sda1", "usb_backup")
        end)

      assert log =~ "refusing to format"
      refute Enum.any?(Recorder.event_names(), &(&1 == :format))
    end
  end

  describe "eject/1" do
    test "unmounts and suppresses remounting until the drive is replugged", ctx do
      server = start_server(ctx)
      present!()
      :ok = Server.check_now(server)

      assert :ok = Server.eject(server)
      assert Server.get_state(server).mount == nil

      :ok = Server.check_now(server)
      assert Enum.count(Recorder.events(), &match?({:mount, _, _}, &1)) == 1

      # Physically gone, then back: the eject no longer applies.
      Recorder.put(:drives, [])
      :ok = Server.check_now(server)
      present!()
      :ok = Server.check_now(server)

      assert Enum.count(Recorder.events(), &match?({:mount, _, _}, &1)) == 2
    end

    test "ejecting nothing is an error, not a crash", ctx do
      server = start_server(ctx)
      assert Server.eject(server) == {:error, :not_mounted}
      assert Process.alive?(server)
    end
  end

  describe "hotplug fallbacks and failure isolation" do
    test "the poll fallback converges when uevents are unavailable (host)", ctx do
      # `subscribe_uevents?: false` forces the fallback branch — on the host
      # `NervesUEvent.subscribe/1` actually succeeds (nerves_uevent starts
      # its PropertyTable even here), it just never publishes an event.
      # Nothing calls check_now/1: the 25 ms poll has to do the work.
      server =
        start_server(ctx,
          start_timer: true,
          subscribe_uevents?: false,
          poll_interval: 25,
          retry_interval: 10_000
        )

      present!()

      assert_receive {:storage_state, %{mount: %{device: "/dev/sda1"}}}, 2_000
      assert Server.get_state(server).mount.fs_type == :ext4
    end

    test "a raising probe leaves the server alive and degraded", ctx do
      server = start_server(ctx)
      Recorder.put(:drives, :raise)

      log = capture_log(fn -> :ok = Server.check_now(server) end)
      assert log =~ "Probe.list_drives raised"

      assert Server.get_state(server) == %{
               drives: [],
               mount: nil,
               share: :off,
               share_folder: "/",
               capacity: nil
             }

      assert Process.alive?(server)
    end

    test "a block uevent schedules one debounced convergence", ctx do
      server = start_server(ctx, debounce_ms: 20)
      present!()

      send(server, %PropertyTable.Event{
        table: NervesUEvent,
        property: ["devices", "virtual", "block", "sda"],
        value: %{},
        timestamp: System.monotonic_time()
      })

      # A non-block event must not trigger anything.
      send(server, %PropertyTable.Event{
        table: NervesUEvent,
        property: ["devices", "virtual", "net", "eth0"],
        value: %{},
        timestamp: System.monotonic_time()
      })

      assert_receive {:storage_state, %{mount: %{device: "/dev/sda1"}}}, 1_000
      assert Enum.count(Recorder.events(), &match?({:mount, _, _}, &1)) == 1
    end
  end

  describe "set_share_folder/3" do
    setup do
      fresh_mount_root!()
      :ok
    end

    test "the drive root is the default and rides along in the state map", ctx do
      server = start_server(ctx)
      present!()

      :ok = Server.check_now(server)

      assert Server.get_state(server).share_folder == "/"
    end

    test "persists the mapping and restarts a running share against the new path", ctx do
      server = start_server(ctx)
      present!()
      enable_share!(ctx)
      :ok = Server.check_now(server)
      assert Server.get_state(server).share == :running
      assert last_prepare_params().share_folder == "/"

      File.mkdir_p!(in_root("backups/ha"))

      assert :ok = Server.set_share_folder(server, @drive_key, "backups/ha")

      # get_state is serialized behind the convergence the call continues into.
      state = Server.get_state(server)
      assert state.share == :running
      assert state.share_folder == "backups/ha"
      assert Settings.get_drive(ctx.settings, @drive_key).share_folder == "backups/ha"

      # The daemon cycled: one termination between two starts, and the
      # config was regenerated with the new folder in between.
      names = Recorder.event_names()
      assert Enum.count(names, &(&1 == :smbd_started)) == 2
      assert Enum.count(names, &(&1 == :smbd_terminated)) == 1
      assert last_prepare_params().share_folder == "backups/ha"

      assert [_daemon] = DynamicSupervisor.which_children(ctx.daemon_supervisor)
      assert_receive {:storage_state, %{share_folder: "backups/ha", share: :running}}
    end

    test "mapping back to the root restarts the share at the mount point", ctx do
      server = start_server(ctx)
      present!()
      enable_share!(ctx)
      File.mkdir_p!(in_root("backups"))
      :ok = Server.check_now(server)

      assert :ok = Server.set_share_folder(server, @drive_key, "backups")
      assert Server.get_state(server).share_folder == "backups"

      assert :ok = Server.set_share_folder(server, @drive_key, "/")

      assert Server.get_state(server).share_folder == "/"
      assert last_prepare_params().share_folder == "/"
    end

    test "a folder change for a drive that is not the shared one leaves smbd alone", ctx do
      server = start_server(ctx)
      present!()
      enable_share!(ctx)
      File.mkdir_p!(in_root("backups"))
      :ok = Server.check_now(server)

      other_key = {"1-1.4", "0bda", "0316"}
      assert :ok = Server.set_share_folder(server, other_key, "backups")

      assert Server.get_state(server).share_folder == "/"
      assert Settings.get_drive(ctx.settings, other_key).share_folder == "backups"
      assert Recorder.event_names() |> Enum.count(&(&1 == :smbd_started)) == 1
      refute :smbd_terminated in Recorder.event_names()
    end

    test "traversal, absolute and empty-segment paths are refused and nothing is persisted",
         ctx do
      server = start_server(ctx)
      present!()
      :ok = Server.check_now(server)

      for path <- ["../x", "a/../..", "..", "/etc", "backups//ha", "./backups"] do
        assert Server.set_share_folder(server, @drive_key, path) == {:error, :invalid_path},
               "expected #{inspect(path)} to be refused"
      end

      assert Settings.get_drive(ctx.settings, @drive_key).share_folder == "/"
      assert Server.get_state(server).share_folder == "/"
      assert Process.alive?(server)
    end

    test "a folder that does not exist on the drive is refused", ctx do
      server = start_server(ctx)
      present!()
      :ok = Server.check_now(server)

      assert Server.set_share_folder(server, @drive_key, "nope") == {:error, :enoent}
      assert Settings.get_drive(ctx.settings, @drive_key).share_folder == "/"
    end

    test "a plain file on the drive is not a folder", ctx do
      server = start_server(ctx)
      present!()
      :ok = Server.check_now(server)
      File.write!(in_root("readme.txt"), "hi")

      assert Server.set_share_folder(server, @drive_key, "readme.txt") == {:error, :enoent}
    end

    test "nothing mounted means nothing to map", ctx do
      server = start_server(ctx)

      assert Server.set_share_folder(server, @drive_key, "backups") == {:error, :not_mounted}
    end
  end

  describe "list_folders/2" do
    setup do
      fresh_mount_root!()
      :ok
    end

    test "lists sorted subdirectories, skipping files and dot-directories", ctx do
      server = start_server(ctx)
      present!()
      :ok = Server.check_now(server)

      File.mkdir_p!(in_root("photos"))
      File.mkdir_p!(in_root("backups"))
      File.mkdir_p!(in_root(".Trashes"))
      File.write!(in_root("readme.txt"), "hi")

      assert Server.list_folders(server, "/") == {:ok, ["backups", "photos"]}
      assert Server.list_folders(server, "") == {:ok, ["backups", "photos"]}
    end

    test "descends into a subdirectory", ctx do
      server = start_server(ctx)
      present!()
      :ok = Server.check_now(server)
      File.mkdir_p!(in_root("backups/ha"))
      File.mkdir_p!(in_root("backups/old"))

      assert Server.list_folders(server, "backups") == {:ok, ["ha", "old"]}
      assert Server.list_folders(server, "backups/ha") == {:ok, []}
    end

    test "a path that would escape the mount point is refused, never listed", ctx do
      server = start_server(ctx)
      present!()
      :ok = Server.check_now(server)

      for path <- ["..", "../..", "backups/../..", "/etc", "/tmp", "a/../../../etc"] do
        assert Server.list_folders(server, path) == {:error, :invalid_path},
               "expected #{inspect(path)} to be refused"
      end

      assert Process.alive?(server)
    end

    test "nothing mounted is reported, not crashed", ctx do
      server = start_server(ctx)

      assert Server.list_folders(server, "/") == {:error, :not_mounted}
    end

    test "a symlink on the drive is neither listed nor traversable nor mappable", ctx do
      server = start_server(ctx)
      present!()
      :ok = Server.check_now(server)
      File.mkdir_p!(in_root("backups"))
      # What a malicious stick would carry: the sandbox's prefix check
      # cannot see through this, so components are lstat-ed instead.
      File.ln_s!("/etc", in_root("escape"))

      assert Server.list_folders(server, "/") == {:ok, ["backups"]}
      assert Server.list_folders(server, "escape") == {:error, :invalid_path}
      assert Server.set_share_folder(server, @drive_key, "escape") == {:error, :invalid_path}
      assert Server.create_folder(server, "escape", "x") == {:error, :invalid_path}
    end

    test "a directory that disappeared surfaces the posix error", ctx do
      server = start_server(ctx)
      present!()
      :ok = Server.check_now(server)

      assert Server.list_folders(server, "gone") == {:error, :enoent}
    end
  end

  describe "create_folder/3" do
    setup do
      fresh_mount_root!()
      :ok
    end

    test "creates the directory, chowns it to the backup account, and returns its path", ctx do
      server = start_server(ctx)
      present!()
      :ok = Server.check_now(server)

      assert Server.create_folder(server, "/", "backups") == {:ok, "backups"}
      assert File.dir?(in_root("backups"))
      assert {:chown_backup, in_root("backups")} in Recorder.events()

      assert Server.create_folder(server, "backups", "ha") == {:ok, "backups/ha"}
      assert File.dir?(in_root("backups/ha"))
      assert {:chown_backup, in_root("backups/ha")} in Recorder.events()
    end

    test "the created path is directly usable as the share folder", ctx do
      server = start_server(ctx)
      present!()
      :ok = Server.check_now(server)

      assert {:ok, created} = Server.create_folder(server, "/", "backups")
      assert :ok = Server.set_share_folder(server, @drive_key, created)
      assert Server.get_state(server).share_folder == "backups"
    end

    test "a filesystem with no Unix ownership is not chowned", ctx do
      server = start_server(ctx)
      present!(StorageFixtures.exfat_bytes())
      :ok = Server.check_now(server)

      assert Server.create_folder(server, "/", "backups") == {:ok, "backups"}
      refute :chown_backup in Recorder.event_names()
    end

    test "a failed chown warns but keeps the created directory", ctx do
      server = start_server(ctx)
      present!()
      :ok = Server.check_now(server)
      Recorder.put(:chown_results, [{:error, :eperm}])

      log =
        capture_log(fn ->
          assert Server.create_folder(server, "/", "backups") == {:ok, "backups"}
        end)

      assert log =~ "chown of"
      assert File.dir?(in_root("backups"))
    end

    test "a duplicate name comes back as :eexist", ctx do
      server = start_server(ctx)
      present!()
      :ok = Server.check_now(server)

      assert Server.create_folder(server, "/", "backups") == {:ok, "backups"}
      assert Server.create_folder(server, "/", "backups") == {:error, :eexist}
    end

    test "every character class the design forbids is rejected", ctx do
      server = start_server(ctx)
      present!()
      :ok = Server.check_now(server)

      for name <- ["a\\b", "a/b", "a:b", "a*b", "a?b", "a\"b", "a<b", "a>b", "a|b", "a\nb"] do
        assert Server.create_folder(server, "/", name) == {:error, :invalid_name},
               "expected #{inspect(name)} to be refused"
      end

      assert Server.create_folder(server, "/", "") == {:error, :invalid_name}
      assert Server.create_folder(server, "/", "   ") == {:error, :invalid_name}
      assert Server.create_folder(server, "/", ".") == {:error, :invalid_name}
      assert Server.create_folder(server, "/", "..") == {:error, :invalid_name}
      assert Server.create_folder(server, "/", "a\tb") == {:error, :invalid_name}
      # Not valid UTF-8: rejected, never raised on.
      assert Server.create_folder(server, "/", <<"a", 0xFF, "b">>) == {:error, :invalid_name}

      assert Server.create_folder(server, "/", String.duplicate("a", 65)) ==
               {:error, :name_too_long}

      assert Server.create_folder(server, "/", String.duplicate("a", 64)) ==
               {:ok, String.duplicate("a", 64)}

      assert File.ls!(MountStub.point()) == [String.duplicate("a", 64)]
    end

    test "the parent path is sandboxed too", ctx do
      server = start_server(ctx)
      present!()
      :ok = Server.check_now(server)

      assert Server.create_folder(server, "..", "escaped") == {:error, :invalid_path}
      assert Server.create_folder(server, "/etc", "escaped") == {:error, :invalid_path}
      refute File.exists?(Path.join(Path.dirname(MountStub.point()), "escaped"))
    end

    test "nothing mounted means nothing to create in", ctx do
      server = start_server(ctx)

      assert Server.create_folder(server, "/", "backups") == {:error, :not_mounted}
    end
  end
end
