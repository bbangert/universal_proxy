defmodule UniversalProxy.Storage.ServerTest do
  # async: false — the stubs share one named Recorder Agent and the test
  # subscribes to the global `"storage:state"` topic; concurrent tests
  # would see each other's events and broadcasts.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias UniversalProxy.Storage.{Server, Settings, Smbd}
  alias UniversalProxy.StorageFixtures

  @pubsub UniversalProxy.PubSub
  @topic "storage:state"
  @settings_table :storage_server_test

  # Probe reports vid/pid as integers; Storage.Settings keys them as
  # lowercase 4-digit hex strings, which is what Server derives. The
  # fourth element is the USB serial: the key names one medium, not every
  # stick of that model in that port.
  @sda_serial "SN-SDA-0001"
  @nvme_serial "SN-NVME-0001"
  @drive_key {"1-1.3", "0bda", "0316", @sda_serial}
  @nvme_key {"1-1.4", "0bda", "0316", @nvme_serial}

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

      # Optional gate: with `:format_gate` set to a pid, `mkfs` blocks
      # inside the server's handle_call until that pid releases it, which
      # is how a test observes what a concurrent call does meanwhile.
      case Recorder.get(:format_gate, nil) do
        pid when is_pid(pid) ->
          send(pid, {:format_started, self()})

          receive do
            :release_format -> :ok
          after
            5_000 -> :ok
          end

        _no_gate ->
          :ok
      end

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

      # Opt-in simulation of a `smbd` that exits on its own the instant it
      # starts (a bad config, a missing shared library): schedules its own
      # crash rather than crashing from `init/1`, so the child still starts
      # cleanly (`DynamicSupervisor.start_child/2` returns `{:ok, pid}` and
      # the server gets to `Process.monitor/1` it) before it dies.
      if Recorder.get(:crash_instantly?, false) do
        send(self(), :simulate_instant_crash)
      end

      {:ok, %{}}
    end

    @impl true
    def handle_info(:simulate_instant_crash, state), do: {:stop, :simulated_crash, state}

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

      username = Keyword.get(opts, :username)

      Recorder.record({:provision_user, byte_size(password), username, before_hash, put_result})

      # The password itself is never recorded; its provisioning hash is,
      # which is all a test needs to tell one password from another.
      Recorder.record(
        {:provision_hash, UniversalProxy.Storage.Smbd.provision_hash(username, password)}
      )

      Recorder.take(:provision_results, {:ok, :provisioned})
    end

    def child_spec(_opts) do
      %{id: :smbd, start: {DaemonStub, :start_link, [[]]}, restart: :temporary}
    end
  end

  setup do
    start_supervised!(Recorder)

    # A real mount point exists whenever something is mounted, and the
    # share-folder revalidation that runs before every share start checks
    # it (Server.validated_share_folder/1), so the stub's point has to be
    # a real directory here too.
    File.mkdir_p!(MountStub.point())
    on_exit(fn -> File.rm_rf(MountStub.point()) end)

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
    name = Keyword.get(opts, :name, "sda")

    %{
      name: name,
      dev_path: "/dev/#{name}",
      size_bytes: 8_000_000_000,
      slot_sub: Keyword.get(opts, :slot_sub, "1-1.3"),
      vendor_id: 0x0BDA,
      product_id: 0x0316,
      serial: Keyword.get(opts, :serial, @sda_serial),
      partitions:
        Keyword.get(opts, :partitions, [
          %{name: "sda1", dev_path: "/dev/sda1", size_bytes: 7_900_000_000}
        ])
    }
  end

  # An NVMe enclosure. `Probe` sorts by device name, so "nvme0n1" comes
  # back *before* "sda" — which is the reordering these tests turn on.
  defp nvme_drive do
    drive(
      name: "nvme0n1",
      slot_sub: "1-1.4",
      serial: @nvme_serial,
      partitions: [
        %{name: "nvme0n1p1", dev_path: "/dev/nvme0n1p1", size_bytes: 900_000_000_000}
      ]
    )
  end

  # sda mounted, then the NVMe enclosure plugged in behind it.
  defp attach_nvme! do
    Recorder.put(:drives, [nvme_drive(), drive()])

    Recorder.put(:heads, %{
      "/dev/sda1" => StorageFixtures.ext4_bytes(),
      "/dev/nvme0n1p1" => StorageFixtures.ext4_bytes()
    })
  end

  defp present!(fs_bytes \\ nil) do
    Recorder.put(:drives, [drive()])
    Recorder.put(:heads, %{"/dev/sda1" => fs_bytes || StorageFixtures.ext4_bytes()})
  end

  defp enable_share!(ctx),
    do: :ok = Settings.put_drive(ctx.settings, @drive_key, %{share_enabled?: true})

  defp set_stored_folder!(ctx, folder),
    do: :ok = Settings.put_drive(ctx.settings, @drive_key, %{share_folder: folder})

  # The folder tests touch the real filesystem under MountStub's point, so
  # every one of them starts from an empty directory.
  defp fresh_mount_root! do
    File.rm_rf!(MountStub.point())
    File.mkdir_p!(MountStub.point())
    on_exit(fn -> File.rm_rf(MountStub.point()) end)
  end

  defp in_root(path), do: Path.join(MountStub.point(), path)

  # Stand-in for /proc/self/mounts. A real file, so a test can rewrite it
  # mid-run and have the server see the kernel's view change.
  defp mounts_file!(lines) do
    path =
      Path.join(
        System.tmp_dir!(),
        "storage_server_mounts_#{System.unique_integer([:positive])}"
      )

    File.write!(path, Enum.map_join(lines, "", &(&1 <> "\n")))
    on_exit(fn -> File.rm(path) end)

    path
  end

  defp provision_hashes, do: for({:provision_hash, hash} <- Recorder.events(), do: hash)

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

  describe "capacity refresh while mounted" do
    test "a changed capacity reading is picked up and broadcast within the tick", ctx do
      server =
        start_server(ctx, start_timer: true, capacity_interval: 30, retry_interval: 10_000)

      present!()
      :ok = Server.check_now(server)

      assert_receive {:storage_state,
                      %{mount: %{device: "/dev/sda1"}, capacity: %{used_pct: 10}}},
                     1_000

      # A backup written straight to the mounted filesystem (no mount,
      # unmount, share transition, or manual op) — nothing but the tick
      # would ever see this.
      Recorder.put(
        :capacity,
        {:ok, %{total_bytes: 1_000, used_bytes: 460, free_bytes: 540, used_pct: 46}}
      )

      assert_receive {:storage_state, %{capacity: %{used_pct: 46}}}, 1_000
      assert Server.get_state(server).capacity.used_pct == 46
    end

    test "no broadcast when the tick's capacity reading is unchanged", ctx do
      server =
        start_server(ctx, start_timer: true, capacity_interval: 30, retry_interval: 10_000)

      present!()
      :ok = Server.check_now(server)
      assert_receive {:storage_state, %{mount: %{device: "/dev/sda1"}}}, 1_000

      # Long enough for several ticks at 30 ms; the payload never moves,
      # so none of them may broadcast.
      refute_receive {:storage_state, _}, 200

      assert Enum.count(Recorder.events(), &match?({:capacity}, &1)) > 1
    end

    test "the tick stops once the drive is ejected", ctx do
      server =
        start_server(ctx, start_timer: true, capacity_interval: 30, retry_interval: 10_000)

      present!()
      :ok = Server.check_now(server)
      assert_receive {:storage_state, %{mount: %{device: "/dev/sda1"}}}, 1_000

      # Let at least one tick land before ejecting, proving the timer was
      # actually running.
      Process.sleep(60)
      before_count = Enum.count(Recorder.events(), &match?({:capacity}, &1))
      assert before_count > 0

      # `eject/2` unmounts synchronously (before the convergence pass it
      # triggers even starts), so the transition is visible on the reply
      # without waiting on a broadcast.
      assert :ok = Server.eject(server, @drive_key)
      assert Server.get_state(server).mount == nil

      # One tick may already have been in flight when the eject landed —
      # `tick_capacity/1` re-checks `mounted?/1` before re-arming itself,
      # so at most that single read is allowed through afterwards.
      just_after_eject = Enum.count(Recorder.events(), &match?({:capacity}, &1))

      # Long enough for several more ticks, if the timer were (wrongly)
      # still armed.
      Process.sleep(150)
      after_count = Enum.count(Recorder.events(), &match?({:capacity}, &1))

      assert after_count - just_after_eject == 0
      assert just_after_eject - before_count <= 1
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

    # The hotplug debounce can coalesce a removal and the insertion that
    # follows it into a single convergence, so this is the swap as the
    # server really sees it: one pass in which the same port, model and
    # device path are occupied by a different medium. Without the serial in
    # the key the replacement would read back the predecessor's opt-in and
    # auto-share — with the predecessor's credentials — a drive nobody
    # opted in.
    test "a same-model stick swapped into the port does not inherit the opt-in", ctx do
      server = start_server(ctx)
      present!()
      enable_share!(ctx)
      :ok = Server.check_now(server)
      assert Server.get_state(server).share == :running

      Recorder.put(:drives, [drive(serial: "SN-SDA-0002")])
      :ok = Server.check_now(server)

      state = Server.get_state(server)
      assert [%{key: {"1-1.3", "0bda", "0316", "SN-SDA-0002"}}] = state.drives
      # Mounted (it is a drive like any other) but NOT shared.
      assert state.mount.device == "/dev/sda1"
      assert state.share == :off
      assert DynamicSupervisor.which_children(ctx.daemon_supervisor) == []
      # And the predecessor's opt-in is untouched: re-plugging it shares again.
      assert Settings.share_enabled?(ctx.settings, @drive_key)
      refute Settings.share_enabled?(ctx.settings, {"1-1.3", "0bda", "0316", "SN-SDA-0002"})
    end

    test "opting the replacement in keys against its own serial", ctx do
      server = start_server(ctx)
      replacement_key = {"1-1.3", "0bda", "0316", "SN-SDA-0002"}
      Recorder.put(:drives, [drive(serial: "SN-SDA-0002")])
      Recorder.put(:heads, %{"/dev/sda1" => StorageFixtures.ext4_bytes()})
      :ok = Server.check_now(server)

      assert :ok = Server.set_share_enabled(server, replacement_key, true)

      assert Server.get_state(server).share == :running
      assert Settings.share_enabled?(ctx.settings, replacement_key)
      # The stick it replaced stays opted out.
      refute Settings.share_enabled?(ctx.settings, @drive_key)
    end

    # A stick with no `serial` attribute keys as `serial: nil` — the one
    # case the per-medium key cannot separate, kept explicit so the
    # limitation is a tested fact and not a surprise.
    test "two serial-less same-model sticks still share one key", ctx do
      server = start_server(ctx)
      serial_less_key = {"1-1.3", "0bda", "0316", nil}
      Recorder.put(:drives, [drive(serial: nil)])
      Recorder.put(:heads, %{"/dev/sda1" => StorageFixtures.ext4_bytes()})
      :ok = Settings.put_drive(ctx.settings, serial_less_key, %{share_enabled?: true})

      :ok = Server.check_now(server)

      assert [%{key: ^serial_less_key}] = Server.get_state(server).drives
      assert Server.get_state(server).share == :running
    end
  end

  describe "format/3" do
    test "stops the share, unmounts, formats, then remounts", ctx do
      server = start_server(ctx)
      present!()
      enable_share!(ctx)
      :ok = Server.check_now(server)
      assert Server.get_state(server).share == :running

      assert :ok = Server.format(server, @drive_key, "usb_backup")

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
                   Server.format(server, @drive_key, "usb_backup")
        end)

      assert log =~ "refusing to format"
      refute Enum.any?(Recorder.event_names(), &(&1 == :format))

      # Exactly one plain umount, and no lazy retry: a lazy detach leaves
      # the kernel holding the filesystem mkfs would overwrite, so it must
      # never sneak in on this path (the second queued busy result is
      # deliberately left unconsumed).
      assert [{:umount, false}] = Enum.filter(Recorder.events(), &match?({:umount, _}, &1))
      assert Server.get_state(server).mount.stale? == false
    end

    test "the mounted partition is formatted, never the whole disk under it", ctx do
      server = start_server(ctx)
      present!()
      :ok = Server.check_now(server)
      assert Server.get_state(server).mount.device == "/dev/sda1"

      assert :ok = Server.format(server, @drive_key, "usb_backup")

      # The caller named the drive; the server resolved the device. The
      # whole disk ("/dev/sda") must never reach mkfs while its partition
      # is the mount — that would take the partition table with it.
      assert {:format, "/dev/sda1", "usb_backup", true} in Recorder.events()
      refute Enum.any?(Recorder.events(), &match?({:format, "/dev/sda", _label, _confirm}, &1))
    end

    test "an unmounted drive is formatted at its first data partition", ctx do
      server = start_server(ctx)
      present!()
      :ok = Server.check_now(server)
      assert :ok = Server.eject(server, @drive_key)
      assert Server.get_state(server).mount == nil

      assert :ok = Server.format(server, @drive_key, "usb_backup")

      assert {:format, "/dev/sda1", "usb_backup", true} in Recorder.events()
    end

    test "a drive with no recognised filesystem is formatted as a whole disk", ctx do
      server = start_server(ctx)
      present!(StorageFixtures.garbage_bytes())
      :ok = Server.check_now(server)
      assert Server.get_state(server).mount == nil

      assert :ok = Server.format(server, @drive_key, "usb_backup")

      assert {:format, "/dev/sda", "usb_backup", true} in Recorder.events()
    end

    test "a key that is not the attached drive's is refused, and nothing is formatted", ctx do
      server = start_server(ctx)
      present!()
      :ok = Server.check_now(server)

      log =
        capture_log(fn ->
          assert Server.format(server, {"9-9", "dead", "beef", "SN-OTHER"}, "usb_backup") ==
                   {:error, :unknown_drive}

          assert Server.format(server, nil, "usb_backup") == {:error, :unknown_drive}
        end)

      assert log =~ "refusing to format"
      refute :format in Recorder.event_names()
      # The share and mount were left alone: nothing was torn down for a
      # format that never happened.
      assert Server.get_state(server).mount.device == "/dev/sda1"
    end

    test "a drive with no bus path is formatted by its nil key", ctx do
      server = start_server(ctx)
      Recorder.put(:drives, [drive(slot_sub: nil)])
      Recorder.put(:heads, %{"/dev/sda1" => StorageFixtures.ext4_bytes()})
      :ok = Server.check_now(server)

      assert :ok = Server.format(server, nil, "usb_backup")
      assert {:format, "/dev/sda1", "usb_backup", true} in Recorder.events()
    end
  end

  describe "stored share folder revalidation" do
    setup do
      fresh_mount_root!()
      :ok
    end

    test "a stored folder that no longer exists keeps the share in :error", ctx do
      server = start_server(ctx)
      present!()
      enable_share!(ctx)
      # Persisted while it existed; gone by the time the share starts —
      # exactly what a stick edited on another machine looks like.
      set_stored_folder!(ctx, "backups/ha")

      log = capture_log(fn -> :ok = Server.check_now(server) end)

      assert log =~ "invalid_share_folder"
      state = Server.get_state(server)
      assert state.share == :error
      # Never a silent fall back to the drive root: smbd was not even
      # configured, let alone started.
      assert state.share_folder == "backups/ha"
      refute :prepare_runtime in Recorder.event_names()
      refute :smbd_started in Recorder.event_names()

      # The directory reappearing is all the next pass needs.
      File.mkdir_p!(in_root("backups/ha"))
      :ok = Server.check_now(server)

      assert Server.get_state(server).share == :running
      assert last_prepare_params().share_folder == "backups/ha"
    end

    test "a stored folder replaced by a symlink is refused", ctx do
      server = start_server(ctx)
      present!()
      enable_share!(ctx)
      set_stored_folder!(ctx, "backups")
      File.ln_s!("/etc", in_root("backups"))

      log = capture_log(fn -> :ok = Server.check_now(server) end)

      assert log =~ "invalid_share_folder"
      assert Server.get_state(server).share == :error
      refute :smbd_started in Recorder.event_names()
    end

    test "credentials that could not be persisted keep the share in :error", ctx do
      # A Settings whose credentials write fails but whose per-drive writes
      # succeed, so the share is opted in and only the secret is missing.
      path =
        Path.join(
          System.tmp_dir!(),
          "storage_server_nopersist_#{System.unique_integer([:positive])}.dets"
        )

      on_exit(fn -> File.rm(path) end)

      settings =
        start_supervised!(
          {Settings,
           name: nil,
           table: :storage_server_test_nopersist,
           dets_path: path,
           persist_fun: fn
             _table, {:credentials, _creds} -> {:error, :enospc}
             table, record -> with :ok <- :dets.insert(table, record), do: :dets.sync(table)
           end},
          id: :nopersist_settings
        )

      server = start_server(ctx, settings: settings)
      present!()
      :ok = Settings.put_drive(settings, @drive_key, %{share_enabled?: true})

      log = capture_log(fn -> :ok = Server.check_now(server) end)

      assert log =~ "credentials_unavailable"
      assert Server.get_state(server).share == :error
      refute :smbd_started in Recorder.event_names()
    end
  end

  describe "credentials_rotated/1" do
    test "a running share is cycled and reprovisioned with the new password", ctx do
      server = start_server(ctx)
      present!()
      enable_share!(ctx)
      :ok = Server.check_now(server)
      assert Server.get_state(server).share == :running
      assert [first_hash] = provision_hashes()

      rotated = Settings.rotate_password(ctx.settings)
      assert :ok = Server.credentials_rotated(server)

      # get_state is serialized behind the convergence the call continues
      # into, so the restart has already happened by the time this replies.
      assert Server.get_state(server).share == :running

      names = Recorder.event_names()
      assert Enum.count(names, &(&1 == :smbd_terminated)) == 1
      assert Enum.count(names, &(&1 == :smbd_started)) == 2

      assert [^first_hash, second_hash] = provision_hashes()
      assert second_hash == Smbd.provision_hash("backup", rotated.password)
      refute second_hash == first_hash
    end

    test "with no share running it is a plain convergence, not an error", ctx do
      server = start_server(ctx)
      present!()
      :ok = Server.check_now(server)

      assert :ok = Server.credentials_rotated(server)

      assert Server.get_state(server).share == :off
      refute :smbd_terminated in Recorder.event_names()
      assert Process.alive?(server)
    end
  end

  describe "eject/2" do
    test "unmounts and suppresses remounting until the drive is replugged", ctx do
      server = start_server(ctx)
      present!()
      :ok = Server.check_now(server)

      assert :ok = Server.eject(server, @drive_key)
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

    test "ejecting a drive that has no mount is an error, not a crash", ctx do
      server = start_server(ctx)
      # Attached, but with a filesystem nothing recognises, so unmounted.
      Recorder.put(:drives, [drive()])
      :ok = Server.check_now(server)

      assert Server.eject(server, @drive_key) == {:error, :not_mounted}
      assert Process.alive?(server)
    end

    test "a key that is not the attached drive's is refused, and nothing is unmounted", ctx do
      server = start_server(ctx)
      present!()
      enable_share!(ctx)
      :ok = Server.check_now(server)

      log =
        capture_log(fn ->
          assert Server.eject(server, {"2-1.4", "1234", "5678", "SN-OTHER"}) ==
                   {:error, :unknown_drive}

          assert Server.eject(server, nil) == {:error, :unknown_drive}
        end)

      assert log =~ "refusing to eject"
      refute Enum.any?(Recorder.event_names(), &(&1 == :umount))

      state = Server.get_state(server)
      assert state.mount.device == "/dev/sda1"
      assert state.share == :running
    end

    # A lazy umount is not a flush and not a detach the user can act on,
    # so "safe to unplug" must never be said on the back of one.
    test "a busy filesystem refuses the eject instead of detaching lazily", ctx do
      server = start_server(ctx)
      present!()
      enable_share!(ctx)
      :ok = Server.check_now(server)
      assert Server.get_state(server).share == :running

      busy = {:error, {:command_failed, "/bin/umount /run/usb-backup", 32, "target is busy"}}
      Recorder.put(:umount_results, [busy, busy])

      log = capture_log(fn -> assert Server.eject(server, @drive_key) == {:error, :busy} end)

      assert log =~ "eject refused"
      # One plain umount, no lazy retry.
      assert [{:umount, false}] = Enum.filter(Recorder.events(), &match?({:umount, _}, &1))

      state = Server.get_state(server)
      # Still mounted, not stale, and the share the eject stopped on the
      # way in is back: a refused eject leaves nothing half-done.
      assert state.mount.device == "/dev/sda1"
      assert state.mount.stale? == false
      assert state.share == :running

      # And no eject suppression: the next pass keeps the drive mounted
      # rather than treating it as ejected.
      :ok = Server.check_now(server)
      assert Server.get_state(server).mount.device == "/dev/sda1"
    end

    # There is no format-in-flight flag: `mkfs` runs inside handle_call, so
    # a concurrent eject waits in the mailbox. This pins that guarantee.
    test "an eject that arrives during a format waits for it", ctx do
      server = start_server(ctx)
      present!()
      :ok = Server.check_now(server)

      Recorder.put(:format_gate, self())
      format = Task.async(fn -> Server.format(server, @drive_key, "usb_backup") end)
      assert_receive {:format_started, _server_pid}, 1_000

      eject = Task.async(fn -> Server.eject(server, @drive_key) end)
      # The server is inside mkfs, so the eject cannot have been served.
      assert Task.yield(eject, 100) == nil

      # The server is blocked in a selective receive inside the stub, so
      # the release jumps the queued eject call.
      send(server, :release_format)
      assert Task.await(format, 2_000) == :ok
      assert Task.await(eject, 2_000) == :ok

      # Serialized end to end: the format's umount, the mkfs, the remount
      # from the convergence that follows it, and only then the eject's
      # umount.
      assert [:umount, :format, :mount, :umount] =
               Recorder.event_names()
               |> Enum.filter(&(&1 in [:umount, :format, :mount]))
               |> Enum.drop_while(&(&1 != :umount))
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

      other_key = @nvme_key
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

    test "a selected folder is chowned to the backup account on ext4", ctx do
      server = start_server(ctx)
      present!()
      :ok = Server.check_now(server)
      # Made by another machine, so owned by another uid: without the chown
      # smbd's `force user` could not write into it.
      File.mkdir_p!(in_root("backups"))

      assert :ok = Server.set_share_folder(server, @drive_key, "backups")

      assert {:chown_backup, in_root("backups")} in Recorder.events()
    end

    test "a filesystem with no Unix ownership is not chowned on select", ctx do
      server = start_server(ctx)
      present!(StorageFixtures.exfat_bytes())
      :ok = Server.check_now(server)
      File.mkdir_p!(in_root("backups"))

      assert :ok = Server.set_share_folder(server, @drive_key, "backups")

      refute :chown_backup in Recorder.event_names()
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

  describe "control bytes in a path are refused (CRLF path-smuggling regression)" do
    setup do
      fresh_mount_root!()
      :ok
    end

    # `String.trim/1` (in `path_segments/1`) only strips whitespace from
    # the two ends of the *whole* path string, so a control byte embedded
    # in a segment that is not at either edge — like `"\n.."` as the
    # second segment of `"safe/\n../etc"` — used to survive segment
    # rejection unchanged: it is not literally `".."`. `Smbd.config/1`
    # then strips CR/LF from the *joined* share path when it writes
    # `smb.conf` (to keep a name from injecting a config directive), which
    # turned that same segment into a literal `".."` smbd would resolve at
    # the filesystem level — a mount escape this sandbox never validated.
    # Every one of these must be refused before expansion, by every
    # path-taking call.
    test "a segment containing a control byte is refused by every path-taking call", ctx do
      server = start_server(ctx)
      present!()
      :ok = Server.check_now(server)

      paths = [
        "\n..",
        "a\r\nb",
        <<0>>,
        # The actual escape this closes: not literally ".." here, but
        # becomes ".." once Smbd.config/1's CRLF-strip runs on it.
        "safe/\n../etc",
        <<"backups/a", 0, "b">>
      ]

      for path <- paths do
        assert Server.list_folders(server, path) == {:error, :invalid_path},
               "expected #{inspect(path)} to be refused by list_folders/2"

        assert Server.set_share_folder(server, @drive_key, path) == {:error, :invalid_path},
               "expected #{inspect(path)} to be refused by set_share_folder/3"

        assert Server.create_folder(server, path, "x") == {:error, :invalid_path},
               "expected #{inspect(path)} to be refused by create_folder/3's rel_path"
      end

      assert Settings.get_drive(ctx.settings, @drive_key).share_folder == "/"
      assert Process.alive?(server)
    end

    # Golden test: the sandbox's job is to make sure the folder it
    # accepts and persists is exactly the folder Smbd ends up serving —
    # not merely "some folder within the mount". A folder Server has
    # validated contains no control bytes (the fix above), so nothing
    # `Smbd.config/1`'s CRLF-strip does can alter it: the configured
    # `[usb_backup]` path is byte-identical to the validated one.
    test "the folder Server validates and stores is what Smbd emits verbatim in smb.conf",
         ctx do
      server = start_server(ctx)
      present!()
      :ok = Server.check_now(server)
      File.mkdir_p!(in_root("backups/ha"))

      assert :ok = Server.set_share_folder(server, @drive_key, "backups/ha")

      validated = Server.get_state(server).share_folder
      assert validated == "backups/ha"

      conf =
        Smbd.config(%{
          mount_point: MountStub.point(),
          username: "backup",
          netbios_name: "node",
          share_folder: validated
        })

      expected_path = MountStub.point() <> "/" <> validated
      assert expected_path == in_root("backups/ha")
      assert conf =~ "path = #{expected_path}"
    end
  end

  describe "smbd child lifecycle" do
    # `Smbd.child_spec/1` is `restart: :temporary` so that this server, not
    # the DynamicSupervisor, decides when smbd comes back — a supervisor
    # restart would resurrect it under a new pid the server never learns.
    # A crash must not restart the daemon from inside the very handler
    # that noticed it: a `smbd` that dies instantly would otherwise
    # spawn/crash/log in a tight loop, bypassing `:retry_interval` pacing
    # entirely.
    test "a daemon that dies on its own is not restarted within the same converge cycle", ctx do
      server = start_server(ctx)
      present!()
      enable_share!(ctx)
      :ok = Server.check_now(server)

      assert Server.get_state(server).share == :running

      assert [{_id, first, _type, _mods}] =
               DynamicSupervisor.which_children(ctx.daemon_supervisor)

      log =
        capture_log(fn ->
          # Untrappable, exactly as a segfaulting smbd would go.
          Process.exit(first, :kill)

          # The share is published as down; the convergence pass this
          # handler triggers withholds the restart, so this is where the
          # payload settles until the retry timer fires (there is none
          # here — `start_timer: false` — so the state is stable to assert
          # on).
          assert_receive {:storage_state, %{share: :error}}, 1_000
        end)

      assert log =~ "smbd"

      assert Server.get_state(server).share == :error
      assert DynamicSupervisor.which_children(ctx.daemon_supervisor) == []
      assert Enum.count(Recorder.events(), &match?({:smbd_started}, &1)) == 1
    end

    test "the retry timer restarts a crashed daemon after :retry_interval", ctx do
      server = start_server(ctx, start_timer: true, retry_interval: 50)
      present!()
      enable_share!(ctx)
      :ok = Server.check_now(server)

      assert Server.get_state(server).share == :running
      # Drain the broadcast this first start already sent, so the later
      # `assert_receive` for the restart can't match this stale one instead.
      assert_receive {:storage_state, %{share: :running}}, 1_000

      assert [{_id, first, _type, _mods}] =
               DynamicSupervisor.which_children(ctx.daemon_supervisor)

      capture_log(fn ->
        Process.exit(first, :kill)
        assert_receive {:storage_state, %{share: :error}}, 1_000
      end)

      # Not restarted immediately...
      assert Server.get_state(server).share == :error
      assert Enum.count(Recorder.events(), &match?({:smbd_started}, &1)) == 1

      # ...but the armed retry timer converges again after :retry_interval,
      # and that pass is not paced (`restart_share?` defaults to true), so
      # it restarts the share.
      assert_receive {:storage_state, %{share: :running}}, 1_000

      assert [{_id, second, _type, _mods}] =
               DynamicSupervisor.which_children(ctx.daemon_supervisor)

      refute second == first
      assert Process.alive?(second)
      assert Enum.count(Recorder.events(), &match?({:smbd_started}, &1)) == 2
    end

    test "repeated instant crashes are paced by :retry_interval, not a loop", ctx do
      server = start_server(ctx, start_timer: true, retry_interval: 40)
      present!()
      enable_share!(ctx)
      Recorder.put(:crash_instantly?, true)

      capture_log(fn ->
        :ok = Server.check_now(server)
        # ~5 retry intervals: enough for several restart cycles if the
        # timer is doing its job, nowhere near enough for the hundreds a
        # tight spawn/crash loop would produce in the same window.
        Process.sleep(220)
      end)

      starts = Recorder.events() |> Enum.count(&match?({:smbd_started}, &1))
      assert starts >= 2
      assert starts <= 10
    end

    test "a deliberate stop is not mistaken for a crash", ctx do
      server = start_server(ctx)
      present!()
      enable_share!(ctx)
      :ok = Server.check_now(server)
      assert Server.get_state(server).share == :running

      assert :ok = Server.set_share_enabled(server, @drive_key, false)

      # The monitor's DOWN is flushed on the way out, so the stop must not
      # read back as a crash and start a replacement.
      refute_receive {:storage_state, %{share: :error}}, 200
      assert Server.get_state(server).share == :off
      assert DynamicSupervisor.which_children(ctx.daemon_supervisor) == []

      :ok = Server.check_now(server)
      assert Server.get_state(server).share == :off
      assert Enum.count(Recorder.events(), &match?({:smbd_started}, &1)) == 1
    end

    # The stored pid can only ever name one child; the sweep is what makes
    # ":off" mean "no smbd process", whatever produced the extra one.
    test "stopping the share sweeps an smbd child this server never started", ctx do
      server = start_server(ctx)
      present!()
      enable_share!(ctx)
      :ok = Server.check_now(server)

      assert [{_id, tracked, _type, _mods}] =
               DynamicSupervisor.which_children(ctx.daemon_supervisor)

      {:ok, orphan} =
        DynamicSupervisor.start_child(ctx.daemon_supervisor, SmbdStub.child_spec([]))

      refute orphan == tracked

      log =
        capture_log(fn ->
          assert :ok = Server.set_share_enabled(server, @drive_key, false)
          # The reply precedes the convergence it schedules
          # (`{:continue, :converge}`); this call is what waits for it.
          assert Server.get_state(server).share == :off
        end)

      assert log =~ "did not track"
      assert DynamicSupervisor.which_children(ctx.daemon_supervisor) == []
      refute Process.alive?(orphan)
      assert Server.get_state(server).share == :off
    end

    # A crash is not an instruction to restart: the pass it triggers
    # re-checks the opt-in, the mount and the folder like any other.
    test "a daemon that dies while the share is no longer wanted stays down", ctx do
      server = start_server(ctx)
      present!()
      enable_share!(ctx)
      :ok = Server.check_now(server)
      assert [{_id, pid, _type, _mods}] = DynamicSupervisor.which_children(ctx.daemon_supervisor)

      # Revoked without poking a convergence, so the crash's pass is the
      # first one to see it.
      :ok = Settings.put_drive(ctx.settings, @drive_key, %{share_enabled?: false})

      capture_log(fn ->
        Process.exit(pid, :kill)

        assert_receive {:storage_state, %{share: :error}}, 1_000
        assert_receive {:storage_state, %{share: :off}}, 1_000
      end)

      assert Server.get_state(server).share == :off
      assert DynamicSupervisor.which_children(ctx.daemon_supervisor) == []
      assert Enum.count(Recorder.events(), &match?({:smbd_started}, &1)) == 1
    end
  end

  describe "the active drive holds position 0" do
    test "a drive that sorts earlier does not displace the mounted one", ctx do
      server = start_server(ctx)
      present!()
      :ok = Server.check_now(server)
      assert Server.get_state(server).mount.device == "/dev/sda1"

      attach_nvme!()
      :ok = Server.check_now(server)

      state = Server.get_state(server)

      # Probe handed back [nvme0n1, sda]; the live mount's drive still
      # leads, which is the position every "first drive" decision reads.
      assert [
               %{name: "sda", partitions: [%{fs_type: :ext4}]},
               %{name: "nvme0n1", fs_type: nil, partitions: [nvme_partition]}
             ] = state.drives

      # And it is still the sniffed one: nothing past position 0 has its
      # head read at all ("not sniffed", distinct from :unknown).
      refute Map.has_key?(nvme_partition, :fs_type)

      # Nothing was mounted on top of the live mount either.
      assert state.mount.device == "/dev/sda1"
      assert Enum.count(Recorder.events(), &match?({:mount, _, _}, &1)) == 1
    end

    test "the newcomer's key is refused by both destructive actions", ctx do
      server = start_server(ctx)
      present!()
      :ok = Server.check_now(server)
      attach_nvme!()
      :ok = Server.check_now(server)

      log =
        capture_log(fn ->
          assert Server.eject(server, @nvme_key) == {:error, :unknown_drive}
          assert Server.format(server, @nvme_key, "usb_backup") == {:error, :unknown_drive}
        end)

      assert log =~ "refusing to eject"
      assert log =~ "refusing to format"
      refute :format in Recorder.event_names()
      refute Enum.any?(Recorder.events(), &match?({:umount, _}, &1))
      assert Server.get_state(server).mount.device == "/dev/sda1"
    end

    test "the mounted drive's own key is still accepted, at its own device", ctx do
      server = start_server(ctx)
      present!()
      :ok = Server.check_now(server)
      attach_nvme!()
      :ok = Server.check_now(server)

      assert :ok = Server.format(server, @drive_key, "usb_backup")

      # The sda mount, never the drive that merely sorts first.
      assert {:format, "/dev/sda1", "usb_backup", true} in Recorder.events()
      refute Enum.any?(Recorder.events(), &match?({:format, "/dev/nvme0n1p1", _l, _c}, &1))
    end

    test "the broadcast payload leads with the mounted drive", ctx do
      server = start_server(ctx)
      present!()
      :ok = Server.check_now(server)
      assert_receive {:storage_state, _mounted}

      attach_nvme!()
      :ok = Server.check_now(server)

      assert_receive {:storage_state, payload}
      assert [%{name: "sda"}, %{name: "nvme0n1"}] = payload.drives
      assert payload == Server.get_state(server)
    end

    test "an ejected drive hands position 0 back to probe order", ctx do
      server = start_server(ctx)
      present!()
      :ok = Server.check_now(server)
      attach_nvme!()
      :ok = Server.check_now(server)

      assert :ok = Server.eject(server, @drive_key)
      :ok = Server.check_now(server)

      state = Server.get_state(server)

      # Nothing mounted, so probe order chooses again — and what it chooses
      # is the next mount target.
      assert [%{name: "nvme0n1"}, %{name: "sda"}] = state.drives
      assert state.mount.device == "/dev/nvme0n1p1"
      assert {:mount, "/dev/nvme0n1p1", :ext4} in Recorder.events()
      assert Server.eject(server, @nvme_key) == :ok
    end

    test "a removed mounted drive hands position 0 back to probe order", ctx do
      server = start_server(ctx)
      present!()
      :ok = Server.check_now(server)
      attach_nvme!()
      :ok = Server.check_now(server)

      # The stick is unplugged; only the enclosure is left.
      Recorder.put(:drives, [nvme_drive()])
      :ok = Server.check_now(server)

      state = Server.get_state(server)
      assert [%{name: "nvme0n1", partitions: [%{fs_type: :ext4}]}] = state.drives
      assert state.mount.device == "/dev/nvme0n1p1"
    end
  end

  describe "mount rehydration" do
    test "an existing mount is adopted at init, not mounted a second time", ctx do
      server =
        start_server(ctx,
          mounts_path: mounts_file!(["/dev/sda1 #{MountStub.point()} ext4 rw,noatime 0 0"])
        )

      # Device, filesystem and mode all come from the table: the drive has
      # not even been probed yet.
      assert Server.get_state(server).mount == %{
               device: "/dev/sda1",
               fs_type: :ext4,
               mode: :read_write,
               point: MountStub.point(),
               stale?: false
             }

      present!()
      enable_share!(ctx)
      :ok = Server.check_now(server)

      state = Server.get_state(server)
      refute Enum.any?(Recorder.events(), &match?({:mount, _, _}, &1))
      assert state.mount.device == "/dev/sda1"
      assert state.capacity == MountStub.capacity()
      # Bound to the drive that owns the device, which is what lets the
      # share (a per-drive opt-in) start over an adopted mount.
      assert state.share == :running
    end

    test "a read-only mount-table entry is adopted as :read_only", ctx do
      server =
        start_server(ctx,
          mounts_path: mounts_file!(["/dev/sda1 #{MountStub.point()} exfat ro,noatime,nodev 0 0"])
        )

      assert Server.get_state(server).mount.mode == :read_only
      assert Server.get_state(server).mount.fs_type == :exfat
    end

    test "a filesystem this subsystem does not manage is adopted as :unknown", ctx do
      server =
        start_server(ctx, mounts_path: mounts_file!(["tmpfs #{MountStub.point()} tmpfs rw 0 0"]))

      assert Server.get_state(server).mount.fs_type == :unknown
    end

    # Overmounting would make the next umount pop one layer while the drive
    # stayed held, and would hand fsck a live filesystem on the way in.
    test "a mount point the kernel already holds is adopted, never stacked", ctx do
      path = mounts_file!([])
      server = start_server(ctx, mounts_path: path)
      present!()

      File.write!(path, "/dev/sda1 #{MountStub.point()} ext4 rw 0 0\n")
      :ok = Server.check_now(server)

      refute Enum.any?(Recorder.events(), &match?({:mount, _, _}, &1))
      assert Server.get_state(server).mount.device == "/dev/sda1"
      assert Server.get_state(server).mount.stale? == false
    end

    test "an adopted mount whose drive is gone takes the removal path", ctx do
      server =
        start_server(ctx,
          mounts_path: mounts_file!(["/dev/sdz1 #{MountStub.point()} ext4 rw 0 0"])
        )

      assert Server.get_state(server).mount.device == "/dev/sdz1"

      # Nothing attached: the drive left while this server was down.
      :ok = Server.check_now(server)

      assert [{:umount, false}] = Enum.filter(Recorder.events(), &match?({:umount, _}, &1))
      assert Server.get_state(server).mount == nil
    end
  end
end
