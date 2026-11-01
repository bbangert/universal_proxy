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

  ## Last seen and reachable

  Bulbs never report on their own, only in reply to a ping or an acked
  DP set, so presence comes from the mesh's pinger
  (`UniversalProxy.TuyaMesh.Presence`), which pushes a snapshot here
  (`{:tuya_mesh_presence, snapshot}`) whenever it changes.

  Last seen is merged, never replaced: per MAC the latest report time from
  `Lights.all/1` or a Presence snapshot is kept, and nil never overwrites
  a known time. So a Lights restart, a mesh restart, a same-mesh upload
  (each starts Lights with every bulb unheard) keep it. A MAC that leaves
  the inventory is dropped; a new mesh, or a clear, drops them all. It is
  in memory only (monotonic ms within one boot): after a reboot every bulb
  is "never seen" until it answers, which the pinger's first round
  (15 s after start, then one bulb per 30 s) makes quick, and nothing is
  written to flash for it.

  Missed pings are kept the same way: per MAC the most consecutive misses
  reported, cleared only by a report newer than the last missed ping. A
  restarted Presence starts at zero misses; this keeps a bulb it had given
  up on unreachable until it actually answers.

  While the mesh runs, a bulb is **reachable** when it has been heard
  this boot, has fewer than `:miss_limit` (2) consecutive missed pings,
  and was last heard within `max(:reachable_ms, 2.5 × interval)`, where
  `interval` is the time Presence expects between its checks of that
  bulb. The window keeps a bulb reachable between scheduled pings and
  while pinging waits for the radio, so marginal range (a missed ping or
  two) or a busy queue never flips it alone: only `:miss_limit` misses in
  a row do. A bulb not reachable yet below `:miss_limit` misses, with
  Presence running and the radio ready, is **checking** (a verdict is
  pending). Idle, nothing is reachable or checking.

  Options: `:tuya_adapter`, `:dynsup`, `:name`, and test seams `:store`,
  `:adapters_fun`, `:mesh_spec_fun` (`(index, mac -> child_spec)`), `:radio`,
  `:lights`, `:pubsub`, `:retry_ms`, `:restart_ms`, `:tick_ms`,
  `:index_check_ticks` (ticks between adapter re-checks, default 6),
  `:reachable_ms`, `:miss_limit`.
  """

  use GenServer

  require Logger

  alias UniversalProxy.TuyaBeaconMesh.{Inventory, Lights, Radio}
  alias UniversalProxy.TuyaMesh.{Mesh, Redact, Store}

  @topic "tuya_mesh"
  @retry_ms 2_000
  @max_retry_ms 30_000
  @restart_ms 30_000
  @tick_ms 5_000
  @index_check_ticks 6
  @report_debounce_ms 300
  @resubscribe_ms 1_000
  @reachable_ms 300_000
  @miss_limit 2
  # Stopping the mesh waits for Lights (5 s) and the Radio's teardown (10 s).
  @change_timeout 30_000
  @shutdown 20_000

  @type reason ::
          :no_role
          | :no_inventory
          | :invalid_inventory
          | :store_unavailable
          | :adapter_missing
          | :lone_radio
          | :start_failed
          | :mesh_exited
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
              reachable: boolean(),
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
          &Map.merge(&1, %{last_seen: nil, reachable: false, checking: false})
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
      mesh_spec_fun:
        Keyword.get(
          opts,
          :mesh_spec_fun,
          &Mesh.child_spec(
            adapter_index: &1,
            adapter_address: &2,
            presence: [notify: self()]
          )
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
      timer: nil,
      refresh_timer: nil,
      ticks: 0,
      mesh: nil,
      reason: nil,
      inventory: nil,
      inventory_error: nil,
      radio_status: nil,
      subscribed: nil,
      lights_running: false,
      last_reports: %{},
      presence: %{},
      presence_live: false,
      published: nil,
      pubsub_mon: nil,
      sub_timer: nil
    }

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
    _ = stop_mesh(state)
    :ok
  catch
    :exit, _reason -> :ok
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
    # Other bulbs under the same MACs: nothing heard from them yet.
    state = if reply == {:ok, :new_mesh}, do: forget_presence(state), else: state
    {:reply, reply, %{state | backoff_ms: state.retry_ms} |> evaluate() |> publish()}
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

  # A snapshot still in the mailbox from a mesh already stopped is dropped.
  defp do_info({:tuya_mesh_presence, snapshot}, %{mesh: %{}} = state) when is_map(snapshot),
    do: {:noreply, state |> merge_presence(snapshot) |> publish()}

  defp do_info({:DOWN, mon, :process, _pid, _reason}, %{mesh: %{mon: mon}} = state) do
    Logger.warning("TuyaMesh: mesh stopped on its own; retrying in #{state.restart_ms} ms")
    state = %{clear_mesh(state) | backoff_ms: state.restart_ms}
    {:noreply, state |> idle(:mesh_exited, true) |> publish()}
  end

  defp do_info(_other, state), do: {:noreply, state}

  # ── Lifecycle ────────────────────────────────────────────────────────

  # Running: the adapter must still be the mesh's. Idle: maybe it can start.
  defp adapters_changed(%{mesh: %{}} = state), do: check_index(state)
  defp adapters_changed(state), do: %{state | backoff_ms: state.retry_ms} |> evaluate()

  defp evaluate(%{mesh: %{}} = state), do: state

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
    case DynamicSupervisor.start_child(state.dynsup, state.mesh_spec_fun.(index, state.mac)) do
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

  defp stop_mesh(%{mesh: %{pid: pid, mon: mon}} = state) do
    Process.demonitor(mon, [:flush])
    _ = DynamicSupervisor.terminate_child(state.dynsup, pid)
    clear_mesh(state)
  end

  defp stop_mesh(state), do: cancel_timer(state)

  defp clear_mesh(state) do
    with {_token, tref} <- state.refresh_timer, do: Process.cancel_timer(tref)
    flush_presence()

    %{
      cancel_timer(state)
      | mesh: nil,
        refresh_timer: nil,
        radio_status: nil,
        subscribed: nil,
        lights_running: false,
        presence_live: false
    }
  end

  # The stopped mesh's Presence may have pushed a snapshot just before:
  # for a new mesh, it would bring back what the old one heard.
  defp flush_presence do
    receive do
      {:tuya_mesh_presence, _snapshot} -> flush_presence()
    after
      0 -> :ok
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

          {:ok, new_index} ->
            Logger.info("TuyaMesh: #{state.mac} moved to hci#{new_index}; restarting the mesh")
            state |> stop_mesh() |> evaluate()

          {:error, :adapter_missing} ->
            Logger.warning("TuyaMesh: #{state.mac} is gone from hci#{index}; stopping the mesh")
            state |> stop_mesh() |> evaluate()
        end
    end
  end

  defp schedule_tick(%{mesh: %{}} = state) do
    %{cancel_timer(state) | timer: arm(:tick, state.tick_ms)}
  end

  defp schedule_tick(state), do: state

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
        prune(%{state | inventory: summarize(inv), inventory_error: nil})

      {:error, :no_inventory} ->
        forget_presence(%{state | inventory: nil, inventory_error: :no_inventory})

      {:error, :unavailable} ->
        %{state | inventory: nil, inventory_error: :store_unavailable}

      {:error, _invalid} ->
        %{state | inventory: nil, inventory_error: :invalid_inventory}
    end
  end

  defp summarize(%Inventory{bulbs: bulbs, groups: groups}) do
    %{
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
    radio_status =
      case Radio.status(server: state.radio) do
        {:ok, s} -> %{ready: s.ready, last_error: s.last_error, queued: s.queued}
        {:error, reason} -> %{ready: false, last_error: reason, queued: 0}
      end

    %{state | radio_status: radio_status}
  end

  defp read_lights(%{mesh: nil} = state), do: state

  defp read_lights(state) do
    case Lights.all(server: state.lights) do
      {:ok, bulbs} ->
        reports =
          Enum.reduce(bulbs, state.last_reports, &put_report(&2, &1.mac, &1.last_report_ms))

        prune(%{state | lights_running: true, last_reports: reports})

      {:error, _} ->
        %{state | lights_running: false}
    end
  end

  # ── Presence ─────────────────────────────────────────────────────────

  # A restarted Lights reports every bulb unheard (nil): never let that
  # overwrite a known time.
  defp put_report(reports, _mac, nil), do: reports
  defp put_report(reports, mac, ms), do: Map.update(reports, mac, ms, &max(&1, ms))

  defp merge_presence(state, snapshot) do
    reports =
      Enum.reduce(snapshot, state.last_reports, fn {mac, p}, acc ->
        put_report(acc, mac, p.last_ms)
      end)

    presence =
      Enum.reduce(snapshot, state.presence, fn {mac, p}, acc ->
        Map.put(acc, mac, merge_verdict(Map.get(acc, mac), p, Map.get(reports, mac)))
      end)

    prune(%{state | last_reports: reports, presence: presence, presence_live: true})
  end

  # Misses only clear on a report newer than the last missed ping, so a
  # restarted Presence (zero misses, nothing heard) doesn't undo a verdict.
  defp merge_verdict(nil, p, _last), do: verdict(p.misses, p.missed_at, p)

  defp merge_verdict(old, p, last) do
    old =
      if replied_since?(last, old.missed_at), do: %{old | misses: 0, missed_at: nil}, else: old

    verdict(max(old.misses, p.misses), later(old.missed_at, p.missed_at), p)
  end

  defp verdict(misses, missed_at, p),
    do: %{misses: misses, missed_at: missed_at, interval_ms: p.interval_ms}

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
        presence: Map.take(state.presence, macs)
    }
  end

  defp prune(state), do: state

  defp forget_presence(state), do: %{state | last_reports: %{}, presence: %{}}

  defp bulb_presence(%{mesh: nil}, _last, _presence, _now), do: {false, false}

  defp bulb_presence(state, last, presence, now) do
    misses = effective_misses(presence, last)
    window = max(state.reachable_ms, div(interval_of(presence) * 5, 2))
    reachable = last != nil and misses < state.miss_limit and now - last <= window

    checking =
      not reachable and misses < state.miss_limit and state.presence_live and
        match?(%{ready: true}, state.radio_status)

    {reachable, checking}
  end

  defp effective_misses(nil, _last), do: 0

  defp effective_misses(%{misses: misses, missed_at: at}, last),
    do: if(replied_since?(last, at), do: 0, else: misses)

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

          Map.merge(bulb, %{last_seen: last_seen(last), reachable: reachable, checking: checking})
        end),
      groups: inventory.groups
    }
  end

  # Monotonic → wall clock, to the second so a slewing clock doesn't make
  # every tick look like a change.
  defp last_seen(nil), do: nil

  defp last_seen(ms) do
    (ms + System.time_offset(:millisecond))
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.truncate(:second)
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
