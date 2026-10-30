defmodule UniversalProxy.TuyaBeaconMesh.CryptoDpTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.TuyaBeaconMesh.{Crypto, Dp}

  defp h(hex), do: Base.decode16!(hex, case: :mixed)

  describe "Crypto (tuya_beacon_reference.py self-test)" do
    test "CRC-8/SMBUS and CRC-16/MODBUS check values" do
      assert Crypto.crc8("123456789") == 0xF4
      assert Crypto.crc16_modbus("123456789") == h("4b37")
    end

    test "XXTEA big-endian vector and round trip" do
      k = h("0123456789abcdeffedcba9876543210")
      pt = h("00112233445566778899aabbccddeeff")
      ct = h("2cb628af2b144a8d17eb1e3d83d1b56f")
      assert Crypto.xxtea_encrypt(pt, k) == ct
      assert Crypto.xxtea_decrypt(ct, k) == pt
    end

    test "key_bytes: 16 chars as ASCII, 32 as hex, anything else raises" do
      assert Crypto.key_bytes("abcdefghijklmnop") == "abcdefghijklmnop"

      assert Crypto.key_bytes("00112233445566778899aabbccddeeff") ==
               h("00112233445566778899aabbccddeeff")

      assert Crypto.key_bytes("00112233445566778899AABBCCDDEEFF") ==
               h("00112233445566778899aabbccddeeff")

      assert_raise ArgumentError, fn -> Crypto.key_bytes("short") end
      assert_raise ArgumentError, fn -> Crypto.key_bytes(String.duplicate("z", 32)) end
    end

    test "parse_key never raises" do
      assert {:ok, "abcdefghijklmnop"} = Crypto.parse_key("abcdefghijklmnop")

      assert {:ok, <<0x00, 0x11, _::binary>>} =
               Crypto.parse_key("00112233445566778899aabbccddeeff")

      for bad <- [String.duplicate("z", 32), "short", nil, 42, String.duplicate("a", 17)] do
        assert Crypto.parse_key(bad) == :error
      end
    end
  end

  describe "Dp" do
    test "encodes the §4.4 example" do
      assert Dp.encode([{1, :bool, true}, {3, :value, 500}]) == {:ok, h("0111010324000001f4")}
    end

    test "decodes until a zero dp id, ignoring padding" do
      assert Dp.decode(h("0111010324000001f400000000000000")) == [
               {1, :bool, true},
               {3, :value, 500}
             ]
    end

    test "round-trips every encodable type" do
      dps = [{2, :enum, 1}, {21, :string, "ab"}, {11, :raw, <<0, 120, 3, 232>>}]
      {:ok, bin} = Dp.encode(dps)
      assert Dp.decode(bin) == dps
    end

    test "refuses payloads over 16 bytes and bad values" do
      assert Dp.encode([{1, :raw, :binary.copy(<<1>>, 15)}]) == {:error, :too_long}
      assert {:ok, <<1, 0x0E, _::binary-14>>} = Dp.encode([{1, :raw, :binary.copy(<<1>>, 14)}])
      assert {:error, {:bad_value, 1, :bool, 3}} = Dp.encode([{1, :bool, 3}])
      assert {:error, {:bad_dp, {0, :bool, true}}} = Dp.encode([{0, :bool, true}])
    end

    test ":value is a signed 32-bit integer; out of range is an error, not a wrap" do
      assert {:ok, <<3, 0x24, 0x7F, 0xFF, 0xFF, 0xFF>>} = Dp.encode([{3, :value, 2_147_483_647}])
      assert {:ok, <<3, 0x24, 0x80, 0, 0, 0>>} = Dp.encode([{3, :value, -2_147_483_648}])
      assert Dp.decode(<<3, 0x24, 0xFF, 0xFF, 0xFF, 0xFE>>) == [{3, :value, -2}]

      for bad <- [2_147_483_648, -2_147_483_649, 4_294_967_301, 1.0] do
        assert {:error, {:bad_value, 3, :value, ^bad}} = Dp.encode([{3, :value, bad}])
      end
    end

    test "decode stops at a TLV that overruns the payload" do
      assert Dp.decode(<<1, 0x11, 1, 3, 0x24, 0, 0>>) == [{1, :bool, true}]
      assert Dp.decode(<<>>) == []
      assert Dp.decode(<<5, 0x52, 0x01, 0x02>>) == [{5, :bitmap, 0x0102}]
      # Unknown type nibbles come back as the number, value raw.
      assert Dp.decode(<<6, 0x91, 0xAA>>) == [{6, 9, <<0xAA>>}]
    end
  end
end
