defmodule UniversalProxy.ESPHome.ZigbeeProxy.AshTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.ESPHome.ZigbeeProxy.Ash
  alias UniversalProxy.ESPHome.ZigbeeProxy.Ash.Scanner

  # Vectors are wire bytes (post-stuffing), copied from the ESPHome
  # ezsp_proxy_tap unit tests and bellows' test_ash.py.
  hex = fn s -> s |> String.replace(" ", "") |> Base.decode16!() end

  # Oracle for ack_frame/1, independent of the implementation's CRC.
  @golden_acks %{
    0 => <<0x7E, 0x80, 0x70, 0x78, 0x7E>>,
    1 => <<0x7E, 0x81, 0x60, 0x59, 0x7E>>,
    2 => <<0x7E, 0x82, 0x50, 0x3A, 0x7E>>,
    3 => <<0x7E, 0x83, 0x40, 0x1B, 0x7E>>,
    4 => <<0x7E, 0x84, 0x30, 0xFC, 0x7E>>,
    5 => <<0x7E, 0x85, 0x20, 0xDD, 0x7E>>,
    6 => <<0x7E, 0x86, 0x10, 0xBE, 0x7E>>,
    7 => <<0x7E, 0x87, 0x00, 0x9F, 0x7E>>
  }

  @reserved [0x7E, 0x7D, 0x11, 0x13, 0x18, 0x1A]

  @rstack hex.("C1 02 02 9B 7B 7E")
  @data_0 hex.("00 43 21 A8 50 9B 98 7E")
  @data_1 hex.("10 43 21 A8 50 9F C2 7E")
  @data_0_retx hex.("08 43 21 A8 50 99 B5 7E")
  @data_5 hex.("50 43 21 A8 50 8E AA 7E")
  @data_5_retx hex.("58 43 21 A8 50 8C 87 7E")
  @data_6 hex.("60 43 21 A8 50 82 44 7E")
  @short_data_0 hex.("00 43 21 A0 40 7E")
  @min_data_0 hex.("00 43 21 A8 C1 08 7E")
  @escaped hex.("00 7D 5E 7D 5D 7D 31 7D 33 7D 38 7D 3A 46 8C 7E")

  @bad_crc_data_0 hex.("00 43 21 A8 50 9A 98 7E")
  @bellows_rstack hex.("C1 02 0B 0A 52 7E")
  @rst hex.("C0 38 BC 7E")

  # fn 0..7, ack field 0, data `00 01 02` randomised
  @wrap_frames [
    hex.("00 42 20 AA E5 4B 7E"),
    hex.("10 42 20 AA FE EC 7E"),
    hex.("20 42 20 AA D2 05 7E"),
    hex.("30 42 20 AA C9 A2 7E"),
    hex.("40 42 20 AA 8B D7 7E"),
    hex.("50 42 20 AA 90 70 7E"),
    hex.("60 42 20 AA BC 99 7E"),
    hex.("70 42 20 AA A7 3E 7E")
  ]

  defp hex(s), do: s |> String.replace(" ", "") |> Base.decode16!()

  defp ack(n), do: Map.fetch!(@golden_acks, n)

  # The result of every FLAG byte: `nil` or `{length, header}`.
  defp scan(data) do
    {_scanner, results} =
      for <<byte <- data>>, reduce: {Scanner.new(), []} do
        {scanner, acc} ->
          {scanner, result} = Scanner.feed_byte(scanner, byte)
          {scanner, if(byte == 0x7E, do: [result | acc], else: acc)}
      end

    Enum.reverse(results)
  end

  defp owed(frames), do: frames |> acks_per_frame() |> elem(0)

  # Feed each frame in turn; the ACKs emitted for each.
  defp acks_per_frame(ash \\ Ash.new(), frames) do
    Enum.map_reduce(frames, ash, fn frame, ash ->
      {ash, acks} = Ash.feed(ash, frame)
      {acks, ash}
    end)
  end

  defp feed_bytewise(ash, data) do
    for <<byte <- data>>, reduce: {ash, []} do
      {ash, acc} ->
        {ash, acks} = Ash.feed(ash, <<byte>>)
        {ash, acc ++ acks}
    end
  end

  # A DATA frame (control 00) with `data_len` 0x42 data bytes, stuffed.
  defp data_frame(data_len) do
    body = <<0x00>> <> :binary.copy(<<0x42>>, data_len)
    stuff(<<body::binary, Ash.crc16(body)::16>>) <> <<0x7E>>
  end

  defp stuff(data) do
    for <<byte <- data>>, into: <<>> do
      if byte in @reserved, do: <<0x7D, Bitwise.bxor(byte, 0x20)>>, else: <<byte>>
    end
  end

  describe "crc16/2" do
    test "CRC-16/CCITT-FALSE check values" do
      assert Ash.crc16(<<0xC1, 0x02, 0x0B>>) == 0x0A52
      assert Ash.crc16(<<0x81>>) == 0x6059
      assert Ash.crc16(<<0xC0>>) == 0x38BC
      assert Ash.crc16("123456789") == 0x29B1
    end

    test "continues from a running CRC" do
      assert Ash.crc16(<<0x02, 0x0B>>, Ash.crc16(<<0xC1>>)) == 0x0A52
      assert Ash.crc16(<<>>) == 0xFFFF
    end

    test "running it over a body plus its big-endian CRC leaves 0" do
      assert Ash.crc16(<<0xC1, 0x02, 0x0B, 0x0A, 0x52>>) == 0
    end
  end

  describe "ack_frame/1" do
    test "matches the golden ACK frames for 0..7" do
      for {n, frame} <- @golden_acks do
        assert Ash.ack_frame(n) == frame, "ack #{n}"
      end
    end

    test "ack 1 is the UG101 reference frame" do
      assert Ash.ack_frame(1) == <<0x7E, 0x81, 0x60, 0x59, 0x7E>>
    end

    test "is FLAG-delimited and needs no escaping" do
      for n <- 0..7 do
        assert <<0x7E, inner::binary-size(3), 0x7E>> = Ash.ack_frame(n)
        assert for(<<b <- inner>>, b in @reserved, do: b) == []
      end
    end

    test "uses only the low 3 bits of ack_num" do
      assert Ash.ack_frame(9) == Ash.ack_frame(1)
      assert Ash.ack_frame(15) == Ash.ack_frame(7)
    end
  end

  describe "scanner (upstream AshFrameScanner tests)" do
    test "S1 unescapes reserved bytes" do
      assert scan(@escaped) == [{7, <<0x00, 0x7E>>}]
    end

    test "S2 rejects a bad CRC and recovers" do
      assert scan(@bad_crc_data_0 <> @data_0) == [nil, {5, <<0x00, 0x43>>}]
    end

    test "S3 CANCEL discards the partial frame" do
      assert scan(<<0x10, 0x43, 0x1A>> <> @data_0) == [{5, <<0x00, 0x43>>}]
    end

    test "S4 SUBSTITUTE discards until the FLAG" do
      substituted = hex("00 43 18 21 A8 50 9B 98 7E")
      assert scan(substituted <> @data_0) == [nil, {5, <<0x00, 0x43>>}]
    end

    test "S5 CANCEL ends a SUBSTITUTE discard" do
      assert scan(<<0x10, 0x18, 0x43, 0x1A>> <> @data_0) == [{5, <<0x00, 0x43>>}]
    end

    test "S6 ignores WAKE between frames" do
      # The leading FLAG closes an empty, invalid frame.
      assert scan(<<0xFF, 0x7E, 0xFF, 0xFF>> <> @data_0) == [nil, {5, <<0x00, 0x43>>}]
    end

    test "S7 ignores XON/XOFF inside a frame" do
      assert scan(hex("00 11 43 21 13 A8 50 9B 98 7E")) == [{5, <<0x00, 0x43>>}]
    end

    test "S8 rejects an oversized frame and recovers" do
      assert scan(data_frame(220) <> data_frame(221) <> @data_0) ==
               [{221, <<0x00, 0x42>>}, nil, {5, <<0x00, 0x43>>}]
    end
  end

  describe "acknowledger (upstream AshAcknowledger tests)" do
    test "A1 acknowledges frames in sequence" do
      assert owed([@data_0, @data_0, @data_0_retx, @data_1]) == [[ack(1)], [], [ack(1)], [ack(2)]]
    end

    test "A2 RSTACK restarts numbering" do
      assert owed([@data_0, @rstack, @data_0]) == [[ack(1)], [], [ack(1)]]
    end

    test "A3 ignores short DATA frames" do
      assert owed([@short_data_0, @min_data_0]) == [[], [ack(1)]]
    end

    test "A4 syncs to the first frame mid-session" do
      assert owed([@data_5_retx, @data_6]) == [[ack(6)], [ack(7)]]
    end

    test "A5 reset forgets numbering" do
      {ash, acks} = Ash.feed(Ash.new(), @data_0)
      assert acks == [ack(1)]

      assert {_, [ack_6]} = Ash.feed(Ash.reset(ash), @data_5)
      assert ack_6 == ack(6)
    end
  end

  describe "acknowledger (additional vectors)" do
    test "D1 bellows RSTACK (RESET_SOFTWARE) syncs to 0 with no ACK" do
      assert {ash, []} = Ash.feed(Ash.new(), @bellows_rstack)
      assert %Ash{rx_sequence: 0, synced?: true} = ash
    end

    test "D2 RST, ERROR, ACK and NAK owe nothing and change nothing" do
      for frame <- [@rst, hex("C2 02 52 98 DE 7E"), hex("81 60 59 7E"), hex("A1 44 3B 7E")] do
        assert Ash.feed(Ash.new(), frame) == {Ash.new(), []}
      end
    end

    test "D3 only a 3-byte version-2 RSTACK resets numbering" do
      {[[_]], synced} = acks_per_frame([@data_5])
      assert synced.rx_sequence == 6

      assert {%Ash{rx_sequence: 0}, []} = Ash.feed(synced, @bellows_rstack)
      assert {%Ash{rx_sequence: 0}, []} = Ash.feed(synced, @rstack)
      assert Ash.feed(synced, hex("C1 03 0B 39 63 7E")) == {synced, []}

      # Body `C1 02` + CRC `18 28`: the 0x18 must be stuffed on the wire.
      length_2 = hex("C1 02 7D 38 28 7E")
      assert scan(length_2) == [{2, <<0xC1, 0x02>>}]
      assert Ash.feed(synced, length_2) == {synced, []}
    end

    test "D4 a CANCEL clears leading garbage before an RSTACK" do
      input = hex("DD F9 FF 1A C1 02 0B 0A 52 7E")
      assert scan(input) == [{3, <<0xC1, 0x02>>}]

      {ash, []} = Ash.feed(Ash.new(), input)
      assert feed_bytewise(Ash.new(), input) == {ash, []}
      assert %Ash{rx_sequence: 0, synced?: true} = ash

      assert {_, [ack_1]} = Ash.feed(ash, @data_0)
      assert ack_1 == ack(1)
    end

    test "D5 a SUBSTITUTEd frame is dropped, the next parses" do
      assert scan(hex("C0 18 38 BC 7E") <> @bellows_rstack) == [nil, {3, <<0xC1, 0x02>>}]
    end

    test "D6 XON/XOFF dropped; repeated FLAGs yield one frame" do
      assert scan(hex("C0 11 38 BC 13 7E")) == [{1, <<0xC0>>}]
      assert scan(hex("C0 38 BC 7E 7E 7E")) == [{1, <<0xC0>>}, nil, nil]
    end

    test "D7 a FLAG ends a SUBSTITUTE discard" do
      input = hex("C0 18 38 BC AA BB CC DD EE FF 7E C0 38 BC 7E 7E 7E")
      assert scan(input) == [nil, {1, <<0xC0>>}, nil, nil]
    end

    test "D8 frame numbers wrap mod 8; out-of-sequence retx is re-ACKed" do
      frames = @wrap_frames ++ Enum.take(@wrap_frames, 2)
      {acks, ash} = acks_per_frame(frames)

      assert acks == Enum.map([1, 2, 3, 4, 5, 6, 7, 0, 1, 2], &[ack(&1)])

      {_, ash_after_7} = acks_per_frame(@wrap_frames)
      assert ash_after_7.rx_sequence == 0

      retx_fn7 = hex("78 42 20 AA 22 FD 7E")
      assert Ash.feed(ash_after_7, retx_fn7) == {ash_after_7, [ack(0)]}
      assert ash.rx_sequence == 2
    end

    test "D9 two frames in one chunk give two adjacent ACK frames" do
      {_ash, acks} = Ash.feed(Ash.new(), @data_0 <> @data_1)

      assert IO.iodata_to_binary(acks) ==
               hex("7E 81 60 59 7E 7E 82 50 3A 7E")
    end

    test "D10 data-field size boundaries (3..220 ACKed)" do
      for {data_len, expected} <- [{2, []}, {3, [ack(1)]}, {220, [ack(1)]}, {221, []}] do
        assert {_, ^expected} = Ash.feed(Ash.new(), data_frame(data_len)), "#{data_len} bytes"
      end
    end

    test "D11 an escape pending at the FLAG invalidates the frame" do
      data_0_no_flag = binary_part(@data_0, 0, byte_size(@data_0) - 1)
      assert Ash.feed(Ash.new(), data_0_no_flag <> <<0x7D, 0x7E>>) == {Ash.new(), []}
    end

    test "D12 a bad CRC owes nothing and changes nothing" do
      assert Ash.feed(Ash.new(), @bad_crc_data_0) == {Ash.new(), []}
    end

    test "D13 WAKE mid-frame is data, so the CRC fails" do
      assert Ash.feed(Ash.new(), hex("00 43 FF 21 A8 50 9B 98 7E")) == {Ash.new(), []}
    end

    test "D14 a real EZSP version response is ACKed" do
      wire = hex("01 42 A1 A8 5C 28 95 D5 2E 8B 7E")
      assert Ash.feed(Ash.new(), wire) == {%Ash{rx_sequence: 1, synced?: true}, [ack(1)]}
    end

    test "reset/1 drops a partial frame" do
      {ash, []} = Ash.feed(Ash.new(), binary_part(@data_0, 0, 4))
      assert {_, [ack_6]} = Ash.feed(Ash.reset(ash), @data_5)
      assert ack_6 == ack(6)
    end
  end

  describe "chunking" do
    @corpus Enum.join([
              <<0xFF, 0x7E, 0xFF>>,
              @data_5_retx,
              @data_6,
              @rstack,
              @data_0,
              @data_0,
              @data_0_retx,
              @escaped,
              @rst,
              <<0x10, 0x18, 0x43, 0x1A>>,
              @data_1,
              @short_data_0,
              @bad_crc_data_0,
              hex.("00 11 43 21 13 A8 50 9B 98 7E")
            ])

    test "the corpus exercises ACKs" do
      {_ash, acks} = Ash.feed(Ash.new(), @corpus)
      assert length(acks) >= 5
    end

    test "byte-by-byte equals one-shot" do
      assert feed_bytewise(Ash.new(), @corpus) == Ash.feed(Ash.new(), @corpus)
    end

    test "every two-way split equals one-shot" do
      one_shot = Ash.feed(Ash.new(), @corpus)

      for split <- 0..byte_size(@corpus) do
        <<head::binary-size(^split), tail::binary>> = @corpus
        {ash, head_acks} = Ash.feed(Ash.new(), head)
        {ash, tail_acks} = Ash.feed(ash, tail)

        assert {ash, head_acks ++ tail_acks} == one_shot, "split at #{split}"
      end
    end

    test "every fixed chunk size equals one-shot" do
      one_shot = Ash.feed(Ash.new(), @corpus)

      for size <- 1..byte_size(@corpus) do
        chunks = for <<chunk::binary-size(^size) <- @corpus>>, do: chunk
        rest = binary_part(@corpus, size * length(chunks), rem(byte_size(@corpus), size))

        result =
          Enum.reduce(chunks ++ [rest], {Ash.new(), []}, fn chunk, {ash, acc} ->
            {ash, acks} = Ash.feed(ash, chunk)
            {ash, acc ++ acks}
          end)

        assert result == one_shot, "chunk size #{size}"
      end
    end
  end
end
