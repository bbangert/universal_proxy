defmodule UniversalProxy.Audio.Input.Store do
  @moduledoc """
  DETS-backed persistence for Sendspin audio-**input** (capture card)
  configuration and pairing state.

  Keyed by `{slot_sub, vendor_id, product_id}` — the same shape as
  `UniversalProxy.Audio.Store` and `UniversalProxy.UART.Store`. For
  built-in capture devices the VID/PID slots are `nil` and `slot_sub`
  is the long ALSA card name.

  Stored value shape:

      %{
        friendly_name: String.t(),
        client_keypair: {pub :: <<_::256>>, priv :: binary()} | nil,
        psk: <<_::256>> | nil,
        psk_id: String.t() | nil,
        psk_category: atom() | nil,
        server_id: String.t() | nil,
        paired_at: DateTime.t() | nil
      }

  Unlike `Audio.Store`'s `client_id` (generated eagerly on every save),
  `client_keypair` is generated **lazily** on first use via
  `ensure_client_keypair/2` — a config with no pairing yet has every
  pairing-related field `nil`, including the keypair, until something
  actually needs it (the connection FSM sending `client/init`). This
  mirrors the Sendspin ground-truth note that the static keypair is a
  long-lived identity, persisted across reboots, that must be stable
  across reconnections.

  The DETS file lives on the writable data partition on Nerves
  (`/data/audio_inputs.dets`) and in `_build/` on the host for
  development. Tests can override via the `:dets_path`, `:table`, and
  `:name` options to `start_link/1`.
  """

  use GenServer

  require Logger

  alias UniversalProxy.Audio.Params
  alias UniversalProxy.Sendspin.Noise

  @default_table :audio_inputs

  @type slot_sub :: String.t()
  @type vendor_id :: non_neg_integer() | nil
  @type product_id :: non_neg_integer() | nil
  @type input_key :: {slot_sub(), vendor_id(), product_id()}

  @type keypair :: {pub :: <<_::256>>, priv :: binary()}

  @type config :: %{
          friendly_name: String.t(),
          client_keypair: keypair() | nil,
          psk: <<_::256>> | nil,
          psk_id: String.t() | nil,
          psk_category: atom() | nil,
          server_id: String.t() | nil,
          paired_at: DateTime.t() | nil
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
  Save or update an audio-input configuration keyed by
  `{slot_sub, vid, pid}`. Missing fields fall back to defaults
  (`friendly_name: slot_sub`, everything pairing-related `nil`) —
  explicit `nil`/`false` values supplied in `params` are preserved
  rather than clobbered (presence-check merge, see `pick/4`).

  Returns `:ok` on success or `{:error, reason}` if DETS rejects the
  write (e.g. `:system_limit` on a full data partition).
  """
  @spec save_config(GenServer.server(), input_key(), map()) :: :ok | {:error, term()}
  def save_config(server \\ __MODULE__, {slot_sub, _vid, _pid} = key, params)
      when is_binary(slot_sub) and is_map(params) do
    GenServer.call(server, {:save, key, params})
  end

  @doc "Look up a saved configuration. Returns `{:ok, map}` or `:error`."
  @spec get_config(GenServer.server(), input_key()) :: {:ok, config()} | :error
  def get_config(server \\ __MODULE__, {slot_sub, _vid, _pid} = key) when is_binary(slot_sub) do
    GenServer.call(server, {:get, key})
  end

  @doc """
  Delete a saved configuration. Returns `:ok` on success or
  `{:error, reason}` if DETS rejects the write.
  """
  @spec delete_config(GenServer.server(), input_key()) :: :ok | {:error, term()}
  def delete_config(server \\ __MODULE__, {slot_sub, _vid, _pid} = key)
      when is_binary(slot_sub) do
    GenServer.call(server, {:delete, key})
  end

  @doc "Return every saved configuration as a `%{key => config}` map."
  @spec all_configs(GenServer.server()) :: %{input_key() => config()}
  def all_configs(server \\ __MODULE__) do
    GenServer.call(server, :all)
  end

  @doc """
  Get the persisted X25519 static keypair for `key`, generating and
  persisting one via `Noise.generate_static_keypair/0` if none exists
  yet. Stable across calls and across process restarts (the keypair is
  the Sendspin client's long-lived identity — see moduledoc).

  Returns `{:ok, {pub, priv}}` or `{:error, reason}` if DETS rejects a
  first-use write.
  """
  @spec ensure_client_keypair(GenServer.server(), input_key()) ::
          {:ok, keypair()} | {:error, term()}
  def ensure_client_keypair(server \\ __MODULE__, {slot_sub, _vid, _pid} = key)
      when is_binary(slot_sub) do
    GenServer.call(server, {:ensure_keypair, key})
  end

  @doc """
  The Sendspin `client_id` for a static public key: base64url encoding
  (no padding) of the raw 32-byte X25519 public key, per the
  ground-truth doc's `client_id` derivation (§10).
  """
  @spec client_id(<<_::256>>) :: String.t()
  def client_id(<<pub::binary-size(32)>>), do: Base.url_encode64(pub, padding: false)

  @doc """
  Persist a completed pairing: `psk`, `psk_id`, `psk_category`,
  `server_id` (the server's static pubkey), and `paired_at`. Defaults
  `paired_at` to `DateTime.utc_now/0` if the caller doesn't supply one.
  Goes through the same presence-check merge as `save_config/3`, so
  `friendly_name` and `client_keypair` are left untouched.
  """
  @spec save_pairing(GenServer.server(), input_key(), map()) :: :ok | {:error, term()}
  def save_pairing(server \\ __MODULE__, {slot_sub, _vid, _pid} = key, attrs)
      when is_binary(slot_sub) and is_map(attrs) do
    paired_at = Params.get(attrs, :paired_at, DateTime.utc_now())
    save_config(server, key, Map.put(attrs, :paired_at, paired_at))
  end

  @doc """
  Clear a device's pairing state (`psk`, `psk_id`, `psk_category`,
  `server_id`, `paired_at` all reset to `nil`), leaving `friendly_name`
  and `client_keypair` untouched — the client keypair is an identity,
  not pairing state, and must survive an unpair.
  """
  @spec clear_pairing(GenServer.server(), input_key()) :: :ok | {:error, term()}
  def clear_pairing(server \\ __MODULE__, {slot_sub, _vid, _pid} = key)
      when is_binary(slot_sub) do
    save_config(server, key, %{
      psk: nil,
      psk_id: nil,
      psk_category: nil,
      server_id: nil,
      paired_at: nil
    })
  end

  # -- Server Callbacks --

  @impl true
  def init(opts) do
    table_name = Keyword.get(opts, :table, @default_table)
    path = Keyword.get(opts, :dets_path) || dets_path()

    case :dets.open_file(table_name, file: to_charlist(path), type: :set) do
      {:ok, table} ->
        Logger.info("Audio input store opened at #{path}")
        {:ok, %{table: table}}

      {:error, reason} ->
        Logger.error("Audio input store failed to open #{path}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, %{table: table}) do
    :dets.close(table)
  end

  @impl true
  def handle_call({:save, key, params}, _from, state) do
    existing = lookup(state.table, key)
    merged = merge_defaults(existing, params, key)

    with :ok <- :dets.insert(state.table, {key, merged}),
         :ok <- :dets.sync(state.table) do
      {:reply, :ok, state}
    else
      {:error, reason} ->
        Logger.error("Audio input store save failed for #{inspect(key)}: #{inspect(reason)}")
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
        Logger.error("Audio input store delete failed for #{inspect(key)}: #{inspect(reason)}")
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

  def handle_call({:ensure_keypair, key}, _from, state) do
    existing = lookup(state.table, key)

    case existing[:client_keypair] do
      {<<_::256>>, priv} = keypair when is_binary(priv) ->
        {:reply, {:ok, keypair}, state}

      _ ->
        keypair = Noise.generate_static_keypair()
        merged = merge_defaults(existing, %{client_keypair: keypair}, key)

        with :ok <- :dets.insert(state.table, {key, merged}),
             :ok <- :dets.sync(state.table) do
          {:reply, {:ok, keypair}, state}
        else
          {:error, reason} ->
            Logger.error(
              "Audio input store keypair generation failed for #{inspect(key)}: #{inspect(reason)}"
            )

            {:reply, {:error, reason}, state}
        end
    end
  end

  # -- Private --

  defp lookup(table, key) do
    case :dets.lookup(table, key) do
      [{^key, cfg}] when is_map(cfg) -> cfg
      _ -> %{}
    end
  end

  # The default `friendly_name` is the capture card's slot; users can
  # rename per input via the UI. Every pairing-related field defaults
  # to `nil` (unpaired) rather than being synthesised, unlike
  # `Audio.Store`'s eager `client_id` generation — the keypair and
  # pairing state only come into existence via `ensure_client_keypair/2`
  # and `save_pairing/3` respectively.
  defp merge_defaults(existing, params, {slot_sub, _vid, _pid}) do
    %{
      friendly_name: pick(params, existing, :friendly_name, slot_sub),
      client_keypair: pick(params, existing, :client_keypair, nil),
      psk: pick(params, existing, :psk, nil),
      psk_id: pick(params, existing, :psk_id, nil),
      psk_category: pick(params, existing, :psk_category, nil),
      server_id: pick(params, existing, :server_id, nil),
      paired_at: pick(params, existing, :paired_at, nil)
    }
  end

  # Uses presence checks (via `Params.has_key?/2`) rather than `||`
  # chaining so that explicit `nil`/`false` values (e.g. clearing a
  # pairing field) are persisted instead of being silently overridden
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

  defp dets_path do
    if File.dir?("/data") do
      "/data/audio_inputs.dets"
    else
      Path.join([File.cwd!(), "_build", "audio_inputs.dets"])
    end
  end
end
