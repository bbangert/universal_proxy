defmodule UniversalProxy.BTD700.Store do
  @moduledoc """
  DETS-backed persistence for Sennheiser BTD 700 configuration, keyed by
  `{usb_port, vendor_id, product_id}` — the same key shape as
  `UniversalProxy.Audio.Store`/`UniversalProxy.FMA120.Store`, so a saved
  BTD 700 config correlates to its audio output.

  Persists only host-chosen preferences:

      %{
        audio_mode: :high_quality | :gaming | :broadcast | nil,
        codec_mask: [:sbc | :aptx | :aptx_adaptive | :aptx_lossless |
                     :aptx_lite | :lc3] | nil,
        broadcast_state: :off_private | :on_public | nil,
        broadcast_quality: :standard_16k | :standard_24k | :high | nil,
        broadcast_encryption: boolean(),
        broadcast_name: String.t() | nil
      }

  A `nil` preference means "no override — leave the device as-is and don't
  re-apply on (re)connect." The Auracast **broadcast key is never persisted
  here** — only the fact that encryption is on/off (`broadcast_encryption`).
  The dongle owns the key itself; `sanitize/1` only recognizes the six
  fields above, so passing a `:broadcast_key` (or any other unknown field)
  into `update_config/3` is silently dropped, not stored.

  Unlike `UniversalProxy.UART.SettingsStore`, this store has **no
  delete-on-unplug**: the key already embeds `{vendor_id, product_id}`, so
  a different device replugged at the same `usb_port` can never inherit a
  stale BTD 700 config the way a bare port-keyed record could. This is a
  deliberate simplification, not an oversight — do not add
  `delete_config/2` without a reason the key shape doesn't already cover.

  Defaults are applied at the read/write boundary so callers may pass
  partial maps. Per-field sanitize guards (mirroring `FMA120.Store`) keep a
  corrupt or older record from crashing readers.

  The DETS file lives on the writable data partition on Nerves
  (`/data/btd700_configs.dets`) and in `_build/` on the host. Tests
  override via `:dets_path`, `:table`, and `:name` opts to `start_link/1`.
  """

  use GenServer

  require Logger

  alias UniversalProxy.Audio.Params

  @default_table :btd700_configs

  @defaults %{
    audio_mode: nil,
    codec_mask: nil,
    broadcast_state: nil,
    broadcast_quality: nil,
    broadcast_encryption: false,
    broadcast_name: nil
  }

  @keys Map.keys(@defaults)

  @audio_modes [:high_quality, :gaming, :broadcast]

  @codecs [:sbc, :aptx, :aptx_adaptive, :aptx_lossless, :aptx_lite, :lc3]

  @broadcast_states [:off_private, :on_public]

  @broadcast_qualities [:standard_16k, :standard_24k, :high]

  # Auracast broadcast name is clamped to 59 bytes on the wire (60-byte
  # payload window minus a trailing NUL — see protocol-payloads.md gotcha
  # #2); enforce the same limit here so a too-long name never round-trips
  # through the store only to be truncated/rejected on send.
  @max_broadcast_name_bytes 59

  @type usb_port :: String.t()
  @type vendor_id :: non_neg_integer() | nil
  @type product_id :: non_neg_integer() | nil
  @type config_key :: {usb_port(), vendor_id(), product_id()}

  @type config :: %{
          audio_mode: :high_quality | :gaming | :broadcast | nil,
          codec_mask: [atom()] | nil,
          broadcast_state: :off_private | :on_public | nil,
          broadcast_quality: :standard_16k | :standard_24k | :high | nil,
          broadcast_encryption: boolean(),
          broadcast_name: String.t() | nil
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
  unknown keys (including any attempt to pass a broadcast key/secret) are
  dropped. Returns `:ok` or `{:error, reason}` if DETS rejects the write.
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
        Logger.info("BTD 700 config store opened at #{path}")
        {:ok, %{table: table}}

      {:error, reason} ->
        Logger.error("BTD 700 config store failed to open #{path}: #{inspect(reason)}")
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
        Logger.error("BTD 700 store update failed for #{inspect(key)}: #{inspect(reason)}")
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
  # sanitize the result so persisted values are always well-typed. Only
  # `@keys` are ever consulted, so any extra field (e.g. a broadcast key)
  # passed in `params` is dropped by construction — never merged, never
  # stored.
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
      audio_mode: member_or_nil(cfg.audio_mode, @audio_modes),
      codec_mask: codec_mask_or_nil(cfg.codec_mask),
      broadcast_state: member_or_nil(cfg.broadcast_state, @broadcast_states),
      broadcast_quality: member_or_nil(cfg.broadcast_quality, @broadcast_qualities),
      broadcast_encryption: bool_or(cfg.broadcast_encryption, false),
      broadcast_name: broadcast_name_or_nil(cfg.broadcast_name)
    }
  end

  defp member_or_nil(v, allowed) when is_atom(v), do: if(v in allowed, do: v, else: nil)
  defp member_or_nil(_, _), do: nil

  defp codec_mask_or_nil(codecs) when is_list(codecs) do
    if Enum.all?(codecs, &(is_atom(&1) and &1 in @codecs)) do
      Enum.uniq(codecs)
    else
      nil
    end
  end

  defp codec_mask_or_nil(_), do: nil

  defp bool_or(v, _default) when is_boolean(v), do: v
  defp bool_or(_v, default), do: default

  defp broadcast_name_or_nil(v) when is_binary(v) and v != "" do
    if String.valid?(v) and byte_size(v) <= @max_broadcast_name_bytes do
      v
    else
      nil
    end
  end

  defp broadcast_name_or_nil(_), do: nil

  defp dets_path do
    if File.dir?("/data") do
      "/data/btd700_configs.dets"
    else
      Path.join([File.cwd!(), "_build", "btd700_configs.dets"])
    end
  end
end
