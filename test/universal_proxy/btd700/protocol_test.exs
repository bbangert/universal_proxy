defmodule UniversalProxy.BTD700.ProtocolTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.BTD700.Protocol

  @frame_size 64

  # Build a fake full 64-byte response/event frame from a
  # {marker, cmd_or_evt_id, payload} tuple, zero-padding out to 64 bytes
  # like the real device would.
  defp fake_frame(marker, id, payload) do
    len = byte_size(payload)
    padding = @frame_size - 4 - len
    <<0x34, marker, id, len>> <> payload <> :binary.copy(<<0>>, padding)
  end

  describe "encode/2 — always exactly 64 bytes, zero-padded" do
    test "every no-arg GET command" do
      for cmd <- [
            :get_audio_mode,
            :get_supported_codecs,
            :get_codec_in_use,
            :get_dongle_state,
            :get_le_audio_state,
            :get_audio_quality,
            :get_broadcast_info,
            :get_broadcast_key,
            :get_broadcast_name,
            :get_firmware_version,
            :factory_reset,
            :get_sink_transport
          ] do
        frame = Protocol.encode(cmd)
        assert byte_size(frame) == @frame_size
        assert <<0x34, 0xFE, _cmd_id, 0, rest::binary>> = frame
        assert rest == :binary.copy(<<0>>, 60)
      end
    end

    test "set_audio_mode" do
      frame = Protocol.encode(:set_audio_mode, <<1, 2>>)
      assert byte_size(frame) == @frame_size
      assert <<0x34, 0xFE, 0x02, 2, 1, 2, pad::binary>> = frame
      assert pad == :binary.copy(<<0>>, 58)
    end

    test "set_codec_mask" do
      frame = Protocol.encode(:set_codec_mask, <<0x07, 0x00>>)
      assert byte_size(frame) == @frame_size
      assert <<0x34, 0xFE, 0x04, 2, 0x07, 0x00, pad::binary>> = frame
      assert pad == :binary.copy(<<0>>, 58)
    end

    test "set_broadcast_info" do
      frame = Protocol.encode(:set_broadcast_info, <<1, 0, 2>>)
      assert byte_size(frame) == @frame_size
      assert <<0x34, 0xFE, 0x0A, 3, 1, 0, 2, pad::binary>> = frame
      assert pad == :binary.copy(<<0>>, 57)
    end

    test "set_broadcast_key" do
      key = <<1, 2, 3, 4, 5>>
      frame = Protocol.encode(:set_broadcast_key, key)
      assert byte_size(frame) == @frame_size
      assert <<0x34, 0xFE, 0x0C, 5, extracted::binary-size(5), pad::binary>> = frame
      assert extracted == key
      assert pad == :binary.copy(<<0>>, 55)
    end

    test "bt_connect connect vs disconnect" do
      connect = Protocol.encode(:bt_connect, <<1>>)
      disconnect = Protocol.encode(:bt_connect, <<0>>)

      assert byte_size(connect) == @frame_size
      assert byte_size(disconnect) == @frame_size
      assert <<0x34, 0xFE, 0x14, 1, 1, _pad::binary>> = connect
      assert <<0x34, 0xFE, 0x14, 1, 0, _pad::binary>> = disconnect
    end

    test "set_broadcast_name" do
      frame = Protocol.encode(:set_broadcast_name, "Office")
      assert byte_size(frame) == @frame_size
      assert <<0x34, 0xFE, 0x0E, 7, "Office", 0, pad::binary>> = frame
      assert pad == :binary.copy(<<0>>, 53)
    end
  end

  describe "encode/2 — clamp-to-60 behavior" do
    test "oversized raw binary arg truncates to 60 bytes and len matches" do
      oversized = :binary.copy(<<0xAB>>, 65)
      frame = Protocol.encode(:set_broadcast_key, oversized)

      assert byte_size(frame) == @frame_size
      assert <<0x34, 0xFE, 0x0C, len, payload::binary-size(60)>> = frame
      assert len == 60
      assert payload == :binary.copy(<<0xAB>>, 60)
    end
  end

  describe "encode/2 — set_broadcast_name truncation (upstream off-by-one fix)" do
    test "60-character name truncates to 59 chars + NUL, len byte matches actual payload" do
      name = String.duplicate("a", 60)
      frame = Protocol.encode(:set_broadcast_name, name)

      assert byte_size(frame) == @frame_size
      assert <<0x34, 0xFE, 0x0E, len, payload::binary>> = frame
      # 59 chars + 1 NUL = 60 bytes of on-wire payload, matching len exactly.
      assert len == 60
      assert byte_size(payload) == 60

      <<encoded_bytes::binary-size(^len), zero_pad::binary>> = payload
      assert zero_pad == :binary.copy(<<0>>, 64 - 4 - len)

      # decode/1 recovers exactly the first 59 chars (NUL-terminated) —
      # sanity-check by feeding the truncated+NUL'd payload back through
      # a manufactured broadcast_name response.
      name_response = fake_frame(0xFF, 0x0D, encoded_bytes)
      assert {:response, :broadcast_name, decoded_name} = Protocol.decode(name_response)
      assert decoded_name == String.duplicate("a", 59)
    end
  end

  describe "decode/1 — byte-exact fixtures" do
    test "firmware version response" do
      frame = fake_frame(0xFF, 0x12, <<3, 0x0B, 0, 0>>)

      assert Protocol.decode(frame) ==
               {:response, :firmware_version, %{major: 3, minor: 11, build: 0, version: "3.11.0"}}
    end

    test "supported codecs mask 0x0007 -> sbc/aptx/aptx_adaptive" do
      frame = fake_frame(0xFF, 0x03, <<0x07, 0x00>>)

      assert Protocol.decode(frame) ==
               {:response, :supported_codecs, [:sbc, :aptx, :aptx_adaptive]}
    end

    test "broadcast name real hardware sample stops at first NUL" do
      payload = "BTD700_3008" <> <<0>> <> :binary.copy(<<0>>, 60 - byte_size("BTD700_3008") - 1)
      frame = fake_frame(0xFF, 0x0D, payload)
      assert Protocol.decode(frame) == {:response, :broadcast_name, "BTD700_3008"}
    end
  end

  describe "decode/1 — audio quality wire-order regression" do
    test "resolution comes before frequency on the wire, not the C-struct order" do
      frame = fake_frame(0xFF, 0x08, <<1, 2, 0>>)

      assert Protocol.decode(frame) ==
               {:response, :audio_quality, %{resolution: :res_16bit, frequency: :freq_48000}}
    end

    test "event variant uses the same wire order" do
      frame = fake_frame(0xFC, 0x11, <<1, 2>>)

      assert Protocol.decode(frame) ==
               {:event, :audio_quality, %{resolution: :res_16bit, frequency: :freq_48000}}
    end
  end

  describe "decode/1 — :ignore for unrelated HID reports" do
    test "consumer-key report (byte 0 != 0x34) is ignored" do
      assert Protocol.decode(<<0x01, 0x02, 0x03>>) == :ignore
    end

    test "any other non-0x34-leading binary is ignored" do
      assert Protocol.decode(<<0xFF, 0xFF>>) == :ignore
    end

    test "empty binary is ignored" do
      assert Protocol.decode(<<>>) == :ignore
    end
  end

  describe "decode/1 — {:unknown, bin} for unrecognized 0x34 frames" do
    test "unrecognized marker" do
      frame = fake_frame(0xAB, 0x01, <<0>>)
      assert Protocol.decode(frame) == {:unknown, frame}
    end

    test "recognized response marker, unrecognized cmd id" do
      frame = fake_frame(0xFF, 0x99, <<0>>)
      assert Protocol.decode(frame) == {:unknown, frame}
    end

    test "recognized event marker, unrecognized evt id" do
      frame = fake_frame(0xFC, 0x99, <<0>>)
      assert Protocol.decode(frame) == {:unknown, frame}
    end

    test "0xFD is defined but unimplemented — unrecognized marker" do
      frame = fake_frame(0xFD, 0x01, <<0>>)
      assert Protocol.decode(frame) == {:unknown, frame}
    end
  end

  describe "decode/1 — event length guard" do
    test "dongle_state event with zero payload bytes falls back to raw" do
      frame = fake_frame(0xFC, 0x0F, <<>>)
      assert Protocol.decode(frame) == {:event, :dongle_state, %{raw: <<>>}}
    end

    test "event declaring more payload than actually present slices defensively" do
      # A truncated report: declared_len says 4 bytes of payload follow,
      # but only 1 byte was actually received (no zero padding at all).
      # data_len = min(byte_size(payload), declared_len) must clamp to
      # what's really there instead of reading past the end.
      frame = <<0x34, 0xFC, 0x0F, 4, 3>>
      assert Protocol.decode(frame) == {:event, :dongle_state, :streaming_audio}
    end

    test "audio_mode event with a normal-length payload decodes fully" do
      frame = fake_frame(0xFC, 0x02, <<1, 2>>)

      assert Protocol.decode(frame) ==
               {:event, :audio_mode, %{mode: :gaming, transport: :le_audio}}
    end

    test "gaming event decodes defensively as a boolean" do
      assert Protocol.decode(fake_frame(0xFC, 0x17, <<1>>)) == {:event, :gaming, true}
      assert Protocol.decode(fake_frame(0xFC, 0x17, <<0>>)) == {:event, :gaming, false}
      assert Protocol.decode(fake_frame(0xFC, 0x17, <<>>)) == {:event, :gaming, %{raw: <<>>}}
    end
  end

  describe "decode/1 — response length guards fall back to raw, never crash" do
    test "audio_mode response too short for its fields" do
      # A truncated report — only 1 byte actually received past the
      # header, not the usual zero-padded 60. `fake_frame/3` always pads
      # to a full 64-byte frame, which would defeat this test, so build
      # the short report directly.
      frame = <<0x34, 0xFF, 0x01, 2, 1>>
      assert Protocol.decode(frame) == {:response, :audio_mode, %{raw: <<1>>}}
    end

    test "firmware version response too short" do
      frame = <<0x34, 0xFF, 0x12, 4, 3, 11>>
      assert Protocol.decode(frame) == {:response, :firmware_version, %{raw: <<3, 11>>}}
    end
  end

  describe "decode/1 — broadcast_key raw bytes" do
    test "returns everything from offset 4 onward" do
      key = <<1, 2, 3, 4>>
      frame = fake_frame(0xFF, 0x0B, key)
      assert {:response, :broadcast_key, decoded} = Protocol.decode(frame)
      assert binary_part(decoded, 0, 4) == key
    end

    test "a frame with nothing past the header decodes to an empty binary" do
      frame = <<0x34, 0xFF, 0x0B, 0>>
      assert Protocol.decode(frame) == {:response, :broadcast_key, <<>>}
    end
  end

  describe "decode/1 — setter-echo responses round-trip as recognized" do
    test "factory_reset ack" do
      frame = fake_frame(0xFF, 0x13, <<>>)
      assert Protocol.decode(frame) == {:response, :factory_reset, %{}}
    end

    test "bt_connect ack" do
      frame = fake_frame(0xFF, 0x14, <<>>)
      assert Protocol.decode(frame) == {:response, :bt_connect, %{}}
    end

    test "set_broadcast_name ack" do
      frame = fake_frame(0xFF, 0x0E, <<>>)
      assert Protocol.decode(frame) == {:response, :set_broadcast_name, %{}}
    end

    # Regression: 0x04's echo was originally missing from @response_ids,
    # which made set_codec_mask completable only via its 5 s timeout.
    test "set_codec_mask ack" do
      frame = fake_frame(0xFF, 0x04, <<>>)
      assert Protocol.decode(frame) == {:response, :set_codec_mask, %{}}
    end
  end

  describe "round trip sanity" do
    test "get_dongle_state encode -> decode of a fabricated response" do
      request = Protocol.encode(:get_dongle_state)
      assert <<0x34, 0xFE, 0x06, 0, _pad::binary>> = request

      response = fake_frame(0xFF, 0x06, <<3>>)
      assert Protocol.decode(response) == {:response, :dongle_state, :streaming_audio}
    end

    test "set_codec_mask encode -> decode of a fabricated ack" do
      request = Protocol.encode(:set_codec_mask, <<0x01, 0x00>>)
      assert <<0x34, 0xFE, 0x04, 2, 1, 0, _pad::binary>> = request

      response = fake_frame(0xFF, 0x04, <<>>)
      assert Protocol.decode(response) == {:response, :set_codec_mask, %{}}
    end

    test "get_broadcast_key encode -> decode of a fabricated response" do
      request = Protocol.encode(:get_broadcast_key)
      assert <<0x34, 0xFE, 0x0B, 0, _pad::binary>> = request

      response = fake_frame(0xFF, 0x0B, <<0xDE, 0xAD, 0xBE, 0xEF>>)
      assert {:response, :broadcast_key, decoded} = Protocol.decode(response)
      assert binary_part(decoded, 0, 4) == <<0xDE, 0xAD, 0xBE, 0xEF>>
    end
  end

  test "no String.to_atom anywhere in the implementation" do
    source = File.read!("lib/universal_proxy/btd700/protocol.ex")
    refute source =~ "String.to_atom"
  end
end
