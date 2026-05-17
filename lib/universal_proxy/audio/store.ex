defmodule UniversalProxy.Audio.Store do
  @moduledoc """
  DETS-backed persistence for Sendspin audio-output configuration.

  Keyed by `{slot_sub, vendor_id, product_id}` — the same shape as
  `UniversalProxy.UART.Store`. For built-in SoC cards on v1 hardware
  the VID/PID slots are `nil` and `slot_sub` is the long ALSA card
  name (e.g. `"bcm2835 Headphones"`).

  Stored value shape:

      %{
        friendly_name: String.t(),
        enabled: boolean(),
        client_id: String.t(),
        volume: 0..100,
        muted: boolean()
      }

  `client_id` is generated once per output the first time it is sighted
  and persists across reboots so a paired Sendspin server keeps
  recognising the player. Volume defaults to `50` and `muted` to
  `false`. These defaults are applied at the `save_config/2` boundary
  so callers can pass partial maps.

  The DETS file lives on the writable data partition on Nerves
  (`/data/audio_outputs.dets`) and in `_build/` on the host for
  development. Tests can override via the `:dets_path`, `:table`, and
  `:name` options to `start_link/1`.
  """

  use GenServer

  require Logger

  alias UniversalProxy.Audio.Params

  @default_table :audio_outputs

  @type slot_sub :: String.t()
  @type vendor_id :: non_neg_integer() | nil
  @type product_id :: non_neg_integer() | nil
  @type output_key :: {slot_sub(), vendor_id(), product_id()}

  @type config :: %{
          friendly_name: String.t(),
          enabled: boolean(),
          client_id: String.t(),
          volume: 0..100,
          muted: boolean()
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

  @doc """
  Save or update an audio-output configuration keyed by
  `{slot_sub, vid, pid}`. Missing fields fall back to defaults
  (`volume: 50`, `muted: false`, `enabled: true`,
  `client_id: <generated>`, `friendly_name: slot_sub`).

  Returns `:ok` on success or `{:error, reason}` if DETS rejects the
  write (e.g. `:system_limit` on a full data partition). Callers must
  handle the error path — `Audio.Server` does so via `with` chains so
  a transient DETS failure surfaces instead of crashing the GenServer
  on the immediate read-back.
  """
  @spec save_config(GenServer.server(), output_key(), map()) :: :ok | {:error, term()}
  def save_config(server \\ __MODULE__, {slot_sub, _vid, _pid} = key, params)
      when is_binary(slot_sub) and is_map(params) do
    GenServer.call(server, {:save, key, params})
  end

  @doc "Look up a saved configuration. Returns `{:ok, map}` or `:error`."
  @spec get_config(GenServer.server(), output_key()) :: {:ok, config()} | :error
  def get_config(server \\ __MODULE__, {slot_sub, _vid, _pid} = key) when is_binary(slot_sub) do
    GenServer.call(server, {:get, key})
  end

  @doc """
  Delete a saved configuration. Returns `:ok` on success or
  `{:error, reason}` if DETS rejects the write.
  """
  @spec delete_config(GenServer.server(), output_key()) :: :ok | {:error, term()}
  def delete_config(server \\ __MODULE__, {slot_sub, _vid, _pid} = key)
      when is_binary(slot_sub) do
    GenServer.call(server, {:delete, key})
  end

  @doc "Return every saved configuration as a `%{key => config}` map."
  @spec get_all(GenServer.server()) :: %{output_key() => config()}
  def get_all(server \\ __MODULE__) do
    GenServer.call(server, :all)
  end

  # -- Server Callbacks --

  @impl true
  def init(opts) do
    table_name = Keyword.get(opts, :table, @default_table)
    path = Keyword.get(opts, :dets_path) || dets_path()

    case :dets.open_file(table_name, file: to_charlist(path), type: :set) do
      {:ok, table} ->
        Logger.info("Audio output store opened at #{path}")
        {:ok, %{table: table}}

      {:error, reason} ->
        Logger.error("Audio output store failed to open #{path}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, %{table: table}) do
    :dets.close(table)
  end

  @impl true
  def handle_call({:save, key, params}, _from, state) do
    existing =
      case :dets.lookup(state.table, key) do
        [{^key, cfg}] when is_map(cfg) -> cfg
        _ -> %{}
      end

    merged = merge_defaults(existing, params, key)

    with :ok <- :dets.insert(state.table, {key, merged}),
         :ok <- :dets.sync(state.table) do
      {:reply, :ok, state}
    else
      {:error, reason} ->
        Logger.error("Audio store save failed for #{inspect(key)}: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get, key}, _from, state) do
    result =
      case :dets.lookup(state.table, key) do
        [{^key, cfg}] when is_map(cfg) -> {:ok, cfg}
        _ -> :error
      end

    {:reply, result, state}
  end

  def handle_call({:delete, key}, _from, state) do
    with :ok <- :dets.delete(state.table, key),
         :ok <- :dets.sync(state.table) do
      {:reply, :ok, state}
    else
      {:error, reason} ->
        Logger.error("Audio store delete failed for #{inspect(key)}: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:all, _from, state) do
    all =
      :dets.foldl(
        fn
          {{_slot, _vid, _pid} = key, cfg}, acc when is_map(cfg) -> Map.put(acc, key, cfg)
          _other, acc -> acc
        end,
        %{},
        state.table
      )

    {:reply, all, state}
  end

  # -- Private --

  # The default `friendly_name` is the long ALSA card name. Users can
  # rename per output via the UI; until they do, "bcm2835 Headphones"
  # is more informative than a synthesised slot.
  defp merge_defaults(existing, params, {slot_sub, _vid, _pid}) do
    %{
      friendly_name: pick(params, existing, :friendly_name, slot_sub),
      enabled: pick(params, existing, :enabled, true),
      client_id: pick(params, existing, :client_id, &generate_client_id/0),
      volume: clamp_volume(pick(params, existing, :volume, 50)),
      muted: !!pick(params, existing, :muted, false)
    }
  end

  # Uses presence checks (via `Params.has_key?/2`) rather than `||`
  # chaining so that explicit `false` values (e.g. `enabled: false`,
  # `muted: false`) are persisted instead of being silently overridden
  # by the default — `false || x` evaluates `x`, which is the bug
  # `pick` exists to avoid. `Params` handles the atom/string-key
  # fallback so this module doesn't reimplement it.
  defp pick(params, existing, key, default) do
    cond do
      Params.has_key?(params, key) ->
        Params.get(params, key)

      Map.has_key?(existing, key) ->
        Map.get(existing, key)

      is_function(default, 0) ->
        default.()

      true ->
        default
    end
  end

  defp clamp_volume(v) when is_integer(v) and v >= 0 and v <= 100, do: v
  defp clamp_volume(v) when is_integer(v) and v < 0, do: 0
  defp clamp_volume(v) when is_integer(v) and v > 100, do: 100
  defp clamp_volume(_), do: 50

  # 16 random bytes is 128 bits of entropy, more than enough to identify
  # a player to a Sendspin server. Hex-encoded for human-greppable logs.
  defp generate_client_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp dets_path do
    if File.dir?("/data") do
      "/data/audio_outputs.dets"
    else
      Path.join([File.cwd!(), "_build", "audio_outputs.dets"])
    end
  end
end
