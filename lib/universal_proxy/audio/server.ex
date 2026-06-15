defmodule UniversalProxy.Audio.Server do
  @moduledoc """
  Tracks the live set of ALSA outputs and brokers state changes
  between hardware, DETS, and the rest of the system.

  Re-enumerates `Audio.Enumerate.safe/0` on `sound`-subsystem kernel
  uevents (via `NervesUEvent`, debounced) — falling back to a 5 s poll
  only on host/dev where uevents aren't available. Either way an initial
  enumeration runs at boot. Whenever the enumerated set diverges from the
  in-memory cache the server:

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
  # Delay between a `sound` uevent and the re-enumeration it triggers:
  # gives ALSA a beat to finish creating the card's sub-devices, and
  # coalesces the burst of uevents one card emits into a single check.
  @hotplug_debounce_ms 1_000
  @mdns_port_base 8928
  # Service types we always publish — used at boot to send a
  # pre-emptive TTL=0 PTR goodbye so peers like Music Assistant's
  # python-zeroconf evict any stale cache from a previous (ungraceful)
  # shutdown. Without this a hard power-cycle can leave MA stuck for
  # the full mDNS TTL (~120 s) before it sees a fresh `Added` event.
  @preemptive_goodbye_types ["_sendspin._tcp"]
  # TCP port range cap. The C++ binary's `--mdns-port` arg has no
  # upper-bound check on the BEAM side, but the kernel rejects bind()
  # with EINVAL for anything > 65535. Capping here turns "binary
  # immediately fails to bind" into an explicit `nil` from the
  # allocator that the caller logs and skips.
  @mdns_port_max 65_535

  @topic_added "sendspin:output_added"
  @topic_removed "sendspin:output_removed"
  @topic_state "sendspin:state"
  # AudioManager's Bluetooth connection topic — the hotplug trigger for BT
  # outputs, which produce no kernel `sound` uevent. Kept as a literal (not a
  # module ref) so Audio.Server carries no compile-time dep on the BT subtree.
  @bt_audio_topic "bluetooth:audio"
  @bluealsa_pcms_topic "bluealsa:pcms"

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
    mdns_module = Keyword.get(opts, :mdns_module, MdnsLite)

    state = %{
      enumerate_module: enumerate_module,
      store: store,
      player_supervisor: player_supervisor,
      player_module: player_module,
      mdns_discovery: mdns_discovery,
      mdns_module: mdns_module,
      outputs: %{},
      # %{key => %{pid: pid, monitor: ref, mdns_port: 8928}}
      players: %{},
      port_base: Keyword.get(opts, :port_base, @mdns_port_base),
      # Keys whose `Player.start_link` returned `:binary_missing` —
      # `respawn_missing_players/1` skips them so we don't log an
      # error every 5 s for the life of the firmware. Cleared on
      # hotplug remove or `set_enabled(_, true)` (user-initiated
      # retry signal).
      binary_missing: MapSet.new(),
      # Ports the allocator picked but the player died on (typically
      # because another process held the port). The allocator skips
      # these so we don't allocate the same dud port over and over.
      # Never explicitly cleared — port space is 56k+ wide, so even
      # a worst-case crash rate takes years to exhaust.
      unusable_ports: MapSet.new(),
      # Derived live-state per output, fed by binary-emitted PubSub
      # events. LiveView mounts can read this through `list_outputs/0`
      # so a late subscriber doesn't have to wait for the next event to
      # learn that the player is already connected and streaming.
      # %{key => %{connection: :connected | :disconnected | :unknown,
      #            stream: %{codec, sample_rate, bit_depth, channels} | nil,
      #            last_error: String.t() | nil}}
      connection_state: %{},
      # Debounce flag: a `sound` uevent schedules one delayed
      # `:check_hotplug` and sets this; the burst of sub-device uevents a
      # single card emits then coalesces into that one re-enumeration.
      hotplug_pending: false
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

    # Bluetooth A2DP connect/disconnect is the hotplug trigger for BT outputs
    # (they emit no kernel `sound` uevent — see the `:bt_audio` handler). Inert
    # on non-BT targets: nothing broadcasts on these topics there.
    Phoenix.PubSub.subscribe(@pubsub, @bt_audio_topic)
    # The authoritative BT trigger: `Bluez.BlueAlsa` broadcasts here the instant
    # a BlueALSA PCM is added/removed — covering bluetoothd auto-reconnects (no
    # `AudioManager` event) and the Connect-returns-before-PCM-ready race that a
    # `:bt_audio` connection event alone would miss. Literal (no compile dep on
    # the BT subtree): `UniversalProxy.Bluez.BlueAlsa.pcms_topic/0`.
    Phoenix.PubSub.subscribe(@pubsub, @bluealsa_pcms_topic)

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

    # Pre-emptive mDNS goodbye for every service type we publish. After
    # an ungraceful shutdown we never sent a TTL=0 record, so peers may
    # still have cached PTR entries pointing at us. Clearing those
    # caches now means the announces from `Audio.Player.init/1` produce
    # a fresh `Added` event on peers instead of a silent refresh.
    send_preemptive_goodbyes(state)

    # Hotplug detection. ALSA cards change only on discrete events, so
    # prefer kernel uevents over a timer: subscribe to `NervesUEvent` and
    # re-enumerate on `sound`-subsystem changes (debounced). Only when
    # uevents aren't available (host/dev — `nerves_uevent` runs on Nerves
    # targets only) do we fall back to the periodic `interval` poll. Either
    # way the immediate `:check_hotplug` enumerates once at boot so the
    # `/audio` page isn't empty until the first event. `start_timer: false`
    # (tests) disables both; they drive enumeration via `check_now/1`.
    if timer? do
      unless subscribe_uevents() do
        if is_integer(interval) and interval > 0,
          do: :timer.send_interval(interval, self(), :check_hotplug)
      end

      send(self(), :check_hotplug)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:list_outputs, _from, state) do
    rows =
      state.outputs
      |> Map.values()
      |> Enum.map(&merge_connection_state(&1, state.connection_state))
      |> Enum.sort_by(& &1.friendly_name)

    {:reply, rows, state}
  end

  def handle_call({:get_output, key}, _from, state) do
    case Map.fetch(state.outputs, key) do
      {:ok, output} ->
        {:reply, {:ok, merge_connection_state(output, state.connection_state)}, state}

      :error ->
        {:reply, :error, state}
    end
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
        cond do
          rename?(existing, merged) and merged.enabled ->
            # The binary's `--name` and mDNS TXT `name=` are baked in
            # at spawn time and there's no `set_name` stdin command.
            # The only way to propagate a rename is to restart the
            # player; the new instance gets the new name as a fresh
            # CLI arg and re-registers mDNS. ~5 s audio gap is
            # acceptable since renames are user-initiated and rare.
            state1 |> stop_player(key) |> start_player(merged)

          rename?(existing, merged) ->
            # Output is disabled. Stop any stale player (defensive —
            # toggle_player should already have done this on the
            # `set_enabled(_, false)` that disabled it) but don't
            # spawn a fresh one. Spawning a player for an output the
            # user just disabled would broadcast it via mDNS again
            # and stream audio they explicitly turned off.
            stop_player(state1, key)

          true ->
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

      # User-initiated enable signals a retry intent. Clear any sticky
      # `binary_missing` flag for this key so the next convergence
      # pass actually tries to spawn the player again.
      state1 =
        if enabled?,
          do: %{state1 | binary_missing: MapSet.delete(state1.binary_missing, key)},
          else: state1

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
    {:noreply, refresh_outputs(%{state | hotplug_pending: false})}
  end

  # Kernel uevent (via NervesUEvent's PropertyTable). Only `sound`-subsystem
  # changes can move the ALSA output set; everything else is ignored.
  # Debounced through `hotplug_pending` so one card's burst of sub-device
  # uevents triggers a single re-enumeration.
  def handle_info(%PropertyTable.Event{property: path}, state) do
    if "sound" in path do
      {:noreply, schedule_hotplug(state)}
    else
      {:noreply, state}
    end
  end

  # A Bluetooth A2DP device coming or going changes the BlueALSA PCM set (via
  # the composite enumerate's `Bluetooth.AudioSink`) but emits **no** kernel
  # `sound` uevent — a BlueALSA PCM is a userspace D-Bus object, not an ALSA
  # card. So `AudioManager`'s connection broadcasts are the hotplug trigger for
  # BT outputs: re-enumerate (debounced) on connect/disconnect and when a fresh
  # pairing reaches the `connected` step. Harmless on non-BT targets (the topic
  # never fires there).
  def handle_info({:bt_audio, :connection, _mac, _status}, state),
    do: {:noreply, schedule_hotplug(state)}

  def handle_info({:bt_audio, :pairing, _mac, :connected}, state),
    do: {:noreply, schedule_hotplug(state)}

  # The BlueALSA PCM set changed (Bluez.BlueAlsa saw an org.bluealsa
  # InterfacesAdded/Removed). Re-enumerate so a connected/disconnected headset
  # surfaces/drops regardless of how it (dis)connected.
  def handle_info({:bluealsa_pcms_changed}, state),
    do: {:noreply, schedule_hotplug(state)}

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

  # Track derived connection / stream state for late LiveView subscribers.
  # Without this, switching between Overview and /audio resets the badge
  # to "Stopped" / "Idle" until the binary's next event lands — even when
  # the player is actively streaming.
  def handle_info({:sendspin_state, key, %{event: "connected"}}, state) do
    {:noreply, update_connection_state(state, key, %{connection: :connected, last_error: nil})}
  end

  def handle_info({:sendspin_state, key, %{event: "disconnected"}}, state) do
    {:noreply, update_connection_state(state, key, %{connection: :disconnected, stream: nil})}
  end

  def handle_info({:sendspin_state, key, %{event: "stream_start"} = payload}, state) do
    stream = %{
      codec: Map.get(payload, :codec),
      sample_rate: Map.get(payload, :sample_rate),
      channels: Map.get(payload, :channels),
      bit_depth: Map.get(payload, :bit_depth)
    }

    {:noreply, update_connection_state(state, key, %{stream: stream})}
  end

  def handle_info({:sendspin_state, key, %{event: "stream_end"}}, state) do
    {:noreply, update_connection_state(state, key, %{stream: nil})}
  end

  def handle_info({:sendspin_state, key, %{event: "error"} = payload}, state) do
    # Bound the cached error string. The binary's `:msg` may be a
    # server-forwarded value of arbitrary size; a multi-MB string would
    # otherwise sit in Server state and ship over the LiveView socket
    # on every diff touching this card.
    msg =
      payload
      |> Map.get(:msg, "error")
      |> to_string()
      |> String.slice(0, 256)

    {:noreply, update_connection_state(state, key, %{last_error: msg})}
  end

  def handle_info({:sendspin_state, key, %{event: "shutdown"}}, state) do
    {:noreply, update_connection_state(state, key, %{connection: :disconnected, stream: nil})}
  end

  def handle_info({:sendspin_state, _key, _other}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    # A player crashed (we use `:temporary` so the DynamicSupervisor
    # doesn't auto-restart). Drop it from `state.players`; the next
    # hotplug poll will respawn if the output is still enabled.
    case Enum.find(state.players, fn {_k, %{monitor: m}} -> m == ref end) do
      {key, %{mdns_port: port}} ->
        Logger.warning("Audio.Player for #{inspect(key)} went down: #{inspect(reason)}")

        state =
          %{state | players: Map.delete(state.players, key)}
          |> maybe_mark_port_unusable(port, reason)
          |> reset_connection_state(key)

        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private --

  # Schedule one debounced re-enumeration. Shared by the kernel-uevent and
  # Bluetooth-connection triggers: `hotplug_pending` coalesces a burst (a
  # card's sub-device uevents, or pairing's connect events) into a single
  # `:check_hotplug`.
  defp schedule_hotplug(%{hotplug_pending: true} = state), do: state

  defp schedule_hotplug(state) do
    Process.send_after(self(), :check_hotplug, @hotplug_debounce_ms)
    %{state | hotplug_pending: true}
  end

  # Subscribe to kernel uevents (all `devices`; `handle_info` filters for
  # the `sound` subsystem). Returns false when `nerves_uevent` isn't
  # running (host/dev) so the caller falls back to a timer. The broad
  # `["devices"]` pattern is a prefix match — the `sound` segment sits at a
  # bus-dependent depth that a narrower pattern can't pin.
  #
  # The subscribe call itself is the readiness check (not a prior
  # `Process.whereis`): if nerves_uevent hasn't started yet — e.g. this
  # Server initialized before it on a cold boot — fall back to the timer
  # for this incarnation, no whereis/subscribe TOCTOU race. An unstarted
  # PropertyTable raises `ArgumentError` (unknown registry); a process
  # that dies mid-call exits. Both mean "not available" → false.
  defp subscribe_uevents do
    NervesUEvent.subscribe(["devices"])
    true
  rescue
    ArgumentError -> false
  catch
    :exit, _ -> false
  end

  defp refresh_outputs(state) do
    enumerated = state.enumerate_module.safe()
    current_keys = MapSet.new(Map.keys(state.outputs))
    new_keys = MapSet.new(Map.keys(enumerated))

    added = MapSet.difference(new_keys, current_keys)
    removed = MapSet.difference(current_keys, new_keys)

    {with_adds, merged_adds} =
      Enum.reduce(added, {state.outputs, []}, fn key, {acc, broadcasts} ->
        info = Map.fetch!(enumerated, key)

        case Store.save_config(state.store, key, initial_config_params(state.store, key, info)) do
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

    # Drop live-state entries for outputs that disappeared. Keeping
    # stale connection / stream data around would surface "Streaming"
    # for a card whose hardware is unplugged.
    connection_state_after =
      Enum.reduce(removed, state.connection_state, &Map.delete(&2, &1))

    # Hotplug remove clears the `binary_missing` flag for the gone
    # key so a re-add later gets a fresh spawn attempt. `unusable_ports`
    # is deliberately NOT cleared — a port that failed to bind for one
    # output will fail for the next one too (the issue is the port
    # being held externally, not the output identity). The space is
    # 56k+ wide, so unbounded growth isn't a practical concern.
    binary_missing_after = MapSet.difference(state.binary_missing, removed)

    state = %{
      state
      | binary_missing: binary_missing_after,
        connection_state: connection_state_after
    }

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

  # On a card's first-ever sighting (no persisted row), seed a readable
  # `friendly_name` that includes the USB port, so two identical adapters are
  # distinguishable in Sendspin/HA. Persisted rows are left untouched: `added`
  # also fires on every boot for already-saved cards, and passing
  # `friendly_name` as a param would override a user's rename.
  defp initial_config_params(store, key, info) do
    case Store.get_config(store, key) do
      {:ok, _existing} -> %{}
      :error -> %{friendly_name: default_friendly_name(info)}
    end
  end

  defp default_friendly_name(%{card_name: name, usb_port: port}) when is_binary(port),
    do: "#{name} (#{port})"

  # Bluetooth A2DP sinks carry no USB port, and two of the same model share a
  # card_name (the BlueZ alias). Append the device-specific MAC tail so the
  # default name — which is also the mDNS instance name — is unique; otherwise
  # identical speakers collide and Music Assistant can't tell them apart.
  defp default_friendly_name(%{card_name: name, alsa_device: "bluealsa:DEV=" <> rest}),
    do: "#{name} (#{bt_mac_suffix(rest)})"

  defp default_friendly_name(%{card_name: name}), do: name

  # Last three octets of the MAC in `"AA:BB:CC:DD:EE:FF,PROFILE=a2dp"` — the
  # device-unique half (the first three are the vendor OUI).
  defp bt_mac_suffix(rest) do
    rest
    |> String.split(",", parts: 2)
    |> hd()
    |> String.split(":")
    |> Enum.take(-3)
    |> Enum.join(":")
  end

  @hardware_keys [:card_index, :alsa_device, :card_name, :usb_port]

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

  defp send_preemptive_goodbyes(%{mdns_module: nil}), do: :ok

  defp send_preemptive_goodbyes(state) do
    Enum.each(@preemptive_goodbye_types, fn type ->
      try do
        state.mdns_module.goodbye_for_type(type)
      rescue
        e ->
          Logger.warning(
            "Audio.Server pre-emptive goodbye for #{type} raised: #{Exception.message(e)}"
          )

          :ok
      catch
        :exit, reason ->
          Logger.warning(
            "Audio.Server pre-emptive goodbye for #{type} exited: #{inspect(reason)}"
          )

          :ok
      end
    end)
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
  #
  # Skips keys in `state.binary_missing` — those previously failed
  # with `:binary_missing` and would just log the same error on every
  # poll. They're cleared on hotplug remove or `set_enabled(_, true)`.
  defp respawn_missing_players(state) do
    state.outputs
    |> Enum.filter(fn {key, merged} ->
      merged.enabled and
        not Map.has_key?(state.players, key) and
        not MapSet.member?(state.binary_missing, key)
    end)
    |> Enum.reduce(state, fn {_key, merged}, acc -> start_player(acc, merged) end)
  end

  defp start_player(%{player_supervisor: nil} = state, _merged), do: state

  defp start_player(state, merged) do
    key = merged.key

    cond do
      Map.has_key?(state.players, key) ->
        state

      true ->
        case allocate_mdns_port(state) do
          nil ->
            Logger.error(
              "Audio.Server: mDNS port range #{state.port_base}..#{@mdns_port_max} " <>
                "exhausted (used+unusable saturated); skipping spawn for #{inspect(key)}"
            )

            state

          mdns_port ->
            start_player_with_port(state, merged, mdns_port)
        end
    end
  end

  defp start_player_with_port(state, merged, mdns_port) do
    key = merged.key
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

      {:error, {:binary_missing, path}} ->
        # Binary not built for this target (or stripped from priv/).
        # Log once and add to `binary_missing` so the next
        # `respawn_missing_players/1` pass skips it instead of
        # logging this every 5 s. User retry via `set_enabled` or
        # a hotplug remove+add clears the flag.
        Logger.error(
          "Audio.Player binary missing at #{path} for #{inspect(key)}; " <>
            "will not retry until set_enabled or hotplug re-add"
        )

        %{state | binary_missing: MapSet.put(state.binary_missing, key)}

      {:error, reason} ->
        Logger.error("Audio.Player start failed for #{inspect(key)}: #{inspect(reason)}")

        state
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
        |> reset_connection_state(key)

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

  # Returns the smallest free port in `[port_base, @mdns_port_max]` not
  # currently in use or known-bad, or `nil` if the range is exhausted.
  # Unbounded `Stream.iterate` would happily return 65536+ and the
  # binary would fail to bind every time — turn that into an explicit
  # failure the caller surfaces in logs.
  defp allocate_mdns_port(state) do
    used =
      state.players
      |> Map.values()
      |> Enum.map(& &1.mdns_port)
      |> MapSet.new()

    skip = MapSet.union(used, state.unusable_ports)

    Enum.find(state.port_base..@mdns_port_max, fn port -> not MapSet.member?(skip, port) end)
  end

  # `:normal` and `:shutdown` (incl. tuple form) are orderly exits —
  # the port is fine, keep it. Anything else means the player died
  # before terminate/2 ran cleanly; the port may be held by another
  # process or otherwise unbindable, so don't allocate it again.
  defp maybe_mark_port_unusable(state, _port, :normal), do: state
  defp maybe_mark_port_unusable(state, _port, :shutdown), do: state
  defp maybe_mark_port_unusable(state, _port, {:shutdown, _}), do: state

  defp maybe_mark_port_unusable(state, port, _abnormal_reason) do
    %{state | unusable_ports: MapSet.put(state.unusable_ports, port)}
  end

  @default_live_state %{connection: :unknown, stream: nil, last_error: nil}

  defp update_connection_state(state, key, patch) do
    existing = Map.get(state.connection_state, key, @default_live_state)
    %{state | connection_state: Map.put(state.connection_state, key, Map.merge(existing, patch))}
  end

  # Called when a player process is gone (set_enabled(false), rename
  # restart, programmatic stop, or crash). Without this, the cached
  # connection / stream payload — last seen as `:connected` /
  # `stream: %{...}` — would survive the player's death and surface
  # on the next list_outputs/0 call, painting a "Streaming" badge on
  # a card whose binary is dead. On re-enable the LiveView's own
  # per-card cache (built from this state) would render the stale
  # data until the freshly-started player's "connected" event lands.
  #
  # Guard with `Map.has_key?` so hotplug-removed outputs (already
  # cleared by refresh_outputs/1) don't double-broadcast.
  defp reset_connection_state(state, key) do
    if Map.has_key?(state.connection_state, key) do
      broadcast_state(key, %{event: "shutdown"})

      update_connection_state(state, key, %{
        connection: :disconnected,
        stream: nil,
        last_error: nil
      })
    else
      state
    end
  end

  defp merge_connection_state(output, connection_state) do
    live = Map.get(connection_state, output.key, @default_live_state)
    Map.merge(output, live)
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
