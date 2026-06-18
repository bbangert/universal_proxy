defmodule UniversalProxy.FMA120.Store do
  @moduledoc """
  DETS-backed persistence for FlooGoo FMA120 configuration, keyed by
  `{usb_port, vendor_id, product_id}` — the same key shape as
  `UniversalProxy.Audio.Store`, so a saved FMA120 config correlates to its
  audio output.

  Persists only host-chosen preferences:

      %{
        friendly_name_override: String.t() | nil,
        le_preference: :a2dp | :lea | nil,
        feature_flags: 0..255 | nil,
        broadcast_mode: 0..255 | nil,
        broadcast_name: String.t() | nil,
        broadcast_encryption_set: boolean(),
        codec_preference: atom() | nil
      }

  A `nil` preference means "no override — leave the device as-is and don't
  re-apply on (re)connect". The dongle owns its own pairing table, so paired
  MACs are **not** persisted here.

  Defaults are applied at the read/write boundary so callers may pass
  partial maps. Per-field sanitize guards (mirroring
  `UniversalProxy.Bluetooth.Settings`) keep a corrupt or older record from
  crashing readers.

  The DETS file lives on the writable data partition on Nerves
  (`/data/fma120_configs.dets`) and in `_build/` on the host. Tests override
  via `:dets_path`, `:table`, and `:name` opts to `start_link/1`.
  """

  use GenServer

  require Logger

  alias UniversalProxy.Audio.Params

  @default_table :fma120_configs

  @defaults %{
    friendly_name_override: nil,
    le_preference: nil,
    feature_flags: nil,
    broadcast_mode: nil,
    broadcast_name: nil,
    broadcast_encryption_set: false,
    codec_preference: nil
  }

  @keys Map.keys(@defaults)

  @le_preferences [:a2dp, :lea]

  # Codec preference atoms (a subset of Protocol's codec map the user may
  # express a preference for; sanitize rejects anything else).
  @codec_preferences [
    :a2dp_sbc,
    :a2dp_aptx,
    :a2dp_aptx_hd,
    :a2dp_aptx_adaptive,
    :a2dp_aptx_adaptive_lossless,
    :lea_lc3,
    :lea_aptx_adaptive,
    :lea_aptx_lite
  ]

  @type usb_port :: String.t()
  @type vendor_id :: non_neg_integer() | nil
  @type product_id :: non_neg_integer() | nil
  @type config_key :: {usb_port(), vendor_id(), product_id()}

  @type config :: %{
          friendly_name_override: String.t() | nil,
          le_preference: :a2dp | :lea | nil,
          feature_flags: 0..255 | nil,
          broadcast_mode: 0..255 | nil,
          broadcast_name: String.t() | nil,
          broadcast_encryption_set: boolean(),
          codec_preference: atom() | nil
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
  @spec defaults() :: config()
  def defaults, do: @defaults

  @doc """
  Look up a saved configuration. Returns `{:ok, config}` (defaults merged in
  for any field a stored record predates) or `:error` if nothing is saved
  for this key.
  """
  @spec get_config(GenServer.server(), config_key()) :: {:ok, config()} | :error
  def get_config(server \\ __MODULE__, {usb_port, _vid, _pid} = key) when is_binary(usb_port) do
    GenServer.call(server, {:get, key})
  end

  @doc """
  Merge `params` into the saved configuration (creating it if absent) and
  persist. Missing fields keep their saved value or fall back to defaults;
  unknown keys are dropped. Returns `:ok` or `{:error, reason}` if DETS
  rejects the write.
  """
  @spec update_config(GenServer.server(), config_key(), map()) :: :ok | {:error, term()}
  def update_config(server \\ __MODULE__, {usb_port, _vid, _pid} = key, params)
      when is_binary(usb_port) and is_map(params) do
    GenServer.call(server, {:update, key, params})
  end

  @doc "Return every saved configuration as a `%{key => config}` map."
  @spec all_configs(GenServer.server()) :: %{config_key() => config()}
  def all_configs(server \\ __MODULE__) do
    GenServer.call(server, :all)
  end

  # -- Server Callbacks --

  @impl true
  def init(opts) do
    table_name = Keyword.get(opts, :table, @default_table)
    path = Keyword.get(opts, :dets_path) || dets_path()

    case :dets.open_file(table_name, file: to_charlist(path), type: :set) do
      {:ok, table} ->
        Logger.info("FMA120 config store opened at #{path}")
        {:ok, %{table: table}}

      {:error, reason} ->
        Logger.error("FMA120 config store failed to open #{path}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, %{table: table}) do
    :dets.close(table)
  end

  @impl true
  def handle_call({:get, key}, _from, state) do
    result =
      case :dets.lookup(state.table, key) do
        [{^key, cfg}] when is_map(cfg) -> {:ok, sanitize(Map.merge(@defaults, cfg))}
        _ -> :error
      end

    {:reply, result, state}
  end

  def handle_call({:update, key, params}, _from, state) do
    existing =
      case :dets.lookup(state.table, key) do
        [{^key, cfg}] when is_map(cfg) -> cfg
        _ -> %{}
      end

    merged = merge_defaults(existing, params)

    with :ok <- :dets.insert(state.table, {key, merged}),
         :ok <- :dets.sync(state.table) do
      {:reply, :ok, state}
    else
      {:error, reason} ->
        Logger.error("FMA120 store update failed for #{inspect(key)}: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:all, _from, state) do
    all =
      :dets.foldl(
        fn
          {{_usb, _vid, _pid} = key, cfg}, acc when is_map(cfg) ->
            Map.put(acc, key, sanitize(Map.merge(@defaults, cfg)))

          _other, acc ->
            acc
        end,
        %{},
        state.table
      )

    {:reply, all, state}
  end

  # -- Private --

  # Presence-aware merge so an explicit `nil`/`false` is persisted rather
  # than silently overridden by a default (the `false || x` bug). Then
  # sanitize the result so persisted values are always well-typed.
  defp merge_defaults(existing, params) do
    @keys
    |> Map.new(fn key ->
      {key, pick(params, existing, key, Map.fetch!(@defaults, key))}
    end)
    |> sanitize()
  end

  defp pick(params, existing, key, default) do
    cond do
      Params.has_key?(params, key) -> Params.get(params, key)
      Map.has_key?(existing, key) -> Map.get(existing, key)
      true -> default
    end
  end

  defp sanitize(cfg) do
    %{
      friendly_name_override: string_or_nil(cfg.friendly_name_override),
      le_preference: member_or_nil(cfg.le_preference, @le_preferences),
      feature_flags: byte_or_nil(cfg.feature_flags),
      broadcast_mode: byte_or_nil(cfg.broadcast_mode),
      broadcast_name: string_or_nil(cfg.broadcast_name),
      broadcast_encryption_set: bool_or(cfg.broadcast_encryption_set, false),
      codec_preference: member_or_nil(cfg.codec_preference, @codec_preferences)
    }
  end

  defp string_or_nil(v) when is_binary(v) and v != "", do: v
  defp string_or_nil(_), do: nil

  defp member_or_nil(v, allowed) when is_atom(v), do: if(v in allowed, do: v, else: nil)
  defp member_or_nil(_, _), do: nil

  defp byte_or_nil(v) when is_integer(v) and v in 0..255, do: v
  defp byte_or_nil(_), do: nil

  defp bool_or(v, _default) when is_boolean(v), do: v
  defp bool_or(_v, default), do: default

  defp dets_path do
    if File.dir?("/data") do
      "/data/fma120_configs.dets"
    else
      Path.join([File.cwd!(), "_build", "fma120_configs.dets"])
    end
  end
end
