defmodule UniversalProxy.Display.Drift do
  @moduledoc """
  Burn-in care for the TV UI: static content (artwork, text, controls,
  the visualizer's baseline) is shifted a few pixels every few minutes, so
  no edge sits on the same panel pixels for hours.

  The offset is a pure function of a monotonic clock: the clock is cut
  into `period_ms` epochs, and each epoch takes the next position of a
  fixed 3×3 walk around the origin, scaled by `amplitude` pixels. The same
  time always gives the same offset.
  """

  @default_period_ms 180_000

  # Each step moves one pixel unit; the walk returns to the origin.
  @walk [{0, 0}, {1, 0}, {1, 1}, {0, 1}, {-1, 1}, {-1, 0}, {-1, -1}, {0, -1}, {1, -1}]
  @steps length(@walk)

  @doc "The default epoch length (#{div(@default_period_ms, 60_000)} min)."
  @spec default_period_ms() :: pos_integer()
  def default_period_ms, do: @default_period_ms

  @doc """
  The `{dx, dy}` pixel offset at `now` (monotonic ms, may be negative);
  `{0, 0}` when `now` is `nil`.
  """
  @spec offset(integer() | nil, number(), pos_integer()) :: {integer(), integer()}
  def offset(now, amplitude, period_ms \\ @default_period_ms)
  def offset(nil, _amplitude, _period_ms), do: {0, 0}

  def offset(now, amplitude, period_ms) when is_integer(now) do
    epoch = Integer.floor_div(now, period_ms)
    {x, y} = Enum.at(@walk, Integer.mod(epoch, @steps))
    {round(x * amplitude), round(y * amplitude)}
  end

  @doc "Milliseconds from `now` until the offset next moves."
  @spec next_change_ms(integer(), pos_integer()) :: pos_integer()
  def next_change_ms(now, period_ms \\ @default_period_ms) when is_integer(now),
    do: period_ms - Integer.mod(now, period_ms)
end
