defmodule UniversalProxy.ESPHome.Infrared.ServerTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.ESPHome.Infrared.Server
  alias UniversalProxy.Hardware

  defp ports(enumerated, bus_paths) do
    Hardware.list_ports(
      slots: nil,
      enumerated: enumerated,
      bus_paths: bus_paths,
      saved_configs: %{},
      line_settings: %{},
      in_use_ports: MapSet.new(),
      zwave_claim: nil,
      tty_class_dir: "/nonexistent-#{System.unique_integer([:positive])}"
    )
  end

  describe "saved_infrared_targets/3" do
    test "a stale saved :infrared config on a locked ZBT-2 port is ignored" do
      for pid <- [0x4001, 0x831A] do
        enumerated = %{
          "ttyACM0" => %{
            vendor_id: 0x303A,
            product_id: pid,
            manufacturer: "Nabu Casa",
            description: "Home Assistant Connect ZBT-2",
            serial_number: "ZB0001"
          }
        }

        ports = ports(enumerated, %{"ttyACM0" => "1-1.1"})
        assert [%{locked: true}] = ports

        config = %{port_type: :infrared, slot_sub: "1-1.1", vendor_id: 0x303A, product_id: pid}
        key = {"1-1.1", 0x303A, pid}

        assert Server.saved_infrared_targets(ports, %{key => "ttyACM0"}, [config]) == []
      end
    end

    test "a saved :infrared override on an unlocked generic port still works" do
      ports =
        ports(
          %{"ttyUSB0" => %{vendor_id: 0x10C4, product_id: 0xEA60, serial_number: "X"}},
          %{"ttyUSB0" => "1-1.2"}
        )

      config = %{port_type: :infrared, slot_sub: "1-1.2", vendor_id: 0x10C4, product_id: 0xEA60}
      key = {"1-1.2", 0x10C4, 0xEA60}

      assert [{^config, "ttyUSB0"}] =
               Server.saved_infrared_targets(ports, %{key => "ttyUSB0"}, [config])
    end

    test "configs of another port type are ignored" do
      config = %{port_type: :zwave, slot_sub: "1-1.2", vendor_id: 0x10C4, product_id: 0xEA60}
      key = {"1-1.2", 0x10C4, 0xEA60}

      assert Server.saved_infrared_targets([], %{key => "ttyUSB0"}, [config]) == []
    end
  end
end
