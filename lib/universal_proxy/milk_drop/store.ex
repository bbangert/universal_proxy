defmodule UniversalProxy.MilkDrop.Store do
  @moduledoc """
  DETS-backed MilkDrop settings and the runtime skip list.

  Two records share one table:

    * `:settings` —

          %{
            include_high_frequency: boolean(),  # default false
            rotate_s: 10..120,                  # default 20
            locked: String.t() | nil            # pack-relative preset file
          }

    * `:skipped` — `{pack_version, %{preset_file => reason}}`: presets the
      renderer found it cannot draw (compile/draw failure, over budget at
      the last ladder rung). Only one pack version is kept: recording a
      skip for a different version drops the old entries, and
      `skipped/2` for any other version reads as empty.

  Values are sanitized on every read and write, so a corrupt or older
  record reads back as defaults. A file DETS refuses to open (not a DETS
  file, unrepairable) is moved aside to `<path>.corrupt` and a fresh table
  is opened: the store fails closed to defaults rather than refusing to
  start.

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

  # -- Server callbacks --

  @impl true
  def init(opts) do
    # Trap exits so terminate/2 runs on a supervisor shutdown too (not only
    # on a crash) and closes the DETS table cleanly.
    Process.flag(:trap_exit, true)

    table_name = Keyword.get(opts, :table, @default_table)
    path = Keyword.get(opts, :dets_path) || Path.join(MilkDrop.root(), "settings.dets")
    pubsub = Keyword.get(opts, :pubsub, UniversalProxy.PubSub)

    with :ok <- mkdir_p(path),
         {:ok, table} <- open(table_name, path) do
      Logger.info("MilkDrop store opened at #{path}")
      {:ok, %{table: table, pubsub: pubsub}}
    else
      {:error, reason} ->
        Logger.error("MilkDrop store failed to open #{path}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, %{table: table}), do: :dets.close(table)

  @impl true
  def handle_call(:settings, _from, state) do
    {:reply, read_settings(state.table), state}
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
    skipped =
      case read_skipped(state.table) do
        {^version, entries} -> Map.put(entries, preset, reason)
        _ -> %{preset => reason}
      end

    case persist(state.table, {:skipped, {version, skipped}}) do
      :ok ->
        broadcast(state, {:milkdrop_skipped, version, skipped})
        {:reply, :ok, state}

      {:error, reason} ->
        Logger.error("MilkDrop store skip update failed: #{inspect(reason)}")
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

  defp open(table_name, path) do
    case :dets.open_file(table_name, file: to_charlist(path), type: :set) do
      {:ok, table} ->
        {:ok, table}

      {:error, reason} ->
        aside = path <> ".corrupt"

        Logger.warning(
          "MilkDrop store could not open #{path} (#{inspect(reason)}); " <>
            "moving it to #{aside} and starting from defaults"
        )

        with :ok <- File.rename(path, aside) do
          :dets.open_file(table_name, file: to_charlist(path), type: :set)
        end
    end
  end

  defp mkdir_p(path), do: File.mkdir_p(Path.dirname(path))

  defp persist(table, record) do
    with :ok <- :dets.insert(table, record), do: :dets.sync(table)
  end

  defp read_settings(table) do
    case :dets.lookup(table, :settings) do
      [{:settings, stored}] when is_map(stored) -> sanitize(Map.merge(@defaults, stored))
      _ -> @defaults
    end
  end

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
