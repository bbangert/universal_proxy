defmodule UniversalProxy.MilkDrop.UserPresets do
  @moduledoc """
  The library of uploaded MilkDrop presets and textures, and its import
  pipeline. One server owns `<root>/user/` and `<root>/incoming/`
  (`UniversalProxy.MilkDrop.root/0`) and runs one write at a time.

  ## On disk

      <root>/user/manifest.json           the renderer's --user-dir manifest
      <root>/user/presets/<name>.milk      preset id "user/<name>.milk"
      <root>/user/textures/<name>.<ext>    .png, .jpg or .jpeg
      <root>/incoming/                     uploads waiting for import/2, staging

  The manifest has the pack's format, so the renderer reads it with the
  same parser (unknown fields ignored). It is built with `Jason`, every
  name re-validated with `UploadCheck.normalise_name/1`, and written to a
  temporary file, synced and renamed over the old one:

      {"format": 1, "version": "user",
       "presets": [{"file": "A.milk", "tags": ["uploaded"],
                    "sha256": "<hex>", "size": 1234, "uploaded_at": 1762560000}],
       "textures": [{"file": "t.png", "sha256": "<hex>", "size": 99,
                     "uploaded_at": 1762560000}]}

  `tags` gains `"high_frequency"` once `set_high_frequency/3` flags a
  preset; uploads start without it (the user chose them, and the upload
  form carries the photosensitivity warning). `sha256`, `size`,
  `uploaded_at` (Unix seconds) and `textures` are the library's own
  metadata.

  The directories are the truth. At start the server deletes everything
  under `incoming/` (stale uploads and staging), then rebuilds the library
  from `presets/` and `textures/`: every entry must be a regular file whose
  name normalises to itself, of the directory's kind, whose content passes
  `UploadCheck.check_preset/1` or `check_texture/2`, and that no other
  kept name claims (by `UploadCheck.fold/1`, or `texture_key/1`; names
  the old manifest lists go first); a texture must not shadow a built-in
  sampler. Anything else is deleted (the
  renderer's texture scan would follow a symlink). Every file is hashed
  (at most the 64 MiB quota), tags and `uploaded_at` come from the old
  manifest, and the manifest is rewritten if it differs. An import or
  delete cut short by a power cut thus leaves a consistent library at the
  next start. Nothing is ever written into the pack's directory.

  ## Import

  `import/2` takes `{client_name, path}` uploads already copied into
  `incoming/` and consumes them: each path must be a regular file directly
  in `incoming/` (else `{:rejected, :bad_source}`), and is deleted before
  `import/2` returns. Planning and staging run in a task under
  `:task_supervisor`, bounded by `:import_timeout_ms` (60 s; then
  `{:error, :timeout}` and nothing is installed):

    1. the free space where `<root>` lives is measured (`:free_space`,
       `df -B1`; a failure is `{:error, {:free_space, reason}}`);
    2. each upload over 32 MiB is `{:rejected, :too_large}` unopened; the
       rest go through `UniversalProxy.MilkDrop.ImportPlan` against the
       library and the pack's texture names, one at a time;
    3. each file to write is checked in order against the quota — at most
       64 MiB, 500 presets and 256 textures in the library afterwards; a
       replacement counts its size difference (`{:rejected, :quota}`) —
       and the free-space floor — max(200 MiB, 10% of the filesystem)
       must stay free after the files staged so far (`{:rejected,
       :no_space}`) — then written by the task, mode 0644, under a
       staging directory in `incoming/`. A file past a limit is rejected
       on its own; a later, smaller one may still fit;
    4. the free space is measured again: below the floor (something else
       wrote to the filesystem meanwhile) every staged file is
       `{:rejected, :no_space}`.

  The server then renames the staged files into `user/` (the same
  filesystem), deletes the file a replacement supersedes when its name
  differs (in case, or a texture's extension), rewrites the manifest and
  tells the Store (`UniversalProxy.MilkDrop.Store`): a replaced id's skips
  go (`Store.clear_user_skips/2`), and an id a differently-named
  replacement supersedes counts as deleted (`Store.user_presets_removed/2`).
  A replacement keeps the replaced preset's `high_frequency` flag. If the
  superseded file can't be deleted, both stay in the library (the newer
  wins at the next start) and the deletion is retried every `:retry_ms`
  (5 s).

  The answer is `{:ok, results}`: `ImportPlan`'s results without `:data`
  (`:status` is `:added`, `:replaced`, `:unchanged`, `:ignored` or
  `{:rejected, reason}`; `:warnings` may hold `:texture_shadowed`), in
  upload order. A file that could not be renamed into place is
  `{:rejected, {:io, :install_failed}}`.

  ## Publishing

  The renderer only sees what the manifest lists, so a write that fails to
  rewrite it fails: installed files are `{:rejected, {:manifest,
  reason}}`, and `delete/2` and `delete_texture/2` return `{:error,
  {:manifest, reason}}` (`set_high_frequency/3` too, and its flag goes
  back). The library keeps matching the disk; the manifest write is
  retried on every later write and every `:retry_ms`, an import with
  nothing to install included (uploading the same files again repairs
  it), and the change is broadcast once it is written — with every list
  empty if nothing else changed (a start-up repair), since a renderer may
  have read the stale manifest.

  The Store's clean-up (`Store.user_presets_removed/2`,
  `Store.clear_user_skips/2`) is independent of that: ids the Store didn't
  acknowledge are asked again on every later write and every
  `:retry_ms`, so a stale lock or skip can't return with a re-upload. A
  queued deletion of a superseded file is dropped once an import installs
  a file of that exact name, or `delete/2` removes it.

  ## Other writes

  `delete/2` and `delete_texture/2` look their argument up in the library
  (a client string is only ever a map key, never part of a path), delete
  the file, rewrite the manifest and, for a preset, call
  `Store.user_presets_removed/2` (its skips, and the `locked` setting if it
  names it). A file that can't be deleted (anything but already gone) is
  `{:error, {:io, reason}}` and changes nothing. `set_high_frequency/3`
  sets or clears the tag. While an import
  runs they return `{:error, :busy}`, as does another `import/2`; the reads
  (`list/1`, `usage/1`, `sha256/2`) are served throughout.

  ## Changes

  Each write that changes the library is broadcast on
  `UniversalProxy.MilkDrop.user_presets_topic/0` as

      {:milkdrop_user_presets,
       %{added: [id], replaced: [id], removed: [id], updated: [id], textures: [name]}}

  (`updated`: a tag changed; `textures`: texture files added, replaced or
  deleted). `UniversalProxy.Display.State` forwards it to a running
  renderer as `reload_user`. An id in `removed` is gone: whatever else is
  keyed by it can be dropped.

  Each start (a restart may have repaired the manifest) is broadcast as
  `{:milkdrop_user_presets_started, %{bytes:, presets:, textures:}}`:
  anything derived from the library should be re-read; Display.State sends
  `reload_user` for it too.

  ## SHA-256 lookups

  `sha256/2` reads the library's `{id, sha256}` table (protected ETS owned
  by the server) without a call, so the Store's skip records can be keyed
  by content even from its start-up recovery (`MilkDrop.Supervisor` starts
  this server first). The table is published whole, with a `:ready` row,
  once the start-up scan is done; before that (a restart), or with no
  table, a lookup hashes the file itself.

  The public API follows the `catch :exit` idiom: while the server is not
  running (or a call times out) reads return an empty library and writes
  `{:error, :not_running}`.

  Tests override via `:name`, `:table`, `:root`, `:store`, `:pubsub`,
  `:task_supervisor`, `:free_space` (`path -> {:ok, %{total_bytes:,
  free_bytes:}} | {:error, reason}`), `:pack_textures` (0-arity: the
  pack's texture file names), `:quota` (`%{bytes:, presets:, textures:}`),
  `:min_free_bytes`, `:min_free_pct`, `:max_upload_bytes`,
  `:import_timeout_ms` and `:retry_ms`.
  """

  use GenServer

  require Logger

  alias UniversalProxy.MilkDrop
  alias UniversalProxy.MilkDrop.{ImportPlan, Pack, Store, UploadCheck}
  alias UniversalProxy.Storage.Mount

  @table __MODULE__
  @task_supervisor UniversalProxy.MilkDrop.UserPresetTasks
  @mib 1024 * 1024
  @quota %{bytes: 64 * @mib, presets: 500, textures: 256}
  @max_upload_bytes 32 * @mib
  @min_free_bytes 200 * @mib
  @min_free_pct 10
  @import_timeout_ms 60_000
  @retry_ms 5_000
  # The caller waits past the task's bound for the server's answer.
  @call_timeout_ms @import_timeout_ms + 15_000
  @manifest "manifest.json"
  # The last second DateTime.from_unix!/1 accepts (9999-12-31).
  @max_unix_s 253_402_300_799
  @manifest_tmp ".manifest.json.tmp"

  @type result :: %{
          upload: String.t(),
          entry: String.t() | nil,
          kind: :preset | :texture | :archive | :other,
          name: String.t() | nil,
          id: String.t() | nil,
          status: :added | :replaced | :unchanged | :ignored | {:rejected, term()},
          replaces: String.t() | nil,
          sha256: String.t() | nil,
          size: non_neg_integer() | nil,
          warnings: [:texture_shadowed]
        }

  @type preset :: %{
          id: String.t(),
          name: String.t(),
          sha256: String.t(),
          size: non_neg_integer(),
          high_frequency: boolean(),
          uploaded_at: DateTime.t()
        }

  @type texture :: %{
          name: String.t(),
          sha256: String.t(),
          size: non_neg_integer(),
          uploaded_at: DateTime.t()
        }

  @type usage :: %{
          bytes: non_neg_integer(),
          presets: non_neg_integer(),
          textures: non_neg_integer(),
          quota: %{bytes: pos_integer(), presets: pos_integer(), textures: pos_integer()}
        }

  # -- Client API --

  def start_link(opts \\ []) do
    gen_opts =
      case Keyword.get(opts, :name, __MODULE__) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "The default `:task_supervisor` imports run under."
  @spec task_supervisor() :: atom()
  def task_supervisor, do: @task_supervisor

  @doc "The library's limits (see the moduledoc)."
  @spec quota() :: %{bytes: pos_integer(), presets: pos_integer(), textures: pos_integer()}
  def quota, do: @quota

  @doc "The library directory under `root`, the renderer's `--user-dir`."
  @spec user_dir(String.t()) :: String.t()
  def user_dir(root \\ MilkDrop.root()), do: Path.join(root, "user")

  @doc "Where uploads wait for `import/2` under `root`."
  @spec incoming_dir(String.t()) :: String.t()
  def incoming_dir(root \\ MilkDrop.root()), do: Path.join(root, "incoming")

  @doc "Import uploads copied into `incoming_dir/1` (see the moduledoc)."
  @spec import(GenServer.server(), [{String.t(), Path.t()}]) ::
          {:ok, [result()]} | {:error, term()}
  def import(server \\ __MODULE__, uploads) when is_list(uploads) do
    GenServer.call(server, {:import, uploads}, @call_timeout_ms)
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc "Delete the uploaded preset `id` (`user/<name>`)."
  @spec delete(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def delete(server \\ __MODULE__, id) when is_binary(id) do
    GenServer.call(server, {:delete, :preset, id})
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc "Delete the uploaded texture `name`."
  @spec delete_texture(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def delete_texture(server \\ __MODULE__, name) when is_binary(name) do
    GenServer.call(server, {:delete, :texture, name})
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc "Flag (or unflag) the uploaded preset `id` as fast-flashing (`high_frequency`)."
  @spec set_high_frequency(GenServer.server(), String.t(), boolean()) :: :ok | {:error, term()}
  def set_high_frequency(server \\ __MODULE__, id, flag)
      when is_binary(id) and is_boolean(flag) do
    GenServer.call(server, {:set_high_frequency, id, flag})
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc "The library, each list sorted by name (empty while the server is not running)."
  @spec list(GenServer.server()) :: %{presets: [preset()], textures: [texture()]}
  def list(server \\ __MODULE__) do
    GenServer.call(server, :list)
  catch
    :exit, _ -> %{presets: [], textures: []}
  end

  @doc "The library's size and counts against its quota (zeros while not running)."
  @spec usage(GenServer.server()) :: usage()
  def usage(server \\ __MODULE__) do
    GenServer.call(server, :usage)
  catch
    :exit, _ -> %{bytes: 0, presets: 0, textures: 0, quota: @quota}
  end

  @doc """
  The SHA-256 (lowercase hex) of the library file preset `id` names, or
  `nil` when there is none. Reads the server's table without a call; with
  no table (the server is not running) it hashes
  `<UniversalProxy.MilkDrop.root()>/user/presets/<name>` itself.
  """
  @spec sha256(atom(), String.t()) :: String.t() | nil
  def sha256(table \\ @table, id) when is_binary(id) do
    case :ets.lookup(table, id) do
      [{^id, sha}] when is_binary(sha) ->
        sha

      _none ->
        if :ets.member(table, :ready), do: nil, else: unready_sha256(table, id)
    end
  rescue
    ArgumentError -> file_sha256(user_dir(), id)
  end

  # A (re)starting server's table, before its scan is in.
  defp unready_sha256(table, id) do
    case :ets.lookup(table, :user_dir) do
      [{:user_dir, dir}] -> file_sha256(dir, id)
      [] -> file_sha256(user_dir(), id)
    end
  end

  @doc """
  The SHA-256 of `<user_dir>/presets/<name>` for preset `id` (`user/<name>`),
  or `nil` when the name is not a valid upload name or no regular file is
  there.
  """
  @spec file_sha256(String.t(), String.t()) :: String.t() | nil
  def file_sha256(user_dir, "user/" <> name) do
    path = Path.join([user_dir, "presets", name])

    with {:ok, ^name} <- UploadCheck.normalise_name(name),
         :preset <- UploadCheck.kind(name),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, data} <- File.read(path) do
      sha(data)
    else
      _ -> nil
    end
  end

  def file_sha256(_user_dir, _id), do: nil

  # -- Server callbacks --

  @impl true
  def init(opts) do
    root = Keyword.get_lazy(opts, :root, &MilkDrop.root/0)
    table = Keyword.get(opts, :table, @table)

    state = %{
      root: root,
      user_dir: user_dir(root),
      incoming: incoming_dir(root),
      table: :ets.new(table, [:named_table, :protected, :set, read_concurrency: true]),
      store: Keyword.get(opts, :store, Store),
      pubsub: Keyword.get(opts, :pubsub, UniversalProxy.PubSub),
      task_supervisor: Keyword.get(opts, :task_supervisor, @task_supervisor),
      free_space: Keyword.get(opts, :free_space, &free_space/1),
      pack_textures: Keyword.get(opts, :pack_textures, &pack_textures/0),
      quota: Map.merge(@quota, Map.new(Keyword.get(opts, :quota, %{}))),
      min_free_bytes: Keyword.get(opts, :min_free_bytes, @min_free_bytes),
      min_free_pct: Keyword.get(opts, :min_free_pct, @min_free_pct),
      max_upload_bytes: Keyword.get(opts, :max_upload_bytes, @max_upload_bytes),
      import_timeout_ms: Keyword.get(opts, :import_timeout_ms, @import_timeout_ms),
      retry_ms: Keyword.get(opts, :retry_ms, @retry_ms),
      library: %{presets: %{}, textures: %{}},
      busy: nil,
      # The manifest on disk lags the library; `pending` is the change not
      # announced yet.
      dirty: false,
      pending: empty_change(),
      # `{kind, name}` files a differently-named replacement superseded
      # that could not be deleted yet.
      cleanup: [],
      # Ids whose Store clean-up (`removed`: skips and lock; `replaced`:
      # skips) the Store has not acknowledged yet.
      store_pending: %{removed: [], replaced: []},
      retry_timer: nil
    }

    # Until `:ready`, a lookup falls back to the file under `:user_dir`.
    :ets.insert(state.table, {:user_dir, state.user_dir})
    clean_incoming(state.incoming)
    {library, dirty} = load_library(state.user_dir)
    :ets.insert(state.table, sha_rows(library) ++ [{:ready, true}])
    state = schedule_retry(%{state | library: library, dirty: dirty})
    {:ok, state, {:continue, :announce}}
  end

  # A restarted server may have repaired the manifest a running renderer
  # read before: announced like a change.
  @impl true
  def handle_continue(:announce, state) do
    Phoenix.PubSub.broadcast(
      state.pubsub,
      MilkDrop.user_presets_topic(),
      {:milkdrop_user_presets_started, usage_of(state.library)}
    )

    {:noreply, state}
  end

  @impl true
  def handle_call(:list, _from, state), do: {:reply, listing(state.library), state}

  def handle_call(:usage, _from, state),
    do: {:reply, Map.put(usage_of(state.library), :quota, state.quota), state}

  def handle_call(_write, _from, %{busy: busy} = state) when busy != nil,
    do: {:reply, {:error, :busy}, state}

  def handle_call({:import, uploads}, from, state) do
    staging = Path.join(state.incoming, ".staging-#{Base.encode16(:crypto.strong_rand_bytes(6))}")
    job = import_job(state, staging)

    task = Task.Supervisor.async_nolink(state.task_supervisor, fn -> run_import(job, uploads) end)
    timer = Process.send_after(self(), {:import_timeout, task.ref}, state.import_timeout_ms)

    busy = %{task: task, from: from, uploads: uploads, staging: staging, timer: timer}
    {:noreply, %{state | busy: busy}}
  catch
    :exit, reason ->
      consume_uploads(state, uploads)
      {:reply, {:error, {:crashed, reason}}, state}
  end

  def handle_call({:delete, kind, key}, _from, state) do
    case lookup(state.library, kind, key) do
      {:ok, name} ->
        {reply, state} = delete_file(state, kind, name)
        {:reply, reply, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:set_high_frequency, id, flag}, _from, state) do
    case lookup(state.library, :preset, id) do
      {:ok, name} -> set_flag(state, name, flag)
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_info({ref, result}, %{busy: %{task: %{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])

    {reply, state} =
      case result do
        {:ok, results, staged} ->
          {results, state} = commit(state, results, staged)
          {{:ok, results}, state}

        {:error, _reason} = error ->
          {error, state}
      end

    {:noreply, finish_import(state, reply)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{busy: %{task: %{ref: ref}}} = state) do
    Logger.error("MilkDrop upload import crashed: #{inspect(reason)}")
    {:noreply, finish_import(state, {:error, {:crashed, reason}})}
  end

  def handle_info({:import_timeout, ref}, %{busy: %{task: %{ref: ref} = task}} = state) do
    Logger.warning("MilkDrop upload import took over #{state.import_timeout_ms} ms; stopping it")
    _ = Task.Supervisor.terminate_child(state.task_supervisor, task.pid)
    Process.demonitor(ref, [:flush])
    {:noreply, finish_import(state, {:error, :timeout})}
  end

  def handle_info(:retry, %{busy: nil} = state),
    do: {:noreply, retry_pending(%{state | retry_timer: nil})}

  def handle_info(:retry, state), do: {:noreply, schedule_retry(%{state | retry_timer: nil})}

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private: import (task side) --

  defp import_job(state, staging) do
    %{
      root: state.root,
      incoming: state.incoming,
      staging: staging,
      library: state.library,
      quota: state.quota,
      free_space: state.free_space,
      pack_textures: state.pack_textures,
      min_free_bytes: state.min_free_bytes,
      min_free_pct: state.min_free_pct,
      max_upload_bytes: state.max_upload_bytes
    }
  end

  # `{:ok, results, staged}`: results in upload order, staged files in
  # the order they are to be installed.
  defp run_import(job, uploads) do
    with {:ok, floor, free} <- measure(job) do
      plan =
        ImportPlan.new(%{
          presets: shas(job.library.presets),
          textures: shas(job.library.textures),
          pack_textures: job.pack_textures.()
        })

      acc = %{usage: usage_of(job.library), free: free, results: [], staged: []}

      {_plan, acc} =
        Enum.reduce(uploads, {plan, acc}, fn {client_name, path}, {plan, acc} ->
          case check_source(job, path) do
            :ok ->
              {results, plan} = ImportPlan.add(plan, client_name, path)
              {plan, Enum.reduce(results, acc, &stage(job, floor, &1, &2))}

            {:error, reason} ->
              {plan, add_result(acc, source_rejected(client_name, reason))}
          end
        end)

      results = Enum.reverse(acc.results)
      staged = Enum.reverse(acc.staged)

      case recheck(job, floor, staged) do
        :ok -> {:ok, results, staged}
        :no_space -> {:ok, Enum.map(results, &unstage(&1, staged)), []}
      end
    end
  end

  defp measure(job) do
    case job.free_space.(job.root) do
      {:ok, %{total_bytes: total, free_bytes: free}} ->
        {:ok, max(job.min_free_bytes, div(total * job.min_free_pct, 100)), free}

      {:error, reason} ->
        {:error, {:free_space, reason}}
    end
  end

  defp recheck(_job, _floor, []), do: :ok

  defp recheck(job, floor, _staged) do
    case measure(job) do
      {:ok, _floor, free} when free >= floor -> :ok
      _low_or_unknown -> :no_space
    end
  end

  defp unstage(result, staged) do
    if Enum.any?(staged, &(&1.kind == result.kind and &1.name == result.name)) and
         result.status in [:added, :replaced],
       do: %{result | status: {:rejected, :no_space}},
       else: result
  end

  defp check_source(job, path) when is_binary(path) do
    expanded = Path.expand(path)

    with true <- Path.dirname(expanded) == Path.expand(job.incoming),
         false <- String.starts_with?(Path.basename(expanded), "."),
         {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(expanded) do
      if size > job.max_upload_bytes, do: {:error, :too_large}, else: :ok
    else
      _ -> {:error, :bad_source}
    end
  end

  defp check_source(_job, _path), do: {:error, :bad_source}

  defp source_rejected(client_name, reason) do
    name = if is_binary(client_name), do: client_name, else: ""

    kind =
      case name |> Path.extname() |> String.downcase() do
        ".milk" -> :preset
        ".zip" -> :archive
        _ -> :other
      end

    %{
      upload: UploadCheck.printable(name),
      entry: nil,
      kind: kind,
      name: nil,
      id: nil,
      status: {:rejected, reason},
      replaces: nil,
      sha256: nil,
      size: nil,
      warnings: []
    }
  end

  # One planned result: written to staging if it changes something and
  # fits, its bytes dropped either way.
  defp stage(job, floor, %{status: status, data: data} = result, acc)
       when status in [:added, :replaced] and is_binary(data) do
    result = Map.delete(result, :data)
    old = old_size(job.library, result)

    usage =
      acc.usage
      |> Map.update!(:bytes, &(&1 + result.size - old))
      |> Map.update!(count_key(result.kind), &(&1 + if(status == :added, do: 1, else: 0)))

    cond do
      over_quota?(usage, job.quota) ->
        add_result(acc, %{result | status: {:rejected, :quota}})

      acc.free - result.size < floor ->
        add_result(acc, %{result | status: {:rejected, :no_space}})

      true ->
        path = Path.join([job.staging, subdir(result.kind), result.name])

        case write_file(path, data) do
          :ok ->
            item = Map.take(result, [:kind, :name, :replaces, :sha256, :size, :status])

            %{
              acc
              | usage: usage,
                free: acc.free - result.size,
                staged: [Map.put(item, :path, path) | acc.staged]
            }
            |> add_result(result)

          {:error, reason} ->
            add_result(acc, %{result | status: {:rejected, {:io, reason}}})
        end
    end
  end

  defp stage(_job, _floor, result, acc), do: add_result(acc, Map.delete(result, :data))

  defp add_result(acc, result), do: %{acc | results: [result | acc.results]}

  defp old_size(_library, %{status: :added}), do: 0

  defp old_size(library, %{kind: kind, replaces: replaces}),
    do: get_in(library, [section(kind), replaces, :size]) || 0

  defp over_quota?(usage, quota) do
    usage.bytes > quota.bytes or usage.presets > quota.presets or
      usage.textures > quota.textures
  end

  # -- Private: import (server side) --

  # Nothing to install: an unpublished manifest is still retried, so
  # uploading the same files again repairs it.
  defp commit(%{dirty: true} = state, results, []) do
    {_reply, state} = publish(state, empty_change())
    {results, state}
  end

  defp commit(state, results, []), do: {results, state}

  defp commit(state, results, staged) do
    now = System.os_time(:second)
    acc = %{library: state.library, failed: MapSet.new(), change: empty_change(), cleanup: []}
    acc = Enum.reduce(staged, acc, &install(state, &1, now, &2))

    # A queued removal of a name this import just installed would delete
    # the new file (the path is exact, so is the comparison).
    installed =
      for item <- staged,
          not MapSet.member?(acc.failed, {item.kind, item.name}),
          into: MapSet.new(),
          do: {item.kind, item.name}

    cleanup = Enum.reject(state.cleanup, &MapSet.member?(installed, &1)) ++ acc.cleanup
    state = %{state | library: acc.library, cleanup: cleanup}
    sync_table(state, acc.change)
    state = tell_store(state, acc.change)
    {published, state} = publish(state, acc.change)

    results =
      Enum.map(results, fn result ->
        cond do
          result.status not in [:added, :replaced] ->
            result

          MapSet.member?(acc.failed, {result.kind, result.name}) ->
            failed(result, {:io, :install_failed})

          published != :ok ->
            failed(result, elem(published, 1))

          true ->
            result
        end
      end)

    {results, schedule_retry(state)}
  end

  defp failed(result, reason), do: %{result | status: {:rejected, reason}}

  defp install(state, item, now, acc) do
    dest = Path.join([state.user_dir, subdir(item.kind), item.name])

    case File.rename(item.path, dest) do
      :ok ->
        superseded = if item.replaces not in [nil, item.name], do: item.replaces

        case superseded && rm(Path.join([state.user_dir, subdir(item.kind), superseded])) do
          {:error, _reason} ->
            # Both files stay listed until the old one's removal succeeds.
            acc = %{acc | cleanup: acc.cleanup ++ [{item.kind, superseded}]}
            installed(acc, %{item | replaces: nil, status: :added}, nil, now, item.replaces)

          _removed_or_none ->
            installed(acc, item, superseded, now, item.replaces)
        end

      {:error, reason} ->
        Logger.error(
          "MilkDrop upload #{inspect(item.name)} could not be installed: #{inspect(reason)}"
        )

        %{acc | failed: MapSet.put(acc.failed, {item.kind, item.name})}
    end
  end

  # `flagged_from`: the replaced preset whose high_frequency flag carries over.
  defp installed(acc, %{kind: :preset} = item, superseded, now, flagged_from) do
    presets = acc.library.presets
    old = flagged_from && presets[flagged_from]

    meta = %{
      sha256: item.sha256,
      size: item.size,
      uploaded_at: now,
      high_frequency: (old && old.high_frequency) || false
    }

    presets = presets |> Map.delete(superseded) |> Map.put(item.name, meta)
    id = UploadCheck.preset_id(item.name)

    change =
      cond do
        item.status == :added ->
          add_change(acc.change, :added, id)

        superseded ->
          acc.change
          |> add_change(:removed, UploadCheck.preset_id(superseded))
          |> add_change(:added, id)

        true ->
          add_change(acc.change, :replaced, id)
      end

    %{acc | library: %{acc.library | presets: presets}, change: change}
  end

  defp installed(acc, %{kind: :texture} = item, superseded, now, _flagged_from) do
    meta = %{sha256: item.sha256, size: item.size, uploaded_at: now}
    textures = acc.library.textures |> Map.delete(superseded) |> Map.put(item.name, meta)

    change =
      Enum.reduce(
        Enum.reject([item.name, superseded], &is_nil/1),
        acc.change,
        &add_change(&2, :textures, &1)
      )

    %{acc | library: %{acc.library | textures: textures}, change: change}
  end

  defp finish_import(%{busy: busy} = state, reply) do
    Process.cancel_timer(busy.timer)
    _ = File.rm_rf(busy.staging)
    consume_uploads(state, busy.uploads)
    GenServer.reply(busy.from, reply)
    %{state | busy: nil}
  end

  # Only files inside `incoming/` are ever deleted.
  defp consume_uploads(state, uploads) do
    incoming = Path.expand(state.incoming)

    for {_client_name, path} <- uploads,
        is_binary(path),
        Path.dirname(Path.expand(path)) == incoming,
        do: File.rm(path)

    :ok
  end

  # -- Private: other writes --

  defp lookup(library, :preset, "user/" <> name) do
    if Map.has_key?(library.presets, name), do: {:ok, name}, else: :error
  end

  defp lookup(_library, :preset, _id), do: :error

  defp lookup(library, :texture, name) do
    if Map.has_key?(library.textures, name), do: {:ok, name}, else: :error
  end

  # A file that can't be deleted stays in the library; one already gone is
  # deleted.
  defp delete_file(state, kind, name) do
    case rm(Path.join([state.user_dir, subdir(kind), name])) do
      :ok ->
        {change, state} =
          forget(%{state | cleanup: List.delete(state.cleanup, {kind, name})}, kind, name)

        publish(state, change)

      {:error, reason} ->
        {{:error, {:io, reason}}, state}
    end
  end

  # Drops a deleted file from the library, the table and the Store.
  defp forget(state, kind, name) do
    library = Map.update!(state.library, section(kind), &Map.delete(&1, name))
    state = %{state | library: library}

    change =
      case kind do
        :preset -> add_change(empty_change(), :removed, UploadCheck.preset_id(name))
        :texture -> add_change(empty_change(), :textures, name)
      end

    sync_table(state, change)
    {change, tell_store(state, change)}
  end

  defp set_flag(state, name, flag) do
    case state.library.presets[name] do
      %{high_frequency: ^flag} ->
        {:reply, :ok, state}

      meta ->
        library = put_in(state.library, [:presets, name], %{meta | high_frequency: flag})
        change = add_change(empty_change(), :updated, UploadCheck.preset_id(name))

        case publish(%{state | library: library}, change) do
          {:ok, state} -> {:reply, :ok, state}
          # Nothing else changed: the flag goes back.
          {error, state} -> {:reply, error, put_in(state.library.presets[name], meta)}
        end
    end
  end

  # -- Private: changes --

  defp empty_change, do: %{added: [], replaced: [], removed: [], updated: [], textures: []}

  # Writes the manifest for the library as it is, then announces every
  # change since the last write that reached disk. On failure the library
  # (which matches the disk) stays, and the write is retried on the next
  # write and every `:retry_ms`.
  defp publish(state, change) do
    pending = merge_change(state.pending, change)

    case write_manifest(state.user_dir, state.library) do
      :ok ->
        # A repaired manifest is news even with nothing listed: a renderer
        # may have read the stale one.
        if state.dirty, do: notify(state, pending), else: broadcast(state, pending)
        {:ok, %{state | dirty: false, pending: empty_change()}}

      {:error, reason} ->
        Logger.error("MilkDrop upload manifest write failed: #{inspect(reason)}; retrying")
        {{:error, {:manifest, reason}}, schedule_retry(%{state | dirty: true, pending: pending})}
    end
  end

  # A later change wins over an earlier one for the same id.
  defp merge_change(old, new) do
    gone = new.removed
    back = new.added

    %{
      added: Enum.uniq((old.added -- gone) ++ back),
      replaced: Enum.uniq((old.replaced -- gone) ++ new.replaced),
      updated: Enum.uniq((old.updated -- gone) ++ new.updated),
      removed: Enum.uniq((old.removed -- back) ++ gone),
      textures: Enum.uniq(old.textures ++ new.textures)
    }
  end

  defp schedule_retry(%{retry_timer: nil} = state) do
    if state.dirty or state.cleanup != [] or state.store_pending != %{removed: [], replaced: []},
      do: %{state | retry_timer: Process.send_after(self(), :retry, state.retry_ms)},
      else: state
  end

  defp schedule_retry(state), do: state

  # Superseded files whose removal failed, the Store's clean-up, then the
  # manifest.
  defp retry_pending(state) do
    {change, cleanup, state} =
      Enum.reduce(state.cleanup, {empty_change(), [], state}, fn {kind, name} = file,
                                                                 {change, left, state} ->
        case rm(Path.join([state.user_dir, subdir(kind), name])) do
          :ok ->
            {forgotten, state} = forget(state, kind, name)
            {merge_change(change, forgotten), left, state}

          {:error, _reason} ->
            {change, left ++ [file], state}
        end
      end)

    state = tell_store(%{state | cleanup: cleanup}, empty_change())

    state =
      if state.dirty or change != empty_change(),
        do: state |> publish(change) |> elem(1),
        else: state

    schedule_retry(state)
  end

  defp add_change(change, key, value), do: Map.update!(change, key, &(&1 ++ [value]))

  defp sync_table(state, change) do
    Enum.each(change.removed, &:ets.delete(state.table, &1))

    rows =
      for name <- Map.keys(state.library.presets),
          id = UploadCheck.preset_id(name),
          id in change.added or id in change.replaced,
          do: {id, state.library.presets[name].sha256}

    :ets.insert(state.table, rows)
    :ok
  end

  # The change's ids join those the Store has yet to acknowledge, and all
  # are asked again; a refusal (the Store down, a failed write) keeps them
  # for the next write and the retry timer, so a stale lock or skip can't
  # come back with a re-upload.
  defp tell_store(state, change) do
    pending = %{
      removed: Enum.uniq(state.store_pending.removed ++ change.removed),
      replaced: Enum.uniq(state.store_pending.replaced ++ change.replaced)
    }

    pending = %{
      removed: store_ask(pending.removed, &Store.user_presets_removed(state.store, &1)),
      replaced: store_ask(pending.replaced, &Store.clear_user_skips(state.store, &1))
    }

    schedule_retry(%{state | store_pending: pending})
  end

  # The ids still unacknowledged.
  defp store_ask([], _fun), do: []

  defp store_ask(ids, fun) do
    case fun.(ids) do
      :ok ->
        []

      {:error, reason} ->
        Logger.warning(
          "MilkDrop: could not clear the Store's entries for #{inspect(ids)}: " <>
            "#{inspect(reason)}; retrying"
        )

        ids
    end
  end

  defp broadcast(_state, %{added: [], replaced: [], removed: [], updated: [], textures: []}),
    do: :ok

  defp broadcast(state, change), do: notify(state, change)

  defp notify(state, change) do
    Phoenix.PubSub.broadcast(
      state.pubsub,
      MilkDrop.user_presets_topic(),
      {:milkdrop_user_presets, change}
    )
  end

  # -- Private: library --

  defp clean_incoming(incoming) do
    with {:error, reason, _path} <- File.rm_rf(incoming) do
      Logger.warning("MilkDrop could not clean #{incoming}: #{inspect(reason)}")
    end

    mkdir_logged(incoming)
  end

  defp load_library(user_dir) do
    mkdir_logged(Path.join(user_dir, "presets"))
    mkdir_logged(Path.join(user_dir, "textures"))
    _ = File.rm(Path.join(user_dir, @manifest_tmp))
    old = read_manifest(user_dir)

    library = %{
      presets: scan(user_dir, :preset, old.presets),
      textures: scan(user_dir, :texture, old.textures)
    }

    # `dirty`: the manifest on disk doesn't match and couldn't be rewritten.
    with {:ok, body} <- encode_manifest(library),
         false <- File.read(Path.join(user_dir, @manifest)) == {:ok, body},
         {:error, reason} <- write_manifest(user_dir, library) do
      Logger.error("MilkDrop upload manifest write failed: #{inspect(reason)}; retrying")
      {library, true}
    else
      _ -> {library, false}
    end
  end

  defp scan(user_dir, kind, old_meta) do
    dir = Path.join(user_dir, subdir(kind))

    # Of names that collide, one the manifest knows wins, the newest upload
    # among those (a replacement whose predecessor couldn't be deleted).
    names =
      case File.ls(dir) do
        {:ok, names} -> Enum.sort_by(names, &collision_rank(old_meta, &1))
        {:error, _} -> []
      end

    {library, _claimed} =
      Enum.reduce(names, {%{}, MapSet.new()}, fn name, {library, claimed} ->
        path = Path.join(dir, name)
        key = library_key(kind, name)

        with false <- MapSet.member?(claimed, key),
             {:ok, size, data} <- valid_file(kind, name, path) do
          meta = file_meta(kind, data, size, Map.get(old_meta, name, %{}), path)
          {Map.put(library, name, meta), MapSet.put(claimed, key)}
        else
          _ ->
            Logger.warning("MilkDrop: removing #{inspect(path)}: not a valid upload")
            _ = File.rm_rf(path)
            {library, claimed}
        end
      end)

    library
  end

  defp collision_rank(old_meta, name) do
    case old_meta do
      %{^name => meta} -> {0, -Map.get(meta, :uploaded_at, 0), name}
      _unknown -> {1, 0, name}
    end
  end

  defp valid_file(kind, name, path) do
    with {:ok, ^name} <- UploadCheck.normalise_name(name),
         ^kind <- UploadCheck.kind(name),
         false <- kind == :texture and UploadCheck.texture_reserved?(name),
         {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(path),
         true <- size <= max_file_bytes(kind),
         {:ok, data} <- File.read(path),
         :ok <- check_content(kind, name, data) do
      {:ok, byte_size(data), data}
    else
      _ -> :error
    end
  end

  defp check_content(:preset, _name, data), do: UploadCheck.check_preset(data)

  defp check_content(:texture, name, data) do
    with {:ok, _info} <- UploadCheck.check_texture(name, data), do: :ok
  end

  defp max_file_bytes(:preset), do: UploadCheck.max_preset_bytes()
  defp max_file_bytes(:texture), do: UploadCheck.max_texture_bytes()

  defp file_meta(kind, data, size, old, path) do
    uploaded_at =
      case old do
        %{uploaded_at: at} -> at
        _ -> mtime(path)
      end

    meta = %{sha256: sha(data), size: size, uploaded_at: uploaded_at}

    if kind == :preset,
      do: Map.put(meta, :high_frequency, Map.get(old, :high_frequency, false)),
      else: meta
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      {:error, _} -> System.os_time(:second)
    end
  end

  defp read_manifest(user_dir) do
    with {:ok, body} <- File.read(Path.join(user_dir, @manifest)),
         {:ok, %{} = doc} <- Jason.decode(body) do
      %{presets: manifest_meta(doc["presets"]), textures: manifest_meta(doc["textures"])}
    else
      _ -> %{presets: %{}, textures: %{}}
    end
  end

  defp manifest_meta(entries) when is_list(entries) do
    for %{"file" => file} = entry <- entries, is_binary(file), into: %{} do
      tags = if is_list(entry["tags"]), do: entry["tags"], else: []
      at = entry["uploaded_at"]

      meta = %{high_frequency: "high_frequency" in tags}
      meta = if at in 0..@max_unix_s//1, do: Map.put(meta, :uploaded_at, at), else: meta
      {file, meta}
    end
  end

  defp manifest_meta(_entries), do: %{}

  defp encode_manifest(library) do
    presets =
      for {name, meta} <- Enum.sort(library.presets), valid_name?(name, :preset) do
        tags = if meta.high_frequency, do: ["uploaded", "high_frequency"], else: ["uploaded"]

        %{
          "file" => name,
          "tags" => tags,
          "sha256" => meta.sha256,
          "size" => meta.size,
          "uploaded_at" => meta.uploaded_at
        }
      end

    textures =
      for {name, meta} <- Enum.sort(library.textures), valid_name?(name, :texture) do
        %{
          "file" => name,
          "sha256" => meta.sha256,
          "size" => meta.size,
          "uploaded_at" => meta.uploaded_at
        }
      end

    Jason.encode(%{
      "format" => 1,
      "version" => "user",
      "presets" => presets,
      "textures" => textures
    })
  end

  defp valid_name?(name, kind),
    do: UploadCheck.normalise_name(name) == {:ok, name} and UploadCheck.kind(name) == kind

  defp write_manifest(user_dir, library) do
    tmp = Path.join(user_dir, @manifest_tmp)

    with {:ok, body} <- encode_manifest(library),
         :ok <- write_file(tmp, body, sync: true),
         :ok <- File.rename(tmp, Path.join(user_dir, @manifest)) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, io_reason(reason)}
    end
  end

  # Mode 0644 whatever the umask; with `sync: true` on disk before it returns.
  defp write_file(path, data, opts \\ []) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, fd} <- :file.open(path, [:write, :raw, :binary]) do
      result =
        with :ok <- :file.write(fd, data),
             :ok <- if(Keyword.get(opts, :sync, false), do: :file.sync(fd), else: :ok),
             do: :file.change_mode(path, 0o644)

      :ok = :file.close(fd)
      result
    end
  end

  defp io_reason(reason) when is_atom(reason), do: {:io, reason}
  defp io_reason(reason), do: reason

  # A file already gone counts as deleted.
  defp rm(path) do
    case File.rm(path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} = error ->
        Logger.error("MilkDrop could not delete #{inspect(path)}: #{inspect(reason)}")
        error
    end
  end

  defp mkdir_logged(dir) do
    with {:error, reason} <- File.mkdir_p(dir) do
      Logger.error("MilkDrop could not create #{dir}: #{inspect(reason)}")
    end

    :ok
  end

  defp listing(library) do
    presets =
      for {name, meta} <- sort_by_name(library.presets) do
        %{
          id: UploadCheck.preset_id(name),
          name: name,
          sha256: meta.sha256,
          size: meta.size,
          high_frequency: meta.high_frequency,
          uploaded_at: DateTime.from_unix!(meta.uploaded_at)
        }
      end

    textures =
      for {name, meta} <- sort_by_name(library.textures) do
        %{
          name: name,
          sha256: meta.sha256,
          size: meta.size,
          uploaded_at: DateTime.from_unix!(meta.uploaded_at)
        }
      end

    %{presets: presets, textures: textures}
  end

  defp sort_by_name(entries),
    do: Enum.sort_by(entries, fn {name, _} -> {UploadCheck.fold(name), name} end)

  defp usage_of(library) do
    sizes = Enum.map(Map.values(library.presets) ++ Map.values(library.textures), & &1.size)

    %{
      bytes: Enum.sum(sizes),
      presets: map_size(library.presets),
      textures: map_size(library.textures)
    }
  end

  defp sha_rows(library),
    do: for({name, meta} <- library.presets, do: {UploadCheck.preset_id(name), meta.sha256})

  defp shas(entries), do: Map.new(entries, fn {name, meta} -> {name, meta.sha256} end)

  defp library_key(:preset, name), do: UploadCheck.fold(name)
  defp library_key(:texture, name), do: UploadCheck.texture_key(name)

  defp section(:preset), do: :presets
  defp section(:texture), do: :textures

  defp subdir(:preset), do: "presets"
  defp subdir(:texture), do: "textures"

  defp count_key(:preset), do: :presets
  defp count_key(:texture), do: :textures

  defp sha(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp free_space(path) do
    case Mount.capacity(mount_point: path) do
      {:ok, %{total_bytes: total, free_bytes: free}} ->
        {:ok, %{total_bytes: total, free_bytes: free}}

      {:error, _reason} = error ->
        error
    end
  end

  # Texture names the renderer looks up in the pack first (it scans the
  # texture directory recursively).
  defp pack_textures do
    case Pack.status() do
      {:ready, _version, dir} ->
        [dir, "textures", "**", "*"]
        |> Path.join()
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> Enum.map(&Path.basename/1)

      _other ->
        []
    end
  end
end
