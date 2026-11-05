defmodule UniversalProxy.Display.Viz do
  @moduledoc """
  Turns Sendspin visualizer frames into bar heights for the viewport, and
  the tiers it degrades through under load.

  A frame is the player's `viz` event (`%{bins: [0..255], loudness:
  0..255}`), a `viz_clear` (`%{event: "viz_clear"}`) or `nil` (none yet).
  Heights are fractions `0.0..1.0`, one per bar.

  `step/3` turns each tick's heights into what is drawn: a bar jumps up
  to a new peak, holds it briefly, then falls at a steady rate; after
  ~1.5 s of near-silent input every bar settles to zero and stays there
  (so the viewport stops redrawing).

  Tiers, from most to least work:

    * `:full` — every bin, every tick.
    * `:reduced` — neighbouring bins averaged in pairs, every other tick.
    * `:pulse` — every bar at the frame's loudness, every other tick.
    * `:off` — no bars; the viewport stops listening.
  """

  @type tier :: :full | :reduced | :pulse | :off
  @type frame :: map() | nil

  @typedoc "Frames waiting for their display time, newest first: `{due_ms, frame}`."
  @type buffer :: [{integer(), map()}]

  @typedoc """
  Drawn bar levels (`0.0..1.0`), how long (ms) each still holds its peak,
  and how long the input has been near silent.
  """
  @type meter :: %{levels: [float()], holds: [non_neg_integer()], quiet_ms: non_neg_integer()}

  @buffer_min 8
  # Never buffer more than this many seconds of frames.
  @buffer_max_s 3
  # Spare slots on top of the frames one lead time holds (jitter, bursts).
  @buffer_headroom 4
  # A lead beyond this is bogus: treated as this (bounded wait).
  @max_lead_ms 5_000

  @hold_ms 150
  @fall_per_s 2.0
  @quiet_level 0.03
  @silence_ms 1_500

  @tiers [:full, :reduced, :pulse, :off]

  @doc "The tiers, best first."
  @spec tiers() :: [tier()]
  def tiers, do: @tiers

  @doc "The tier below `tier` (`:off` stays `:off`)."
  @spec degrade(tier()) :: tier()
  def degrade(:full), do: :reduced
  def degrade(:reduced), do: :pulse
  def degrade(_tier), do: :off

  @doc "How many render ticks a tier redraws on (1 = every tick)."
  @spec tick_divisor(tier()) :: pos_integer()
  def tick_divisor(:full), do: 1
  def tick_divisor(_tier), do: 2

  @doc "`count` bar heights for `frame` at `tier`."
  @spec heights(frame(), tier(), non_neg_integer()) :: [float()]
  def heights(_frame, :off, count), do: zeros(count)

  def heights(%{bins: bins}, :full, count) when is_list(bins), do: resample(bins, count)

  def heights(%{bins: bins}, :reduced, count) when is_list(bins) do
    bins
    |> Enum.chunk_every(2)
    |> Enum.flat_map(fn chunk ->
      avg = Enum.sum(Enum.map(chunk, &byte/1)) / length(chunk)
      List.duplicate(avg, length(chunk))
    end)
    |> resample(count)
  end

  def heights(%{loudness: loudness}, :pulse, count),
    do: List.duplicate(byte(loudness) / 255, count)

  def heights(_frame, _tier, count), do: zeros(count)

  @doc """
  `bins` (0..255) resampled to `count` heights (`0.0..1.0`): each bar
  takes the peak of the bins it covers, or the nearest bin when there are
  more bars than bins.
  """
  @spec resample([number()], non_neg_integer()) :: [float()]
  def resample(_bins, 0), do: []
  def resample([], count), do: zeros(count)

  def resample(bins, count) do
    values = List.to_tuple(Enum.map(bins, &byte/1))
    n = tuple_size(values)

    for i <- 0..(count - 1) do
      first = div(i * n, count)
      last = max(div((i + 1) * n, count) - 1, first)
      peak = Enum.max(for j <- first..last, do: elem(values, j))
      peak / 255
    end
  end

  @doc """
  How many frames the due-frame buffer must hold for frames that arrive
  `lead_ms` early at `rate` frames per second: one lead time's worth plus
  headroom, at least #{@buffer_min} and at most #{@buffer_max_s} seconds' worth.
  """
  @spec buffer_cap(non_neg_integer() | nil, pos_integer() | nil) :: pos_integer()
  def buffer_cap(lead_ms, rate) when is_integer(rate) and rate > 0 do
    lead = min(max(lead_ms || 0, 0), @max_lead_ms)
    needed = ceil(lead * rate / 1000) + @buffer_headroom
    needed |> max(@buffer_min) |> min(max(rate * @buffer_max_s, @buffer_min))
  end

  def buffer_cap(_lead_ms, _rate), do: @buffer_min

  @doc """
  Adds a frame that arrived at `now` (monotonic ms). Frames come ahead of
  their display time by `lead_ms` (0 when absent, at most
  #{@max_lead_ms}), so each is due at `now + lead_ms`.

  A full buffer (`max` frames) drops the new frame, not the oldest: the
  oldest is the next one due, and dropping those would leave nothing to
  draw for a whole lead time. Size `max` with `buffer_cap/2`.

  A `viz_clear` replaces everything still waiting (`buffer_clear/1`) and
  is due at once, so no frame queued before it paints stale bars later.
  """
  @spec buffer_push(buffer(), map(), integer(), pos_integer()) :: buffer()
  def buffer_push(buffer, frame, now, max \\ @buffer_min)

  def buffer_push(buffer, %{event: "viz_clear"} = clear, now, _max),
    do: [{now, clear} | buffer_clear(buffer)]

  def buffer_push(buffer, frame, now, max) do
    if length(buffer) >= max do
      buffer
    else
      lead =
        case Map.get(frame, :lead_ms) do
          ms when is_integer(ms) and ms > 0 -> min(ms, @max_lead_ms)
          _other -> 0
        end

      [{now + lead, frame} | buffer]
    end
  end

  @doc "Drops every frame still waiting."
  @spec buffer_clear(buffer()) :: buffer()
  def buffer_clear(_buffer), do: []

  @doc """
  The frame to paint at `now`: the newest one already due, with older due
  frames discarded (`nil` while none is due), and the frames still waiting.
  """
  @spec buffer_take(buffer(), integer()) :: {map() | nil, buffer()}
  def buffer_take(buffer, now) do
    {due, waiting} = Enum.split_with(buffer, fn {due_ms, _frame} -> due_ms <= now end)

    case due do
      [{_due_ms, frame} | _older] -> {frame, waiting}
      [] -> {nil, waiting}
    end
  end

  @doc "A meter for `count` bars, all at zero."
  @spec meter(non_neg_integer()) :: meter()
  def meter(count),
    do: %{levels: zeros(count), holds: List.duplicate(0, count), quiet_ms: @silence_ms}

  @doc """
  Advances `meter` by `dt_ms` towards `targets` (this tick's heights, or
  `nil` when no fresh frame came: silence). Per bar: a target at or above
  the level becomes the level and is held #{@hold_ms} ms; after that the
  level falls #{@fall_per_s} bar heights per second, never below the
  target. Once every target has been below #{@quiet_level} for
  #{@silence_ms} ms the targets count as zero, so the bars settle and stop
  changing.
  """
  @spec step(meter(), [float()] | nil, pos_integer()) :: meter()
  def step(%{levels: levels} = meter, targets, dt_ms) do
    count = length(levels)
    targets = fit(targets, count)

    quiet_ms =
      if Enum.all?(targets, &(&1 < @quiet_level)),
        do: min(meter.quiet_ms + dt_ms, @silence_ms),
        else: 0

    targets = if quiet_ms >= @silence_ms, do: zeros(count), else: targets
    fall = @fall_per_s * dt_ms / 1000

    {levels, holds} =
      [levels, meter.holds, targets]
      |> Enum.zip_with(fn [level, hold, target] -> bar(level, hold, target, fall, dt_ms) end)
      |> Enum.unzip()

    %{levels: levels, holds: holds, quiet_ms: quiet_ms}
  end

  @doc "Whether the meter has settled: silent input and every bar at zero."
  @spec settled?(meter()) :: boolean()
  def settled?(meter),
    do: meter.quiet_ms >= @silence_ms and Enum.all?(meter.levels, &(&1 == 0.0))

  defp bar(level, _hold, target, _fall, _dt) when target >= level and target > 0.0,
    do: {target, @hold_ms}

  defp bar(level, hold, _target, _fall, dt) when hold > 0, do: {level, max(hold - dt, 0)}

  defp bar(level, _hold, target, fall, _dt) do
    next = max(target, level - fall)
    {if(next < 0.01, do: 0.0, else: next), 0}
  end

  defp fit(nil, count), do: zeros(count)

  defp fit(targets, count) do
    fitted = targets |> Enum.take(count) |> Enum.map(&clamp/1)
    fitted ++ zeros(count - length(fitted))
  end

  defp clamp(v) when is_number(v), do: v |> max(0.0) |> min(1.0) |> Kernel.*(1.0)
  defp clamp(_v), do: 0.0

  defp zeros(count), do: List.duplicate(0.0, count)

  defp byte(v) when is_integer(v), do: v |> max(0) |> min(255)
  defp byte(v) when is_float(v), do: v |> max(0.0) |> min(255.0)
  defp byte(_v), do: 0
end
