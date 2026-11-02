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
      `:followup_gap_ms`. A DP is confirmed only by a report after the
      command that changed it to the wanted value (Lights keeps merged
      DPs, not per-report ones), so a DP that already held that value is
      resent.

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

  ## Optimistic state

  Each light's last known DPs are kept here, with its brightness, colour
  brightness and RGB peak (`Commands.components/2`, each kept only once a
  batch carrying the DP it shapes was accepted: `Commands.committed/2`):
  what was sent to it and accepted, over the Lights report DPs for a bulb first commanded. Once a
  command's sends are accepted, the light's `LightStateResponse` (with
  its `device_id`) is pushed to Espex, so HA doesn't snap back. A group
  diverted to direct sends records only what at least one member
  accepted. A light whose on/off isn't known yet gets no push, and
  nothing refused is recorded or pushed.

  Options: `:name`, `:lights` (module, default `Lights`) and `:lights_opts`
  (extra options to its calls, e.g. `server:`), `:members` (`gid ->
  {:ok, [mac]} | :error`, default from `UniversalProxy.TuyaMesh.status/1`),
  `:device_ids` (`-> map`, default `Store.device_ids/1`), `:pubsub` and
  `:subscribe` (default `true`) for the Store broadcasts, `:push` (`struct
  -> any`, default `Espex.push_state/2` on `:server`), `:server`,
  `:presence` (server, default `Presence`), `:radio_status` (`-> {:ok,
  map} | {:error, term}`, default `Radio.status/1` with a 500 ms timeout),
  `:radio_poll_ms`, `:window_ms` (6 s),
  `:retry_ms`, `:max_retry_ms`, `:stale_ms`, `:followup_gap_ms`,
  `:activity_hold_ms`, `:keepalive_ms` (see "Backlog"), `:max_followups`
  (10).
  """

  # TODO(4c): reconcile `views` with real reports (Lights report updates,
  # group aggregation) and push member bulb states after a group command.

  use GenServer

  require Logger

  alias Espex.Proto
  alias UniversalProxy.TuyaBeaconMesh.{Lights, Radio}
  alias UniversalProxy.TuyaMesh
  alias UniversalProxy.TuyaMesh.{Commands, Presence, Store}

  @retryable [:busy, :queue_full]

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

    if Keyword.get(opts, :subscribe, true),
      do: {:ok, state, {:continue, :subscribe}},
      else: {:ok, state}
  end

  @impl GenServer
  def handle_continue(:subscribe, state), do: {:noreply, subscribe(state)}

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
    current = view_dps(state, target, command.device_id) || base

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

  def handle_info({:tuya_mesh_store, _event}, state),
    do: {:noreply, state |> reconcile() |> reschedule()}

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
    case Enum.filter(job.members, &newer_command?(state, &1, job)) do
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
        state = state |> accepted_frame() |> record(job, batch)
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
    state = update_member_view(state, mac, Commands.expected(batch), job.components)
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
    {before_ms, before_dps} = Map.get(job.snapshot, mac, {nil, %{}})

    missing =
      if reported_since?(bulb, before_ms),
        do: Commands.unconfirmed(job.sent, fresh_dps(Map.get(bulb, :dps), before_dps)),
        else: job.sent

    Commands.split(missing)
  end

  defp reported_since?(%{last_report_ms: at}, before) when is_integer(at), do: at != before
  defp reported_since?(_bulb, _before), do: false

  # Lights merges partial reports into a bulb's cached DPs, and a ping
  # reply moves `last_report_ms` too, so only a DP whose value changed since
  # the command was provably reported after it. One that already held the
  # wanted value counts as unconfirmed: at worst a redundant frame.
  defp fresh_dps(dps, before) when is_map(dps),
    do: Map.reject(dps, fn {id, value} -> Map.fetch(before, id) == {:ok, value} end)

  defp fresh_dps(_dps, _before), do: %{}

  defp newer_command?(state, mac, job), do: Map.get(state.touched, mac, 0) > job.id

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

    views =
      Map.filter(state.views, fn {target, view} -> Map.get(ids, target) == view.device_id end)

    %{state | jobs: jobs, views: views}
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
  defp subscribe(state) do
    Phoenix.PubSub.subscribe(state.pubsub, Store.topic())
    reconcile(state)
  rescue
    ArgumentError ->
      Logger.warning("TuyaMesh.Commander: PubSub unavailable; not following Store changes")
      state
  end

  # ── Views and optimistic state ───────────────────────────────────────

  # A kept view belongs to one sub-device: another id's is never used
  # (without Store broadcasts, a replaced mesh's would linger).
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

    job.members
    |> Enum.reject(&newer_command?(state, &1, job))
    |> Enum.reduce(state, &update_member_view(&2, &1, sent, job.components))
  end

  defp record_light(state, job, sent) do
    dps =
      (view_dps(state, job.target, job.command.device_id) || job.base)
      |> Map.merge(sent)
      |> Map.merge(Commands.committed(job.components, sent))

    view = %{device_id: job.command.device_id, dps: dps}
    %{state | views: Map.put(state.views, job.target, view)}
  end

  defp update_member_view(state, mac, sent, components) do
    case Map.fetch(state.views, {:bulb, mac}) do
      {:ok, view} ->
        dps = view.dps |> Map.merge(sent) |> Map.merge(Commands.committed(components, sent))
        %{state | views: Map.put(state.views, {:bulb, mac}, %{view | dps: dps})}

      :error ->
        state
    end
  end

  defp push(state, job) do
    %{key: key, device_id: device_id, settings: settings} = job.command
    dps = view_dps(state, job.target, device_id) || %{}

    case Commands.state_response(dps, settings, key, device_id) do
      nil -> :ok
      response -> state.push.(response)
    end

    state
  end

  defp default_push(server, struct) do
    Espex.push_state(server, struct)
  rescue
    ArgumentError -> :ok
  end

  # ── Inputs ───────────────────────────────────────────────────────────

  # A bulb first commanded starts from the DPs it last reported.
  defp base_dps(%{views: views} = state, {:bulb, mac} = target)
       when not is_map_key(views, target) do
    case state.lights.status(mac, state.lights_opts) do
      {:ok, %{dps: dps}} when is_map(dps) -> dps
      _other -> %{}
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
            do: {mac, {Map.get(bulb, :last_report_ms), Map.get(bulb, :dps) || %{}}}

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

  defp describe({:bulb, mac}), do: "bulb #{mac}"
  defp describe({:group, gid}), do: "group #{gid}"
end
