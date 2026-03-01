defmodule UniversalProxy.ESPHome.Infrared.Irdroid.DeviceTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.ESPHome.Infrared.Irdroid.Device
  alias UniversalProxy.ESPHome.Infrared.Irdroid.DeviceWorker

  describe "match?/1" do
    test "matches IRDroid transceiver (0x04D8 / 0xF58B)" do
      info = %{vendor_id: 0x04D8, product_id: 0xF58B}
      assert Device.match?(info)
    end

    test "matches IR Toy (0x04D8 / 0xFD08)" do
      info = %{vendor_id: 0x04D8, product_id: 0xFD08}
      assert Device.match?(info)
    end

    test "matches with string hex IDs" do
      info = %{vendor_id: "0x04D8", product_id: "0xFD08"}
      assert Device.match?(info)
    end

    test "matches with decimal string IDs" do
      info = %{vendor_id: "1240", product_id: "64776"}
      assert Device.match?(info)
    end

    test "rejects wrong vendor ID" do
      info = %{vendor_id: 0x1234, product_id: 0xF58B}
      refute Device.match?(info)
    end

    test "rejects wrong product ID" do
      info = %{vendor_id: 0x04D8, product_id: 0x0001}
      refute Device.match?(info)
    end

    test "rejects missing IDs" do
      refute Device.match?(%{})
      refute Device.match?(%{vendor_id: nil, product_id: nil})
    end
  end

  describe "build_entity/3" do
    test "builds entity with transmit+receive for PID 0xF58B" do
      config = %{serial_number: "SN001", friendly_name: "My IRDroid"}
      info = %{vendor_id: 0x04D8, product_id: 0xF58B}

      entity = Device.build_entity(config, "/dev/ttyACM0", info)

      assert entity.serial_number == "SN001"
      assert entity.port_path == "/dev/ttyACM0"
      assert entity.name == "My IRDroid"
      assert entity.product_id == 0xF58B
      assert :transmit in entity.capabilities
      assert :receive in entity.capabilities
      assert entity.worker_module == DeviceWorker
    end

    test "builds entity with transmit-only for PID 0xFD08" do
      config = %{serial_number: "SN002", friendly_name: nil}
      info = %{vendor_id: 0x04D8, product_id: 0xFD08}

      entity = Device.build_entity(config, "/dev/ttyACM1", info)

      assert entity.product_id == 0xFD08
      assert entity.capabilities == [:transmit]
      assert entity.name == "IRDroid / IR Toy"
    end
  end
end
