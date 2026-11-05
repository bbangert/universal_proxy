defmodule UniversalProxy.Display.Progress do
  @moduledoc """
  Track position for the Now Playing progress bar, extrapolated from the
  player's last `metadata` event.

  The event's `progress` (`track_progress` and `track_duration` in ms,
  `playback_speed` in thousandths, `progress_age_ms`) was true
  `progress_age_ms` before `received_at` (monotonic ms). At `now` the
  position is

      track_progress + (progress_age_ms + now - received_at) * playback_speed / 1000

  clamped to `0..track_duration` (a duration of 0 is a live stream: no
  upper bound). While not playing, the position doesn't advance.
  """

  @type t :: %{
          elapsed_ms: non_neg_integer(),
          duration_ms: pos_integer() | nil,
          speed: non_neg_integer()
        }

  @doc """
  The position at `now`, or `nil` when the metadata has no progress.
  `playing?` false freezes it (speed 0).
  """
  @spec at(map() | nil, integer(), boolean()) :: t() | nil
  def at(metadata, now, playing? \\ true)

  def at(%{progress: %{track_progress: progress} = p} = metadata, now, playing?)
      when is_integer(progress) do
    speed = if playing?, do: non_neg(Map.get(p, :playback_speed, 1000)), else: 0
    duration = positive(Map.get(p, :track_duration))
    age = non_neg(Map.get(p, :progress_age_ms, 0))

    since =
      case Map.get(metadata, :received_at) do
        at when is_integer(at) and is_integer(now) -> max(now - at, 0)
        _unknown -> 0
      end

    elapsed = progress + div((age + since) * speed, 1000)
    elapsed = if duration, do: min(elapsed, duration), else: elapsed

    %{elapsed_ms: max(elapsed, 0), duration_ms: duration, speed: speed}
  end

  def at(_metadata, _now, _playing?), do: nil

  @doc """
  `metadata` with its progress re-based on the position at `now` (as
  `at/3` gives it with `playing?`): `track_progress` is that position,
  `progress_age_ms` 0 and `received_at` `now`. Metadata without progress
  is returned unchanged.
  """
  @spec anchor(map(), integer(), boolean()) :: map()
  def anchor(metadata, now, playing?) do
    case at(metadata, now, playing?) do
      %{elapsed_ms: elapsed} ->
        progress = %{metadata.progress | track_progress: elapsed} |> Map.put(:progress_age_ms, 0)
        metadata |> Map.put(:progress, progress) |> Map.put(:received_at, now)

      nil ->
        metadata
    end
  end

  @doc "The played fraction `0.0..1.0` (`0.0` without a duration)."
  @spec fraction(t()) :: float()
  def fraction(%{elapsed_ms: e, duration_ms: d}) when is_integer(d), do: min(e / d, 1.0)
  def fraction(_progress), do: 0.0

  @doc """
  Milliseconds until the shown position (whole seconds) changes, or `nil`
  while it doesn't advance (paused, or at the end).
  """
  @spec next_tick_ms(t() | nil) :: pos_integer() | nil
  def next_tick_ms(%{speed: speed} = p) when speed > 0 do
    if p.duration_ms && p.elapsed_ms >= p.duration_ms do
      nil
    else
      to_next_second = 1000 - rem(p.elapsed_ms, 1000)
      max(div(to_next_second * 1000 + speed - 1, speed), 1)
    end
  end

  def next_tick_ms(_progress), do: nil

  @doc ~S'Formats milliseconds as `m:ss`, or `h:mm:ss` from an hour.'
  @spec format(non_neg_integer()) :: String.t()
  def format(ms) do
    total = div(max(ms, 0), 1000)
    {h, m, s} = {div(total, 3600), div(rem(total, 3600), 60), rem(total, 60)}

    if h > 0,
      do: "#{h}:#{pad(m)}:#{pad(s)}",
      else: "#{m}:#{pad(s)}"
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp non_neg(n) when is_integer(n) and n > 0, do: n
  defp non_neg(_n), do: 0

  defp positive(n) when is_integer(n) and n > 0, do: n
  defp positive(_n), do: nil
end
