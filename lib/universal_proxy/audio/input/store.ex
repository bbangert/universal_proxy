defmodule UniversalProxy.Audio.Input.Store do
  @moduledoc """
  DETS-backed persistence for Sendspin audio-**input** (capture card)
  configuration and pairing records.

  Keyed by `{slot_sub, vendor_id, product_id}` — the same shape as
  `UniversalProxy.Audio.Store` and `UniversalProxy.UART.Store`. For
  built-in capture devices the VID/PID slots are `nil` and `slot_sub`
  is the long ALSA card name.

  Stored value shape:

      %{
        friendly_name: String.t(),
        client_keypair: {pub :: <<_::256>>, priv :: binary()} | nil,
        pairing_psk: <<_::256>> | nil,
        pairings: [
          %{
            psk: <<_::256>>,
            psk_id: String.t(),
            server_id: String.t(),
            paired_at: DateTime.t(),
            last_used: DateTime.t()
          }
        ]
      }

  Unlike `Audio.Store`'s `client_id` (generated eagerly on every save),
  `client_keypair` is generated **lazily** on first use via
  `ensure_client_keypair/2` — a config with no pairing yet has every
  pairing-related field `nil`, including the keypair, until something
  actually needs it (the connection FSM sending `client/init`). This
  mirrors the Sendspin ground-truth note that the static keypair is a
  long-lived identity, persisted across reboots, that must be stable
  across reconnections.

  `pairing_psk` is the input's Sendspin **pairing PSK** — the secret behind
  its pairing token (`pairing_token/2`), which an operator pastes into
  Music Assistant to pair over the Pairing PSK method. Like the keypair it is
  minted lazily from the CSPRNG (`ensure_pairing_psk/2`), long-lived, and
  not pairing *state*: a pairing does not consume it and `clear_pairing/2`
  leaves it alone. `regenerate_pairing_psk/2` replaces it (the operator's
  "Regenerate pairing token").

  `pairings` are the input's **pairing records** (`pairing.md` "Pairing
  Records"): one long-term PSK per server it has paired with, bound to that
  server's `server_id`. Up to 8 are kept; a new pairing replaces the record
  for the same server, else is added, evicting the least recently used record
  — never the one the caller marks as backing its open connection — so a
  pairing never fails for lack of storage.

  Rows written before Sendspin 1.0.0-rc1 held one flat record (`psk`,
  `psk_id`, `psk_category`, `server_id`, `paired_at`). They are converted on
  read: a record with a 32-byte PSK and a `server_id` becomes the first entry
  of `pairings` (its `psk_id` recomputed, not trusted), anything else is
  dropped, and the flat keys are discarded on the next write.

  The file holds private key material, so it is kept owner-only (`0600`).

  The DETS file lives on the writable data partition on Nerves
  (`/data/audio_inputs.dets`) and in `_build/` on the host for
  development. Tests can override via the `:dets_path`, `:table`, and
  `:name` options to `start_link/1`.
  """

  use GenServer

  require Logger

  alias UniversalProxy.Audio.Params
  alias UniversalProxy.Sendspin.Noise
  alias UniversalProxy.Sendspin.Pairing
  alias UniversalProxy.Sendspin.PairingToken

  @default_table :audio_inputs

  @type slot_sub :: String.t()
  @type vendor_id :: non_neg_integer() | nil
  @type product_id :: non_neg_integer() | nil
  @type input_key :: {slot_sub(), vendor_id(), product_id()}

  @type keypair :: {pub :: <<_::256>>, priv :: binary()}

  @type config :: %{
          friendly_name: String.t(),
          client_keypair: keypair() | nil,
          pairing_psk: <<_::256>> | nil,
          pairings: [pairing_record()]
        }

  @type pairing_record :: %{
          psk: <<_::256>>,
          psk_id: String.t(),
          server_id: String.t(),
          paired_at: DateTime.t(),
          last_used: DateTime.t()
        }

  # `pairing.md`: a client MUST be able to store at least 5 records.
  @max_pairings 8

  @legacy_pairing_keys [:psk, :psk_id, :psk_category, :server_id, :paired_at]

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
  Get the persisted pairing PSK for `key`, minting and persisting a fresh
  32-byte CSPRNG one if none exists yet. Stable across calls and restarts.

  Returns `{:ok, psk}` or `{:error, reason}` if DETS rejects a first-use
  write. The PSK is a long-lived pairing secret: never log or broadcast it.
  """
  @spec ensure_pairing_psk(GenServer.server(), input_key()) ::
          {:ok, <<_::256>>} | {:error, term()}
  def ensure_pairing_psk(server \\ __MODULE__, {slot_sub, _vid, _pid} = key)
      when is_binary(slot_sub) do
    GenServer.call(server, {:ensure_pairing_psk, key})
  end

  @doc """
  The input's version-0 Sendspin pairing token (`"SP:0…"`), built from its
  static public key and pairing PSK — both minted on first use.

  `{:ok, token}` or `{:error, reason}`; the token never appears in any other
  return value, so it cannot leak through a logged error tuple.
  """
  @spec pairing_token(GenServer.server(), input_key()) :: {:ok, String.t()} | {:error, term()}
  def pairing_token(server \\ __MODULE__, {slot_sub, _vid, _pid} = key)
      when is_binary(slot_sub) do
    with {:ok, {pub, _priv}} <- ensure_client_keypair(server, key),
         {:ok, pairing_psk} <- ensure_pairing_psk(server, key) do
      {:ok, PairingToken.encode_psk_token(pub, pairing_psk)}
    end
  end

  @doc """
  The Sendspin `client_id` for a static public key: base64url encoding
  (no padding) of the raw 32-byte X25519 public key, per the
  ground-truth doc's `client_id` derivation (§10).
  """
  @spec client_id(<<_::256>>) :: String.t()
  def client_id(<<pub::binary-size(32)>>), do: Base.url_encode64(pub, padding: false)

  @doc """
  Persist a completed pairing: the new long-term `psk` for `server_id` (the
  server's static pubkey), `paired_at` defaulting to now. The record for the
  same server is replaced, else one is added, evicting the least recently
  used record at capacity but never the one whose `psk_id` is `opts[:protect]`
  (the record backing the caller's open connection). `friendly_name`, the
  keypair and the pairing PSK are untouched.
  """
  @spec save_pairing(GenServer.server(), input_key(), map(), keyword()) :: :ok | {:error, term()}
  def save_pairing(server \\ __MODULE__, {slot_sub, _vid, _pid} = key, attrs, opts \\ [])
      when is_binary(slot_sub) and is_map(attrs) do
    psk = Params.get(attrs, :psk)
    paired_at = Params.get(attrs, :paired_at, DateTime.utc_now())

    record = %{
      psk: psk,
      psk_id: Pairing.psk_id_for(psk),
      server_id: Params.get(attrs, :server_id),
      paired_at: paired_at,
      last_used: paired_at
    }

    GenServer.call(server, {:save_pairing, key, record, Keyword.get(opts, :protect)})
  end

  @doc "The pairing records of a config (as `get_config/2` returns it), most recently used first."
  @spec pairings(map()) :: [pairing_record()]
  def pairings(config) when is_map(config) do
    config |> Map.get(:pairings, []) |> Enum.sort_by(& &1.last_used, {:desc, DateTime})
  end

  @doc """
  Note that the record with `psk_id` just authenticated a connection, for the
  least-recently-used eviction order. Best effort and asynchronous.
  """
  @spec touch_pairing(GenServer.server(), input_key(), String.t()) :: :ok
  def touch_pairing(server \\ __MODULE__, {slot_sub, _vid, _pid} = key, psk_id)
      when is_binary(slot_sub) and is_binary(psk_id) do
    GenServer.cast(server, {:touch_pairing, key, psk_id})
  end

  @doc """
  Remove the pairing record matching `server_id: id` or `psk_id: id`.
  Removing a record that isn't there is `:ok`.
  """
  @spec remove_pairing(
          GenServer.server(),
          input_key(),
          [server_id: String.t()] | [psk_id: String.t()]
        ) ::
          :ok | {:error, term()}
  def remove_pairing(server \\ __MODULE__, {slot_sub, _vid, _pid} = key, [{field, id}])
      when is_binary(slot_sub) and field in [:server_id, :psk_id] and is_binary(id) do
    GenServer.call(server, {:remove_pairing, key, field, id})
  end

  @doc """
  Clear every pairing record of a device, leaving `friendly_name`,
  `client_keypair` and `pairing_psk` untouched — the keypair is an identity
  and the pairing PSK a long-lived credential, not pairing state.
  """
  @spec clear_pairing(GenServer.server(), input_key()) :: :ok | {:error, term()}
  def clear_pairing(server \\ __MODULE__, {slot_sub, _vid, _pid} = key)
      when is_binary(slot_sub) do
    save_config(server, key, %{pairings: []})
  end

  @doc """
  Replace the input's pairing PSK with a fresh one, invalidating its pairing
  token. Existing pairing records are unaffected.
  """
  @spec regenerate_pairing_psk(GenServer.server(), input_key()) :: :ok | {:error, term()}
  def regenerate_pairing_psk(server \\ __MODULE__, {slot_sub, _vid, _pid} = key)
      when is_binary(slot_sub) do
    save_config(server, key, %{pairing_psk: Pairing.generate_psk()})
  end

  # -- Server Callbacks --

  @impl true
  def init(opts) do
    # Trap exits so terminate/2 runs on a supervisor shutdown too (not only
    # on a crash) and closes the DETS table cleanly.
    Process.flag(:trap_exit, true)

    table_name = Keyword.get(opts, :table, @default_table)
    path = Keyword.get(opts, :dets_path) || dets_path()

    case :dets.open_file(table_name, file: to_charlist(path), type: :set) do
      {:ok, table} ->
        restrict_permissions(path)
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
        [{^key, cfg}] when is_map(cfg) -> {:ok, normalize(cfg)}
        _ -> :error
      end

    {:reply, result, state}
  end

  def handle_call({:save_pairing, key, record, protect}, _from, state) do
    existing = lookup(state.table, key)
    pairings = upsert_pairing(Map.get(existing, :pairings, []), record, protect)
    {:reply, write(state.table, key, merge_defaults(existing, %{pairings: pairings}, key)), state}
  end

  def handle_call({:remove_pairing, key, field, id}, _from, state) do
    existing = lookup(state.table, key)
    pairings = Enum.reject(Map.get(existing, :pairings, []), &(Map.fetch!(&1, field) == id))
    {:reply, write(state.table, key, merge_defaults(existing, %{pairings: pairings}, key)), state}
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
          {{_slot, _vid, _pid} = key, cfg}, acc when is_map(cfg) ->
            Map.put(acc, key, normalize(cfg))

          _other, acc ->
            acc
        end,
        %{},
        state.table
      )

    {:reply, all, state}
  end

  def handle_call({:ensure_pairing_psk, key}, _from, state) do
    existing = lookup(state.table, key)

    case existing[:pairing_psk] do
      <<_::256>> = psk ->
        {:reply, {:ok, psk}, state}

      _ ->
        psk = Pairing.generate_psk()
        merged = merge_defaults(existing, %{pairing_psk: psk}, key)

        with :ok <- :dets.insert(state.table, {key, merged}),
             :ok <- :dets.sync(state.table) do
          {:reply, {:ok, psk}, state}
        else
          {:error, reason} ->
            Logger.error(
              "Audio input store pairing PSK generation failed for #{inspect(key)}: " <>
                inspect(reason)
            )

            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:ensure_keypair, key}, _from, state) do
    existing = lookup(state.table, key)

    case existing[:client_keypair] do
      # Both halves must be exactly 32 bytes (X25519). A malformed row
      # (e.g. a truncated priv from some earlier bug) falls through to
      # the regenerate-and-persist branch below instead of being
      # returned forever — otherwise ensure_client_keypair/2 could
      # never heal a bad record and every later Noise setup using it
      # would fail.
      {<<_::256>>, <<_::256>>} = keypair ->
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

  @impl true
  def handle_cast({:touch_pairing, key, psk_id}, state) do
    existing = lookup(state.table, key)
    now = DateTime.utc_now()

    pairings =
      Enum.map(Map.get(existing, :pairings, []), fn
        %{psk_id: ^psk_id} = record -> %{record | last_used: now}
        record -> record
      end)

    _ = write(state.table, key, merge_defaults(existing, %{pairings: pairings}, key))
    {:noreply, state}
  end

  # -- Private --

  defp lookup(table, key) do
    case :dets.lookup(table, key) do
      [{^key, cfg}] when is_map(cfg) -> normalize(cfg)
      _ -> %{}
    end
  end

  defp write(table, key, cfg) do
    with :ok <- :dets.insert(table, {key, cfg}),
         :ok <- :dets.sync(table) do
      :ok
    else
      {:error, reason} = error ->
        Logger.error("Audio input store write failed for #{inspect(key)}: #{inspect(reason)}")
        error
    end
  end

  # Replace the same server's record, else add one, evicting the least
  # recently used unprotected records past capacity.
  defp upsert_pairing(pairings, record, protect) do
    others = Enum.reject(pairings, &(&1.server_id == record.server_id))
    keep = [record | Enum.sort_by(others, & &1.last_used, {:desc, DateTime})]

    if length(keep) <= @max_pairings do
      keep
    else
      {protected, evictable} = Enum.split_with(tl(keep), &(&1.psk_id == protect))
      [record | protected] ++ Enum.take(evictable, @max_pairings - 1 - length(protected))
    end
  end

  # Convert a row written before rc1 (one flat record) to the `pairings` list.
  defp normalize(%{pairings: pairings} = cfg) when is_list(pairings),
    do: Map.drop(cfg, @legacy_pairing_keys)

  defp normalize(cfg) do
    cfg |> Map.drop(@legacy_pairing_keys) |> Map.put(:pairings, legacy_pairings(cfg))
  end

  defp legacy_pairings(%{psk: <<_::256>> = psk, server_id: server_id} = cfg)
       when is_binary(server_id) and byte_size(server_id) == 43 do
    paired_at =
      case Map.get(cfg, :paired_at) do
        %DateTime{} = at -> at
        _other -> DateTime.from_unix!(0)
      end

    [
      %{
        psk: psk,
        psk_id: Pairing.psk_id_for(psk),
        server_id: server_id,
        paired_at: paired_at,
        last_used: paired_at
      }
    ]
  end

  defp legacy_pairings(_cfg), do: []

  # The default `friendly_name` is the capture card's slot; users can
  # rename per input via the UI. The keypair and pairing PSK default to
  # `nil` and `pairings` to `[]` (unpaired) rather than being synthesised,
  # unlike `Audio.Store`'s eager `client_id` generation — they only come into
  # existence via `ensure_client_keypair/2`, `ensure_pairing_psk/2` and
  # `save_pairing/4`.
  defp merge_defaults(existing, params, {slot_sub, _vid, _pid}) do
    %{
      friendly_name: pick(params, existing, :friendly_name, slot_sub),
      client_keypair: pick(params, existing, :client_keypair, nil),
      pairing_psk: pick(params, existing, :pairing_psk, nil),
      pairings: pick(params, existing, :pairings, [])
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

  # Owner-only: the table holds private keys and PSKs. Best effort — a
  # filesystem without POSIX modes keeps working.
  defp restrict_permissions(path) do
    case File.chmod(path, 0o600) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Audio input store chmod #{path} failed: #{inspect(reason)}")
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
