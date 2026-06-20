defmodule UniversalProxy.ESPHome.PskStore do
  @moduledoc """
  DETS-backed persistence for the ESPHome Native API Noise pre-shared key.

  Implements the `Espex.PskStore` behaviour. The native API starts in
  plaintext; the first time Home Assistant connects it provisions a 32-byte
  PSK via `NoiseEncryptionSetKeyRequest`, and espex calls `store_psk/1` here
  to durably persist it *before* applying the key. From then on the session
  is encrypted.

  **The device never mints a key.** This store is a pure persistence sink for
  the HA-provisioned key. Encrypted ⇔ a key is present: `load_psk/0` returns
  the raw 32-byte binary when one exists, `nil` otherwise. `clear/0` deletes
  the key (the Security tab's Reset action), returning the proxy to plaintext.

  The DETS file lives on the writable data partition on Nerves
  (`/data/esphome_psk.dets`) and in `_build/` on the host for development.
  It is owned at the top-level application supervisor (a peer to `ConfigStore`,
  not inside `ESPHome.Supervisor`) so a `restart/0` of the ESPHome subtree
  never closes the DETS file.
  """

  @behaviour Espex.PskStore

  use GenServer

  require Logger

  alias Phoenix.PubSub

  @psk_key :psk
  @topic "esphome:psk"

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
  Persist the HA-provisioned 32-byte Noise PSK (the `Espex.PskStore`
  callback). Writes + syncs DETS, broadcasts the new key, then replies `:ok`.
  On a DETS error replies `{:error, reason}` so espex aborts the key apply.
  """
  @impl Espex.PskStore
  def store_psk(<<_::256>> = psk) do
    GenServer.call(__MODULE__, {:store, psk})
  end

  @doc """
  Return the persisted raw 32-byte PSK, or `nil` when plaintext. Used by the
  supervisor boot seed and by `SecurityLive`.
  """
  @spec load_psk(GenServer.server()) :: <<_::256>> | nil
  def load_psk(server \\ __MODULE__) do
    GenServer.call(server, :load)
  end

  @doc """
  Clear the persisted key, returning the proxy to plaintext. Deletes + syncs
  DETS and broadcasts `nil`. Returns `{:error, reason}` if the DETS delete or
  sync fails (so a caller doesn't report a reset that didn't happen).
  """
  @spec clear(GenServer.server()) :: :ok | {:error, term()}
  def clear(server \\ __MODULE__) do
    GenServer.call(server, :clear)
  end

  @doc "The PubSub topic broadcast on every key change."
  @spec topic() :: String.t()
  def topic, do: @topic

  # -- Server Callbacks --

  @impl GenServer
  def init(opts) do
    table_name = Keyword.get(opts, :table, :esphome_psk)
    path = Keyword.get(opts, :dets_path) || dets_path()

    case :dets.open_file(table_name, file: to_charlist(path), type: :set) do
      {:ok, table} ->
        Logger.info("ESPHome PSK store opened at #{path}")
        {:ok, %{table: table}}

      {:error, reason} ->
        Logger.error("ESPHome PSK store failed to open #{path}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl GenServer
  def terminate(_reason, %{table: table}) do
    :dets.close(table)
  end

  @impl GenServer
  def handle_call({:store, psk}, _from, state) do
    with :ok <- :dets.insert(state.table, {@psk_key, psk}),
         :ok <- :dets.sync(state.table) do
      broadcast(psk)
      {:reply, :ok, state}
    else
      {:error, reason} ->
        Logger.error("ESPHome PSK store write failed: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:load, _from, state) do
    {:reply, read_psk(state.table), state}
  end

  def handle_call(:clear, _from, state) do
    with :ok <- :dets.delete(state.table, @psk_key),
         :ok <- :dets.sync(state.table) do
      broadcast(nil)
      {:reply, :ok, state}
    else
      {:error, reason} ->
        Logger.error("ESPHome PSK store clear failed: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  # -- Private --

  defp read_psk(table) do
    case :dets.lookup(table, @psk_key) do
      [{@psk_key, <<_::256>> = psk}] -> psk
      _ -> nil
    end
  end

  defp broadcast(key_or_nil) do
    PubSub.broadcast(UniversalProxy.PubSub, @topic, {:esphome_psk, key_or_nil})
  end

  defp dets_path do
    if File.dir?("/data") do
      "/data/esphome_psk.dets"
    else
      Path.join([File.cwd!(), "_build", "esphome_psk.dets"])
    end
  end
end
