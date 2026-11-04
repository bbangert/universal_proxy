defmodule UniversalProxy.Bluetooth.ManagerTest do
  # async: false — shares the global :persistent_term adapter-path key and
  # a constant DETS table atom across tests.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias UniversalProxy.Bluetooth.{Manager, Settings}
  alias Bluez.DevicePath

  @pubsub UniversalProxy.PubSub
  @table :bluetooth_manager_test_settings

  @hci0_mac "B8:27:EB:11:22:33"
  @hci1_mac "AA:BB:CC:DD:EE:FF"

  defmodule StubBluez do
    @moduledoc "Stands in for the Bluez subtree in host tests."
    use Agent

    def start_link(_opts), do: Agent.start_link(fn -> :ok end)
  end

  defmodule RecordingBluez do
    @moduledoc "Reports the adapter terms it sees when it starts."

    def child_spec(test_pid) do
      %{id: __MODULE__, start: {__MODULE__, :start_link, [test_pid]}}
    end

    def start_link(test_pid) do
      send(
        test_pid,
        {:bluez_started, DevicePath.desired_adapter(), DevicePath.excluded_adapters()}
      )

      Agent.start_link(fn -> :ok end)
    end
  end

  defmodule FlakyBluez do
    @moduledoc "Fails its first start (counter slot 1 = failures left)."

    def child_spec(counter) do
      %{id: __MODULE__, start: {__MODULE__, :start_link, [counter]}}
    end

    def start_link(counter) do
      if :counters.get(counter, 1) > 0 do
        :counters.sub(counter, 1, 1)
        {:error, :boom}
      else
        Agent.start_link(fn -> :ok end)
      end
    end
  end

  setup do
    # Pre-clear as well as on_exit-clear: a crashed predecessor test (whose
    # on_exit never ran) must not leak a stale adapter path/MAC into the
    # "auto" assertions below.
    :persistent_term.erase(DevicePath.adapter_path_key())
    :persistent_term.erase(DevicePath.desired_adapter_key())
    :persistent_term.erase(DevicePath.excluded_adapters_key())

    tmp = Path.join(System.tmp_dir!(), "bt_manager_test_#{System.unique_integer([:positive])}")

    sysfs = Path.join(tmp, "sys_class_bluetooth")
    write_adapter(sysfs, "hci0", @hci0_mac)
    write_adapter(sysfs, "hci1", @hci1_mac)

    dets_path = Path.join(tmp, "settings.dets")

    on_exit(fn ->
      :persistent_term.erase(DevicePath.adapter_path_key())
      :persistent_term.erase(DevicePath.desired_adapter_key())
      :persistent_term.erase(DevicePath.excluded_adapters_key())
      File.rm_rf(tmp)
    end)

    settings = start_supervised!({Settings, name: nil, table: @table, dets_path: dets_path})
    dynsup = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    :ok = Phoenix.PubSub.subscribe(@pubsub, UniversalProxy.Bluetooth.state_topic())

    {:ok, settings: settings, dynsup: dynsup, sysfs: sysfs}
  end

  defp write_adapter(sysfs, hci, mac) do
    dir = Path.join(sysfs, hci)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "address"), mac <> "\n")
  end

  defp start_manager(ctx, opts \\ []) do
    # Per-test overrides FIRST — Keyword.get takes the first match.
    manager =
      start_supervised!({Manager,
       opts ++
         [
           name: nil,
           settings: ctx.settings,
           dynamic_supervisor: ctx.dynsup,
           bluez_child: StubBluez,
           sysfs_root: ctx.sysfs,
           pubsub: @pubsub,
           # No OS daemons in host tests — skip the L2CAP settle pause.
           restart_settle_ms: 0
         ]})

    # start_supervised! returns after init/1, but the boot reconcile runs in
    # handle_continue — synchronize on a call so assertions that query the
    # DynamicSupervisor directly don't race it.
    _ = Manager.status(manager)
    manager
  end

  defp child_count(dynsup), do: DynamicSupervisor.which_children(dynsup) |> length()

  describe "boot reconcile" do
    test "enabled (default): starts the subtree and publishes the desired radio (auto)", ctx do
      manager = start_manager(ctx)

      assert child_count(ctx.dynsup) == 1
      # nil = auto; the MAC → path resolution is Bluez.Client's job now.
      assert :persistent_term.get(DevicePath.desired_adapter_key(), :unset) == nil

      assert %{
               enabled: true,
               proxying?: true,
               adapter: %{hci: "hci0", address: nil, name: nil},
               active_connections: %{allowed?: true, used: 0, limit: 3}
             } = Manager.status(manager)

      assert_receive {:bluetooth_state, %{proxying?: true}}
    end

    test "disabled: subtree still runs, but proxying? (HA-facing) is false", ctx do
      :ok = Settings.set_enabled(ctx.settings, false)
      manager = start_manager(ctx)

      # The stack is always on — enabled only gates the espex wiring.
      assert child_count(ctx.dynsup) == 1

      assert %{enabled: false, proxying?: false, adapter: %{hci: "hci0"}} =
               Manager.status(manager)

      assert_receive {:bluetooth_state, %{enabled: false, proxying?: false}}
    end

    test "a selected radio MAC is published as the desired adapter", ctx do
      :ok = Settings.set_adapter(ctx.settings, @hci1_mac)
      _manager = start_manager(ctx)

      assert :persistent_term.get(DevicePath.desired_adapter_key()) == @hci1_mac
    end

    test "coerces persisted :audio roles to :off when the target lacks audio support", ctx do
      :ok = Settings.set_role(ctx.settings, @hci1_mac, :audio)

      _manager = start_manager(ctx, audio_role_supported_fun: fn -> false end)

      assert Settings.role(Settings.get(ctx.settings), @hci1_mac) == :off
    end

    test "leaves persisted :audio roles alone when the target supports audio", ctx do
      :ok = Settings.set_role(ctx.settings, @hci1_mac, :audio)

      _manager = start_manager(ctx)

      assert Settings.role(Settings.get(ctx.settings), @hci1_mac) == :audio
    end

    test "the :proxy-role adapter is published, taking precedence over legacy adapter", ctx do
      # Legacy selector points one way; an explicit :proxy role wins.
      :ok = Settings.set_adapter(ctx.settings, @hci1_mac)
      :ok = Settings.set_role(ctx.settings, "00:11:22:33:44:55", :proxy)
      _manager = start_manager(ctx)

      assert :persistent_term.get(DevicePath.desired_adapter_key()) == "00:11:22:33:44:55"
    end

    test "an :audio-only role leaves the proxy on auto (legacy fallback)", ctx do
      # An audio headset adapter must not be picked as the proxy radio.
      :ok = Settings.set_role(ctx.settings, @hci1_mac, :audio)
      _manager = start_manager(ctx)

      assert :persistent_term.get(DevicePath.desired_adapter_key(), :unset) == nil
    end

    test "status identifies the claimed adapter via live daemon info while running", ctx do
      # Simulate Bluez.Client having claimed hci1 and the daemon answering.
      :persistent_term.put(DevicePath.adapter_path_key(), "/org/bluez/hci1")

      manager =
        start_manager(ctx,
          adapters_info_fun: fn ->
            [%{path: "/org/bluez/hci1", address: @hci1_mac, name: "dongle", powered: true}]
          end
        )

      assert %{adapter: %{hci: "hci1", address: @hci1_mac, name: "dongle"}} =
               Manager.status(manager)
    end

    test "no controllers in sysfs: subtree still starts (its retry loop owns absence)", ctx do
      File.rm_rf!(ctx.sysfs)
      manager = start_manager(ctx)

      assert child_count(ctx.dynsup) == 1
      # Running but unidentified: the default claimed path names hci0,
      # identity appears once the daemon answers.
      assert %{proxying?: true, adapter: %{hci: "hci0", address: nil}} =
               Manager.status(manager)
    end
  end

  describe "reconcile/2" do
    test "the enabled toggle flips proxying? without touching the subtree", ctx do
      manager = start_manager(ctx)
      assert_receive {:bluetooth_state, %{proxying?: true}}
      [{_, pid, _, _}] = DynamicSupervisor.which_children(ctx.dynsup)

      :ok = Settings.set_enabled(ctx.settings, false)
      :ok = Manager.reconcile(manager)

      assert [{_, ^pid, _, _}] = DynamicSupervisor.which_children(ctx.dynsup)
      assert_receive {:bluetooth_state, %{enabled: false, proxying?: false}}

      :ok = Settings.set_enabled(ctx.settings, true)
      :ok = Manager.reconcile(manager)

      assert [{_, ^pid, _, _}] = DynamicSupervisor.which_children(ctx.dynsup)
      assert_receive {:bluetooth_state, %{enabled: true, proxying?: true}}
    end

    test "reconcile without changes is a no-op (still broadcasts)", ctx do
      manager = start_manager(ctx)
      # Drain the boot broadcast so the assertion below is the reconcile's.
      assert_receive {:bluetooth_state, _}
      [{_, pid, _, _}] = DynamicSupervisor.which_children(ctx.dynsup)

      :ok = Manager.reconcile(manager)

      assert [{_, ^pid, _, _}] = DynamicSupervisor.which_children(ctx.dynsup)
      assert_receive {:bluetooth_state, %{proxying?: true}}
    end

    test "restart: true cycles the subtree and republishes the desired radio", ctx do
      manager = start_manager(ctx)
      [{_, pid_before, _, _}] = DynamicSupervisor.which_children(ctx.dynsup)

      :ok = Settings.set_adapter(ctx.settings, @hci1_mac)
      :ok = Manager.reconcile(manager, restart: true)

      [{_, pid_after, _, _}] = DynamicSupervisor.which_children(ctx.dynsup)
      assert pid_after != pid_before
      assert :persistent_term.get(DevicePath.desired_adapter_key()) == @hci1_mac
    end
  end

  describe "failed start" do
    test "a start_child error is retried until it succeeds", ctx do
      failures_left = :counters.new(1, [])
      :counters.put(failures_left, 1, 1)

      manager =
        start_manager(ctx,
          bluez_child: FlakyBluez.child_spec(failures_left),
          start_retry_ms: 50
        )

      # First attempt failed (broadcast says down)…
      assert_receive {:bluetooth_state, %{proxying?: false}}

      # …then the retry tick brings it up without any external nudge.
      # (No child-count assert between the two — the 50 ms retry races it.)
      assert_receive {:bluetooth_state, %{proxying?: true}}, 2_000
      assert child_count(ctx.dynsup) == 1
      assert %{proxying?: true} = Manager.status(manager)
    end
  end

  describe "subtree crash" do
    test "broadcasts down, then re-binds to the supervisor's replacement", ctx do
      manager = start_manager(ctx)
      assert_receive {:bluetooth_state, %{proxying?: true}}

      [{_, pid, _, _}] = DynamicSupervisor.which_children(ctx.dynsup)
      Process.exit(pid, :kill)

      assert_receive {:bluetooth_state, %{proxying?: false}}, 1_000
      # Rebind tick is 1 s; the DynamicSupervisor restarts the child
      # immediately, so the next broadcast reports it back up. Generous
      # absolute timeout — the down message above may have consumed up to
      # its own budget already on a loaded CI box.
      assert_receive {:bluetooth_state, %{proxying?: true}}, 5_000

      assert %{proxying?: true} = Manager.status(manager)
      [{_, new_pid, _, _}] = DynamicSupervisor.which_children(ctx.dynsup)
      assert new_pid != pid
    end
  end

  # Timeouts are explicit (not the 100 ms default): these assertions run
  # right after start_manager/2, whose boot reconcile does real sysfs I/O —
  # same loaded-CI reasoning as the crash/retry tests below.
  describe "role-paused status" do
    defp bounce_fun do
      test_pid = self()
      fn -> send(test_pid, :esphome_bounced) end
    end

    test "roles engaged with no :proxy: subtree runs, but proxying? is false", ctx do
      # The only radio the user touched holds :audio — nothing may proxy.
      :ok = Settings.set_role(ctx.settings, @hci1_mac, :audio)
      manager = start_manager(ctx, esphome_restart_fun: bounce_fun())

      # The subtree still runs (the radio list needs the daemon for MACs).
      assert child_count(ctx.dynsup) == 1

      assert %{enabled: true, proxying?: false, paused?: true} = Manager.status(manager)
      assert_receive {:bluetooth_state, %{proxying?: false, paused?: true}}, 1_000

      # Booting INTO paused seeds the tracker without bouncing espex —
      # espex starts after Bluetooth and reads the same settings fresh.
      refute_receive :esphome_bounced, 100
    end

    test "an explicitly :off-only roles map is paused too", ctx do
      # Single radio turned Off — must NOT fall back to auto-claiming it.
      :ok = Settings.set_role(ctx.settings, @hci0_mac, :off)
      manager = start_manager(ctx)

      assert %{proxying?: false, paused?: true} = Manager.status(manager)
    end

    test "assigning :proxy resumes: reconcile broadcasts and bounces espex", ctx do
      :ok = Settings.set_role(ctx.settings, @hci1_mac, :audio)
      manager = start_manager(ctx, esphome_restart_fun: bounce_fun())
      assert_receive {:bluetooth_state, %{paused?: true}}, 1_000

      :ok = Settings.set_role(ctx.settings, @hci0_mac, :proxy)
      :ok = Manager.reconcile(manager)

      assert_receive {:bluetooth_state, %{proxying?: true, paused?: false}}, 1_000
      assert_receive :esphome_bounced
    end

    test "un-assigning the running :proxy pauses: reconcile broadcasts and bounces espex", ctx do
      :ok = Settings.set_role(ctx.settings, @hci0_mac, :proxy)
      manager = start_manager(ctx, esphome_restart_fun: bounce_fun())
      assert_receive {:bluetooth_state, %{proxying?: true, paused?: false}}, 1_000

      :ok = Settings.set_role(ctx.settings, @hci0_mac, :off)
      :ok = Manager.reconcile(manager)

      assert_receive {:bluetooth_state, %{proxying?: false, paused?: true}}, 1_000
      assert_receive :esphome_bounced
    end

    test "a role change that doesn't flip pausedness never bounces espex", ctx do
      :ok = Settings.set_role(ctx.settings, @hci0_mac, :proxy)
      manager = start_manager(ctx, esphome_restart_fun: bounce_fun())
      assert_receive {:bluetooth_state, %{paused?: false}}, 1_000

      # A different radio takes :audio — still un-paused throughout.
      :ok = Settings.set_role(ctx.settings, @hci1_mac, :audio)
      :ok = Manager.reconcile(manager)

      assert_receive {:bluetooth_state, %{proxying?: true, paused?: false}}, 1_000
      refute_receive :esphome_bounced, 100
    end
  end

  describe "Tuya mesh adapter" do
    test "the Bluez spec is built per start, with the mesh adapter only once assigned", ctx do
      test_pid = self()

      spec_fun = fn opts ->
        send(test_pid, {:spec_opts, opts})
        StubBluez
      end

      # nil first: Keyword.get takes the first match, so this overrides the
      # harness's fixed StubBluez child and the per-start fun runs.
      manager = start_manager(ctx, bluez_child: nil, bluez_spec_fun: spec_fun)
      assert_receive {:spec_opts, [tuya_adapter: nil]}

      :ok = Settings.set_role(ctx.settings, @hci1_mac, :tuya_mesh)
      :ok = Manager.reconcile(manager, restart: true)
      assert_receive {:spec_opts, [tuya_adapter: @hci1_mac]}

      :ok = Settings.set_role(ctx.settings, @hci1_mac, :off)
      :ok = Manager.reconcile(manager, restart: true)
      assert_receive {:spec_opts, [tuya_adapter: nil]}
    end

    test "a bluez_child: override wins over the per-start spec", ctx do
      test_pid = self()

      _manager =
        start_manager(ctx, bluez_spec_fun: fn opts -> send(test_pid, {:spec_opts, opts}) end)

      assert child_count(ctx.dynsup) == 1
      refute_received {:spec_opts, _}
    end

    test "the exclusion is published before the subtree starts and cleared with the role", ctx do
      :ok = Settings.set_role(ctx.settings, @hci1_mac, :tuya_mesh)
      manager = start_manager(ctx, bluez_child: RecordingBluez.child_spec(self()))

      # Seen from inside the child's start: the term landed first.
      assert_receive {:bluez_started, nil, [@hci1_mac]}

      :ok = Settings.set_role(ctx.settings, @hci1_mac, :off)
      :ok = Manager.reconcile(manager, restart: true)

      # [] is written, not left stale, so the client may claim it again.
      assert_receive {:bluez_started, nil, []}
      assert :persistent_term.get(DevicePath.excluded_adapters_key()) == []
    end

    test "the mesh radio and the proxy radio are published side by side", ctx do
      :ok = Settings.set_role(ctx.settings, @hci0_mac, :proxy)
      :ok = Settings.set_role(ctx.settings, @hci1_mac, :tuya_mesh)
      _manager = start_manager(ctx, bluez_child: RecordingBluez.child_spec(self()))

      assert_receive {:bluez_started, @hci0_mac, [@hci1_mac]}
    end

    test "a mesh-only role isn't paused: the auto fallback proxies on another radio", ctx do
      :ok = Settings.set_role(ctx.settings, @hci1_mac, :tuya_mesh)
      manager = start_manager(ctx)

      assert %{proxying?: true, paused?: false} = Manager.status(manager)
      assert :persistent_term.get(DevicePath.desired_adapter_key(), :unset) == nil
    end

    test "status reports no adapter when the path names the excluded mesh radio", ctx do
      # A lone mesh radio: the client never claims it, so the path is still
      # the hci0 default, and that's the mesh radio.
      :ok = Settings.set_role(ctx.settings, @hci0_mac, :tuya_mesh)

      manager =
        start_manager(ctx,
          adapters_info_fun: fn ->
            [%{path: "/org/bluez/hci0", address: @hci0_mac, name: "pi", powered: true}]
          end
        )

      assert %{proxying?: false, adapter: nil} = Manager.status(manager)
    end

    test "status reports no adapter when the proxy radio is gone and only the mesh is left",
         ctx do
      # The proxy on hci0 was unplugged: its stale path matches no live
      # adapter, and the only one left is the excluded mesh radio.
      :persistent_term.put(DevicePath.adapter_path_key(), "/org/bluez/hci0")
      :ok = Settings.set_role(ctx.settings, @hci1_mac, :tuya_mesh)

      manager =
        start_manager(ctx,
          adapters_info_fun: fn ->
            [%{path: "/org/bluez/hci1", address: @hci1_mac, name: "dongle", powered: true}]
          end
        )

      assert %{proxying?: false, adapter: nil} = Manager.status(manager)
    end

    test "an unmatched path with a non-mesh radio still present keeps the adapter map", ctx do
      :persistent_term.put(DevicePath.adapter_path_key(), "/org/bluez/hci2")
      :ok = Settings.set_role(ctx.settings, @hci1_mac, :tuya_mesh)

      manager =
        start_manager(ctx,
          adapters_info_fun: fn ->
            [
              %{path: "/org/bluez/hci0", address: @hci0_mac, name: "pi", powered: true},
              %{path: "/org/bluez/hci1", address: @hci1_mac, name: "dongle", powered: true}
            ]
          end
        )

      assert %{proxying?: true, adapter: %{hci: "hci2", address: nil}} = Manager.status(manager)
    end

    test "boot warns about a lone mesh radio but keeps the role", ctx do
      File.rm_rf!(Path.join(ctx.sysfs, "hci1"))
      :ok = Settings.set_role(ctx.settings, @hci0_mac, :tuya_mesh)

      log = capture_log(fn -> start_manager(ctx) end)

      assert log =~ "#{@hci0_mac} holds the :tuya_mesh role but 1 radio(s) are present"
      assert Settings.tuya_adapter(Settings.get(ctx.settings)) == @hci0_mac
      # Still excluded: the radio stays dedicated to the mesh.
      assert :persistent_term.get(DevicePath.excluded_adapters_key()) == [@hci0_mac]
    end

    test "no boot warning with a second radio present", ctx do
      :ok = Settings.set_role(ctx.settings, @hci1_mac, :tuya_mesh)

      refute capture_log(fn -> start_manager(ctx) end) =~ ":tuya_mesh role"
    end
  end

  describe "held mesh radio" do
    # hci0 is the mesh radio, held over the user channel: bluetoothd lists
    # only hci1 until the mesh lets go.
    setup ctx do
      :ok = Settings.set_role(ctx.settings, @hci0_mac, :tuya_mesh)
      :ok = Settings.set_role(ctx.settings, @hci1_mac, :proxy)
      test = self()
      entry = %{address: @hci0_mac, index: 0, holder: :tuya_mesh, pid: test}
      held = start_supervised!({Agent, fn -> [entry] end}, id: :held)

      listed =
        start_supervised!(
          {Agent,
           fn ->
             [%{path: "/org/bluez/hci1", address: @hci1_mac, name: "dongle", powered: true}]
           end},
          id: :listed
        )

      {:ok, held: held, listed: listed}
    end

    defp held_opts(ctx, release_fun) do
      [
        bluez_child: {RecordingBluez, self()},
        held_fun: fn -> Agent.get(ctx.held, & &1) end,
        adapters_info_fun: fn -> Agent.get(ctx.listed, & &1) end,
        release_mesh_fun: release_fun,
        handback_poll_ms: 5
      ]
    end

    # bluetoothd taking hci0 back `ms` after the mesh released it.
    defp hand_back(ctx, test, ms) do
      spawn(fn ->
        Process.sleep(ms)

        Agent.update(ctx.listed, fn listed ->
          [%{path: "/org/bluez/hci0", address: @hci0_mac, name: "pi", powered: true} | listed]
        end)

        send(test, :listed)
      end)
    end

    # The next of the ordering events, whatever else is in the mailbox.
    defp next_event do
      receive do
        :released -> :released
        :listed -> :listed
        {:bluez_started, _desired, _excluded} -> :bluez_started
      after
        2_000 -> :none
      end
    end

    test "a restart has the mesh release it and waits for bluetoothd before starting", ctx do
      test = self()

      release = fn ->
        send(test, :released)
        Agent.update(ctx.held, fn _ -> [] end)
        hand_back(ctx, test, 100)
        :ok
      end

      manager = start_manager(ctx, held_opts(ctx, release))
      assert next_event() == :bluez_started

      log = capture_log(fn -> :ok = Manager.reconcile(manager, restart: true) end)

      assert [next_event(), next_event(), next_event()] == [:released, :listed, :bluez_started]
      refute log =~ "restarting anyway"
    end

    test "the wait for bluetoothd is bounded", ctx do
      test = self()

      release = fn ->
        send(test, :released)
        Agent.update(ctx.held, fn _ -> [] end)
        :ok
      end

      manager = start_manager(ctx, held_opts(ctx, release) ++ [handback_timeout_ms: 100])
      assert next_event() == :bluez_started

      started = System.monotonic_time(:millisecond)
      log = capture_log(fn -> :ok = Manager.reconcile(manager, restart: true) end)

      assert [next_event(), next_event()] == [:released, :bluez_started]
      assert System.monotonic_time(:millisecond) - started >= 100

      assert log =~
               "bluetoothd doesn't list #{@hci0_mac} after 100 ms; restarting anyway"
    end

    test "a release that fails is logged and the restart goes ahead", ctx do
      manager =
        start_manager(
          ctx,
          held_opts(ctx, fn -> {:error, :timeout} end) ++ [handback_timeout_ms: 50]
        )

      assert next_event() == :bluez_started

      log = capture_log(fn -> :ok = Manager.reconcile(manager, restart: true) end)

      assert next_event() == :bluez_started
      assert log =~ "the Tuya mesh didn't release its radio (:timeout); restarting anyway"
    end

    test "nothing held: no release, no wait", ctx do
      Agent.update(ctx.held, fn _ -> [] end)
      test = self()

      manager =
        start_manager(
          ctx,
          held_opts(ctx, fn ->
            send(test, :released)
            :ok
          end)
        )

      assert next_event() == :bluez_started

      :ok = Manager.reconcile(manager, restart: true)

      assert next_event() == :bluez_started
      refute_received :released
    end

    test "a reconcile without a restart never releases", ctx do
      test = self()

      manager =
        start_manager(
          ctx,
          held_opts(ctx, fn ->
            send(test, :released)
            :ok
          end)
        )

      assert next_event() == :bluez_started

      :ok = Manager.reconcile(manager)

      assert next_event() == :none
    end

    test "status never names the held index as the proxy adapter", ctx do
      # The client never claimed: the path is the hci0 default, which the
      # mesh holds out of bluetoothd's sight.
      :persistent_term.put(DevicePath.adapter_path_key(), "/org/bluez/hci0")
      manager = start_manager(ctx, held_opts(ctx, fn -> :ok end))

      assert %{proxying?: false, adapter: nil} = Manager.status(manager)
    end
  end

  describe "adapter claim settling" do
    test "rebroadcasts status when the Client announces an adapter change", ctx do
      # Stands in for Bluez.Client's live Adapter1 view, which is empty
      # until the (asynchronous) claim lands.
      {:ok, info} = Agent.start_link(fn -> [] end)

      _manager = start_manager(ctx, adapters_info_fun: fn -> Agent.get(info, & &1) end)

      # The reconcile-time broadcast predates the claim: no adapter identity.
      assert_receive {:bluetooth_state, %{adapter: %{address: nil}}}, 1_000

      # The Client resolves + claims hci1 after its setup, then announces it
      # on adapters_topic. The Manager must rebroadcast the settled identity.
      :persistent_term.put(DevicePath.adapter_path_key(), "/org/bluez/hci1")

      Agent.update(info, fn _ ->
        [%{path: "/org/bluez/hci1", address: @hci1_mac, name: "BlueZ 5.79"}]
      end)

      Phoenix.PubSub.broadcast(
        @pubsub,
        Bluez.Client.adapters_topic(),
        {:bluetooth_adapters_changed}
      )

      assert_receive {:bluetooth_state, %{adapter: %{hci: "hci1", address: @hci1_mac}}}
    end
  end
end
