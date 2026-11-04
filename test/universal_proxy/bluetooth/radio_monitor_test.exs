defmodule UniversalProxy.Bluetooth.RadioMonitorTest do
  # async: false — writes the global :persistent_term adapter path.
  use ExUnit.Case, async: false

  alias UniversalProxy.Bluetooth.{HeldRadios, RadioMonitor}
  alias Bluez.{Client, DevicePath}

  @pubsub UniversalProxy.PubSub

  @pi_mac "B8:27:EB:11:22:33"
  @dongle_mac "AA:BB:CC:DD:EE:FF"

  setup do
    # Pre-clear too — a crashed predecessor's stale adapter path would
    # flip in_use? assertions.
    :persistent_term.erase(DevicePath.adapter_path_key())

    root = Path.join(System.tmp_dir!(), "radio_mon_test_#{System.unique_integer([:positive])}")
    add_uart_radio(root, "hci0", @pi_mac)

    on_exit(fn ->
      :persistent_term.erase(DevicePath.adapter_path_key())
      File.rm_rf(root)
    end)

    :ok = Phoenix.PubSub.subscribe(@pubsub, UniversalProxy.Bluetooth.radios_topic())

    {:ok, root: root}
  end

  defp add_uart_radio(root, hci, mac) do
    class_dir = Path.join(root, hci)
    File.mkdir_p!(class_dir)
    File.write!(Path.join(class_dir, "address"), mac <> "\n")

    device_dir = Path.join(root, "devices/serial/#{hci}-dev")
    File.mkdir_p!(device_dir)
    File.write!(Path.join(device_dir, "modalias"), "of:NbluetoothT(null)Cbrcm,bcm43438-bt\n")
    File.ln_s!(device_dir, Path.join(class_dir, "device"))
  end

  defp start_monitor(ctx, opts \\ []) do
    # Per-test overrides FIRST — Keyword.get takes the first match.
    monitor =
      start_supervised!(
        {RadioMonitor,
         opts ++
           [
             name: nil,
             sysfs_root: ctx.root,
             pubsub: @pubsub,
             adapters_info_fun: fn ->
               [%{path: "/org/bluez/hci0", address: @pi_mac, name: "raspberrypi", powered: true}]
             end
           ]}
      )

    # init's first enumeration runs in handle_continue — synchronize.
    _ = RadioMonitor.list(monitor)
    monitor
  end

  # Simulate the Bluez.Client adapter-change broadcast that drives a
  # re-enumeration (claim at setup, or a hotplug InterfacesAdded/Removed).
  defp signal_adapters_changed do
    Phoenix.PubSub.broadcast(@pubsub, Client.adapters_topic(), {:bluetooth_adapters_changed})
  end

  test "list/1 overlays the live Adapter1 name and marks the radio in use", ctx do
    :persistent_term.put(DevicePath.adapter_path_key(), "/org/bluez/hci0")
    monitor = start_monitor(ctx)

    assert [
             %{
               hci: "hci0",
               address: @pi_mac,
               name: "raspberrypi",
               chip: "Broadcom BCM43438 (CYW43438)",
               bus: :uart,
               in_use?: true
             }
           ] = RadioMonitor.list(monitor)
  end

  test "a radio that isn't the active adapter path is not in use", ctx do
    :persistent_term.put(DevicePath.adapter_path_key(), "/org/bluez/hci1")
    monitor = start_monitor(ctx)

    assert [%{hci: "hci0", in_use?: false}] = RadioMonitor.list(monitor)
  end

  test "nothing is in use while the daemon is down (no overlay)", ctx do
    :persistent_term.put(DevicePath.adapter_path_key(), "/org/bluez/hci0")
    monitor = start_monitor(ctx, adapters_info_fun: fn -> [] end)

    assert [%{hci: "hci0", in_use?: false, name: nil, address: nil}] =
             RadioMonitor.list(monitor)
  end

  test "the first enumeration broadcasts; refresh broadcasts only on change", ctx do
    monitor = start_monitor(ctx)
    assert_receive {:bluetooth_radios, [%{hci: "hci0"}]}

    # Unchanged refresh: no broadcast.
    _ = RadioMonitor.refresh(monitor)
    refute_receive {:bluetooth_radios, _}, 100

    # Hotplug: a dongle appears, refresh picks it up and broadcasts. No
    # daemon overlay entry for it → no address yet.
    add_uart_radio(ctx.root, "hci1", @dongle_mac)

    assert [%{hci: "hci0"}, %{hci: "hci1", address: nil}] =
             RadioMonitor.refresh(monitor)

    assert_receive {:bluetooth_radios, [_, %{hci: "hci1"}]}
  end

  test "an adapter-change signal re-enumerates without an explicit refresh", ctx do
    monitor = start_monitor(ctx)
    assert_receive {:bluetooth_radios, [%{hci: "hci0"}]}

    # A dongle appears and the Client broadcasts the adapter-change event;
    # RadioMonitor re-enumerates and broadcasts the new list — no poll.
    add_uart_radio(ctx.root, "hci1", @dongle_mac)
    signal_adapters_changed()

    assert_receive {:bluetooth_radios, [_, %{hci: "hci1"}]}, 1_000
    assert [_, %{hci: "hci1"}] = RadioMonitor.list(monitor)
  end

  test "empty sysfs → empty list, no crash", ctx do
    File.rm_rf!(ctx.root)
    monitor = start_monitor(ctx)

    assert RadioMonitor.list(monitor) == []
  end

  test "the mesh radio is never in_use?, even on the claimed/default path", ctx do
    # A lone mesh radio at hci0: the client never claims it, but hci0 is the
    # default adapter path.
    :persistent_term.put(DevicePath.adapter_path_key(), "/org/bluez/hci0")
    monitor = start_monitor(ctx, roles_fun: fn -> %{@pi_mac => :tuya_mesh} end)

    assert [%{address: @pi_mac, role: :tuya_mesh, in_use?: false}] = RadioMonitor.list(monitor)
  end

  describe "held radios" do
    setup ctx do
      add_uart_radio(ctx.root, "hci1", @dongle_mac)
      registry = :"radio_monitor_held_#{System.unique_integer([:positive])}"
      start_supervised!({HeldRadios, registry: registry})

      live =
        start_supervised!(
          {Agent,
           fn ->
             [
               %{path: "/org/bluez/hci0", address: @pi_mac, name: "raspberrypi", powered: true},
               %{path: "/org/bluez/hci1", address: @dongle_mac, name: "dongle", powered: true}
             ]
           end}
        )

      {:ok, registry: registry, live: live}
    end

    defp start_held_monitor(ctx, opts \\ []) do
      start_monitor(
        ctx,
        opts ++
          [
            adapters_info_fun: fn -> Agent.get(ctx.live, & &1) end,
            held_fun: fn -> HeldRadios.list(registry: ctx.registry) end,
            roles_fun: fn -> %{@dongle_mac => :tuya_mesh} end
          ]
      )
    end

    # A process holding `mac` at `index`, as the mesh Radio does over the
    # user channel, until killed.
    defp hold(ctx, mac, index) do
      test = self()

      pid =
        spawn(fn ->
          :ok = HeldRadios.hold(mac, index, registry: ctx.registry, pubsub: @pubsub)
          send(test, :held)
          Process.sleep(:infinity)
        end)

      assert_receive :held
      pid
    end

    # bluetoothd drops a held adapter.
    defp unlist(ctx, hci),
      do:
        Agent.update(ctx.live, fn live -> Enum.reject(live, &(&1.path == "/org/bluez/#{hci}")) end)

    test "a held radio keeps its MAC, role and last-known name, never in use", ctx do
      :persistent_term.put(DevicePath.adapter_path_key(), "/org/bluez/hci1")
      monitor = start_held_monitor(ctx)

      assert [%{held: nil}, %{hci: "hci1", address: @dongle_mac, held: nil}] =
               RadioMonitor.list(monitor)

      unlist(ctx, "hci1")
      hold(ctx, @dongle_mac, 1)

      # The hold's broadcast re-enumerates.
      assert_receive {:bluetooth_radios, [_, %{hci: "hci1", held: :tuya_mesh}]}, 1_000

      assert [
               %{hci: "hci0", address: @pi_mac, held: nil},
               %{
                 hci: "hci1",
                 address: @dongle_mac,
                 name: "dongle",
                 chip: "Broadcom BCM43438 (CYW43438)",
                 role: :tuya_mesh,
                 held: :tuya_mesh,
                 in_use?: false
               }
             ] = RadioMonitor.list(monitor)
    end

    test "a stale daemon row naming a held MAC loses it: the MAC is listed once", ctx do
      # bluetoothd still names the dongle, now under hci0, while it is held
      # at hci1.
      Agent.update(ctx.live, fn _ ->
        [%{path: "/org/bluez/hci0", address: @dongle_mac, name: "dongle", powered: true}]
      end)

      hold(ctx, @dongle_mac, 1)
      monitor = start_held_monitor(ctx)

      radios = RadioMonitor.list(monitor)

      assert [%{hci: "hci1", held: :tuya_mesh}] =
               Enum.filter(radios, &(&1.address == @dongle_mac))

      assert %{hci: "hci0", address: nil, role: nil, held: nil} = hd(radios)
    end

    test "a held index sysfs doesn't show is listed from what was last seen", ctx do
      monitor = start_held_monitor(ctx)
      _ = RadioMonitor.list(monitor)

      # Re-enumerated under hci2 before sysfs shows it; the name and chip are
      # what the MAC last had.
      unlist(ctx, "hci1")
      File.rm_rf!(Path.join(ctx.root, "hci1"))
      hold(ctx, @dongle_mac, 2)

      assert [
               %{hci: "hci0"},
               %{
                 hci: "hci2",
                 address: @dongle_mac,
                 name: "dongle",
                 chip: "Broadcom BCM43438 (CYW43438)",
                 held: :tuya_mesh
               }
             ] = RadioMonitor.refresh(monitor)

      # Never seen before: a minimal row.
      hold(ctx, "11:22:33:44:55:66", 3)

      assert %{hci: "hci3", chip: "Unknown", name: nil, held: :tuya_mesh} =
               List.last(RadioMonitor.refresh(monitor))
    end

    test "a holder exiting re-enumerates (a crash sends no broadcast)", ctx do
      unlist(ctx, "hci1")
      pid = hold(ctx, @dongle_mac, 1)
      monitor = start_held_monitor(ctx)
      assert [_, %{address: @dongle_mac, held: :tuya_mesh}] = RadioMonitor.list(monitor)

      Process.exit(pid, :kill)

      assert_receive {:bluetooth_radios, [_, %{hci: "hci1", address: nil, held: nil}]}, 1_000
    end
  end
end
