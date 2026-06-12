defmodule UniversalProxy.Bluetooth.RadioMonitorTest do
  # async: false — writes the global :persistent_term adapter path.
  use ExUnit.Case, async: false

  alias UniversalProxy.Bluetooth.RadioMonitor
  alias UniversalProxy.Bluez.DevicePath

  @pubsub UniversalProxy.PubSub

  @pi_mac "B8:27:EB:11:22:33"
  @dongle_mac "AA:BB:CC:DD:EE:FF"

  setup do
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
      start_supervised!({RadioMonitor,
       opts ++
         [
           name: nil,
           sysfs_root: ctx.root,
           pubsub: @pubsub,
           # Long enough that tests drive refresh explicitly unless they
           # opt into a fast poll.
           poll_ms: 60_000,
           adapters_info_fun: fn ->
             [%{path: "/org/bluez/hci0", address: @pi_mac, name: "raspberrypi", powered: true}]
           end,
           proxying_fun: fn -> true end
         ]})

    # init's first enumeration runs in handle_continue — synchronize.
    _ = RadioMonitor.list(monitor)
    monitor
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

  test "nothing is in use while the subtree is down", ctx do
    :persistent_term.put(DevicePath.adapter_path_key(), "/org/bluez/hci0")
    monitor = start_monitor(ctx, proxying_fun: fn -> false end)

    assert [%{hci: "hci0", in_use?: false}] = RadioMonitor.list(monitor)
  end

  test "radios without live daemon info get name: nil", ctx do
    monitor = start_monitor(ctx, adapters_info_fun: fn -> [] end)

    assert [%{hci: "hci0", name: nil}] = RadioMonitor.list(monitor)
  end

  test "the first enumeration broadcasts; refresh broadcasts only on change", ctx do
    monitor = start_monitor(ctx)
    assert_receive {:bluetooth_radios, [%{hci: "hci0"}]}

    # Unchanged refresh: no broadcast.
    _ = RadioMonitor.refresh(monitor)
    refute_receive {:bluetooth_radios, _}, 100

    # Hotplug: a dongle appears, refresh picks it up and broadcasts.
    add_uart_radio(ctx.root, "hci1", @dongle_mac)

    assert [%{hci: "hci0"}, %{hci: "hci1", address: @dongle_mac}] =
             RadioMonitor.refresh(monitor)

    assert_receive {:bluetooth_radios, [_, %{hci: "hci1"}]}
  end

  test "the poll picks up hotplug without an explicit refresh", ctx do
    monitor = start_monitor(ctx, poll_ms: 50)
    assert_receive {:bluetooth_radios, [%{hci: "hci0"}]}

    add_uart_radio(ctx.root, "hci1", @dongle_mac)

    assert_receive {:bluetooth_radios, [_, %{hci: "hci1"}]}, 1_000
    assert [_, %{hci: "hci1"}] = RadioMonitor.list(monitor)
  end

  test "empty sysfs → empty list, no crash", ctx do
    File.rm_rf!(ctx.root)
    monitor = start_monitor(ctx)

    assert RadioMonitor.list(monitor) == []
  end
end
