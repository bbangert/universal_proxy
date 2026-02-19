defmodule UniversalProxy.ESPHome.ZWave.Frame do
  @moduledoc """
  Pure functions and constants for the Z-Wave Serial API frame format.

  The Z-Wave Serial API uses a simple framing protocol over UART:

  - **Single-byte frames:** ACK (0x06), NAK (0x15), CAN (0x18)
  - **Data frames:** SOF (0x01) | LENGTH | TYPE | CMD | PAYLOAD... | CHECKSUM

  The checksum is the XOR of all bytes between SOF and the checksum
  position (exclusive), with an initial value of 0xFF.

  This module contains no processes or side effects -- only data
  transformation functions suitable for use in the parser and server.
  """

  import Bitwise

  # -- Frame type bytes --

  @sof 0x01
  @ack 0x06
  @nak 0x15
  @can 0x18
  @bl_menu 0x0D
  @bl_begin_upload 0x43

  # -- Z-Wave Serial API constants --

  @command_get_network_ids 0x20
  @command_type_response 0x01
  @min_get_network_ids_length 9
  @home_id_size 4

  defguard is_single_byte_frame(byte) when byte in [@ack, @nak, @can]

  def sof, do: @sof
  def ack, do: @ack
  def nak, do: @nak
  def can, do: @can
  def bl_menu, do: @bl_menu
  def bl_begin_upload, do: @bl_begin_upload

  def command_get_network_ids, do: @command_get_network_ids
  def command_type_response, do: @command_type_response
  def min_get_network_ids_length, do: @min_get_network_ids_length
  def home_id_size, do: @home_id_size

  @doc """
  Calculate the Z-Wave frame checksum.

  XOR all bytes from offset 1 to length-2 (inclusive), starting
  with initial value 0xFF. Expects the full frame as a binary
  (including SOF and the checksum position).
  """
  @spec calculate_checksum(binary()) :: byte()
  def calculate_checksum(frame) when is_binary(frame) do
    size = byte_size(frame)

    frame
    |> :binary.bin_to_list()
    |> Enum.slice(1, size - 2)
    |> Enum.reduce(0xFF, &bxor/2)
  end

  @doc """
  Validate the checksum of a complete Z-Wave data frame.

  Returns `true` if the last byte matches the calculated checksum.
  """
  @spec valid_checksum?(binary()) :: boolean()
  def valid_checksum?(frame) when byte_size(frame) >= 3 do
    expected = calculate_checksum(frame)
    last_byte = :binary.at(frame, byte_size(frame) - 1)
    expected == last_byte
  end

  def valid_checksum?(_), do: false

  @doc """
  Build a simple Z-Wave command frame with no parameters.

  Frame format: SOF | LENGTH(0x03) | TYPE(0x00) | CMD | CHECKSUM
  """
  @spec build_simple_command(byte()) :: binary()
  def build_simple_command(command_id) when is_integer(command_id) do
    partial = <<@sof, 0x03, 0x00, command_id>>
    checksum = calculate_checksum(partial <> <<0x00>>)
    partial <> <<checksum>>
  end

  @doc """
  Returns the pre-built GET_NETWORK_IDS (0x20) command frame.
  """
  @spec get_network_ids_command() :: binary()
  def get_network_ids_command do
    build_simple_command(@command_get_network_ids)
  end

  @doc """
  Extract the 4-byte home ID from a GET_NETWORK_IDS response frame.

  The frame buffer must start at SOF. Returns `{:ok, home_id_bytes}`
  if the frame is a valid GET_NETWORK_IDS response, or `:error` otherwise.

  Frame format: SOF(0x01) | LENGTH(>=0x09) | TYPE(0x01) | CMD(0x20) | HOME_ID(4) | NODE_ID | ... | CHECKSUM
  """
  @spec extract_home_id(binary()) :: {:ok, <<_::32>>} | :error
  def extract_home_id(
        <<@sof, length, @command_type_response, @command_get_network_ids, rest::binary>>
      )
      when length >= @min_get_network_ids_length and byte_size(rest) >= @home_id_size do
    <<home_id::binary-size(@home_id_size), _rest::binary>> = rest
    {:ok, home_id}
  end

  def extract_home_id(_), do: :error

  @doc """
  Encode a 4-byte home ID binary as a uint32 (big-endian).
  """
  @spec encode_home_id(<<_::32>>) :: non_neg_integer()
  def encode_home_id(<<a, b, c, d>>) do
    (a <<< 24) ||| (b <<< 16) ||| (c <<< 8) ||| d
  end

  def encode_home_id(_), do: 0

  @doc """
  Compute the frame length for forwarding to the API client.

  For data frames (starting with SOF), returns `length_byte + 2`
  (SOF + payload + checksum). For single-byte frames, returns 1.
  """
  @spec frame_data_length(binary()) :: non_neg_integer()
  def frame_data_length(<<@sof, length, _rest::binary>>), do: length + 2
  def frame_data_length(<<_byte>>), do: 1
  def frame_data_length(data) when is_binary(data), do: byte_size(data)
end
