defmodule UniversalProxy.TuyaMesh.WallClockTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.TuyaMesh.WallClock

  @day_ms 86_400_000

  setup do
    key = {WallClock, :test, System.unique_integer([:positive])}
    on_exit(fn -> :persistent_term.erase(key) end)
    {:ok, key: key}
  end

  defp offset(key, raw), do: WallClock.offset_ms(key: key, raw: fn -> raw end)

  describe "stabilise/3" do
    test "adopts the first reading" do
      assert WallClock.stabilise(nil, 1_234, 1_000) == 1_234
    end

    test "keeps the stored offset within the tolerance, either side" do
      assert WallClock.stabilise(10_000, 10_999, 1_000) == 10_000
      assert WallClock.stabilise(10_000, 9_001, 1_000) == 10_000
      assert WallClock.stabilise(10_000, 11_000, 1_000) == 10_000
    end

    test "adopts a reading beyond the tolerance" do
      assert WallClock.stabilise(10_000, 11_001, 1_000) == 11_001
      assert WallClock.stabilise(10_000, 10_000 + 71 * @day_ms, 1_000) == 10_000 + 71 * @day_ms
    end
  end

  describe "offset_ms/1" do
    test "jitter around a half-second boundary never changes the result", %{key: key} do
      first = offset(key, 1_700_000_000_499)

      for raw <- [1_700_000_000_501, 1_700_000_000_499, 1_700_000_000_500, 1_700_000_000_502] do
        assert offset(key, raw) == first
      end

      # The truncated last_seen is identical for every reading, too.
      seen = WallClock.to_datetime(123_456, fn -> first end)

      for raw <- [1_700_000_000_501, 1_700_000_000_499] do
        assert WallClock.to_datetime(123_456, fn -> offset(key, raw) end) == seen
      end
    end

    test "a clock step is adopted and then held", %{key: key} do
      before = offset(key, 1_000_000)
      stepped = before + 71 * @day_ms

      assert offset(key, stepped) == stepped
      assert offset(key, stepped + 1) == stepped
      assert offset(key, stepped - 1) == stepped
    end

    test "the real clock reads a plausible offset" do
      expected = System.os_time(:millisecond) - System.monotonic_time(:millisecond)
      assert abs(WallClock.offset_ms() - expected) <= 1_000
    end
  end

  test "to_datetime applies the offset and truncates to the second" do
    assert ~U[1970-01-01 00:01:01Z] == WallClock.to_datetime(1_500, fn -> 60_000 end)
    assert WallClock.to_datetime(nil) == nil
  end
end
