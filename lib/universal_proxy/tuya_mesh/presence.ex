defmodule UniversalProxy.TuyaMesh.Presence do
  @moduledoc """
  The mesh pinger: keeps every bulb's presence known without starving
  commands.

  Beacon Mesh bulbs don't report on their own, except once at power-on
  (an unprompted ping reply): they answer a ping (a presence reply) or an
  acked DP set (a DP report). So a bulb nobody commands goes silent, and
  only a ping tells a live one from a dead one. This process pings, and
  pushes what it learns to the Resolver, which decides what the status
  calls reachable.

  ## Schedule

  Every `:cycle_ms` (60 s, jittered by `:jitter`, default ±10 %) it sends
  one broadcast ping (`Lights.ping_all/1`). Every bulb that hears it
  should answer, but replies collide: on hardware a broadcast drew 8 or 9
  of 10, a different bulb missing each time
  (`docs/protocols/tuya_beacon_mesh.md` §4.9). So a missing reply leaves
  a bulb **unconfirmed**, not missed:

    * a bulb whose `heard_ms` (the last frame from it, `Lights.all/1`;
      including ones Lights holds while re-anchoring a reset counter)
      advanced within the broadcast's reply window (`:broadcast_reply_ms`,
      5 s), or in the `:fresh_ms` (15 s) before the broadcast, is
      confirmed;
    * every other bulb becomes unconfirmed and gets **one** direct
      `Lights.ping/2` in the follow-up slots after it. Only when that
      direct ping too goes unanswered for its window (`:reply_ms`, 5 s)
      is it a **miss**.

  Follow-ups go one at a time, in two classes:

    * **urgent**: a deciding second miss, or, in a **suspected outage**,
      a check of any bulb not yet missed twice. An outage is suspected
      when a broadcast drew replies from fewer than half of the bulbs
      heard in the 10 minutes before it (known stragglers aside, they
      never answer broadcasts; at least 2 such bulbs), and lasts until a
      broadcast draws half again. Urgent checks go first, oldest
      unconfirmed first and, from the same broadcast, misses first.
    * **routine**: everything else, a bulb that missed one broadcast (a
      collision, most likely), a persistent straggler's check, a dead
      bulb's backed-off one. They go by deadline: the moment the bulb's
      reachable window at the Resolver (2.5 × its `interval_ms`) would run
      out.

  What the budget (below) doesn't fit carries over, keeping its place.

  A bulb's direct follow-ups back off with its misses: none after its
  first (the second, deciding one comes at the next cycle), then
  `:direct_backoff_ms` (2 min) after its second, doubling to
  `:max_direct_backoff_ms` (15 min). It still hears every broadcast, and
  any frame from it, its power-on announce included, confirms it at once:
  misses and backoff clear as soon as `heard_ms` advances.

  A **persistent straggler** (it missed the broadcast and answered the
  direct ping twice in a row, e.g. a bulb whose `beaconKey` overrides the
  mesh key and can't open broadcasts) is checked directly every other
  cycle at most, and its `interval_ms` in the snapshot is honest about it:
  two cycles, or, when the routine budget can't serve all stragglers that
  often, the time it takes to: stragglers × the routine spacing, against
  the routine rate less what suspect checks took over the last ten
  minutes (counted as at least half of it), rounded up to 30 s. 4
  stragglers: 120 s (window 300 s); 10: 300 s (window 750 s). Deadline
  order then serves each within that. Outside an outage, such a bulb
  going dead is noticed a cycle or two later than the others; in a
  suspected outage its cadence is set aside and it is checked at once.
  Answering a broadcast clears the record.

  Every frame (broadcast or direct) is sent only when all of these hold:

    * nothing is outstanding (one frame and its reply window at a time);
    * `:min_gap_ms` (5 s) passed since the last attempt, or since an
      uncertain one settled (below);
    * its budget allows it (see "Budget");
    * `Radio.status/1` reads ready, discovering and listening, with
      nothing on air and nothing queued, so a frame never queues in front
      of, or behind, a command.

  A broadcast that is due goes before follow-ups. Ticks come every
  `:tick_ms` (5 s), or every `:busy_tick_ms` (1 s) while a frame is
  outstanding, follow-ups wait, or the pinger is settling.

  ## Outage detection

  All of 10 bulbs losing power is noticed in about 2.3 to 3.3 minutes,
  whatever routine traffic came before (an hour of rotating broadcast
  misses, or a straggler warm-up, use routine budget only). Each needs two
  misses, so 20 urgent direct pings plus the broadcasts around them, one
  frame per 5 s slot, at most 8 follow-ups in any minute (one slot of the
  10 stays free for a broadcast). Worst case, the power goes just after a
  broadcast was answered (t = 0; simulated without jitter):

    * the next broadcast airs at 60 s and draws nothing: an outage is
      suspected; its window closes at 65 s;
    * 8 urgent direct pings (65 to 100 s): 8 first misses;
    * the next broadcast at 120 s; then, as earlier frames leave the
      minute, the two bulbs left over from the first cycle (their first
      misses) and the first 6 of the others' second misses: the first
      bulbs are Not reachable at about 135 s;
    * the third broadcast at 180 s; the last 4 second misses: the last
      bulb is Not reachable at about 200 s.

  So 2.3 to 3.3 min, up to about 3.5 with the cycle's jitter; a smaller
  mesh, or power going just before a broadcast, is faster. The Resolver's
  reachable window (2.5 cycles) also stops a bulb reading reachable 150 s
  after it was last heard, before its second miss.

  ## What counts as a miss

  A miss is counted only when the direct ping provably aired alone and
  its whole reply window passed with a working receiver; a bulb becomes
  unconfirmed only when the broadcast provably aired alone and its window
  passed the same way. Anything uncertain gives no verdict: nothing is
  unconfirmed or missed, and the frame is tried again later.

    * A frame refused (`:busy`, `:queue_full`, `:not_ready`, a timeout,
      anything but `:ok`): no verdict.
    * `Lights.ping/2` and `ping_all/1` return `:ok` for a frame merely
      queued: a command can reach the Radio between the idle check and
      the call, and then the frame waits behind it (or a control send
      drops it). So right after the call, `Radio.status/1` must show it on
      air: the radio still working (as above), something on air, nothing
      queued, and `last_tx_sn` exactly one past the value read at the idle
      check. Otherwise no verdict.
    * The reply window starts when that confirmation is read. A report
      counts as a reply when it is no older than the moment just before
      the call, so one arriving during the call counts too.
    * Every tick in the window reads the Radio again: not ready, not
      discovering or not listening drops the attempt (a receiver that was
      down may have missed the replies).
    * The window closing while `Lights.all/1` fails defers the verdict to
      the next read that works, which may still show the replies.

  Residual imprecision, which only core changes could remove: the Radio
  is sampled once a second, so a receiver lost and back inside one second
  goes unseen; `last_tx_sn` one ahead could, in principle, belong to
  another frame if Lights' cursor skipped a number and that frame aired
  while ours was dropped, both inside the call; an advert cut short by
  `Radio.stop_tx/1` after the confirmation is not seen. Numbers handed
  out but never aired (a cursor gap), or a Radio that hasn't sent a frame
  yet (`last_tx_sn` nil), make one frame fail confirmation for nothing;
  the next one passes.

  ## Settling an uncertain frame

  A frame whose fate is unknown may still air later: a call that timed
  out stays in Lights' queue, an `:ok` that couldn't be confirmed may sit
  queued behind a command, and `{:uncertain, _}` (or `:not_running`,
  which a Lights crash mid-call also returns) may have gone out. So after
  any outcome but a confirmed frame or a refusal known to have queued
  nothing (`:busy`, `:queue_full`, `:not_ready`, `:unknown_bulb`,
  `:persist_failed`, a refused advertise), the pinger settles first: it
  waits for a later `Lights.all/1` to return (Lights handles calls in
  order, so the request is done with by then), then for the Radio to read
  idle (nothing queued, nothing on air), and the gap starts from that
  moment. An uncertain attempt counts against the caps.

  Every new process starts settling too: Lights and the Radio can outlive
  a pinger (a crash restarts only it), so a predecessor's frame may still
  be queued.

  ## Budget

  At most `:max_per_minute` (10) frames in any 60 s and `:max_per_hour`
  (240) in any hour, each one sequence number (refused frames hand theirs
  back) and one advert slot of at least 3 s. Within that:

    * **Broadcasts are reserved** `:broadcast_reserve` an hour: as many as
      the shortest jittered cycle allows (60 s - 10 %: 67). Follow-ups
      never use that share, and always leave one slot of each minute
      free, so a due broadcast is never held back by follow-ups and every
      bulb that answers broadcasts stays heard within the Resolver's
      window, whatever the stragglers do.
    * **Follow-ups** share the rest of the hour (240 - 67 = 173).
    * **Routine** follow-ups leave `:urgent_reserve` (40) of that to
      urgent ones (at most half of it), so 133 an hour, and are spaced
      evenly (`:routine_spacing_ms`, the hour / 133, 27 s), so a heavy
      straggler load never spends the hour early and never starves
      urgent checks. 2.2 a minute: 10 stragglers each every 300 s, or 2
      broadcast collisions a minute (20 per 10 min) with room to spare.
    * **Urgent** follow-ups aren't spaced: an outage's burst (about 20 in
      3 minutes) only meets the minute cap and the follow-ups' 173 an
      hour, of which routine ones leave at least 40.

  What that gives:

    * Healthy (10 bulbs): one broadcast a minute plus 1 or 2 stragglers,
      2 to 3 frames a minute (120 to 180 an hour; 10 to 15 % airtime);
      persistent stragglers every other cycle at most, so 4 of them add 2
      a minute.
    * All dead: one broadcast a minute plus direct pings backed off to 15
      min each, about 100 an hour once the first 20 minutes are past.
    * At the cap, 240 numbers an hour (5_760 a day). Lights sizes leases
      for one persist per minute at the observed rate, clamped to at
      least 32 numbers: at 4 a minute that is one persist every 8 minutes
      or more (at most about 180 a day), under the one-a-minute budget.
      The 16-bit counter then moves half its range in under 6 days and
      wraps in under 12, so an old dump soon reads as ahead of the
      device's counter; the Store takes a dump's `seq` only as a bounded
      advance of at most 299 (`UniversalProxy.TuyaMesh.Store`, "Upload
      seq"), which holds however fast the counter moves.

  ## Frame log

  The caps count the frames of the last hour from a frame log, an ETS
  table (`:frames`) that the Resolver owns and passes to every Presence
  it starts, so a pinger restart or a mesh restart (an upload) keeps the
  hour's history. Each attempt is logged before its call (a crash inside
  the call still counts it) and removed again only when the frame was
  provably refused. A Resolver that stops hands the log to its successor;
  one that was killed leaves its successor a log that doesn't know the
  last hour (`unknown_history/3`): the minute's cap counts as spent and
  only broadcasts go (within their reservation) until an hour has passed.
  Without `:frames` (tests), a Presence keeps a log of its own, lost with
  it, and starts with the minute's cap counted as spent.

  ## Snapshot

  After each tick, when it changed, `{:tuya_mesh_presence, generation,
  snapshot}` is sent to `:notify` (a pid; the Resolver passes itself).
  `generation` is `{mesh, pinger}`: `:mesh_generation` (given by the
  Resolver, bumped for every mesh it starts) and a
  `System.unique_integer([:monotonic])` taken when this process starts,
  so a later pinger always has a larger one. Messages from two processes
  have no order between them; these numbers do, so the Resolver can drop
  a late snapshot from a pinger already replaced. `snapshot` maps each MAC
  to `t:bulb/0`: the latest report time, the consecutive misses this
  process counted and when the last missed ping was asked for, the time
  expected between checks of the bulb (`interval_ms`: the cycle), and
  whether a direct ping to it is outstanding. Times are monotonic
  milliseconds from `:clock`.

  ## Supervision

  The last child of `UniversalProxy.TuyaMesh.Mesh` (`:rest_for_one`
  Radio → Lights → Presence). A crash here restarts only this process:
  Radio and Lights keep running. A Radio or Lights restart restarts it
  too, which is right: its view of either is stale then. Its state is
  only the schedule; the verdicts it pushed survive in the Resolver, which
  adds a restarted pinger's misses to the old one's. Every call it makes
  goes through `Lights`'/`Radio`'s own `catch :exit` wrappers, which turn
  a stopped or stuck server into an error tuple, so only a bug here can
  crash it.

  Options: `:lights`, `:radio` (server names), `:notify`,
  `:mesh_generation`, `:frames`, `:name`, and the timing above
  (`:cycle_ms`, `:broadcast_reply_ms`, `:reply_ms`, `:fresh_ms`,
  `:min_gap_ms`, `:max_per_minute`, `:max_per_hour`, `:broadcast_reserve`,
  `:urgent_reserve`, `:routine_spacing_ms`, `:direct_backoff_ms`,
  `:max_direct_backoff_ms`, `:tick_ms`, `:busy_tick_ms`), plus test seams
  `:clock` (`(-> integer())`, monotonic ms) and `:jitter` (`(interval_ms
  -> offset_ms)`).
  """

  use GenServer

  alias UniversalProxy.TuyaBeaconMesh.{Lights, Radio}

  @cycle_ms 60_000
  @broadcast_reply_ms 5_000
  @reply_ms 5_000
  @fresh_ms 15_000
  @min_gap_ms 5_000
  @max_per_minute 10
  @max_per_hour 240
  # Follow-ups only urgent checks (deciding misses, a suspected outage's)
  # may use: an outage's two rounds over 10 bulbs, twice over.
  @urgent_reserve 40
  # Recently heard bulbs of which fewer than half answer a broadcast: a
  # suspected outage.
  @recent_ms 600_000
  @interval_step 30_000
  # A persistent straggler (missed the broadcast, answered the direct ping,
  # twice in a row) is checked directly every other cycle.
  @straggler_cycles 2
  @direct_backoff_ms 120_000
  @max_direct_backoff_ms 900_000
  @tick_ms 5_000
  @busy_tick_ms 1_000
  @minute 60_000
  @ten_minutes 600_000
  @hour 3_600_000
  # Short: the readiness checks run in this loop.
  @radio_timeout 1_000
  @sn_space 65_536
  # Refusals that provably queued nothing for the Radio.
  @refused [:busy, :queue_full, :not_ready, :unknown_bulb, :persist_failed]

  @type bulb :: %{
          last_ms: integer() | nil,
          misses: non_neg_integer(),
          missed_at: integer() | nil,
          interval_ms: pos_integer(),
          pinging: boolean()
        }

  @type snapshot :: %{String.t() => bulb()}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The current snapshot (see the moduledoc)."
  @spec snapshot(GenServer.server()) :: {:ok, snapshot()} | {:error, :not_running}
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  catch
    :exit, _reason -> {:error, :not_running}
  end

  @doc """
  Marks `table` (a frame log, see "Frame log") as not knowing what was sent
  before `now`: the minute cap counts as spent, and no follow-up goes
  until an hour has passed.
  """
  @spec unknown_history(:ets.tid() | atom(), integer(), keyword()) :: true
  def unknown_history(table, now, opts \\ []) do
    per_minute = Keyword.get(opts, :max_per_minute, @max_per_minute)
    rows = for _ <- 1..per_minute, do: {System.unique_integer([:monotonic]), now, :unknown}
    :ets.insert(table, [{:unknown_until, now + @hour} | rows])
  end

  @doc false
  # Runs one tick now: tests drive the schedule with a fake clock.
  @spec poll(GenServer.server()) :: :ok
  def poll(server \\ __MODULE__), do: GenServer.call(server, :poll)

  # ── Server ───────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
    started = clock.()
    per_minute = Keyword.get(opts, :max_per_minute, @max_per_minute)
    per_hour = Keyword.get(opts, :max_per_hour, @max_per_hour)
    cycle_ms = Keyword.get(opts, :cycle_ms, @cycle_ms)
    frames = frame_log(Keyword.get(opts, :frames), started, per_minute)

    state = %{
      lights: Keyword.get(opts, :lights, Lights),
      radio: Keyword.get(opts, :radio, Radio),
      notify: Keyword.get(opts, :notify),
      generation:
        {Keyword.get(opts, :mesh_generation, 0), System.unique_integer([:monotonic, :positive])},
      clock: clock,
      jitter: Keyword.get(opts, :jitter, &default_jitter/1),
      cycle_ms: cycle_ms,
      broadcast_reply_ms: Keyword.get(opts, :broadcast_reply_ms, @broadcast_reply_ms),
      reply_ms: Keyword.get(opts, :reply_ms, @reply_ms),
      fresh_ms: Keyword.get(opts, :fresh_ms, @fresh_ms),
      gap_ms: Keyword.get(opts, :min_gap_ms, @min_gap_ms),
      per_minute: per_minute,
      per_hour: per_hour,
      broadcast_reserve:
        Keyword.get(opts, :broadcast_reserve, min(broadcast_reserve(cycle_ms), per_hour)),
      urgent_reserve: Keyword.get(opts, :urgent_reserve, @urgent_reserve),
      routine_spacing_ms: Keyword.get(opts, :routine_spacing_ms),
      outage: false,
      straggler_interval: 0,
      backoff_ms: Keyword.get(opts, :direct_backoff_ms, @direct_backoff_ms),
      max_backoff_ms: Keyword.get(opts, :max_direct_backoff_ms, @max_direct_backoff_ms),
      tick_ms: Keyword.get(opts, :tick_ms, @tick_ms),
      busy_tick_ms: Keyword.get(opts, :busy_tick_ms, @busy_tick_ms),
      bulbs: %{},
      lights_ok: false,
      # nil, or :lights then :radio while settling (moduledoc, "Settling an
      # uncertain frame"). A new process starts settling: a predecessor's
      # frame may still be queued.
      settling: :lights,
      pending: nil,
      next_attempt: started,
      frames: frames,
      next_broadcast: started,
      pushed: nil,
      timer: nil
    }

    {:ok, state |> budgets() |> schedule()}
  end

  # Follow-ups get what the broadcasts' reservation leaves of the hour;
  # routine ones all but the urgent reserve, spaced evenly over the hour so
  # it never runs out early (see "Budget").
  defp budgets(state) do
    followups = max(state.per_hour - state.broadcast_reserve, 0)
    routine = followups - min(state.urgent_reserve, div(followups, 2))

    Map.merge(state, %{
      followup_hour: followups,
      routine_hour: routine,
      routine_spacing_ms: state.routine_spacing_ms || spacing(routine)
    })
  end

  @impl GenServer
  def handle_call(:snapshot, _from, state), do: {:reply, {:ok, build_snapshot(state)}, state}
  def handle_call(:poll, _from, state), do: {:reply, :ok, run(state)}

  @impl GenServer
  def handle_info({:tick, token}, %{timer: {token, _}} = state),
    do: {:noreply, state |> run() |> schedule()}

  def handle_info(_other, state), do: {:noreply, state}

  defp schedule(state) do
    with {_token, tref} <- state.timer, do: Process.cancel_timer(tref)
    ms = if busy?(state), do: min(state.tick_ms, state.busy_tick_ms), else: state.tick_ms
    token = make_ref()
    %{state | timer: {token, Process.send_after(self(), {:tick, token}, ms)}}
  end

  defp busy?(state) do
    state.pending != nil or state.settling != nil or
      Enum.any?(state.bulbs, fn {_mac, b} -> b.unconfirmed != nil end)
  end

  # ── Tick ─────────────────────────────────────────────────────────────

  defp run(state) do
    state
    |> refresh()
    |> resolve_pending()
    |> then(&%{&1 | straggler_interval: straggler_interval(&1, &1.clock.())})
    |> maybe_send()
    |> push()
  end

  # Bulbs come and go with the inventory Lights holds; while Lights is
  # down the last view is kept and nothing is sent.
  defp refresh(state) do
    case Lights.all(server: state.lights) do
      {:ok, list} ->
        bulbs =
          Map.new(list, fn %{mac: mac} = bulb ->
            {mac, merge(Map.get(state.bulbs, mac), bulb.heard_ms)}
          end)

        pending =
          case state.pending do
            %{kind: {:direct, mac}} = p -> if Map.has_key?(bulbs, mac), do: p
            other -> other
          end

        settling = if state.settling == :lights, do: :radio, else: state.settling
        %{state | bulbs: bulbs, pending: pending, lights_ok: true, settling: settling}

      {:error, _reason} ->
        %{state | lights_ok: false}
    end
  end

  defp merge(nil, last),
    do: %{
      last: last,
      misses: 0,
      missed_at: nil,
      unconfirmed: nil,
      direct_after: nil,
      straggles: 0
    }

  defp merge(bulb, last), do: if(newer?(last, bulb.last), do: heard(bulb, last), else: bulb)

  defp newer?(nil, _known), do: false
  defp newer?(_last, nil), do: true
  defp newer?(last, known), do: last > known

  # Any frame from it: the bulb is there; misses and backoff clear.
  defp heard(bulb, last),
    do: %{bulb | last: last, misses: 0, missed_at: nil, unconfirmed: nil, direct_after: nil}

  defp heard_since?(%{last: last}, at), do: last != nil and last >= at

  # ── Verdicts ─────────────────────────────────────────────────────────

  defp resolve_pending(%{pending: nil} = state), do: state

  defp resolve_pending(%{pending: %{kind: kind, asked: asked, deadline: deadline}} = state) do
    cond do
      # A direct ping's reply: refresh already confirmed it (heard/2).
      answered?(state, kind, asked) ->
        straggled(%{state | pending: nil}, kind, asked)

      # Replies may have gone unheard: no verdict.
      not receiving?(state) ->
        %{state | pending: nil}

      # The read that would show the replies failed: decide on a later one.
      not state.lights_ok ->
        state

      state.clock.() >= deadline ->
        close_window(%{state | pending: nil}, kind, asked)

      true ->
        state
    end
  end

  defp answered?(state, {:direct, mac}, asked), do: heard_since?(state.bulbs[mac], asked)
  defp answered?(_state, :broadcast, _asked), do: false

  # Missed the broadcast, answered the direct ping. From the second time
  # in a row it is a persistent straggler (it may never hear broadcasts):
  # its next direct check skips a cycle.
  defp straggled(state, {:direct, mac}, asked) do
    update_in(state.bulbs[mac], fn b ->
      straggles = b.straggles + 1

      if straggles >= @straggler_cycles,
        do: %{b | straggles: straggles, direct_after: asked + straggler_backoff(state)},
        else: %{b | straggles: straggles}
    end)
  end

  # Past the next cycle's follow-ups, before the one after.
  defp straggler_backoff(state),
    do: state.cycle_ms * (@straggler_cycles - 1) + div(state.cycle_ms, 2)

  # The broadcast's non-responders are unconfirmed (unless their direct
  # pings are backed off); a direct ping's silence is a miss.
  defp close_window(state, :broadcast, asked) do
    now = state.clock.()
    outage = outage?(state, asked)

    bulbs =
      Map.new(state.bulbs, fn {mac, b} ->
        cond do
          heard_since?(b, asked) -> {mac, %{b | straggles: 0}}
          heard_since?(b, asked - state.fresh_ms) -> {mac, b}
          b.unconfirmed != nil -> {mac, b}
          waiting?(b, now, outage) -> {mac, b}
          true -> {mac, %{b | unconfirmed: asked}}
        end
      end)

    %{state | bulbs: bulbs, outage: outage}
  end

  defp close_window(state, {:direct, mac}, asked),
    do: %{state | bulbs: Map.update!(state.bulbs, mac, &missed(&1, asked, state))}

  # Backed off: a dead bulb always, a straggler's cadence except in an
  # outage (then it may be dead too, and is checked at once).
  defp waiting?(%{direct_after: nil}, _now, _outage), do: false
  defp waiting?(%{misses: 0}, _now, true), do: false
  defp waiting?(b, now, _outage), do: now < b.direct_after

  # Fewer than half of the bulbs heard in the last 10 minutes, known
  # stragglers aside (they never answer broadcasts), answered this one.
  defp outage?(state, asked) do
    recent =
      Enum.filter(state.bulbs, fn {_mac, b} ->
        b.straggles < @straggler_cycles and heard_since?(b, asked - @recent_ms)
      end)

    answered = Enum.count(recent, fn {_mac, b} -> heard_since?(b, asked) end)
    length(recent) >= 2 and answered * 2 < length(recent)
  end

  defp missed(bulb, asked, state) do
    misses = bulb.misses + 1

    %{
      bulb
      | misses: misses,
        missed_at: asked,
        unconfirmed: nil,
        direct_after: asked + direct_backoff(misses, state)
    }
  end

  # None after the first miss (the deciding second comes next cycle), then
  # the base, doubling, capped.
  defp direct_backoff(1, _state), do: 0

  defp direct_backoff(misses, state),
    do: min(state.backoff_ms * Integer.pow(2, misses - 2), state.max_backoff_ms)

  # ── Sending ──────────────────────────────────────────────────────────

  defp maybe_send(%{settling: :radio} = state) do
    case radio_idle(state) do
      {:idle, _sn} -> %{state | settling: nil, next_attempt: state.clock.() + state.gap_ms}
      _ -> state
    end
  end

  defp maybe_send(%{settling: :lights} = state), do: state

  defp maybe_send(state) do
    now = state.clock.()

    with nil <- state.pending,
         true <- state.lights_ok,
         true <- now >= state.next_attempt,
         {:ok, kind, tag} <- next_frame(state, now),
         {:idle, sn} <- radio_idle(state) do
      send_frame(state, kind, tag, sn)
    else
      _ -> state
    end
  end

  # A due broadcast within its reservation goes first; a follow-up only
  # within the follow-up budget (see "Budget").
  defp next_frame(state, now) do
    if now >= state.next_broadcast and broadcast_allowed?(state, now),
      do: {:ok, :broadcast, :broadcast},
      else: next_followup(state, now)
  end

  # Urgent checks first (a deciding second miss, or in a suspected outage
  # any bulb not yet missed twice), oldest unconfirmed first and, from the
  # same broadcast, misses first; then routine ones by deadline, the
  # moment the bulb's reachable window would run out.
  defp next_followup(state, now) do
    urgent? = followup_allowed?(state, now, :urgent)
    routine? = followup_allowed?(state, now, :routine)

    state.bulbs
    |> Enum.filter(fn {_mac, b} -> b.unconfirmed != nil end)
    |> Enum.map(fn {mac, b} -> {mac, b, class(state, b)} end)
    |> Enum.filter(fn {_mac, _b, class} ->
      if class == :urgent, do: urgent?, else: routine?
    end)
    |> Enum.min_by(fn {mac, b, class} -> order(state, b, class, mac) end, fn -> nil end)
    |> case do
      {mac, _b, :urgent} -> {:ok, {:direct, mac}, :urgent}
      {mac, b, :routine} -> {:ok, {:direct, mac}, routine_tag(b)}
      nil -> :none
    end
  end

  defp class(_state, %{misses: 1}), do: :urgent
  defp class(%{outage: true}, %{misses: 0}), do: :urgent
  defp class(_state, _bulb), do: :routine

  defp order(_state, b, :urgent, mac), do: {0, b.unconfirmed, -b.misses, mac}
  defp order(state, b, :routine, mac), do: {1, deadline(state, b), mac}

  defp deadline(state, b), do: (b.last || b.unconfirmed) + div(interval(state, b) * 5, 2)

  # Routine checks of stragglers and dead bulbs are maintenance; others
  # (a bulb that just missed a broadcast) suspect. Both count as routine.
  defp routine_tag(%{misses: 0, straggles: s}) when s < @straggler_cycles, do: :suspect
  defp routine_tag(_bulb), do: :maintenance

  defp send_frame(state, kind, tag, sn) do
    asked = state.clock.()
    state = %{state | next_attempt: asked + state.gap_ms}

    state =
      if kind == :broadcast,
        do: %{state | next_broadcast: asked + state.cycle_ms + state.jitter.(state.cycle_ms)},
        else: state

    # Logged before the call, so a crash inside it still counts.
    key = log_frame(state, asked, tag)

    # Anything but a confirmed frame is "try later": nothing is unconfirmed
    # or missed. Unless it provably queued nothing it may still air, so it
    # stays counted and the next frame waits for it to settle.
    case call(state, kind) do
      :ok ->
        if aired_alone?(state, sn) do
          window = if kind == :broadcast, do: state.broadcast_reply_ms, else: state.reply_ms
          %{state | pending: %{kind: kind, asked: asked, deadline: state.clock.() + window}}
        else
          %{state | settling: :lights}
        end

      {:error, reason} when reason in @refused ->
        unlog_frame(state, key)
        still_due(state, kind, asked)

      {:error, {:advertise, _reason}} ->
        unlog_frame(state, key)
        still_due(state, kind, asked)

      {:error, _uncertain} ->
        %{state | settling: :lights}
    end
  end

  # A refused broadcast stays due; a refused direct ping stays unconfirmed.
  defp still_due(state, :broadcast, asked), do: %{state | next_broadcast: asked}
  defp still_due(state, _direct, _asked), do: state

  defp call(state, :broadcast), do: Lights.ping_all(server: state.lights)
  defp call(state, {:direct, mac}), do: Lights.ping(mac, server: state.lights)

  # ── Frame log ────────────────────────────────────────────────────────

  # The shared log a Resolver owns, or one of this process's own (lost
  # with it, so a start counts the minute's cap as spent).
  defp frame_log(nil, started, per_minute) do
    table = :ets.new(__MODULE__, [:set, :private])
    rows = for _ <- 1..per_minute, do: {System.unique_integer([:monotonic]), started, :unknown}
    :ets.insert(table, rows)
    table
  end

  defp frame_log(table, _started, _per_minute), do: table

  # Rows are `{key, at, tag}`, tag `:broadcast`, `:urgent`, `:suspect`,
  # `:maintenance` or `:unknown`.
  defp log_frame(state, at, tag) do
    key = System.unique_integer([:monotonic])
    :ets.select_delete(state.frames, [{{:_, :"$1", :_}, [{:<, :"$1", at - @hour}], [true]}])
    :ets.insert(state.frames, {key, at, tag})
    key
  end

  defp unlog_frame(state, key), do: :ets.delete(state.frames, key)

  @followups [:urgent, :suspect, :maintenance]
  @routine [:suspect, :maintenance]

  # Frames with a tag in `tags` (all when nil) sent after `since`.
  defp frames_since(state, since, tags \\ nil) do
    :ets.tab2list(state.frames)
    |> Enum.count(fn
      {_key, at, tag} when is_integer(at) -> at > since and (tags == nil or tag in tags)
      _marker -> false
    end)
  end

  defp broadcast_allowed?(state, now) do
    frames_since(state, now - @minute) < state.per_minute and
      frames_since(state, now - @hour, [:broadcast]) < state.broadcast_reserve
  end

  # One slot of every minute is left for a broadcast; follow-ups share
  # what the hour's broadcasts don't reserve; routine ones leave the urgent
  # reserve and are spaced evenly; none while the log doesn't know the last
  # hour.
  defp followup_allowed?(state, now, class) do
    not history_unknown?(state, now) and
      frames_since(state, now - @minute) < state.per_minute - 1 and
      frames_since(state, now - @hour, @followups) < state.followup_hour and
      (class == :urgent or routine_allowed?(state, now))
  end

  defp routine_allowed?(state, now) do
    frames_since(state, now - @hour, @routine) < state.routine_hour and
      frames_since(state, now - state.routine_spacing_ms, @routine) == 0
  end

  defp spacing(0), do: @hour
  defp spacing(per_hour), do: div(@hour, per_hour) + 1

  defp history_unknown?(state, now) do
    case :ets.lookup(state.frames, :unknown_until) do
      [{:unknown_until, until}] -> now < until
      [] -> false
    end
  end

  # Broadcasts an hour can hold at the shortest jittered cycle (-10 %).
  defp broadcast_reserve(cycle_ms), do: div(@hour, cycle_ms - div(cycle_ms, 10)) + 1

  # ── Radio ────────────────────────────────────────────────────────────

  defp radio_status(state), do: Radio.status(server: state.radio, timeout: @radio_timeout)

  # The SN of the last frame aired, read with the idle check: the frame's
  # confirmation compares against it.
  defp radio_idle(state) do
    case radio_status(state) do
      {:ok, %{queued: 0, tx: nil} = status} ->
        if working?(status), do: {:idle, status.last_tx_sn}, else: :busy

      _ ->
        :busy
    end
  end

  # Ours is the frame on air and the only one the Radio took since the
  # idle check: nothing queued in front of or behind it.
  defp aired_alone?(state, sn) when is_integer(sn) do
    case radio_status(state) do
      {:ok, %{queued: 0, tx: tx, last_tx_sn: last} = status} when tx != nil ->
        working?(status) and last == rem(sn + 1, @sn_space)

      _ ->
        false
    end
  end

  defp aired_alone?(_state, nil), do: false

  defp receiving?(state) do
    case radio_status(state) do
      {:ok, status} -> working?(status)
      _ -> false
    end
  end

  defp working?(%{ready: true, discovering: true, listening: true}), do: true
  defp working?(_status), do: false

  # ── Snapshot ─────────────────────────────────────────────────────────

  defp push(%{notify: nil} = state), do: state

  defp push(state) do
    snapshot = build_snapshot(state)

    if snapshot != state.pushed do
      send(state.notify, {:tuya_mesh_presence, state.generation, snapshot})
      %{state | pushed: snapshot}
    else
      state
    end
  end

  defp build_snapshot(state) do
    direct =
      case state.pending do
        %{kind: {:direct, mac}} -> mac
        _ -> nil
      end

    Map.new(state.bulbs, fn {mac, b} ->
      {mac,
       %{
         last_ms: b.last,
         misses: b.misses,
         missed_at: b.missed_at,
         interval_ms: interval(state, b),
         pinging: direct == mac
       }}
    end)
  end

  # A persistent straggler is checked every other cycle, or less often
  # when the routine budget can't serve all stragglers that often: the
  # stragglers between them get the routine rate less what suspect checks
  # took over the last ten minutes (never counted below half of it).
  defp interval(state, %{straggles: n}) when n >= @straggler_cycles,
    do: max(state.cycle_ms * @straggler_cycles, state.straggler_interval)

  defp interval(state, _bulb), do: state.cycle_ms

  defp straggler_interval(state, now) do
    stragglers = Enum.count(state.bulbs, fn {_mac, b} -> b.straggles >= @straggler_cycles end)
    per_minute = @minute / max(state.routine_spacing_ms, 1)
    suspects = frames_since(state, now - @ten_minutes, [:suspect]) / 10
    share = max(per_minute - suspects, per_minute / 2)

    if stragglers == 0 or share <= 0 do
      0
    else
      ms = stragglers * @minute / share
      ceil(ms / @interval_step) * @interval_step
    end
  end

  # Uniform in ±10 % of the interval.
  defp default_jitter(ms) do
    span = div(ms, 10)
    :rand.uniform(2 * span + 1) - span - 1
  end
end
