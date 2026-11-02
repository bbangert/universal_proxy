defmodule UniversalProxy.TuyaMesh.Presence do
  @moduledoc """
  The mesh pinger: keeps every bulb's presence known without starving
  commands.

  Beacon Mesh bulbs never report on their own: they answer a ping (a
  presence reply) or an acked DP set (a DP report), nothing else. So a
  bulb nobody commands goes silent, and only a ping tells a live one from
  a dead one. This process pings, and pushes what it learns to the
  Resolver, which decides what the status calls reachable.

  ## Schedule

  Every `:tick_ms` (5 s; `:pending_tick_ms`, 1 s, while a ping is
  outstanding) it reads `Lights.all/1` (each bulb's `heard_ms`: the last
  frame from it, including ones Lights holds while re-anchoring a reset
  counter; kept as the latest seen) and then, at most once, pings the
  most overdue bulb that is:

    * due: its next check time has passed (below);
    * silent for over `:silence_ms` (60 s), or never heard;

  and only when all of these hold:

    * no ping is outstanding (one at a time);
    * `:min_gap_ms` (60 s) passed since the last ping attempt. A new
      process (a restart of this one, of Lights or the Radio, or of the
      whole mesh after an upload) starts as if it had just attempted one:
      its predecessor may have, and no state survives the restart to say
      when;
    * `Radio.status/1` reads ready, discovering and listening, with
      nothing on air and nothing queued, so a ping never queues in front
      of, or behind, a command.

  A bulb's next check is its last reply plus its interval, or the missed
  ping plus its interval, each with `:jitter` added (default ±10 %), so
  bulbs drift apart instead of lining up. The interval is
  `:base_interval_ms` (2 min) while the bulb answers; after `n`
  consecutive missed pings it is `base * 2^(n-1)`, capped at
  `:max_interval_ms` (15 min): 2, 2, 4, 8, 15 min. Any report (a ping
  reply, a DP report from an acked command) resets it. A fresh start
  checks every bulb once after `:start_delay_ms` (15 s, jittered; the
  gap above holds the first attempt to 60 s), or at its last reply plus
  the base interval when that is later.

  ## What counts as a miss

  A miss is counted only when the ping provably aired alone and the whole
  reply window passed with a working receiver. Anything uncertain gives
  no verdict: the attempt is dropped, the bulb stays due and is tried
  again after the gap, and nothing counts towards the miss limit.

    * A ping refused (`:busy`, `:queue_full`, `:not_ready`,
      `:not_running`, a timeout, anything but `:ok`): no verdict.
    * `Lights.ping/2` returns `:ok` for a frame merely queued: a command
      can reach the Radio between the idle check and the ping, and then
      the ping waits behind it (or a control send drops it). So right
      after the call, `Radio.status/1` must show the ping on air: the
      radio still working (as above), something on air, nothing queued,
      and `last_tx_sn` exactly one past the value read at the idle check.
      Otherwise no verdict.
    * The reply window (`:reply_ms`, 10 s) starts when that confirmation
      is read. A report counts as the reply when it is no older than the
      moment just before the ping call, so one arriving during the call
      counts too.
    * Every tick in the window reads the Radio again: not ready, not
      discovering or not listening drops the attempt (a receiver that was
      down may have missed the reply).
    * The window closing while `Lights.all/1` fails defers the verdict to
      the next read that works, which may still show the reply.

  Residual imprecision, which only core changes could remove: the Radio
  is sampled once a second, so a receiver lost and back inside one second
  goes unseen; `last_tx_sn` one ahead could, in principle, belong to
  another frame if Lights' cursor skipped a number and that frame aired
  while the ping was dropped, both inside the call; an advert cut short by
  `Radio.stop_tx/1` after the confirmation is not seen. Numbers handed
  out but never aired (a cursor gap), or a Radio that hasn't sent a frame
  yet (`last_tx_sn` nil), make one ping fail confirmation for nothing;
  the next one passes.

  ## Budget

  Every attempt waits `:min_gap_ms` after the previous one, so pings are
  bounded by `3_600_000 / min_gap_ms` per hour whatever the bulb count:
  60/hour with the default 60 s. That bound is reached when every bulb
  answers: each wants a ping every 2 min, so from `base / min_gap` = 2
  bulbs on, the gap paces them (10 bulbs: one each ~10 min). Dead bulbs
  cost little: at 15 min each, 4/hour.

  Each ping takes one sequence number (refused frames hand theirs back)
  and one advert slot of at least 3 s. At the bound that is 60 numbers
  (1_440 a day) and 3 min of airtime (5 %) an hour. Lights sizes leases for
  one persist per minute at the observed rate, clamped to at least 32
  numbers, so pinging alone causes one persist every 32 min at most (45 a
  day). It also moves the shared 16-bit counter half its range in about 23
  days, past which an old dump would compare as ahead: the Store accepts a
  dump's `seq` only as a bounded advance on its own cursor
  (`UniversalProxy.TuyaMesh.Store`, "Upload seq"), so that is safe.

  60 s rather than 30 s: twice the numbers, persists and airtime would buy
  only a faster first round after a restart (10 bulbs: 10 min instead of
  5 min to all heard) and checks every 5 min instead of 10 for live bulbs.
  A dead bulb is still found within about two of its checks either way.

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
  process counted and when the last missed ping was asked for, the bulb's
  expected time between checks (`interval_ms`: its interval, or the gap
  times the bulb count when that is longer), and whether a ping to it is
  outstanding. Times are monotonic milliseconds from `:clock`.

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
  `:mesh_generation`, `:name`, and
  the timing above (`:tick_ms`, `:pending_tick_ms`, `:start_delay_ms`,
  `:silence_ms`, `:base_interval_ms`, `:max_interval_ms`, `:min_gap_ms`,
  `:reply_ms`), plus test seams `:clock` (`(-> integer())`, monotonic ms)
  and `:jitter` (`(interval_ms -> offset_ms)`).
  """

  use GenServer

  alias UniversalProxy.TuyaBeaconMesh.{Lights, Radio}

  @tick_ms 5_000
  @pending_tick_ms 1_000
  @start_delay_ms 15_000
  @silence_ms 60_000
  @base_interval_ms 120_000
  @max_interval_ms 900_000
  @min_gap_ms 60_000
  @reply_ms 10_000
  # Short: the readiness checks run in this loop.
  @radio_timeout 1_000
  @sn_space 65_536

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
    gap_ms = Keyword.get(opts, :min_gap_ms, @min_gap_ms)

    state = %{
      lights: Keyword.get(opts, :lights, Lights),
      radio: Keyword.get(opts, :radio, Radio),
      notify: Keyword.get(opts, :notify),
      generation:
        {Keyword.get(opts, :mesh_generation, 0), System.unique_integer([:monotonic, :positive])},
      clock: clock,
      started: started,
      jitter: Keyword.get(opts, :jitter, &default_jitter/1),
      tick_ms: Keyword.get(opts, :tick_ms, @tick_ms),
      pending_tick_ms: Keyword.get(opts, :pending_tick_ms, @pending_tick_ms),
      start_delay_ms: Keyword.get(opts, :start_delay_ms, @start_delay_ms),
      silence_ms: Keyword.get(opts, :silence_ms, @silence_ms),
      base_ms: Keyword.get(opts, :base_interval_ms, @base_interval_ms),
      max_ms: Keyword.get(opts, :max_interval_ms, @max_interval_ms),
      gap_ms: gap_ms,
      reply_ms: Keyword.get(opts, :reply_ms, @reply_ms),
      bulbs: %{},
      lights_ok: false,
      pending: nil,
      # The predecessor may have just attempted one.
      next_attempt: started + gap_ms,
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

  # Faster while a ping is outstanding, so the receiver is checked
  # through its reply window.
  defp schedule(state) do
    with {_token, tref} <- state.timer, do: Process.cancel_timer(tref)
    ms = if state.pending, do: min(state.tick_ms, state.pending_tick_ms), else: state.tick_ms
    token = make_ref()
    %{state | timer: {token, Process.send_after(self(), {:tick, token}, ms)}}
  end

  # ── Tick ─────────────────────────────────────────────────────────────

  defp run(state) do
    state
    |> refresh()
    |> resolve_pending()
    |> maybe_ping()
    |> push()
  end

  # Bulbs come and go with the inventory Lights holds; while Lights is
  # down the last view is kept and nothing is pinged.
  defp refresh(state) do
    now = state.clock.()

    case Lights.all(server: state.lights) do
      {:ok, list} ->
        bulbs =
          Map.new(list, fn %{mac: mac} = bulb ->
            {mac, merge(Map.get(state.bulbs, mac), bulb.heard_ms, now, state)}
          end)

        pending = if state.pending && Map.has_key?(bulbs, state.pending.mac), do: state.pending
        %{state | bulbs: bulbs, pending: pending, lights_ok: true}

      {:error, _reason} ->
        %{state | lights_ok: false}
    end
  end

  defp merge(nil, last, now, state) do
    start = max(now, state.started + state.start_delay_ms + state.jitter.(state.start_delay_ms))
    due = if last, do: max(start, last + state.base_ms), else: start
    %{last: last, misses: 0, missed_at: nil, interval: state.base_ms, due: due}
  end

  defp merge(bulb, last, _now, state) do
    if newer?(last, bulb.last), do: heard(bulb, last, state), else: bulb
  end

  defp newer?(nil, _known), do: false
  defp newer?(_last, nil), do: true
  defp newer?(last, known), do: last > known

  # Any report: the bulb is there, back to the base interval.
  defp heard(bulb, last, state) do
    %{
      bulb
      | last: last,
        misses: 0,
        missed_at: nil,
        interval: state.base_ms,
        due: last + state.base_ms + state.jitter.(state.base_ms)
    }
  end

  defp resolve_pending(%{pending: nil} = state), do: state

  defp resolve_pending(%{pending: %{mac: mac, asked: asked, deadline: deadline}} = state) do
    bulb = Map.fetch!(state.bulbs, mac)

    cond do
      # Refresh already reset it (heard/3).
      bulb.last != nil and bulb.last >= asked ->
        %{state | pending: nil}

      # The reply may have gone unheard: no verdict.
      not receiving?(state) ->
        %{state | pending: nil}

      # The read that would show the reply failed: decide on a later one.
      not state.lights_ok ->
        state

      state.clock.() >= deadline ->
        %{state | pending: nil, bulbs: Map.put(state.bulbs, mac, missed(bulb, asked, state))}

      true ->
        state
    end
  end

  defp missed(bulb, asked, state) do
    misses = bulb.misses + 1
    interval = min(state.base_ms * Integer.pow(2, misses - 1), state.max_ms)

    %{
      bulb
      | misses: misses,
        missed_at: asked,
        interval: interval,
        due: asked + interval + state.jitter.(interval)
    }
  end

  defp maybe_ping(state) do
    now = state.clock.()

    with nil <- state.pending,
         true <- state.lights_ok,
         true <- now >= state.next_attempt,
         {:ok, mac} <- next_due(state, now),
         {:idle, sn} <- radio_idle(state) do
      asked = state.clock.()
      state = %{state | next_attempt: asked + state.gap_ms}

      # Anything but :ok (busy, queue full, not ready, timeout...) is
      # "try later": the bulb stays due, nothing counts as a miss. So is
      # an :ok that can't be confirmed on air alone.
      with :ok <- Lights.ping(mac, server: state.lights),
           true <- aired_alone?(state, sn) do
        deadline = state.clock.() + state.reply_ms
        %{state | pending: %{mac: mac, asked: asked, deadline: deadline}}
      else
        _ -> state
      end
    else
      _ -> state
    end
  end

  defp next_due(state, now) do
    state.bulbs
    |> Enum.filter(fn {_mac, b} -> now >= b.due and silent?(b, now, state) end)
    |> Enum.min_by(fn {mac, b} -> {b.due, mac} end, fn -> nil end)
    |> case do
      {mac, _bulb} -> {:ok, mac}
      nil -> :none
    end
  end

  defp silent?(%{last: nil}, _now, _state), do: true
  defp silent?(%{last: last}, now, state), do: now - last > state.silence_ms

  # ── Radio ────────────────────────────────────────────────────────────

  defp radio_status(state), do: Radio.status(server: state.radio, timeout: @radio_timeout)

  # The SN of the last frame aired, read with the idle check: the ping's
  # confirmation compares against it.
  defp radio_idle(state) do
    case radio_status(state) do
      {:ok, %{queued: 0, tx: nil} = status} ->
        if working?(status), do: {:idle, status.last_tx_sn}, else: :busy

      _ ->
        :busy
    end
  end

  # The ping is the frame on air and the only one the Radio took since the
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
    round_ms = map_size(state.bulbs) * state.gap_ms
    pending = state.pending && state.pending.mac

    Map.new(state.bulbs, fn {mac, b} ->
      {mac,
       %{
         last_ms: b.last,
         misses: b.misses,
         missed_at: b.missed_at,
         interval_ms: max(b.interval, round_ms),
         pinging: pending == mac
       }}
    end)
  end

  # Uniform in ±10 % of the interval.
  defp default_jitter(ms) do
    span = div(ms, 10)
    :rand.uniform(2 * span + 1) - span - 1
  end
end
