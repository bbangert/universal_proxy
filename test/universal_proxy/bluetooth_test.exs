defmodule UniversalProxy.BluetoothTest do
  # async: false — drives the globally-named Settings/Manager/RadioMonitor
  # (the public API targets those names) and the persistent_term adapter
  # path. Note: the toggle setters fire an async ESPHome supervisor
  # restart, same as UART config writes.
  use ExUnit.Case, async: false

  alias UniversalProxy.Bluetooth
  alias UniversalProxy.Bluetooth.{AudioManager, HeldRadios, Manager, RadioMonitor, Settings}
  alias Bluez.DevicePath

  @pubsub UniversalProxy.PubSub
  @table :bluetooth_public_api_test

  @hci0_mac "B8:27:EB:11:22:33"
  @hci1_mac "AA:BB:CC:DD:EE:FF"

  defmodule StubBluez do
    @moduledoc false
    use Agent

    def start_link(_opts), do: Agent.start_link(fn -> :ok end)
  end

  defmodule RecordingBluez do
    @moduledoc false
    # Tells the test the adapter terms each subtree start sees.
    def child_spec(test), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [test]}}

    def start_link(test) do
      send(test, {:bluez_started, DevicePath.desired_adapter(), DevicePath.excluded_adapters()})
      Agent.start_link(fn -> :ok end)
    end
  end

  # AudioManager ops for the bond-cleanup ordering test: one speaker bonded to
  # hci1, whose Disconnect blocks until the test releases it.
  defmodule BlockingOps do
    @moduledoc false
    @behaviour UniversalProxy.Bluetooth.AudioManager.Ops

    @adapter "/org/bluez/hci1"
    @speaker "/org/bluez/hci1/dev_11_22_33_44_55_66"

    def speaker_path, do: @speaker

    @impl true
    def adapters_info(_c), do: [%{path: @adapter, address: "AA:BB:CC:DD:EE:FF"}]

    @impl true
    def managed_devices(_c) do
      [
        %{
          path: @speaker,
          mac: "11:22:33:44:55:66",
          props: %{"UUIDs" => [AudioManager.audio_sink_uuid()]}
        }
      ]
    end

    @impl true
    def disconnect(_c, path) do
      send(:bt_cleanup_test, {:cleanup_started, self(), path})

      receive do
        :release -> :ok
      end
    end

    @impl true
    def remove(_c, _adapter, path) do
      send(:bt_cleanup_test, {:removed, path})
      :ok
    end

    @impl true
    def start_discovery(_c, _a), do: :ok
    @impl true
    def stop_discovery(_c, _a), do: :ok
    @impl true
    def pair(_c, _p), do: :ok
    @impl true
    def set_trusted(_c, _p, _v), do: :ok
    @impl true
    def connect(_c, _p), do: :ok
  end

  setup do
    # Pre-clear AND on_exit-clear — a crashed predecessor must not leak
    # adapter terms into the "subsystem down" / auto-selection tests.
    :persistent_term.erase(DevicePath.adapter_path_key())
    :persistent_term.erase(DevicePath.desired_adapter_key())
    :persistent_term.erase(DevicePath.excluded_adapters_key())

    on_exit(fn ->
      :persistent_term.erase(DevicePath.adapter_path_key())
      :persistent_term.erase(DevicePath.desired_adapter_key())
      :persistent_term.erase(DevicePath.excluded_adapters_key())
    end)

    :ok = Phoenix.PubSub.subscribe(@pubsub, Bluetooth.state_topic())
    :ok
  end

  # Brings up the whole subsystem under the production-global names, with
  # fixture sysfs + a stub Bluez child — the shape the public API targets.
  # `radios` is the [{hci, mac}] set present (both by default).
  defp start_subsystem(radios \\ [{"hci0", @hci0_mac}, {"hci1", @hci1_mac}]) do
    tmp = Path.join(System.tmp_dir!(), "bt_public_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(tmp) end)

    sysfs = Path.join(tmp, "sysfs")
    for {hci, mac} <- radios, do: add_radio(sysfs, hci, mac)

    start_supervised!({Settings, table: @table, dets_path: Path.join(tmp, "s.dets")})
    dynsup = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    start_supervised!(
      {Manager,
       dynamic_supervisor: dynsup,
       bluez_child: StubBluez,
       sysfs_root: sysfs,
       pubsub: @pubsub,
       restart_settle_ms: 0}
    )

    # Radio MACs only exist via the daemon overlay (sysfs has none), so
    # select_radio's membership check depends on this stub.
    start_supervised!(
      {RadioMonitor,
       sysfs_root: sysfs,
       pubsub: @pubsub,
       poll_ms: 60_000,
       adapters_info_fun: fn ->
         for {hci, mac} <- radios,
             do: %{path: "/org/bluez/#{hci}", address: mac, name: hci, powered: true}
       end}
    )

    # Both run their first pass in handle_continue — synchronize before
    # tests query the DynamicSupervisor or radio list directly.
    _ = Manager.status()
    _ = RadioMonitor.list()

    %{dynsup: dynsup, sysfs: sysfs}
  end

  defp add_radio(sysfs, hci, mac) do
    dir = Path.join(sysfs, hci)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "address"), mac <> "\n")
  end

  describe "with the subsystem down (non-BT target / early boot)" do
    test "status/0 reports a disabled shape instead of raising" do
      assert %{
               enabled: false,
               proxying?: false,
               adapter: nil,
               active_connections: %{allowed?: false, used: 0, limit: 0}
             } = Bluetooth.status()
    end

    test "roles/0 degrades to the empty-role shape" do
      assert Bluetooth.roles() == %{proxy: nil, audio: [], tuya_mesh: nil}
    end

    test "radio reads degrade to empty lists" do
      assert Bluetooth.list_radios() == []
      assert Bluetooth.refresh_radios() == []
    end

    test "stats/0 degrades to zeros" do
      assert Bluetooth.stats() == %{
               ads_per_s: 0,
               devices_15min: 0,
               connections: %{used: 0, limit: 0}
             }
    end

    test "setters return a clean error" do
      assert Bluetooth.set_enabled(false) == {:error, :unavailable}
      assert Bluetooth.set_active_connections(false) == {:error, :unavailable}
      assert Bluetooth.select_radio(nil) == {:error, :unavailable}
    end
  end

  describe "toggles" do
    test "set_enabled/1 persists and broadcasts WITHOUT touching the subtree" do
      %{dynsup: dynsup} = start_subsystem()
      assert %{enabled: true, proxying?: true} = Bluetooth.status()
      [{_, pid, _, _}] = DynamicSupervisor.which_children(dynsup)

      assert Bluetooth.set_enabled(false) == :ok
      assert %{enabled: false} = Settings.get()
      # The stack stays up — only the espex wiring (and proxying?) change.
      assert [{_, ^pid, _, _}] = DynamicSupervisor.which_children(dynsup)
      assert_receive {:bluetooth_state, %{enabled: false, proxying?: false}}

      assert Bluetooth.set_enabled(true) == :ok
      assert [{_, ^pid, _, _}] = DynamicSupervisor.which_children(dynsup)
      assert_receive {:bluetooth_state, %{enabled: true, proxying?: true}}
    end

    test "set_active_connections/1 persists and rebroadcasts without touching the subtree" do
      %{dynsup: dynsup} = start_subsystem()
      [{_, pid, _, _}] = DynamicSupervisor.which_children(dynsup)

      assert Bluetooth.set_active_connections(false) == :ok
      assert %{active_connections: false} = Settings.get()

      # Same subtree incarnation — only the espex wiring changes.
      assert [{_, ^pid, _, _}] = DynamicSupervisor.which_children(dynsup)
      assert_receive {:bluetooth_state, %{active_connections: %{allowed?: false}}}
    end
  end

  describe "select_radio/1" do
    test "switches to a known radio's MAC and restarts the subtree on it" do
      %{dynsup: dynsup} = start_subsystem()
      [{_, pid_before, _, _}] = DynamicSupervisor.which_children(dynsup)

      assert Bluetooth.select_radio(@hci1_mac) == :ok

      # The MAC is published for Bluez.Client to resolve at its setup.
      assert :persistent_term.get(DevicePath.desired_adapter_key()) == @hci1_mac
      assert %{adapter: @hci1_mac} = Settings.get()
      [{_, pid_after, _, _}] = DynamicSupervisor.which_children(dynsup)
      assert pid_after != pid_before
    end

    test "accepts lowercase input (normalized to the stored form)" do
      start_subsystem()

      assert Bluetooth.select_radio(String.downcase(@hci1_mac)) == :ok
      assert %{adapter: @hci1_mac} = Settings.get()
    end

    test "nil returns to auto (first adapter)" do
      start_subsystem()
      :ok = Bluetooth.select_radio(@hci1_mac)

      assert Bluetooth.select_radio(nil) == :ok
      assert %{adapter: nil} = Settings.get()
      assert :persistent_term.get(DevicePath.desired_adapter_key(), :unset) == nil
    end

    test "a MAC no enumerated radio has is rejected" do
      start_subsystem()

      assert Bluetooth.select_radio("00:11:22:33:44:55") == {:error, :unknown_radio}
      assert %{adapter: nil} = Settings.get()
    end
  end

  describe "set_role/2" do
    # AudioManager isn't started in this harness, so forget_all_on_adapter
    # no-ops (exit-safe) — these tests cover persistence + proxy re-targeting.
    test "assigning :proxy persists the role and re-targets the subtree" do
      %{dynsup: dynsup} = start_subsystem()
      [{_, pid_before, _, _}] = DynamicSupervisor.which_children(dynsup)

      assert Bluetooth.set_role(@hci1_mac, :proxy) == :ok

      assert Settings.proxy_adapter(Settings.get()) == @hci1_mac
      assert :persistent_term.get(DevicePath.desired_adapter_key()) == @hci1_mac
      [{_, pid_after, _, _}] = DynamicSupervisor.which_children(dynsup)
      assert pid_after != pid_before
    end

    test "an :audio-only assignment doesn't restart the proxy subtree" do
      %{dynsup: dynsup} = start_subsystem()
      [{_, pid_before, _, _}] = DynamicSupervisor.which_children(dynsup)

      assert Bluetooth.set_role(@hci1_mac, :audio) == :ok

      assert Settings.audio_adapters(Settings.get()) == [@hci1_mac]
      # Proxy target unchanged (still auto) → no restart.
      [{_, pid_after, _, _}] = DynamicSupervisor.which_children(dynsup)
      assert pid_after == pid_before
    end

    test "normalizes case and rejects a bad role" do
      start_subsystem()

      assert Bluetooth.set_role(String.downcase(@hci1_mac), :audio) == :ok
      assert Settings.audio_adapters(Settings.get()) == [@hci1_mac]
      assert {:error, :invalid_role} = Bluetooth.set_role(@hci1_mac, :bogus)
    end

    test "rejects :audio on hardware without audio-role support" do
      start_subsystem()
      Application.put_env(:universal_proxy, :bt_audio_role_override, false)
      on_exit(fn -> Application.delete_env(:universal_proxy, :bt_audio_role_override) end)

      assert {:error, :audio_role_unsupported} = Bluetooth.set_role(@hci1_mac, :audio)
      assert Settings.audio_adapters(Settings.get()) == []
      # Non-audio roles pass the gate untouched.
      assert Bluetooth.set_role(@hci1_mac, :off) == :ok
    end
  end

  describe "set_role/2 with :tuya_mesh" do
    defp subtree_pid(dynsup) do
      [{_, pid, _, _}] = DynamicSupervisor.which_children(dynsup)
      pid
    end

    test "dedicates a radio: persisted, excluded, surfaced, subtree restarted" do
      %{dynsup: dynsup} = start_subsystem()
      pid_before = subtree_pid(dynsup)

      assert Bluetooth.set_role(String.downcase(@hci1_mac), :tuya_mesh) == :ok

      assert %{tuya_mesh: @hci1_mac, proxy: nil} = Bluetooth.roles()
      assert :persistent_term.get(DevicePath.excluded_adapters_key()) == [@hci1_mac]
      assert subtree_pid(dynsup) != pid_before

      # The radio list carries the role, so the UI can show the mesh radio
      # as taken even though the proxy stack never claims it.
      radios = Bluetooth.list_radios()
      assert %{role: :tuya_mesh, in_use?: false} = Enum.find(radios, &(&1.address == @hci1_mac))
      assert %{role: nil} = Enum.find(radios, &(&1.address == @hci0_mac))

      # Not a pause: the other radio keeps proxying via the auto fallback.
      assert %{paused?: false, proxying?: true} = Bluetooth.status()
    end

    test "a mesh change restarts the subtree even when the proxy radio doesn't move" do
      %{dynsup: dynsup} = start_subsystem()
      :ok = Bluetooth.set_role(@hci0_mac, :proxy)
      pid_before = subtree_pid(dynsup)

      assert Bluetooth.set_role(@hci1_mac, :tuya_mesh) == :ok
      assert Settings.proxy_adapter(Settings.get()) == @hci0_mac
      pid_mesh = subtree_pid(dynsup)
      assert pid_mesh != pid_before

      # Leaving the role restarts too, clearing the exclusion.
      assert Bluetooth.set_role(@hci1_mac, :off) == :ok
      assert :persistent_term.get(DevicePath.excluded_adapters_key()) == []
      assert subtree_pid(dynsup) != pid_mesh
    end

    test "is refused on a lone radio, leaving the settings untouched" do
      %{dynsup: dynsup} = start_subsystem([{"hci0", @hci0_mac}])
      pid_before = subtree_pid(dynsup)

      assert Bluetooth.set_role(@hci0_mac, :tuya_mesh) == {:error, :needs_second_radio}

      assert Settings.get().roles == %{}
      assert subtree_pid(dynsup) == pid_before
    end

    test "is refused while the radio list is unavailable, leaving the settings untouched" do
      %{dynsup: dynsup} = start_subsystem()
      :ok = Bluetooth.set_role(@hci1_mac, :tuya_mesh)
      [{_, pid_before, _, _}] = DynamicSupervisor.which_children(dynsup)
      stop_supervised!(RadioMonitor)

      # Unverifiable MAC: accepting it would demote the real mesh radio.
      assert Bluetooth.set_role("00:11:22:33:44:55", :tuya_mesh) ==
               {:error, :radios_unavailable}

      assert Settings.get().roles == %{@hci1_mac => :tuya_mesh}
      assert [{_, ^pid_before, _, _}] = DynamicSupervisor.which_children(dynsup)
    end

    test "is refused for a MAC no present radio has" do
      start_subsystem()

      assert Bluetooth.set_role("00:11:22:33:44:55", :tuya_mesh) == {:error, :unknown_radio}
      assert Settings.get().roles == %{}
    end

    test "moving the mesh to another radio demotes the old one to :off" do
      start_subsystem()
      :ok = Bluetooth.set_role(@hci1_mac, :tuya_mesh)

      assert Bluetooth.set_role(@hci0_mac, :tuya_mesh) == :ok

      assert Settings.get().roles == %{@hci0_mac => :tuya_mesh, @hci1_mac => :off}
      assert :persistent_term.get(DevicePath.excluded_adapters_key()) == [@hci0_mac]
    end
  end

  describe "set_role/2 bond cleanup before a restart" do
    test "leaving :audio for a role that restarts the subtree waits for the cleanup" do
      %{dynsup: dynsup} = start_subsystem()
      Process.register(self(), :bt_cleanup_test)
      start_supervised!({Task.Supervisor, name: __MODULE__.CleanupTasks})

      start_supervised!(
        {AudioManager,
         conn: nil,
         ops: BlockingOps,
         settings: Settings,
         task_supervisor: __MODULE__.CleanupTasks,
         reconnect_on_boot: false}
      )

      :ok = Bluetooth.set_role(@hci1_mac, :audio)
      [{_, pid_before, _, _}] = DynamicSupervisor.which_children(dynsup)

      # :audio -> :proxy moves the proxy radio, so the subtree restarts.
      setter = Task.async(fn -> Bluetooth.set_role(@hci1_mac, :proxy) end)

      speaker = BlockingOps.speaker_path()
      assert_receive {:cleanup_started, cleanup_pid, ^speaker}, 1_000

      # Cleanup still running: the subtree hasn't been touched yet.
      refute Task.yield(setter, 100)
      assert [{_, ^pid_before, _, _}] = DynamicSupervisor.which_children(dynsup)

      send(cleanup_pid, :release)
      assert Task.await(setter) == :ok

      assert_received {:removed, ^speaker}
      [{_, pid_after, _, _}] = DynamicSupervisor.which_children(dynsup)
      assert pid_after != pid_before
    end
  end

  describe "a radio the Tuya mesh holds over the user channel" do
    @hci2_mac "11:22:33:44:55:66"

    defp adapter_entry(hci, mac),
      do: %{path: "/org/bluez/#{hci}", address: mac, name: "radio-#{hci}", powered: true}

    # hci0 is the mesh radio, held (so bluetoothd lists only hci1 and hci2);
    # hci1 proxies. The Manager's release reaches the holder, which lets go
    # and has "bluetoothd" list hci0 again 50 ms later.
    setup do
      tmp = Path.join(System.tmp_dir!(), "bt_held_test_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(tmp) end)
      sysfs = Path.join(tmp, "sysfs")

      for {hci, mac} <- [{"hci0", @hci0_mac}, {"hci1", @hci1_mac}, {"hci2", @hci2_mac}],
          do: add_radio(sysfs, hci, mac)

      start_supervised!(HeldRadios)
      start_supervised!({Settings, table: @table, dets_path: Path.join(tmp, "s.dets")})
      :ok = Settings.set_role(@hci0_mac, :tuya_mesh)
      :ok = Settings.set_role(@hci1_mac, :proxy)

      listed =
        start_supervised!(
          {Agent, fn -> [adapter_entry("hci1", @hci1_mac), adapter_entry("hci2", @hci2_mac)] end},
          id: :listed
        )

      holder = start_holder(listed)
      dynsup = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
      test = self()

      start_supervised!(
        {Manager,
         dynamic_supervisor: dynsup,
         bluez_child: {RecordingBluez, test},
         sysfs_root: sysfs,
         pubsub: @pubsub,
         restart_settle_ms: 0,
         esphome_restart_fun: fn -> :ok end,
         adapters_info_fun: fn -> Agent.get(listed, & &1) end,
         handback_poll_ms: 5,
         release_mesh_fun: fn ->
           send(test, :release_asked)
           send(holder, {:release, self()})

           receive do
             :unheld -> :ok
           after
             1_000 -> {:error, :timeout}
           end
         end}
      )

      start_supervised!(
        {RadioMonitor,
         sysfs_root: sysfs, pubsub: @pubsub, adapters_info_fun: fn -> Agent.get(listed, & &1) end}
      )

      _ = Manager.status()
      _ = RadioMonitor.list()
      assert_receive {:bluez_started, @hci1_mac, [@hci0_mac]}

      %{dynsup: dynsup, holder: holder}
    end

    defp start_holder(listed) do
      test = self()

      pid =
        spawn(fn ->
          :ok = HeldRadios.hold(@hci0_mac, 0)
          send(test, :held)

          receive do
            {:release, from} ->
              :ok = HeldRadios.release(@hci0_mac)
              send(test, :released)
              send(from, :unheld)
              Process.sleep(50)
              Agent.update(listed, &[adapter_entry("hci0", @hci0_mac) | &1])
              send(test, :listed)
          end

          Process.sleep(:infinity)
        end)

      on_exit(fn -> Process.exit(pid, :kill) end)
      assert_receive :held
      pid
    end

    defp subtree(dynsup) do
      [{_, pid, _, _}] = DynamicSupervisor.which_children(dynsup)
      pid
    end

    defp next_event do
      receive do
        :released -> :released
        :listed -> :listed
        {:bluez_started, _desired, _excluded} -> :bluez_started
      after
        2_000 -> :none
      end
    end

    test "is listed with its MAC, the mesh role and the held state, once" do
      radios = Bluetooth.list_radios()

      assert [
               %{
                 hci: "hci0",
                 address: @hci0_mac,
                 role: :tuya_mesh,
                 held: :tuya_mesh,
                 in_use?: false
               },
               %{hci: "hci1", address: @hci1_mac, role: :proxy, held: nil},
               %{hci: "hci2", address: @hci2_mac, held: nil}
             ] = radios

      assert Enum.count(radios, &(&1.address == @hci0_mac)) == 1
    end

    test "setting :tuya_mesh again is a no-op", %{dynsup: dynsup} do
      pid = subtree(dynsup)

      assert Bluetooth.set_role(String.downcase(@hci0_mac), :tuya_mesh) == :ok

      assert subtree(dynsup) == pid
      refute_received :release_asked
      assert HeldRadios.held?(@hci0_mac)
    end

    test "moving the mesh to another radio releases the held one first" do
      assert Bluetooth.set_role(@hci2_mac, :tuya_mesh) == :ok

      assert [next_event(), next_event()] == [:released, :listed]
      assert_receive {:bluez_started, @hci1_mac, [@hci2_mac]}

      assert Settings.get().roles == %{
               @hci0_mac => :off,
               @hci1_mac => :proxy,
               @hci2_mac => :tuya_mesh
             }
    end

    test "a new role releases it first: Bluez starts only once bluetoothd has it back" do
      assert Bluetooth.set_role(@hci0_mac, :proxy) == :ok

      assert [next_event(), next_event(), next_event()] == [:released, :listed, :bluez_started]
      assert Settings.get().roles == %{@hci0_mac => :proxy}
      assert :persistent_term.get(DevicePath.excluded_adapters_key()) == []

      # bluetoothd's again: identified by the daemon, no longer held.
      assert %{address: @hci0_mac, role: :proxy, held: nil} =
               Enum.find(Bluetooth.list_radios(), &(&1.hci == "hci0"))
    end

    test "another radio's role change that restarts nothing leaves the mesh alone",
         %{dynsup: dynsup} do
      pid = subtree(dynsup)

      assert Bluetooth.set_role(@hci2_mac, :audio) == :ok

      assert subtree(dynsup) == pid
      refute_received :release_asked
      assert HeldRadios.held?(@hci0_mac)
      assert %{held: :tuya_mesh, role: :tuya_mesh} = hd(Bluetooth.list_radios())
    end

    test "another radio's role change that restarts the subtree keeps the mesh radio excluded" do
      assert Bluetooth.set_role(@hci1_mac, :off) == :ok

      # The restart tears the mesh down with the subtree, so it is released
      # first; the new subtree still leaves hci0 to the mesh.
      assert [next_event(), next_event()] == [:released, :listed]
      assert_receive {:bluez_started, nil, [@hci0_mac]}
    end
  end
end
