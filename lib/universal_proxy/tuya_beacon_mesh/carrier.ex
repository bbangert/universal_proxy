defmodule UniversalProxy.TuyaBeaconMesh.Carrier do
  @moduledoc """
  The P2 air carrier (tuya_beacon_mesh.md §2): a 26-byte frame travels as the payload of
  an AD 0x03 element (Complete List of 16-bit Service UUIDs), bytes verbatim. The bulbs
  send `02 01 06` (Flags) + `1B 03 <frame>`, 31 bytes, and so do we.

  Pure: no I/O.
  """

  @frame_size 26

  @doc "Legacy advertising data for one frame: Flags 0x06 then the AD 0x03 element."
  @spec ad_bytes(<<_::208>>) :: <<_::248>>
  def ad_bytes(<<_::binary-size(@frame_size)>> = frame),
    do: <<2, 1, 6, @frame_size + 1, 3>> <> frame

  @doc """
  Every 26-byte AD 0x03 payload in raw advertising data, in order. A malformed or
  truncated AD structure ends the walk; zero-length padding is skipped.
  """
  @spec frames(binary()) :: [<<_::208>>]
  def frames(data) when is_binary(data), do: walk(data, [])

  defp walk(<<0, rest::binary>>, acc), do: walk(rest, acc)

  defp walk(<<len, type, rest::binary>>, acc) when byte_size(rest) >= len - 1 do
    <<value::binary-size(^len - 1), more::binary>> = rest
    acc = if type == 3 and len - 1 == @frame_size, do: [value | acc], else: acc
    walk(more, acc)
  end

  defp walk(_, acc), do: Enum.reverse(acc)
end
