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

  Follow-ups go one at a time, oldest unconfirmed first, and among those
  unconfirmed by the same broadcast, bulbs with misses first. When the
  frame caps (below) don't fit them all into one cycle, the rest carry
  over, keeping their place, so every bulb's verdict comes within a
  bounded time. A bulb's direct follow-ups back off with its misses: none
  after its first (the second, deciding one comes at the next cycle),
  then `:direct_backoff_ms` (2 min) after its second, doubling to
  `:max_direct_backoff_ms` (15 min). It still hears every broadcast, and
  any frame from it, its power-on announce included, confirms it at once:
  misses and backoff clear as soon as `heard_ms` advances.

  Every frame (broadcast or direct) is sent only when all of these hold:

    * nothing is outstanding (one frame and its reply window at a time);
    * `:min_gap_ms` (5 s) passed since the last attempt, or since an
      uncertain one settled (below);
    * the frame caps allow it: at most `:max_per_minute` (10) attempts in
      any 60 s and `:max_per_hour` (240) in any hour;
    * `Radio.status/1` reads ready, discovering and listening, with
      nothing on air and nothing queued, so a frame never queues in front
      of, or behind, a command.

  A broadcast that is due goes before follow-ups. Ticks come every
  `:tick_ms` (5 s), or every `:busy_tick_ms` (1 s) while a frame is
  outstanding, follow-ups wait, or the pinger is settling.

  ## Outage detection

  All of 10 bulbs losing power is noticed within about 2.5 to 3.5
  minutes. Each needs two misses, so 20 direct pings plus the broadcasts
  around them, one frame per 5 s slot but at most 10 in any minute. Worst
  case, the power goes just after a broadcast was answered (t = 0):

    * the next broadcast airs by about 66 s (60 s cycle, +10 % jitter)
      and draws nothing; its window closes at about 71 s;
    * 9 direct pings fill that minute's cap (71 to 111 s): 9 first misses;
    * the next broadcast airs once the first frame leaves the 60 s window
      (about 126 s); then the carried-over tenth bulb's first miss and,
      as earlier frames leave the window, the other 9's second misses
      (131 to 176 s, the last decided by about 181 s);
    * the tenth bulb's second miss follows the third broadcast (about
      186 s): decided by about 197 s.

  So the last bulb is Not reachable about 3.3 min after the power went
  (plus a second or two of tick granularity), the first after about
  2.3 min; a smaller mesh, or power going just before a broadcast, is
  faster. The Resolver's reachable window (2.5 cycles) also stops a bulb
  reading reachable 150 s after it was last heard, before its second
  miss.

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

  Every new process starts settling too, and counts a full minute's cap as
  spent at its start. Lights and the Radio can outlive a pinger (a crash
  restarts only it), so a predecessor's frame may still be queued and its
  frames of the last minute are unknown. So the first broadcast goes about
  a minute after a start.

  ## Budget

  The caps bound every case: at most 10 frames in any minute and 240 in
  any hour, each one sequence number (refused frames hand theirs back)
  and one advert slot of at least 3 s.

    * Healthy (10 bulbs): one broadcast a minute plus a direct ping for
      each of its usual 1 or 2 stragglers, so 2 to 3 frames a minute (120
      to 180 an hour; 6 to 9 min of airtime, 10 to 15 %). A bulb whose
      inventory `beaconKey` overrides the mesh key can't open broadcasts,
      so it is a straggler every cycle.
    * All dead: one broadcast a minute plus direct pings backed off to 15
      min each, about 100 an hour once the first 20 minutes are past.
    * The hour cap leaves 60 frames of headroom over the healthy maximum
      for an outage's burst (about 25 frames). The minute cap is what
      makes the detection above take 3 minutes rather than 2; at 10 a
      minute a burst holds at most 30 s of each minute's air, and only
      while the bulbs it pings aren't answering anything.

  At the cap, 240 numbers an hour (5_760 a day). Lights sizes leases for
  one persist per minute at the observed rate, clamped to at least 32
  numbers: at 4 numbers a minute that is one persist every 8 minutes or
  more (at most about 180 a day), under the one-a-minute budget. The
  16-bit counter then moves half its range in under 6 days and wraps in
  under 12, so an old dump soon reads as ahead of the device's counter;
  the Store takes a dump's `seq` only as a bounded advance of at most 299
  (`UniversalProxy.TuyaMesh.Store`, "Upload seq"), which holds however
  fast the counter moves: a stale dump can only ever move it forward, and
  by at most 299.

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
  `:mesh_generation`, `:name`, and the timing above (`:cycle_ms`,
  `:broadcast_reply_ms`, `:reply_ms`, `:fresh_ms`, `:min_gap_ms`,
  `:max_per_minute`, `:max_per_hour`, `:direct_backoff_ms`,
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
  @direct_backoff_ms 120_000
  @max_direct_backoff_ms 900_000
  @tick_ms 5_000
  @busy_tick_ms 1_000
  @minute 60_000
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

    state = %{
      lights: Keyword.get(opts, :lights, Lights),
      radio: Keyword.get(opts, :radio, Radio),
      notify: Keyword.get(opts, :notify),
      generation:
        {Keyword.get(opts, :mesh_generation, 0), System.unique_integer([:monotonic, :positive])},
      clock: clock,
      jitter: Keyword.get(opts, :jitter, &default_jitter/1),
      cycle_ms: Keyword.get(opts, :cycle_ms, @cycle_ms),
      broadcast_reply_ms: Keyword.get(opts, :broadcast_reply_ms, @broadcast_reply_ms),
      reply_ms: Keyword.get(opts, :reply_ms, @reply_ms),
      fresh_ms: Keyword.get(opts, :fresh_ms, @fresh_ms),
      gap_ms: Keyword.get(opts, :min_gap_ms, @min_gap_ms),
      per_minute: per_minute,
      per_hour: Keyword.get(opts, :max_per_hour, @max_per_hour),
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
      # Attempt times of the last hour. A predecessor may have spent this
      # minute's.
      sent: List.duplicate(started, per_minute),
      next_broadcast: started,
      pushed: nil,
      timer: nil
    }

    {:ok, schedule(state)}
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
    do: %{last: last, misses: 0, missed_at: nil, unconfirmed: nil, direct_after: nil}

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
        %{state | pending: nil}

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

  # The broadcast's non-responders are unconfirmed (unless their direct
  # pings are backed off); a direct ping's silence is a miss.
  defp close_window(state, :broadcast, asked) do
    now = state.clock.()

    bulbs =
      Map.new(state.bulbs, fn {mac, b} ->
        cond do
          heard_since?(b, asked - state.fresh_ms) -> {mac, b}
          b.unconfirmed != nil -> {mac, b}
          b.direct_after != nil and now < b.direct_after -> {mac, b}
          true -> {mac, %{b | unconfirmed: asked}}
        end
      end)

    %{state | bulbs: bulbs}
  end

  defp close_window(state, {:direct, mac}, asked),
    do: %{state | bulbs: Map.update!(state.bulbs, mac, &missed(&1, asked, state))}

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
         true <- within_caps?(state, now),
         {:ok, kind} <- next_frame(state, now),
         {:idle, sn} <- radio_idle(state) do
      send_frame(state, kind, sn)
    else
      _ -> state
    end
  end

  defp next_frame(state, now) do
    if now >= state.next_broadcast do
      {:ok, :broadcast}
    else
      state.bulbs
      |> Enum.filter(fn {_mac, b} -> b.unconfirmed != nil end)
      |> Enum.min_by(fn {mac, b} -> {b.unconfirmed, -b.misses, mac} end, fn -> nil end)
      |> case do
        {mac, _bulb} -> {:ok, {:direct, mac}}
        nil -> :none
      end
    end
  end

  defp send_frame(state, kind, sn) do
    asked = state.clock.()
    state = %{state | next_attempt: asked + state.gap_ms}

    state =
      if kind == :broadcast,
        do: %{state | next_broadcast: asked + state.cycle_ms + state.jitter.(state.cycle_ms)},
        else: state

    # Anything but a confirmed frame is "try later": nothing is unconfirmed
    # or missed. Unless it provably queued nothing it may still air, so it
    # counts against the caps and the next frame waits for it to settle.
    case call(state, kind) do
      :ok ->
        state = count(state, asked)

        if aired_alone?(state, sn) do
          window = if kind == :broadcast, do: state.broadcast_reply_ms, else: state.reply_ms
          %{state | pending: %{kind: kind, asked: asked, deadline: state.clock.() + window}}
        else
          %{state | settling: :lights}
        end

      {:error, reason} when reason in @refused ->
        still_due(state, kind, asked)

      {:error, {:advertise, _reason}} ->
        still_due(state, kind, asked)

      {:error, _uncertain} ->
        %{count(state, asked) | settling: :lights}
    end
  end

  # A refused broadcast stays due; a refused direct ping stays unconfirmed.
  defp still_due(state, :broadcast, asked), do: %{state | next_broadcast: asked}
  defp still_due(state, _direct, _asked), do: state

  defp call(state, :broadcast), do: Lights.ping_all(server: state.lights)
  defp call(state, {:direct, mac}), do: Lights.ping(mac, server: state.lights)

  defp count(state, at), do: %{state | sent: [at | Enum.filter(state.sent, &(at - &1 < @hour))]}

  defp within_caps?(state, now) do
    Enum.count(state.sent, &(now - &1 < @minute)) < state.per_minute and
      Enum.count(state.sent, &(now - &1 < @hour)) < state.per_hour
  end

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
         interval_ms: state.cycle_ms,
         pinging: direct == mac
       }}
    end)
  end

  # Uniform in ±10 % of the interval.
  defp default_jitter(ms) do
    span = div(ms, 10)
    :rand.uniform(2 * span + 1) - span - 1
  end
end
