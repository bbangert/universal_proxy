defmodule UniversalProxy.MilkDropUploadFixtures do
  @moduledoc """
  Byte-level builders for `UniversalProxy.MilkDrop.Zip` / `UploadCheck` /
  `ImportPlan` tests: zips written header by header (so every field can
  lie), and minimal PNG/JPEG headers.

  `zip/2` takes a list of entries (keyword lists or maps) with `:name` and
  `:data` (default `""`) and `:method` (`:stored`, the default, or
  `:deflate`). Everything else overrides a field: `:method_code`, `:flags`
  (default bit 11, UTF-8), `:crc`, `:csize`, `:usize`, `:ext_attr`,
  `:offset`, `:disk`, `:cd_extra`, `:compressed` (the raw bytes stored),
  and for the local header `:local_name`, `:local_flags`, `:local_method`,
  `:local_crc`, `:local_csize`, `:local_usize`, `:local_extra`, `:trailer`
  (bytes after the data, e.g. a data descriptor). Archive options:
  `:count`, `:on_disk`, `:disk`, `:cd_disk`, `:comment`, `:prefix`,
  `:zip64_locator` (insert one before the EOCD).
  """

  import Bitwise

  @spec zip([keyword() | map()], keyword()) :: binary()
  def zip(entries, opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "")

    {locals, cds, cd_offset} =
      Enum.reduce(entries, {[], [], byte_size(prefix)}, fn entry, {locals, cds, offset} ->
        {local, cd} = entry(Map.new(entry), offset)
        {[local | locals], [cd | cds], offset + byte_size(local)}
      end)

    cd = cds |> Enum.reverse() |> IO.iodata_to_binary()
    count = Keyword.get(opts, :count, length(entries))
    comment = Keyword.get(opts, :comment, "")

    locator =
      if Keyword.get(opts, :zip64_locator, false),
        do: <<"PK", 6, 7, 0::32, 0::64, 1::little-32>>,
        else: ""

    eocd =
      <<"PK", 5, 6, Keyword.get(opts, :disk, 0)::little-16,
        Keyword.get(opts, :cd_disk, 0)::little-16, Keyword.get(opts, :on_disk, count)::little-16,
        count::little-16, byte_size(cd)::little-32, cd_offset::little-32,
        byte_size(comment)::little-16, comment::binary>>

    IO.iodata_to_binary([prefix, Enum.reverse(locals), cd, locator, eocd])
  end

  defp entry(e, offset) do
    name = Map.fetch!(e, :name)
    data = Map.get(e, :data, "")
    method = Map.get(e, :method, :stored)
    code = Map.get(e, :method_code, if(method == :deflate, do: 8, else: 0))

    compressed =
      Map.get_lazy(e, :compressed, fn -> if method == :deflate, do: deflate(data), else: data end)

    flags = Map.get(e, :flags, 0x0800)
    crc = Map.get(e, :crc, :erlang.crc32(data))
    csize = Map.get(e, :csize, byte_size(compressed))
    usize = Map.get(e, :usize, byte_size(data))
    local_name = Map.get(e, :local_name, name)
    local_extra = Map.get(e, :local_extra, "")
    cd_extra = Map.get(e, :cd_extra, "")

    local =
      <<"PK", 3, 4, 20::little-16, Map.get(e, :local_flags, flags)::little-16,
        Map.get(e, :local_method, code)::little-16, 0::32, Map.get(e, :local_crc, crc)::little-32,
        Map.get(e, :local_csize, csize)::little-32, Map.get(e, :local_usize, usize)::little-32,
        byte_size(local_name)::little-16, byte_size(local_extra)::little-16, local_name::binary,
        local_extra::binary, compressed::binary, Map.get(e, :trailer, "")::binary>>

    cd =
      <<"PK", 1, 2, 0x031E::little-16, 20::little-16, flags::little-16, code::little-16, 0::32,
        crc::little-32, csize::little-32, usize::little-32, byte_size(name)::little-16,
        byte_size(cd_extra)::little-16, 0::little-16, Map.get(e, :disk, 0)::little-16,
        0::little-16, Map.get(e, :ext_attr, default_attr(name))::little-32,
        Map.get(e, :offset, offset)::little-32, name::binary, cd_extra::binary>>

    {local, cd}
  end

  defp default_attr(name) do
    if String.ends_with?(name, "/"), do: 0o040755 <<< 16, else: 0o100644 <<< 16
  end

  @doc "Raw deflate (no zlib header), as zip method 8 stores it."
  @spec deflate(iodata()) :: binary()
  def deflate(data) do
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, :default, :deflated, -15, 8, :default)
    out = :zlib.deflate(z, data, :finish)
    :ok = :zlib.deflateEnd(z)
    :zlib.close(z)
    IO.iodata_to_binary(out)
  end

  @doc "A PNG signature + IHDR (no image data: only the header is checked)."
  @spec png(non_neg_integer(), non_neg_integer(), keyword()) :: binary()
  def png(w, h, opts \\ []) do
    ihdr =
      <<w::32, h::32, Keyword.get(opts, :depth, 8), Keyword.get(opts, :color, 6), 0, 0,
        Keyword.get(opts, :interlace, 0)>>

    <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 13::32, "IHDR", ihdr::binary,
      :erlang.crc32(["IHDR", ihdr])::32, 0::32, "IEND", 0xAE426082::32>>
  end

  @doc "A JPEG with an APP0 segment, a frame header and an EOI."
  @spec jpeg(non_neg_integer(), non_neg_integer(), keyword()) :: binary()
  def jpeg(w, h, opts \\ []) do
    sof = Keyword.get(opts, :sof, 0xC0)
    app0 = <<"JFIF", 0, 1, 1, 0, 0, 1, 0, 1, 0, 0>>

    <<0xFF, 0xD8, 0xFF, 0xE0, byte_size(app0) + 2::16, app0::binary, 0xFF, sof, 17::16, 8, h::16,
      w::16, 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1, 0xFF, 0xDA, 12::16, 3, 1, 0, 2, 0x11, 3, 0x11,
      0, 63, 0, 0x12, 0x34, Keyword.get(opts, :eoi, <<0xFF, 0xD9>>)::binary>>
  end

  @doc "A minimal valid `.milk` body."
  @spec milk(String.t()) :: binary()
  def milk(extra \\ "") do
    "[preset00]\r\nfRating=3.000000\r\nzoom=1.010000\r\n" <> extra
  end
end
