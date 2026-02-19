defmodule UniversalProxy.ESPHome.ZWave.Parser do
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

  alias UniversalProxy.ESPHome.ZWave.Frame

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
          | :send_can
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

  # -- Internal byte-level state machine --

  defp parse_byte(%{state: :wait_start} = parser, byte) do
    parse_start(parser, byte)
  end

  defp parse_byte(%{state: :wait_length} = parser, byte) do
    if byte == 0 do
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

  defp parse_byte(%{state: :read_bl_menu} = parser, byte) do
    parser = put_byte(parser, byte)

    if byte == 0 do
      frame_data = binary_part(parser.buffer, 0, parser.buffer_index)
      {%{parser | state: :wait_start}, [{:frame_complete, frame_data}]}
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
    parser = %{parser | buffer_index: 0, in_bootloader: true}
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
       when state in [:send_ack, :send_nak, :send_can] do
    response_byte =
      case state do
        :send_ack -> Frame.ack()
        :send_nak -> Frame.nak()
        :send_can -> Frame.can()
      end

    parser = %{parser | last_response: response_byte, state: :wait_start}
    {parser, actions ++ [{:send_response, response_byte}]}
  end

  defp handle_response(parser, actions) do
    {parser, actions}
  end

  # -- Buffer helpers --

  defp put_byte(%{buffer_index: idx} = parser, byte) when idx < @max_frame_size do
    <<prefix::binary-size(idx), _old, suffix::binary>> = parser.buffer
    buffer = <<prefix::binary, byte, suffix::binary>>
    %{parser | buffer: buffer, buffer_index: idx + 1}
  end

  defp put_byte(parser, _byte), do: parser
end
