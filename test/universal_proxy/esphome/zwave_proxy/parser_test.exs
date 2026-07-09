defmodule UniversalProxy.ESPHome.ZWaveProxy.ParserTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.ESPHome.ZWaveProxy.{Frame, Parser}

  @ack Frame.ack()
  @nak Frame.nak()
  @can Frame.can()

  # GET_NETWORK_IDS response with home ID DE:AD:BE:EF, 16-bit node ID.
  # LENGTH = 9 (TYPE + CMD + 6 payload bytes + CHECKSUM), full frame =
  # LENGTH + 2 bytes.
  defp network_ids_response do
    body = <<0x01, 0x09, 0x01, 0x20, 0xDE, 0xAD, 0xBE, 0xEF, 0x05, 0x00>>
    body <> <<Frame.calculate_checksum(body <> <<0x00>>)>>
  end

  defp feed_all(data), do: Parser.feed(Parser.new(), data)

  describe "data frames" do
    test "valid frame in one burst: ACK first, then frame_complete" do
      frame = network_ids_response()
      {parser, actions} = feed_all(frame)

      assert actions == [{:send_response, @ack}, {:frame_complete, frame}]
      assert parser.state == :wait_start
      assert parser.last_response == @ack
    end

    test "same frame split byte-by-byte across feeds parses identically" do
      frame = network_ids_response()

      {parser, actions} =
        for <<byte <- frame>>, reduce: {Parser.new(), []} do
          {p, acc} ->
            {p, actions} = Parser.feed(p, <<byte>>)
            {p, acc ++ actions}
        end

      assert actions == [{:send_response, @ack}, {:frame_complete, frame}]
      assert parser.state == :wait_start
    end

    test "two frames in one burst yield ordered action pairs" do
      frame = network_ids_response()
      {_parser, actions} = feed_all(frame <> frame)

      assert actions == [
               {:send_response, @ack},
               {:frame_complete, frame},
               {:send_response, @ack},
               {:frame_complete, frame}
             ]
    end

    test "bad checksum: NAK, no frame, parser resyncs on next frame" do
      good = network_ids_response()
      corrupted = binary_part(good, 0, byte_size(good) - 1) <> <<0x00>>

      {parser, actions} = feed_all(corrupted <> good)

      assert actions == [
               {:send_response, @nak},
               {:send_response, @ack},
               {:frame_complete, good}
             ]

      assert parser.last_response == @ack
    end

    test "LENGTH below the minimum frame (0, 1, 2): immediate NAK, following frame still parses" do
      good = network_ids_response()

      for bad_len <- [0x00, 0x01, 0x02] do
        {_parser, actions} = feed_all(<<0x01, bad_len>> <> good)

        assert actions == [
                 {:send_response, @nak},
                 {:send_response, @ack},
                 {:frame_complete, good}
               ]
      end
    end

    # Documents the deliberate divergence from the C++ (audit F5): a
    # zero-payload frame (LENGTH = 3) is ACKed and forwarded correctly
    # here, whereas upstream would consume its checksum as payload.
    test "zero-payload frame (LENGTH = 3) is parsed correctly" do
      frame = Frame.build_simple_command(0x20)
      {_parser, actions} = feed_all(frame)

      assert actions == [{:send_response, @ack}, {:frame_complete, frame}]
    end
  end

  describe "single-byte frames" do
    test "ACK/NAK/CAN/BL_BEGIN_UPLOAD forward as one-byte frames, no local response" do
      for byte <- [@ack, @nak, @can, Frame.bl_begin_upload()] do
        {parser, actions} = feed_all(<<byte>>)
        assert actions == [{:frame_complete, <<byte>>}]
        assert parser.state == :wait_start
      end
    end

    test "unrecognized start bytes are ignored" do
      {parser, actions} = feed_all(<<0xAA, 0x55, 0xFE>>)
      assert actions == []
      assert parser.state == :wait_start
    end
  end

  describe "bootloader menu" do
    test "menu accumulates until 0x00 and forwards including terminator" do
      menu = <<Frame.bl_menu(), "Gecko Bootloader", 0x00>>
      {parser, actions} = feed_all(menu)

      assert actions == [{:frame_complete, menu}]
      assert parser.in_bootloader
    end

    test "SOF frame after a menu exits bootloader mode" do
      menu = <<Frame.bl_menu(), "menu", 0x00>>
      frame = network_ids_response()

      {parser, _actions} = feed_all(menu <> frame)
      refute parser.in_bootloader
    end

    test "a non-menu byte abandons the tentative menu and reparses as a frame start" do
      # A stray 0x0D followed immediately by a real SOF frame: the 0x0D is
      # NOT a bootloader menu; the frame after it must still parse, and we
      # must never enter bootloader mode.
      good = network_ids_response()
      {parser, actions} = feed_all(<<Frame.bl_menu()>> <> good)

      assert actions == [{:send_response, @ack}, {:frame_complete, good}]
      refute parser.in_bootloader
    end

    test "a lone ACK after a stray 0x0D is recovered, not swallowed" do
      # 0x06 (ACK) is not menu text, so the tentative menu bails and the
      # ACK is reparsed as a single-byte frame.
      {parser, actions} = feed_all(<<Frame.bl_menu(), @ack>>)
      assert actions == [{:frame_complete, <<@ack>>}]
      refute parser.in_bootloader
    end

    test "committing bootloader mode resets response deduplication" do
      # Prime last_response as if a prior ACK was sent, then complete a
      # real menu — the commit must clear it so a client's XMODEM
      # ACK/NAK/CAN during a firmware update isn't dropped as a duplicate.
      primed = %{Parser.new() | last_response: @ack}
      menu = <<Frame.bl_menu(), "Gecko Bootloader", 0x00>>
      {parser, _actions} = Parser.feed(primed, menu)

      assert parser.in_bootloader
      assert parser.last_response == 0
    end

    test "a menu overflowing the buffer without a terminator recovers on the next frame" do
      # All printable, so it stays a tentative menu until the 257-byte
      # buffer fills; then it bails and reparses. A following good frame
      # must still be ACKed and forwarded (no truncated menu emitted).
      overflowing = <<Frame.bl_menu()>> <> :binary.copy("A", 300)
      good = network_ids_response()

      {parser, actions} = feed_all(overflowing <> good)

      assert {:frame_complete, good} in actions
      refute Enum.any?(actions, fn a -> match?({:frame_complete, <<0x0D, _::binary>>}, a) end)
      refute parser.in_bootloader
    end
  end

  describe "duplicate_response?/2" do
    test "true for the single-byte response the parser just sent" do
      {parser, _actions} = feed_all(network_ids_response())
      assert Parser.duplicate_response?(parser, <<@ack>>)
      refute Parser.duplicate_response?(parser, <<@nak>>)
    end

    test "true after a NAK was sent locally" do
      {parser, _actions} = feed_all(<<0x01, 0x00>>)
      assert Parser.duplicate_response?(parser, <<@nak>>)
      refute Parser.duplicate_response?(parser, <<@ack>>)
    end

    test "never true for multi-byte frames" do
      {parser, _actions} = feed_all(network_ids_response())
      refute Parser.duplicate_response?(parser, <<@ack, @ack>>)
      refute Parser.duplicate_response?(parser, network_ids_response())
    end

    test "fresh parser only suppresses a (nonsense) 0x00 byte, like the C++" do
      parser = Parser.new()
      assert Parser.duplicate_response?(parser, <<0>>)
      refute Parser.duplicate_response?(parser, <<@ack>>)
    end
  end
end
