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

  The two clock reads are not atomic, so the raw offset jitters by a
  millisecond or so. Consumers publish a status only when it changes, and
  `last_seen` is truncated to the second, so that jitter must not reach
  them. The accepted offset is kept in `:persistent_term` (shared by every
  caller, written only on a real step or drift) and a new raw reading
  replaces it only when it differs by more than the tolerance.
  """

  @key {__MODULE__, :offset}
  @tolerance_ms 1_000

  @doc """
  Milliseconds to add to a monotonic time to get unix time: the accepted
  offset, unchanged while the raw reading stays within the tolerance of it.

  Options (for tests): `:key` (the `:persistent_term` key), `:raw` (a
  function returning the raw offset) and `:tolerance_ms`.
  """
  @spec offset_ms(keyword()) :: integer()
  def offset_ms(opts \\ []) do
    key = Keyword.get(opts, :key, @key)
    raw = Keyword.get(opts, :raw, &raw_offset/0).()
    stored = :persistent_term.get(key, nil)
    offset = stabilise(stored, raw, Keyword.get(opts, :tolerance_ms, @tolerance_ms))
    if offset != stored, do: :persistent_term.put(key, offset)
    offset
  end

  @doc "The stored offset while `raw` is within `tolerance` of it, else `raw`."
  @spec stabilise(integer() | nil, integer(), non_neg_integer()) :: integer()
  def stabilise(nil, raw, _tolerance), do: raw
  def stabilise(stored, raw, tolerance) when abs(raw - stored) <= tolerance, do: stored
  def stabilise(_stored, raw, _tolerance), do: raw

  defp raw_offset do
    monotonic = System.monotonic_time(:millisecond)
    System.os_time(:millisecond) - monotonic
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
