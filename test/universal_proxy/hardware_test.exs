defmodule UniversalProxy.HardwareTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Hardware

  describe "known_devices/0" do
    test "includes the Sennheiser BTD 700 as a locked bt_audio device" do
      assert {0x3542, 0x3001, info} =
               Enum.find(Hardware.known_devices(), fn {vid, pid, _} ->
                 {vid, pid} == {0x3542, 0x3001}
               end)

      assert info.kind == :bt_audio
      assert info.name == "Sennheiser BTD 700"
      assert info.locked == true
    end
  end

  describe "list_ports/1 in dynamic mode (no slot mapping)" do
    test "auto-detects a Z-Wave ZWA-2 by VID/PID and locks the kind" do
      [port] =
        Hardware.list_ports(
          slots: nil,
          enumerated: %{
            "ttyACM0" => %{
              vendor_id: 0x303A,
              product_id: 0x4001,
              manufacturer: "Nabu Casa",
              description: "Home Assistant Connect ZWA-2",
              serial_number: "DH001K8R"
            }
          },
          bus_paths: %{"ttyACM0" => "1-1.1"},
          saved_configs: %{},
          line_settings: %{},
          in_use_ports: MapSet.new()
        )

      assert port.detection == :auto
      assert port.kind == :zwave
      assert port.kind_label == "Z-Wave"
      assert port.name == "Home Assistant Connect ZWA-2"
      assert port.vendor == "Nabu Casa"
      assert port.chip == "Silicon Labs EFR32ZG23"
      assert port.serial == "DH001K8R"
      assert port.vidpid == "303A:4001"
      assert port.configured == true
      assert port.locked == true
      assert port.connected == true
      assert port.device == "/dev/ttyACM0"
      assert port.tty_name == "ttyACM0"
      assert port.slot == "USB 1"
      assert port.slot_sub == "1-1.1"
      assert port.id == "p_1_1_1"
    end

    test "auto-detects a generic FTDI cable as TTL (editable, not locked)" do
      [port] =
        Hardware.list_ports(
          slots: nil,
          enumerated: %{
            "ttyUSB0" => %{
              vendor_id: 0x0403,
              product_id: 0x6001,
              manufacturer: "FTDI",
              description: "FT232R USB UART",
              serial_number: "BG018NOP"
            }
          },
          bus_paths: %{"ttyUSB0" => "1-1.3"},
          saved_configs: %{},
          line_settings: %{},
          in_use_ports: MapSet.new()
        )

      assert port.detection == :auto
      assert port.kind == :ttl
      assert port.kind_label == "TTL"
      assert port.name == "USB Serial Adapter"
      assert port.vendor == "FTDI"
      assert port.chip == "FT232RL"
      assert port.locked == false
      assert port.configured == true
    end

    test "auto-detects a CH340 cable as TTL" do
      [port] =
        Hardware.list_ports(
          slots: nil,
          enumerated: %{
            "ttyUSB0" => %{
              vendor_id: 0x1A86,
              product_id: 0x7523,
              manufacturer: "QinHeng Electronics",
              description: "USB Serial",
              serial_number: nil
            }
          },
          bus_paths: %{"ttyUSB0" => "1-1.4"},
          saved_configs: %{},
          line_settings: %{},
          in_use_ports: MapSet.new()
        )

      assert port.detection == :auto
      assert port.kind == :ttl
      assert port.name == "USB Serial Adapter"
      assert port.chip == "CH340"
      assert port.locked == false
    end

    test "saved config overrides chipset default kind" do
      [port] =
        Hardware.list_ports(
          slots: nil,
          enumerated: %{
            "ttyUSB0" => %{
              vendor_id: 0x0403,
              product_id: 0x6001,
              manufacturer: "FTDI",
              description: "USB Serial Adapter",
              serial_number: "FTAB5QZ1"
            }
          },
          bus_paths: %{"ttyUSB0" => "1-1.3"},
          saved_configs: %{
            {"1-1.3", 0x0403, 0x6001} => %{
              slot_sub: "1-1.3",
              vendor_id: 0x0403,
              product_id: 0x6001,
              serial_number: "FTAB5QZ1",
              port_type: :rs485,
              friendly_name: "Modbus bus"
            }
          },
          line_settings: %{},
          in_use_ports: MapSet.new()
        )

      # Saved RS-485 wins over the chipset default of TTL.
      assert port.detection == :manual
      assert port.kind == :rs485
      assert port.kind_label == "RS-485"
      assert port.locked == false
      assert port.name == "Modbus bus"
      # Chip info still flows through from the device table.
      assert port.chip == "FT232RL"
    end

    test "saved config does NOT override branded locked devices" do
      [port] =
        Hardware.list_ports(
          slots: nil,
          enumerated: %{
            "ttyACM0" => %{
              vendor_id: 0x303A,
              product_id: 0x4001,
              serial_number: "DH001K8R"
            }
          },
          bus_paths: %{"ttyACM0" => "1-1.1"},
          # Even if a saved config somehow exists for this port + chip,
          # we must not let it override the hardware-fixed Z-Wave kind.
          saved_configs: %{
            {"1-1.1", 0x303A, 0x4001} => %{
              slot_sub: "1-1.1",
              vendor_id: 0x303A,
              product_id: 0x4001,
              serial_number: "DH001K8R",
              port_type: :rs485
            }
          },
          line_settings: %{},
          in_use_ports: MapSet.new()
        )

      assert port.kind == :zwave
      assert port.detection == :auto
      assert port.locked == true
    end

    # Regression guard for the ZWA-2 VID/PID mixup: 10C4:EA60 is the
    # generic CP2102/CP2102N bridge (used by SONOFF Z-Wave dongles and
    # countless TTL adapters) — it must classify as editable TTL, never
    # as a locked ZWA-2.
    test "auto-detects a CP2102 (10C4:EA60) as generic TTL, not a ZWA-2" do
      [port] =
        Hardware.list_ports(
          slots: nil,
          enumerated: %{
            "ttyUSB0" => %{
              vendor_id: 0x10C4,
              product_id: 0xEA60,
              manufacturer: "Silicon Labs",
              description: "CP2102N USB to UART Bridge Controller",
              serial_number: "DH001K8R"
            }
          },
          bus_paths: %{"ttyUSB0" => "1-1.2"},
          saved_configs: %{},
          line_settings: %{},
          in_use_ports: MapSet.new()
        )

      assert port.detection == :auto
      assert port.kind == :ttl
      assert port.name == "USB Serial Adapter"
      assert port.chip == "CP2102/CP2102N"
      assert port.locked == false
    end

    # A SONOFF Z-Wave dongle shares the CP210x VID/PID with plain serial
    # cables; the USB descriptor string is what distinguishes it (HA does
    # the same). NOT HW-validated — no SONOFF stick on the testbed.
    test "auto-detects a SONOFF Z-Wave dongle (10C4:EA60) by descriptor" do
      [port] =
        Hardware.list_ports(
          slots: nil,
          enumerated: %{
            "ttyUSB0" => %{
              vendor_id: 0x10C4,
              product_id: 0xEA60,
              manufacturer: "ITEAD",
              description: "SONOFF Zwave 800 Dongle Plus",
              serial_number: "SZW800"
            }
          },
          bus_paths: %{"ttyUSB0" => "1-1.2"},
          saved_configs: %{},
          line_settings: %{},
          in_use_ports: MapSet.new()
        )

      assert port.detection == :auto
      assert port.kind == :zwave
      assert port.locked == true
      assert port.name == "SONOFF Zwave 800 Dongle Plus"
    end

    test "auto-detects a Nortek-style CP210x by '*z-wave*' descriptor" do
      [port] =
        Hardware.list_ports(
          slots: nil,
          enumerated: %{
            "ttyUSB0" => %{
              vendor_id: 0x10C4,
              product_id: 0x8A2A,
              description: "HubZ Smart Home Controller — Z-Wave",
              serial_number: "N1"
            }
          },
          bus_paths: %{"ttyUSB0" => "1-1.2"},
          saved_configs: %{},
          line_settings: %{},
          in_use_ports: MapSet.new()
        )

      assert port.kind == :zwave
      assert port.locked == true
    end

    test "auto-detects an Aeotec Z-Stick (0658:0200) as locked Z-Wave" do
      [port] =
        Hardware.list_ports(
          slots: nil,
          enumerated: %{
            "ttyACM0" => %{vendor_id: 0x0658, product_id: 0x0200, serial_number: "AE1"}
          },
          bus_paths: %{"ttyACM0" => "1-1.2"},
          saved_configs: %{},
          line_settings: %{},
          in_use_ports: MapSet.new()
        )

      assert port.kind == :zwave
      assert port.locked == true
      assert port.name == "Aeotec Z-Stick Gen5+"
    end

    test "auto-detects branded IRdroid IR Toy as locked IR" do
      [port] =
        Hardware.list_ports(
          slots: nil,
          enumerated: %{
            "ttyACM1" => %{
              vendor_id: 0x04D8,
              product_id: 0xFD08,
              serial_number: "IRT-7B2A-9F"
            }
          },
          bus_paths: %{"ttyACM1" => "1-1.2"},
          saved_configs: %{},
          line_settings: %{},
          in_use_ports: MapSet.new()
        )

      assert port.detection == :auto
      assert port.kind == :ir
      assert port.name == "IRdroid IR Toy"
      assert port.locked == true
    end

    test "auto-detects Hardware Group USB Infrared Transceiver as locked IR" do
      [port] =
        Hardware.list_ports(
          slots: nil,
          enumerated: %{
            "ttyACM0" => %{
              vendor_id: 0x04D8,
              product_id: 0xF58B,
              manufacturer: "Hardware Group LTD",
              description: "USB Infrared Transceiver",
              serial_number: "352"
            }
          },
          bus_paths: %{"ttyACM0" => "1-1.2"},
          saved_configs: %{},
          line_settings: %{},
          in_use_ports: MapSet.new()
        )

      assert port.detection == :auto
      assert port.kind == :ir
      assert port.name == "USB Infrared Transceiver"
      assert port.locked == true
    end

    test "marks an unknown VID/PID with no saved config as needs setup" do
      [port] =
        Hardware.list_ports(
          slots: nil,
          enumerated: %{
            "ttyUSB0" => %{
              vendor_id: 0x9999,
              product_id: 0xAAAA,
              manufacturer: "Acme Co",
              description: "Mystery Adapter",
              serial_number: nil
            }
          },
          bus_paths: %{"ttyUSB0" => "1-1.4"},
          saved_configs: %{},
          line_settings: %{},
          in_use_ports: MapSet.new()
        )

      assert port.detection == :unknown
      assert port.kind == nil
      assert port.kind_label == "Generic USB serial"
      assert port.configured == false
      assert port.locked == false
      assert port.vidpid == "9999:AAAA"
    end

    test "an unknown adapter with a saved config becomes manual-configured" do
      [port] =
        Hardware.list_ports(
          slots: nil,
          enumerated: %{
            "ttyUSB0" => %{
              vendor_id: 0x9999,
              product_id: 0xAAAA,
              manufacturer: "Acme Co",
              description: "Mystery Adapter",
              serial_number: "MY123"
            }
          },
          bus_paths: %{"ttyUSB0" => "1-1.3"},
          saved_configs: %{
            {"1-1.3", 0x9999, 0xAAAA} => %{
              slot_sub: "1-1.3",
              vendor_id: 0x9999,
              product_id: 0xAAAA,
              serial_number: "MY123",
              port_type: :rs485,
              friendly_name: "Bus A"
            }
          },
          line_settings: %{},
          in_use_ports: MapSet.new()
        )

      assert port.detection == :manual
      assert port.kind == :rs485
      assert port.kind_label == "RS-485"
      assert port.configured == true
      assert port.locked == false
      assert port.name == "Bus A"
    end

    test "zwave-claimed port shows in_use with the Z-Wave JS user label" do
      base = [
        slots: nil,
        enumerated: %{
          "ttyACM0" => %{vendor_id: 0x303A, product_id: 0x4001, serial_number: "DH001K8R"}
        },
        bus_paths: %{"ttyACM0" => "1-1.1"},
        saved_configs: %{},
        line_settings: %{},
        in_use_ports: MapSet.new()
      ]

      [subscribed] =
        Hardware.list_ports(base ++ [zwave_claim: %{tty_name: "ttyACM0", subscribed: true}])

      assert subscribed.in_use == true
      assert subscribed.user == "Z-Wave JS · Home Assistant"

      [idle] =
        Hardware.list_ports(base ++ [zwave_claim: %{tty_name: "ttyACM0", subscribed: false}])

      assert idle.in_use == true
      assert idle.user == "Z-Wave proxy"

      [unclaimed] = Hardware.list_ports(base ++ [zwave_claim: nil])
      assert unclaimed.in_use == false
      assert unclaimed.user == nil
    end

    test "zwave claim on a different tty does not mark this port in_use" do
      [port] =
        Hardware.list_ports(
          slots: nil,
          enumerated: %{
            "ttyUSB0" => %{vendor_id: 0x0403, product_id: 0x6001, serial_number: "X"}
          },
          bus_paths: %{"ttyUSB0" => "1-1.2"},
          saved_configs: %{},
          line_settings: %{},
          in_use_ports: MapSet.new(),
          zwave_claim: %{tty_name: "ttyACM0", subscribed: true}
        )

      assert port.in_use == false
      assert port.user == nil
    end

    test "marks port as in_use when its tty name is currently opened" do
      [port] =
        Hardware.list_ports(
          slots: nil,
          enumerated: %{
            "ttyACM0" => %{vendor_id: 0x10C4, product_id: 0xEA60, serial_number: "DH001K8R"}
          },
          bus_paths: %{"ttyACM0" => "1-1.1"},
          saved_configs: %{},
          line_settings: %{},
          in_use_ports: MapSet.new(["ttyACM0"])
        )

      assert port.in_use == true
      assert port.user == "ESPHome serial proxy"
    end

    test "skips built-in SoC UARTs (ttyAMA, ttyS)" do
      ports =
        Hardware.list_ports(
          slots: nil,
          enumerated: %{
            "ttyAMA0" => %{},
            "ttyS0" => %{},
            "ttyUSB0" => %{vendor_id: 0x0403, product_id: 0x6001, serial_number: "X"}
          },
          bus_paths: %{"ttyUSB0" => "1-1.2"},
          saved_configs: %{},
          line_settings: %{},
          in_use_ports: MapSet.new()
        )

      assert [%{tty_name: "ttyUSB0"}] = ports
    end

    test "sorts ports by physical bus path" do
      ports =
        Hardware.list_ports(
          slots: nil,
          enumerated: %{
            "ttyUSB1" => %{vendor_id: 0x0403, product_id: 0x6001, serial_number: "A"},
            "ttyUSB0" => %{vendor_id: 0x0403, product_id: 0x6001, serial_number: "B"},
            "ttyACM0" => %{vendor_id: 0x10C4, product_id: 0xEA60, serial_number: "C"}
          },
          bus_paths: %{"ttyUSB1" => "1-1.4", "ttyUSB0" => "1-1.3", "ttyACM0" => "1-1.2"},
          saved_configs: %{},
          line_settings: %{},
          in_use_ports: MapSet.new()
        )

      assert Enum.map(ports, & &1.slot_sub) == ["1-1.2", "1-1.3", "1-1.4"]
      assert Enum.map(ports, & &1.slot) == ["USB 1", "USB 2", "USB 3"]
    end
  end

  describe "list_ports/1 persisted line settings" do
    test "a matching :line_settings entry decorates the port with real values" do
      [port] =
        Hardware.list_ports(
          slots: nil,
          enumerated: %{
            "ttyUSB0" => %{
              vendor_id: 0x0403,
              product_id: 0x6001,
              manufacturer: "FTDI",
              description: "FT232R USB UART",
              serial_number: "BG018NOP"
            }
          },
          bus_paths: %{"ttyUSB0" => "1-1.3"},
          saved_configs: %{},
          line_settings: %{
            "p_1_1_3" => [
              speed: 115_200,
              data_bits: 8,
              stop_bits: 1,
              parity: :none,
              flow_control: :none
            ]
          },
          in_use_ports: MapSet.new()
        )

      assert port.id == "p_1_1_3"
      assert port.baud == 115_200
      assert port.data_bits == 8
      assert port.stop_bits == 1
      assert port.parity == "none"
    end

    test "no matching :line_settings entry leaves baud nil (unchanged shape)" do
      [port] =
        Hardware.list_ports(
          slots: nil,
          enumerated: %{
            "ttyUSB0" => %{
              vendor_id: 0x0403,
              product_id: 0x6001,
              manufacturer: "FTDI",
              description: "FT232R USB UART",
              serial_number: "BG018NOP"
            }
          },
          bus_paths: %{"ttyUSB0" => "1-1.3"},
          saved_configs: %{},
          line_settings: %{},
          in_use_ports: MapSet.new()
        )

      assert port.baud == nil
    end
  end

  describe "list_ports/1 in slot mode (per-target topology)" do
    test "renders one row per declared slot, even unplugged ones" do
      ports =
        Hardware.list_ports(
          slots: ["1-1.1.2", "1-1.1.3", "1-1.2", "1-1.3"],
          enumerated: %{
            "ttyACM0" => %{vendor_id: 0x04D8, product_id: 0xF58B, serial_number: "352"},
            "ttyUSB0" => %{vendor_id: 0x0403, product_id: 0x6001, serial_number: "BG018NOP"},
            "ttyUSB1" => %{vendor_id: 0x0403, product_id: 0x6001, serial_number: "FTEM3U93"}
          },
          bus_paths: %{
            "ttyUSB1" => "1-1.1.2",
            "ttyACM0" => "1-1.2",
            "ttyUSB0" => "1-1.3"
          },
          saved_configs: %{},
          line_settings: %{},
          in_use_ports: MapSet.new()
        )

      assert length(ports) == 4
      assert Enum.map(ports, & &1.slot_sub) == ["1-1.1.2", "1-1.1.3", "1-1.2", "1-1.3"]
      assert Enum.map(ports, & &1.slot) == ["USB 1", "USB 2", "USB 3", "USB 4"]
      assert Enum.map(ports, & &1.connected) == [true, false, true, true]

      [_, empty, _, _] = ports
      assert empty.slot_sub == "1-1.1.3"
      assert empty.connected == false
      assert empty.in_use == false
      assert empty.configured == false
      assert empty.id == "p_1_1_1_3"
      assert empty.kind == nil
      assert empty.device == nil
    end

    test "preserves declared slot order even when sysfs returns sources unordered" do
      ports =
        Hardware.list_ports(
          slots: ["1-1.1.2", "1-1.1.3", "1-1.2", "1-1.3"],
          enumerated: %{},
          bus_paths: %{},
          saved_configs: %{},
          line_settings: %{},
          in_use_ports: MapSet.new()
        )

      assert Enum.map(ports, & &1.slot_sub) == ["1-1.1.2", "1-1.1.3", "1-1.2", "1-1.3"]
      assert Enum.all?(ports, &(&1.connected == false))
    end

    test "appends bonus rows for plugged adapters not in the slot list" do
      ports =
        Hardware.list_ports(
          slots: ["1-1.2", "1-1.3"],
          enumerated: %{
            "ttyUSB0" => %{vendor_id: 0x0403, product_id: 0x6001, serial_number: "X"},
            "ttyUSB9" => %{vendor_id: 0x0403, product_id: 0x6001, serial_number: "Y"}
          },
          bus_paths: %{
            "ttyUSB0" => "1-1.2",
            "ttyUSB9" => "1-1.99"
          },
          saved_configs: %{},
          line_settings: %{},
          in_use_ports: MapSet.new()
        )

      assert length(ports) == 3
      assert Enum.map(ports, & &1.slot_sub) == ["1-1.2", "1-1.3", "1-1.99"]
    end
  end

  describe "list_ports/1 fallback behaviour" do
    test "returns an empty list when nothing is plugged in and dynamic mode" do
      assert Hardware.list_ports(
               slots: nil,
               enumerated: %{},
               bus_paths: %{},
               saved_configs: %{},
               line_settings: %{},
               in_use_ports: MapSet.new()
             ) == []
    end

    test "derives a stable HTML-safe id from the slot path" do
      [port] =
        Hardware.list_ports(
          slots: nil,
          enumerated: %{"ttyUSB0" => %{vendor_id: 0x0403, product_id: 0x6001}},
          bus_paths: %{"ttyUSB0" => "1-1.2.3"},
          saved_configs: %{},
          line_settings: %{},
          in_use_ports: MapSet.new()
        )

      assert port.slot_sub == "1-1.2.3"
      assert port.id == "p_1_1_2_3"
    end
  end

  describe "list_ports/1 sysfs walk" do
    # Builds a fake /sys/class/tty/ tree with matching symlinks so the
    # parse_bus_path/1 logic gets exercised end-to-end.
    test "extracts bus paths from /sys/class/tty symlinks" do
      dir = Path.join(System.tmp_dir!(), "uph-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      # Match the real Pi3 layout from the dev device.
      File.ln_s!(
        "../../devices/platform/soc/3f980000.usb/usb1/1-1/1-1.3/1-1.3:1.0/ttyUSB0/tty/ttyUSB0",
        Path.join(dir, "ttyUSB0")
      )

      File.ln_s!(
        "../../devices/platform/soc/3f980000.usb/usb1/1-1/1-1.1/1-1.1.2/1-1.1.2:1.0/ttyUSB1/tty/ttyUSB1",
        Path.join(dir, "ttyUSB1")
      )

      File.ln_s!(
        "../../devices/platform/soc/3f980000.usb/usb1/1-1/1-1.2/1-1.2:1.0/tty/ttyACM0",
        Path.join(dir, "ttyACM0")
      )

      # Built-in UART that should be ignored by usb_serial?/1
      File.ln_s!("../../foo/ttyAMA0", Path.join(dir, "ttyAMA0"))

      ports =
        Hardware.list_ports(
          slots: nil,
          enumerated: %{
            "ttyACM0" => %{vendor_id: 0x04D8, product_id: 0xF58B, serial_number: "352"},
            "ttyUSB0" => %{vendor_id: 0x0403, product_id: 0x6001, serial_number: "BG018NOP"},
            "ttyUSB1" => %{vendor_id: 0x0403, product_id: 0x6001, serial_number: "FTEM3U93"}
          },
          tty_class_dir: dir,
          saved_configs: %{},
          line_settings: %{},
          in_use_ports: MapSet.new()
        )

      assert Enum.map(ports, & &1.slot_sub) == ["1-1.1.2", "1-1.2", "1-1.3"]
    end
  end

  describe "usb_hubs/1" do
    # Build a fake /sys/bus/usb/devices tree with a hub, a non-hub device,
    # and a root hub, then assert only the real hub is detected.
    test "detects hub-class devices and parses their descriptors" do
      dir = Path.join(System.tmp_dir!(), "uhub-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)

      # The FMA120's internal hub at the USB 2 receptacle.
      hub = Path.join(dir, "1-1.1.3")
      File.mkdir_p!(hub)
      File.write!(Path.join(hub, "bDeviceClass"), "09\n")
      File.write!(Path.join(hub, "idVendor"), "0a12\n")
      File.write!(Path.join(hub, "idProduct"), "4010\n")
      # (no product/manufacturer file — many hubs report none)

      # The FMA120 functions one level below the hub — NOT a hub.
      dev = Path.join(dir, "1-1.1.3.1")
      File.mkdir_p!(dev)
      File.write!(Path.join(dev, "bDeviceClass"), "ef\n")
      File.write!(Path.join(dev, "idVendor"), "0a12\n")
      File.write!(Path.join(dev, "idProduct"), "4007\n")
      File.write!(Path.join(dev, "product"), "FlooGoo FMA120\n")

      # A root hub, which must be skipped (name doesn't match a bus path).
      root = Path.join(dir, "usb1")
      File.mkdir_p!(root)
      File.write!(Path.join(root, "bDeviceClass"), "09\n")

      hubs = Hardware.usb_hubs(usb_devices_dir: dir)

      assert Map.keys(hubs) == ["1-1.1.3"]
      assert hubs["1-1.1.3"] == %{vendor_id: 0x0A12, product_id: 0x4010, name: "USB hub"}
    end

    test "returns an empty map when the sysfs root is absent" do
      assert Hardware.usb_hubs(usb_devices_dir: "/nonexistent-#{System.unique_integer()}") == %{}
    end
  end
end
