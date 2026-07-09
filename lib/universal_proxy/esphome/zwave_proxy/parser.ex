defmodule UniversalProxy.ESPHome.ZWaveProxy.Parser do
  @moduledoc """
  Pure functional state machine for parsing Z-Wave Serial API frames.

  Mirrors the C++ `ZWaveParsingState` enum from the ESPHome zwave_proxy
  component. Takes parser state + bytes, returns new state + a list of
  actions for the caller to execute. Contains no side effects -- all UART
  writes and network sends are expressed as action tuples.

  ## Actions

  The `feed/2` function returns `{updated_parser, actions}` where each
  action is one of:

  - `{:send_response, byte}` -- the caller should write this byte (ACK/NAK/CAN)
    to the UART immediately (local acknowledgment, latency-critical)
  - `{:frame_complete, binary}` -- a complete validated frame is ready to
    forward to the API client

  ## Usage

      parser = Parser.new()
      {parser, actions} = Parser.feed(parser, uart_bytes)

      Enum.each(actions, fn
        {:send_response, byte} -> Circuits.UART.write(pid, <<byte>>)
        {:frame_complete, data} -> send(subscriber, {:zwave_frame, data})
      end)

  """

  alias UniversalProxy.ESPHome.ZWaveProxy.Frame

  @sof Frame.sof()
  @ack Frame.ack()
  @nak Frame.nak()
  @can Frame.can()
  @bl_menu Frame.bl_menu()
  @bl_begin_upload Frame.bl_begin_upload()

  @type state ::
          :wait_start
          | :wait_length
          | :wait_type
          | :wait_command_id
          | :wait_payload
          | :wait_checksum
          | :send_ack
          | :send_nak
          | :read_bl_menu

  @type action ::
          {:send_response, byte()}
          | {:frame_complete, binary()}

  @type t :: %__MODULE__{
          state: state(),
          buffer: binary(),
          buffer_index: non_neg_integer(),
          end_frame_after: non_neg_integer(),
          last_response: byte(),
          in_bootloader: boolean()
        }

  defstruct state: :wait_start,
            buffer: <<0::size(257)-unit(8)>>,
            buffer_index: 0,
            end_frame_after: 0,
            last_response: 0,
            in_bootloader: false

  @max_frame_size 257

  # Smallest valid LENGTH byte: TYPE + CMD + CHECKSUM (a zero-payload
  # frame). Anything shorter can't carry a command, so it's rejected.
  @min_frame_length 3

  # A byte that can appear in bootloader-menu output: printable ASCII
  # plus CR/LF and the NUL terminator. Used to read the menu tentatively
  # (see `parse_start/2` for BL_MENU and the `:read_bl_menu` handler).
  defguardp is_bl_menu_byte(byte)
            when byte == 0 or byte == 0x0D or byte == 0x0A or (byte >= 0x20 and byte <= 0x7E)

  @doc """
  Create a new parser in the initial waiting state.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{buffer: <<0::size(@max_frame_size)-unit(8)>>}
  end

  @doc """
  Feed a binary of UART bytes through the parser.

  Processes each byte through the state machine and accumulates actions.
  Returns `{updated_parser, actions}` where actions is a list to be
  executed in order by the caller.
  """
  @spec feed(t(), binary()) :: {t(), [action()]}
  def feed(%__MODULE__{} = parser, <<>>) do
    {parser, []}
  end

  def feed(%__MODULE__{} = parser, data) when is_binary(data) do
    data
    |> :binary.bin_to_list()
    |> Enum.reduce({parser, []}, fn byte, {p, actions} ->
      {p2, new_actions} = parse_byte(p, byte)
      {p2, actions ++ new_actions}
    end)
  end

  @doc """
  Should a client-originated frame be suppressed as a duplicate of the
  response this parser already sent locally?

  Mirrors the C++ `send_frame` guard exactly: the proxy pre-ACKs every
  valid frame on the UART for latency, and the API client (Z-Wave JS)
  then sends its own ACK — forwarding that duplicate would hand the
  module a second ACK it may misattribute to the next frame in flight.
  Like the C++, `last_response` is not reset after a suppressed frame.
  """
  @spec duplicate_response?(t(), binary()) :: boolean()
  def duplicate_response?(%__MODULE__{last_response: last}, <<byte>>), do: byte == last
  def duplicate_response?(%__MODULE__{}, _data), do: false

  @doc """
  Is the parser partway through a frame (i.e. not idle at `:wait_start`)?

  The owning server uses this to abandon a stalled partial frame after an
  inter-byte timeout — a byte lost to UART noise would otherwise leave
  stale bytes that corrupt the next frame.
  """
  @spec mid_frame?(t()) :: boolean()
  def mid_frame?(%__MODULE__{state: :wait_start}), do: false
  def mid_frame?(%__MODULE__{}), do: true

  # -- Internal byte-level state machine --

  defp parse_byte(%{state: :wait_start} = parser, byte) do
    parse_start(parser, byte)
  end

  defp parse_byte(%{state: :wait_length} = parser, byte) do
    # Reject any LENGTH below a minimal frame (was: only 0). A 1- or
    # 2-byte length can't hold TYPE + CMD + CHECKSUM. NAK immediately —
    # our handle_response runs inline, so bytes already buffered behind
    # this one are reparsed rather than dropped.
    if byte < @min_frame_length do
      {%{parser | state: :send_nak}, []}
      |> then(fn {p, a} -> handle_response(p, a) end)
    else
      parser = put_byte(parser, byte)
      parser = %{parser | end_frame_after: parser.buffer_index + byte - 1}
      {%{parser | state: :wait_type}, []}
    end
  end

  defp parse_byte(%{state: :wait_type} = parser, byte) do
    parser = put_byte(parser, byte)
    {%{parser | state: :wait_command_id}, []}
  end

  # DELIBERATE divergence from the C++ (see audit F5): upstream moves to
  # WAIT_PAYLOAD unconditionally here, so a zero-payload frame (LENGTH =
  # 3: TYPE + CMD + CHECKSUM) has its checksum consumed as payload and
  # the parser then eats one extra byte. We check `end_frame_after` so
  # L=3 frames parse correctly. Unreachable in practice (module→host
  # frames carry payload) — do not "fix" this back to match upstream.
  defp parse_byte(%{state: :wait_command_id} = parser, byte) do
    parser = put_byte(parser, byte)

    if parser.buffer_index >= parser.end_frame_after do
      {%{parser | state: :wait_checksum}, []}
    else
      {%{parser | state: :wait_payload}, []}
    end
  end

  defp parse_byte(%{state: :wait_payload} = parser, byte) do
    parser = put_byte(parser, byte)

    if parser.buffer_index >= parser.end_frame_after do
      {%{parser | state: :wait_checksum}, []}
    else
      {parser, []}
    end
  end

  defp parse_byte(%{state: :wait_checksum} = parser, byte) do
    parser = put_byte(parser, byte)
    frame_data = binary_part(parser.buffer, 0, parser.buffer_index)
    calculated = Frame.calculate_checksum(frame_data)

    if calculated == byte do
      parser = %{parser | state: :send_ack}
      {parser, actions} = handle_response(parser, [])
      {parser, actions ++ [{:frame_complete, frame_data}]}
    else
      parser = %{parser | state: :send_nak}
      handle_response(parser, [])
    end
  end

  # The menu is read tentatively (see `parse_start/2` for BL_MENU): a
  # byte that can't be menu text — or a buffer that fills without a NUL
  # terminator — means the 0x0D that started this state wasn't really a
  # bootloader menu (e.g. garbled data after the parser lost frame
  # alignment). Abandon the tentative menu and re-parse this byte as a
  # fresh frame start; it may be the SOF/ACK/NAK of real traffic.
  defp parse_byte(%{state: :read_bl_menu, buffer_index: idx} = parser, byte)
       when idx >= @max_frame_size or not is_bl_menu_byte(byte) do
    parse_start(%{parser | state: :wait_start}, byte)
  end

  defp parse_byte(%{state: :read_bl_menu} = parser, byte) do
    parser = put_byte(parser, byte)

    if byte == 0 do
      # A plausible menu completed with its NUL terminator — commit
      # bootloader mode now. Reset response dedup: in bootloader mode a
      # client's single-byte XMODEM writes (ACK/NAK/CAN) are raw data
      # and must never be suppressed as duplicate proxy responses.
      frame_data = binary_part(parser.buffer, 0, parser.buffer_index)
      parser = %{parser | state: :wait_start, in_bootloader: true, last_response: 0}
      {parser, [{:frame_complete, frame_data}]}
    else
      {parser, []}
    end
  end

  defp parse_byte(parser, _byte) do
    {%{parser | state: :wait_start}, []}
  end

  # -- Start byte handling (mirrors C++ parse_start_) --

  defp parse_start(parser, @sof) do
    parser = %{parser | buffer_index: 0, in_bootloader: false}
    parser = put_byte(parser, @sof)
    {%{parser | state: :wait_length}, []}
  end

  defp parse_start(parser, @bl_menu) do
    # Tentative — do NOT commit bootloader mode yet. A stray 0x0D also
    # appears in garbled data after a lost frame boundary; `in_bootloader`
    # flips only once a plausible menu completes (see `:read_bl_menu`).
    parser = %{parser | buffer_index: 0}
    parser = put_byte(parser, @bl_menu)
    {%{parser | state: :read_bl_menu}, []}
  end

  defp parse_start(parser, byte)
       when byte in [@ack, @nak, @can, @bl_begin_upload] do
    parser = %{parser | buffer_index: 0}
    parser = put_byte(parser, byte)
    {%{parser | state: :wait_start}, [{:frame_complete, <<byte>>}]}
  end

  defp parse_start(parser, _byte) do
    {parser, []}
  end

  # -- Response handling (mirrors C++ response_handler_) --

  defp handle_response(%{state: state} = parser, actions)
       when state in [:send_ack, :send_nak] do
    response_byte =
      case state do
        :send_ack -> Frame.ack()
        :send_nak -> Frame.nak()
      end

    parser = %{parser | last_response: response_byte, state: :wait_start}
    {parser, actions ++ [{:send_response, response_byte}]}
  end

  defp handle_response(parser, actions) do
    {parser, actions}
  end

  # -- Buffer helpers --

  defp put_byte(%{buffer_index: idx} = parser, byte) when idx < @max_frame_size do
    <<prefix::binary-size(^idx), _old, suffix::binary>> = parser.buffer
    buffer = <<prefix::binary, byte, suffix::binary>>
    %{parser | buffer: buffer, buffer_index: idx + 1}
  end

  defp put_byte(parser, _byte), do: parser
end
