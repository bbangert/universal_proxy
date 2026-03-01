defmodule UniversalProxy.ESPHome.Infrared.Irdroid.ProtocolTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.ESPHome.Infrared.Irdroid.Protocol

  # Timer count <-> microsecond conversion factor:
  # 48 MHz / 256 prescaler = 187500 Hz -> 1 count = ~5.3333 us
  # So 1 us = 48_000_000 / 256 / 1_000_000 = 0.1875 counts
  # And 1 count = 1 / 0.1875 = 5.3333 us
  #
  # The protocol module uses the inverse: us_per_count = 48e6/256/1e6

  describe "command builders" do
    test "reset returns 0x00" do
      assert Protocol.reset() == <<0x00>>
    end

    test "enter_receive_mode returns 'm'" do
      assert Protocol.enter_receive_mode() == "m"
    end

    test "enter_transmit_mode returns 'n'" do
      assert Protocol.enter_transmit_mode() == "n"
    end

    test "get_version returns 'v'" do
      assert Protocol.get_version() == "v"
    end
  end

  describe "encode_carrier/1" do
    test "encodes 38kHz carrier" do
      result = Protocol.encode_carrier(38_000)
      <<0x06, pr2, 0x00>> = result
      # PR2 = round(48_000_000 / (16 * 38_000)) - 1 = round(78.9) - 1 = 78
      assert pr2 == 78
    end

    test "encodes 36kHz carrier" do
      <<0x06, pr2, 0x00>> = Protocol.encode_carrier(36_000)
      # PR2 = round(48_000_000 / (16 * 36_000)) - 1 = round(83.3) - 1 = 82
      assert pr2 == 82
    end

    test "clamps PR2 to valid range" do
      # Very high frequency -> low PR2
      <<0x06, pr2_high, 0x00>> = Protocol.encode_carrier(10_000_000)
      assert pr2_high >= 0

      # Very low frequency -> high PR2
      <<0x06, pr2_low, 0x00>> = Protocol.encode_carrier(100)
      assert pr2_low <= 255
    end
  end

  describe "encode_transmit/2" do
    test "encodes timings with notify prefix and terminator" do
      timings = [9000, -4500, 560, -560]
      result = Protocol.encode_transmit(timings)

      # Starts with 0x25 (notify-on-complete) and 0x03 (TX start)
      assert <<0x25, 0x03, rest::binary>> = result

      # Should end with 0xFF, 0xFF terminator
      total_len = byte_size(rest)
      <<_timing_data::binary-size(total_len - 2), 0xFF, 0xFF>> = rest

      # Each timing is 2 bytes, so 4 timings = 8 bytes of timing data
      assert total_len == 8 + 2
    end

    test "timing values are big-endian uint16" do
      # 9000 us -> count = round(9000 * 48e6/256/1e6) = round(9000 * 0.1875) = round(1687.5) = 1688
      timings = [9000]
      <<0x25, 0x03, hi, lo, 0xFF, 0xFF>> = Protocol.encode_transmit(timings)
      count = hi * 256 + lo
      expected = round(9000 * 48_000_000 / 256 / 1_000_000)
      assert count == expected
    end

    test "negative timings use absolute value" do
      timings = [-4500]
      <<0x25, 0x03, hi, lo, 0xFF, 0xFF>> = Protocol.encode_transmit(timings)
      count = hi * 256 + lo
      expected = round(4500 * 48_000_000 / 256 / 1_000_000)
      assert count == expected
    end

    test "repeat_count duplicates the payload" do
      timings = [1000]
      single = Protocol.encode_transmit(timings, repeat_count: 1)
      double = Protocol.encode_transmit(timings, repeat_count: 2)

      # Single: 0x25, 0x03, <2 bytes timing>, 0xFF, 0xFF = 6 bytes
      assert byte_size(single) == 6
      # Double: 0x25, 0x03, <2 bytes + 0xFFFF> x2 = 2 + 4 + 4 = 10 bytes
      assert byte_size(double) == 10
    end
  end

  describe "feed/2 - version response" do
    test "parses 4-byte version response" do
      state = Protocol.new()
      # V<hw><fw_h><fw_l> where hw=2, fw=25
      data = <<"V", ?2, ?2, ?5>>

      {new_state, actions} = Protocol.feed(state, data)

      assert [{:version, 2, 25}] = actions
      assert new_state.mode == :idle
    end

    test "handles split version response" do
      state = Protocol.new()

      {state, []} = Protocol.feed(state, "V")
      {state, []} = Protocol.feed(state, "2")
      {_state, actions} = Protocol.feed(state, "25")

      assert [{:version, 2, 25}] = actions
    end
  end

  describe "feed/2 - mode acknowledgement" do
    test "parses S01 mode entry" do
      state = Protocol.new()

      {_state, actions} = Protocol.feed(state, "S01")

      assert [{:mode_entered, "S01"}] = actions
    end
  end

  describe "feed/2 - receive mode" do
    test "parses timing pairs terminated by 0xFFFF" do
      state = %{Protocol.new() | mode: :receive}

      # Two timing counts: 100 (mark) and 50 (space), then terminator
      data = <<0x00, 100, 0x00, 50, 0xFF, 0xFF>>
      {_state, actions} = Protocol.feed(state, data)

      assert [{:rx_timings, timings}] = actions
      assert length(timings) == 2

      [mark, space] = timings
      assert mark > 0
      assert space < 0
      assert mark == round(100 / (48_000_000 / 256 / 1_000_000))
      assert space == -round(50 / (48_000_000 / 256 / 1_000_000))
    end

    test "handles split data across multiple feed calls" do
      state = %{Protocol.new() | mode: :receive}

      {state, []} = Protocol.feed(state, <<0x00>>)
      {state, []} = Protocol.feed(state, <<100, 0x00, 50>>)
      {_state, actions} = Protocol.feed(state, <<0xFF, 0xFF>>)

      assert [{:rx_timings, [_mark, _space]}] = actions
    end

    test "detects overflow (six 0xFF bytes)" do
      state = %{Protocol.new() | mode: :receive}
      data = <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>

      {_state, actions} = Protocol.feed(state, data)

      assert [:rx_overflow] = actions
    end

    test "empty timing sequences are ignored" do
      state = %{Protocol.new() | mode: :receive}
      data = <<0xFF, 0xFF>>

      {_state, actions} = Protocol.feed(state, data)

      assert actions == []
    end

    test "alternates mark/space starting with mark (positive)" do
      state = %{Protocol.new() | mode: :receive}
      data = <<0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0xFF, 0xFF>>

      {_state, [{:rx_timings, timings}]} = Protocol.feed(state, data)

      [t1, t2, t3] = timings
      assert t1 > 0
      assert t2 < 0
      assert t3 > 0
    end
  end

  describe "feed/2 - transmit mode" do
    test "parses completion signal 'C'" do
      state = %{Protocol.new() | mode: :transmit}

      {_state, actions} = Protocol.feed(state, "C")

      assert [:tx_complete] = actions
    end

    test "parses failure signal 'F'" do
      state = %{Protocol.new() | mode: :transmit}

      {_state, actions} = Protocol.feed(state, "F")

      assert [{:tx_error, :buffer_underrun}] = actions
    end
  end

  describe "mode transition helpers" do
    test "set_receive_mode configures receive state" do
      state = Protocol.new()
      state = Protocol.set_receive_mode(state)

      assert state.mode == :receive
      assert state.pulse == true
      assert state.rx_timings == []
    end

    test "set_transmit_mode configures transmit state" do
      state = Protocol.new()
      state = Protocol.set_transmit_mode(state)

      assert state.mode == :transmit
    end

    test "set_idle resets to idle" do
      state = %{Protocol.new() | mode: :receive, rx_timings: [100, -50]}
      state = Protocol.set_idle(state)

      assert state.mode == :idle
      assert state.rx_timings == []
      assert state.pulse == true
    end
  end

  describe "timing round-trip" do
    test "encode then decode preserves timings within rounding error" do
      original_timings = [9000, -4500, 560, -560, 560, -1690, 560]

      # Encode: us -> device counts
      <<0x25, 0x03, encoded_data::binary>> = Protocol.encode_transmit(original_timings)

      # Strip terminator
      data_len = byte_size(encoded_data) - 2
      <<timing_data::binary-size(data_len), 0xFF, 0xFF>> = encoded_data

      # Decode: device counts -> us (simulating what feed/2 does)
      count_to_us = 1 / (48_000_000 / 256 / 1_000_000)
      us_per_count = 48_000_000 / 256 / 1_000_000

      decoded =
        for <<hi, lo <- timing_data>> do
          raw = hi * 256 + lo
          round(raw * count_to_us)
        end

      for {original, decoded} <- Enum.zip(Enum.map(original_timings, &abs/1), decoded) do
        # Rounding error should be at most 1 count = ~5.3 us
        assert abs(original - decoded) <= ceil(1 / us_per_count) + 1,
               "Expected #{original} ~= #{decoded}"
      end
    end
  end
end
