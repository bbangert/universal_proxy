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

  describe "irdroid_device?/1" do
    test "matches IRDroid by integer VID/PID" do
      assert Server.irdroid_device?(%{vendor_id: 0x04D8, product_id: 0xFD08})
      assert Server.irdroid_device?(%{vendor_id: 0x04D8, product_id: 0xF58B})
    end

    test "matches IRDroid by hex-string VID/PID" do
      assert Server.irdroid_device?(%{vendor_id: "0x04D8", product_id: "0xFD08"})
      assert Server.irdroid_device?(%{vendor_id: "0x04d8", product_id: "0xf58b"})
    end

    test "matches IRDroid by bare hex-string VID/PID" do
      assert Server.irdroid_device?(%{vendor_id: "04D8", product_id: "FD08"})
    end

    test "matches IRDroid by decimal-string PID" do
      assert Server.irdroid_device?(%{vendor_id: "1240", product_id: "64776"})
    end

    test "rejects wrong vendor" do
      refute Server.irdroid_device?(%{vendor_id: 0x1234, product_id: 0xFD08})
    end

    test "rejects wrong product" do
      refute Server.irdroid_device?(%{vendor_id: 0x04D8, product_id: 0x0000})
    end

    test "rejects missing keys" do
      refute Server.irdroid_device?(%{serial_number: "abc123"})
    end
  end
end
