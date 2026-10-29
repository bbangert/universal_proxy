defmodule UniversalProxy.TuyaBeaconMesh.Crypto do
  @moduledoc """
  Primitives shared by the Tuya beacon protocols (tuya_beacon_mesh.md §3): CRC-8/SMBUS,
  CRC-16/MODBUS, XXTEA with big-endian word packing, and the Tuya key-string rule.

  Pure: no I/O.
  """
  import Bitwise

  @delta 0x9E3779B9
  @mask32 0xFFFFFFFF

  @doc "CRC-8/SMBUS: poly 0x07, init 0, no reflection. `crc8(\"123456789\") == 0xF4`."
  @spec crc8(binary()) :: byte()
  def crc8(data) when is_binary(data) do
    for <<b <- data>>, reduce: 0 do
      crc -> crc8_byte(bxor(crc, b), 8)
    end
  end

  defp crc8_byte(crc, 0), do: crc

  defp crc8_byte(crc, n) do
    crc = if (crc &&& 0x80) != 0, do: bxor(crc <<< 1, 0x07) &&& 0xFF, else: crc <<< 1 &&& 0xFF
    crc8_byte(crc, n - 1)
  end

  @doc "CRC-16/MODBUS, returned as 2 bytes big-endian. check(\"123456789\") == <<0x4B, 0x37>>."
  @spec crc16_modbus(binary()) :: <<_::16>>
  def crc16_modbus(data) when is_binary(data) do
    crc =
      for <<b <- data>>, reduce: 0xFFFF do
        crc -> crc16_byte(bxor(crc, b), 8)
      end

    <<crc::16>>
  end

  defp crc16_byte(crc, 0), do: crc

  defp crc16_byte(crc, n) do
    crc = if (crc &&& 1) != 0, do: bxor(crc >>> 1, 0xA001), else: crc >>> 1
    crc16_byte(crc, n - 1)
  end

  @doc """
  XXTEA encrypt with big-endian word packing and no length word. `data` is zero-padded to
  a multiple of 4 bytes; `key` must be 16 bytes.
  """
  @spec xxtea_encrypt(binary(), <<_::128>>) :: binary()
  def xxtea_encrypt(data, <<_::128>> = key) do
    v = words(data)
    k = words(key)
    n = tuple_size(v)
    rounds = 6 + div(52, n)

    {v, _s, _z} =
      Enum.reduce(1..rounds, {v, 0, elem(v, n - 1)}, fn _, {v, s, z} ->
        s = s + @delta &&& @mask32
        e = s >>> 2 &&& 3

        Enum.reduce(0..(n - 1), {v, s, z}, fn p, {v, s, z} ->
          y = elem(v, rem(p + 1, n))
          vp = elem(v, p) + mx(z, y, s, p, e, k) &&& @mask32
          {put_elem(v, p, vp), s, vp}
        end)
      end)

    unwords(v)
  end

  @doc "Inverse of `xxtea_encrypt/2`."
  @spec xxtea_decrypt(binary(), <<_::128>>) :: binary()
  def xxtea_decrypt(data, <<_::128>> = key) do
    v = words(data)
    k = words(key)
    n = tuple_size(v)
    rounds = 6 + div(52, n)

    {v, _s, _y} =
      Enum.reduce(1..rounds, {v, rounds * @delta &&& @mask32, elem(v, 0)}, fn _, {v, s, y} ->
        e = s >>> 2 &&& 3

        {v, y} =
          Enum.reduce((n - 1)..0//-1, {v, y}, fn p, {v, y} ->
            z = elem(v, rem(p - 1 + n, n))
            vp = elem(v, p) - mx(z, y, s, p, e, k) &&& @mask32
            {put_elem(v, p, vp), vp}
          end)

        {v, s - @delta &&& @mask32, y}
      end)

    unwords(v)
  end

  defp mx(z, y, s, p, e, k) do
    a = bxor(z >>> 5, y <<< 2 &&& @mask32)
    b = bxor(y >>> 3, z <<< 4 &&& @mask32)
    c = bxor(s, y)
    d = bxor(elem(k, bxor(p &&& 3, e)), z)
    bxor(a + b &&& @mask32, c + d &&& @mask32)
  end

  defp words(bin) do
    pad = rem(4 - rem(byte_size(bin), 4), 4)
    for(<<w::32-big <- bin <> :binary.copy(<<0>>, pad)>>, do: w) |> List.to_tuple()
  end

  defp unwords(v), do: for(w <- Tuple.to_list(v), into: <<>>, do: <<w::32-big>>)

  @doc """
  Tuya key-string rule (§3): a 16-char key is used as its ASCII bytes, a 32-char one is
  hex-decoded. A 16-byte binary that is neither passes through unchanged.
  """
  @spec key_bytes(String.t()) :: <<_::128>>
  def key_bytes(key) when byte_size(key) == 32, do: Base.decode16!(key, case: :mixed)
  def key_bytes(key) when byte_size(key) == 16, do: key

  def key_bytes(key),
    do: raise(ArgumentError, "key must be 16 ASCII chars or 32 hex chars, got #{byte_size(key)}")
end
