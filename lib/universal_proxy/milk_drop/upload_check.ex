defmodule UniversalProxy.MilkDrop.UploadCheck do
  @moduledoc """
  Pure checks for uploaded MilkDrop presets and textures: names, `.milk`
  content and texture headers. Nothing here touches the filesystem.

  ## Names (`normalise_name/1`)

  Uploads are stored flat under a basename (a zip's folders are dropped by
  the caller), so a name is one path segment. It is normalised the way the
  pack pipeline normalises ids (`tools/milkdrop_pack/milkpack/names.py`:
  runs of spaces become one, the stem is trimmed, the extension is
  lowercased, so `"My  Preset .MILK"` becomes `"My Preset.milk"`), except
  that non-ASCII letters are kept, NFC-normalised, rather than folded to
  ASCII. The result must then:

    * be valid UTF-8 (anything else is `{:error, :invalid_name}`);
    * use only Unicode letters, decimal digits, space and
      `- _ . , ( ) [ ] & ' + ! # @ $ % = ~ ;` — so no `/ \\ : * ? " < > |`,
      no control or format characters (bidi overrides, zero-width,
      BOM) and no combining marks NFC can't compose;
    * not start or end with a space or dot in the stem, nor contain `..`;
    * be 1..200 bytes with its extension;
    * end in `.milk` (a preset) or `.jpg`/`.jpeg`/`.png` (a texture).

  That is stricter than the renderer's `valid_preset_file`
  (`c_src/milkdrop_renderer/src/manifest.cpp`), so `preset_id/1` of any
  accepted name is a valid renderer id in the reserved `user/` namespace.

  Duplicates are compared by `fold/1` (NFC + lowercase). projectM looks
  textures up by lowercase stem, so texture duplicates compare by
  `texture_key/1` (`a.png` and `A.JPG` collide).

  ## Presets (`check_preset/1`)

  A mirror of the basics of projectM's `PresetFileParser`: at most 256 KiB
  (`:too_large`), no NUL (`:nul_byte`), no C0 control byte other than tab,
  LF and CR (`:control_char`), at most 20,000 lines (`:too_many_lines`)
  of at most 64 KiB each (`:line_too_long`), and at least one `key=value`
  line, i.e. one whose first space or `=` is an `=` after a non-empty key
  (`:no_values`). projectM reads the file as bytes and only the name is
  required to be UTF-8, so content is accepted as UTF-8 or Latin-1/CP1252
  alike (every byte sequence that passes the checks above is valid
  Latin-1) and stored unchanged — its SHA-256 then matches the user's
  file. Preset code is not parsed or "sanitised" here.

  ## Textures (`check_texture/2`)

  At most 4 MiB (`:too_large`). The magic bytes must match the extension
  (`:bad_magic`) and the header must parse (`:bad_header`); dimensions are
  read from the PNG `IHDR` or the first JPEG `SOFn` and must be 1..2048
  per side and at most 2048 × 2048 pixels (`{:dimensions, w, h}`). PNG
  chunks must all be present up to `IEND` with matching CRCs
  (`:bad_header`), and the `IDAT` stream must inflate to exactly the raw
  size the header implies (`:bad_image`) — checked in bounded chunks, so
  a decompression bomb never reaches stb_image.
  Interlaced PNGs (`:interlaced`) and anything but baseline or extended
  sequential Huffman JPEGs (`:unsupported_jpeg`) are refused: stb_image
  picks its decoder by content, so this keeps uploads on the common
  decoder paths. Stems that projectM reserves for built-in samplers
  (`main`, `blur1`, `noise_lq`, `idlem`, …, also behind any `XY_` prefix,
  which projectM strips before lookup) are reported by
  `texture_reserved?/1`.
  """

  @max_name_bytes 200
  @max_preset_bytes 256 * 1024
  @max_texture_bytes 4 * 1024 * 1024
  @max_line_bytes 64 * 1024
  @max_lines 20_000
  @max_side 2048
  @max_pixels 2048 * 2048

  @preset_exts ~w(.milk)
  @texture_exts ~w(.jpg .jpeg .png)
  @name_re ~r/\A[\p{L}\p{Nd} \-_.,()\[\]&'+!#@$%=~;]+\z/u
  @control_re ~r/[\x01-\x08\x0b\x0c\x0e-\x1f]/

  # projectM's TextureManager preloads `idlem`, `idleheadphones` and the
  # noise textures; `main` and `blur1..3` are the render targets.
  @builtin_textures ~w(main blur1 blur2 blur3 noise_lq noise_lq_lite noise_mq noise_hq
                       noisevol_lq noisevol_hq idlem idleheadphones)

  @png_sig <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>
  @png_channels %{0 => 1, 2 => 3, 3 => 1, 4 => 2, 6 => 4}
  # Legal bit depths per colour type (PNG spec, IHDR).
  @png_depths %{
    0 => [1, 2, 4, 8, 16],
    2 => [8, 16],
    3 => [1, 2, 4, 8],
    4 => [8, 16],
    6 => [8, 16]
  }
  # SOF0 (baseline) and SOF1 (extended sequential, Huffman).
  @jpeg_ok_sof [0xC0, 0xC1]
  # Every other SOFn: progressive, lossless, arithmetic, hierarchical.
  # 0xC4 (DHT), 0xC8 (JPG) and 0xCC (DAC) are not frame markers.
  @jpeg_other_sof [0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF]

  @type kind :: :preset | :texture | :other
  @type texture_info :: %{format: :png | :jpeg, width: pos_integer(), height: pos_integer()}

  @doc "The largest accepted `.milk` file, in bytes."
  @spec max_preset_bytes() :: pos_integer()
  def max_preset_bytes, do: @max_preset_bytes

  @doc "The largest accepted texture file, in bytes."
  @spec max_texture_bytes() :: pos_integer()
  def max_texture_bytes, do: @max_texture_bytes

  @doc "What a file is, by its (case-insensitive) extension."
  @spec kind(String.t()) :: kind()
  def kind(name) do
    ext = name |> Path.extname() |> String.downcase()

    cond do
      ext in @preset_exts -> :preset
      ext in @texture_exts -> :texture
      true -> :other
    end
  end

  @doc "Normalise and validate an upload's basename (see the moduledoc)."
  @spec normalise_name(binary()) :: {:ok, String.t()} | {:error, :invalid_name}
  def normalise_name(name) when is_binary(name) do
    with true <- String.valid?(name),
         nfc when is_binary(nfc) <- :unicode.characters_to_nfc_binary(name),
         ext = nfc |> Path.extname() |> String.downcase(),
         true <- ext in @preset_exts or ext in @texture_exts,
         stem = nfc |> binary_part(0, byte_size(nfc) - byte_size(ext)) |> squash_spaces(),
         normalised = stem <> ext,
         true <- valid_stem?(stem) and byte_size(normalised) <= @max_name_bytes do
      {:ok, normalised}
    else
      _ -> {:error, :invalid_name}
    end
  end

  @doc "The renderer id of an accepted preset name: `user/<name>`."
  @spec preset_id(String.t()) :: String.t()
  def preset_id(name), do: "user/" <> name

  @doc "The duplicate-comparison key of a name: NFC, lowercased."
  @spec fold(String.t()) :: String.t()
  def fold(name) do
    name |> nfc() |> String.downcase() |> nfc()
  end

  @doc "The key projectM looks a texture up by: its folded stem."
  @spec texture_key(String.t()) :: String.t()
  def texture_key(name), do: name |> Path.rootname() |> fold()

  @doc "Whether a texture name shadows one of projectM's built-in samplers."
  @spec texture_reserved?(String.t()) :: boolean()
  def texture_reserved?(name) do
    key = texture_key(name)
    key in @builtin_textures or unprefixed(key) in @builtin_textures
  end

  @doc """
  A display-safe rendering of an untrusted name: invalid UTF-8 and
  control or format characters become `?`, cut to 200 bytes on a
  character boundary.
  """
  @spec printable(binary()) :: String.t()
  def printable(name) when is_binary(name) do
    name
    |> String.replace_invalid("?")
    |> String.replace(~r/[\p{Cc}\p{Cf}]/u, "?")
    |> truncate(@max_name_bytes)
  end

  @doc "Validate a `.milk` file's content (see the moduledoc)."
  @spec check_preset(binary()) ::
          :ok
          | {:error,
             :too_large
             | :nul_byte
             | :control_char
             | :too_many_lines
             | :line_too_long
             | :no_values}
  def check_preset(data) when byte_size(data) > @max_preset_bytes, do: {:error, :too_large}

  def check_preset(data) do
    lines = :binary.split(data, ["\r\n", "\n", "\r"], [:global])

    cond do
      :binary.match(data, <<0>>) != :nomatch -> {:error, :nul_byte}
      Regex.match?(@control_re, data) -> {:error, :control_char}
      length(lines) > @max_lines -> {:error, :too_many_lines}
      Enum.any?(lines, &(byte_size(&1) > @max_line_bytes)) -> {:error, :line_too_long}
      not Enum.any?(lines, &key_value_line?/1) -> {:error, :no_values}
      true -> :ok
    end
  end

  @doc """
  Validate a texture's content against its (already normalised) name.
  Returns its format and dimensions.
  """
  @spec check_texture(String.t(), binary()) ::
          {:ok, texture_info()}
          | {:error,
             :too_large
             | :bad_magic
             | :bad_header
             | :bad_image
             | :interlaced
             | :unsupported_jpeg
             | {:dimensions, non_neg_integer(), non_neg_integer()}}
  def check_texture(_name, data) when byte_size(data) > @max_texture_bytes,
    do: {:error, :too_large}

  def check_texture(name, data) do
    result =
      case name |> Path.extname() |> String.downcase() do
        ".png" -> png(data)
        ext when ext in [".jpg", ".jpeg"] -> jpeg(data)
        _ -> {:error, :bad_magic}
      end

    with {:ok, %{width: w, height: h}} <- result,
         :ok <- check_dimensions(w, h) do
      result
    end
  end

  # -- Private: names --

  # TextureManager::ExtractTextureSettings: a name longer than three bytes
  # whose third byte is `_` loses its first three bytes (`fc_`, `cf_`, any
  # `XY_`) before lookup.
  defp unprefixed(<<_, _, "_", rest::binary>>) when rest != "", do: rest
  defp unprefixed(_key), do: nil

  defp squash_spaces(stem), do: stem |> String.split(" ", trim: true) |> Enum.join(" ")

  defp valid_stem?(stem) do
    stem != "" and Regex.match?(@name_re, stem) and not String.starts_with?(stem, ".") and
      not String.ends_with?(stem, ".") and not String.contains?(stem, "..")
  end

  defp nfc(name) do
    case :unicode.characters_to_nfc_binary(name) do
      bin when is_binary(bin) -> bin
      _ -> name
    end
  end

  defp truncate(name, max) when byte_size(name) <= max, do: name

  defp truncate(name, max) do
    name
    |> String.graphemes()
    |> Enum.reduce_while({"", 0}, fn g, {acc, size} ->
      if size + byte_size(g) > max,
        do: {:halt, {acc, size}},
        else: {:cont, {acc <> g, size + byte_size(g)}}
    end)
    |> elem(0)
  end

  # -- Private: presets --

  # projectM's ParseLine: the key ends at the first space or "=".
  defp key_value_line?(line) do
    case :binary.match(line, [" ", "="]) do
      {pos, 1} when pos > 0 -> binary_part(line, pos, 1) == "="
      _ -> false
    end
  end

  # -- Private: textures --

  defp check_dimensions(w, h) do
    if w in 1..@max_side and h in 1..@max_side and w * h <= @max_pixels,
      do: :ok,
      else: {:error, {:dimensions, w, h}}
  end

  defp png(<<@png_sig, 13::32, "IHDR", ihdr::binary-13, crc::32, chunks::binary>>) do
    <<w::32, h::32, depth, color, compression, filter, interlace>> = ihdr

    cond do
      crc != :erlang.crc32(["IHDR", ihdr]) ->
        {:error, :bad_header}

      depth not in Map.get(@png_depths, color, []) or compression != 0 or filter != 0 or
          interlace not in [0, 1] ->
        {:error, :bad_header}

      interlace == 1 ->
        {:error, :interlaced}

      true ->
        # Dimensions first: they bound the inflated size checked below.
        with :ok <- check_dimensions(w, h),
             {:ok, idat} <- png_chunks(chunks, []),
             :ok <- png_inflate(idat, png_raw_size(w, h, depth, color)) do
          {:ok, %{format: :png, width: w, height: h}}
        end
    end
  end

  defp png(<<@png_sig, _::binary>>), do: {:error, :bad_header}
  defp png(_), do: {:error, :bad_magic}

  # The chunks after IHDR, up to IEND: every CRC must match, nothing may
  # run past the end, and a second IHDR is malformed. Returns the IDAT
  # payloads (sub-binaries) in order.
  defp png_chunks(<<len::32, type::binary-4, rest::binary>>, idat) do
    case rest do
      <<data::binary-size(^len), crc::32, rest::binary>> ->
        cond do
          crc != :erlang.crc32([type, data]) -> {:error, :bad_header}
          type == "IHDR" -> {:error, :bad_header}
          type == "IEND" and idat == [] -> {:error, :bad_image}
          type == "IEND" -> {:ok, Enum.reverse(idat)}
          type == "IDAT" -> png_chunks(rest, [data | idat])
          true -> png_chunks(rest, idat)
        end

      _ ->
        {:error, :bad_header}
    end
  end

  defp png_chunks(_truncated, _idat), do: {:error, :bad_header}

  # Filtered scanlines of a non-interlaced image: one filter byte plus the
  # packed row, per row.
  defp png_raw_size(w, h, depth, color),
    do: h * (1 + div(w * Map.fetch!(@png_channels, color) * depth + 7, 8))

  # stb_image inflates the whole IDAT stream into a growing buffer, so a
  # tiny image can carry a decompression bomb: inflate it ourselves in
  # bounded chunks, counting (and discarding) the output, and require
  # exactly the raw size the header implies.
  defp png_inflate(idat, expected) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z)
      count = Enum.reduce(idat, 0, &png_drain(z, :zlib.safeInflate(z, &1), &2, expected))
      :ok = :zlib.inflateEnd(z)
      if count == expected, do: :ok, else: {:error, :bad_image}
    rescue
      ErlangError -> {:error, :bad_image}
    catch
      :too_big -> {:error, :bad_image}
    after
      :zlib.close(z)
    end
  end

  defp png_drain(z, {status, output}, count, expected) do
    count = count + IO.iodata_length(output)
    if count > expected, do: throw(:too_big)

    case status do
      :continue -> png_drain(z, :zlib.safeInflate(z, []), count, expected)
      :finished -> count
    end
  end

  defp png_drain(_z, {:need_dictionary, _adler, _output}, _count, _expected),
    do: throw(:too_big)

  defp jpeg(<<0xFF, 0xD8, 0xFF, _::binary>> = data) do
    <<_soi::binary-2, rest::binary>> = data
    jpeg_markers(rest)
  end

  defp jpeg(_), do: {:error, :bad_magic}

  # Walk the marker segments up to the first frame header. Each step
  # consumes at least two bytes, so this ends on any input.
  # A fill byte: drop it as a sub-binary (no copy) and look again.
  defp jpeg_markers(<<0xFF, 0xFF, _::binary>> = data),
    do: jpeg_markers(binary_part(data, 1, byte_size(data) - 1))

  defp jpeg_markers(<<0xFF, m, rest::binary>>) when m in 0xD0..0xD7 or m == 0x01,
    do: jpeg_markers(rest)

  # A second SOI, the end of the image or scan data before any frame header.
  defp jpeg_markers(<<0xFF, m, _::binary>>) when m in [0xD8, 0xD9, 0xDA],
    do: {:error, :bad_header}

  defp jpeg_markers(<<0xFF, m, len::16, rest::binary>>) when len >= 2 do
    body_len = len - 2

    case rest do
      <<body::binary-size(^body_len), after_segment::binary>> ->
        jpeg_segment(m, body, after_segment)

      _ ->
        {:error, :bad_header}
    end
  end

  defp jpeg_markers(_), do: {:error, :bad_header}

  # The body is exactly the segment (length 8 + 3 × Nf) minus its length
  # field: precision (8 bits: all stb_image decodes), height, width, Nf
  # (1, 3 or 4: what stb_image decodes), then Nf component specs (distinct
  # ids, sampling factors 1..4 each, table selector 0..3).
  defp jpeg_segment(m, <<8, h::16, w::16, nf, specs::binary>>, rest)
       when m in @jpeg_ok_sof and nf in [1, 3, 4] and byte_size(specs) == 3 * nf do
    if components_ok?(specs) and :binary.match(rest, <<0xFF, 0xD9>>) != :nomatch,
      do: {:ok, %{format: :jpeg, width: w, height: h}},
      else: {:error, :bad_header}
  end

  defp jpeg_segment(m, _body, _rest) when m in @jpeg_ok_sof, do: {:error, :bad_header}
  defp jpeg_segment(m, _body, _rest) when m in @jpeg_other_sof, do: {:error, :unsupported_jpeg}
  defp jpeg_segment(_m, _body, rest), do: jpeg_markers(rest)

  defp components_ok?(specs) do
    components = for <<id, hs::4, vs::4, tq <- specs>>, do: {id, hs, vs, tq}

    Enum.all?(components, fn {_id, hs, vs, tq} -> hs in 1..4 and vs in 1..4 and tq in 0..3 end) and
      components |> Enum.uniq_by(&elem(&1, 0)) |> length() == length(components)
  end
end
