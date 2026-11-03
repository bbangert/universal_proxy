defmodule UniversalProxy.TuyaMesh.Commander do
  @moduledoc """
  Runs Home Assistant light commands on the Tuya mesh: maps each one to DP
  batches (`UniversalProxy.TuyaMesh.Commands`) and sends them through
  `UniversalProxy.TuyaBeaconMesh.Lights`, off the `EntityProvider`'s loop
  (`command/2` is a cast).

  One process serialises every command. Its Lights calls are inline (Lights
  is one process too, so nothing is lost), and every wait is a timer, so a
  newer command is always handled before the next step of an older one.

  ## Backlog

  Each frame stays on air for at least 3 s and the Radio's queue is short,
  so a burst of commands outruns it. The backlog is kept here instead: one
  pending command per light (a newer one replaces it, see "Superseding"),
  fed to Lights one action per dispatch, so commands arriving meanwhile are
  handled between frames.

    * **Order:** user frames (a command's batches, and a group's diverted
      direct sends) go first, oldest command first; a confirmation read
      next (it only plans the follow-ups); follow-ups last, one per
      `:followup_gap_ms` (3 s, about one frame's airtime) across every
      command, and only while `Radio.status/1` shows nothing queued
      (polled every `:radio_poll_ms`, 500 ms; unknown counts as busy), so
      a new command never waits behind more than the frame on air. Neither
      gate ever delays user frames.
    * **Capacity:** `{:error, :busy}` or `{:error, :queue_full}` keeps the
      frame where it is and holds every frame for `:retry_ms` (500 ms),
      doubling to `:max_retry_ms` (4 s) while the refusals last, back to
      `:retry_ms` after a frame is accepted. There is no retry count.
    * **Staleness:** a command still not fully sent `:stale_ms` (45 s)
      after it arrived is dropped and logged (what went out is still
      pushed); follow-ups get the same bound from when their pass starts.

  While it has work, and for `:activity_hold_ms` (5 s) after a command
  arrives, it tells `UniversalProxy.TuyaMesh.Presence` to hold off new
  pings (`Presence.command_activity/2`), at least every
  `:keepalive_ms` (2 s).

  ## Sends

  Every batch is an acked set (`ack: true`): the ack draws a DP report,
  the only read-back the bulbs have.

    * **Bulb:** the batches go out in order with `Lights.set/3`.
    * **Group:** the batches go out with `Lights.group_set/3`. A group
      frame reaches only part of the members (4–9 of 10 on hardware), so
      after `:window_ms` every member that hasn't confirmed a DP gets one
      round of direct sets carrying only what it is missing, one every
      `:followup_gap_ms`. A DP is confirmed only by a DP report after the
      command that carried it with the wanted value (Lights stamps each
      reported DP, `dp_reported_at`; a ping reply stamps none).

  `{:error, :busy}` and `{:error, :queue_full}` wait for capacity (see
  "Backlog"); any other error stops the command. A direct send that fails
  drops every remaining frame for that bulb.

  ## Direct-frame budget

  A group command sends at most `:max_followups` direct frames in all,
  shared between a diversion (below) and the confirmation pass. Each pass
  plans every member's first frame (on, mode and its value) before any
  member's second (a brightness that didn't fit), members in inventory
  order. What doesn't fit is dropped, not deferred: those bulbs keep what
  the broadcast gave them (or nothing) until the next command.

  ## Superseding

  A newer command for a light replaces the older one's remaining batches,
  retries and follow-ups, so slider drags don't queue up (the Radio
  already coalesces queued frames for the same light and DPs). Every bulb
  carries the id of the latest command that addresses it (its own or a
  group's). A group command replaces its members' bulb commands; a group
  never broadcasts again once a member has a newer command (its remaining
  batches go directly to the other members, or nowhere when every member
  is superseded), and no direct frame goes to a bulb with a newer command.

  ## Mesh identity

  Every command carries its light's sub-device id. The Store allocates
  them (`Store.device_ids/1`): a group's id is new whenever the stored
  mesh changes or the group leaves it (local group ids are reused for
  unrelated groups), and a bulb's follows its MAC, the physical bulb.
  A command is admitted only while its light still has that id, and
  every frame goes out through one function that reads the id back right
  before the Lights call: a command whose light no longer has it is
  dropped, along with the light's kept DPs. Kept DPs are tied to their
  sub-device id and never used for another. On every `{:tuya_mesh_store, _}` broadcast the same
  check drops the stale commands and kept DPs at once (subscribed at
  start; the per-send check is what guarantees it).

  ## Membership changes

  A group command reaches whoever is in the group when it airs. Its
  members are resolved when it is admitted (`:members`); a pending one
  then follows the group's membership as the Resolver's status reports it
  (each status against the one before, so a status delivered late never
  undoes the membership the command was admitted with):

    * **Joined:** a bulb that joined gets no direct frame from a command
      issued before it joined (no diversion, no follow-up), but a
      broadcast that airs after the join reaches it: the broadcast counts
      it as a member (the group never broadcasts over its newer command,
      see "Superseding"), and takes the broadcast into its kept state as
      the group's latest command for it.
    * **Left:** a bulb that left gets nothing more from the command (its
      planned direct frames are dropped) and no longer takes the group's
      sends into its kept state.
    * **Deleted:** a group gone from the status has its command dropped,
      with its kept and pushed state.

  The group's state is derived again from its current members (see
  "Light state") and pushed when that changes it.

  ## Light state

  This process is the only one that pushes light states to Home
  Assistant. Each light's last known DPs are kept here, with its
  brightness, colour brightness and RGB peak (`Commands.components/2`,
  each kept only once a batch carrying the DP it shapes was accepted:
  `Commands.committed/2`):

    * **Optimistic:** what was sent to it and accepted, over the Lights
      report DPs for a bulb first commanded. A group diverted to direct
      sends records only what at least one member accepted; nothing
      refused is recorded.
    * **Real:** every bulb's reported DPs arrive with the Resolver's
      status (`{:tuya_mesh_status, _}`: `dps`, and `dp_at`, when a DP
      report last carried each). A DP reported since it was last seen
      here is taken unless it was set here after that report (its send
      time against its report time), and the components follow a
      reported colour or brightness (`Commands.reconcile_components/2`).
      A ping reply carries no DPs and moves no DP's time.
    * **Groups** follow their members (`UniversalProxy.TuyaMesh.GroupState`,
      Home Assistant's light-group rules) over the members whose state is
      known; a group with none known shows what was last sent to it.

  A command's accepted sends push its light at once; its members (for a
  group), and every group sharing a bulb with it, follow on the next
  flush. Real reports mark their bulbs and those bulbs' groups, and a
  flush `:push_debounce_ms` (200 ms) later pushes each marked light once,
  bulbs before groups. A push happens only when the state differs from
  the one last pushed, for the light's current sub-device (key and
  `device_id`), and never for a light whose on/off is unknown. What was
  pushed last is kept in an ETS table (`light_states/1`), so a new
  connection's initial states match it.

  The bulbs can't be asked for their state, so every known bulb's state
  DPs (`Commands.state_dps/1`) go to the Store whenever they change, pushed
  or not (`Store.put_light_state/3`, which throttles its writes). On every
  (re)subscription and whenever the Store (re)starts, every known bulb is
  saved again (the Store may have lost held changes), and, then and at
  start, a bulb with no view yet is seeded from what the Store kept. A seeded view counts as
  older than anything live: it has no send times and no report cursor,
  so every DP Lights holds (whatever its report time) and every command
  replaces it. Its groups are derived from it as usual.

  Options: `:name`, `:lights` (module, default `Lights`) and `:lights_opts`
  (extra options to its calls, e.g. `server:`), `:members` (`gid ->
  {:ok, [mac]} | :error`, read at admission, default from
  `UniversalProxy.TuyaMesh.status/1`; see "Membership changes"),
  `:device_ids` (`-> map`, default `Store.device_ids/1`), `:pubsub` and
  `:subscribe` (default `true`) for the Store broadcasts, `:push` (`struct
  -> any`, default `Espex.push_state/2` on `:server`), `:server`,
  `:presence` (server, default `Presence`), `:radio_status` (`-> {:ok,
  map} | {:error, term}`, default `Radio.status/1` with a 500 ms timeout),
  `:radio_poll_ms`, `:window_ms` (6 s),
  `:retry_ms`, `:max_retry_ms`, `:stale_ms`, `:followup_gap_ms`,
  `:activity_hold_ms`, `:keepalive_ms` (see "Backlog"), `:max_followups`
  (10), `:settings` (`-> Store.settings`), `:status` (`-> status`, read
  on every (re)subscription, default `TuyaMesh.status/1`),
  `:push_debounce_ms`, `:resubscribe_ms` (1 s), `:saved_states` (`-> %{mac
  => dps}`, default `Store.light_states/1`), `:save_state` (`(mac, dps) ->
  any`, default `Store.put_light_state/3`), and
  `:states_table` (`true`, the named table, by default for the registered
  process; `:unnamed`; or `false`).
  """

  use GenServer

  require Logger

  alias Espex.Proto
  alias UniversalProxy.TuyaBeaconMesh.{Lights, Radio}
  alias UniversalProxy.TuyaMesh
  alias UniversalProxy.TuyaMesh.{Commands, Entities, GroupState, Presence, Store}

  @retryable [:busy, :queue_full]
  @states_table Module.concat(__MODULE__, States)

  @type target :: {:bulb, String.t()} | {:group, 0..254}
  @type command :: %{
          target: target(),
          key: non_neg_integer(),
          device_id: non_neg_integer(),
          settings: Commands.settings(),
          request: Proto.LightCommandRequest.t()
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  The light states last pushed to Home Assistant, for a new connection's
  initial states. `[]` when no Commander keeps them.
  """
  @spec light_states(:ets.table()) :: [Proto.LightStateResponse.t()]
  def light_states(table \\ @states_table) do
    for {_target, response} <- :ets.tab2list(table), do: response
  rescue
    ArgumentError -> []
  end

  @doc "Queues a light command. Never blocks; a no-op when not running."
  @spec command(command(), GenServer.server()) :: :ok
  def command(command, server \\ __MODULE__), do: GenServer.cast(server, {:command, command})

  # ── GenServer ────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    server = Keyword.get(opts, :server, Espex.Server)

    state = %{
      lights: Keyword.get(opts, :lights, Lights),
      lights_opts: Keyword.get(opts, :lights_opts, []),
      radio_status: Keyword.get(opts, :radio_status, &default_radio_status/0),
      radio_poll_ms: Keyword.get(opts, :radio_poll_ms, 500),
      members: Keyword.get(opts, :members, &default_members/1),
      device_ids: Keyword.get(opts, :device_ids, &default_device_ids/0),
      pubsub: Keyword.get(opts, :pubsub, UniversalProxy.PubSub),
      push: Keyword.get(opts, :push, &default_push(server, &1)),
      presence: Keyword.get(opts, :presence, Presence),
      window_ms: Keyword.get(opts, :window_ms, 6_000),
      retry_ms: Keyword.get(opts, :retry_ms, 500),
      max_retry_ms: Keyword.get(opts, :max_retry_ms, 4_000),
      stale_ms: Keyword.get(opts, :stale_ms, 45_000),
      followup_gap_ms: Keyword.get(opts, :followup_gap_ms, 3_000),
      activity_hold_ms: Keyword.get(opts, :activity_hold_ms, 5_000),
      keepalive_ms: Keyword.get(opts, :keepalive_ms, 2_000),
      max_followups: Keyword.get(opts, :max_followups, 10),
      settings: Keyword.get(opts, :settings, &Store.settings/0),
      status: Keyword.get(opts, :status, &TuyaMesh.status/0),
      push_debounce_ms: Keyword.get(opts, :push_debounce_ms, 200),
      resubscribe_ms: Keyword.get(opts, :resubscribe_ms, 1_000),
      states: states_table(opts),
      saved_states: Keyword.get(opts, :saved_states, &default_saved_states/0),
      save_state: Keyword.get(opts, :save_state, &default_save_state/2),
      subscribe?: Keyword.get(opts, :subscribe, true),
      saved: %{},
      mesh_groups: %{},
      pushed: %{},
      dirty: MapSet.new(),
      flush: nil,
      next_id: 1,
      jobs: %{},
      views: %{},
      touched: %{},
      # Frames held until then after a refusal for capacity; the hold
      # doubles while refusals last.
      blocked_until: nil,
      backoff_ms: Keyword.get(opts, :retry_ms, 500),
      signalled_at: nil,
      next_followup_at: nil,
      dispatch: nil
    }

    {:ok, state, {:continue, :start}}
  end

  @impl GenServer
  def handle_continue(:start, state) do
    state = state |> seed() |> arm_flush()
    {:noreply, if(state.subscribe?, do: subscribe(state), else: state)}
  end

  @impl GenServer
  # Identity is checked first: a command for a light that no longer has
  # its sub-device id (an old mesh's group, during the provider's resync)
  # must not touch views, members or other jobs.
  def handle_cast({:command, %{target: target, device_id: device_id} = command}, state) do
    if valid?(read_ids(state), target, device_id) do
      state = state |> signal_activity(true) |> admit(command)
      {:noreply, reschedule(state)}
    else
      Logger.debug(
        "TuyaMesh.Commander: #{describe(target)} command for a stale sub-device; dropped"
      )

      {:noreply, state}
    end
  end

  def handle_cast(_msg, state), do: {:noreply, state}

  defp admit(state, %{target: target, request: request} = command) do
    state = drop_stale_view(state, target, command.device_id)
    base = base_dps(state, target)
    current = known(view_dps(state, target, command.device_id)) || base

    case Commands.batches(request, command.settings, current) do
      [] ->
        Logger.debug("TuyaMesh.Commander: nothing to send for #{inspect(target)}")
        state

      batches ->
        components = Commands.components(request, current)
        start_job(state, command, base, components, batches)
    end
  end

  @impl GenServer
  def handle_info({:dispatch, token}, %{dispatch: {token, _tref}} = state),
    do: {:noreply, %{state | dispatch: nil} |> dispatch() |> reschedule()}

  # The colour-temperature range or direction changed: every kept light
  # is encoded again (and its kept initial state with it).
  def handle_info({:tuya_mesh_store, :settings_changed}, state) do
    targets = Map.keys(state.views) ++ for(gid <- Map.keys(state.mesh_groups), do: {:group, gid})
    {:noreply, state |> reconcile() |> mark_dirty(targets) |> arm_flush() |> reschedule()}
  end

  # A (re)started Store: it may not have been there to seed from.
  def handle_info({:tuya_mesh_store, :ready}, state),
    do: {:noreply, state |> reconcile() |> resave() |> seed() |> arm_flush() |> reschedule()}

  # The Store may have dropped light states (a clear, another mesh): the
  # next change is saved again, nothing is restored eagerly.
  def handle_info({:tuya_mesh_store, :inventory_changed}, state),
    do: {:noreply, %{state | saved: %{}} |> reconcile() |> arm_flush() |> reschedule()}

  def handle_info({:tuya_mesh_store, _event}, state),
    do: {:noreply, state |> reconcile() |> arm_flush() |> reschedule()}

  def handle_info(:resubscribe, state), do: {:noreply, state |> subscribe() |> reschedule()}

  def handle_info({:tuya_mesh_status, status}, state),
    do: {:noreply, state |> apply_status(status) |> arm_flush() |> reschedule()}

  def handle_info({:flush, token}, %{flush: {token, _tref}} = state),
    do: {:noreply, %{state | flush: nil} |> flush()}

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Jobs ─────────────────────────────────────────────────────────────

  defp start_job(state, command, base, components, batches) do
    id = state.next_id
    target = command.target
    members = members(state, target)

    job = %{
      id: id,
      target: target,
      command: command,
      base: base,
      components: components,
      phase: :send,
      pending: batches,
      sent: [],
      members: members,
      # The group's current membership, joiners included, which a
      # broadcast reaches; `members` are the ones direct frames may go to
      # (no joiners, and a diversion drops the superseded ones).
      resolved: members,
      snapshot: snapshot(state, target, members),
      sent_at: nil,
      then_check?: false,
      budget: state.max_followups,
      accepted: %{},
      ready_at: now(),
      deadline: now() + state.stale_ms
    }

    macs = if match?({:bulb, _}, target), do: [elem(target, 1)], else: members

    # A group command replaces its members' own commands.
    jobs = Map.drop(state.jobs, for(mac <- members, do: {:bulb, mac}))
    touched = Map.merge(state.touched, Map.new(macs, &{&1, id}))

    %{
      state
      | next_id: id + 1,
        jobs: Map.put(jobs, target, job),
        touched: touched
    }
  end

  # Every step starts at the execution boundary: a light that is no longer
  # the one commanded gets nothing more.
  defp step(state, job) do
    if current?(state, job), do: run(state, job), else: abandon(state, job)
  end

  # Never re-broadcast over a member's newer command (its own, or another
  # group's): the rest goes to the other members directly.
  defp run(state, %{phase: :send, target: {:group, _}} = job) do
    case Enum.filter(job.resolved, &newer_command?(state, &1, job)) do
      [] -> send_step(state, job)
      superseded -> divert(state, job, job.members -- superseded)
    end
  end

  defp run(state, %{phase: :send} = job), do: send_step(state, job)

  defp run(state, %{phase: :check} = job), do: check(state, job)

  defp run(state, %{phase: :direct, pending: []} = job), do: finish_direct(state, job)

  defp run(state, %{phase: :followup, pending: []} = job), do: done(state, job)

  defp run(state, %{pending: [{mac, batch} | rest]} = job) do
    if newer_command?(state, mac, job),
      do: run(state, %{job | pending: drop_mac(rest, mac)}),
      else: direct_send(state, job, mac, batch, rest)
  end

  defp send_step(state, %{pending: [batch | rest]} = job) do
    case send_frame(state, job, job.target, batch) do
      :ok ->
        state = state |> accepted_frame() |> addressed(job) |> record(job, batch)
        job = %{job | pending: rest, sent: job.sent ++ batch, sent_at: now()}
        if rest == [], do: sent_all(state, job), else: continue(state, job, 0)

      :stale ->
        abandon(state, job)

      {:error, reason} when reason in @retryable ->
        hold(state, job)

      {:error, reason} ->
        Logger.info(
          "TuyaMesh.Commander: #{describe(job.target)} command failed: #{inspect(reason)}"
        )

        stop_sending(state, job)
    end
  end

  # The unsent batches go to `live` members directly, within the budget;
  # what was broadcast is still checked after the window.
  defp divert(state, job, []) do
    Logger.debug("TuyaMesh.Commander: #{describe(job.target)} superseded on every member")
    stop_sending(state, job)
  end

  defp divert(state, job, live) do
    Logger.debug("TuyaMesh.Commander: #{describe(job.target)} goes direct to #{length(live)}")
    remaining = List.flatten(job.pending)
    plan = for mac <- live, do: {mac, Commands.split(remaining)}
    {items, budget} = within_budget(job, plan)

    job = %{
      job
      | phase: :direct,
        pending: items,
        budget: budget,
        members: live,
        then_check?: job.sent != []
    }

    run(state, job)
  end

  defp direct_send(state, job, mac, batch, rest) do
    case send_frame(state, job, {:bulb, mac}, batch) do
      :stale ->
        abandon(state, job)

      :ok ->
        {state, job} = state |> accepted_frame() |> accept(job, mac, batch)
        state = if job.phase == :followup, do: followup_sent(state), else: state
        continue(state, %{job | pending: rest}, 0)

      {:error, reason} when reason in @retryable ->
        hold(state, job)

      # A bulb that failed gets none of its later frames either.
      {:error, reason} ->
        Logger.info("TuyaMesh.Commander: direct send to #{mac} failed: #{inspect(reason)}")
        continue(state, %{job | pending: drop_mac(rest, mac)}, 0)
    end
  end

  # A diverted batch a member accepted: kept for that member, and for the
  # group once the diversion is over.
  defp accept(state, %{phase: :direct} = job, mac, batch) do
    ids = read_ids(state)
    state = update_member_view(state, mac, Commands.expected(batch), job.components, ids)
    {state, %{job | accepted: Map.update(job.accepted, mac, batch, &(&1 ++ batch))}}
  end

  defp accept(state, job, _mac, _batch), do: {state, job}

  defp finish_direct(state, job) do
    accepted = job.accepted |> Map.values() |> List.flatten() |> Enum.uniq()

    state =
      if accepted == [],
        do: state,
        else: record_light(state, job, Commands.expected(accepted))

    state = if job.sent != [] or accepted != [], do: push(state, job), else: state

    if job.then_check?,
      do: continue(state, %{job | phase: :check, pending: []}, check_delay(state, job)),
      else: done(state, job)
  end

  defp drop_mac(items, mac), do: Enum.reject(items, &match?({^mac, _batch}, &1))

  # The one way a frame goes out: the job's light is checked against the
  # Store right before every send, since a mesh can change during any
  # earlier call (a confirmation read, a failed send) before its
  # broadcast reaches this process.
  defp send_frame(state, job, dest, batch) do
    if current?(state, job), do: lights_send(state, dest, batch), else: :stale
  end

  defp lights_send(state, {:bulb, mac}, batch),
    do: state.lights.set(mac, batch, [ack: true] ++ state.lights_opts)

  defp lights_send(state, {:group, gid}, batch),
    do: state.lights.group_set(gid, batch, [ack: true] ++ state.lights_opts)

  # No capacity: the frame stays first in line and every frame waits.
  defp hold(state, job) do
    state = %{
      state
      | blocked_until: now() + state.backoff_ms,
        backoff_ms: min(state.backoff_ms * 2, state.max_retry_ms)
    }

    %{state | jobs: Map.put(state.jobs, job.target, job)}
  end

  defp accepted_frame(state), do: %{state | blocked_until: nil, backoff_ms: state.retry_ms}

  # What went out still counts: pushed, but no follow-ups for the rest.
  defp stop_sending(state, %{sent: []} = job), do: done(state, job)
  defp stop_sending(state, job), do: done(push(state, job), job)

  defp sent_all(state, %{target: {:bulb, _}} = job), do: done(push(state, job), job)

  defp sent_all(state, %{members: []} = job), do: done(push(state, job), job)

  defp sent_all(state, job),
    do: continue(push(state, job), %{job | phase: :check, pending: []}, state.window_ms)

  defp check_delay(state, job), do: max(job.sent_at + state.window_ms - now(), 0)

  defp now, do: System.monotonic_time(:millisecond)

  # Members that haven't shown the DPs since the command get them directly.
  defp check(state, job) do
    case state.lights.all(state.lights_opts) do
      {:ok, bulbs} ->
        by_mac = Map.new(bulbs, &{&1.mac, &1})

        plan =
          for mac <- job.members, not newer_command?(state, mac, job) do
            {mac, followups_for(mac, Map.get(by_mac, mac), job)}
          end

        {items, budget} = within_budget(job, plan)

        # Only plans: the follow-ups go through the dispatcher, under the
        # capacity hold, the follow-up pacing and user-frame priority.
        continue(
          state,
          %{job | phase: :followup, pending: items, budget: budget, then_check?: false},
          0
        )

      {:error, reason} ->
        Logger.debug("TuyaMesh.Commander: no follow-ups (Lights: #{inspect(reason)})")
        done(state, job)
    end
  end

  # Every member's first frame, then every member's second, cut at the
  # command's remaining budget.
  defp within_budget(job, plan) do
    rounds = plan |> Enum.map(fn {_mac, batches} -> length(batches) end) |> Enum.max(fn -> 0 end)

    items =
      for i <- 0..(rounds - 1)//1,
          {mac, batches} <- plan,
          i < length(batches),
          do: {mac, Enum.at(batches, i)}

    {taken, dropped} = Enum.split(items, job.budget)

    if dropped != [] do
      Logger.debug(
        "TuyaMesh.Commander: #{describe(job.target)}: #{length(dropped)} direct frames over the budget"
      )
    end

    {taken, job.budget - length(taken)}
  end

  defp followups_for(mac, bulb, job) do
    before = Map.get(job.snapshot, mac, %{})
    Commands.split(Commands.unconfirmed(job.sent, reported_since(bulb, before)))
  end

  # The DPs a report carried after the command: Lights stamps each DP a DP
  # report carries (`dp_reported_at`), and a ping reply none, so a DP is
  # confirmed only when its stamp moved and its value is the one sent.
  defp reported_since(%{dps: dps, dp_reported_at: stamps}, before)
       when is_map(dps) and is_map(stamps) do
    for {dp, at} <- stamps,
        is_integer(at),
        later?(at, Map.fetch(before, dp)),
        Map.has_key?(dps, dp),
        into: %{},
        do: {dp, dps[dp]}
  end

  defp reported_since(_bulb, _before), do: %{}

  defp later?(_at, :error), do: true
  defp later?(at, {:ok, before}), do: at > before

  defp newer_command?(state, mac, job), do: Map.get(state.touched, mac, 0) > job.id

  # A broadcast that aired is the latest command for every current member
  # it reached (a joiner too), so an older command's follow-up never
  # overrides it. Never called with a superseded member (see `run/2`).
  defp addressed(state, %{target: {:group, _}} = job),
    do: %{state | touched: Map.merge(state.touched, Map.new(job.resolved, &{&1, job.id}))}

  defp addressed(state, _bulb_job), do: state

  # The job's next action is due after `delay`; a confirmation pass gets
  # its own staleness bound from when it starts.
  defp continue(state, job, delay) do
    ready_at = now() + delay

    job =
      if job.phase == :check,
        do: %{job | ready_at: ready_at, deadline: ready_at + state.stale_ms},
        else: %{job | ready_at: ready_at}

    %{state | jobs: Map.put(state.jobs, job.target, job)}
  end

  # ── Dispatch ─────────────────────────────────────────────────────────

  # One action per dispatch, and at most one Lights call: commands that
  # arrived meanwhile (even during that call) are admitted, and supersede,
  # before the next frame. Every path that has made a call returns here
  # through `continue/3` rather than trying the next frame itself.
  defp dispatch(state) do
    now = now()
    state = state |> expire(now) |> signal_activity(false)

    case next_job(state, now) do
      nil ->
        state

      job ->
        if followup_frame?(job) and not radio_drained?(state),
          do: wait_for_radio(state, now),
          else: step(state, job)
    end
  end

  # A follow-up goes only when the Radio has nothing queued: `:ok` from
  # Lights means the frame entered the Radio's FIFO, so pacing alone would
  # still let several follow-ups queue ahead of a later user command. An
  # unknown status counts as not drained (for follow-ups only).
  defp radio_drained?(state) do
    case state.radio_status.() do
      {:ok, %{queued: 0}} -> true
      _queued_or_unknown -> false
    end
  catch
    :exit, _reason -> false
  end

  # Polled again after `:radio_poll_ms` (user frames are never held).
  defp wait_for_radio(state, now) do
    at = now + state.radio_poll_ms
    %{state | next_followup_at: max(state.next_followup_at || at, at)}
  end

  defp default_radio_status, do: Radio.status(timeout: 500)

  defp next_job(state, now) do
    state.jobs
    |> Map.values()
    |> Enum.filter(&(available_at(state, &1) <= now))
    |> Enum.min_by(&{priority(&1), &1.id}, fn -> nil end)
  end

  # When a job's next action may run: frames not during a capacity hold,
  # follow-up frames not before the shared follow-up pacing allows.
  defp available_at(state, job) do
    holds =
      cond do
        followup_frame?(job) -> [state.blocked_until, state.next_followup_at]
        frame?(job) -> [state.blocked_until]
        true -> []
      end

    Enum.max([job.ready_at | Enum.reject(holds, &is_nil/1)])
  end

  defp followup_frame?(job), do: job.phase == :followup and frame?(job)

  # One follow-up per `:followup_gap_ms` across every command, so they
  # never queue more than a frame ahead of a new user command.
  defp followup_sent(state), do: %{state | next_followup_at: now() + state.followup_gap_ms}

  defp priority(%{phase: phase}) when phase in [:send, :direct], do: 0
  defp priority(%{phase: :check}), do: 1
  defp priority(%{phase: :followup}), do: 2

  defp frame?(%{phase: :send}), do: true
  defp frame?(%{phase: phase, pending: [_ | _]}) when phase in [:direct, :followup], do: true
  defp frame?(_job), do: false

  # The next wake-up: the earliest due action (frames not before the
  # capacity hold), the earliest staleness bound, and, with work left, the
  # Presence keepalive.
  defp reschedule(%{jobs: jobs} = state) when map_size(jobs) == 0, do: arm(state, nil)

  defp reschedule(state) do
    now = now()

    due = for job <- Map.values(state.jobs), do: available_at(state, job)

    deadlines = for job <- Map.values(state.jobs), do: job.deadline + 1
    at = Enum.min([now + state.keepalive_ms | due ++ deadlines])
    arm(state, max(at - now, 0))
  end

  defp arm(state, delay) do
    with {_token, tref} <- state.dispatch, do: Process.cancel_timer(tref)

    case delay do
      nil ->
        %{state | dispatch: nil}

      ms ->
        token = make_ref()
        %{state | dispatch: {token, Process.send_after(self(), {:dispatch, token}, ms)}}
    end
  end

  # A command that couldn't be sent in time is dropped: nothing runs
  # absurdly late. What did go out is still pushed.
  defp expire(state, now) do
    state.jobs
    |> Map.values()
    |> Enum.filter(&(&1.deadline < now))
    |> Enum.reduce(state, fn job, state ->
      # A light that is no longer the one commanded gets no push.
      if current?(state, job), do: expire_job(state, job), else: abandon(state, job)
    end)
  end

  defp expire_job(state, %{phase: phase} = job) when phase in [:send, :direct] do
    Logger.info(
      "TuyaMesh.Commander: #{describe(job.target)} command not sent within " <>
        "#{state.stale_ms} ms; dropped"
    )

    if phase == :send,
      do: stop_sending(state, job),
      else: finish_direct(state, %{job | then_check?: false})
  end

  defp expire_job(state, job) do
    Logger.debug("TuyaMesh.Commander: #{describe(job.target)} follow-ups out of time; dropped")
    done(state, job)
  end

  # Presence holds off new pings while there is work (see "Backlog").
  defp signal_activity(state, force?) do
    now = now()

    if force? or (state.jobs != %{} and stale_signal?(state, now)) do
      Presence.command_activity(state.presence, state.activity_hold_ms)
      %{state | signalled_at: now}
    else
      state
    end
  end

  defp stale_signal?(%{signalled_at: nil}, _now), do: true
  defp stale_signal?(state, now), do: now - state.signalled_at >= div(state.keepalive_ms, 2)

  defp done(state, job) do
    case Map.get(state.jobs, job.target) do
      %{id: id} when id == job.id -> %{state | jobs: Map.delete(state.jobs, job.target)}
      _other -> state
    end
  end

  # ── Mesh identity ────────────────────────────────────────────────────

  defp current?(state, job), do: valid?(read_ids(state), job.target, job.command.device_id)

  defp valid?(ids, target, device_id), do: Map.get(ids, target) == device_id

  defp abandon(state, job) do
    Logger.info(
      "TuyaMesh.Commander: #{describe(job.target)} is no longer the light commanded; dropped"
    )

    %{done(state, job) | views: Map.delete(state.views, job.target)}
    |> forget_pushed([job.target])
  end

  # Drops the commands and kept DPs of every light whose id changed.
  defp reconcile(state) do
    ids = read_ids(state)

    {jobs, stale} =
      Map.split_with(state.jobs, fn {target, job} ->
        Map.get(ids, target) == job.command.device_id
      end)

    if stale != %{} do
      Logger.info("TuyaMesh.Commander: mesh changed; dropped #{map_size(stale)} commands")
    end

    {views, stale_views} =
      Map.split_with(state.views, fn {target, view} -> Map.get(ids, target) == view.device_id end)

    stale_pushed =
      for {target, response} <- state.pushed,
          Map.get(ids, target) != response.device_id,
          do: target

    # A light that is still there under a new sub-device (a new mesh can
    # keep a group's local id and members) gets its state again, derived
    # from what is still known; so does a group never pushed.
    renewed =
      (Map.keys(stale_views) ++ stale_pushed)
      |> Enum.filter(&Map.has_key?(ids, &1))

    unpushed =
      for gid <- Map.keys(state.mesh_groups),
          not Map.has_key?(state.pushed, {:group, gid}),
          do: {:group, gid}

    %{state | jobs: jobs, views: views}
    |> forget_pushed(stale_pushed)
    |> mark_dirty(renewed ++ unpushed)
  end

  defp read_ids(state) do
    case state.device_ids.() do
      ids when is_map(ids) -> ids
      _unreadable -> %{}
    end
  end

  # Once, at start. The subscription links this process to the PubSub
  # registry, so a registry restart restarts it and it subscribes afresh;
  # without PubSub it runs unsubscribed, the per-send check still holding.
  # Retried every `:resubscribe_ms` while PubSub is down (its lifecycle is
  # independent of this process). Topics already held are skipped: the
  # registry is :duplicate and would deliver twice. Whatever was broadcast
  # meanwhile is lost, so every (re)subscription reads a fresh status. A
  # subscription links this process to the registry: a registry restart
  # restarts it, and it subscribes afresh.
  defp subscribe(state) do
    held = Registry.keys(state.pubsub, self())

    added =
      for topic <- [Store.topic(), TuyaMesh.topic()], topic not in held do
        :ok = Phoenix.PubSub.subscribe(state.pubsub, topic)
        topic
      end

    if added == [],
      do: state,
      else:
        state
        |> reconcile()
        |> resave()
        |> seed()
        |> apply_status(state.status.())
        |> arm_flush()
  rescue
    ArgumentError ->
      Logger.debug("TuyaMesh.Commander: PubSub unavailable; retrying")
      Process.send_after(self(), :resubscribe, state.resubscribe_ms)
      state
  end

  # ── Views and optimistic state ───────────────────────────────────────

  # A kept view belongs to one sub-device: another id's is never used
  # (without Store broadcasts, a replaced mesh's would linger).
  # A view with no values yet (only send times) knows nothing.
  defp known(dps) when dps == %{}, do: nil
  defp known(dps), do: dps

  defp view_dps(state, target, device_id) do
    case Map.get(state.views, target) do
      %{device_id: ^device_id, dps: dps} -> dps
      _none_or_stale -> nil
    end
  end

  defp drop_stale_view(state, target, device_id) do
    case Map.get(state.views, target) do
      %{device_id: id} when id != device_id -> %{state | views: Map.delete(state.views, target)}
      _same_or_none -> state
    end
  end

  # What an accepted batch set, kept for the light (and, after a group
  # batch, for its members already known).
  defp record(state, job, batch) do
    sent = Commands.expected(batch)
    state = record_light(state, job, sent)

    ids = if job.resolved == [], do: %{}, else: read_ids(state)

    job.resolved
    |> Enum.reject(&newer_command?(state, &1, job))
    |> Enum.reduce(state, &update_member_view(&2, &1, sent, job.components, ids))
  end

  defp record_light(state, job, sent) do
    dps =
      (known(view_dps(state, job.target, job.command.device_id)) || job.base)
      |> Map.merge(sent)
      |> Map.merge(Commands.committed(job.components, sent))
      |> Commands.reconcile_components(sent)

    id = job.command.device_id

    view =
      case Map.get(state.views, job.target) do
        %{device_id: ^id} = view -> %{view | dps: dps, sent_at: sent_times(view, id, sent)}
        _none_or_stale -> %{device_id: id, dps: dps, sent_at: sent_times(nil, id, sent)}
      end

    %{state | views: Map.put(state.views, job.target, view)}
  end

  # A member whose state isn't known yet still gets the send times (and
  # no values), so a report older than the group's send can't win later.
  defp update_member_view(state, mac, sent, components, ids) do
    target = {:bulb, mac}

    case Map.fetch(state.views, target) do
      {:ok, %{dps: dps} = view} when dps == %{} ->
        view = %{view | sent_at: sent_times(view, view.device_id, sent)}
        %{state | views: Map.put(state.views, target, view)}

      {:ok, view} ->
        dps =
          view.dps
          |> Map.merge(sent)
          |> Map.merge(Commands.committed(components, sent))
          |> Commands.reconcile_components(sent)

        view = %{view | dps: dps, sent_at: sent_times(view, view.device_id, sent)}
        %{state | views: Map.put(state.views, target, view)}

      :error ->
        case Map.get(ids, target) do
          id when is_integer(id) ->
            view = %{device_id: id, dps: %{}, sent_at: sent_times(nil, id, sent)}
            %{state | views: Map.put(state.views, target, view)}

          nil ->
            state
        end
    end
  end

  # When a DP was last set optimistically: a real report only supersedes
  # it when newer.
  defp sent_times(%{device_id: id, sent_at: at}, id, sent),
    do: Map.merge(at, Map.new(sent, fn {dp, _v} -> {dp, now()} end))

  defp sent_times(_view, _id, sent), do: Map.new(sent, fn {dp, _v} -> {dp, now()} end)

  # A command's accepted sends: the light's state now; its members' and
  # the groups sharing a light with it on the next flush.
  defp push(state, job) do
    ids = read_ids(state)
    state = push_target(state, job.target, job.command.settings, ids)

    related =
      case job.target do
        {:bulb, mac} ->
          groups_of(state, [mac])

        {:group, _gid} ->
          for(mac <- job.resolved, do: {:bulb, mac}) ++ groups_of(state, job.resolved)
      end

    state |> mark_dirty(related -- [job.target]) |> arm_flush()
  end

  # ── Light states ─────────────────────────────────────────────────────

  # Real reports from the Resolver's status: a DP the bulb reported after
  # it was last set here replaces the kept value (see `Commands.reconcile_components/2`).
  defp apply_status(state, %{bulbs: bulbs} = status) when is_list(bulbs) do
    ids = read_ids(state)
    old_groups = state.mesh_groups

    groups =
      Map.new(Map.get(status, :groups, []), fn g -> {g.local_id, Map.get(g, :members, [])} end)

    # A new group, or one whose members changed, is derived again whether
    # or not anything reported; a removed one is forgotten.
    changed =
      for {gid, members} <- groups, Map.get(state.mesh_groups, gid) != members, do: {:group, gid}

    removed =
      for gid <- Map.keys(state.mesh_groups), not Map.has_key?(groups, gid), do: {:group, gid}

    state =
      %{state | mesh_groups: groups, views: Map.drop(state.views, removed)}
      |> forget_pushed(removed)
      |> mark_dirty(changed)
      |> regroup(old_groups, groups)

    {state, macs} =
      Enum.reduce(bulbs, {state, []}, fn bulb, {state, macs} ->
        case real_report(state, bulb, Map.get(ids, {:bulb, bulb.mac})) do
          nil -> {state, macs}
          {:seen, state} -> {state, macs}
          state -> {state, [bulb.mac | macs]}
        end
      end)

    mark_dirty(state, for(mac <- macs, do: {:bulb, mac}) ++ groups_of(state, macs))
  end

  defp apply_status(state, _status), do: state

  # Per DP: a DP whose report time (`dp_at`) moved since last seen here is
  # taken unless it was set here after that report. A ping moves no DP's
  # time, so it never brings old values back.
  #
  # The cursor (when each DP was last seen, `:reported`) lives in the bulb's
  # view, so it goes wherever the view goes: a view dropped and built again
  # (an identity blip, say, then a group send's send times) starts with
  # none, and the retained DPs are taken again.
  defp real_report(state, %{mac: mac} = bulb, id) when is_integer(id) do
    values = Map.get(bulb, :dps) || %{}
    target = {:bulb, mac}

    view =
      case Map.get(state.views, target) do
        %{device_id: ^id} = view -> view
        _none_or_stale -> %{device_id: id, dps: %{}, sent_at: %{}}
      end

    seen = Map.get(view, :reported, %{})

    fresh =
      for {dp, at} <- Map.get(bulb, :dp_at) || %{},
          is_integer(dp) and is_integer(at),
          Map.has_key?(values, dp),
          later?(at, Map.fetch(seen, dp)),
          into: %{},
          do: {dp, at}

    if fresh == %{} do
      nil
    else
      real =
        for {dp, at} <- fresh,
            later?(at, Map.fetch(view.sent_at, dp)),
            into: %{},
            do: {dp, values[dp]}

      dps = view.dps |> Map.merge(real) |> Commands.reconcile_components(real)

      view =
        Map.merge(view, %{
          dps: dps,
          sent_at: Map.drop(view.sent_at, Map.keys(real)),
          reported: Map.merge(seen, fresh)
        })

      state = %{state | views: Map.put(state.views, target, view)}
      if real == %{}, do: {:seen, state}, else: state
    end
  end

  defp real_report(_state, _bulb, _id), do: nil

  # ── Membership changes ───────────────────────────────────────────────

  # Pending group commands follow what changed between the last status
  # and this one (see "Membership changes"); a group first seen now has
  # nothing to compare.
  defp regroup(state, old_groups, groups) do
    state.jobs
    |> Map.values()
    |> Enum.filter(&match?(%{target: {:group, gid}} when is_map_key(old_groups, gid), &1))
    |> Enum.reduce(state, fn %{target: {:group, gid}} = job, state ->
      before = Map.fetch!(old_groups, gid)

      case Map.fetch(groups, gid) do
        {:ok, ^before} -> state
        {:ok, members} -> regroup_job(state, job, members -- before, before -- members)
        :error -> drop_deleted(state, job)
      end
    end)
  end

  defp drop_deleted(state, job) do
    Logger.info("TuyaMesh.Commander: #{describe(job.target)} was deleted; its command dropped")
    done(state, job)
  end

  defp regroup_job(state, job, joined, left) do
    joined = joined -- job.resolved
    left = Enum.filter(left, &(&1 in job.resolved))

    job = %{
      job
      | resolved: (job.resolved ++ joined) -- left,
        members: job.members -- left,
        snapshot: Map.drop(job.snapshot, left),
        accepted: Map.drop(job.accepted, left),
        pending: drop_macs(job, left)
    }

    %{state | jobs: Map.put(state.jobs, job.target, job)}
  end

  # Direct frames are `{mac, batch}`; a broadcast's pending batches aren't.
  defp drop_macs(%{phase: phase, pending: pending}, macs) when phase in [:direct, :followup],
    do: Enum.reject(pending, fn {mac, _batch} -> mac in macs end)

  defp drop_macs(%{pending: pending}, _macs), do: pending

  defp groups_of(state, macs) do
    for {gid, members} <- state.mesh_groups, Enum.any?(macs, &(&1 in members)), do: {:group, gid}
  end

  defp mark_dirty(state, targets),
    do: %{state | dirty: MapSet.union(state.dirty, MapSet.new(targets))}

  # Bursts of reports coalesce into one push per light.
  defp arm_flush(%{flush: nil} = state) do
    if MapSet.size(state.dirty) == 0 do
      state
    else
      token = make_ref()

      %{
        state
        | flush: {token, Process.send_after(self(), {:flush, token}, state.push_debounce_ms)}
      }
    end
  end

  defp arm_flush(state), do: state

  # Bulbs first, so their groups are derived from what was just pushed.
  defp flush(state) do
    ids = read_ids(state)
    settings = state.settings.()
    {bulbs, groups} = state.dirty |> MapSet.to_list() |> Enum.split_with(&match?({:bulb, _}, &1))
    state = %{state | dirty: MapSet.new()}
    Enum.reduce(bulbs ++ groups, state, &push_target(&2, &1, settings, ids))
  end

  # Pushed only when it differs from what Home Assistant last got, and
  # only for the light's current sub-device.
  defp push_target(state, target, settings, ids) do
    {state, response} = response_for(state, target, settings, Map.get(ids, target), ids)

    cond do
      response == nil -> state
      Map.get(state.pushed, target) == response -> save(state, target)
      true -> state |> record_push(target, response) |> save(target)
    end
  end

  defp record_push(state, target, response) do
    state.push.(response)
    if state.states, do: :ets.insert(state.states, {target, response})
    %{state | pushed: Map.put(state.pushed, target, response)}
  end

  # Bulbs only (a group is derived from its members again), and whenever
  # its state DPs changed, even where the response didn't (a colour kept
  # in white mode, say).
  defp save(state, {:bulb, mac} = target) do
    with %{dps: dps} <- Map.get(state.views, target),
         dps = Commands.state_dps(dps),
         false <- Map.get(state.saved, mac) == dps do
      state.save_state.(mac, dps)
      %{state | saved: Map.put(state.saved, mac, dps)}
    else
      _unknown_or_saved -> state
    end
  end

  defp save(state, _group), do: state

  # A Store that (re)started, or was out of reach, may hold older states
  # than the views here (held changes lost in a crash): every bulb whose
  # state is known is saved again; the Store drops what it already has.
  defp resave(state) do
    known = for {{:bulb, _mac} = t, %{dps: dps}} <- state.views, is_boolean(dps[1]), do: t
    Enum.reduce(known, %{state | saved: %{}}, &save(&2, &1))
  end

  # The states the Store kept, for bulbs with no view yet (see "Light
  # state"). With no send times and no report cursor (`:reported`), the
  # seed loses to every report Lights holds and to every command.
  defp seed(state) do
    ids = read_ids(state)

    seeded =
      for {mac, dps} <- saved_states(state),
          not Map.has_key?(state.views, {:bulb, mac}),
          id = Map.get(ids, {:bulb, mac}),
          is_integer(id),
          into: %{},
          do: {{:bulb, mac}, %{device_id: id, dps: dps, sent_at: %{}}}

    macs = for {:bulb, mac} <- Map.keys(seeded), do: mac

    %{state | views: Map.merge(state.views, seeded)}
    |> mark_dirty(Map.keys(seeded) ++ groups_of(state, macs))
  end

  defp saved_states(state) do
    case state.saved_states.() do
      saved when is_map(saved) ->
        for {mac, dps} <- saved, is_binary(mac), is_map(dps), dps != %{}, do: {mac, dps}

      _unreadable ->
        []
    end
  end

  defp forget_pushed(state, targets) do
    if state.states, do: Enum.each(targets, &:ets.delete(state.states, &1))
    %{state | pushed: Map.drop(state.pushed, targets)}
  end

  defp response_for(state, _target, _settings, nil, _ids), do: {state, nil}

  defp response_for(state, {:bulb, _mac} = target, settings, id, _ids) do
    case view_dps(state, target, id) do
      nil -> {state, nil}
      dps -> {state, Commands.state_response(dps, settings, light_key(target), id)}
    end
  end

  # A group follows its members (Home Assistant's light-group rules); with
  # none known yet, what was last sent to it.
  defp response_for(state, {:group, gid} = target, settings, id, ids) do
    members =
      state.mesh_groups
      |> Map.get(gid, [])
      |> Enum.map(&view_dps(state, {:bulb, &1}, Map.get(ids, {:bulb, &1})))
      |> Enum.reject(&is_nil/1)

    state =
      case GroupState.aggregate(members) do
        nil ->
          state

        agg ->
          dps = with_controls(agg, view_dps(state, target, id))
          %{state | views: Map.put(state.views, target, %{device_id: id, dps: dps, sent_at: %{}})}
      end

    case view_dps(state, target, id) do
      nil -> {state, nil}
      dps -> {state, Commands.state_response(dps, settings, light_key(target), id)}
    end
  end

  # Off says nothing about the mode, colour or brightness: an all-off group
  # keeps the ones it had, so a later "on" without a mode keeps them too.
  defp with_controls(%{1 => false} = off, kept) when map_size(off) == 1 and is_map(kept),
    do: Map.put(kept, 1, false)

  defp with_controls(agg, _kept), do: agg

  defp light_key({:bulb, mac}), do: Entities.key_for(Entities.object_id({:bulb, mac, :light}))
  defp light_key({:group, gid}), do: Entities.key_for(Entities.object_id({:group, gid, :light}))

  defp states_table(opts) do
    case Keyword.get(opts, :states_table, Keyword.get(opts, :name, __MODULE__) == __MODULE__) do
      true -> :ets.new(@states_table, [:named_table, :set, :protected, read_concurrency: true])
      :unnamed -> :ets.new(__MODULE__, [:set, :protected, read_concurrency: true])
      _none -> nil
    end
  end

  defp default_push(server, struct) do
    Espex.push_state(server, struct)
  rescue
    ArgumentError -> :ok
  end

  # ── Inputs ───────────────────────────────────────────────────────────

  # A bulb first commanded starts from the DPs it last reported.
  defp base_dps(state, {:bulb, mac} = target) do
    case Map.get(state.views, target) do
      %{dps: dps} when dps != %{} ->
        %{}

      _unknown ->
        case state.lights.status(mac, state.lights_opts) do
          {:ok, %{dps: dps}} when is_map(dps) -> dps
          _other -> %{}
        end
    end
  end

  defp base_dps(_state, _target), do: %{}

  defp members(_state, {:bulb, _mac}), do: []

  defp members(state, {:group, gid}) do
    case state.members.(gid) do
      {:ok, macs} when is_list(macs) -> macs
      _unknown -> []
    end
  end

  defp snapshot(_state, _target, []), do: %{}

  defp snapshot(state, _target, members) do
    case state.lights.all(state.lights_opts) do
      {:ok, bulbs} ->
        for %{mac: mac} = bulb <- bulbs,
            mac in members,
            into: %{},
            do: {mac, Map.get(bulb, :dp_reported_at) || %{}}

      _error ->
        %{}
    end
  end

  defp default_members(gid) do
    case Enum.find(TuyaMesh.status().groups, &(&1.local_id == gid)) do
      %{members: macs} -> {:ok, macs}
      nil -> :error
    end
  end

  defp default_device_ids, do: Store.device_ids()

  defp default_saved_states, do: Store.light_states()

  defp default_save_state(mac, dps), do: Store.put_light_state(mac, dps)

  defp describe({:bulb, mac}), do: "bulb #{mac}"
  defp describe({:group, gid}), do: "group #{gid}"
end
