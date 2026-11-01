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

  Every `:tick_ms` (5 s) it reads `Lights.all/1` (each bulb's
  `last_report_ms`, kept as the latest seen) and then, at most once, pings
  the most overdue bulb that is:

    * due: its next check time has passed (below);
    * silent for over `:silence_ms` (60 s), or never heard;

  and only when all of these hold:

    * no ping is outstanding (one at a time: the last one got its reply,
      or `:reply_ms`, 10 s, passed without one);
    * `:min_gap_ms` (30 s) passed since the last ping attempt;
    * `Radio.status/1` reads ready, nothing on air and nothing queued
      (`queued == 0`), so a ping never queues in front of, or behind, a
      command.

  A bulb's next check is its last reply plus its interval, or the missed
  ping plus its interval, each with `:jitter` added (default ±10 %), so
  bulbs drift apart instead of lining up. The interval is
  `:base_interval_ms` (2 min) while the bulb answers; after `n`
  consecutive missed pings it is `base * 2^(n-1)`, capped at
  `:max_interval_ms` (15 min): 2, 2, 4, 8, 15 min. Any report (a ping
  reply, a DP report from an acked command) resets it. A fresh start
  checks every bulb once after `:start_delay_ms` (15 s, jittered), or at
  its last reply plus the base interval when that is later.

  A ping refused for a reason of the moment (`:busy`, `:queue_full`,
  `:not_ready`, `:not_running`, a timeout, anything but `:ok`) is not a
  miss: the bulb stays due and is tried again after the gap.

  ## Budget

  Every attempt waits `:min_gap_ms` after the previous one, so pings are
  bounded by `3_600_000 / min_gap_ms` per hour whatever the bulb count:
  120/hour with the defaults. That bound is only reached when every bulb
  answers: each wants a ping every 2 min, so from `base / min_gap` = 4
  bulbs on, the gap paces them (10 bulbs: one each ~5 min). Dead bulbs
  cost little: at 15 min each, 4/hour. Each ping takes one sequence
  number (refused frames hand theirs back) and one advert slot of at least
  3 s, so the worst case is 120 numbers and 6 min of airtime (10 %) per
  hour. Lights sizes leases for one persist per minute at the observed
  rate, clamped to at least 32 numbers: 2 numbers a minute make one
  persist every 16 min at most (90 a day) from pinging alone, far under
  that target.

  ## Snapshot

  After each tick, when it changed, `{:tuya_mesh_presence, snapshot}` is
  sent to `:notify` (a pid; the Resolver passes itself), where
  `snapshot` maps each MAC to `t:bulb/0`: the latest report time, the
  consecutive missed pings and when the last missed one was sent, the
  bulb's expected time between checks (`interval_ms`: its interval, or the
  gap times the bulb count when that is longer), and whether a ping to it
  is outstanding. Times are monotonic milliseconds from `:clock`.

  ## Supervision

  The last child of `UniversalProxy.TuyaMesh.Mesh` (`:rest_for_one`
  Radio → Lights → Presence). A crash here restarts only this process:
  Radio and Lights keep running. A Radio or Lights restart restarts it
  too, which is right: its view of either is stale then. Its state is
  only the schedule, so a restart costs one early round of pings; the
  verdicts it pushed survive in the Resolver. Every call it makes goes
  through `Lights`'/`Radio`'s own `catch :exit` wrappers, which turn a
  stopped or stuck server into an error tuple, so only a bug here can
  crash it.

  Options: `:lights`, `:radio` (server names), `:notify`, `:name`, and
  the timing above (`:tick_ms`, `:start_delay_ms`, `:silence_ms`,
  `:base_interval_ms`, `:max_interval_ms`, `:min_gap_ms`, `:reply_ms`),
  plus test seams `:clock` (`(-> integer())`, monotonic ms) and `:jitter`
  (`(interval_ms -> offset_ms)`).
  """

  use GenServer

  alias UniversalProxy.TuyaBeaconMesh.{Lights, Radio}

  @tick_ms 5_000
  @start_delay_ms 15_000
  @silence_ms 60_000
  @base_interval_ms 120_000
  @max_interval_ms 900_000
  @min_gap_ms 30_000
  @reply_ms 10_000
  # Short: the readiness check runs in this loop.
  @radio_timeout 1_000

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

    state = %{
      lights: Keyword.get(opts, :lights, Lights),
      radio: Keyword.get(opts, :radio, Radio),
      notify: Keyword.get(opts, :notify),
      clock: clock,
      started: clock.(),
      jitter: Keyword.get(opts, :jitter, &default_jitter/1),
      tick_ms: Keyword.get(opts, :tick_ms, @tick_ms),
      start_delay_ms: Keyword.get(opts, :start_delay_ms, @start_delay_ms),
      silence_ms: Keyword.get(opts, :silence_ms, @silence_ms),
      base_ms: Keyword.get(opts, :base_interval_ms, @base_interval_ms),
      max_ms: Keyword.get(opts, :max_interval_ms, @max_interval_ms),
      gap_ms: Keyword.get(opts, :min_gap_ms, @min_gap_ms),
      reply_ms: Keyword.get(opts, :reply_ms, @reply_ms),
      bulbs: %{},
      lights_ok: false,
      pending: nil,
      next_attempt: nil,
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
    token = make_ref()
    %{state | timer: {token, Process.send_after(self(), {:tick, token}, state.tick_ms)}}
  end

  # ── Tick ─────────────────────────────────────────────────────────────

  defp run(state) do
    now = state.clock.()

    state
    |> refresh(now)
    |> resolve_pending(now)
    |> maybe_ping(now)
    |> push()
  end

  # Bulbs come and go with the inventory Lights holds; while Lights is
  # down the last view is kept and nothing is pinged.
  defp refresh(state, now) do
    case Lights.all(server: state.lights) do
      {:ok, list} ->
        bulbs =
          Map.new(list, fn %{mac: mac} = bulb ->
            {mac, merge(Map.get(state.bulbs, mac), bulb.last_report_ms, now, state)}
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

  defp resolve_pending(%{pending: nil} = state, _now), do: state

  defp resolve_pending(%{pending: %{mac: mac, sent: sent}} = state, now) do
    bulb = Map.fetch!(state.bulbs, mac)

    cond do
      # Refresh already reset it (heard/3).
      bulb.last != nil and bulb.last >= sent ->
        %{state | pending: nil}

      now - sent >= state.reply_ms ->
        %{state | pending: nil, bulbs: Map.put(state.bulbs, mac, missed(bulb, sent, state))}

      true ->
        state
    end
  end

  defp missed(bulb, sent, state) do
    misses = bulb.misses + 1
    interval = min(state.base_ms * Integer.pow(2, misses - 1), state.max_ms)

    %{
      bulb
      | misses: misses,
        missed_at: sent,
        interval: interval,
        due: sent + interval + state.jitter.(interval)
    }
  end

  defp maybe_ping(state, now) do
    with nil <- state.pending,
         true <- state.lights_ok,
         true <- state.next_attempt == nil or now >= state.next_attempt,
         {:ok, mac} <- next_due(state, now),
         true <- radio_idle?(state) do
      state = %{state | next_attempt: now + state.gap_ms}

      # Anything but :ok (busy, queue full, not ready, timeout...) is
      # "try later": the bulb stays due, nothing counts as a miss.
      case Lights.ping(mac, server: state.lights) do
        :ok -> %{state | pending: %{mac: mac, sent: now}}
        {:error, _reason} -> state
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

  defp radio_idle?(state) do
    case Radio.status(server: state.radio, timeout: @radio_timeout) do
      {:ok, %{ready: true, queued: 0} = status} -> Map.get(status, :tx) == nil
      _ -> false
    end
  end

  # ── Snapshot ─────────────────────────────────────────────────────────

  defp push(%{notify: nil} = state), do: state

  defp push(state) do
    snapshot = build_snapshot(state)

    if snapshot != state.pushed do
      send(state.notify, {:tuya_mesh_presence, snapshot})
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
