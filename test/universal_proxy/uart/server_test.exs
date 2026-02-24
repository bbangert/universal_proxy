defmodule UniversalProxy.UART.ServerTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.UART.Server

  describe "zwa2_device?/1" do
    test "matches ZWA-2 by VID/PID" do
      info = %{vendor_id: 0x303A, product_id: 0x4001, serial_number: "abc123"}
      assert Server.zwa2_device?(info)
    end

    test "rejects unknown VID/PID" do
      info = %{vendor_id: 0x1234, product_id: 0x5678, serial_number: "unknown"}
      refute Server.zwa2_device?(info)
    end

    test "rejects when vendor_id is missing" do
      info = %{product_id: 0x4001, serial_number: "abc123"}
      refute Server.zwa2_device?(info)
    end

    test "rejects when product_id is missing" do
      info = %{vendor_id: 0x303A, serial_number: "abc123"}
      refute Server.zwa2_device?(info)
    end

    test "rejects when both VID and PID are missing" do
      info = %{serial_number: "abc123", manufacturer: "Nabu Casa", description: "ZWA-2"}
      refute Server.zwa2_device?(info)
    end
  end
end
