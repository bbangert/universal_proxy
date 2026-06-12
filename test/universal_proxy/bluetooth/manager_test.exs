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
    # Per-test overrides FIRST — Keyword.get takes the first match.
    manager =
      start_supervised!(
        {Manager,
         opts ++
           [
             name: nil,
             settings: ctx.settings,
             dynamic_supervisor: ctx.dynsup,
             bluez_child: StubBluez,
             sysfs_root: ctx.sysfs,
             pubsub: @pubsub
           ]}
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
      # immediately, so the next broadcast reports it back up.
      assert_receive {:bluetooth_state, %{proxying?: true}}, 3_000

      assert %{proxying?: true} = Manager.status(manager)
      [{_, new_pid, _, _}] = DynamicSupervisor.which_children(ctx.dynsup)
      assert new_pid != pid
    end
  end
end
