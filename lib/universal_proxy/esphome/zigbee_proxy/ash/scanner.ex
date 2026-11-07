defmodule UniversalProxy.ESPHome.ZigbeeProxy.Ash.Scanner do
  @moduledoc """
  Reassembles one direction of an ASH byte stream into unstuffed,
  CRC-checked frames, one byte at a time.

  A port of ESPHome's `ezsp_proxy_tap` `AshFrameScanner`. Only the first
  two body bytes (control + first data byte) are kept: the CRC is checked
  as bytes arrive and acknowledging needs nothing past the header.

  Byte handling, in order:

  - `FLAG` (`0x7E`) ends a frame — valid only if not discarding, not
    poisoned, no escape pending, at least control + CRC was read, and
    the running CRC is 0. Always resets.
  - `CANCEL` (`0x1A`) resets, which also ends a SUBSTITUTE discard.
  - While discarding everything else is ignored; `WAKE` (`0xFF`) is
    ignored only between frames.
  - `SUBSTITUTE` (`0x18`) discards through the next FLAG; `XON`/`XOFF`
    (`0x11`/`0x13`) are dropped anywhere, even with an escape pending;
    `ESCAPE` (`0x7D`) XORs the next stored byte with `0x20`.
  - A body + CRC longer than 223 bytes (220 data bytes) poisons the frame.
  """

  alias UniversalProxy.ESPHome.ZigbeeProxy.Ash

  import Bitwise

  @flag 0x7E
  @escape 0x7D
  @xon 0x11
  @xoff 0x13
  @substitute 0x18
  @cancel 0x1A
  @wake 0xFF
  @xor 0x20

  @crc_size 2
  # Smallest legal frame: a bare control byte plus its CRC
  @min_frame_size 1 + @crc_size
  # control + 220 data bytes + CRC
  @max_frame_size 1 + 220 + @crc_size
  @header_size 2

  @typedoc """
  A completed, CRC-valid frame: its body length (control + data, CRC
  excluded) and the first `min(length, 2)` body bytes.
  """
  @type frame :: {length :: pos_integer(), header :: binary()}

  @type t :: %__MODULE__{
          idx: non_neg_integer(),
          crc: 0..0xFFFF,
          escaped?: boolean(),
          discarding?: boolean(),
          poisoned?: boolean(),
          header: binary()
        }

  defstruct idx: 0,
            crc: 0xFFFF,
            escaped?: false,
            discarding?: false,
            poisoned?: false,
            header: <<>>

  @doc """
  Create a scanner waiting for the start of a frame.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Feed one byte. Returns `{scanner, frame}` when the byte is a FLAG that
  completes a valid frame, otherwise `{scanner, nil}`.
  """
  @spec feed_byte(t(), byte()) :: {t(), frame() | nil}
  def feed_byte(%__MODULE__{} = scanner, @flag) do
    {new(), completed_frame(scanner)}
  end

  def feed_byte(%__MODULE__{}, @cancel), do: {new(), nil}
  def feed_byte(%__MODULE__{discarding?: true} = scanner, _byte), do: {scanner, nil}
  def feed_byte(%__MODULE__{idx: 0} = scanner, @wake), do: {scanner, nil}

  def feed_byte(%__MODULE__{} = scanner, @substitute) do
    {%{scanner | discarding?: true}, nil}
  end

  def feed_byte(%__MODULE__{} = scanner, byte) when byte in [@xon, @xoff], do: {scanner, nil}

  def feed_byte(%__MODULE__{} = scanner, @escape) do
    {%{scanner | escaped?: true}, nil}
  end

  def feed_byte(%__MODULE__{escaped?: true} = scanner, byte) do
    store(%{scanner | escaped?: false}, bxor(byte, @xor))
  end

  def feed_byte(%__MODULE__{} = scanner, byte), do: store(scanner, byte)

  defp completed_frame(%__MODULE__{
         discarding?: false,
         poisoned?: false,
         escaped?: false,
         crc: 0,
         idx: idx,
         header: header
       })
       when idx >= @min_frame_size do
    length = idx - @crc_size
    # A 1-byte body leaves a CRC byte in the header.
    {length, binary_part(header, 0, min(length, @header_size))}
  end

  defp completed_frame(%__MODULE__{}), do: nil

  defp store(%__MODULE__{idx: idx} = scanner, _value) when idx >= @max_frame_size do
    {%{scanner | poisoned?: true}, nil}
  end

  defp store(%__MODULE__{idx: idx, header: header} = scanner, value) do
    header = if idx < @header_size, do: <<header::binary, value>>, else: header
    {%{scanner | idx: idx + 1, crc: Ash.crc16(<<value>>, scanner.crc), header: header}, nil}
  end
end
