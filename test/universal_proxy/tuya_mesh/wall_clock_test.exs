defmodule UniversalProxy.TuyaMesh.WallClockTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.TuyaMesh.WallClock

  test "offset_ms tracks the OS clock, in whole seconds" do
    offset = WallClock.offset_ms()
    assert rem(offset, 1000) == 0

    expected = System.os_time(:millisecond) - System.monotonic_time(:millisecond)
    assert abs(offset - expected) <= 1000
  end

  test "to_datetime applies the offset and truncates to the second" do
    assert ~U[1970-01-01 00:01:01Z] == WallClock.to_datetime(1_500, fn -> 60_000 end)
    assert WallClock.to_datetime(nil) == nil
  end
end
