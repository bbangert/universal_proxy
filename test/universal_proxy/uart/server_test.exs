defmodule UniversalProxy.UART.ServerTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.UART.Server

  describe "zwave_device?/1" do
    test "matches Nabu Casa ZWA-2 by VID/PID" do
      info = %{vendor_id: 0x303A, product_id: 0x4001, serial_number: "abc123"}
      assert Server.zwave_device?(info)
    end

    test "matches Aeotec Z-Stick Gen5+ by VID/PID" do
      info = %{vendor_id: 0x0658, product_id: 0x0200, serial_number: "xyz789"}
      assert Server.zwave_device?(info)
    end

    test "matches Nortek HUSBZB-1 by VID/PID" do
      info = %{vendor_id: 0x10C4, product_id: 0x8A2A, serial_number: "nortek1"}
      assert Server.zwave_device?(info)
    end

    test "rejects unknown VID/PID" do
      info = %{vendor_id: 0x1234, product_id: 0x5678, serial_number: "unknown"}
      refute Server.zwave_device?(info)
    end

    test "rejects when vendor_id is missing" do
      info = %{product_id: 0x4001, serial_number: "abc123"}
      refute Server.zwave_device?(info)
    end

    test "rejects when product_id is missing" do
      info = %{vendor_id: 0x303A, serial_number: "abc123"}
      refute Server.zwave_device?(info)
    end

    test "rejects when both VID and PID are missing" do
      info = %{serial_number: "abc123", manufacturer: "Nabu Casa", description: "ZWA-2"}
      refute Server.zwave_device?(info)
    end

    test "rejects when VID/PID are not integers" do
      info = %{vendor_id: "303A", product_id: "4001", serial_number: "abc123"}
      refute Server.zwave_device?(info)
    end
  end
end
