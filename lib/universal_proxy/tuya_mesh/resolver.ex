defmodule UniversalProxy.TuyaMesh.Resolver do
  @moduledoc """
  Decides when the mesh runs, starts and stops it, and publishes its status.

  The mesh (`UniversalProxy.TuyaMesh.Mesh`) is started under the sibling
  DynamicSupervisor only when all of these hold:

    1. a radio holds the `:tuya_mesh` role (`:tuya_adapter`);
    2. the Store holds a valid inventory;
    3. that MAC is a present adapter (`Bluez.Client.adapters_info/0`), whose
       object path `/org/bluez/hciN` gives the Radio's `adapter_index`;
    4. it is not the only adapter present (the mesh adapter is dedicated,
       so a lone one would leave nothing for the proxy).

  Otherwise the Resolver stays idle with a `reason`. A missing adapter or a
  lone radio (a dongle that enumerates late, a claim that lags) is
  re-checked on a timer (2 s, doubling up to 30 s). No role and no
  inventory wait for an event instead: a role change restarts the whole
  Bluez subtree, and an upload goes through `replace/3`.

  The mesh is `:temporary`. If it exhausts its own restart budget it stops,
  and the Resolver tries again after 30 s rather than letting the failure
  escalate into the Bluez subtree.

  ## The adapter stays the one with the role

  hciN indexes are reused: unplug the mesh dongle and another adapter can
  take its index. So while the mesh runs, the Resolver re-resolves the MAC
  on every `{:bluetooth_adapters_changed}` from `Bluez.Client`
  (`Bluez.Client.adapters_topic/0`: claim, hotplug add/remove) and every
  30 s. When the MAC is gone, or sits under another index, the mesh is
  stopped at once and the start conditions are evaluated again (so a dongle
  that came back under a new index gets the mesh there). An empty adapter
  list means the daemon isn't answering, not that the adapter left, and
  changes nothing. The Radio is also started with the expected
  `adapter_address`, so it refuses to power, scan or advertise on whatever
  else holds its index, even between two of these checks.

  A Radio on the HCI user channel takes its adapter away from
  `bluetoothd` while it holds it, so there the adapter reads as gone (or,
  briefly around a re-bind, moved). The mesh is kept running then: the
  MAC is recorded in `UniversalProxy.Bluetooth.HeldRadios` (by the
  Radio's process, from the BD_ADDR check until the channel closes), or
  the Radio's status says it holds the channel (`transport:
  :user_channel`, `lease_held: true`), and the user channel resolves the
  MAC and checks the controller's own address on every bind, so it can't
  be driving another adapter. The same holds while the Radio hands the
  adapter over to its fallback transport (`transport_handoff: true`,
  bounded by the Radio): `bluetoothd` is still taking it back. The status
  is read fresh at that point; when the Radio doesn't answer, what the
  last read said decides.

  ## Releasing the radio

  `release/2` stops the mesh, which closes a user channel and so hands
  the adapter back to `bluetoothd`, and keeps it stopped (`reason:
  :released`) for `:hold_ms` (default 30 s) instead of starting it again
  as soon as the adapter reappears. `UniversalProxy.Bluetooth.Manager`
  calls it before restarting the Bluez subtree (a role change), so the
  adapter is back with `bluetoothd` before the new subtree claims radios.
  The hold only matters when no restart follows; then the mesh starts
  again when it ends.

  While idle, the same event re-evaluates at once instead of waiting for
  the retry timer.

  ## Changes and shutdown

  `replace/3` and `clear/2` stop the mesh before touching the Store and
  start it again after, so no Lights is left running on an inventory that
  is no longer stored (the Store refuses such a writer anyway, see
  `UniversalProxy.TuyaMesh.Store`). The Resolver traps exits and stops the
  mesh in `terminate/2`, with a shutdown long enough for the Radio's
  teardown, so it is only ever gone once the mesh is.

  ## Status

  `status/1` is served from this process's state, never by calling into the
  mesh, so it stays cheap. The state is kept current by subscribing to the
  Radio's reports (each burst triggers one `Lights.all/1` read, 300 ms
  later) and by a 5 s tick that reads `Radio.status/1` (the Radio publishes
  no readiness events) and re-evaluates reachability. The bulb and group
  lists come from the Store, re-read on its `{:tuya_mesh_store,
  :inventory_changed}` broadcasts (`Store.topic/0`), so a group removed by
  a Lights persist disappears too; seq-only writes cause no re-read. Every
  change is broadcast on `UniversalProxy.PubSub` topic `"tuya_mesh"` as
  `{:tuya_mesh_status, status}`. Statuses carry no keys.

  Both subscriptions survive a PubSub restart: the Resolver monitors the
  PubSub registry and subscribes again once it is back.
  Uploads pass the inventory, keys and all, through `replace/3`, so
  `format_status/1` and every call handler redact it (`Redact`).

  ## Reported DPs

  Every status bulb carries `dps`, the DPs Lights has from the bulb's
  reports, `dp_at`, when a DP report last carried each of them (Lights'
  `dp_reported_at`, monotonic ms; a ping reply moves none), and `dps_at`,
  the newest of those or nil. They are merged per MAC, like last seen, so
  a restarted Lights that knows none yet never empties them.
  `last_seen_ms` is last seen as that monotonic time, for a reader that
  converts it to wall time only once the clock is known good.
  Lights is re-read on every Radio report (debounced), so a new report
  reaches the broadcast within about 300 ms. Bulbs report only on acked
  sets and pings (pings carry no DPs).

  ## Last seen and reachable

  Bulbs never report on their own, only in reply to a ping or an acked
  DP set, so presence comes from the mesh's pinger
  (`UniversalProxy.TuyaMesh.Presence`), which pushes a snapshot here
  (`{:tuya_mesh_presence, {mesh_generation, pinger_generation}, snapshot}`)
  whenever it changes.

  Last seen is merged, never replaced: per MAC the latest `heard_ms` from
  `Lights.all/1` or a Presence snapshot is kept, and nil never overwrites
  a known time. So a Lights restart, a mesh restart, a same-mesh upload
  (each starts Lights with every bulb unheard) keep it. Before the mesh is
  stopped for a change, Lights is read once more and every snapshot
  already queued here is merged, so nothing heard just before is lost. A
  MAC that leaves the inventory is dropped. Everything is forgotten on a
  clear, and whenever the stored mesh changes identity
  (`Store.mesh_fingerprint/1`, a hash of its key, compared on every
  inventory load, so A → B → A forgets twice). It is in memory only
  (monotonic ms within one boot): after a reboot every bulb is "never
  seen" until it answers, which the pinger's first broadcast (seconds
  after the mesh starts) settles for most bulbs, and nothing is written to
  flash for it.

  Snapshots are ordered by generation, not by arrival (messages from two
  processes have none): the Resolver bumps its mesh generation for every
  mesh it starts and whenever the stored mesh changes identity, and passes
  it to the mesh's Presence; each Presence adds a monotonic pinger
  generation of its own. A snapshot from an older mesh generation, or an
  older pinger within the current one, is dropped, so a late snapshot
  can neither retire the live pinger nor bring back another mesh's
  observations.

  Missed pings carry across pinger restarts: each Presence counts from
  zero, so when a newer pinger reports (or the mesh stops) what the old
  one counted becomes a per-bulb baseline that the new one's count adds
  to. Any report newer than the last missed ping clears it all.

  While the mesh runs, a bulb is **reachable** when it has been heard
  this boot, has fewer than `:miss_limit` (2) consecutive missed pings,
  and was last heard within `max(:reachable_ms, 2.5 × interval)`, where
  `interval` is the time Presence expects between its checks of that
  bulb: its 60 s cycle, so 150 s (`:reachable_ms`, 2 min, is the floor
  without a pinger). The window keeps a bulb reachable between checks, a
  broadcast reply lost to a collision, and a follow-up carried over a
  cycle, while still tracking reality within a few minutes; a missed
  direct ping (marginal range) never flips it alone: only `:miss_limit`
  misses in a row do. A bulb not reachable yet below `:miss_limit` misses, with
  Presence running and the radio ready, is **checking** (a verdict is
  pending), as long as the latest `Lights.all/1` read worked and the
  current pinger has reported the bulb. Idle, nothing is reachable or
  checking.

  Options: `:tuya_adapter`, `:dynsup`, `:name`, and test seams `:store`,
  `:adapters_fun`, `:mesh_spec_fun` (`(index, mac -> child_spec)`, or
  `(index, mac, presence_opts -> child_spec)` to get the Presence options
  `notify:`, `mesh_generation:` and `frames:`, the pinger's frame log this
  process owns, see `UniversalProxy.TuyaMesh.Presence`), `:radio`,
  `:lights`, `:pubsub`, `:retry_ms`, `:restart_ms`, `:tick_ms`,
  `:index_check_ticks` (ticks between adapter re-checks, default 6),
  `:reachable_ms`, `:miss_limit`, `:held_radios` (`HeldRadios` options).
  """

  use GenServer

  require Logger

  alias UniversalProxy.Bluetooth.HeldRadios
  alias UniversalProxy.TuyaBeaconMesh.{Inventory, Lights, Radio}
  alias UniversalProxy.TuyaMesh.{Mesh, Presence, Redact, Store, WallClock}

  @topic "tuya_mesh"
  @retry_ms 2_000
  @max_retry_ms 30_000
  @restart_ms 30_000
  @tick_ms 5_000
  @index_check_ticks 6
  @report_debounce_ms 300
  @resubscribe_ms 1_000
  @reachable_ms 120_000
  @miss_limit 2
  # Stopping the mesh waits for Lights (5 s) and the Radio's teardown (10 s).
  @change_timeout 30_000
  @shutdown 20_000
  @release_hold_ms 30_000

  @type reason ::
          :no_role
          | :no_inventory
          | :invalid_inventory
          | :store_unavailable
          | :adapter_missing
          | :lone_radio
          | :start_failed
          | :mesh_exited
          | :released
          | :not_running

  @type status :: %{
          role_mac: String.t() | nil,
          state: :running | :idle,
          reason: reason() | nil,
          adapter_index: non_neg_integer() | nil,
          radio: %{ready: boolean(), last_error: term(), queued: non_neg_integer()} | nil,
          lights_running: boolean(),
          bulbs: [
            %{
              mac: String.t(),
              label: String.t() | nil,
              node_id: non_neg_integer(),
              last_seen: DateTime.t() | nil,
              last_seen_ms: integer() | nil,
              reachable: boolean(),
              dps: %{optional(pos_integer()) => term()},
              dp_at: %{optional(pos_integer()) => integer()},
              dps_at: integer() | nil,
              checking: boolean()
            }
          ],
          groups: [%{local_id: 0..254, name: String.t() | nil, members: [String.t()]}]
        }

  @doc "PubSub topic of `{:tuya_mesh_status, status}` broadcasts."
  @spec topic() :: String.t()
  def topic, do: @topic

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, shutdown: @shutdown}
  end

  @doc "The current status (see the moduledoc). Exits when not running."
  @spec status(GenServer.server()) :: status()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Stops the mesh, runs `Store.replace/3`, then re-evaluates. Exits when not running."
  @spec replace(Inventory.t(), keyword(), GenServer.server()) ::
          {:ok, :same_mesh | :new_mesh} | {:error, term()}
  def replace(inventory, opts, server \\ __MODULE__),
    do: GenServer.call(server, {:replace, Redact.seal(inventory), opts}, @change_timeout)

  @doc "Stops the mesh and clears the Store (`Store.clear/2` opts). Exits when not running."
  @spec clear(GenServer.server(), keyword()) :: :ok | {:error, term()}
  def clear(server \\ __MODULE__, opts \\ []),
    do: GenServer.call(server, {:clear, opts}, @change_timeout)

  @doc """
  Stops the mesh and keeps it stopped for `:hold_ms` (default
  #{@release_hold_ms}), see "Releasing the radio". Returns once the mesh
  (and so its radio) is down. `opts`: `:hold_ms`, `:timeout` (default
  #{@change_timeout}). Exits when not running.
  """
  @spec release(GenServer.server(), keyword()) :: :ok
  def release(server \\ __MODULE__, opts \\ []),
    do:
      GenServer.call(
        server,
        {:release, Keyword.get(opts, :hold_ms, @release_hold_ms)},
        Keyword.get(opts, :timeout, @change_timeout)
      )

  @doc false
  # The status shape for when no Resolver runs (`UniversalProxy.TuyaMesh`'s
  # fallback): idle, inventory from `load_result`, nothing live.
  @spec offline_status(String.t() | nil, reason(), {:ok, Inventory.t()} | {:error, term()}) ::
          status()
  def offline_status(mac, reason, load_result) do
    inventory =
      case load_result do
        {:ok, %Inventory{} = inv} -> summarize(inv)
        _ -> %{bulbs: [], groups: []}
      end

    %{
      role_mac: normalize_mac(mac),
      state: :idle,
      reason: reason,
      adapter_index: nil,
      radio: nil,
      lights_running: false,
      bulbs:
        Enum.map(
          inventory.bulbs,
          &Map.merge(&1, %{
            last_seen: nil,
            last_seen_ms: nil,
            reachable: false,
            checking: false,
            dps: %{},
            dp_at: %{},
            dps_at: nil
          })
        ),
      groups: inventory.groups
    }
  end

  # ── Server ───────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    # So terminate/2 runs on a supervisor shutdown and stops the mesh first.
    Process.flag(:trap_exit, true)
    retry_ms = Keyword.get(opts, :retry_ms, @retry_ms)

    state = %{
      mac: opts |> Keyword.get(:tuya_adapter) |> normalize_mac(),
      dynsup: Keyword.fetch!(opts, :dynsup),
      store: Keyword.get(opts, :store, Store),
      adapters_fun: Keyword.get(opts, :adapters_fun, &Bluez.Client.adapters_info/0),
      held_radios: Keyword.get(opts, :held_radios, []),
      mesh_spec_fun:
        Keyword.get(
          opts,
          :mesh_spec_fun,
          &Mesh.child_spec(adapter_index: &1, adapter_address: &2, presence: &3)
        ),
      radio: Keyword.get(opts, :radio, Radio),
      lights: Keyword.get(opts, :lights, Lights),
      pubsub: Keyword.get(opts, :pubsub, UniversalProxy.PubSub),
      retry_ms: retry_ms,
      backoff_ms: retry_ms,
      restart_ms: Keyword.get(opts, :restart_ms, @restart_ms),
      tick_ms: Keyword.get(opts, :tick_ms, @tick_ms),
      index_check_ticks: Keyword.get(opts, :index_check_ticks, @index_check_ticks),
      reachable_ms: Keyword.get(opts, :reachable_ms, @reachable_ms),
      miss_limit: Keyword.get(opts, :miss_limit, @miss_limit),
      time_offset_fun: Keyword.get(opts, :time_offset_fun, &WallClock.offset_ms/0),
      timer: nil,
      refresh_timer: nil,
      # Armed by release/2: the mesh stays stopped until it fires.
      release_timer: nil,
      ticks: 0,
      mesh: nil,
      reason: nil,
      inventory: nil,
      inventory_error: nil,
      radio_status: nil,
      # The Radio's last status said it holds the adapter's user channel.
      radio_held: false,
      subscribed: nil,
      lights_running: false,
      last_reports: %{},
      last_dps: %{},
      presence: %{},
      mesh_generation: 0,
      pinger_generation: 0,
      presence_mesh: nil,
      published: nil,
      pubsub_mon: nil,
      sub_timer: nil,
      frames: frame_log(Keyword.get(opts, :name, __MODULE__)),
      frames_key: {__MODULE__, :frames, Keyword.get(opts, :name, __MODULE__)}
    }

    # The OS clock can step after boot (nerves_time); last_seen is derived
    # from it. Ticks republish within a few seconds of a step; this covers
    # an idle mesh (no ticks) once ERTS notices the step.
    :erlang.monitor(:time_offset, :clock_service)

    # The evaluation that follows reads everything fresh: nothing to catch up.
    {state, _added} = subscribe(state)
    {:ok, state, {:continue, :evaluate}}
  end

  # ── Subscriptions ────────────────────────────────────────────────────

  # Adapter changes and Store inventory changes both arrive over PubSub,
  # which is a sibling at the application's top level and may restart on
  # its own, taking every subscription with it. The Registry behind it is
  # monitored and the subscriptions re-made (every second until it is back);
  # each tick also checks them, since a Registry partition can restart
  # under the same top-level pid. Subscribing is skipped for a topic already
  # held, as the registry is :duplicate and would deliver twice.
  #
  # Whatever was broadcast while a subscription was gone is lost, so a
  # re-made one catches up: the Store topic re-reads the summary, the
  # adapters topic re-checks the adapter.
  defp ensure_subscribed(state) do
    {state, added} = subscribe(state)
    catch_up(state, added)
  end

  # The topics it (re)subscribed to come back alongside the state.
  defp subscribe(state) do
    state = cancel_sub_timer(state)

    case subscribe_topics(state.pubsub) do
      {:ok, added} -> {monitor_pubsub(state), added}
      :error -> {%{state | sub_timer: arm(:resubscribe, @resubscribe_ms)}, []}
    end
  end

  # Registry raises ArgumentError when it isn't running.
  defp subscribe_topics(pubsub) do
    held = Registry.keys(pubsub, self())

    added =
      for topic <- [Bluez.Client.adapters_topic(), Store.topic()], topic not in held do
        :ok = Phoenix.PubSub.subscribe(pubsub, topic)
        topic
      end

    {:ok, added}
  rescue
    ArgumentError -> :error
  end

  defp catch_up(state, added) do
    state = if Store.topic() in added, do: load_inventory(state), else: state
    if Bluez.Client.adapters_topic() in added, do: adapters_changed(state), else: state
  end

  defp monitor_pubsub(state) do
    case {GenServer.whereis(state.pubsub), state.pubsub_mon} do
      {pid, {pid, _mon}} ->
        state

      {pid, previous} when is_pid(pid) ->
        with {_old, mon} <- previous, do: Process.demonitor(mon, [:flush])
        %{state | pubsub_mon: {pid, Process.monitor(pid)}}

      {_none, _previous} ->
        state
    end
  end

  defp cancel_sub_timer(%{sub_timer: {_token, tref}} = state) do
    Process.cancel_timer(tref)
    %{state | sub_timer: nil}
  end

  defp cancel_sub_timer(state), do: state

  # Uploads bring the whole inventory, keys and all, through here.
  @impl GenServer
  def format_status(status), do: Redact.format_status(status)

  @impl GenServer
  def terminate(_reason, state) do
    _ = halt_mesh(state)
    save_frame_log(state)
    :ok
  catch
    :exit, _reason -> :ok
  end

  # ── Frame log ────────────────────────────────────────────────────────

  # The pinger's frame log (`Presence`, "Frame log") outlives pingers and
  # meshes here. A Resolver that stops hands it on to its successor
  # through :persistent_term (one write per stop); a successor that finds
  # none although a Resolver ran before (it was killed) can't know the
  # last hour, and marks the log so.
  defp frame_log(name) do
    table = :ets.new(:tuya_mesh_frames, [:set, :public])
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get({__MODULE__, :frames, name}, nil) do
      rows when is_list(rows) ->
        :ets.insert(table, rows)
        :persistent_term.erase({__MODULE__, :frames, name})

      nil ->
        if :persistent_term.get({__MODULE__, :ran, name}, false),
          do: Presence.unknown_history(table, now),
          else: :persistent_term.put({__MODULE__, :ran, name}, true)
    end

    table
  end

  defp save_frame_log(state) do
    :persistent_term.put(state.frames_key, :ets.tab2list(state.frames))
  rescue
    ArgumentError -> :ok
  end

  # Evaluation loads the inventory (keys and all) from the Store, so the
  # continue and info callbacks are guarded like the calls.
  @impl GenServer
  def handle_continue(:evaluate, state),
    do: Redact.guard("TuyaMesh.Resolver", fn -> {:noreply, state |> evaluate() |> publish()} end)

  # A :replace request holds the inventory, keys and all: anything raised
  # while handling a call leaves as a key-free Redact.Error.
  @impl GenServer
  def handle_call(request, from, state),
    do: Redact.guard("TuyaMesh.Resolver", fn -> do_call(request, from, state) end)

  defp do_call(:status, _from, state), do: {:reply, build_status(state), state}

  defp do_call({:replace, inventory, opts}, _from, state) do
    state = stop_mesh(state)
    reply = inventory |> Redact.unseal() |> Store.replace(opts, state.store)
    {:reply, reply, %{state | backoff_ms: state.retry_ms} |> evaluate() |> publish()}
  end

  defp do_call({:release, hold_ms}, _from, state) do
    state = state |> stop_mesh() |> cancel_release()
    Logger.info("TuyaMesh: mesh released its radio for #{hold_ms} ms")
    state = %{state | release_timer: arm(:resume, hold_ms)} |> idle(:released, false)
    {:reply, :ok, publish(state)}
  end

  defp do_call({:clear, opts}, _from, state) do
    state = stop_mesh(state)
    reply = Store.clear(state.store, opts)
    {:reply, reply, %{state | backoff_ms: state.retry_ms} |> evaluate() |> publish()}
  end

  @impl GenServer
  def handle_info(message, state),
    do: Redact.guard("TuyaMesh.Resolver", fn -> do_info(message, state) end)

  # Timer messages carry the token they were armed with, so one that was
  # already delivered when its timer was cancelled is recognised and dropped.
  defp do_info({:evaluate, token}, %{timer: {token, _}} = state),
    do: {:noreply, %{state | timer: nil} |> evaluate() |> publish()}

  defp do_info({:resume, token}, %{release_timer: {token, _}} = state) do
    state = %{state | release_timer: nil, backoff_ms: state.retry_ms}
    {:noreply, state |> evaluate() |> publish()}
  end

  defp do_info({:tick, token}, %{timer: {token, _}, mesh: %{}} = state) do
    # The catch-up can stop the mesh (its adapter left while the PubSub was
    # down): everything after it works on whatever state it left, running
    # or idle.
    state = %{state | timer: nil, ticks: state.ticks + 1} |> ensure_subscribed()

    state =
      if rem(state.ticks, state.index_check_ticks) == 0,
        do: check_index(state),
        else: state

    {:noreply, state |> observe() |> schedule_tick() |> publish()}
  end

  defp do_info({:resubscribe, token}, %{sub_timer: {token, _}} = state),
    do: {:noreply, %{state | sub_timer: nil} |> ensure_subscribed() |> publish()}

  defp do_info({:DOWN, mon, :process, _pid, _reason}, %{pubsub_mon: {_pid2, mon}} = state),
    do: {:noreply, %{state | pubsub_mon: nil} |> ensure_subscribed() |> publish()}

  # Uploads, clears and group changes: re-read the summary (no keys kept).
  defp do_info({:tuya_mesh_store, :inventory_changed}, state),
    do: {:noreply, state |> load_inventory() |> publish()}

  defp do_info({:bluetooth_adapters_changed}, state),
    do: {:noreply, state |> adapters_changed() |> publish()}

  defp do_info({:tuya_report, _report}, %{refresh_timer: nil, mesh: %{}} = state) do
    {:noreply, %{state | refresh_timer: arm(:refresh_reports, @report_debounce_ms)}}
  end

  defp do_info({:tuya_report, _report}, state), do: {:noreply, state}

  defp do_info({:refresh_reports, token}, %{refresh_timer: {token, _}} = state) do
    {:noreply, %{state | refresh_timer: nil} |> read_lights() |> publish()}
  end

  # The mesh's queued snapshots are merged when it stops: one arriving
  # after that is dropped.
  defp do_info({:tuya_mesh_presence, generation, snapshot}, %{mesh: %{}} = state)
       when is_map(snapshot),
       do: {:noreply, state |> merge_presence(generation, snapshot) |> publish()}

  defp do_info({:DOWN, mon, :process, _pid, _reason}, %{mesh: %{mon: mon}} = state) do
    Logger.warning("TuyaMesh: mesh stopped on its own; retrying in #{state.restart_ms} ms")
    state = %{clear_mesh(state) | backoff_ms: state.restart_ms}
    {:noreply, state |> idle(:mesh_exited, true) |> publish()}
  end

  defp do_info({:CHANGE, _ref, :time_offset, :clock_service, _offset}, state),
    do: {:noreply, publish(state)}

  defp do_info(_other, state), do: {:noreply, state}

  # ── Lifecycle ────────────────────────────────────────────────────────

  # Running: the adapter must still be the mesh's. Idle: maybe it can start.
  defp adapters_changed(%{mesh: %{}} = state), do: check_index(state)
  defp adapters_changed(state), do: %{state | backoff_ms: state.retry_ms} |> evaluate()

  defp evaluate(%{mesh: %{}} = state), do: state
  defp evaluate(%{release_timer: {_token, _tref}} = state), do: idle(state, :released, false)

  defp evaluate(state) do
    state = state |> cancel_timer() |> load_inventory()

    case start_conditions(state) do
      {:ok, index} -> start_mesh(state, index)
      {:idle, reason, retry?} -> idle(state, reason, retry?)
    end
  end

  defp start_conditions(%{mac: nil}), do: {:idle, :no_role, false}

  defp start_conditions(%{inventory: nil, inventory_error: :store_unavailable}),
    do: {:idle, :store_unavailable, true}

  defp start_conditions(%{inventory: nil, inventory_error: reason}), do: {:idle, reason, false}

  defp start_conditions(state) do
    case resolve_index(state) do
      {:ok, index} -> {:ok, index}
      {:error, reason} -> {:idle, reason, true}
    end
  end

  defp resolve_index(state) do
    adapters = state.adapters_fun.()

    with {:ok, index} <- find_index(adapters, state.mac) do
      if Enum.any?(adapters, &(normalize_mac(&1[:address]) != state.mac)),
        do: {:ok, index},
        else: {:error, :lone_radio}
    end
  end

  defp find_index(adapters, mac) do
    with %{path: path} <- Enum.find(adapters, &(normalize_mac(&1[:address]) == mac)),
         {:ok, index} <- Bluez.Hci.adapter_index(path) do
      {:ok, index}
    else
      _ -> {:error, :adapter_missing}
    end
  end

  defp start_mesh(state, index) do
    state = new_mesh_generation(state)

    case DynamicSupervisor.start_child(state.dynsup, mesh_spec(state, index)) do
      {:ok, pid} ->
        Logger.info("TuyaMesh: mesh started on hci#{index} (#{state.mac})")
        mesh = %{pid: pid, mon: Process.monitor(pid), index: index}

        %{state | mesh: mesh, reason: nil, backoff_ms: state.retry_ms, ticks: 0}
        |> observe()
        |> schedule_tick()

      other ->
        # Only the shape: a start error can carry child specs and args.
        Logger.warning("TuyaMesh: mesh failed to start (#{error_kind(other)})")
        idle(state, :start_failed, true)
    end
  end

  defp mesh_spec(%{mesh_spec_fun: fun} = state, index) when is_function(fun, 3),
    do:
      fun.(index, state.mac,
        notify: self(),
        mesh_generation: state.mesh_generation,
        frames: state.frames
      )

  defp mesh_spec(state, index), do: state.mesh_spec_fun.(index, state.mac)

  defp error_kind({:error, {reason, _detail}}) when is_atom(reason), do: inspect(reason)
  defp error_kind({:error, reason}) when is_atom(reason), do: inspect(reason)
  defp error_kind(:ignore), do: ":ignore"
  defp error_kind(_other), do: "error"

  defp idle(state, reason, retry?) do
    if reason != state.reason, do: log_idle(state, reason)

    state = %{state | reason: reason}

    if retry? do
      %{
        state
        | timer: arm(:evaluate, state.backoff_ms),
          backoff_ms: min(state.backoff_ms * 2, @max_retry_ms)
      }
    else
      state
    end
  end

  defp log_idle(state, reason) when reason in [:adapter_missing, :lone_radio] do
    Logger.warning("TuyaMesh: mesh idle (#{reason}) for #{state.mac}; retrying")
  end

  defp log_idle(_state, reason), do: Logger.info("TuyaMesh: mesh idle (#{reason})")

  # Before a change: what Lights heard last is read first, as the restart
  # loses it.
  defp stop_mesh(state), do: state |> read_lights() |> halt_mesh()

  defp halt_mesh(%{mesh: %{pid: pid, mon: mon}} = state) do
    Process.demonitor(mon, [:flush])
    _ = DynamicSupervisor.terminate_child(state.dynsup, pid)
    clear_mesh(state)
  end

  defp halt_mesh(state), do: cancel_timer(state)

  defp clear_mesh(state) do
    with {_token, tref} <- state.refresh_timer, do: Process.cancel_timer(tref)
    state = state |> drain_presence() |> fold_misses()

    %{
      cancel_timer(state)
      | mesh: nil,
        refresh_timer: nil,
        radio_status: nil,
        radio_held: false,
        subscribed: nil,
        lights_running: false
    }
  end

  # Snapshots the stopped mesh's Presence pushed before it went: merged,
  # not lost. Whether they still apply is the next inventory load's call.
  defp drain_presence(state) do
    receive do
      {:tuya_mesh_presence, generation, snapshot} when is_map(snapshot) ->
        state |> merge_presence(generation, snapshot) |> drain_presence()
    after
      0 -> state
    end
  end

  # The running mesh's index must still name its MAC: gone or moved stops
  # it now (and a moved one restarts on the new index). [] is the daemon
  # not answering, which proves nothing either way. An idle Resolver has no
  # index to check: its own evaluation (and retry timer) covers it.
  defp check_index(%{mesh: nil} = state), do: state

  defp check_index(%{mesh: %{index: index}} = state) do
    case state.adapters_fun.() do
      [] ->
        state

      adapters ->
        case find_index(adapters, state.mac) do
          {:ok, ^index} ->
            state

          other ->
            state = read_radio(state)

            if state.radio_held or HeldRadios.held?(state.mac, state.held_radios),
              do: state,
              else: adapter_left(state, index, other)
        end
    end
  end

  defp adapter_left(state, _index, {:ok, new_index}) do
    Logger.info("TuyaMesh: #{state.mac} moved to hci#{new_index}; restarting the mesh")
    state |> stop_mesh() |> evaluate()
  end

  defp adapter_left(state, index, {:error, :adapter_missing}) do
    Logger.warning("TuyaMesh: #{state.mac} is gone from hci#{index}; stopping the mesh")
    state |> stop_mesh() |> evaluate()
  end

  defp schedule_tick(%{mesh: %{}} = state) do
    %{cancel_timer(state) | timer: arm(:tick, state.tick_ms)}
  end

  defp schedule_tick(state), do: state

  defp cancel_release(%{release_timer: {_token, tref}} = state) do
    Process.cancel_timer(tref)
    %{state | release_timer: nil}
  end

  defp cancel_release(state), do: state

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: {_token, tref}} = state) do
    Process.cancel_timer(tref)
    %{state | timer: nil}
  end

  defp arm(tag, ms) do
    token = make_ref()
    {token, Process.send_after(self(), {tag, token}, ms)}
  end

  # ── Observation ──────────────────────────────────────────────────────

  # Last seen and misses follow the inventory: kept while it can't be read
  # (store down, invalid), pruned to it once it can, gone with it.
  defp load_inventory(state) do
    case Store.load(state.store) do
      {:ok, inv} ->
        summary = summarize(inv)

        state =
          if state.presence_mesh in [nil, summary.mesh],
            do: state,
            else: state |> forget_presence() |> new_mesh_generation()

        prune(%{state | inventory: summary, inventory_error: nil, presence_mesh: summary.mesh})

      {:error, :no_inventory} ->
        state = forget_presence(state)
        %{state | inventory: nil, inventory_error: :no_inventory, presence_mesh: nil}

      {:error, :unavailable} ->
        %{state | inventory: nil, inventory_error: :store_unavailable}

      {:error, _invalid} ->
        %{state | inventory: nil, inventory_error: :invalid_inventory}
    end
  end

  # `mesh` is the key-free fingerprint, never shown in a status.
  defp summarize(%Inventory{bulbs: bulbs, groups: groups} = inv) do
    %{
      mesh: Store.mesh_fingerprint(inv),
      bulbs: Enum.map(bulbs, &%{mac: &1.mac, label: &1.label, node_id: &1.node_id}),
      groups: Enum.map(groups, &%{local_id: &1.local_id, name: &1.name, members: &1.members})
    }
  end

  defp observe(%{mesh: nil} = state), do: state
  defp observe(state), do: state |> subscribe_radio() |> read_radio() |> read_lights()

  # Radio subscriptions die with the Radio, so follow its current pid.
  defp subscribe_radio(state) do
    case GenServer.whereis(state.radio) do
      pid when is_pid(pid) and pid == state.subscribed ->
        state

      pid when is_pid(pid) ->
        case Radio.subscribe(self(), :all, server: pid) do
          :ok -> %{state | subscribed: pid}
          {:error, _} -> %{state | subscribed: nil}
        end

      _ ->
        %{state | subscribed: nil}
    end
  end

  defp read_radio(state) do
    case Radio.status(server: state.radio) do
      {:ok, s} ->
        %{
          state
          | radio_status: %{ready: s.ready, last_error: s.last_error, queued: s.queued},
            radio_held: holds_adapter?(s)
        }

      {:error, reason} ->
        %{state | radio_status: %{ready: false, last_error: reason, queued: 0}}
    end
  end

  defp holds_adapter?(%{transport: :user_channel, lease_held: true}), do: true
  defp holds_adapter?(%{transport_handoff: true}), do: true
  defp holds_adapter?(_status), do: false

  defp read_lights(%{mesh: nil} = state), do: state

  defp read_lights(state) do
    case Lights.all(server: state.lights) do
      {:ok, bulbs} ->
        reports =
          Enum.reduce(bulbs, state.last_reports, &put_report(&2, &1.mac, &1.heard_ms))

        dps = Enum.reduce(bulbs, state.last_dps, &put_dps/2)
        prune(%{state | lights_running: true, last_reports: reports, last_dps: dps})

      {:error, _} ->
        %{state | lights_running: false}
    end
  end

  # ── Presence ─────────────────────────────────────────────────────────

  # A bulb's DPs, each with when a DP report last carried it (Lights'
  # `dp_reported_at`): a DP is taken only when reported later than the one
  # known, so a restarted Lights (nothing reported yet) never empties them
  # and a ping reply never moves them.
  defp put_dps(%{mac: mac} = bulb, acc) do
    {known, known_at} = Map.get(acc, mac, {%{}, %{}})
    values = Map.get(bulb, :dps) || %{}

    newer =
      for {dp, at} <- Map.get(bulb, :dp_reported_at) || %{},
          is_integer(at),
          Map.has_key?(values, dp),
          at > Map.get(known_at, dp, at - 1),
          do: {dp, at}

    dps = Map.merge(known, Map.new(newer, fn {dp, _at} -> {dp, values[dp]} end))
    Map.put(acc, mac, {dps, Map.merge(known_at, Map.new(newer))})
  end

  # A restarted Lights reports every bulb unheard (nil): never let that
  # overwrite a known time.
  defp put_report(reports, _mac, nil), do: reports
  defp put_report(reports, mac, ms), do: Map.update(reports, mac, ms, &max(&1, ms))

  # Generations order snapshots (see the moduledoc): another mesh
  # generation's, or an older pinger's, are dropped.
  defp merge_presence(state, {mesh_gen, pinger_gen}, snapshot)
       when mesh_gen == state.mesh_generation and pinger_gen >= state.pinger_generation do
    state = if pinger_gen > state.pinger_generation, do: fold_misses(state), else: state
    seen_by = {mesh_gen, pinger_gen}

    reports =
      Enum.reduce(snapshot, state.last_reports, fn {mac, p}, acc ->
        put_report(acc, mac, p.last_ms)
      end)

    presence =
      Enum.reduce(snapshot, state.presence, fn {mac, p}, acc ->
        Map.put(acc, mac, merge_entry(Map.get(acc, mac), p, Map.get(reports, mac), seen_by))
      end)

    prune(%{state | last_reports: reports, presence: presence, pinger_generation: pinger_gen})
  end

  defp merge_presence(state, _generation, _snapshot), do: state

  # `current` is this pinger's own count; `base` what pingers before it
  # counted since the last report; `seen_by` the pinger that last reported
  # the bulb.
  defp merge_entry(nil, p, last, seen_by),
    do:
      merge_entry(
        %{base: 0, current: 0, missed_at: nil, interval_ms: nil, seen_by: nil},
        p,
        last,
        seen_by
      )

  defp merge_entry(entry, p, last, seen_by) do
    {base, missed_at} =
      if replied_since?(last, entry.missed_at),
        do: {0, p.missed_at},
        else: {entry.base, later(entry.missed_at, p.missed_at)}

    %{
      base: base,
      current: p.misses,
      missed_at: missed_at,
      interval_ms: p.interval_ms,
      seen_by: seen_by
    }
  end

  # The pinger counting is gone (replaced, or its mesh stopped): its count
  # becomes the baseline the next one adds to.
  defp fold_misses(state) do
    presence =
      Map.new(state.presence, fn {mac, e} ->
        {mac, %{e | base: e.base + e.current, current: 0}}
      end)

    %{state | presence: presence}
  end

  defp new_mesh_generation(state),
    do: %{state | mesh_generation: state.mesh_generation + 1, pinger_generation: 0}

  defp replied_since?(nil, _missed_at), do: false
  defp replied_since?(_last, nil), do: false
  defp replied_since?(last, missed_at), do: last >= missed_at

  defp later(nil, b), do: b
  defp later(a, nil), do: a
  defp later(a, b), do: max(a, b)

  defp prune(%{inventory: %{bulbs: bulbs}} = state) do
    macs = Enum.map(bulbs, & &1.mac)

    %{
      state
      | last_reports: Map.take(state.last_reports, macs),
        last_dps: Map.take(state.last_dps, macs),
        presence: Map.take(state.presence, macs)
    }
  end

  defp prune(state), do: state

  defp forget_presence(state), do: %{state | last_reports: %{}, last_dps: %{}, presence: %{}}

  defp bulb_presence(%{mesh: nil}, _last, _presence, _now), do: {false, false}

  defp bulb_presence(state, last, presence, now) do
    misses = effective_misses(presence, last)
    window = max(state.reachable_ms, div(interval_of(presence) * 5, 2))
    reachable = last != nil and misses < state.miss_limit and now - last <= window

    # Only a bulb the live pinger reported, with Lights answering, can be
    # pinged at all.
    checking =
      not reachable and misses < state.miss_limit and state.lights_running and
        live_entry?(state, presence) and match?(%{ready: true}, state.radio_status)

    {reachable, checking}
  end

  defp live_entry?(state, %{seen_by: seen_by}),
    do: seen_by == {state.mesh_generation, state.pinger_generation}

  defp live_entry?(_state, nil), do: false

  defp effective_misses(nil, _last), do: 0

  defp effective_misses(%{base: base, current: current, missed_at: at}, last),
    do: if(replied_since?(last, at), do: 0, else: base + current)

  defp interval_of(%{interval_ms: ms}) when is_integer(ms), do: ms
  defp interval_of(_presence), do: 0

  defp build_status(state) do
    now = System.monotonic_time(:millisecond)
    inventory = state.inventory || %{bulbs: [], groups: []}

    %{
      role_mac: state.mac,
      state: if(state.mesh, do: :running, else: :idle),
      reason: state.reason,
      adapter_index: state.mesh && state.mesh.index,
      radio: state.radio_status,
      lights_running: state.lights_running,
      bulbs:
        Enum.map(inventory.bulbs, fn bulb ->
          last = Map.get(state.last_reports, bulb.mac)

          {reachable, checking} =
            bulb_presence(state, last, Map.get(state.presence, bulb.mac), now)

          {dps, dp_at} = Map.get(state.last_dps, bulb.mac, {%{}, %{}})

          Map.merge(bulb, %{
            last_seen: WallClock.to_datetime(last, state.time_offset_fun),
            last_seen_ms: last,
            reachable: reachable,
            checking: checking,
            dps: dps,
            dp_at: dp_at,
            dps_at: dp_at |> Map.values() |> Enum.max(fn -> nil end)
          })
        end),
      groups: inventory.groups
    }
  end

  defp publish(state) do
    status = build_status(state)

    if status != state.published do
      broadcast(state.pubsub, status)
      %{state | published: status}
    else
      state
    end
  end

  # PubSub's registry raises (not exits) when it isn't started.
  defp broadcast(pubsub, status) do
    Phoenix.PubSub.broadcast(pubsub, @topic, {:tuya_mesh_status, status})
  rescue
    ArgumentError -> :ok
  end

  defp normalize_mac(mac) when is_binary(mac), do: String.upcase(mac)
  defp normalize_mac(_mac), do: nil
end
