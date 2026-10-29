defmodule UniversalProxy.TuyaBeaconMesh.Dp do
  @moduledoc """
  P2 data-point TLVs (tuya_beacon_mesh.md §4.4): each DP is
  `[dp_id][(type << 4) | len][value]`, concatenated, at most 16 bytes in all.

  Values are typed as `{dp_id, type, value}`:

  | type | wire | value |
  |---|---|---|
  | `:raw` | 0 | binary |
  | `:bool` | 1 | boolean (1 byte) |
  | `:value` | 2 | integer (4 bytes, big-endian, signed) |
  | `:string` | 3 | UTF-8 binary |
  | `:enum` | 4 | integer index (1 byte) |
  | `:bitmap` | 5 | non-negative integer (receive only) |

  Pure: no I/O.
  """
  import Bitwise

  @type dp_type :: :raw | :bool | :value | :string | :enum | :bitmap
  @type dp :: {1..255, dp_type(), term()}

  @types %{raw: 0, bool: 1, value: 2, string: 3, enum: 4, bitmap: 5}
  @names Map.new(@types, fn {k, v} -> {v, k} end)

  @doc "Encodes DPs into TLVs; `{:error, :too_long}` past 16 bytes."
  @spec encode([dp()]) :: {:ok, binary()} | {:error, term()}
  def encode(dps) when is_list(dps) do
    tlvs = Enum.map(dps, &encode_one/1)

    case Enum.find(tlvs, &match?({:error, _}, &1)) do
      nil ->
        bin = IO.iodata_to_binary(tlvs)
        if byte_size(bin) <= 16, do: {:ok, bin}, else: {:error, :too_long}

      err ->
        err
    end
  end

  defp encode_one({id, type, value}) when id in 1..255 do
    case value_bytes(type, value) do
      {:ok, v} when byte_size(v) <= 15 -> <<id, @types[type] <<< 4 ||| byte_size(v), v::binary>>
      {:ok, _} -> {:error, {:value_too_long, id}}
      :error -> {:error, {:bad_value, id, type, value}}
    end
  end

  defp encode_one(other), do: {:error, {:bad_dp, other}}

  defp value_bytes(:bool, v) when is_boolean(v), do: {:ok, if(v, do: <<1>>, else: <<0>>)}
  defp value_bytes(:value, v) when is_integer(v), do: {:ok, <<v::32-big-signed>>}
  defp value_bytes(:enum, v) when v in 0..255, do: {:ok, <<v>>}
  defp value_bytes(:string, v) when is_binary(v), do: {:ok, v}
  defp value_bytes(:raw, v) when is_binary(v), do: {:ok, v}
  defp value_bytes(_, _), do: :error

  @doc "Decodes TLVs until a zero DP id or the end of the payload."
  @spec decode(binary()) :: [dp()]
  def decode(<<id, type::4, len::4, rest::binary>>) when id != 0 and byte_size(rest) >= len do
    <<v::binary-size(^len), rest::binary>> = rest
    name = Map.get(@names, type, type)
    [{id, name, decode_value(name, v)} | decode(rest)]
  end

  def decode(_), do: []

  defp decode_value(:bool, <<b>>), do: b != 0
  defp decode_value(:value, <<v::32-big-signed>>), do: v
  defp decode_value(:enum, <<v>>), do: v
  defp decode_value(:bitmap, v) when byte_size(v) > 0, do: :binary.decode_unsigned(v)
  defp decode_value(_, v), do: v
end
