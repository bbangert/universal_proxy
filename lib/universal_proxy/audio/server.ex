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

  alias UniversalProxy.Audio.{MdnsDiscovery, Params, Player, Store}

  @pubsub UniversalProxy.PubSub
  @hotplug_interval 5_000
  @mdns_port_base 8928

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

    player_supervisor =
      Keyword.get(opts, :player_supervisor, UniversalProxy.Audio.PlayerSupervisor)

    player_module = Keyword.get(opts, :player_module, Player)
    mdns_discovery = Keyword.get(opts, :mdns_discovery, MdnsDiscovery)

    state = %{
      enumerate_module: enumerate_module,
      store: store,
      player_supervisor: player_supervisor,
      player_module: player_module,
      mdns_discovery: mdns_discovery,
      outputs: %{},
      # %{key => %{pid: pid, monitor: ref, mdns_port: 8928}}
      players: %{},
      port_base: Keyword.get(opts, :port_base, @mdns_port_base)
    }

    # Subscribe to our own state topic so binary-emitted volume/mute
    # events (Music Assistant's slider, group sync, etc.) get persisted
    # to DETS. Without this the cached `state.outputs[key].volume` and
    # the DETS row stay frozen at the last value BEAM itself set —
    # and the next respawn (kill -9, reboot) would restore that stale
    # value via `--initial-volume`. Server broadcasts on the same
    # topic from `update_config`, but those payloads don't carry an
    # `:event` key, so the handler ignores them.
    Phoenix.PubSub.subscribe(@pubsub, @topic_state)

    # Restart hygiene: any PlayerSupervisor children left over from a
    # previous Server incarnation (Server crashed but PlayerSupervisor
    # didn't, per `rest_for_one` semantics) are terminated. New players
    # are spawned by the immediate `:check_hotplug` below.
    #
    # NOTE: each `terminate_child` call blocks up to ~500 ms while the
    # Player's terminate/2 waits for the binary to acknowledge shutdown
    # (see `Audio.Player.@shutdown_grace_ms`). At N players that's
    # N × 500 ms of synchronous wait here — acceptable for occasional
    # Server-only restarts, but cold-reboot latency scales with the
    # number of active outputs.
    state = terminate_all_players(state)

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
      state1 = put_in(state.outputs[key], merged)

      # Normalize the payload before forwarding/broadcasting. Values
      # come from `merged` (post `Store.merge_defaults` /
      # `clamp_volume` / `!!`), so subscribers and the player can
      # never see caller-supplied garbage like `%{volume: "77"}`.
      # `update` is still the presence check so calls that didn't
      # ask to change a field don't re-send the cached value.
      normalized = Map.take(merged, Map.keys(update))

      state2 =
        if rename?(existing, merged) do
          # The binary's `--name` and mDNS TXT `name=` are baked in
          # at spawn time and there's no `set_name` stdin command.
          # The only way to propagate a rename is to restart the
          # player; the new instance gets the new name as a fresh
          # CLI arg and re-registers mDNS. ~5 s audio gap is
          # acceptable since renames are user-initiated and rare.
          state1 |> stop_player(key) |> start_player(merged)
        else
          forward_to_player(state1, key, normalized)
          state1
        end

      broadcast_state(key, normalized)
      {:reply, :ok, state2}
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
      state1 = put_in(state.outputs[key], merged)
      state2 = toggle_player(state1, merged, enabled?)
      broadcast_state(key, %{enabled: enabled?})
      {:reply, :ok, state2}
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

  # Binary-emitted volume/mute events flow back through PubSub. Persist
  # them so a respawn (kill -9, reboot) restores the actual last-known
  # value rather than whatever BEAM last wrote. Internal Server-issued
  # `:sendspin_state` payloads (from `update_config`/`set_enabled`) lack
  # the `:event` key and fall through to the catch-all clause below.
  def handle_info({:sendspin_state, key, %{event: "volume", value: v}}, state)
      when is_integer(v) do
    {:noreply, persist_binary_state(state, key, %{volume: clamp_volume(v)})}
  end

  def handle_info({:sendspin_state, key, %{event: "mute", value: m}}, state)
      when is_boolean(m) do
    {:noreply, persist_binary_state(state, key, %{muted: m})}
  end

  def handle_info({:sendspin_state, _key, _other}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    # A player crashed (we use `:temporary` so the DynamicSupervisor
    # doesn't auto-restart). Drop it from `state.players`; the next
    # hotplug poll will respawn if the output is still enabled.
    case Enum.find(state.players, fn {_k, %{monitor: m}} -> m == ref end) do
      {key, _entry} ->
        Logger.warning("Audio.Player for #{inspect(key)} went down: #{inspect(reason)}")
        {:noreply, %{state | players: Map.delete(state.players, key)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private --

  defp refresh_outputs(state) do
    enumerated = state.enumerate_module.safe()
    current_keys = MapSet.new(Map.keys(state.outputs))
    new_keys = MapSet.new(Map.keys(enumerated))

    added = MapSet.difference(new_keys, current_keys)
    removed = MapSet.difference(current_keys, new_keys)

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

    # Update state with new outputs map, then sync player processes
    # (stop removed, spawn enabled adds) BEFORE broadcasting. A
    # subscriber that reacts to `:sendspin_output_added` by calling
    # `Audio.set_volume/2` must find the player already started.
    #
    # The trailing `respawn_missing_players/1` makes refresh idempotent:
    # any enabled output without a live player is (re)spawned. This is
    # what brings the player back after the binary is killed externally
    # (`kill -9`) — the `:DOWN` handler clears `state.players[key]` but
    # leaves `outputs[key]` untouched, so the diff above shows "no adds,
    # no removes" and would never respawn on its own.
    new_state =
      %{state | outputs: final_outputs}
      |> stop_players(removed)
      |> start_players_for_enabled(merged_adds)
      |> respawn_missing_players()

    Enum.each(merged_adds, &broadcast_added/1)
    Enum.each(removed, &broadcast_removed/1)

    new_state
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

  # -- Player process management --

  defp start_players_for_enabled(state, merged_adds) do
    Enum.reduce(merged_adds, state, fn merged, acc ->
      if merged.enabled, do: start_player(acc, merged), else: acc
    end)
  end

  # Update DETS + the in-memory cache with values reported by the
  # binary. Only writes when the value actually differs — avoids
  # hammering DETS on every `time_sync` style event chatter.
  defp persist_binary_state(state, key, update) do
    case Map.fetch(state.outputs, key) do
      {:ok, existing} ->
        if changed?(existing, update) do
          case Store.save_config(state.store, key, update) do
            :ok ->
              {:ok, saved} = Store.get_config(state.store, key)
              merged = merge(key, hardware_fields(existing), saved)
              put_in(state.outputs[key], merged)

            {:error, reason} ->
              Logger.warning(
                "Audio.Server: persisting binary state for #{inspect(key)} failed: #{inspect(reason)}"
              )

              state
          end
        else
          state
        end

      :error ->
        # Output disappeared between broadcast and handler — drop.
        state
    end
  end

  defp changed?(existing, update) do
    Enum.any?(update, fn {k, v} -> Map.get(existing, k) != v end)
  end

  defp clamp_volume(v) when is_integer(v) and v >= 0 and v <= 100, do: v
  defp clamp_volume(v) when is_integer(v) and v < 0, do: 0
  defp clamp_volume(v) when is_integer(v) and v > 100, do: 100
  defp clamp_volume(_), do: 50

  # Convergence pass: ensure every enabled, currently-tracked output
  # has a live player. Called at the end of each `refresh_outputs/1`
  # so a player that died between polls (binary `kill -9`, DETS bounce,
  # etc.) is brought back without waiting for a hot-unplug-then-plug
  # cycle.
  defp respawn_missing_players(state) do
    state.outputs
    |> Enum.filter(fn {key, merged} ->
      merged.enabled and not Map.has_key?(state.players, key)
    end)
    |> Enum.reduce(state, fn {_key, merged}, acc -> start_player(acc, merged) end)
  end

  defp start_player(%{player_supervisor: nil} = state, _merged), do: state

  defp start_player(state, merged) do
    key = merged.key

    if Map.has_key?(state.players, key) do
      state
    else
      mdns_port = allocate_mdns_port(state)
      server_url = current_server_url(state)

      opts = [
        key: key,
        config: merged,
        mdns_port: mdns_port,
        server_url: server_url
      ]

      case DynamicSupervisor.start_child(
             state.player_supervisor,
             {state.player_module, opts}
           ) do
        {:ok, pid} ->
          ref = Process.monitor(pid)

          put_in(state.players[key], %{pid: pid, monitor: ref, mdns_port: mdns_port})

        {:error, reason} ->
          Logger.error("Audio.Player start failed for #{inspect(key)}: #{inspect(reason)}")

          state
      end
    end
  end

  defp stop_players(state, keys) do
    Enum.reduce(keys, state, fn key, acc -> stop_player(acc, key) end)
  end

  defp stop_player(%{player_supervisor: nil} = state, _key), do: state

  defp stop_player(state, key) do
    case Map.fetch(state.players, key) do
      {:ok, %{pid: pid, monitor: ref}} ->
        Process.demonitor(ref, [:flush])
        _ = DynamicSupervisor.terminate_child(state.player_supervisor, pid)
        %{state | players: Map.delete(state.players, key)}

      :error ->
        state
    end
  end

  defp toggle_player(state, merged, true), do: start_player(state, merged)
  defp toggle_player(state, merged, false), do: stop_player(state, merged.key)

  defp terminate_all_players(%{player_supervisor: nil} = state), do: state

  defp terminate_all_players(state) do
    state.player_supervisor
    |> safe_which_children()
    |> Enum.each(fn {_id, pid, _type, _modules} when is_pid(pid) ->
      _ = DynamicSupervisor.terminate_child(state.player_supervisor, pid)
    end)

    %{state | players: %{}}
  end

  defp safe_which_children(supervisor) do
    DynamicSupervisor.which_children(supervisor)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp rename?(existing, merged) do
    Map.get(existing, :friendly_name) != merged.friendly_name
  end

  # Caller passes pre-normalized values (atom keys, types matching
  # `Player.set_volume/2` and `set_muted/2` guards). The map's keys
  # double as the presence check — a call that didn't ask to change
  # `:volume` shouldn't re-push the cached value.
  defp forward_to_player(state, key, normalized) do
    case Map.fetch(state.players, key) do
      {:ok, %{pid: pid}} ->
        # The player can die between `Map.fetch` and the `GenServer.call`
        # — `:DOWN` arrives later. Without this guard the EXIT signal
        # would propagate through Server's own handle_call and crash
        # the whole audio subsystem. Swallow the exit; the next
        # hotplug poll will respawn the player.
        try do
          if Map.has_key?(normalized, :volume) do
            state.player_module.set_volume(pid, normalized.volume)
          end

          if Map.has_key?(normalized, :muted) do
            state.player_module.set_muted(pid, normalized.muted)
          end

          :ok
        catch
          :exit, reason ->
            Logger.warning(
              "Audio.Player call for #{inspect(key)} exited: #{inspect(reason)}; will respawn at next poll"
            )

            :ok
        end

      :error ->
        :ok
    end
  end

  defp allocate_mdns_port(state) do
    used =
      state.players
      |> Map.values()
      |> Enum.map(& &1.mdns_port)
      |> MapSet.new()

    Stream.iterate(state.port_base, &(&1 + 1))
    |> Enum.find(fn port -> not MapSet.member?(used, port) end)
  end

  defp current_server_url(state) do
    case state.mdns_discovery do
      nil ->
        nil

      mod ->
        try do
          case mod.current_server() do
            {:ok, url} -> url
            _ -> nil
          end
        rescue
          _ -> nil
        catch
          :exit, _ -> nil
        end
    end
  end
end
