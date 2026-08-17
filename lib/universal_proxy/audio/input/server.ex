defmodule UniversalProxy.Audio.Input.Server do
  @moduledoc """
  Tracks the live set of ALSA capture cards and owns one
  `Audio.Input.Source` per card.

  The input-side sibling of `UniversalProxy.Audio.Server`, and built from the
  same parts: re-enumerate `Audio.Input.Enumerate.safe/0` on `sound`-subsystem
  kernel uevents (debounced) with a 5 s poll fallback on hosts where uevents
  aren't available, diff the result against an in-memory cache, and converge
  the set of running child processes onto it. Whenever the enumerated set
  diverges the server:

    * ensures a DETS row exists for new inputs (seeding `friendly_name` from
      the card name on a first-ever sighting only),
    * starts an `Audio.Input.Source` on an allocated listener port,
    * advertises that source over mDNS once — and only once — its listener
      reports bound,
    * sends a TTL=0 goodbye and unregisters when a card goes away, while
      keeping its DETS row so the pairing survives an unplug.

  Unlike outputs there is no `enabled` flag: a present capture card always
  gets a source. A source that cannot capture (no `arecord`) stays up in a
  `:degraded` state rather than being torn down — it is still a discoverable,
  pairable Sendspin client, just one with no audio.

  ## PubSub conventions

  Three topics are owned by this module. Topic strings are literals and tags
  are static atoms — never derived from enumerated input.

      "sendspin:input_added"    {:sendspin_input_added, input_map}
      "sendspin:input_removed"  {:sendspin_input_removed, %{key: key}}
      "sendspin:input_state"    {:input_state, key, state_map}

  `input_map` is what `list_inputs/1` returns for a single entry: enumerate
  info merged with the *non-secret* half of the persisted config. The PSK,
  the PSK id and the client keypair never leave this subsystem — a LiveView
  assign is the last place long-term key material should live.

  `state_map` is the derived live state of one input:

      %{
        status: :detected | :waiting | :pairing | :paired | :streaming | :degraded,
        connection: :disconnected | :connected,
        pin: nil | String.t(),
        port: nil | :inet.port_number(),
        last_error: nil | String.t()
      }

  `:status` is what a badge renders:

    * `:detected` — card enumerated, source starting, listener not bound yet
    * `:waiting` — advertised over mDNS, waiting for Music Assistant to dial
      in and activate us (`:connection` distinguishes "no socket" from
      "connected but not yet activated")
    * `:pairing` — MA offered the pairing activity; `:pin` carries the PIN to
      display as soon as we derive it (the operator types it into MA)
    * `:paired` — `source@v1` active, not streaming
    * `:streaming` — capture running, audio frames going out
    * `:degraded` — active but capture cannot start (no `arecord`)

  The same map is merged into `list_inputs/1` rows so a LiveView that mounts
  after the events have gone by still renders the truth.

  ## mDNS

  Each source gets its own `_sendspin._tcp` service, structurally identical
  to the one `Audio.Player` publishes (same `protocol`/`transport`, a `path`
  TXT key that must start with `/` or Music Assistant silently ignores the
  service, and a `name` TXT key) but with its own port and a
  `{:sendspin_source, slot_sub, vid, pid}` id. Registration is deferred until
  the source reports `{:listener_bound, port}`, for the reason spelled out in
  `Audio.Player`'s moduledoc: MA's discovery connect is one-shot, so
  advertising into the spawn-to-bind gap burns it on a connection refused.

  There is deliberately no boot-time `goodbye_for_type/1` here even though
  `Audio.Server` does one. That call is type-wide: `Audio.Input.Server` starts
  *after* `Audio.Server`, so a second pre-emptive goodbye would evict the
  player services that had just registered. `Audio.Server`'s goodbye already
  covers `_sendspin._tcp` for both halves of the subsystem.

  ## Test seams

  `start_link/1` takes `:enumerate_module`, `:store`, `:source_supervisor`,
  `:source_module`, `:mdns_module`, `:port_base` and `:start_timer`, matching
  `Audio.Server` option for option. `nil` for `:source_supervisor` or
  `:mdns_module` short-circuits that side entirely.
  """

  use GenServer

  require Logger

  alias UniversalProxy.Audio.Input.{DeviceInfo, Enumerate, Source, Store}
  alias UniversalProxy.Audio.Player

  @pubsub UniversalProxy.PubSub
  @hotplug_interval 5_000
  # Same rationale as `Audio.Server`: give ALSA a beat to finish creating a
  # card's sub-devices and coalesce one card's burst of uevents into a single
  # re-enumeration.
  @hotplug_debounce_ms 1_000

  # Listener port base. Deliberately 1,000 above `Audio.Server`'s 8928 so the
  # two allocators — which both climb upward from their base and know nothing
  # about each other — would need a thousand simultaneous outputs before they
  # could collide. A collision isn't fatal (the loser fails to bind, its port
  # is marked unusable and the next one is tried) but it is confusing, and the
  # gap costs nothing.
  @listener_port_base 9_928
  @listener_port_max 65_535

  # mDNS registration retry cadence, per input. `{:listener_bound, port}` is a
  # one-shot signal, so a transient MdnsLite outage at that instant would
  # otherwise leave a source unadvertised for its whole lifetime. Backs off
  # exponentially per consecutive failure so a host with no MdnsLite doesn't
  # log forever at the base interval.
  @mdns_retry_ms 5_000
  @mdns_retry_max_ms 60_000

  @topic_added "sendspin:input_added"
  @topic_removed "sendspin:input_removed"
  @topic_state "sendspin:input_state"

  # Bounds the cached error string: `{:error, reason}` from a source may carry
  # a server-supplied value of arbitrary size, and it ships over the LiveView
  # socket on every diff touching this card.
  @max_error_length 256

  @type key :: Store.input_key()

  @type input_state :: %{
          status: :detected | :waiting | :pairing | :paired | :streaming | :degraded,
          connection: :connected | :disconnected,
          pin: String.t() | nil,
          port: :inet.port_number() | nil,
          last_error: String.t() | nil,
          pairing_window: integer() | nil
        }

  @default_input_state %{
    status: :detected,
    connection: :disconnected,
    pin: nil,
    port: nil,
    last_error: nil,
    # Unix-second expiry of an open "allow pairing" consent window, or `nil`.
    pairing_window: nil
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
  Return all currently-present capture inputs as merged maps (enumerate info
  + persisted config + derived live state), sorted by `friendly_name`.
  """
  @spec list_inputs(GenServer.server()) :: [map()]
  def list_inputs(server \\ __MODULE__) do
    GenServer.call(server, :list_inputs)
  end

  @doc """
  Look up a single input by key. Returns `{:ok, merged_map}` if the input is
  currently present, `:error` otherwise.
  """
  @spec get_input(GenServer.server(), key()) :: {:ok, map()} | :error
  def get_input(server \\ __MODULE__, {slot_sub, _vid, _pid} = key) when is_binary(slot_sub) do
    GenServer.call(server, {:get_input, key})
  end

  @doc """
  Force a hotplug poll synchronously. Tests use this to avoid waiting on the
  periodic timer or the uevent debounce.
  """
  @spec check_now(GenServer.server()) :: :ok
  def check_now(server \\ __MODULE__) do
    GenServer.call(server, :check_now)
  end

  @doc """
  Open the "allow pairing" consent window on the live `Source` for `key`.
  Returns `:ok` whether or not a source is currently running for that key.
  """
  @spec allow_pairing(GenServer.server(), key()) :: :ok
  def allow_pairing(server \\ __MODULE__, {slot_sub, _vid, _pid} = key)
      when is_binary(slot_sub) do
    GenServer.call(server, {:allow_pairing, key})
  end

  # -- Server callbacks --

  @impl GenServer
  def init(opts) do
    state = %{
      enumerate_module: Keyword.get(opts, :enumerate_module) || configured_enumerate_module(),
      store: Keyword.get(opts, :store, Store),
      source_supervisor:
        Keyword.get(opts, :source_supervisor, UniversalProxy.Audio.Input.SourceSupervisor),
      source_module: Keyword.get(opts, :source_module, Source),
      mdns_module: Keyword.get(opts, :mdns_module, MdnsLite),
      port_base: Keyword.get(opts, :port_base, @listener_port_base),
      # %{key => merged enumerate info + non-secret config}
      inputs: %{},
      # %{key => %{pid: pid, monitor: ref, port: 9928}}
      sources: %{},
      # Derived live state per input; see the moduledoc for the shape. Kept
      # here (not just broadcast) so a LiveView mounting after the events
      # have gone by renders the truth through `list_inputs/1`.
      connection_state: %{},
      # Keys whose source refused to start with `:binary_missing` (no
      # `arecord` for the spawn path). `respawn_missing_sources/1` skips
      # them so we don't log the same error every poll for the life of the
      # firmware. Cleared on hotplug remove.
      binary_missing: MapSet.new(),
      # Ports the allocator handed out that the source could not bind (or
      # died on). Never cleared — the range is 55k+ wide.
      unusable_ports: MapSet.new(),
      # %{key => consecutive mDNS registration failures}
      mdns_failures: %{},
      # %{key => Process.send_after ref for a pending register retry}. Kept so
      # a source that goes away (unplug / respawn) can cancel its outstanding
      # retry instead of resurrecting a stale advertisement later.
      mdns_retry_timers: %{},
      mdns_registered: MapSet.new(),
      hotplug_pending: false
    }

    # Restart hygiene: under `:rest_for_one` a Server-only crash leaves the
    # SourceSupervisor and its children running, and those orphans still hold
    # listener ports we are about to re-allocate. Terminate them; the
    # immediate `:check_hotplug` below spawns replacements.
    state = terminate_all_sources(state)

    # Hotplug detection, identical in shape to `Audio.Server`: prefer kernel
    # uevents, fall back to a poll only where `nerves_uevent` isn't running
    # (host/dev), and either way enumerate once at boot. `start_timer: false`
    # (tests) disables both and drives convergence through `check_now/1`.
    if Keyword.get(opts, :start_timer, true) do
      unless subscribe_uevents() do
        interval = Keyword.get(opts, :hotplug_interval, @hotplug_interval)

        if is_integer(interval) and interval > 0,
          do: :timer.send_interval(interval, self(), :check_hotplug)
      end

      send(self(), :check_hotplug)
    end

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:list_inputs, _from, state) do
    rows =
      state.inputs
      |> Map.values()
      |> Enum.map(&merge_input_state(&1, state.connection_state))
      |> Enum.sort_by(& &1.friendly_name)

    {:reply, rows, state}
  end

  def handle_call({:get_input, key}, _from, state) do
    case Map.fetch(state.inputs, key) do
      {:ok, input} -> {:reply, {:ok, merge_input_state(input, state.connection_state)}, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call(:check_now, _from, state) do
    {:reply, :ok, refresh_inputs(state)}
  end

  def handle_call({:allow_pairing, key}, _from, state) do
    case Map.fetch(state.sources, key) do
      {:ok, %{pid: pid}} -> source_allow_pairing(state.source_module, pid)
      :error -> :ok
    end

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(:check_hotplug, state) do
    {:noreply, refresh_inputs(%{state | hotplug_pending: false})}
  end

  # Kernel uevent (via NervesUEvent's PropertyTable). Only `sound`-subsystem
  # changes can move the ALSA capture set; everything else is ignored.
  def handle_info(%PropertyTable.Event{property: path}, state) do
    if "sound" in path do
      {:noreply, schedule_hotplug(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:source_event, key, event}, state) do
    {:noreply, handle_source_event(state, key, event)}
  end

  def handle_info({:retry_mdns_register, key, port}, state) do
    # Only retry while the source that asked for it is still the live one on
    # the same port — a card that was unplugged, or a source that respawned
    # elsewhere, must not resurrect a stale advertisement.
    case Map.fetch(state.sources, key) do
      {:ok, %{port: ^port}} ->
        if MapSet.member?(state.mdns_registered, key) do
          {:noreply, state}
        else
          {:noreply, register_mdns(state, key, port)}
        end

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    # A source died (`:temporary`, so the DynamicSupervisor won't restart
    # it). Drop it, retire its advertisement — the listener behind it is gone
    # and a live record pointing at a dead port burns MA's one-shot connect —
    # and schedule a debounced re-enumeration to respawn it. The explicit
    # schedule matters: on Nerves targets enumeration is uevent-driven and a
    # source crash emits no uevent.
    case Enum.find(state.sources, fn {_k, %{monitor: m}} -> m == ref end) do
      {key, %{port: port}} ->
        Logger.warning("Audio.Input.Source for #{inspect(key)} went down: #{inspect(reason)}")

        state =
          %{state | sources: Map.delete(state.sources, key)}
          |> maybe_mark_port_unusable(port, reason)
          |> unregister_mdns(key)
          |> reset_input_state(key)
          |> schedule_hotplug()

        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    # Retire every advertisement we own. Without this a Server restart leaves
    # peers holding records for listeners that are about to be torn down by
    # the incoming incarnation's `terminate_all_sources/1`.
    Enum.reduce(state.mdns_registered, state, &unregister_mdns(&2, &1))
    :ok
  end

  # -- Hotplug plumbing (shape-identical to Audio.Server) --

  defp schedule_hotplug(%{hotplug_pending: true} = state), do: state

  defp schedule_hotplug(state) do
    Process.send_after(self(), :check_hotplug, @hotplug_debounce_ms)
    %{state | hotplug_pending: true}
  end

  # The subscribe call is itself the readiness check — no `whereis`/subscribe
  # TOCTOU race. An unstarted PropertyTable raises `ArgumentError` (unknown
  # registry); a process dying mid-call exits. Both mean "not available".
  defp subscribe_uevents do
    NervesUEvent.subscribe(["devices"])
    true
  rescue
    ArgumentError -> false
  catch
    :exit, _ -> false
  end

  # -- Convergence --

  defp refresh_inputs(state) do
    enumerated = state.enumerate_module.safe()
    current_keys = MapSet.new(Map.keys(state.inputs))
    new_keys = MapSet.new(Map.keys(enumerated))

    added = MapSet.difference(new_keys, current_keys)
    removed = MapSet.difference(current_keys, new_keys)
    # Keys present in BOTH the cache and the fresh enumeration whose hardware
    # fields changed. A card that keeps its stable `{slot_sub, vid, pid}` key
    # but re-enumerates at a new ALSA index (a remove/re-add collapsed by the
    # hotplug debounce) is neither added nor removed, yet the running Source
    # holds a now-stale `plughw` path — reconcile it below.
    changed = changed_keys(state, enumerated, MapSet.intersection(current_keys, new_keys))

    {with_adds, merged_adds} =
      Enum.reduce(added, {state.inputs, []}, fn key, {acc, broadcasts} ->
        info = Map.fetch!(enumerated, key)

        case seed_config(state, key, info) do
          {:ok, merged} -> {Map.put(acc, key, merged), [merged | broadcasts]}
          :skip -> {acc, broadcasts}
        end
      end)

    {with_changes, merged_changes} =
      Enum.reduce(changed, {with_adds, []}, fn key, {acc, broadcasts} ->
        merged = remerge_config(state, key, Map.fetch!(enumerated, key))
        {Map.put(acc, key, merged), [merged | broadcasts]}
      end)

    final_inputs = Enum.reduce(removed, with_changes, &Map.delete(&2, &1))

    # A gone card must not keep painting "Streaming" from cached live state,
    # and a re-add later deserves a fresh spawn attempt — so drop both its
    # live state and its `binary_missing` mark. `unusable_ports` deliberately
    # survives: a port that couldn't be bound for one card can't be bound for
    # the next either (the holder is external), and the range is 55k+ wide.
    state = %{
      state
      | connection_state: Enum.reduce(removed, state.connection_state, &Map.delete(&2, &1)),
        binary_missing: MapSet.difference(state.binary_missing, removed)
    }

    # Sync child processes BEFORE broadcasting, exactly as `Audio.Server`
    # does: a subscriber that reacts to `:sendspin_input_added` by calling
    # back in must find the source already started.
    #
    # `respawn_missing_sources/1` is what makes this idempotent — it brings
    # back a source that died between polls, for which the add/remove diff
    # above is empty.
    new_state =
      %{state | inputs: final_inputs}
      |> stop_sources(removed)
      |> start_sources(merged_adds)
      |> restart_sources(merged_changes)
      |> respawn_missing_sources()

    Enum.each(merged_adds, &broadcast_added/1)
    # A hardware change is an upsert of the existing row, not a new card — the
    # add/remove events would confuse a subscriber keyed by `key`, so it rides
    # the same `input_added` upsert with the fresh hardware fields. The Source
    # restart drives the usual `input_state` lifecycle on top of it.
    Enum.each(merged_changes, &broadcast_added/1)
    Enum.each(removed, &broadcast_removed/1)

    new_state
  end

  defp seed_config(state, key, info) do
    with :ok <- Store.save_config(state.store, key, initial_config_params(state, key, info)),
         {:ok, saved} <- Store.get_config(state.store, key) do
      {:ok, merge(key, info, saved)}
    else
      :error ->
        Logger.error(
          "Audio input store missing row immediately after save for #{inspect(key)}; skipping"
        )

        :skip

      {:error, reason} ->
        Logger.warning(
          "Audio input store save_config failed for #{inspect(key)}: #{inspect(reason)}; " <>
            "skipping until next poll"
        )

        :skip
    end
  end

  # On a card's first-ever sighting seed a readable `friendly_name`; on every
  # later sighting (including every boot) pass nothing, so a user's rename is
  # never overwritten by the default.
  defp initial_config_params(state, key, info) do
    case Store.get_config(state.store, key) do
      {:ok, _existing} -> %{}
      :error -> %{friendly_name: default_friendly_name(info)}
    end
  end

  defp default_friendly_name(%{name: name, usb_port: port}) when is_binary(port),
    do: "#{name} (#{port})"

  defp default_friendly_name(%{name: name}), do: name

  @hardware_keys [:name, :alsa_device, :card_index, :vid, :pid, :usb_port]
  # Only the non-secret half of the persisted config crosses this boundary.
  # `psk`, `psk_id` and `client_keypair` are long-term key material and stay
  # inside the Store / Source pair.
  @public_config_keys [:friendly_name, :paired_at]

  defp merge(key, info, config) do
    info
    |> Map.take(@hardware_keys)
    |> Map.put(:key, key)
    |> Map.merge(Map.take(config, @public_config_keys))
    |> Map.put(:paired, not is_nil(Map.get(config, :paired_at)))
  end

  # Keys present in both cache and enumeration whose enumerated hardware fields
  # differ. Only hardware moves (a new ALSA index, a renamed card) count — the
  # persisted config half is reconciled elsewhere.
  defp changed_keys(state, enumerated, both_keys) do
    Enum.filter(both_keys, fn key ->
      cached = Map.take(Map.fetch!(state.inputs, key), @hardware_keys)
      fresh = Map.take(Map.fetch!(enumerated, key), @hardware_keys)
      cached != fresh
    end)
  end

  # Re-merge fresh hardware into the row while preserving the persisted config
  # (friendly_name, pairing). Prefer the authoritative DETS config; fall back
  # to the cached row's public fields if the Store can't answer.
  defp remerge_config(state, key, info) do
    case Store.get_config(state.store, key) do
      {:ok, saved} -> merge(key, info, saved)
      :error -> merge(key, info, Map.fetch!(state.inputs, key))
    end
  end

  # -- Source lifecycle --

  defp start_sources(state, merged_adds) do
    Enum.reduce(merged_adds, state, fn merged, acc -> start_source(acc, merged) end)
  end

  # A card whose hardware changed under a stable key: tear down the Source
  # holding the stale `plughw` path and start a fresh one on the new device.
  # Pairing survives — it is persisted in DETS keyed by the unchanged
  # `{slot_sub, vid, pid}`, so the restarted Source reloads the stored PSK and
  # reconnects at trust `user` with no re-pairing. Reuses the same stop/start
  # paths as remove/add.
  defp restart_sources(state, merged_changes) do
    Enum.reduce(merged_changes, state, fn merged, acc ->
      acc |> stop_source(merged.key) |> start_source(merged)
    end)
  end

  # Convergence pass: every tracked input that has no live source gets one.
  # Unlike outputs there's no `enabled` flag to consult — a present capture
  # card always gets a source.
  defp respawn_missing_sources(state) do
    state.inputs
    |> Enum.filter(fn {key, _merged} ->
      not Map.has_key?(state.sources, key) and not MapSet.member?(state.binary_missing, key)
    end)
    |> Enum.reduce(state, fn {_key, merged}, acc -> start_source(acc, merged) end)
  end

  defp start_source(%{source_supervisor: nil} = state, _merged), do: state

  defp start_source(state, merged) do
    if Map.has_key?(state.sources, merged.key) do
      state
    else
      case allocate_port(state) do
        nil ->
          Logger.error(
            "Audio.Input.Server: listener port range #{state.port_base}..#{@listener_port_max} " <>
              "exhausted (used+unusable saturated); skipping spawn for #{inspect(merged.key)}"
          )

          state

        port ->
          start_source_with_port(state, merged, port)
      end
    end
  end

  defp start_source_with_port(state, merged, port) do
    key = merged.key

    opts = [
      key: key,
      alsa_device: merged.alsa_device,
      name: merged.friendly_name,
      store: state.store,
      owner: self(),
      port: port
    ]

    case DynamicSupervisor.start_child(state.source_supervisor, {state.source_module, opts}) do
      {:ok, pid} ->
        put_in(state.sources[key], %{pid: pid, monitor: Process.monitor(pid), port: port})

      {:error, {:binary_missing, path}} ->
        Logger.error(
          "Audio.Input.Source binary missing at #{path} for #{inspect(key)}; " <>
            "will not retry until hotplug re-add"
        )

        %{state | binary_missing: MapSet.put(state.binary_missing, key)}

      {:error, {:listener_failed, reason}} ->
        # The port we handed out could not be bound (held externally, or
        # raced with another allocator). Retire it so the next convergence
        # pass picks a different one instead of failing identically forever.
        Logger.error(
          "Audio.Input.Source for #{inspect(key)} could not bind port #{port} " <>
            "(#{inspect(reason)}); retiring the port"
        )

        %{state | unusable_ports: MapSet.put(state.unusable_ports, port)}

      {:error, reason} ->
        Logger.error("Audio.Input.Source start failed for #{inspect(key)}: #{inspect(reason)}")
        state
    end
  end

  defp stop_sources(state, keys), do: Enum.reduce(keys, state, &stop_source(&2, &1))

  defp stop_source(%{source_supervisor: nil} = state, key), do: unregister_mdns(state, key)

  defp stop_source(state, key) do
    case Map.fetch(state.sources, key) do
      {:ok, %{pid: pid, monitor: ref}} ->
        Process.demonitor(ref, [:flush])
        _ = DynamicSupervisor.terminate_child(state.source_supervisor, pid)

        %{state | sources: Map.delete(state.sources, key)}
        |> unregister_mdns(key)
        |> reset_input_state(key)

      :error ->
        unregister_mdns(state, key)
    end
  end

  # Drives the source's `allow_pairing/1` consent gesture through the same
  # `:source_module` seam the rest of the lifecycle uses. Tolerant of a test
  # stub that doesn't implement it.
  defp source_allow_pairing(module, pid) do
    module.allow_pairing(pid)
  rescue
    UndefinedFunctionError -> :ok
  catch
    :exit, _ -> :ok
  end

  defp terminate_all_sources(%{source_supervisor: nil} = state), do: state

  defp terminate_all_sources(state) do
    state.source_supervisor
    |> safe_which_children()
    |> Enum.each(fn {_id, pid, _type, _modules} ->
      if is_pid(pid), do: DynamicSupervisor.terminate_child(state.source_supervisor, pid)
    end)

    %{state | sources: %{}}
  end

  defp safe_which_children(supervisor) do
    DynamicSupervisor.which_children(supervisor)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  # Smallest free port in `[port_base, @listener_port_max]` that isn't in use
  # or known-bad, or `nil` when the range is exhausted. An unbounded iterate
  # would happily return 65536+, which `bind()` rejects with EINVAL every
  # time — better an explicit failure the caller logs and skips.
  defp allocate_port(state) do
    used =
      state.sources
      |> Map.values()
      |> Enum.map(& &1.port)
      |> MapSet.new()

    skip = MapSet.union(used, state.unusable_ports)

    Enum.find(state.port_base..@listener_port_max, &(not MapSet.member?(skip, &1)))
  end

  # Orderly exits leave the port fine; anything else means the source died
  # before it could release the listener cleanly, so don't hand the port out
  # again.
  defp maybe_mark_port_unusable(state, _port, :normal), do: state
  defp maybe_mark_port_unusable(state, _port, :shutdown), do: state
  defp maybe_mark_port_unusable(state, _port, {:shutdown, _}), do: state

  defp maybe_mark_port_unusable(state, port, _abnormal) do
    %{state | unusable_ports: MapSet.put(state.unusable_ports, port)}
  end

  # -- Source events --

  # The listener is bound: this is the mDNS-deferral contract firing. Record
  # the port the source actually got (it should equal the one we allocated,
  # but the source is the authority) and advertise.
  defp handle_source_event(state, key, {:listener_bound, port}) do
    state
    |> sync_source_port(key, port)
    |> register_mdns(key, port)
    |> update_input_state(key, %{status: :waiting, port: port})
  end

  defp handle_source_event(state, key, :connected) do
    update_input_state(state, key, %{connection: :connected, last_error: nil})
  end

  defp handle_source_event(state, key, :activated) do
    update_input_state(state, key, %{status: :paired, pin: nil})
  end

  defp handle_source_event(state, key, {:pairing_required, _params}) do
    update_input_state(state, key, %{status: :pairing, pin: nil})
  end

  defp handle_source_event(state, key, :pairing_started) do
    update_input_state(state, key, %{status: :pairing, pin: nil})
  end

  # The operator opened (or the window closed / expired on) the "allow pairing"
  # consent window. `expires` is a Unix second, or `nil` when the window closed.
  defp handle_source_event(state, key, {:pairing_window, expires}) do
    update_input_state(state, key, %{pairing_window: expires})
  end

  defp handle_source_event(state, key, {:pairing_pin, pin}) when is_binary(pin) do
    update_input_state(state, key, %{status: :pairing, pin: pin})
  end

  # The PSK landed in DETS, so the cached row's `paired` flag is now stale —
  # re-read it before anyone can call `list_inputs/1` and see `paired: false`
  # next to a `:paired` badge.
  defp handle_source_event(state, key, :paired) do
    state
    |> refresh_config(key)
    |> update_input_state(key, %{status: :paired, pin: nil})
  end

  # A failed attempt leaves the connection up: MA retries by offering the
  # pairing activity again, so we stay in `:pairing` with the stale PIN
  # cleared.
  defp handle_source_event(state, key, {:pairing_failed, reason}) do
    update_input_state(state, key, %{status: :pairing, pin: nil, last_error: describe(reason)})
  end

  defp handle_source_event(state, key, :streaming) do
    update_input_state(state, key, %{status: :streaming, pin: nil})
  end

  defp handle_source_event(state, key, :stopped) do
    update_input_state(state, key, %{status: :paired})
  end

  # The listener stays up and keeps its advertisement — MA redials the same
  # port — so only the connection-derived half of the state resets.
  defp handle_source_event(state, key, :disconnected) do
    update_input_state(state, key, %{status: :waiting, connection: :disconnected, pin: nil})
  end

  defp handle_source_event(state, key, {:capture_missing, path}) do
    Logger.error(
      "Audio.Input.Source for #{inspect(key)} has no capture binary at #{path}; " <>
        "the source stays advertised but cannot stream"
    )

    update_input_state(state, key, %{status: :degraded, last_error: "capture binary missing"})
  end

  defp handle_source_event(state, key, {:error, reason}) do
    update_input_state(state, key, %{last_error: describe(reason)})
  end

  defp handle_source_event(state, key, event) do
    Logger.debug("Audio.Input.Server ignoring #{inspect(event)} for #{inspect(key)}")
    state
  end

  defp sync_source_port(state, key, port) do
    case Map.fetch(state.sources, key) do
      {:ok, %{port: ^port}} ->
        state

      {:ok, entry} ->
        Logger.warning(
          "Audio.Input.Source for #{inspect(key)} bound port #{port}, not the allocated " <>
            "#{entry.port}; advertising the bound one"
        )

        put_in(state.sources[key], %{entry | port: port})

      :error ->
        state
    end
  end

  defp refresh_config(state, key) do
    with {:ok, cached} <- Map.fetch(state.inputs, key),
         {:ok, saved} <- Store.get_config(state.store, key) do
      put_in(state.inputs[key], merge(key, cached, saved))
    else
      _ -> state
    end
  end

  # Fold a patch into the derived live state and tell subscribers. Guarded on
  # the input still being tracked so a straggling event from a source we just
  # tore down can't resurrect state for an unplugged card.
  defp update_input_state(state, key, patch) do
    if Map.has_key?(state.inputs, key) do
      merged = Map.merge(current_input_state(state, key), patch)
      broadcast_state(key, merged)
      %{state | connection_state: Map.put(state.connection_state, key, merged)}
    else
      state
    end
  end

  # The source behind this input is gone (crash, or a stop we drove). Reset to
  # the just-detected state and say so, otherwise a card whose source died
  # mid-stream keeps rendering "Streaming" forever.
  defp reset_input_state(state, key) do
    if Map.has_key?(state.connection_state, key) do
      update_input_state(state, key, @default_input_state)
    else
      state
    end
  end

  defp current_input_state(state, key),
    do: Map.get(state.connection_state, key, @default_input_state)

  defp merge_input_state(input, connection_state) do
    Map.merge(input, Map.get(connection_state, input.key, @default_input_state))
  end

  # Bounds an attacker-influenced reason for the UI/diagnostics. `String.slice/3`
  # counts codepoints, not bytes; the value comes from `inspect/1`, so it is
  # already valid UTF-8 and the slice stays a valid string (worst case the
  # byte length is a small multiple of `@max_error_length`, still bounded).
  defp describe(reason) do
    reason
    |> inspect()
    |> String.slice(0, @max_error_length)
  end

  # -- mDNS --

  defp register_mdns(%{mdns_module: nil} = state, _key, _port), do: state

  defp register_mdns(state, key, port) do
    case Map.fetch(state.inputs, key) do
      {:ok, input} -> do_register_mdns(state, key, port, input)
      :error -> state
    end
  end

  defp do_register_mdns(state, key, port, input) do
    # Clear anything already advertised under this id first. Re-registering
    # after a source respawn would otherwise leave the old (dead-port) SRV
    # record in MdnsLite's table alongside the new one — the table is a
    # MapSet of whole service maps, so two ports means two entries.
    state = unregister_mdns(state, key)

    display_name = Player.sendspin_instance_name(input.friendly_name, DeviceInfo.node_name())

    service = %{
      id: mdns_service_id(key),
      instance_name: display_name,
      protocol: "sendspin",
      transport: "tcp",
      port: port,
      # `path` MUST be present and MUST start with "/" — Music Assistant
      # silently ignores a `_sendspin._tcp` instance without it. `client_id`
      # is deliberately not published (the player publishes it as a non-spec
      # extra): deriving it here would force the Store to mint the long-term
      # X25519 identity at advertise time, undoing its lazy first-use design.
      txt_payload: [
        "path=#{Source.default_path()}",
        "name=#{display_name}"
      ]
    }

    level = if Map.get(state.mdns_failures, key, 0) == 0, do: :warning, else: :debug

    case safe_mdns(state, fn mod -> mod.add_mdns_service(service) end) do
      :ok ->
        %{
          state
          | mdns_registered: MapSet.put(state.mdns_registered, key),
            mdns_failures: Map.delete(state.mdns_failures, key)
        }
        |> cancel_mdns_retry(key)

      other ->
        failures = Map.get(state.mdns_failures, key, 0)
        delay = min(@mdns_retry_ms * Integer.pow(2, failures), @mdns_retry_max_ms)

        Logger.log(
          level,
          "#{inspect(state.mdns_module)}.add_mdns_service returned #{inspect(other)} for " <>
            "#{inspect(key)}; retrying in #{delay}ms"
        )

        state = cancel_mdns_retry(state, key)
        ref = Process.send_after(self(), {:retry_mdns_register, key, port}, delay)

        %{
          state
          | mdns_failures: Map.put(state.mdns_failures, key, failures + 1),
            mdns_retry_timers: Map.put(state.mdns_retry_timers, key, ref)
        }
    end
  end

  defp cancel_mdns_retry(state, key) do
    case Map.pop(state.mdns_retry_timers, key) do
      {nil, _timers} ->
        state

      {ref, timers} ->
        _ = Process.cancel_timer(ref)
        %{state | mdns_retry_timers: timers}
    end
  end

  defp unregister_mdns(%{mdns_module: nil} = state, _key), do: state

  defp unregister_mdns(state, key) do
    id = mdns_service_id(key)

    # Goodbye BEFORE remove: `remove_mdns_service/1` strips the service from
    # the table, and a goodbye after that has nothing to build a packet from.
    # Without the TTL=0 PTR, peer caches (python-zeroconf) hold our record for
    # its full TTL and treat the next announce as a refresh, never an `Added`
    # — so Music Assistant wouldn't re-discover the card for ~120 s.
    if MapSet.member?(state.mdns_registered, key) do
      _ = safe_mdns(state, fn mod -> mod.goodbye_service(id) end)
    end

    _ = safe_mdns(state, fn mod -> mod.remove_mdns_service(id) end)

    state = cancel_mdns_retry(state, key)

    %{
      state
      | mdns_registered: MapSet.delete(state.mdns_registered, key),
        mdns_failures: Map.delete(state.mdns_failures, key)
    }
  end

  defp mdns_service_id({slot_sub, vid, pid}), do: {:sendspin_source, slot_sub, vid, pid}

  # `MdnsLite`'s functions are `GenServer.call`s into the TableServer: a
  # stopped or restarting MdnsLite exits rather than raising, and an
  # unstarted `MdnsLite.Responders` registry raises `ArgumentError`. Both
  # shapes have to be caught or an mDNS hiccup takes the whole input
  # subsystem down with it.
  defp safe_mdns(state, fun) do
    fun.(state.mdns_module)
  rescue
    e ->
      Logger.debug("#{inspect(state.mdns_module)} call raised: #{Exception.message(e)}")
      {:error, :mdns_unavailable}
  catch
    :exit, reason ->
      Logger.debug("#{inspect(state.mdns_module)} call exited: #{inspect(reason)}")
      {:error, :mdns_unavailable}
  end

  # -- Broadcast helpers (literal topics; static atom tags) --

  defp broadcast_added(merged) do
    Phoenix.PubSub.broadcast(@pubsub, @topic_added, {:sendspin_input_added, merged})
  end

  defp broadcast_removed(key) do
    Phoenix.PubSub.broadcast(@pubsub, @topic_removed, {:sendspin_input_removed, %{key: key}})
  end

  defp broadcast_state(key, state_map) do
    Phoenix.PubSub.broadcast(@pubsub, @topic_state, {:input_state, key, state_map})
  end

  defp configured_enumerate_module do
    Application.get_env(:universal_proxy, :audio_input_enumerate_module, Enumerate)
  end
end
