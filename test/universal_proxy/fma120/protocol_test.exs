defmodule UniversalProxy.FMA120.ProtocolTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.FMA120.Protocol

  describe "encode/2" do
    test "bare query prepends BC: and terminates with CRLF" do
      assert Protocol.encode("VR") == "BC:VR\r\n"
      assert Protocol.encode("VR", nil) == "BC:VR\r\n"
    end

    test "integer payload is hex-byte encoded, uppercase, zero-padded" do
      assert Protocol.encode("AM", 0) == "BC:AM=00\r\n"
      assert Protocol.encode("AM", 1) == "BC:AM=01\r\n"
      assert Protocol.encode("TC", 0x0A) == "BC:TC=0A\r\n"
      assert Protocol.encode("FT", 255) == "BC:FT=FF\r\n"
    end

    test "binary payload passes through verbatim (UTF-8 strings)" do
      assert Protocol.encode("BN", "Office BT") == "BC:BN=Office BT\r\n"
      assert Protocol.encode("BE", "secret") == "BC:BE=secret\r\n"
    end

    test "hex_byte/1" do
      assert Protocol.hex_byte(0) == "00"
      assert Protocol.hex_byte(5) == "05"
      assert Protocol.hex_byte(255) == "FF"
    end
  end

  describe "decode/1 — live hardware samples" do
    test "VR is an ASCII version string, not hex" do
      assert Protocol.decode("VR=1.1.7G") == {:version, "1.1.7G"}
    end

    test "AM=00 decodes to high-quality / fma120" do
      assert Protocol.decode("AM=00") ==
               {:audio_mode, %{quality: :high_quality, variant: :fma120}}
    end

    test "FD row decodes index/mac/state-byte/cod/name (state byte kept raw)" do
      assert Protocol.decode("FD=00,905682D5F226,C5,00240404,Office BT") ==
               {:found_device,
                %{
                  index: 0,
                  mac: "905682D5F226",
                  state_byte: 0xC5,
                  connection_state: :idle,
                  cod: "00240404",
                  name: "Office BT"
                }}
    end

    test "ER is DECIMAL, not hex" do
      assert Protocol.decode("ER=01") == {:error, 1}
      assert Protocol.decode("ER=02") == {:error, 2}
    end

    test "OK is a bare ack" do
      assert Protocol.decode("OK") == :ok
    end
  end

  describe "decode/1 — AM audio mode" do
    test "quality bits 0-1" do
      assert {:audio_mode, %{quality: :high_quality}} = Protocol.decode("AM=00")
      assert {:audio_mode, %{quality: :gaming}} = Protocol.decode("AM=01")
      assert {:audio_mode, %{quality: :broadcast}} = Protocol.decode("AM=02")
    end

    test "variant bit 7" do
      assert {:audio_mode, %{variant: :fma120}} = Protocol.decode("AM=00")
      assert {:audio_mode, %{variant: :fma121}} = Protocol.decode("AM=80")
    end
  end

  describe "decode/1 — ST source state" do
    test "maps the full enum" do
      assert Protocol.decode("ST=00") == {:source_state, :init}
      assert Protocol.decode("ST=04") == {:source_state, :connected}
      assert Protocol.decode("ST=06") == {:source_state, :audio_streaming}
      assert Protocol.decode("ST=0B") == {:source_state, :voice_stopping}
    end

    test "unknown state byte → :unknown atom (no crash)" do
      assert Protocol.decode("ST=FF") == {:source_state, :unknown}
    end
  end

  describe "decode/1 — LA / LF" do
    test "LA LE-audio state" do
      assert Protocol.decode("LA=00") == {:le_audio_state, :disconnected}
      assert Protocol.decode("LA=03") == {:le_audio_state, :unicast_streaming}
      assert Protocol.decode("LA=05") == {:le_audio_state, :broadcast_streaming}
    end

    test "LF preference" do
      assert Protocol.decode("LF=00") == {:le_preference, :a2dp}
      assert Protocol.decode("LF=01") == {:le_preference, :lea}
    end
  end

  describe "decode/1 — BM broadcast mode bitfield" do
    test "all-zero byte" do
      assert {:broadcast_mode, bm} = Protocol.decode("BM=00")

      assert bm == %{
               profile: :tmap,
               encryption: :unencrypted,
               quality: :standard,
               usb_playback: :maintain_3min,
               latency: :reserved,
               quality_range: :single,
               usb_volume: :fixed
             }
    end

    test "encryption / profile combos (bits 0-1)" do
      assert {:broadcast_mode, %{profile: :tmap, encryption: :unencrypted}} =
               Protocol.decode("BM=00")

      assert {:broadcast_mode, %{profile: :tmap, encryption: :encrypted}} =
               Protocol.decode("BM=01")

      assert {:broadcast_mode, %{profile: :pbp, encryption: :unencrypted}} =
               Protocol.decode("BM=02")

      assert {:broadcast_mode, %{profile: :pbp, encryption: :encrypted}} =
               Protocol.decode("BM=03")
    end

    test "high quality, follow-usb-volume, both-range, default latency" do
      # bit2 quality=1 (0x04), bit6 range=1 (0x40), bit7 usb_vol=1 (0x80),
      # bits4-5 latency=3 (0x30) → 0xF4
      assert {:broadcast_mode, bm} = Protocol.decode("BM=F4")
      assert bm.quality == :high
      assert bm.quality_range == :both
      assert bm.usb_volume == :follow
      assert bm.latency == :default
    end
  end

  describe "decode/1 — BN / BE / AD" do
    test "BN broadcast name is UTF-8 (not hex)" do
      assert Protocol.decode("BN=Living Room") == {:broadcast_name, "Living Room"}
    end

    test "BE encryption set/unset" do
      assert Protocol.decode("BE=00") == {:broadcast_encryption, :unset}
      assert Protocol.decode("BE=01") == {:broadcast_encryption, :set}
    end

    test "AD broadcast address decodes hex to 48-bit binary" do
      assert Protocol.decode("AD=905682D5F226") ==
               {:broadcast_address, <<0x90, 0x56, 0x82, 0xD5, 0xF2, 0x26>>}
    end
  end

  describe "decode/1 — FT feature flags" do
    test "bit0 LED" do
      assert {:features, %{led: false}} = Protocol.decode("FT=00")
      assert {:features, %{led: true}} = Protocol.decode("FT=01")
    end

    test "best-effort bits 1-3" do
      assert {:features, f} = Protocol.decode("FT=0F")
      assert f.led and f.aptx_lossless and f.gatt_client and f.usb_audio_source
    end
  end

  describe "decode/1 — AC active codec" do
    test "minimal codec id + rssi" do
      # codec 0x0A (aptX Adaptive Lossless), rssi 0xC4 (signed -60)
      assert {:active_codec, ac} = Protocol.decode("AC=0AC4")
      assert ac.codec == :a2dp_aptx_adaptive_lossless
      assert ac.codec_id == 0x0A
      assert ac.rssi == -60
      # missing trailing fields default to 0
      assert ac.rate == 0
      assert ac.presentation_delay == 0
    end

    test "rate and sample rates parsed big-endian; sample rates ×10" do
      # codec 07 (LC3), rssi 00, rate 0x0030, speaker 0x1130, mic 0x0000
      assert {:active_codec, ac} =
               Protocol.decode("AC=070000301130 0000" |> String.replace(" ", ""))

      assert ac.codec == :lea_lc3
      assert ac.rate == 0x0030
      assert ac.speaker_sample_rate == 0x1130 * 10
      assert ac.mic_sample_rate == 0
    end

    test "odd-length / non-hex payload → {:unknown, line}" do
      assert match?({:unknown, _}, Protocol.decode("AC=0AC"))
      assert match?({:unknown, _}, Protocol.decode("AC=ZZ"))
    end
  end

  describe "decode/1 — FN paired/recent device" do
    test "bare index reply (no MAC)" do
      assert Protocol.decode("FN=00") == {:paired_device, %{index: 0}}
    end

    test "index + MAC normalizes the MAC to FD's uppercase-hex format" do
      # idx 00 + MAC 90:56:82:D5:F2:26 → mac must match the FD hex-string form.
      assert Protocol.decode("FN=00905682D5F226") ==
               {:paired_device, %{index: 0, mac: "905682D5F226"}}

      # Same device via FD and FN ends up under the same MAC string (one key).
      {:found_device, fd} = Protocol.decode("FD=00,905682D5F226,C5,00240404,Office BT")
      {:paired_device, fn_dev} = Protocol.decode("FN=00905682D5F226")
      assert fd.mac == fn_dev.mac
    end

    test "index + MAC + name" do
      assert {:paired_device, %{index: 1, mac: "905682D5F226", name: name}} =
               Protocol.decode("FN=01905682D5F226" <> Base.encode16("Hub"))

      assert name == "Hub"
    end

    test "a truncated payload (neither bare idx, idx+MAC, nor longer) is unknown" do
      # 2 bytes: an index plus one stray byte — matches no FN shape.
      assert Protocol.decode("FN=0190") == {:unknown, "FN=0190"}
    end
  end

  describe "decode/1 — unknown / malformed" do
    test "unknown header → {:unknown, line}" do
      assert Protocol.decode("ZZ=01") == {:unknown, "ZZ=01"}
      assert Protocol.decode("garbage") == {:unknown, "garbage"}
    end

    test "malformed hex payload → {:unknown, line} (no crash)" do
      assert Protocol.decode("AM=ZZ") == {:unknown, "AM=ZZ"}
      assert Protocol.decode("ST=") == {:unknown, "ST="}
    end
  end

  describe "feed/2 — line accumulator" do
    test "single complete line" do
      assert Protocol.feed("", "VR=1.1.7G\r\n") == {"", [{:version, "1.1.7G"}]}
    end

    test "multiple lines in one chunk" do
      {rest, decoded} = Protocol.feed("", "VR=1.1.7G\r\nAM=00\r\n")
      assert rest == ""

      assert decoded == [
               {:version, "1.1.7G"},
               {:audio_mode, %{quality: :high_quality, variant: :fma120}}
             ]
    end

    test "partial line carried in remaining buffer" do
      {rest, decoded} = Protocol.feed("", "VR=1.1")
      assert rest == "VR=1.1"
      assert decoded == []
    end

    test "partial line completed across chunks" do
      {rest1, d1} = Protocol.feed("", "VR=1.1")
      assert d1 == []
      {rest2, d2} = Protocol.feed(rest1, ".7G\r\nAM=")
      assert rest2 == "AM="
      assert d2 == [{:version, "1.1.7G"}]
    end

    test "handles a chunk boundary splitting CR from LF" do
      {rest1, d1} = Protocol.feed("", "OK\r")
      assert d1 == []
      assert rest1 == "OK\r"

      {rest2, d2} = Protocol.feed(rest1, "\nAM=00\r\n")
      assert rest2 == ""
      assert d2 == [:ok, {:audio_mode, %{quality: :high_quality, variant: :fma120}}]
    end

    test "drops empty lines" do
      {rest, decoded} = Protocol.feed("", "OK\r\n\r\nOK\r\n")
      assert rest == ""
      assert decoded == [:ok, :ok]
    end

    test "FD row volunteered alongside a direct reply" do
      {rest, decoded} = Protocol.feed("", "AM=00\r\nFD=00,905682D5F226,C5,00240404,Office BT\r\n")
      assert rest == ""

      assert [{:audio_mode, _}, {:found_device, %{name: "Office BT", state_byte: 0xC5}}] = decoded
    end
  end
end
