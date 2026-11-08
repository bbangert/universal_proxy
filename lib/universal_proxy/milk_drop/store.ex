defmodule UniversalProxy.MilkDrop.Store do
  @moduledoc """
  DETS-backed MilkDrop settings and the runtime skip list.

  Five records share one table:

    * `:settings` —

          %{
            include_high_frequency: boolean(),  # default false
            rotate_s: 10..120,                  # default 20
            min_fps: 20..max, step 5,           # default 20
            locked: String.t() | nil            # a preset id
          }

      `min_fps` is the frame rate a preset must hold; its maximum is
      `UniversalProxy.MilkDrop.max_min_fps/0` (30 on rpi3, 60 on rpi4/5).

    * `:skipped` — `{pack_version, %{preset_file => entry}}`: presets the
      renderer found it cannot draw (compile/draw failure, over budget at
      the last ladder rung, a GPU reset) or that were showing when the
      device went down (`device_reset`). An entry is the reason string,
      or `%{reason: reason, fps: fps}` when the renderer measured a frame
      rate (`budget`). Every write is synced to disk before it returns.
      Only one pack version is kept: recording a skip for a different
      version drops the old entries, and `skipped/2` for any other version
      reads as empty.

      A `budget` skip whose recorded fps holds the current minimum (with
      the renderer's 1 fps slack: `fps >= min_fps - 1`) is never kept:
      lowering `min_fps` drops those skips in the same write as the new
      settings, so those presets return from the next visualizer session,
      and a late skip measured under an earlier, higher minimum is not
      stored. `budget` skips without a recorded fps are kept.

    * `:user_skipped` — `%{id => %{reason:, fps:, sha256:}}`: skipped
      uploads (`user/` ids, which `skip/5` routes here), independent of
      the pack version. An entry counts only while the library file its
      id names has that SHA-256 (the `:user_sha` lookup, default
      `UniversalProxy.MilkDrop.UserPresets.sha256/1`), so a skip is
      effectively keyed by `{id, sha256}`: a replaced upload starts
      afresh, and entries for changed files are dropped on the next
      write. A skip for an id the library doesn't hold is not stored, nor
      one for content other than the library file's: `skip/5`'s
      `sha256:` and `mark_in_flight/5`'s name the content the renderer
      loaded, so a skip of an upload's old content, reported after the
      file was replaced (or recovered after a device reset), doesn't skip
      the replacement. Without them the file's current content counts.
      `skipped/2` and `skip_entries/2` return both lists, as does every
      `{:milkdrop_skipped, ...}` broadcast; the budget readmission above
      applies to both.

    * `:selection` — the preset selector's choices, independent of the
      pack version (a pack upgrade keeps them):

          %{
            gen: non_neg_integer(),         # bumped on every change
            favourites: [id],               # 3 tickets per rotation deal
            hidden: [id],                   # never rotate
            playlist: [id],                 # in the order added
            playlist_enabled: boolean()     # rotate only playlist ∩ eligible
          }

      Ids are pack-relative files or `user/` ids, kept whether or not the
      pack or the library holds them (an upload may come later). Each is
      a valid renderer preset id of at most 512 bytes (`valid_id?/1`), each list holds at most 5000 distinct ids, and
      the record's JSON (the renderer's `--selection-file`, which it reads
      up to 1 MiB) at most 768 KiB: an addition past a limit is refused
      (`{:error, :invalid_id | :too_many | :too_large}`); removals always
      go through. A change that
      changes nothing is not written and keeps `gen`. Deleted uploads
      leave it in the same write as their skips (`user_presets_removed/2`).

    * `:in_flight` — the preset the renderer was last told to load (see
      "Device resets" below).

  Values are sanitized on every read and write, so a corrupt or older
  record reads back as defaults. A file DETS reports as corrupt or
  unrepairable (not a DETS file, a failed repair) is moved aside to
  `<path>.corrupt` and a fresh table is opened.

  Any other open failure (permissions, missing directory, out of file
  descriptors) says nothing about the file's contents, so it is left
  untouched: the store stays up serving defaults, writes return
  `{:error, reason}`, and the open is retried before every write and on a
  timer (`:retry_ms`, default #{30_000}).

  ## Device resets

  On rpi3 some presets hang the vc4 GPU, and the kernel's hang recovery
  can take the whole device down (it reboots within ~7 s of
  `[drm] Resetting GPU.`). The renderer reports a reset it survives as a
  `gpu_hang` skip; a fatal one leaves no time for that. So
  `UniversalProxy.Display.MilkDrop` records each preset before the
  renderer loads it (`mark_in_flight/4`, `/5` with an upload's content
  hash; synced to disk before it returns).

  The record carries the Linux boot id (`/proc/sys/kernel/random/boot_id`).
  When the store opens a record written during an earlier boot, the device
  went down while that preset was loading or playing: the preset is added
  to the skip list with reason `device_reset` (if the record's pack version
  is the pinned one; an upload's whatever the version, so a hostile upload
  can't put the device in a reboot loop), a warning is logged and the
  record is deleted once that skip is on disk. If the skip can't be written the record is kept,
  and the recovery is retried before the next mark or clear (which are
  refused until it succeeds) and when the store next opens.

  The record belongs to the process that wrote it (its owner, the
  session's server), which the store monitors. It is deleted
  `:in_flight_grace_ms` (default #{30_000}) after its owner goes down,
  however it went down, or after the owner asks for it with
  `clear_in_flight/2` (the session ended cleanly while its server lives
  on), and only if it is still the same record then (every mark carries a
  unique `generation`, so a re-mark of the same preset within the same
  second is not mistaken for the cleared one). The grace period is there
  because a renderer stuck on a hung GPU can still exit "cleanly" (its
  exit watchdog) in the seconds before the device dies.

  The pending clear is persisted with the record (a wall-clock deadline and
  the boot id), so a store that restarts during the grace period in the
  same boot still clears it: at the deadline, or at once if that has passed
  (a clock step can't push it past one grace period from the restart). A
  store that restarts in the same boot also checks the owner it finds in
  the record: a live one is monitored again, a dead one (or one from
  another VM run) starts a full grace period. While the table can't be
  opened, marks and clears are refused but kept in memory and applied when
  it opens. An orderly shutdown of the store (`:normal`, `:shutdown`: a
  reboot or firmware update) deletes the record at once, since that is
  not a device reset.

  Accepted false positive: a power cut while a preset is loading or
  playing skips that one preset. "Clear skipped presets" in the web UI
  (`clear_skipped/1`) brings it back.

  The record is written on each preset change (about every 20 s by
  default, `rotate_s`) and once more when its owner ends, so its flash
  wear is negligible.

  Changes are broadcast on `UniversalProxy.MilkDrop.settings_topic/0`, the
  selection's (`{:milkdrop_selection, selection}`, the whole record) on
  `UniversalProxy.MilkDrop.selection_topic/0` (see `UniversalProxy.MilkDrop`).

  The public API follows the `catch :exit` idiom for optional subsystems:
  while the store is not running reads return defaults and writes
  `{:error, :not_running}`.

  The DETS file lives at `<UniversalProxy.MilkDrop.root()>/settings.dets`
  (`/data/milkdrop/settings.dets` on Nerves). Tests override via the
  `:dets_path`, `:table`, `:name` and `:pubsub` opts to `start_link/1`
  (and `:boot_id`, `:vm`, `:pack_version`, `:in_flight_grace_ms`,
  `:retry_ms`, `:insert`, a stand-in for `:dets.insert/2`, and
  `:user_sha`, a 1-arity fun from a `user/` id to its library file's
  SHA-256 or `nil`).
  """

  use GenServer

  require Logger

  alias UniversalProxy.Audio.Params
  alias UniversalProxy.MilkDrop
  alias UniversalProxy.MilkDrop.UserPresets

  @default_table :milkdrop_settings
  @retry_ms 30_000
  @in_flight_grace_ms 30_000
  @boot_id_path "/proc/sys/kernel/random/boot_id"
  @in_flight_keys [
    :pack_version,
    :preset,
    :at,
    :session,
    :owner,
    :boot_id,
    :generation,
    :clear_at,
    :sha256
  ]

  @rotate_min 10
  @rotate_max 120

  @min_fps_min 20
  @min_fps_step 5
  # The renderer accepts a window at one under the minimum (see its README,
  # "Cost guard").
  @min_fps_slack 1

  @defaults %{include_high_frequency: false, rotate_s: 20, min_fps: @min_fps_min, locked: nil}

  @keys Map.keys(@defaults)

  @empty_selection %{gen: 0, favourites: [], hidden: [], playlist: [], playlist_enabled: false}
  @selection_lists [:favourites, :hidden, :playlist]
  @max_id_bytes 512
  # UTF-8 continuation and lead bytes are all >= 0x80, so a byte scan is exact.
  @control_bytes Enum.map(Enum.to_list(0..31) ++ [127], &<<&1>>)
  @max_selection_ids 5000
  # The renderer reads at most 1 MiB of --selection-file.
  @max_selection_bytes 768 * 1024

  @type settings :: %{
          include_high_frequency: boolean(),
          rotate_s: 10..120,
          min_fps: pos_integer(),
          locked: String.t() | nil
        }

  @type skipped :: %{String.t() => String.t()}

  @type selection :: %{
          gen: non_neg_integer(),
          favourites: [String.t()],
          hidden: [String.t()],
          playlist: [String.t()],
          playlist_enabled: boolean()
        }

  @type selection_error :: :invalid_id | :too_many | :too_large | term()

  @type skip_entry :: %{reason: String.t(), fps: float() | nil}

  @type user_skip_entry :: %{reason: String.t(), fps: float() | nil, sha256: String.t()}

  @type in_flight :: %{
          pack_version: String.t(),
          preset: String.t(),
          at: integer(),
          session: term(),
          owner: pid() | nil,
          boot_id: String.t() | nil,
          generation: term(),
          clear_at: integer() | nil,
          sha256: String.t() | nil
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

  @doc "Compile-time defaults, for defensive callers."
  @spec defaults() :: settings()
  def defaults, do: @defaults

  @doc "The current settings (defaults while the store is not running)."
  @spec settings(GenServer.server()) :: settings()
  def settings(server \\ __MODULE__) do
    GenServer.call(server, :settings)
  catch
    :exit, _ -> @defaults
  end

  @doc """
  Merge `params` (atom or string keys; unknown keys dropped) into the
  settings and persist. `rotate_s` is clamped to #{@rotate_min}..#{@rotate_max};
  `min_fps` to the nearest of `min_fps_options/0`; a wrongly-typed value
  keeps the saved one. A lower `min_fps` drops the `budget` skips it lets
  back in, in the same write (see the moduledoc): on an error neither is
  saved. Returns the new settings.
  """
  @spec update(GenServer.server(), map()) :: {:ok, settings()} | {:error, term()}
  def update(server \\ __MODULE__, params) when is_map(params) do
    GenServer.call(server, {:update, params})
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc "The `min_fps` values this board offers: 20 up to `UniversalProxy.MilkDrop.max_min_fps/0` in steps of 5."
  @spec min_fps_options() :: [pos_integer()]
  def min_fps_options,
    do: Enum.to_list(@min_fps_min..max_min_fps()//@min_fps_step)

  @doc """
  Record that `preset` (a pack-relative file) cannot be drawn with pack
  `version`, for `reason`. A different `version` than the stored one
  replaces the whole skip list. An upload's `user/` id is recorded for
  its current content instead, whatever `version` (see the moduledoc).
  See `skip/5` to record a measured fps.
  """
  @spec skip(GenServer.server(), String.t(), String.t(), String.t() | atom()) ::
          :ok | {:error, term()}
  def skip(server \\ __MODULE__, version, preset, reason),
    do: skip(server, version, preset, reason, [])

  @doc """
  `skip/4` with options: `fps:` — the frame rate the renderer measured
  (with a `budget` skip), kept so a lower `min_fps` can bring it back. A
  `budget` skip whose fps already holds the current `min_fps` (measured
  under an earlier, higher one) is not stored, and returns `:ok`.
  `sha256:` — for an upload, the content the renderer loaded; a skip for
  content the library no longer holds is not stored (and returns `:ok`).
  """
  @spec skip(GenServer.server(), String.t(), String.t(), String.t() | atom(), keyword()) ::
          :ok | {:error, term()}
  def skip(server, version, preset, reason, opts)
      when is_binary(version) and is_binary(preset) and is_list(opts) do
    entry = skip_entry(reason_string(reason), Keyword.get(opts, :fps))
    GenServer.call(server, {:skip, version, preset, entry, Keyword.get(opts, :sha256)})
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc """
  The skip list for pack `version` (none for any version but the stored
  one), plus the skipped uploads whose files are unchanged.
  """
  @spec skipped(GenServer.server(), String.t()) :: skipped()
  def skipped(server \\ __MODULE__, version) when is_binary(version) do
    server |> skip_entries(version) |> Map.new(fn {preset, %{reason: r}} -> {preset, r} end)
  end

  @doc """
  `skipped/2` with each entry's recorded fps (`nil` when none was
  measured).
  """
  @spec skip_entries(GenServer.server(), String.t()) :: %{String.t() => skip_entry()}
  def skip_entries(server \\ __MODULE__, version) when is_binary(version) do
    GenServer.call(server, {:skipped, version})
  catch
    :exit, _ -> %{}
  end

  @doc "Forget every skipped preset, uploads included."
  @spec clear_skipped(GenServer.server()) :: :ok | {:error, term()}
  def clear_skipped(server \\ __MODULE__) do
    GenServer.call(server, :clear_skipped)
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc "Forget the skips of these uploads (`user/` ids): their content changed."
  @spec clear_user_skips(GenServer.server(), [String.t()]) :: :ok | {:error, term()}
  def clear_user_skips(server \\ __MODULE__, ids) when is_list(ids) do
    GenServer.call(server, {:forget_user, ids, false})
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc """
  These uploads (`user/` ids) were deleted: forget their skips, the
  `locked` setting if it names one of them, and their favourite, hidden
  and playlist entries, in one write.
  """
  @spec user_presets_removed(GenServer.server(), [String.t()]) :: :ok | {:error, term()}
  def user_presets_removed(server \\ __MODULE__, ids) when is_list(ids) do
    GenServer.call(server, {:forget_user, ids, true})
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc "The empty selection (`gen` 0), what `selection/1` reads while the store is not running."
  @spec empty_selection() :: selection()
  def empty_selection, do: @empty_selection

  @doc """
  Whether `id` can be stored in the selection or sent to the renderer:
  the renderer's preset-id rule (a relative path ending in `.milk`, no
  `.`, `..` or empty segment, valid UTF-8 without control characters),
  at most #{@max_id_bytes} bytes. Says nothing about whether a preset has
  that id.
  """
  @spec valid_id?(term()) :: boolean()
  def valid_id?(id) when is_binary(id) and byte_size(id) in 1..@max_id_bytes do
    String.valid?(id) and :binary.match(id, @control_bytes) == :nomatch and
      String.ends_with?(id, ".milk") and
      not Enum.any?(String.split(id, "/"), &(&1 in ["", ".", ".."]))
  end

  def valid_id?(_id), do: false

  @doc "The preset selection (see the moduledoc; `empty_selection/0` while the store is not running)."
  @spec selection(GenServer.server()) :: selection()
  def selection(server \\ __MODULE__) do
    GenServer.call(server, :selection)
  catch
    :exit, _ -> @empty_selection
  end

  @doc "Favourite (or unfavourite) preset `id`. Returns the new selection."
  @spec favourite(GenServer.server(), String.t(), boolean()) ::
          {:ok, selection()} | {:error, selection_error()}
  def favourite(server \\ __MODULE__, id, flag) when is_boolean(flag),
    do: change_selection(server, id, {:favourites, id, flag})

  @doc "Hide (or unhide) preset `id` from the rotation. Returns the new selection."
  @spec hide(GenServer.server(), String.t(), boolean()) ::
          {:ok, selection()} | {:error, selection_error()}
  def hide(server \\ __MODULE__, id, flag) when is_boolean(flag),
    do: change_selection(server, id, {:hidden, id, flag})

  @doc "Append preset `id` to the playlist (kept where it is if already there)."
  @spec playlist_add(GenServer.server(), String.t()) ::
          {:ok, selection()} | {:error, selection_error()}
  def playlist_add(server \\ __MODULE__, id),
    do: change_selection(server, id, {:playlist, id, true})

  @doc "Remove preset `id` from the playlist."
  @spec playlist_remove(GenServer.server(), String.t()) ::
          {:ok, selection()} | {:error, selection_error()}
  def playlist_remove(server \\ __MODULE__, id),
    do: change_selection(server, id, {:playlist, id, false})

  @doc "Empty the playlist (`playlist_enabled` stays as it is)."
  @spec playlist_clear(GenServer.server()) :: {:ok, selection()} | {:error, selection_error()}
  def playlist_clear(server \\ __MODULE__), do: selection_call(server, :playlist_clear)

  @doc "Rotate only through the playlist (or not)."
  @spec set_playlist_enabled(GenServer.server(), boolean()) ::
          {:ok, selection()} | {:error, selection_error()}
  def set_playlist_enabled(server \\ __MODULE__, flag) when is_boolean(flag),
    do: selection_call(server, {:playlist_enabled, flag})

  defp change_selection(server, id, change) do
    if valid_id?(id), do: selection_call(server, change), else: {:error, :invalid_id}
  end

  defp selection_call(server, change) do
    GenServer.call(server, {:selection, change})
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc """
  Record that `session` (a renderer session) is about to load `preset` of
  pack `version`, replacing any earlier record. The calling process owns
  the record: it is cleared a grace period after the caller goes down. The
  write is synced to disk before this returns. See "Device resets".
  """
  @spec mark_in_flight(GenServer.server(), term(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def mark_in_flight(server \\ __MODULE__, session, version, preset)
      when is_binary(version) and is_binary(preset) do
    mark_in_flight(server, session, version, preset, [])
  end

  @doc """
  `mark_in_flight/4` with options: `sha256:` — for an upload, the content
  being loaded, so a device reset skips that content only (see the
  moduledoc's `:user_skipped`).
  """
  @spec mark_in_flight(GenServer.server(), term(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def mark_in_flight(server, session, version, preset, opts)
      when is_binary(version) and is_binary(preset) and is_list(opts) do
    GenServer.call(
      server,
      {:mark_in_flight, session, version, preset, Keyword.get(opts, :sha256)}
    )
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc """
  `session` ended: its in-flight record is deleted `:in_flight_grace_ms`
  from now, if it is still the same record then. Another session's record
  is left alone. An error means the clear is not on disk yet; the store
  still clears the record once its owner goes down.
  """
  @spec clear_in_flight(GenServer.server(), term()) :: :ok | {:error, term()}
  def clear_in_flight(server \\ __MODULE__, session) do
    GenServer.call(server, {:clear_in_flight, session})
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc "The in-flight record, or `nil` (also while the store is not running)."
  @spec in_flight(GenServer.server()) :: in_flight() | nil
  def in_flight(server \\ __MODULE__) do
    GenServer.call(server, :in_flight)
  catch
    :exit, _ -> nil
  end

  # -- Server callbacks --

  @impl true
  def init(opts) do
    # Trap exits so terminate/2 runs on a supervisor shutdown too (not only
    # on a crash) and closes the DETS table cleanly.
    Process.flag(:trap_exit, true)

    table_name = Keyword.get(opts, :table, @default_table)
    path = Keyword.get(opts, :dets_path) || Path.join(MilkDrop.root(), "settings.dets")
    pubsub = Keyword.get(opts, :pubsub, UniversalProxy.PubSub)

    state = %{
      table: nil,
      table_name: table_name,
      path: path,
      pubsub: pubsub,
      retry_ms: Keyword.get(opts, :retry_ms, @retry_ms),
      retry_timer: nil,
      open_error: nil,
      boot_id: Keyword.get_lazy(opts, :boot_id, &read_boot_id/0),
      # Tells this store's marks from those of another VM run in the same
      # boot (unique_integer/1 starts over with the VM).
      incarnation: :crypto.strong_rand_bytes(8),
      # Tells this VM's pids from those another VM run left in the record.
      vm: Keyword.get_lazy(opts, :vm, fn -> List.to_string(:os.getpid()) end),
      pack_version: Keyword.get_lazy(opts, :pack_version, &pinned_version/0),
      in_flight_grace_ms: Keyword.get(opts, :in_flight_grace_ms, @in_flight_grace_ms),
      insert: Keyword.get(opts, :insert, &:dets.insert/2),
      user_sha: Keyword.get(opts, :user_sha, &UserPresets.sha256/1),
      # `{pid, ref}` of the monitored owner of the in-flight record.
      owner: nil,
      # Asked for while the table was closed, applied when it opens.
      pending_mark: nil,
      pending_clears: %{},
      # false while an earlier boot's record could not be recorded as a skip.
      recovered?: true
    }

    case open_table(state) do
      {:ok, state} -> {:ok, state}
      {:error, state} -> {:ok, schedule_retry(state)}
    end
  end

  @impl true
  def terminate(_reason, %{table: nil}), do: :ok

  def terminate(reason, %{table: table} = state) do
    if orderly?(reason) and state.recovered?, do: _ = :dets.delete(table, :in_flight)
    :dets.close(table)
  end

  @impl true
  def handle_info(:retry_open, %{table: nil} = state) do
    case open_table(%{state | retry_timer: nil}) do
      {:ok, state} -> {:noreply, state}
      {:error, state} -> {:noreply, schedule_retry(state)}
    end
  end

  def handle_info({:clear_in_flight, generation}, %{table: table} = state) when table != nil do
    case read_in_flight(table) do
      %{generation: ^generation} -> delete_in_flight(table)
      _other -> :ok
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, %{owner: {pid, ref}} = state) do
    state = %{state | owner: nil}
    _ = owner_down(state, pid)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:settings, _from, state) do
    {:reply, read_settings(state.table), state}
  end

  def handle_call(:selection, _from, state) do
    {:reply, read_selection(state.table), state}
  end

  def handle_call(:in_flight, _from, state) do
    reply =
      case read_in_flight(state.table) do
        nil -> nil
        marker -> Map.take(marker, @in_flight_keys)
      end

    {:reply, reply, state}
  end

  # A mark or clear refused here is kept and applied when the table opens.
  def handle_call(request, from, %{table: nil} = state)
      when request == :clear_skipped or
             (is_tuple(request) and
                elem(request, 0) in [
                  :update,
                  :skip,
                  :selection,
                  :forget_user,
                  :mark_in_flight,
                  :clear_in_flight
                ]) do
    case open_table(state) do
      {:ok, state} ->
        handle_call(request, from, state)

      {:error, state} ->
        state = queue_closed(request, from, state)
        {:reply, {:error, state.open_error}, schedule_retry(state)}
    end
  end

  def handle_call({:clear_in_flight, session}, _from, state) do
    case ensure_recovered(state) do
      {:ok, state} -> {:reply, clear_session(state, session), state}
      {error, state} -> {:reply, error, state}
    end
  end

  # The settings and the skip list they readmit from are one write, so a
  # failure leaves both as they were and a retry readmits again.
  def handle_call({:update, params}, _from, state) do
    existing = read_settings(state.table)
    merged = merge(existing, params)
    readmission = readmission(state, merged.min_fps)

    case persist(state, [{:settings, merged} | readmission_records(readmission)]) do
      :ok ->
        if merged != existing, do: broadcast(state, {:milkdrop_settings, merged})
        announce_readmission(state, merged.min_fps, readmission)
        {:reply, {:ok, merged}, state}

      {:error, reason} ->
        Logger.error("MilkDrop store settings update failed: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:skip, version, preset, reason, sha}, _from, state) do
    {:reply, add_skip(state, version, preset, reason, sha), state}
  end

  def handle_call({:forget_user, ids, removed?}, _from, state) do
    {:reply, forget_user(state, ids, removed?), state}
  end

  def handle_call({:selection, change}, _from, state) do
    existing = read_selection(state.table)

    reply =
      case apply_selection(existing, change) do
        {:ok, ^existing} ->
          {:ok, existing}

        {:ok, changed} ->
          with :ok <- check_selection_size(change, changed),
               do: save_selection(state, %{changed | gen: existing.gen + 1})

        {:error, _reason} = error ->
          error
      end

    {:reply, reply, state}
  end

  def handle_call({:mark_in_flight, session, version, preset, sha}, {owner, _tag}, state) do
    marker = new_marker(state, owner, session, version, preset, sha)

    with {:ok, state} <- ensure_recovered(state),
         :ok <- persist(state, {:in_flight, marker}) do
      {:reply, :ok, monitor_owner(state, owner)}
    else
      {{:error, _reason} = error, state} ->
        {:reply, error, state}

      {:error, reason} = error ->
        Logger.error("MilkDrop store in-flight write failed: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  def handle_call({:skipped, version}, _from, state) do
    {:reply, all_skips(state, version), state}
  end

  def handle_call(:clear_skipped, _from, state) do
    with :ok <- :dets.delete(state.table, :skipped),
         :ok <- :dets.delete(state.table, :user_skipped),
         :ok <- :dets.sync(state.table) do
      broadcast(state, {:milkdrop_skipped, nil, %{}})
      {:reply, :ok, state}
    else
      {:error, reason} = error ->
        Logger.error("MilkDrop store clear_skipped failed: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  # -- Private --

  # Opens the table into `state`. On failure the state stays closed
  # (`table: nil`) with `open_error` set.
  defp open_table(%{table_name: table_name, path: path} = state) do
    with :ok <- mkdir_p(path),
         {:ok, table} <- open(table_name, path) do
      Logger.info("MilkDrop store opened at #{path}")
      {:ok, recover_in_flight(%{state | table: table, open_error: nil})}
    else
      {:error, reason} ->
        Logger.warning(
          "MilkDrop store could not open #{path}: #{inspect(reason)}; " <>
            "serving defaults until it can"
        )

        {:error, %{state | open_error: reason}}
    end
  end

  defp schedule_retry(%{retry_timer: nil, retry_ms: ms} = state) when is_integer(ms) and ms > 0,
    do: %{state | retry_timer: Process.send_after(self(), :retry_open, ms)}

  defp schedule_retry(state), do: state

  defp open(table_name, path) do
    case dets_open(table_name, path) do
      {:ok, table} ->
        {:ok, table}

      {:error, reason} = error ->
        if corrupt?(reason), do: move_aside(table_name, path, reason), else: error
    end
  end

  # A repair that crashes inside DETS (a truncated file) comes back as a
  # bare `{:EXIT, _}`, which is missing from its specs.
  @dialyzer {:nowarn_function, dets_open: 2}
  defp dets_open(table_name, path) do
    case :dets.open_file(table_name, file: to_charlist(path), type: :set) do
      {:ok, _table} = ok -> ok
      {:error, _reason} = error -> error
      other -> {:error, {:dets_crash, other}}
    end
  end

  # Only reasons that describe the file itself. `{:file_error, _, posix}`
  # (:eacces, :enoent, :emfile, ...) is operational: the file may be fine.
  defp corrupt?({:not_a_dets_file, _}), do: true
  defp corrupt?({:needs_repair, _}), do: true
  defp corrupt?({:bad_freelist, _}), do: true
  defp corrupt?({:bad_object, _}), do: true
  defp corrupt?({:dets_crash, _}), do: true
  defp corrupt?(:bad_object), do: true
  defp corrupt?(_reason), do: false

  defp move_aside(table_name, path, reason) do
    aside = path <> ".corrupt"

    Logger.warning(
      "MilkDrop store could not open #{path} (#{inspect(reason)}); " <>
        "moving it to #{aside} and starting from defaults"
    )

    with :ok <- File.rename(path, aside), do: dets_open(table_name, path)
  end

  defp mkdir_p(path), do: File.mkdir_p(Path.dirname(path))

  # `sha`: the upload content the skip is for (nil: whatever is installed).
  defp add_skip(state, version, preset, reason, sha) do
    min_fps = read_settings(state.table).min_fps

    cond do
      readmitted?(reason, min_fps) ->
        Logger.info(
          "MilkDrop: #{preset} holds the minimum frame rate #{min_fps} " <>
            "(#{reason.fps} fps); not skipping it"
        )

        :ok

      user_id?(preset) ->
        store_user_skip(state, preset, reason, sha)

      true ->
        store_skip(state, version, preset, reason)
    end
  end

  defp store_skip(state, version, preset, reason) do
    skipped =
      case read_skipped(state.table) do
        {^version, entries} -> Map.put(entries, preset, reason)
        _ -> %{preset => reason}
      end

    case persist(state, {:skipped, {version, skipped}}) do
      :ok ->
        broadcast_skipped(state, version)
        :ok

      {:error, reason} = error ->
        Logger.error("MilkDrop store skip update failed: #{inspect(reason)}")
        error
    end
  end

  # The records to write when budget skips measured at or above `min_fps`
  # (with the renderer's slack) are to be dropped, and how many go; nil
  # when none do. Those without a recorded fps stay.
  defp readmission(state, min_fps) do
    pack =
      case read_skipped(state.table) do
        {version, entries} -> readmit(entries, min_fps, &{:skipped, {version, &1}})
        nil -> nil
      end

    user = readmit(read_user_skipped(state.table), min_fps, &{:user_skipped, &1})

    case Enum.reject([pack, user], &is_nil/1) do
      [] -> nil
      parts -> {Enum.map(parts, &elem(&1, 0)), parts |> Enum.map(&elem(&1, 1)) |> Enum.sum()}
    end
  end

  defp readmit(entries, min_fps, record) do
    kept = Map.reject(entries, fn {_preset, e} -> readmitted?(e, min_fps) end)
    cleared = map_size(entries) - map_size(kept)
    if cleared > 0, do: {record.(kept), cleared}
  end

  defp readmission_records(nil), do: []
  defp readmission_records({records, _cleared}), do: records

  defp announce_readmission(_state, _min_fps, nil), do: :ok

  defp announce_readmission(state, min_fps, {_records, cleared}) do
    Logger.info("MilkDrop: minimum frame rate #{min_fps}: #{cleared} budget skip(s) cleared")

    case read_skipped(state.table) do
      {version, _entries} -> broadcast_skipped(state, version)
      nil -> broadcast_skipped(state, skip_version(state))
    end
  end

  # The renderer's own rule: a window holds `min_fps` at `min_fps - slack`
  # or more. The fps it reports is rounded down, so this never readmits a
  # preset the renderer would skip again.
  defp readmitted?(%{reason: "budget", fps: fps}, min_fps) when is_number(fps),
    do: fps >= min_fps - @min_fps_slack

  defp readmitted?(_entry, _min_fps), do: false

  # Both lists, as `skipped/2` reads them.
  defp broadcast_skipped(state, version) do
    reasons = Map.new(all_skips(state, version), fn {preset, e} -> {preset, e.reason} end)
    broadcast(state, {:milkdrop_skipped, version, reasons})
  end

  defp all_skips(state, version) do
    pack =
      case read_skipped(state.table) do
        {^version, entries} -> Map.new(entries, fn {p, e} -> {p, entry_details(e)} end)
        _ -> %{}
      end

    state
    |> current_user_skips()
    |> Map.new(fn {id, e} -> {id, Map.take(e, [:reason, :fps])} end)
    |> Map.merge(pack)
  end

  # The version a broadcast of user-skip changes is for: the pinned pack's,
  # else the stored list's.
  defp skip_version(state) do
    case {state.pack_version, read_skipped(state.table)} do
      {nil, {version, _entries}} -> version
      {version, _} -> version
    end
  end

  # -- Private: upload skips --

  defp user_id?("user/" <> _), do: true
  defp user_id?(_preset), do: false

  defp store_user_skip(state, id, reason, loaded) do
    case state.user_sha.(id) do
      nil ->
        Logger.info("MilkDrop: #{id} is not in the upload library; not skipping it")
        :ok

      sha when is_binary(loaded) and loaded != sha ->
        Logger.info("MilkDrop: #{id} was replaced since it was loaded; not skipping it")
        :ok

      sha ->
        entry = reason |> entry_details() |> Map.put(:sha256, sha)
        entries = state |> current_user_skips() |> Map.put(id, entry)
        persist_user_skips(state, entries, [], "skip update")
    end
  end

  # Skips of these ids go, and with `removed?` (the uploads are gone) the
  # lock if it names one and their selection entries.
  defp forget_user(state, ids, removed?) do
    entries = read_user_skipped(state.table)
    kept = state |> current_user_skips() |> Map.drop(ids)
    settings = read_settings(state.table)
    unlock? = removed? and settings.locked in ids
    selection = read_selection(state.table)
    pruned = if removed?, do: drop_selected(selection, ids), else: selection
    reselect? = pruned != selection
    pruned = %{pruned | gen: if(reselect?, do: selection.gen + 1, else: selection.gen)}

    records =
      if(unlock?, do: [{:settings, %{settings | locked: nil}}], else: []) ++
        if reselect?, do: [{:selection, pruned}], else: []

    if kept == entries and records == [] do
      :ok
    else
      with :ok <- persist_user_skips(state, kept, records, "upload clean-up") do
        if unlock?, do: broadcast(state, {:milkdrop_settings, %{settings | locked: nil}})
        if reselect?, do: broadcast_selection(state, pruned)
        :ok
      end
    end
  end

  defp persist_user_skips(state, entries, records, what) do
    case persist(state, [{:user_skipped, entries} | records]) do
      :ok ->
        broadcast_skipped(state, skip_version(state))
        :ok

      {:error, reason} = error ->
        Logger.error("MilkDrop store #{what} failed: #{inspect(reason)}")
        error
    end
  end

  # The entries whose library file still has the recorded content.
  defp current_user_skips(state) do
    Map.filter(read_user_skipped(state.table), fn {id, %{sha256: sha}} ->
      state.user_sha.(id) == sha
    end)
  end

  # -- Private: selection --

  defp apply_selection(selection, {list, id, true}) do
    ids = Map.fetch!(selection, list)

    cond do
      id in ids -> {:ok, selection}
      length(ids) >= @max_selection_ids -> {:error, :too_many}
      true -> {:ok, %{selection | list => ids ++ [id]}}
    end
  end

  defp apply_selection(selection, {list, id, false}),
    do: {:ok, Map.update!(selection, list, &List.delete(&1, id))}

  defp apply_selection(selection, :playlist_clear), do: {:ok, %{selection | playlist: []}}

  defp apply_selection(selection, {:playlist_enabled, flag}),
    do: {:ok, %{selection | playlist_enabled: flag}}

  defp drop_selected(selection, ids) do
    drop = MapSet.new(ids)

    Enum.reduce(@selection_lists, selection, fn list, acc ->
      Map.update!(acc, list, fn kept -> Enum.reject(kept, &MapSet.member?(drop, &1)) end)
    end)
  end

  defp save_selection(state, selection) do
    case persist(state, {:selection, selection}) do
      :ok ->
        broadcast_selection(state, selection)
        {:ok, selection}

      {:error, reason} = error ->
        Logger.error("MilkDrop store selection update failed: #{inspect(reason)}")
        error
    end
  end

  # Only an addition can grow the renderer's file (`UniversalProxy.Display.MilkDrop`
  # writes these five keys as they are), so a removal always goes through.
  defp check_selection_size({_list, _id, true}, selection) do
    if IO.iodata_length(Jason.encode_to_iodata!(selection)) <= @max_selection_bytes,
      do: :ok,
      else: {:error, :too_large}
  end

  defp check_selection_size(_change, _selection), do: :ok

  defp broadcast_selection(state, selection) do
    Phoenix.PubSub.broadcast(
      state.pubsub,
      MilkDrop.selection_topic(),
      {:milkdrop_selection, selection}
    )
  end

  defp read_selection(nil), do: @empty_selection

  defp read_selection(table) do
    case :dets.lookup(table, :selection) do
      [{:selection, stored}] when is_map(stored) -> sanitize_selection(stored)
      _ -> @empty_selection
    end
  end

  defp sanitize_selection(stored) do
    gen = if is_integer(stored[:gen]) and stored[:gen] >= 0, do: stored.gen, else: 0
    enabled? = stored[:playlist_enabled] == true

    Enum.reduce(@selection_lists, %{@empty_selection | gen: gen, playlist_enabled: enabled?}, fn
      list, acc -> %{acc | list => sanitize_ids(stored[list])}
    end)
  end

  defp sanitize_ids(ids) when is_list(ids),
    do: ids |> Enum.filter(&valid_id?/1) |> Enum.uniq() |> Enum.take(@max_selection_ids)

  defp sanitize_ids(_ids), do: []

  defp new_marker(state, owner, session, version, preset, sha) do
    %{
      sha256: sha,
      pack_version: version,
      preset: preset,
      at: System.os_time(:second),
      session: session,
      owner: owner,
      vm: state.vm,
      boot_id: state.boot_id,
      generation: {state.incarnation, System.unique_integer([:monotonic, :positive])}
    }
  end

  defp queue_closed({:mark_in_flight, session, version, preset, sha}, {owner, _tag}, state) do
    marker = new_marker(state, owner, session, version, preset, sha)
    pending_clears = Map.delete(state.pending_clears, session)
    monitor_owner(%{state | pending_mark: marker, pending_clears: pending_clears}, owner)
  end

  defp queue_closed({:clear_in_flight, session}, _from, state) do
    clear_at = System.os_time(:millisecond) + state.in_flight_grace_ms
    %{state | pending_clears: Map.put(state.pending_clears, session, clear_at)}
  end

  defp queue_closed(_request, _from, state), do: state

  defp monitor_owner(%{owner: {owner, _ref}} = state, owner), do: state

  defp monitor_owner(state, owner) do
    with {_old, ref} <- state.owner, do: Process.demonitor(ref, [:flush])
    %{state | owner: {owner, Process.monitor(owner)}}
  end

  # Run on every open: the earlier boot's record first, then what was asked
  # for while the table was closed, then the same-boot record's owner.
  defp recover_in_flight(state) do
    %{pending_mark: mark, pending_clears: clears} = state
    state = %{state | pending_mark: nil, pending_clears: %{}}

    case consume_in_flight(state) do
      :ok ->
        state = %{state | recovered?: true}
        apply_pending_mark(state, mark)
        reconcile(state, clears)

      {:error, _reason} ->
        %{state | recovered?: false}
    end
  end

  defp ensure_recovered(%{recovered?: true} = state), do: {:ok, state}

  defp ensure_recovered(state) do
    case consume_in_flight(state) do
      :ok -> {:ok, %{state | recovered?: true}}
      {:error, _reason} = error -> {error, state}
    end
  end

  # A record from an earlier boot names the preset that was loading or
  # playing when the device went down; it is deleted only once its skip is
  # on disk. A record from this boot is left for `reconcile/2`. An
  # unreadable boot id on either side counts as an earlier boot.
  defp consume_in_flight(%{table: table} = state) do
    case read_in_flight(table) do
      nil ->
        if :dets.member(table, :in_flight), do: _ = delete_in_flight(table)
        :ok

      %{boot_id: boot_id} when boot_id != nil and boot_id == state.boot_id ->
        :ok

      %{pack_version: version, preset: preset} = marker ->
        if is_nil(state.pack_version) or state.pack_version == version or user_id?(preset) do
          Logger.warning(
            "MilkDrop preset #{preset} was running when the device last stopped; skipping it"
          )

          record_device_reset(state, version, preset, marker.sha256)
        else
          Logger.info(
            "MilkDrop preset #{preset} (pack #{version}) was running when the device last " <>
              "stopped; that pack is no longer pinned"
          )

          delete_in_flight(table)
        end
    end
  end

  defp record_device_reset(state, version, preset, sha) do
    case add_skip(state, version, preset, "device_reset", sha) do
      :ok ->
        delete_in_flight(state.table)

      {:error, reason} = error ->
        Logger.error(
          "MilkDrop store could not record #{preset} as device_reset (#{inspect(reason)}); " <>
            "keeping its in-flight record to retry"
        )

        error
    end
  end

  defp apply_pending_mark(_state, nil), do: :ok

  defp apply_pending_mark(state, marker) do
    with {:error, reason} = error <- persist(state, {:in_flight, marker}) do
      Logger.error("MilkDrop store in-flight write failed: #{inspect(reason)}")
      error
    end
  end

  # The same-boot record after a (re)open: a persisted pending clear resumes,
  # a clear asked for while closed starts, a live owner is monitored again
  # and a dead one (or one from another VM run) starts a full grace period.
  defp reconcile(state, clears) do
    case read_in_flight(state.table) do
      nil ->
        state

      %{clear_at: at, clear_boot_id: boot_id} = marker
      when is_integer(at) and boot_id == state.boot_id ->
        _ = start_clear(state, marker, remaining(state, at), persist: false)
        state

      %{session: session} = marker when is_map_key(clears, session) ->
        _ = start_clear(state, marker, remaining(state, Map.fetch!(clears, session)))
        state

      %{owner: owner} = marker ->
        if owner_alive?(state, marker) do
          monitor_owner(state, owner)
        else
          _ = start_clear(state, marker, state.in_flight_grace_ms)
          state
        end
    end
  end

  defp owner_down(%{table: nil}, _owner), do: :ok

  defp owner_down(state, owner) do
    case read_in_flight(state.table) do
      %{owner: ^owner, clear_at: nil} = marker ->
        if own?(state, marker), do: start_clear(state, marker, state.in_flight_grace_ms)

      _other ->
        :ok
    end
  end

  defp clear_session(state, session) do
    case read_in_flight(state.table) do
      %{session: ^session, clear_at: nil} = marker ->
        start_clear(state, marker, state.in_flight_grace_ms)

      _other ->
        :ok
    end
  end

  defp own?(state, marker),
    do: state.recovered? and marker.boot_id == state.boot_id and marker.vm == state.vm

  defp owner_alive?(state, %{owner: owner} = marker) do
    is_pid(owner) and node(owner) == node() and own?(state, marker) and Process.alive?(owner)
  end

  # The wall clock can step (NTP on a board without an RTC): the remaining
  # wait is capped at one grace period.
  defp remaining(state, clear_at),
    do: min(clear_at - System.os_time(:millisecond), state.in_flight_grace_ms)

  # Deletes `marker` after `ms` if it is still the record then; the
  # deadline is persisted with it unless it already is.
  defp start_clear(state, marker, ms, opts \\ [])

  defp start_clear(state, _marker, ms, _opts) when ms <= 0, do: delete_in_flight(state.table)

  defp start_clear(state, marker, ms, opts) do
    Process.send_after(self(), {:clear_in_flight, marker.generation}, ms)

    if Keyword.get(opts, :persist, true) do
      pending = %{
        marker
        | clear_at: System.os_time(:millisecond) + ms,
          clear_boot_id: state.boot_id
      }

      with {:error, reason} = error <- persist(state, {:in_flight, pending}) do
        Logger.error("MilkDrop store in-flight clear write failed: #{inspect(reason)}")
        error
      end
    else
      :ok
    end
  end

  defp read_in_flight(nil), do: nil

  defp read_in_flight(table) do
    case :dets.lookup(table, :in_flight) do
      [{:in_flight, %{pack_version: v, preset: p, at: at, boot_id: b} = marker}]
      when is_binary(v) and is_binary(p) and is_integer(at) and (is_binary(b) or is_nil(b)) and
             is_map_key(marker, :session) ->
        marker
        |> Map.put_new(:generation, nil)
        |> Map.update(:owner, nil, &if(is_pid(&1), do: &1))
        |> Map.put_new(:vm, nil)
        |> Map.update(:clear_at, nil, &if(is_integer(&1), do: &1))
        |> Map.update(:clear_boot_id, nil, &if(is_binary(&1), do: &1))
        |> Map.update(:sha256, nil, &if(is_binary(&1), do: &1))

      _ ->
        nil
    end
  end

  defp delete_in_flight(table) do
    with :ok <- :dets.delete(table, :in_flight), do: :dets.sync(table)
  end

  defp orderly?(:normal), do: true
  defp orderly?(:shutdown), do: true
  defp orderly?({:shutdown, _}), do: true
  defp orderly?(_reason), do: false

  defp read_boot_id do
    case File.read(@boot_id_path) do
      {:ok, id} -> String.trim(id)
      {:error, _} -> nil
    end
  end

  defp pinned_version do
    case MilkDrop.Pack.configured_pin() do
      %{version: version} -> version
      nil -> nil
    end
  end

  # `records` is one record or a list of them, inserted in one call.
  defp persist(%{table: table, insert: insert}, records) do
    with :ok <- insert.(table, records), do: :dets.sync(table)
  end

  defp read_settings(nil), do: @defaults

  defp read_settings(table) do
    case :dets.lookup(table, :settings) do
      [{:settings, stored}] when is_map(stored) -> sanitize(Map.merge(@defaults, stored))
      _ -> @defaults
    end
  end

  defp read_user_skipped(nil), do: %{}

  defp read_user_skipped(table) do
    case :dets.lookup(table, :user_skipped) do
      [{:user_skipped, entries}] when is_map(entries) ->
        for {id, entry} <- entries,
            is_binary(id),
            user_id?(id),
            valid_user_entry?(entry),
            into: %{},
            do: {id, entry}

      _ ->
        %{}
    end
  end

  defp read_skipped(nil), do: nil

  defp read_skipped(table) do
    case :dets.lookup(table, :skipped) do
      [{:skipped, {version, entries}}] when is_binary(version) and is_map(entries) ->
        {version, sanitize_skipped(entries)}

      _ ->
        nil
    end
  end

  defp broadcast(state, message) do
    Phoenix.PubSub.broadcast(state.pubsub, MilkDrop.settings_topic(), message)
  end

  # Presence-aware merge (an explicit `false`/`nil` is kept), then
  # per-field sanitize with the saved value as each field's fallback.
  defp merge(existing, params) do
    Map.new(@keys, fn key ->
      value = if Params.has_key?(params, key), do: Params.get(params, key), else: existing[key]
      {key, sanitize_field(key, value, existing[key])}
    end)
  end

  defp sanitize(stored) do
    Map.new(@keys, fn key -> {key, sanitize_field(key, stored[key], @defaults[key])} end)
  end

  defp sanitize_field(:include_high_frequency, v, _fallback) when is_boolean(v), do: v

  defp sanitize_field(:rotate_s, v, _fallback) when is_integer(v),
    do: v |> max(@rotate_min) |> min(@rotate_max)

  defp sanitize_field(:min_fps, v, _fallback) when is_number(v) do
    steps = round((min(max(v, @min_fps_min), max_min_fps()) - @min_fps_min) / @min_fps_step)
    min(@min_fps_min + steps * @min_fps_step, max_min_fps())
  end

  defp sanitize_field(:locked, nil, _fallback), do: nil
  defp sanitize_field(:locked, v, _fallback) when is_binary(v) and v != "", do: v
  defp sanitize_field(_key, _v, fallback), do: fallback

  defp sanitize_skipped(entries) do
    for {preset, entry} <- entries, is_binary(preset), valid_entry?(entry), into: %{} do
      {preset, entry}
    end
  end

  defp valid_entry?(reason) when is_binary(reason), do: true

  defp valid_entry?(%{reason: reason, fps: fps}) when is_binary(reason) and is_float(fps),
    do: true

  defp valid_entry?(_entry), do: false

  defp valid_user_entry?(%{reason: reason, fps: fps, sha256: sha})
       when is_binary(reason) and (is_float(fps) or is_nil(fps)) and is_binary(sha),
       do: true

  defp valid_user_entry?(_entry), do: false

  # Stored as the bare reason unless there is an fps to keep (the original
  # format, still read as is).
  defp skip_entry(reason, fps) when is_number(fps) and fps >= 0,
    do: %{reason: reason, fps: fps / 1}

  defp skip_entry(reason, _fps), do: reason

  defp entry_details(reason) when is_binary(reason), do: %{reason: reason, fps: nil}
  defp entry_details(%{reason: reason, fps: fps}), do: %{reason: reason, fps: fps}

  defp max_min_fps, do: MilkDrop.max_min_fps()

  defp reason_string(reason) when is_binary(reason), do: reason
  defp reason_string(reason) when is_atom(reason), do: Atom.to_string(reason)
end
