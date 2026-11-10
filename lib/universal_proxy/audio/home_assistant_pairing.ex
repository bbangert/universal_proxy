defmodule UniversalProxy.Audio.HomeAssistantPairing do
  @moduledoc """
  The one audio output whose Sendspin client is reported to Home Assistant,
  so HA can read its pairing token and hand it to Music Assistant
  (`UniversalProxy.ESPHome.Sendspin`, the `Espex.Sendspin` adapter).

  The ESPHome protocol carries one Sendspin client per device, but every
  output runs its own player. So nothing is reported until the user selects
  an output; the selection is persisted in `UniversalProxy.Audio.Store`
  along with the last Sendspin `client_id` seen for it.

  ## Keeping Home Assistant in step

  Espex has the `:sendspin` adapter only while a selection exists:
  `UniversalProxy.ESPHome.Supervisor.start_espex/2` reads `selected?/1`
  whenever Espex starts, and a change made while it runs is applied with
  `Espex.update_adapters/2`, then `Espex.disconnect_clients/1` so Home
  Assistant reconnects and re-reads the device capabilities. Both steps are
  retried with backoff (Espex down or mid-restart) until they succeed.

  HA reads the `client_id` only when it connects, so a new one for the
  selected output (its player listening for the first time, or with a new
  keypair) also disconnects the clients. The cached `client_id` survives
  unplugs and reboots, so HA keeps seeing the same id while the output is
  away or its player is starting; the token request answers `:not_ready`
  meanwhile.

  ## Unplugged outputs

  The selection is kept while its output is unplugged, and applies again
  when it comes back. Only an output that is present can be selected.

  Changes are broadcast on `topic/0` as `{:home_assistant_pairing, key |
  nil}`. The pairing token never passes through this process.
  """

  use GenServer

  require Logger

  alias UniversalProxy.Audio.{Server, Store}

  @pubsub UniversalProxy.PubSub
  @topic "sendspin:home_assistant_pairing"
  @state_topic "sendspin:state"
  @default_retry_ms 1_000
  @max_retry_ms 30_000

  @type key :: Store.output_key()
  @type selection :: Store.home_assistant_pairing()

  defstruct selection: nil,
            store: Store,
            audio_server: Server,
            pubsub: @pubsub,
            espex_server: Espex.Server,
            adapter: UniversalProxy.ESPHome.Sendspin,
            update_adapters: nil,
            disconnect_clients: nil,
            pending: nil,
            timer: nil,
            retry_ms: @default_retry_ms,
            backoff_ms: @default_retry_ms

  # -- Client API --

  @doc """
  Starts the process. Options: `:name` (default `#{inspect(__MODULE__)}`,
  `nil` for none), `:store` and `:audio_server` (the `Audio.Store` and
  `Audio.Server` to use), `:pubsub`, `:espex_server`, `:adapter` (the
  module wired as `:sendspin`), `:retry_ms`, and the Espex seams
  `:update_adapters` (`(server, changes) -> :ok | {:error, _}`) and
  `:disconnect_clients` (`(server) -> :ok`).
  """
  def start_link(opts \\ []) do
    gen_opts =
      case Keyword.get(opts, :name, __MODULE__) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "The PubSub topic selection changes are broadcast on."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "The current selection, or `nil` when no output is selected."
  @spec selection(GenServer.server()) :: selection() | nil
  def selection(server \\ __MODULE__), do: GenServer.call(server, :selection)

  @doc """
  Whether an output is selected; `false` while this process is down (the
  `catch :exit` idiom).
  """
  @spec selected?(GenServer.server()) :: boolean()
  def selected?(server \\ __MODULE__) do
    selection(server) != nil
  catch
    :exit, _ -> false
  end

  @doc """
  Select the output `key`, replacing any other selection.
  `{:error, :not_found}` when the output isn't present,
  `{:error, :unavailable}` while the audio subsystem is down, or
  `{:error, reason}` if DETS rejects the write.
  """
  @spec select(GenServer.server(), key()) ::
          :ok | {:error, :not_found | :unavailable | term()}
  def select(server \\ __MODULE__, {slot_sub, _vid, _pid} = key) when is_binary(slot_sub) do
    GenServer.call(server, {:select, key})
  end

  @doc "Clear the selection. `{:error, reason}` if DETS rejects the write."
  @spec clear(GenServer.server()) :: :ok | {:error, term()}
  def clear(server \\ __MODULE__), do: GenServer.call(server, :clear)

  # -- Server Callbacks --

  @impl true
  def init(opts) do
    t = %__MODULE__{
      store: Keyword.get(opts, :store, Store),
      audio_server: Keyword.get(opts, :audio_server, Server),
      pubsub: Keyword.get(opts, :pubsub, @pubsub),
      espex_server: Keyword.get(opts, :espex_server, Espex.Server),
      adapter: Keyword.get(opts, :adapter, UniversalProxy.ESPHome.Sendspin),
      update_adapters: Keyword.get(opts, :update_adapters, &Espex.update_adapters/2),
      disconnect_clients: Keyword.get(opts, :disconnect_clients, &Espex.disconnect_clients/1),
      retry_ms: Keyword.get(opts, :retry_ms, @default_retry_ms),
      backoff_ms: Keyword.get(opts, :retry_ms, @default_retry_ms)
    }

    Phoenix.PubSub.subscribe(t.pubsub, @state_topic)
    t = %{t | selection: load(t)}

    # Catch up with a `client_id` that arrived while this process was down.
    t =
      case t.selection && live_client_id(t, t.selection.key) do
        id when is_binary(id) -> observe_client_id(t, id)
        _none -> t
      end

    {:ok, t}
  end

  @impl true
  def handle_call(:selection, _from, t), do: {:reply, t.selection, t}

  def handle_call({:select, key}, _from, %{selection: %{key: key}} = t), do: {:reply, :ok, t}

  def handle_call({:select, key}, _from, t) do
    case get_output(t, key) do
      {:ok, output} ->
        id = Map.get(output, :sendspin_client_id)
        change(t, %{key: key, client_id: if(is_binary(id), do: id)})

      {:error, _reason} = error ->
        {:reply, error, t}
    end
  end

  def handle_call(:clear, _from, %{selection: nil} = t), do: {:reply, :ok, t}
  def handle_call(:clear, _from, t), do: change(t, nil)

  @impl true
  def handle_info({:sendspin_state, key, payload}, %{selection: %{key: key}} = t) do
    case client_id_of(payload) do
      id when is_binary(id) -> {:noreply, observe_client_id(t, id)}
      nil -> {:noreply, t}
    end
  end

  def handle_info({:retry, token}, %{timer: token} = t),
    do: {:noreply, apply_pending(%{t | timer: nil})}

  def handle_info(_msg, t), do: {:noreply, t}

  # -- Private --

  defp change(t, selection) do
    case store_put(t, selection) do
      :ok ->
        Logger.info(
          "Home Assistant Sendspin pairing: " <>
            if(selection, do: "reporting #{inspect(selection.key)}", else: "cleared")
        )

        Phoenix.PubSub.broadcast(t.pubsub, @topic, {:home_assistant_pairing, key_of(selection)})
        {:reply, :ok, apply_pending(%{t | selection: selection, pending: :update})}

      {:error, _reason} = error ->
        {:reply, error, t}
    end
  end

  # The binary's one-shot `listening` event, or `Audio.Server`'s re-publish
  # of it as `%{sendspin_client_id: id}`.
  defp client_id_of(%{event: "listening", client_id: id}) when is_binary(id), do: id
  defp client_id_of(%{sendspin_client_id: id}) when is_binary(id), do: id
  defp client_id_of(_payload), do: nil

  defp observe_client_id(%{selection: %{client_id: id}} = t, id), do: t

  defp observe_client_id(t, id) do
    selection = %{t.selection | client_id: id}

    case store_put(t, selection) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Home Assistant Sendspin pairing: could not persist the client id (#{inspect(reason)})"
        )
    end

    # An :update already pending reconnects once it has been applied.
    pending = t.pending || :reconnect
    apply_pending(%{t | selection: selection, pending: pending})
  end

  defp apply_pending(%{pending: nil} = t), do: t

  defp apply_pending(%{pending: :update} = t) do
    adapter = if t.selection, do: t.adapter

    case espex(fn -> t.update_adapters.(t.espex_server, sendspin: adapter) end) do
      :ok -> apply_pending(%{t | pending: :reconnect})
      error -> retry(t, error)
    end
  end

  defp apply_pending(%{pending: :reconnect} = t) do
    case espex(fn -> t.disconnect_clients.(t.espex_server) end) do
      :ok -> %{t | pending: nil, backoff_ms: t.retry_ms}
      error -> retry(t, error)
    end
  end

  defp retry(%{timer: token} = t, _error) when is_reference(token), do: t

  defp retry(t, error) do
    Logger.debug(
      "Home Assistant Sendspin pairing: Espex #{t.pending} failed (#{inspect(error)}); retrying"
    )

    token = make_ref()
    Process.send_after(self(), {:retry, token}, t.backoff_ms)
    %{t | timer: token, backoff_ms: min(t.backoff_ms * 2, @max_retry_ms)}
  end

  # Espex down or restarting: a call exits, its registry raises.
  defp espex(fun) do
    fun.()
  rescue
    ArgumentError -> {:error, :not_running}
  catch
    :exit, _reason -> {:error, :not_running}
  end

  defp load(t) do
    Store.get_home_assistant_pairing(t.store)
  catch
    :exit, _reason -> nil
  end

  defp store_put(t, selection) do
    Store.put_home_assistant_pairing(t.store, selection)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp get_output(t, key) do
    case Server.get_output(t.audio_server, key) do
      {:ok, output} -> {:ok, output}
      :error -> {:error, :not_found}
    end
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp live_client_id(t, key) do
    case get_output(t, key) do
      {:ok, output} -> Map.get(output, :sendspin_client_id)
      {:error, _reason} -> nil
    end
  end

  defp key_of(nil), do: nil
  defp key_of(%{key: key}), do: key
end
