defmodule UniversalProxy.Display.DriftTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Display.Drift

  test "walks a 3x3 square one step per period, then repeats" do
    offsets = for epoch <- 0..9, do: Drift.offset(epoch * 1_000, 1, 1_000)

    assert offsets == [
             {0, 0},
             {1, 0},
             {1, 1},
             {0, 1},
             {-1, 1},
             {-1, 0},
             {-1, -1},
             {0, -1},
             {1, -1},
             {0, 0}
           ]
  end

  test "is constant within a period, scales with the amplitude, and needs a clock" do
    assert Drift.offset(1_000, 5, 1_000) == Drift.offset(1_999, 5, 1_000)
    assert Drift.offset(2_000, 5, 1_000) == {5, 5}
    assert Drift.offset(2_000, 4.4, 1_000) == {4, 4}
    assert Drift.offset(nil, 5) == {0, 0}
  end

  test "copes with a negative monotonic clock" do
    assert Drift.offset(-1, 1, 1_000) == {1, -1}
    assert Drift.next_change_ms(-1, 1_000) == 1
    assert Drift.next_change_ms(-1_000, 1_000) == 1_000
  end

  test "next_change_ms/2 is the time to the next period boundary" do
    assert Drift.next_change_ms(0) == Drift.default_period_ms()
    assert Drift.next_change_ms(250, 1_000) == 750
    assert Drift.next_change_ms(999, 1_000) == 1
  end
end
