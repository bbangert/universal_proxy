defmodule UniversalProxy.ESPHome.ZigbeeProxy.Ash do
  @moduledoc """
  Pure functional ASH acknowledger for the NCP → host direction of an
  EZSP serial link.

  A behavioural port of ESPHome's `ezsp_proxy_tap` `AshAcknowledger`:
  while a client has put the Zigbee port in PROTOCOL mode, the proxy
  ACKs the NCP's DATA frames locally so the ACK isn't stuck behind the
  network round-trip. It only follows the NCP's frame numbering — it is
  an observer, never NAKs, and never acknowledges RSTACK, ACK, NAK, RST
  or ERROR frames. Frames are reassembled by `Ash.Scanner`.

  Deliberately matches the tap, not bellows: the tap syncs to the first
  DATA frame it sees when no RSTACK was seen (mid-session enable),
  ignores DATA frames with fewer than 3 data bytes, and lets a CANCEL
  end a SUBSTITUTE discard.

  ## Usage

      ash = Ash.new()
      {ash, acks} = Ash.feed(ash, ncp_bytes)

      Enum.each(acks, &Circuits.UART.write(pid, &1))
      send(subscriber, {:zigbee_rx, ncp_bytes})

  Feeding is byte-at-a-time, so how the input is chunked never changes
  the ACKs produced.
  """

  import Bitwise

  alias UniversalProxy.ESPHome.ZigbeeProxy.Ash.Scanner

  @flag 0x7E
  @rstack_control 0xC1
  @protocol_version 0x02
  # control, version, reset code
  @rstack_body_size 3
  # control + an EZSP frame of at least 3 bytes
  @min_data_body_size 4

  @crc_init 0xFFFF
  @crc_table (for byte <- 0..255 do
                Enum.reduce(1..8, byte <<< 8, fn _bit, crc ->
                  if (crc &&& 0x8000) != 0,
                    do: bxor(crc <<< 1, 0x1021) &&& 0xFFFF,
                    else: crc <<< 1 &&& 0xFFFF
                end)
              end)
             |> List.to_tuple()

  @type ack_num :: 0..7

  @type t :: %__MODULE__{
          scanner: Scanner.t(),
          rx_sequence: ack_num(),
          synced?: boolean()
        }

  defstruct scanner: %Scanner{}, rx_sequence: 0, synced?: false

  @doc """
  Create an acknowledger that has not yet seen the NCP's frame numbering.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Forget the NCP's frame numbering and any partial frame. The next RSTACK
  or DATA frame sets the numbering again.
  """
  @spec reset(t()) :: t()
  def reset(%__MODULE__{}), do: new()

  @doc """
  Feed bytes read from the NCP.

  Returns the updated acknowledger and the ACK frames owed, one per
  completed frame that earns one, in stream order. The caller writes
  them to the NCP.
  """
  @spec feed(t(), binary()) :: {t(), [binary()]}
  def feed(%__MODULE__{} = ash, data) when is_binary(data), do: feed(ash, data, [])

  defp feed(ash, <<byte, rest::binary>>, acks) do
    case feed_byte(ash, byte) do
      {ash, nil} -> feed(ash, rest, acks)
      {ash, ack_num} -> feed(ash, rest, [ack_frame(ack_num) | acks])
    end
  end

  defp feed(ash, <<>>, acks), do: {ash, Enum.reverse(acks)}

  @doc """
  The wire ACK frame for `ack_num` (only its low 3 bits are used):
  `FLAG, 0x80 | ack_num, CRC (big-endian), FLAG`.

  None of the eight possible frames contains a byte that needs escaping.
  """
  @spec ack_frame(non_neg_integer()) :: <<_::40>>
  def ack_frame(ack_num) when is_integer(ack_num) and ack_num >= 0 do
    control = 0x80 ||| (ack_num &&& 7)
    <<@flag, control, crc16(<<control>>)::16, @flag>>
  end

  @doc """
  CRC-16/CCITT-FALSE (poly 0x1021, no reflection, no final XOR) of
  `data`, continuing from `crc` — `0xFFFF` (the ASH initial value)
  starts a new checksum.

  ASH sends it big-endian after the unstuffed frame body; running it
  over the body plus its CRC leaves `0` when the frame is intact.
  """
  @spec crc16(binary(), 0..0xFFFF) :: 0..0xFFFF
  def crc16(data, crc \\ @crc_init) when is_binary(data) do
    for <<byte <- data>>, reduce: crc do
      acc -> bxor(acc <<< 8 &&& 0xFFFF, elem(@crc_table, bxor(acc >>> 8, byte)))
    end
  end

  defp feed_byte(%__MODULE__{scanner: scanner} = ash, byte) do
    case Scanner.feed_byte(scanner, byte) do
      {scanner, nil} -> {%{ash | scanner: scanner}, nil}
      {scanner, {length, header}} -> handle_frame(%{ash | scanner: scanner}, length, header)
    end
  end

  # An RSTACK restarts the NCP's frame numbering; anything else carrying
  # the RSTACK control byte (bad length or version) is ignored.
  defp handle_frame(ash, @rstack_body_size, <<@rstack_control, @protocol_version>>) do
    {%{ash | rx_sequence: 0, synced?: true}, nil}
  end

  # ACK/NAK/RST/ERROR (and a malformed RSTACK): nothing is owed.
  defp handle_frame(ash, _length, <<control, _rest::binary>>) when control >= 0x80 do
    {ash, nil}
  end

  defp handle_frame(ash, length, _header) when length < @min_data_body_size do
    {ash, nil}
  end

  defp handle_frame(ash, _length, <<control, _rest::binary>>) do
    frame_num = control >>> 4 &&& 7
    re_tx? = (control &&& 0x08) != 0

    # Without an RSTACK the session began before we were watching:
    # follow the NCP's numbering.
    rx = if ash.synced?, do: ash.rx_sequence, else: frame_num
    ash = %{ash | rx_sequence: rx, synced?: true}

    cond do
      frame_num == rx ->
        next = rx + 1 &&& 7
        {%{ash | rx_sequence: next}, next}

      re_tx? ->
        {ash, rx}

      true ->
        {ash, nil}
    end
  end
end
