defmodule UniversalProxy.MilkDrop.Zip do
  @moduledoc """
  A deliberately small, strict reader for untrusted `.zip` uploads.

  OTP's `:zip` is unsuitable here: it doesn't bound real inflation, it
  rewrites `..` paths instead of rejecting them, and it extracts under the
  local-header name. This reader:

    * finds the End Of Central Directory record (searching back over at
      most the maximum comment length) and reads the central directory
      first — local headers are never trusted for the entry list;
    * rejects the whole archive (`open/2` returns `{:error, reason}`) unless
      every entry passes every check below;
    * never writes anything: `read/2` returns an entry's bytes, and the
      caller decides where they go.

  ## Checks in `open/2`

    * one disk only (`:multi_disk`), no ZIP64 (`:zip64`: the 0xFFFF /
      0xFFFFFFFF sentinels, a ZIP64 EOCD locator or a `0x0001` extra
      field), the central directory exactly fills the space before the
      EOCD and the EOCD comment runs to the end of the file
      (`:not_a_zip` / `:bad_central_directory`), and the first entry
      starts the file (`:leading_data`: no prepended or SFX data);
    * at most `:max_entries` (256) entries, directories included
      (`:too_many_entries`);
    * per entry, `{reason, name}` with a display-safe `name`
      (`UploadCheck.printable/1`):
      * `:encrypted` — general-purpose flag bit 0, 6 or 13;
      * `:unsupported_method` — anything but stored (0) or deflate (8);
      * `:name_encoding` — the name isn't UTF-8 (bit 11 set or not: zips
        without it are UTF-8 in practice on macOS/Linux, and CP437 names
        with non-ASCII bytes are rejected rather than guessed at);
      * `:unsafe_path` — empty, absolute, a backslash, a `:` (drive
        letters), a control byte, or a `.`, `..` or empty segment. Paths
        are rejected, never rewritten;
      * `:not_regular_file` — the Unix file type in the external
        attributes is neither regular nor directory (symlinks, devices,
        FIFOs), or contradicts the trailing `/`; type 0 (DOS) is allowed;
      * `:bad_sizes` — a stored entry whose sizes differ, a deflated one
        more than 1 KiB larger than its content, or a directory with
        content;
      * `:ratio` — a deflated entry declaring more than 200× its
        compressed size (+ 1 KiB);
      * `:duplicate` — two files whose paths are equal ignoring case and
        Unicode normalisation (NFC/NFD);
      * `:bad_local_header` / `:header_mismatch` — the local header is
        missing or its name (byte for byte), flags, method, CRC or sizes
        differ from the central directory;
      * `:overlap` — the entry's data runs into the next entry or into
        the central directory;
    * the declared uncompressed sizes sum to at most `:max_total`
      (32 MiB, `:too_large`).

  Data descriptors (flag bit 3) are accepted: the central directory's CRC
  and sizes are authoritative, the local header's may then be zero, and the
  descriptor itself is never read.

  ## Reading

  `read/2` inflates raw deflate with `:zlib.safeInflate/2` in bounded
  chunks and aborts as soon as the output passes the declared size;
  output shorter than declared is also an error (`{:size_mismatch,
  name}`), as are a CRC mismatch (`{:crc_mismatch, name}`) and a corrupt
  stream (`{:corrupt, name}`). Since each entry yields exactly its
  declared size, the archive yields at most `:max_total` bytes in all.

  Sources are a file path (read with `:file.pread/3`, never loaded whole)
  or `{:binary, data}`.
  """

  import Bitwise

  alias UniversalProxy.MilkDrop.UploadCheck

  defmodule Entry do
    @moduledoc "One central-directory entry (see `UniversalProxy.MilkDrop.Zip`)."

    @enforce_keys [:name, :dir?, :method, :size, :compressed_size, :crc32, :data_offset]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            name: String.t(),
            dir?: boolean(),
            method: :stored | :deflate,
            size: non_neg_integer(),
            compressed_size: non_neg_integer(),
            crc32: non_neg_integer(),
            data_offset: non_neg_integer()
          }
  end

  @enforce_keys [:source, :entries]
  defstruct @enforce_keys

  @opaque source :: {:file, :file.io_device()} | {:binary, binary()}
  @type t :: %__MODULE__{source: source(), entries: [Entry.t()]}

  @type entry_reason ::
          :encrypted
          | :unsupported_method
          | :name_encoding
          | :unsafe_path
          | :not_regular_file
          | :bad_sizes
          | :ratio
          | :duplicate
          | :bad_local_header
          | :header_mismatch
          | :overlap
          | :size_mismatch
          | :crc_mismatch
          | :corrupt

  @type reason ::
          :not_a_zip
          | :bad_central_directory
          | :multi_disk
          | :zip64
          | :too_many_entries
          | :too_large
          | :leading_data
          | :truncated
          | {entry_reason(), String.t()}
          | {:io, File.posix()}

  @max_entries 256
  @max_total 32 * 1024 * 1024
  @max_ratio 200
  @slack 1024
  @chunk 65_536

  @eocd_sig <<"PK", 5, 6>>
  @eocd_size 22
  @max_comment 0xFFFF
  @zip64_locator_sig <<"PK", 6, 7>>
  @zip64_locator_size 20
  @cd_sig <<"PK", 1, 2>>
  @local_sig <<"PK", 3, 4>>

  @flag_encrypted 0x0001
  @flag_descriptor 0x0008
  @flag_strong_encryption 0x0040
  @flag_masked_headers 0x2000

  @s_ifmt 0o170000
  @s_ifreg 0o100000
  @s_ifdir 0o040000

  # -- Public API --

  @doc """
  Open and validate an archive. Options: `:max_entries` (256) and
  `:max_total` (32 MiB of declared uncompressed bytes). A file source
  stays open until `close/1`.
  """
  @spec open(Path.t() | {:binary, binary()}, keyword()) :: {:ok, t()} | {:error, reason()}
  def open(source, opts \\ [])

  def open({:binary, data}, opts) when is_binary(data), do: validate({:binary, data}, opts)

  def open(path, opts) when is_binary(path) do
    case :file.open(path, [:read, :raw, :binary]) do
      {:ok, fd} ->
        case validate({:file, fd}, opts) do
          {:ok, _} = ok ->
            ok

          error ->
            :ok = :file.close(fd)
            error
        end

      {:error, reason} ->
        {:error, {:io, reason}}
    end
  end

  @doc "Close the archive's file (a no-op for binaries)."
  @spec close(t()) :: :ok
  def close(%__MODULE__{source: {:file, fd}}) do
    _ = :file.close(fd)
    :ok
  end

  def close(%__MODULE__{}), do: :ok

  @doc "The validated entries, in central-directory order (directories included)."
  @spec entries(t()) :: [Entry.t()]
  def entries(%__MODULE__{entries: entries}), do: entries

  @doc """
  An entry's content: exactly `entry.size` bytes whose CRC-32 matches, or
  an error (see the moduledoc). Directories read as `""`.
  """
  @spec read(t(), Entry.t()) :: {:ok, binary()} | {:error, reason()}
  def read(%__MODULE__{}, %Entry{dir?: true}), do: {:ok, ""}

  def read(%__MODULE__{source: source}, %Entry{} = entry) do
    data =
      case entry.method do
        :stored -> pread!(source, entry.data_offset, entry.compressed_size)
        :deflate -> inflate!(source, entry)
      end

    cond do
      byte_size(data) != entry.size -> fail!({:size_mismatch, entry.name})
      :erlang.crc32(data) != entry.crc32 -> fail!({:crc_mismatch, entry.name})
      true -> {:ok, data}
    end
  catch
    {:zip_error, reason} -> {:error, reason}
  end

  # -- Private: validation --

  defp validate(source, opts) do
    max_entries = Keyword.get(opts, :max_entries, @max_entries)
    max_total = Keyword.get(opts, :max_total, @max_total)
    size = source_size!(source)

    {cd_offset, cd_size, count} = eocd!(source, size)
    if count > max_entries, do: fail!(:too_many_entries)
    # Bound the read by what `count` records can hold (each at most a
    # header plus three 16-bit-length fields), before reading it.
    if cd_size > count * (46 + 3 * 0xFFFF), do: fail!(:bad_central_directory)
    if count == 0 and cd_offset != 0, do: fail!(:leading_data)

    records = parse_cd!(pread!(source, cd_offset, cd_size), count, [])

    if Enum.sum_by(records, & &1.size) > max_total, do: fail!(:too_large)
    check_duplicates!(records)

    entries = Enum.map(records, &check_local!(source, &1, cd_offset))
    check_overlap!(records, entries)

    {:ok, %__MODULE__{source: source, entries: entries}}
  catch
    {:zip_error, reason} -> {:error, reason}
  end

  defp eocd!(source, size) do
    # Room for the longest comment, plus a ZIP64 locator in front of it.
    tail_len = min(size, @zip64_locator_size + @eocd_size + @max_comment)
    tail = pread!(source, size - tail_len, tail_len)
    pos = eocd_position(tail) || fail!(:not_a_zip)

    <<_::binary-size(^pos), _sig::binary-4, disk::little-16, cd_disk::little-16,
      on_disk::little-16, total::little-16, cd_size::little-32, cd_offset::little-32, _::binary>> =
      tail

    zip64_locator? =
      pos >= @zip64_locator_size and
        binary_part(tail, pos - @zip64_locator_size, 4) == @zip64_locator_sig

    cond do
      zip64_locator? or total == 0xFFFF or 0xFFFFFFFF in [cd_size, cd_offset] ->
        fail!(:zip64)

      disk != 0 or cd_disk != 0 or on_disk != total ->
        fail!(:multi_disk)

      cd_offset + cd_size != size - tail_len + pos ->
        fail!(:bad_central_directory)

      true ->
        {cd_offset, cd_size, total}
    end
  end

  # The last signature whose comment length runs exactly to the end.
  defp eocd_position(tail) do
    tail
    |> :binary.matches(@eocd_sig)
    |> Enum.map(&elem(&1, 0))
    |> Enum.reverse()
    |> Enum.find(fn pos ->
      match?(
        <<_::binary-size(^pos), _::binary-size(20), len::little-16, rest::binary>>
        when byte_size(rest) == len,
        tail
      )
    end)
  end

  defp parse_cd!(<<>>, 0, acc), do: Enum.reverse(acc)

  defp parse_cd!(
         <<@cd_sig, _made_by::little-16, _needed::little-16, flags::little-16, method::little-16,
           _time::little-16, _date::little-16, crc::little-32, csize::little-32, usize::little-32,
           name_len::little-16, extra_len::little-16, comment_len::little-16,
           disk_start::little-16, _int_attr::little-16, ext_attr::little-32, offset::little-32,
           name::binary-size(name_len), extra::binary-size(extra_len),
           _comment::binary-size(comment_len), rest::binary>>,
         count,
         acc
       )
       when count > 0 do
    raw = %{
      raw_name: name,
      flags: flags,
      method: method,
      crc32: crc,
      compressed_size: csize,
      size: usize,
      offset: offset,
      ext_attr: ext_attr
    }

    if disk_start != 0, do: fail!(:multi_disk)
    if zip64_extra?(extra) or 0xFFFFFFFF in [csize, usize, offset], do: fail!(:zip64)

    parse_cd!(rest, count - 1, [check_record!(raw) | acc])
  end

  defp parse_cd!(_cd, _count, _acc), do: fail!(:bad_central_directory)

  defp check_record!(raw) do
    name = decode_name!(raw.raw_name)
    dir? = String.ends_with?(name, "/")

    cond do
      (raw.flags &&& (@flag_encrypted ||| @flag_strong_encryption ||| @flag_masked_headers)) !=
          0 ->
        fail!({:encrypted, name})

      raw.method not in [0, 8] ->
        fail!({:unsupported_method, name})

      not safe_path?(name, dir?) ->
        fail!({:unsafe_path, name})

      not file_type_ok?(raw.ext_attr, dir?) ->
        fail!({:not_regular_file, name})

      not sizes_ok?(raw, dir?) ->
        fail!({:bad_sizes, name})

      raw.method == 8 and raw.size > @max_ratio * raw.compressed_size + @slack ->
        fail!({:ratio, name})

      true ->
        Map.merge(raw, %{name: name, dir?: dir?})
    end
  end

  defp decode_name!(raw) do
    if String.valid?(raw),
      do: raw,
      else: fail!({:name_encoding, UploadCheck.printable(raw)})
  end

  defp safe_path?(name, dir?) do
    path = if dir?, do: binary_part(name, 0, byte_size(name) - 1), else: name

    path != "" and not String.contains?(path, ["\\", ":"]) and
      not String.match?(path, ~r/[\x00-\x1f\x7f]/) and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))
  end

  # The high 16 bits of the external attributes hold a Unix st_mode when
  # the archiver set one; 0 means none (DOS-made archives).
  defp file_type_ok?(ext_attr, dir?) do
    case ext_attr >>> 16 &&& @s_ifmt do
      0 -> true
      @s_ifdir -> dir?
      @s_ifreg -> not dir?
      _ -> false
    end
  end

  defp sizes_ok?(%{size: size}, true), do: size == 0
  defp sizes_ok?(%{method: 0} = raw, false), do: raw.compressed_size == raw.size
  defp sizes_ok?(raw, false), do: raw.compressed_size <= raw.size + @slack

  defp check_duplicates!(records) do
    Enum.reduce(records, MapSet.new(), fn
      %{dir?: true}, seen ->
        seen

      %{name: name}, seen ->
        key = UploadCheck.fold(name)
        if MapSet.member?(seen, key), do: fail!({:duplicate, name})
        MapSet.put(seen, key)
    end)
  end

  defp zip64_extra?(<<id::little-16, len::little-16, _::binary-size(len), rest::binary>>),
    do: id == 0x0001 or zip64_extra?(rest)

  defp zip64_extra?(<<>>), do: false
  defp zip64_extra?(_malformed), do: fail!(:bad_central_directory)

  defp check_local!(source, rec, cd_offset) do
    if rec.offset + 30 > cd_offset, do: fail!({:overlap, rec.name})

    <<sig::binary-4, _needed::little-16, flags::little-16, method::little-16, _time::little-16,
      _date::little-16, crc::little-32, csize::little-32, usize::little-32, name_len::little-16,
      extra_len::little-16>> = pread!(source, rec.offset, 30)

    if sig != @local_sig, do: fail!({:bad_local_header, rec.name})

    data_offset = rec.offset + 30 + name_len + extra_len
    if data_offset + rec.compressed_size > cd_offset, do: fail!({:overlap, rec.name})

    name = pread!(source, rec.offset + 30, name_len)
    extra = pread!(source, rec.offset + 30 + name_len, extra_len)
    if zip64_extra?(extra), do: fail!(:zip64)

    consistent? =
      name == rec.raw_name and flags == rec.flags and method == rec.method and
        local_value_ok?(crc, rec.crc32, flags) and
        local_value_ok?(csize, rec.compressed_size, flags) and
        local_value_ok?(usize, rec.size, flags)

    unless consistent?, do: fail!({:header_mismatch, rec.name})

    %Entry{
      name: rec.name,
      dir?: rec.dir?,
      method: if(rec.method == 0, do: :stored, else: :deflate),
      size: rec.size,
      compressed_size: rec.compressed_size,
      crc32: rec.crc32,
      data_offset: data_offset
    }
  end

  # With a data descriptor the local CRC and sizes may be zero.
  defp local_value_ok?(local, central, flags),
    do: local == central or ((flags &&& @flag_descriptor) != 0 and local == 0)

  defp check_overlap!(records, entries) do
    records
    |> Enum.zip(entries)
    |> Enum.map(fn {rec, entry} ->
      {rec.offset, entry.data_offset + entry.compressed_size, entry.name}
    end)
    |> Enum.sort()
    |> tap(fn
      # The first entry starts the file: no prepended (SFX) data.
      [{start, _stop, _name} | _] when start != 0 -> fail!(:leading_data)
      _ -> :ok
    end)
    |> Enum.reduce(0, fn {start, stop, name}, prev_stop ->
      if start < prev_stop, do: fail!({:overlap, name})
      stop
    end)
    |> then(fn _end -> :ok end)
  end

  # -- Private: inflate --

  defp inflate!(source, entry) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, -15)
      acc = inflate_chunks!(z, source, entry, entry.data_offset, entry.compressed_size, {[], 0})
      :ok = :zlib.inflateEnd(z)
      acc |> elem(0) |> Enum.reverse() |> IO.iodata_to_binary()
    rescue
      ErlangError -> fail!({:corrupt, entry.name})
    after
      :zlib.close(z)
    end
  end

  defp inflate_chunks!(_z, _source, _entry, _offset, 0, acc), do: acc

  defp inflate_chunks!(z, source, entry, offset, left, acc) do
    len = min(left, @chunk)
    input = pread!(source, offset, len)
    acc = drain!(z, :zlib.safeInflate(z, input), entry, acc)
    inflate_chunks!(z, source, entry, offset + len, left - len, acc)
  end

  defp drain!(z, {status, output}, entry, {chunks, count}) do
    count = count + IO.iodata_length(output)
    if count > entry.size, do: fail!({:size_mismatch, entry.name})
    acc = {[output | chunks], count}

    case status do
      :continue -> drain!(z, :zlib.safeInflate(z, []), entry, acc)
      :finished -> acc
    end
  end

  # Raw deflate never asks for a preset dictionary.
  defp drain!(_z, {:need_dictionary, _adler, _output}, entry, _acc),
    do: fail!({:corrupt, entry.name})

  # -- Private: sources --

  defp source_size!({:binary, data}), do: byte_size(data)

  defp source_size!({:file, fd}) do
    case :file.position(fd, :eof) do
      {:ok, size} -> size
      {:error, reason} -> fail!({:io, reason})
    end
  end

  defp pread!(_source, _offset, 0), do: <<>>

  defp pread!({:binary, data}, offset, len) do
    if offset >= 0 and offset + len <= byte_size(data),
      do: binary_part(data, offset, len),
      else: fail!(:truncated)
  end

  defp pread!({:file, fd}, offset, len) do
    case :file.pread(fd, offset, len) do
      {:ok, data} when byte_size(data) == len -> data
      {:ok, _short} -> fail!(:truncated)
      :eof -> fail!(:truncated)
      {:error, reason} -> fail!({:io, reason})
    end
  end

  defp fail!({reason, name}) when is_atom(reason) and is_binary(name),
    do: throw({:zip_error, {reason, UploadCheck.printable(name)}})

  defp fail!(reason), do: throw({:zip_error, reason})
end
