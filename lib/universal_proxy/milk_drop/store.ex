defmodule UniversalProxy.MilkDrop.Store do
  @moduledoc """
  DETS-backed MilkDrop settings and the runtime skip list.

  Three records share one table:

    * `:settings` —

          %{
            include_high_frequency: boolean(),  # default false
            rotate_s: 10..120,                  # default 20
            locked: String.t() | nil            # pack-relative preset file
          }

    * `:skipped` — `{pack_version, %{preset_file => reason}}`: presets the
      renderer found it cannot draw (compile/draw failure, over budget at
      the last ladder rung, a GPU reset) or that were showing when the
      device went down (`device_reset`). Every write is synced to disk
      before it returns. Only one pack version is kept: recording a
      skip for a different version drops the old entries, and
      `skipped/2` for any other version reads as empty.

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
  renderer loads it (`mark_in_flight/4`, synced to disk before it
  returns) and asks for the record to be dropped when its session ends
  (`clear_in_flight/2`).

  The record carries the Linux boot id (`/proc/sys/kernel/random/boot_id`).
  When the store opens a record written during an earlier boot, the device
  went down while that preset was loading or playing: the preset is added
  to the skip list with reason `device_reset` (if the record's pack version
  is the pinned one), a warning is logged and the record is deleted. A
  record from the current boot (the store restarted, the device did not) is
  left to its session.

  `clear_in_flight/2` deletes the record only after `:in_flight_grace_ms`
  (default #{30_000}) and only if it is still the one that session wrote:
  a renderer stuck on a hung GPU can still exit "cleanly" (its exit
  watchdog) in the seconds before the device dies. An orderly shutdown of
  the store (`:normal`, `:shutdown`: a reboot or firmware update) deletes
  it at once, since that is not a device reset.

  Accepted false positive: a power cut while a preset is loading or
  playing skips that one preset. "Clear skipped presets" in the web UI
  (`clear_skipped/1`) brings it back.

  The record is written on each preset change only (about every 20 s by
  default, `rotate_s`), so its flash wear is negligible.

  Changes are broadcast on `UniversalProxy.MilkDrop.settings_topic/0` (see
  `UniversalProxy.MilkDrop`).

  The public API follows the `catch :exit` idiom for optional subsystems:
  while the store is not running reads return defaults and writes
  `{:error, :not_running}`.

  The DETS file lives at `<UniversalProxy.MilkDrop.root()>/settings.dets`
  (`/data/milkdrop/settings.dets` on Nerves). Tests override via the
  `:dets_path`, `:table`, `:name` and `:pubsub` opts to `start_link/1`.
  """

  use GenServer

  require Logger

  alias UniversalProxy.Audio.Params
  alias UniversalProxy.MilkDrop

  @default_table :milkdrop_settings
  @retry_ms 30_000
  @in_flight_grace_ms 30_000
  @boot_id_path "/proc/sys/kernel/random/boot_id"

  @rotate_min 10
  @rotate_max 120

  @defaults %{include_high_frequency: false, rotate_s: 20, locked: nil}

  @keys Map.keys(@defaults)

  @type settings :: %{
          include_high_frequency: boolean(),
          rotate_s: 10..120,
          locked: String.t() | nil
        }

  @type skipped :: %{String.t() => String.t()}

  @type in_flight :: %{
          pack_version: String.t(),
          preset: String.t(),
          at: integer(),
          session: term(),
          boot_id: String.t() | nil
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
  a wrongly-typed value keeps the saved one. Returns the new settings.
  """
  @spec update(GenServer.server(), map()) :: {:ok, settings()} | {:error, term()}
  def update(server \\ __MODULE__, params) when is_map(params) do
    GenServer.call(server, {:update, params})
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc """
  Record that `preset` (a pack-relative file) cannot be drawn with pack
  `version`, for `reason`. A different `version` than the stored one
  replaces the whole skip list.
  """
  @spec skip(GenServer.server(), String.t(), String.t(), String.t() | atom()) ::
          :ok | {:error, term()}
  def skip(server \\ __MODULE__, version, preset, reason)
      when is_binary(version) and is_binary(preset) do
    GenServer.call(server, {:skip, version, preset, reason_string(reason)})
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc "The skip list for pack `version` (`%{}` for any version but the stored one)."
  @spec skipped(GenServer.server(), String.t()) :: skipped()
  def skipped(server \\ __MODULE__, version) when is_binary(version) do
    GenServer.call(server, {:skipped, version})
  catch
    :exit, _ -> %{}
  end

  @doc "Forget every skipped preset."
  @spec clear_skipped(GenServer.server()) :: :ok | {:error, term()}
  def clear_skipped(server \\ __MODULE__) do
    GenServer.call(server, :clear_skipped)
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc """
  Record that `session` (a renderer session) is about to load `preset` of
  pack `version`, replacing any earlier record. The write is synced to disk
  before this returns. See "Device resets".
  """
  @spec mark_in_flight(GenServer.server(), term(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def mark_in_flight(server \\ __MODULE__, session, version, preset)
      when is_binary(version) and is_binary(preset) do
    GenServer.call(server, {:mark_in_flight, session, version, preset})
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc """
  `session` ended: its in-flight record is deleted `:in_flight_grace_ms`
  from now, if it is still the same record then. Another session's record
  is left alone.
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
      pack_version: Keyword.get_lazy(opts, :pack_version, &pinned_version/0),
      in_flight_grace_ms: Keyword.get(opts, :in_flight_grace_ms, @in_flight_grace_ms)
    }

    case open_table(state) do
      {:ok, state} -> {:ok, state}
      {:error, state} -> {:ok, schedule_retry(state)}
    end
  end

  @impl true
  def terminate(_reason, %{table: nil}), do: :ok

  def terminate(reason, %{table: table}) do
    if orderly?(reason), do: _ = :dets.delete(table, :in_flight)
    :dets.close(table)
  end

  @impl true
  def handle_info(:retry_open, %{table: nil} = state) do
    case open_table(%{state | retry_timer: nil}) do
      {:ok, state} -> {:noreply, state}
      {:error, state} -> {:noreply, schedule_retry(state)}
    end
  end

  def handle_info({:clear_in_flight, marker}, %{table: table} = state) when table != nil do
    if read_in_flight(table) == marker, do: delete_in_flight(table)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:settings, _from, state) do
    {:reply, read_settings(state.table), state}
  end

  def handle_call(:in_flight, _from, state) do
    reply =
      case read_in_flight(state.table) do
        nil -> nil
        marker -> Map.take(marker, [:pack_version, :preset, :at, :session, :boot_id])
      end

    {:reply, reply, state}
  end

  # Nothing readable to clear while closed.
  def handle_call({:clear_in_flight, _session}, _from, %{table: nil} = state),
    do: {:reply, :ok, state}

  def handle_call({:clear_in_flight, session}, _from, state) do
    case read_in_flight(state.table) do
      %{session: ^session} when state.in_flight_grace_ms <= 0 ->
        {:reply, delete_in_flight(state.table), state}

      %{session: ^session} = marker ->
        Process.send_after(self(), {:clear_in_flight, marker}, state.in_flight_grace_ms)
        {:reply, :ok, state}

      _other ->
        {:reply, :ok, state}
    end
  end

  def handle_call(request, from, %{table: nil} = state)
      when request == :clear_skipped or
             (is_tuple(request) and elem(request, 0) in [:update, :skip, :mark_in_flight]) do
    case open_table(state) do
      {:ok, state} -> handle_call(request, from, state)
      {:error, state} -> {:reply, {:error, state.open_error}, schedule_retry(state)}
    end
  end

  def handle_call({:update, params}, _from, state) do
    existing = read_settings(state.table)
    merged = merge(existing, params)

    case persist(state.table, {:settings, merged}) do
      :ok ->
        if merged != existing, do: broadcast(state, {:milkdrop_settings, merged})
        {:reply, {:ok, merged}, state}

      {:error, reason} ->
        Logger.error("MilkDrop store settings update failed: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:skip, version, preset, reason}, _from, state) do
    {:reply, add_skip(state, version, preset, reason), state}
  end

  def handle_call({:mark_in_flight, session, version, preset}, _from, state) do
    marker = %{
      pack_version: version,
      preset: preset,
      at: System.os_time(:second),
      session: session,
      boot_id: state.boot_id
    }

    case persist(state.table, {:in_flight, marker}) do
      :ok ->
        {:reply, :ok, state}

      {:error, reason} ->
        Logger.error("MilkDrop store in-flight write failed: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:skipped, version}, _from, state) do
    reply =
      case read_skipped(state.table) do
        {^version, entries} -> entries
        _ -> %{}
      end

    {:reply, reply, state}
  end

  def handle_call(:clear_skipped, _from, state) do
    with :ok <- :dets.delete(state.table, :skipped),
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
      state = %{state | table: table, open_error: nil}
      consume_in_flight(state)
      {:ok, state}
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

  defp add_skip(state, version, preset, reason) do
    skipped =
      case read_skipped(state.table) do
        {^version, entries} -> Map.put(entries, preset, reason)
        _ -> %{preset => reason}
      end

    case persist(state.table, {:skipped, {version, skipped}}) do
      :ok ->
        broadcast(state, {:milkdrop_skipped, version, skipped})
        :ok

      {:error, reason} = error ->
        Logger.error("MilkDrop store skip update failed: #{inspect(reason)}")
        error
    end
  end

  # A record from an earlier boot names the preset that was loading or
  # playing when the device went down. Same boot: the store restarted, the
  # record still belongs to its session. An unreadable boot id on either
  # side counts as an earlier boot.
  defp consume_in_flight(%{table: table} = state) do
    case read_in_flight(table) do
      nil ->
        if :dets.member(table, :in_flight), do: delete_in_flight(table)

      %{boot_id: boot_id} when boot_id != nil and boot_id == state.boot_id ->
        :ok

      %{pack_version: version, preset: preset} ->
        if is_nil(state.pack_version) or state.pack_version == version do
          Logger.warning(
            "MilkDrop preset #{preset} was running when the device last stopped; skipping it"
          )

          add_skip(state, version, preset, "device_reset")
        else
          Logger.info(
            "MilkDrop preset #{preset} (pack #{version}) was running when the device last " <>
              "stopped; that pack is no longer pinned"
          )
        end

        delete_in_flight(table)
    end
  end

  defp read_in_flight(nil), do: nil

  defp read_in_flight(table) do
    case :dets.lookup(table, :in_flight) do
      [{:in_flight, %{pack_version: v, preset: p, at: at, boot_id: b} = marker}]
      when is_binary(v) and is_binary(p) and is_integer(at) and (is_binary(b) or is_nil(b)) and
             is_map_key(marker, :session) ->
        marker

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

  defp persist(table, record) do
    with :ok <- :dets.insert(table, record), do: :dets.sync(table)
  end

  defp read_settings(nil), do: @defaults

  defp read_settings(table) do
    case :dets.lookup(table, :settings) do
      [{:settings, stored}] when is_map(stored) -> sanitize(Map.merge(@defaults, stored))
      _ -> @defaults
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

  defp sanitize_field(:locked, nil, _fallback), do: nil
  defp sanitize_field(:locked, v, _fallback) when is_binary(v) and v != "", do: v
  defp sanitize_field(_key, _v, fallback), do: fallback

  defp sanitize_skipped(entries) do
    for {preset, reason} <- entries, is_binary(preset), is_binary(reason), into: %{} do
      {preset, reason}
    end
  end

  defp reason_string(reason) when is_binary(reason), do: reason
  defp reason_string(reason) when is_atom(reason), do: Atom.to_string(reason)
end
