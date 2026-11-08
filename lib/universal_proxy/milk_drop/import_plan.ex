defmodule UniversalProxy.MilkDrop.ImportPlan do
  @moduledoc """
  Plans an import of uploaded presets without touching the disk: given the
  uploads (single `.milk` files or `.zip` archives) and what is already
  installed, it reads and validates every candidate and returns one result
  per file, carrying the bytes to write for those that change something.
  Writing them, quota and free-space checks and the user manifest are the
  caller's job.

  ## Uploads

  An upload is `{client_name, source}`, where `source` is a path or
  `{:binary, data}` and `client_name` (the browser's file name) picks the
  kind: `.milk`, `.zip`, or anything else (`{:rejected,
  :unsupported_file}`).

    * A `.milk` upload is stored under its normalised client name
      (`UniversalProxy.MilkDrop.UploadCheck.normalise_name/1`).
    * A `.zip` is opened with `UniversalProxy.MilkDrop.Zip`; a structural
      failure rejects the whole archive in one `kind: :archive` result.
      Entries are flattened: each file is stored under its normalised
      basename, whatever folder it sits in (so a zip folder can never
      reach the pack's `high_frequency/` id space). Directory entries and
      well-known junk (`__MACOSX/`, `._*`, `.DS_Store`, `Thumbs.db`,
      `desktop.ini`) are skipped without a result; files that are neither
      presets nor textures are `:ignored`. An entry is inflated only after
      its name, declared size and the archive's texture count (at most 64)
      pass; a read failure (CRC, a size lie, a corrupt stream) means the
      archive is hostile or damaged and rejects all of it.

  Within one plan the first occurrence of a name wins and later ones are
  `{:rejected, :duplicate_name}` (presets compare by
  `UploadCheck.fold/1`, textures by `UploadCheck.texture_key/1`, i.e. by
  stem as projectM looks them up). Only accepted files claim a name.

  ## Results

  Each result is a map:

    * `:upload` — the client file name (display-safe);
    * `:entry` — the path inside the zip, or `nil`;
    * `:kind` — `:preset`, `:texture`, `:archive` or `:other`;
    * `:name` — the stored basename, `:id` — `user/<name>` for presets;
    * `:status` — `:added`, `:replaced` (an installed file with the same
      folded name has different content; `:replaces` names it, which may
      differ in case or, for a texture, extension), `:unchanged` (same
      content: nothing to write), `:ignored` or `{:rejected, reason}`;
    * `:sha256` (lowercase hex) and `:size` of accepted files;
    * `:warnings` — `[:texture_shadowed]` when a pack texture with the
      same stem exists: the pack's wins in the renderer's lookup;
    * `:data` — the bytes to write for `:added`/`:replaced`, else `nil`.

  Rejection reasons are the `UploadCheck` and `Zip` errors plus
  `:unsupported_file`, `:invalid_name`, `:duplicate_name`,
  `:reserved_name` and `:too_many_textures`.

  At most one archive's accepted content (≤ 32 MiB, `Zip`'s total cap) is
  held per `add/3` call; callers with many uploads should write each
  call's results before the next.
  """

  alias UniversalProxy.MilkDrop.UploadCheck
  alias UniversalProxy.MilkDrop.Zip

  @max_textures_per_archive 64
  @junk_names ~w(.ds_store thumbs.db desktop.ini)

  @type source :: Path.t() | {:binary, binary()}
  @type upload :: {String.t(), source()}

  @type existing :: %{
          optional(:presets) => %{String.t() => String.t()},
          optional(:textures) => %{String.t() => String.t()},
          optional(:pack_textures) => [String.t()]
        }

  @type status :: :added | :replaced | :unchanged | :ignored | {:rejected, term()}

  @type result :: %{
          upload: String.t(),
          entry: String.t() | nil,
          kind: :preset | :texture | :archive | :other,
          name: String.t() | nil,
          id: String.t() | nil,
          status: status(),
          replaces: String.t() | nil,
          sha256: String.t() | nil,
          size: non_neg_integer() | nil,
          warnings: [:texture_shadowed],
          data: binary() | nil
        }

  @enforce_keys [:presets, :textures, :pack_textures, :claimed]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{
            presets: %{String.t() => {String.t(), String.t()}},
            textures: %{String.t() => {String.t(), String.t()}},
            pack_textures: MapSet.t(String.t()),
            claimed: MapSet.t({:preset | :texture, String.t()})
          }

  @doc """
  A plan over what is installed: `:presets` and `:textures` map stored
  user names to their SHA-256 (lowercase hex); `:pack_textures` lists the
  pack's texture file names.
  """
  @spec new(existing()) :: t()
  def new(existing \\ %{}) do
    %__MODULE__{
      presets: index(Map.get(existing, :presets, %{}), &UploadCheck.fold/1),
      textures: index(Map.get(existing, :textures, %{}), &UploadCheck.texture_key/1),
      pack_textures:
        existing |> Map.get(:pack_textures, []) |> MapSet.new(&UploadCheck.texture_key/1),
      claimed: MapSet.new()
    }
  end

  @doc "Plan every upload; see the moduledoc for memory use."
  @spec plan([upload()], existing()) :: [result()]
  def plan(uploads, existing \\ %{}) do
    {results, _plan} =
      Enum.flat_map_reduce(uploads, new(existing), fn {name, source}, plan ->
        add(plan, name, source)
      end)

    results
  end

  @doc """
  Plan one upload. Returns its results and the plan updated with the names
  it claimed, so a later upload of the same name is a duplicate.
  """
  @spec add(t(), String.t(), source()) :: {[result()], t()}
  def add(%__MODULE__{} = plan, client_name, source) do
    upload = UploadCheck.printable(client_name)

    case client_name |> Path.extname() |> String.downcase() do
      ".milk" -> add_milk(plan, upload, client_name, source)
      ".zip" -> add_zip(plan, upload, source)
      _ -> {[result(upload, nil, :other, status: {:rejected, :unsupported_file})], plan}
    end
  end

  # -- Private: uploads --

  defp add_milk(plan, upload, client_name, source) do
    base = result(upload, nil, :preset)

    with {:ok, name} <- UploadCheck.normalise_name(client_name),
         {:ok, data} <- read_source(source, UploadCheck.max_preset_bytes()) do
      accept(plan, %{base | name: name}, data)
    else
      {:error, reason} -> {[%{base | status: {:rejected, reason}}], plan}
    end
  end

  defp add_zip(plan, upload, source) do
    case Zip.open(source) do
      {:ok, zip} ->
        try do
          zip
          |> Zip.entries()
          |> Enum.reject(&skip_entry?/1)
          |> Enum.reduce({[], plan, 0}, &add_entry(zip, upload, &1, &2))
          |> then(fn {results, plan, _textures} -> {Enum.reverse(results), plan} end)
        catch
          {:archive_rejected, reason} ->
            {[result(upload, nil, :archive, status: {:rejected, reason})], plan}
        after
          Zip.close(zip)
        end

      {:error, reason} ->
        {[result(upload, nil, :archive, status: {:rejected, reason})], plan}
    end
  end

  defp add_entry(zip, upload, entry, {results, plan, textures}) do
    kind = UploadCheck.kind(entry.name)
    base = result(upload, entry.name, kind)

    case entry_check(kind, entry, plan, textures) do
      {:ok, name} ->
        data = read_entry!(zip, entry)
        {new_results, plan} = accept(plan, %{base | name: name}, data)
        accepted? = match?([%{sha256: sha}] when is_binary(sha), new_results)
        textures = if kind == :texture and accepted?, do: textures + 1, else: textures
        {Enum.reverse(new_results, results), plan, textures}

      {:skip, status} ->
        {[%{base | status: status} | results], plan, textures}
    end
  end

  # Everything decidable before inflating.
  defp entry_check(:other, _entry, _plan, _textures), do: {:skip, :ignored}

  defp entry_check(kind, entry, plan, textures) do
    max =
      if kind == :preset,
        do: UploadCheck.max_preset_bytes(),
        else: UploadCheck.max_texture_bytes()

    with {:ok, name} <- UploadCheck.normalise_name(Path.basename(entry.name)),
         :ok <- if(entry.size > max, do: {:error, :too_large}, else: :ok),
         :ok <- texture_limits(kind, name, textures),
         :ok <- unclaimed(plan, kind, name) do
      {:ok, name}
    else
      {:error, reason} -> {:skip, {:rejected, reason}}
    end
  end

  defp texture_limits(:preset, _name, _textures), do: :ok

  defp texture_limits(:texture, name, textures) do
    cond do
      UploadCheck.texture_reserved?(name) -> {:error, :reserved_name}
      textures >= @max_textures_per_archive -> {:error, :too_many_textures}
      true -> :ok
    end
  end

  defp read_entry!(zip, entry) do
    case Zip.read(zip, entry) do
      {:ok, data} -> data
      {:error, reason} -> throw({:archive_rejected, reason})
    end
  end

  # -- Private: accepting one file --

  defp accept(plan, %{kind: kind, name: name} = base, data) do
    with :ok <- unclaimed(plan, kind, name),
         {:ok, warnings} <- check_content(plan, kind, name, data) do
      sha = :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

      result =
        case against_installed(plan, kind, name, sha) do
          # Nothing to write: report the installed file.
          {:unchanged, old_name} -> %{base | name: old_name, status: :unchanged}
          {status, replaces} -> %{base | status: status, replaces: replaces, data: data}
        end

      result = %{
        result
        | id: if(kind == :preset, do: UploadCheck.preset_id(result.name)),
          sha256: sha,
          size: byte_size(data),
          warnings: warnings
      }

      {[result], claim(plan, kind, name)}
    else
      {:error, reason} -> {[%{base | status: {:rejected, reason}}], plan}
    end
  end

  defp check_content(_plan, :preset, _name, data) do
    with :ok <- UploadCheck.check_preset(data), do: {:ok, []}
  end

  defp check_content(plan, :texture, name, data) do
    with {:ok, _info} <- UploadCheck.check_texture(name, data) do
      shadowed? = MapSet.member?(plan.pack_textures, UploadCheck.texture_key(name))
      {:ok, if(shadowed?, do: [:texture_shadowed], else: [])}
    end
  end

  defp against_installed(plan, kind, name, sha) do
    case Map.get(installed(plan, kind), key(kind, name)) do
      nil -> {:added, nil}
      {old_name, ^sha} -> {:unchanged, old_name}
      {old_name, _other} -> {:replaced, old_name}
    end
  end

  defp unclaimed(plan, kind, name) do
    if MapSet.member?(plan.claimed, {kind, key(kind, name)}),
      do: {:error, :duplicate_name},
      else: :ok
  end

  defp claim(plan, kind, name),
    do: %{plan | claimed: MapSet.put(plan.claimed, {kind, key(kind, name)})}

  defp installed(plan, :preset), do: plan.presets
  defp installed(plan, :texture), do: plan.textures

  defp key(:preset, name), do: UploadCheck.fold(name)
  defp key(:texture, name), do: UploadCheck.texture_key(name)

  # -- Private: helpers --

  defp index(names_to_sha, key_fun) do
    Map.new(names_to_sha, fn {name, sha} -> {key_fun.(name), {name, sha}} end)
  end

  defp skip_entry?(%Zip.Entry{dir?: true}), do: true

  defp skip_entry?(%Zip.Entry{name: name}) do
    base = Path.basename(name)

    hd(String.split(name, "/")) == "__MACOSX" or String.starts_with?(base, "._") or
      String.downcase(base) in @junk_names
  end

  defp read_source({:binary, data}, max) when byte_size(data) > max, do: {:error, :too_large}
  defp read_source({:binary, data}, _max), do: {:ok, data}

  defp read_source(path, max) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > max -> {:error, :too_large}
      {:ok, %File.Stat{type: :regular}} -> path |> File.read() |> io() |> within(max)
      {:ok, _} -> {:error, :not_regular_file}
      {:error, reason} -> {:error, {:io, reason}}
    end
  end

  defp io({:error, reason}), do: {:error, {:io, reason}}
  defp io(ok), do: ok

  # The file may have grown since it was stat'ed.
  defp within({:ok, data}, max) when byte_size(data) > max, do: {:error, :too_large}
  defp within(result, _max), do: result

  defp result(upload, entry, kind, fields \\ []) do
    Map.merge(
      %{
        upload: upload,
        entry: entry,
        kind: kind,
        name: nil,
        id: nil,
        status: nil,
        replaces: nil,
        sha256: nil,
        size: nil,
        warnings: [],
        data: nil
      },
      Map.new(fields)
    )
  end
end
