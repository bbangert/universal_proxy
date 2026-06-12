defmodule UniversalProxy.Bluetooth.RadiosTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Bluetooth.Radios

  @pi_mac "B8:27:EB:11:22:33"
  @dongle_mac "AA:BB:CC:DD:EE:FF"

  # DT/serdev modalias as the Pi kernel exposes it for the onboard radio.
  @bcm43438_modalias "of:NbluetoothT(null)Cbrcm,bcm43438-bt"
  # ASUS USB-BT500 interface modalias (RTL8761B behind ASUS's VID).
  @bt500_modalias "usb:v0B05p190Ed0200dc00dsc00dp00icE0isc01ip01in00"

  setup do
    root = Path.join(System.tmp_dir!(), "radios_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  # ── fixture builders ──────────────────────────────────────────────────────

  defp add_uart_radio(root, hci, mac, modalias_source \\ :modalias) do
    class_dir = Path.join(root, hci)
    File.mkdir_p!(class_dir)
    File.write!(Path.join(class_dir, "address"), mac <> "\n")

    device_dir = Path.join(root, "devices/platform/soc/3f201000.serial/serial0/serial0-0")
    File.mkdir_p!(device_dir)

    case modalias_source do
      :modalias -> File.write!(Path.join(device_dir, "modalias"), @bcm43438_modalias <> "\n")
      :uevent -> File.write!(Path.join(device_dir, "uevent"), uevent(@bcm43438_modalias))
      :none -> :ok
    end

    File.ln_s!(device_dir, Path.join(class_dir, "device"))
  end

  defp add_usb_radio(root, hci, mac, opts \\ []) do
    modalias = Keyword.get(opts, :modalias, @bt500_modalias)
    speed = Keyword.get(opts, :speed, "480")
    port = Keyword.get(opts, :port, "1-1.2")

    class_dir = Path.join(root, hci)
    File.mkdir_p!(class_dir)
    File.write!(Path.join(class_dir, "address"), mac <> "\n")

    usb_device_dir = Path.join(root, "devices/platform/soc/3f980000.usb/usb1/1-1/#{port}")
    intf_dir = Path.join(usb_device_dir, "#{port}:1.0")
    File.mkdir_p!(intf_dir)
    File.write!(Path.join(intf_dir, "modalias"), modalias <> "\n")
    if speed, do: File.write!(Path.join(usb_device_dir, "speed"), speed <> "\n")

    File.ln_s!(intf_dir, Path.join(class_dir, "device"))
  end

  defp uevent(modalias) do
    "DRIVER=hci_uart\nOF_NAME=bluetooth\nMODALIAS=#{modalias}\n"
  end

  # ── sysfs_adapters/1 ──────────────────────────────────────────────────────

  describe "sysfs_adapters/1" do
    test "missing root → []" do
      assert Radios.sysfs_adapters("/nonexistent/sysfs") == []
    end

    test "sorts by hci index and normalizes addresses", %{root: root} do
      add_uart_radio(root, "hci10", "b8:27:eb:00:00:10")
      add_usb_radio(root, "hci2", @dongle_mac)

      assert [%{hci: "hci2"}, %{hci: "hci10", address: "B8:27:EB:00:00:10"}] =
               Radios.sysfs_adapters(root)
    end

    test "all-zero address (uninitialized controller) reads as nil", %{root: root} do
      add_uart_radio(root, "hci0", "00:00:00:00:00:00")
      assert [%{hci: "hci0", address: nil}] = Radios.sysfs_adapters(root)
    end
  end

  # ── enumerate/1 ───────────────────────────────────────────────────────────

  describe "enumerate/1: SoC UART radio" do
    test "classifies the bus and identifies the chip from the DT modalias", %{root: root} do
      add_uart_radio(root, "hci0", @pi_mac)

      assert [
               %{
                 hci: "hci0",
                 address: @pi_mac,
                 bus: :uart,
                 detail: "SoC · UART",
                 chip: "Broadcom BCM43438 (CYW43438)",
                 bt_version: "4.1",
                 ble?: true,
                 bredr?: true
               }
             ] = Radios.enumerate(root)
    end

    test "falls back to the uevent MODALIAS line when modalias is absent", %{root: root} do
      add_uart_radio(root, "hci0", @pi_mac, :uevent)

      assert [%{bus: :uart, chip: "Broadcom BCM43438 (CYW43438)"}] = Radios.enumerate(root)
    end

    test "no modalias at all still classifies UART from the device path", %{root: root} do
      add_uart_radio(root, "hci0", @pi_mac, :none)

      assert [%{bus: :uart, detail: "SoC · UART", chip: "Unknown", bt_version: nil}] =
               Radios.enumerate(root)
    end
  end

  describe "enumerate/1: USB dongle" do
    test "parses VID:PID, port, and link speed (ASUS USB-BT500)", %{root: root} do
      add_usb_radio(root, "hci1", @dongle_mac)

      assert [
               %{
                 hci: "hci1",
                 address: @dongle_mac,
                 bus: :usb,
                 detail: "USB 2.0 · port 1-1.2",
                 chip: "Realtek RTL8761B (ASUS USB-BT500)",
                 bt_version: "5.0",
                 ble?: true,
                 bredr?: true
               }
             ] = Radios.enumerate(root)
    end

    test "unknown VID:PID → Unknown chip, bus details still parsed", %{root: root} do
      add_usb_radio(root, "hci1", @dongle_mac,
        modalias: "usb:v1234pABCDd0001dc00dsc00dp00icE0isc01ip01in00",
        port: "1-1.4",
        speed: "12"
      )

      assert [
               %{
                 bus: :usb,
                 detail: "USB 1.1 · port 1-1.4",
                 chip: "Unknown",
                 bt_version: nil
               }
             ] = Radios.enumerate(root)
    end

    test "missing speed attribute degrades to plain USB", %{root: root} do
      add_usb_radio(root, "hci1", @dongle_mac, speed: nil)

      assert [%{detail: "USB · port 1-1.2"}] = Radios.enumerate(root)
    end
  end

  describe "enumerate/1: degenerate trees" do
    test "device entry that is a plain dir with no hints → unknown bus", %{root: root} do
      class_dir = Path.join(root, "hci0")
      File.mkdir_p!(Path.join(class_dir, "device"))
      File.write!(Path.join(class_dir, "address"), @pi_mac)

      assert [%{bus: :unknown, detail: "Unknown", chip: "Unknown"}] = Radios.enumerate(root)
    end

    test "mixed tree enumerates everything in index order", %{root: root} do
      add_uart_radio(root, "hci0", @pi_mac)
      add_usb_radio(root, "hci1", @dongle_mac)

      assert [%{hci: "hci0", bus: :uart}, %{hci: "hci1", bus: :usb}] = Radios.enumerate(root)
    end
  end
end
