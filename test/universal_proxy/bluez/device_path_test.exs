defmodule UniversalProxy.Bluez.DevicePathTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Bluez.DevicePath

  doctest DevicePath

  describe "from_address/1" do
    test "formats a packed MAC as a BlueZ device path" do
      assert DevicePath.from_address(0xAABBCCDDEEFF) ==
               "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF"
    end

    test "pads addresses with leading zero octets" do
      assert DevicePath.from_address(0x0000C0FFEE01) ==
               "/org/bluez/hci0/dev_00_00_C0_FF_EE_01"
    end

    test "rejects out-of-range addresses" do
      assert_raise FunctionClauseError, fn -> DevicePath.from_address(0x1000000000000) end
      assert_raise FunctionClauseError, fn -> DevicePath.from_address(-1) end
    end
  end

  describe "valid?/1" do
    test "accepts 48-bit integers, rejects everything else" do
      assert DevicePath.valid?(0)
      assert DevicePath.valid?(0xAABBCCDDEEFF)
      assert DevicePath.valid?(0xFFFFFFFFFFFF)

      refute DevicePath.valid?(0x1_0000_0000_0000)
      refute DevicePath.valid?(0xFFFFFFFFFFFFFFFF)
      refute DevicePath.valid?(-1)
      refute DevicePath.valid?("AA:BB:CC:DD:EE:FF")
      refute DevicePath.valid?(nil)
    end
  end

  describe "to_address/1" do
    test "round-trips from_address/1" do
      for address <- [0, 0xAABBCCDDEEFF, 0x0000C0FFEE01, 0xFFFFFFFFFFFF] do
        assert address |> DevicePath.from_address() |> DevicePath.to_address() ==
                 {:ok, address}
      end
    end

    test "accepts lowercase hex (BlueZ emits uppercase, but be liberal)" do
      assert DevicePath.to_address("/org/bluez/hci0/dev_aa_bb_cc_dd_ee_ff") ==
               {:ok, 0xAABBCCDDEEFF}
    end

    test "rejects child paths under a device" do
      assert DevicePath.to_address("/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF/service000a") ==
               :error
    end

    test "rejects other adapters, malformed MACs, and non-device paths" do
      assert DevicePath.to_address("/org/bluez/hci1/dev_AA_BB_CC_DD_EE_FF") == :error
      assert DevicePath.to_address("/org/bluez/hci0/dev_AA_BB_CC_DD_EE") == :error
      assert DevicePath.to_address("/org/bluez/hci0/dev_AA_BB_CC_DD_EE_GG") == :error
      assert DevicePath.to_address("/org/bluez/hci0") == :error
      assert DevicePath.to_address("") == :error
    end
  end
end
