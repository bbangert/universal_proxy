defmodule UniversalProxy.Audio.Server do
  @moduledoc """
  Tracks the live set of ALSA outputs and brokers state changes
  between hardware, DETS, and the rest of the system.

  Polls `Audio.Enumerate.safe/0` every 5 s — same cadence and
  rationale as `UniversalProxy.UART.Server`. Whenever the enumerated
  set diverges from the in-memory cache the server:

    * ensures a DETS row exists for new outputs (default `enabled =
      true`, `volume = 50`, `muted = false`, fresh `client_id`),
    * broadcasts a lifecycle event on PubSub,
    * keeps DETS rows around for outputs that disappear so user
      configuration survives unplugs and reboots.

  In Phase 1 this server does **not** spawn the C++ binary; that wiring
  arrives in `UniversalProxy.Audio.Player` (Phase 3) and slots in here
  next to the enumerate diff.

  ## PubSub conventions

  Three topics are owned by this module. Tags are static atoms — never
  built from binaries — to keep us off the atom-exhaustion gangplank.

      "sendspin:output_added"    {:sendspin_output_added, output_map}
      "sendspin:output_removed"  {:sendspin_output_removed, %{key: key}}
      "sendspin:state"           {:sendspin_state, key, partial_update}

  The `output_map` payload mirrors what `list_outputs/0` returns for a
  single entry — enumerate info merged with DETS config. The
  `:sendspin_state` channel carries partial updates from
  `Audio.Player` once Phase 3 lands; Phase 1 broadcasts on
  configuration writes so the LiveView can patch a single card without
  re-fetching the whole list.

  ## Test seams

  The enumerate module and the store reference are both injectable via
  `start_link/1` options. `Audio.Server` itself reads the enumerate
  module out of application env so callers can swap in a stub for
  isolated tests without hand-rolling supervisor trees.
  """

  use GenServer

  require Logger

  alias UniversalProxy.Audio.{Params, Store}

  @pubsub UniversalProxy.PubSub
  @hotplug_interval 5_000

  @topic_added "sendspin:output_added"
  @topic_removed "sendspin:output_removed"
  @topic_state "sendspin:state"

  @type key :: Store.output_key()

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
  Return all currently-present audio outputs as a list of merged maps
  (enumerate info + persisted config), sorted by `friendly_name`.
  """
  @spec list_outputs(GenServer.server()) :: [map()]
  def list_outputs(server \\ __MODULE__) do
    GenServer.call(server, :list_outputs)
  end

  @doc """
  Look up a single output by key. Returns `{:ok, merged_map}` if the
  output is currently present, `:error` otherwise.
  """
  @spec get_output(GenServer.server(), key()) :: {:ok, map()} | :error
  def get_output(server \\ __MODULE__, {slot_sub, _vid, _pid} = key) when is_binary(slot_sub) do
    GenServer.call(server, {:get_output, key})
  end

  @doc """
  Update one or more configuration fields for an output. Accepted keys:
  `:friendly_name`, `:volume`, `:muted`. Broadcasts a `:sendspin_state`
  message with the merged result. Returns `{:error, :not_found}` if
  the output isn't tracked or `{:error, reason}` if the DETS write
  fails.
  """
  @spec update_config(GenServer.server(), key(), map()) ::
          :ok | {:error, :not_found | term()}
  def update_config(server \\ __MODULE__, {slot_sub, _vid, _pid} = key, params)
      when is_binary(slot_sub) and is_map(params) do
    GenServer.call(server, {:update_config, key, params})
  end

  @doc """
  Toggle the `enabled` flag for an output. Phase 3 wires this into
  player-process lifecycle; Phase 1 just persists and broadcasts.
  Returns `{:error, :not_found}` if the output isn't tracked or
  `{:error, reason}` if the DETS write fails.
  """
  @spec set_enabled(GenServer.server(), key(), boolean()) ::
          :ok | {:error, :not_found | term()}
  def set_enabled(server \\ __MODULE__, {slot_sub, _vid, _pid} = key, enabled?)
      when is_binary(slot_sub) and is_boolean(enabled?) do
    GenServer.call(server, {:set_enabled, key, enabled?})
  end

  @doc """
  Force a hotplug poll synchronously. Tests use this to avoid waiting
  on the periodic timer.
  """
  @spec check_now(GenServer.server()) :: :ok
  def check_now(server \\ __MODULE__) do
    GenServer.call(server, :check_now)
  end

  # -- Server Callbacks --

  @impl true
  def init(opts) do
    enumerate_module = Keyword.get(opts, :enumerate_module) || configured_enumerate_module()
    store = Keyword.get(opts, :store, Store)
    interval = Keyword.get(opts, :hotplug_interval, @hotplug_interval)
    timer? = Keyword.get(opts, :start_timer, true)

    state = %{
      enumerate_module: enumerate_module,
      store: store,
      outputs: %{}
    }

    # Start the timer AFTER state is built so a future failure between
    # the two doesn't leak a timer pointing at a soon-to-be-dead PID.
    # The immediate `send(self(), :check_hotplug)` makes the first
    # poll fire on boot rather than after `interval` ms — Phase 4's
    # LiveView would otherwise show an empty `/audio` page for 5 s.
    if timer? and is_integer(interval) and interval > 0 do
      :timer.send_interval(interval, self(), :check_hotplug)
      send(self(), :check_hotplug)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:list_outputs, _from, state) do
    rows =
      state.outputs
      |> Map.values()
      |> Enum.sort_by(& &1.friendly_name)

    {:reply, rows, state}
  end

  def handle_call({:get_output, key}, _from, state) do
    {:reply, Map.fetch(state.outputs, key), state}
  end

  def handle_call({:update_config, key, params}, _from, state) do
    with {:ok, existing} <- Map.fetch(state.outputs, key),
         update = sanitize_update(params),
         :ok <- Store.save_config(state.store, key, update),
         {:ok, saved} <- Store.get_config(state.store, key) do
      merged = merge(key, hardware_fields(existing), saved)
      new_state = put_in(state.outputs[key], merged)
      broadcast_state(key, update)
      {:reply, :ok, new_state}
    else
      :error -> {:reply, {:error, :not_found}, state}
      {:error, _reason} = err -> {:reply, err, state}
    end
  end

  def handle_call({:set_enabled, key, enabled?}, _from, state) do
    with {:ok, existing} <- Map.fetch(state.outputs, key),
         :ok <- Store.save_config(state.store, key, %{enabled: enabled?}),
         {:ok, saved} <- Store.get_config(state.store, key) do
      merged = merge(key, hardware_fields(existing), saved)
      new_state = put_in(state.outputs[key], merged)
      broadcast_state(key, %{enabled: enabled?})
      {:reply, :ok, new_state}
    else
      :error -> {:reply, {:error, :not_found}, state}
      {:error, _reason} = err -> {:reply, err, state}
    end
  end

  def handle_call(:check_now, _from, state) do
    {:reply, :ok, refresh_outputs(state)}
  end

  @impl true
  def handle_info(:check_hotplug, state) do
    {:noreply, refresh_outputs(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private --

  defp refresh_outputs(state) do
    enumerated = state.enumerate_module.safe()
    current_keys = MapSet.new(Map.keys(state.outputs))
    new_keys = MapSet.new(Map.keys(enumerated))

    added = MapSet.difference(new_keys, current_keys)
    removed = MapSet.difference(current_keys, new_keys)

    # Build the new state first, then broadcast. A synchronous
    # subscriber that reacts to `:sendspin_output_added` by calling
    # `list_outputs/1` must see the new entry already in state — Phase
    # 3's Player startup will be driven from here and depends on it.
    {with_adds, merged_adds} =
      Enum.reduce(added, {state.outputs, []}, fn key, {acc, broadcasts} ->
        info = Map.fetch!(enumerated, key)

        case Store.save_config(state.store, key, %{}) do
          :ok ->
            case Store.get_config(state.store, key) do
              {:ok, saved} ->
                merged = merge(key, info, saved)
                {Map.put(acc, key, merged), [merged | broadcasts]}

              :error ->
                Logger.error(
                  "Audio store missing row immediately after save for #{inspect(key)}; skipping"
                )

                {acc, broadcasts}
            end

          {:error, reason} ->
            Logger.warning(
              "Audio store save_config failed for #{inspect(key)}: #{inspect(reason)}; skipping until next poll"
            )

            {acc, broadcasts}
        end
      end)

    final_outputs = Enum.reduce(removed, with_adds, &Map.delete(&2, &1))

    Enum.each(merged_adds, &broadcast_added/1)
    Enum.each(removed, &broadcast_removed/1)

    %{state | outputs: final_outputs}
  end

  defp merge(key, hardware, config) do
    hardware
    |> Map.put(:key, key)
    |> Map.merge(config)
  end

  @hardware_keys [:card_index, :alsa_device, :card_name]

  defp hardware_fields(output), do: Map.take(output, @hardware_keys)

  @allowed_update_keys [:friendly_name, :volume, :muted]

  defp sanitize_update(params), do: Params.take(params, @allowed_update_keys)

  # -- Broadcast helpers (topic strings hardcoded; tags are static
  # atoms, never derived from input). --

  defp broadcast_added(merged) do
    Phoenix.PubSub.broadcast(@pubsub, @topic_added, {:sendspin_output_added, merged})
  end

  defp broadcast_removed(key) do
    Phoenix.PubSub.broadcast(@pubsub, @topic_removed, {:sendspin_output_removed, %{key: key}})
  end

  defp broadcast_state(key, partial) do
    Phoenix.PubSub.broadcast(@pubsub, @topic_state, {:sendspin_state, key, partial})
  end

  defp configured_enumerate_module do
    Application.get_env(
      :universal_proxy,
      :audio_enumerate_module,
      UniversalProxy.Audio.Enumerate
    )
  end
end
