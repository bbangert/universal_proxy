defmodule UniversalProxy.Display.ProgressTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Display.Progress

  defp meta(progress, received_at \\ 1_000) do
    %{
      received_at: received_at,
      progress:
        Map.merge(
          %{
            track_progress: 10_000,
            track_duration: 100_000,
            playback_speed: 1000,
            progress_age_ms: 0
          },
          progress
        )
    }
  end

  describe "at/3" do
    test "extrapolates from the age and the time since arrival" do
      assert %{elapsed_ms: 15_250, duration_ms: 100_000} =
               Progress.at(meta(%{progress_age_ms: 250}), 6_000)
    end

    test "scales with playback_speed (thousandths)" do
      assert %{elapsed_ms: 20_000} = Progress.at(meta(%{playback_speed: 2000}), 6_000)
    end

    test "speed 0 (paused on the server) or not playing doesn't advance" do
      assert %{elapsed_ms: 10_000, speed: 0} = Progress.at(meta(%{playback_speed: 0}), 60_000)
      assert %{elapsed_ms: 10_000, speed: 0} = Progress.at(meta(%{}), 60_000, false)
    end

    test "clamps at the duration; 0 duration is a live stream with no bound" do
      assert %{elapsed_ms: 100_000} = Progress.at(meta(%{}), 1_000_000)

      assert %{elapsed_ms: 1_009_000, duration_ms: nil} =
               Progress.at(meta(%{track_duration: 0}), 1_000_000)
    end

    test "missing timing: no :now or received_at means no time since arrival" do
      assert %{elapsed_ms: 10_000} = Progress.at(meta(%{}), nil)
      assert %{elapsed_ms: 10_500} = Progress.at(meta(%{progress_age_ms: 500}, nil), 99_000)

      assert %{elapsed_ms: 10_000, speed: 1000} =
               Progress.at(%{progress: %{track_progress: 10_000}}, 5_000)
    end

    test "a clock that went backwards doesn't rewind" do
      assert %{elapsed_ms: 10_000} = Progress.at(meta(%{}, 5_000), 1_000)
    end

    test "no progress, no position" do
      assert Progress.at(nil, 0) == nil
      assert Progress.at(%{title: "x"}, 0) == nil
      assert Progress.at(%{progress: %{track_progress: nil}}, 0) == nil
    end
  end

  test "fraction/1" do
    assert Progress.fraction(%{elapsed_ms: 25, duration_ms: 100, speed: 1000}) == 0.25
    assert Progress.fraction(%{elapsed_ms: 25, duration_ms: nil, speed: 1000}) == 0.0
  end

  test "next_tick_ms/1 is the time to the next whole second, nil when frozen or done" do
    assert Progress.next_tick_ms(%{elapsed_ms: 10_300, duration_ms: 100_000, speed: 1000}) == 700
    assert Progress.next_tick_ms(%{elapsed_ms: 10_300, duration_ms: 100_000, speed: 2000}) == 350
    assert Progress.next_tick_ms(%{elapsed_ms: 10_000, duration_ms: nil, speed: 1000}) == 1000
    assert Progress.next_tick_ms(%{elapsed_ms: 10_300, duration_ms: 100_000, speed: 0}) == nil
    assert Progress.next_tick_ms(%{elapsed_ms: 100_000, duration_ms: 100_000, speed: 1000}) == nil
    assert Progress.next_tick_ms(nil) == nil
  end

  test "format/1" do
    assert Progress.format(0) == "0:00"
    assert Progress.format(65_999) == "1:05"
    assert Progress.format(3_725_000) == "1:02:05"
  end
end
