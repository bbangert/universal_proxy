defmodule UniversalProxy.ESPHome.ZWaveProxy.FrameTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.ESPHome.ZWaveProxy.Frame

  describe "calculate_checksum/1" do
    # Hand-computed vector: 0xFF ⊕ 0x03 ⊕ 0x00 ⊕ 0x20 = 0xDC. Anchors the
    # algorithm so other tests may use calculate_checksum/1 as a builder.
    test "matches the hand-computed GET_NETWORK_IDS checksum" do
      assert Frame.calculate_checksum(<<0x01, 0x03, 0x00, 0x20, 0x00>>) == 0xDC
    end
  end

  describe "command building" do
    test "get_network_ids_command/0 produces the exact ESPHome bytes" do
      assert Frame.get_network_ids_command() == <<0x01, 0x03, 0x00, 0x20, 0xDC>>
    end

    test "built commands carry a valid checksum" do
      assert Frame.valid_checksum?(Frame.build_simple_command(0x07))
    end
  end

  describe "valid_checksum?/1" do
    test "false for a corrupted frame" do
      refute Frame.valid_checksum?(<<0x01, 0x03, 0x00, 0x20, 0x00>>)
    end

    test "false for binaries too short to be data frames" do
      refute Frame.valid_checksum?(<<0x06>>)
      refute Frame.valid_checksum?(<<0x01, 0x03>>)
    end
  end

  describe "extract_home_id/1" do
    # [SOF][LENGTH=9][TYPE=resp][CMD=0x20][HOME(4)][NODE(2)][CK]
    @response <<0x01, 0x09, 0x01, 0x20, 0xDE, 0xAD, 0xBE, 0xEF, 0x05, 0x00, 0xF0>>

    test "extracts the 4-byte home ID from a GET_NETWORK_IDS response" do
      assert Frame.extract_home_id(@response) == {:ok, <<0xDE, 0xAD, 0xBE, 0xEF>>}
    end

    # Captured verbatim from a ZWA-2 on the rpi3 testbed (2026-07-08):
    # LENGTH = 8 because the controller is in 8-bit node-ID mode, which
    # is every stick's state after power-up until Z-Wave JS switches it
    # to 16-bit. Upstream ESPHome's >= 9 check rejects this frame (its
    # comment even sums to 8) — see audit F8.
    test "extracts the home ID from a real 8-bit-node-ID response (LENGTH = 8)" do
      frame = <<0x01, 0x08, 0x01, 0x20, 0xE1, 0x04, 0x82, 0x19, 0x01, 0xA9>>
      assert Frame.valid_checksum?(frame)
      assert Frame.extract_home_id(frame) == {:ok, <<0xE1, 0x04, 0x82, 0x19>>}
    end

    test "rejects request-type frames (TYPE = 0x00)" do
      <<sof, len, _type, rest::binary>> = @response
      assert Frame.extract_home_id(<<sof, len, 0x00, rest::binary>>) == :error
    end

    test "rejects other command IDs" do
      <<sof, len, type, _cmd, rest::binary>> = @response
      assert Frame.extract_home_id(<<sof, len, type, 0x02, rest::binary>>) == :error
    end

    test "rejects frames shorter than the minimum LENGTH" do
      <<sof, _len, rest::binary>> = @response
      assert Frame.extract_home_id(<<sof, 0x07, rest::binary>>) == :error
    end

    test "rejects single-byte and bootloader frames" do
      assert Frame.extract_home_id(<<0x06>>) == :error
      assert Frame.extract_home_id(<<0x0D, "menu", 0x00>>) == :error
    end
  end

  describe "encode_home_id/1" do
    test "encodes big-endian like ESPHome's encode_uint32" do
      assert Frame.encode_home_id(<<0xDE, 0xAD, 0xBE, 0xEF>>) == 0xDEADBEEF
      assert Frame.encode_home_id(<<0, 0, 0, 0>>) == 0
    end

    test "returns 0 for non-4-byte input" do
      assert Frame.encode_home_id(<<1, 2, 3>>) == 0
      assert Frame.encode_home_id(nil) == 0
    end
  end

  describe "frame_data_length/1" do
    test "data frames report LENGTH + 2, single bytes report 1" do
      assert Frame.frame_data_length(@response) == 11
      assert Frame.frame_data_length(<<0x06>>) == 1
    end
  end
end
