defmodule UniversalProxy.BluetoothTest do
  # async: false — drives the globally-named Settings/Manager/RadioMonitor
  # (the public API targets those names) and the persistent_term adapter
  # path. Note: the toggle setters fire an async ESPHome supervisor
  # restart, same as UART config writes.
  use ExUnit.Case, async: false

  alias UniversalProxy.Bluetooth
  alias UniversalProxy.Bluetooth.{Manager, RadioMonitor, Settings}
  alias UniversalProxy.Bluez.DevicePath

  @pubsub UniversalProxy.PubSub
  @table :bluetooth_public_api_test

  @hci0_mac "B8:27:EB:11:22:33"
  @hci1_mac "AA:BB:CC:DD:EE:FF"

  defmodule StubBluez do
    @moduledoc false
    use Agent

    def start_link(_opts), do: Agent.start_link(fn -> :ok end)
  end

  setup do
    on_exit(fn ->
      :persistent_term.erase(DevicePath.adapter_path_key())
      :persistent_term.erase(DevicePath.desired_adapter_key())
    end)

    :ok = Phoenix.PubSub.subscribe(@pubsub, Bluetooth.state_topic())
    :ok
  end

  # Brings up the whole subsystem under the production-global names, with
  # fixture sysfs + a stub Bluez child — the shape the public API targets.
  defp start_subsystem do
    tmp = Path.join(System.tmp_dir!(), "bt_public_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(tmp) end)

    sysfs = Path.join(tmp, "sysfs")
    add_radio(sysfs, "hci0", @hci0_mac)
    add_radio(sysfs, "hci1", @hci1_mac)

    start_supervised!({Settings, table: @table, dets_path: Path.join(tmp, "s.dets")})
    dynsup = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    start_supervised!(
      {Manager,
       dynamic_supervisor: dynsup, bluez_child: StubBluez, sysfs_root: sysfs, pubsub: @pubsub}
    )

    # Radio MACs only exist via the daemon overlay (sysfs has none), so
    # select_radio's membership check depends on this stub.
    start_supervised!(
      {RadioMonitor,
       sysfs_root: sysfs,
       pubsub: @pubsub,
       poll_ms: 60_000,
       adapters_info_fun: fn ->
         [
           %{path: "/org/bluez/hci0", address: @hci0_mac, name: "pi", powered: true},
           %{path: "/org/bluez/hci1", address: @hci1_mac, name: "dongle", powered: true}
         ]
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

    test "radio reads degrade to empty lists" do
      assert Bluetooth.list_radios() == []
      assert Bluetooth.refresh_radios() == []
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
end
