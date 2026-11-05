defmodule UniversalProxy.Display.Viz do
  @moduledoc """
  Turns Sendspin visualizer frames into bar heights for the viewport, and
  the tiers it degrades through under load.

  A frame is the player's `viz` event (`%{bins: [0..255], loudness:
  0..255}`), a `viz_clear` (`%{event: "viz_clear"}`) or `nil` (none yet).
  Heights are fractions `0.0..1.0`, one per bar.

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

  @buffer_max 8

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
  Adds a frame that arrived at `now` (monotonic ms). Frames come ahead of
  their display time by `lead_ms` (0 when absent), so each is due at
  `now + lead_ms`. Keeps at most `max` frames, dropping the oldest.
  """
  @spec buffer_push(buffer(), map(), integer(), pos_integer()) :: buffer()
  def buffer_push(buffer, frame, now, max \\ @buffer_max) do
    lead =
      case Map.get(frame, :lead_ms) do
        ms when is_integer(ms) and ms > 0 -> ms
        _other -> 0
      end

    Enum.take([{now + lead, frame} | buffer], max)
  end

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

  @doc "Heights decayed towards zero by `factor` (silence between frames)."
  @spec decay([float()], float()) :: [float()]
  def decay(heights, factor) do
    Enum.map(heights, fn h ->
      d = h * factor
      if d < 0.01, do: 0.0, else: d
    end)
  end

  defp zeros(count), do: List.duplicate(0.0, count)

  defp byte(v) when is_integer(v), do: v |> max(0) |> min(255)
  defp byte(v) when is_float(v), do: v |> max(0.0) |> min(255.0)
  defp byte(_v), do: 0
end
