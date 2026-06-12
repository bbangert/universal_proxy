defmodule UniversalProxy.Bluetooth.ManagerTest do
  # async: false — shares the global :persistent_term adapter-path key and
  # a constant DETS table atom across tests.
  use ExUnit.Case, async: false

  alias UniversalProxy.Bluetooth.{Manager, Settings}
  alias UniversalProxy.Bluez.DevicePath

  @pubsub UniversalProxy.PubSub
  @table :bluetooth_manager_test_settings

  @hci0_mac "B8:27:EB:11:22:33"
  @hci1_mac "AA:BB:CC:DD:EE:FF"

  defmodule StubBluez do
    @moduledoc "Stands in for the UniversalProxy.Bluez subtree in host tests."
    use Agent

    def start_link(_opts), do: Agent.start_link(fn -> :ok end)
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "bt_manager_test_#{System.unique_integer([:positive])}")

    sysfs = Path.join(tmp, "sys_class_bluetooth")
    write_adapter(sysfs, "hci0", @hci0_mac)
    write_adapter(sysfs, "hci1", @hci1_mac)

    dets_path = Path.join(tmp, "settings.dets")

    on_exit(fn ->
      :persistent_term.erase(DevicePath.adapter_path_key())
      :persistent_term.erase(DevicePath.desired_adapter_key())
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
    manager =
      start_supervised!(
        {Manager,
         [
           name: nil,
           settings: ctx.settings,
           dynamic_supervisor: ctx.dynsup,
           bluez_child: StubBluez,
           sysfs_root: ctx.sysfs,
           pubsub: @pubsub
         ] ++ opts}
      )

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

    test "disabled: leaves the subtree down but still reports a radio", ctx do
      :ok = Settings.set_enabled(ctx.settings, false)
      manager = start_manager(ctx)

      assert child_count(ctx.dynsup) == 0

      assert %{enabled: false, proxying?: false, adapter: %{hci: "hci0"}} =
               Manager.status(manager)

      assert_receive {:bluetooth_state, %{enabled: false, proxying?: false}}
    end

    test "a selected radio MAC is published as the desired adapter", ctx do
      :ok = Settings.set_adapter(ctx.settings, @hci1_mac)
      _manager = start_manager(ctx)

      assert :persistent_term.get(DevicePath.desired_adapter_key()) == @hci1_mac
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

    test "no controllers in sysfs: subtree still starts, no adapter shown when down", ctx do
      File.rm_rf!(ctx.sysfs)
      :ok = Settings.set_enabled(ctx.settings, false)
      manager = start_manager(ctx)

      assert %{proxying?: false, adapter: nil} = Manager.status(manager)

      # Enabling still starts the subtree — its own retry loop owns
      # controller absence.
      :ok = Settings.set_enabled(ctx.settings, true)
      :ok = Manager.reconcile(manager)
      assert child_count(ctx.dynsup) == 1
    end
  end

  describe "reconcile/2" do
    test "disable stops the subtree and broadcasts; enable restarts it", ctx do
      manager = start_manager(ctx)
      assert_receive {:bluetooth_state, %{proxying?: true}}

      :ok = Settings.set_enabled(ctx.settings, false)
      :ok = Manager.reconcile(manager)

      assert child_count(ctx.dynsup) == 0
      assert_receive {:bluetooth_state, %{enabled: false, proxying?: false}}

      :ok = Settings.set_enabled(ctx.settings, true)
      :ok = Manager.reconcile(manager)

      assert child_count(ctx.dynsup) == 1
      assert_receive {:bluetooth_state, %{enabled: true, proxying?: true}}
    end

    test "reconcile without changes is a no-op (still broadcasts)", ctx do
      manager = start_manager(ctx)
      [{_, pid, _, _}] = DynamicSupervisor.which_children(ctx.dynsup)

      :ok = Manager.reconcile(manager)

      assert [{_, ^pid, _, _}] = DynamicSupervisor.which_children(ctx.dynsup)
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

  describe "subtree crash" do
    test "broadcasts down, then re-binds to the supervisor's replacement", ctx do
      manager = start_manager(ctx)
      assert_receive {:bluetooth_state, %{proxying?: true}}

      [{_, pid, _, _}] = DynamicSupervisor.which_children(ctx.dynsup)
      Process.exit(pid, :kill)

      assert_receive {:bluetooth_state, %{proxying?: false}}, 1_000
      # Rebind tick is 1 s; the DynamicSupervisor restarts the child
      # immediately, so the next broadcast reports it back up.
      assert_receive {:bluetooth_state, %{proxying?: true}}, 3_000

      assert %{proxying?: true} = Manager.status(manager)
      [{_, new_pid, _, _}] = DynamicSupervisor.which_children(ctx.dynsup)
      assert new_pid != pid
    end
  end
end
