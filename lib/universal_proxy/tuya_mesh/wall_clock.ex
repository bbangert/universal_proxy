defmodule UniversalProxy.TuyaMesh.WallClock do
  @moduledoc """
  Converts monotonic timestamps to wall-clock time for display.

  The offset comes from the OS clock (`System.os_time/1` minus
  `System.monotonic_time/1`), not `System.time_offset/1`: with
  `+C multi_time_warp` ERTS notices an OS clock step (nerves_time setting
  the clock after boot) only some time later, and until then
  `System.time_offset/1` still holds the pre-step value while
  `DateTime.utc_now/0`, which the UI compares against, already shows the
  new date.

  The offset is rounded to whole seconds. The two clock reads are not
  atomic, and a millisecond of jitter would otherwise tip a
  second-truncated value over a boundary and make an unchanged status
  look changed.
  """

  @doc "Milliseconds to add to a monotonic time to get unix time."
  @spec offset_ms() :: integer()
  def offset_ms do
    monotonic = System.monotonic_time(:millisecond)
    os = System.os_time(:millisecond)
    round((os - monotonic) / 1000) * 1000
  end

  @doc """
  The wall-clock time (to the second) of monotonic `ms`, or nil for a
  non-integer. `offset_fun` supplies the offset (injectable for tests).
  """
  @spec to_datetime(term(), (-> integer())) :: DateTime.t() | nil
  def to_datetime(ms, offset_fun \\ &offset_ms/0)

  def to_datetime(ms, offset_fun) when is_integer(ms) do
    (ms + offset_fun.())
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.truncate(:second)
  end

  def to_datetime(_ms, _offset_fun), do: nil
end
