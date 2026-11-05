defmodule UniversalProxy.Display.VizTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Display.{Spec, Viz}

  test "tiers degrade full -> reduced -> pulse -> off" do
    assert Viz.tiers() == [:full, :reduced, :pulse, :off]
    assert Enum.map(Viz.tiers(), &Viz.degrade/1) == [:reduced, :pulse, :off, :off]
    assert Viz.tick_divisor(:full) == 1
    assert Viz.tick_divisor(:reduced) == 2
  end

  describe "resample/2" do
    test "takes the peak of the bins each bar covers" do
      assert Viz.resample([0, 255, 51, 102], 2) == [1.0, 0.4]
    end

    test "repeats bins when there are more bars than bins" do
      assert Viz.resample([0, 255], 4) == [0.0, 0.0, 1.0, 1.0]
    end

    test "clamps out-of-range values and copes with nothing" do
      assert Viz.resample([300, -5], 2) == [1.0, 0.0]
      assert Viz.resample([], 3) == [0.0, 0.0, 0.0]
      assert Viz.resample([1, 2], 0) == []
    end
  end

  describe "heights/3" do
    @frame %{bins: [0, 255, 51, 102], loudness: 51}

    test "full uses every bin" do
      assert Viz.heights(@frame, :full, 4) == [0.0, 1.0, 0.2, 0.4]
    end

    test "reduced averages neighbouring bins" do
      assert Viz.heights(@frame, :reduced, 4) == [0.5, 0.5, 0.3, 0.3]
    end

    test "pulse sets every bar to the loudness" do
      assert Viz.heights(@frame, :pulse, 3) == [0.2, 0.2, 0.2]
    end

    test "off, a clear or no frame are flat" do
      assert Viz.heights(@frame, :off, 2) == [0.0, 0.0]
      assert Viz.heights(%{event: "viz_clear"}, :full, 2) == [0.0, 0.0]
      assert Viz.heights(nil, :full, 2) == [0.0, 0.0]
    end
  end

  describe "frame buffer" do
    defp frame(n, lead \\ nil),
      do: if(lead, do: %{bins: [n], lead_ms: lead}, else: %{bins: [n]})

    test "a frame is painted on the first take at or after its due time, not before" do
      buffer = Viz.buffer_push([], frame(1, 100), 1_000)

      assert {nil, ^buffer} = Viz.buffer_take(buffer, 1_050)
      assert {nil, ^buffer} = Viz.buffer_take(buffer, 1_099)
      assert {%{bins: [1]}, []} = Viz.buffer_take(buffer, 1_100)
    end

    test "the newest due frame wins; older due ones are dropped, later ones wait" do
      buffer =
        []
        |> Viz.buffer_push(frame(1, 100), 0)
        |> Viz.buffer_push(frame(2, 100), 40)
        |> Viz.buffer_push(frame(3, 100), 80)

      assert {%{bins: [2]}, [{180, %{bins: [3]}}]} = Viz.buffer_take(buffer, 150)
    end

    test "frames without a lead (or a clear) are due at once" do
      buffer = Viz.buffer_push([], %{event: "viz_clear"}, 10)
      assert {%{event: "viz_clear"}, []} = Viz.buffer_take(buffer, 10)
      assert {%{bins: [5]}, []} = Viz.buffer_take(Viz.buffer_push([], frame(5, -3), 0), 0)
    end

    test "a clear drops frames still waiting, so nothing stale paints after it" do
      buffer =
        []
        |> Viz.buffer_push(frame(1, 100), 0)
        |> Viz.buffer_push(%{event: "viz_clear"}, 50)

      assert {%{event: "viz_clear"}, waiting} = Viz.buffer_take(buffer, 50)
      assert {nil, []} = Viz.buffer_take(waiting, 150)
      assert Viz.buffer_clear([{1, %{bins: [1]}}]) == []
    end

    test "a full buffer drops the new frame, keeping the next-due ones" do
      buffer = Enum.reduce(1..12, [], &Viz.buffer_push(&2, frame(&1, 1_000), &1))
      assert length(buffer) == 8
      assert Enum.map(buffer, fn {_due, f} -> hd(f.bins) end) == Enum.to_list(8..1//-1)
      assert {%{bins: [1]}, _waiting} = Viz.buffer_take(buffer, 1_001)
      assert length(Viz.buffer_push(buffer, frame(13), 0, 3)) == 8
    end

    test "sized by buffer_cap/2, a long lead keeps every frame until it is due" do
      # 500 ms ahead at 30 fps: 15 frames in flight; the old fixed cap of 8
      # dropped the next-due ones and the bars went flat.
      cap = Viz.buffer_cap(500, 30)
      assert cap >= 16

      {drawn, _buffer} =
        Enum.reduce(0..89, {[], []}, fn i, {drawn, buffer} ->
          now = i * 33
          buffer = Viz.buffer_push(buffer, frame(i, 500), now, cap)

          case Viz.buffer_take(buffer, now) do
            {nil, buffer} -> {drawn, buffer}
            {%{bins: [n]}, buffer} -> {[n | drawn], buffer}
          end
        end)

      drawn = Enum.reverse(drawn)
      assert length(drawn) >= 70
      assert drawn == Enum.to_list(hd(drawn)..List.last(drawn))
    end

    test "a bogus lead waits at most 5 s" do
      buffer = Viz.buffer_push([], frame(1, 3_600_000), 0)
      assert {%{bins: [1]}, []} = Viz.buffer_take(buffer, 5_000)
    end
  end

  describe "buffer_cap/2" do
    test "one lead time of frames plus headroom, at least 8, at most 3 s worth" do
      assert Viz.buffer_cap(100, 20) == 8
      assert Viz.buffer_cap(500, 30) == 19
      assert Viz.buffer_cap(1_000, 20) == 24
      assert Viz.buffer_cap(60_000, 20) == 60
      assert Viz.buffer_cap(0, 30) == 8
      assert Viz.buffer_cap(nil, nil) == 8
    end
  end

  describe "meter" do
    defp run(meter, steps), do: Enum.reduce(steps, meter, &Viz.step(&2, &1, 50))

    test "a peak is taken at once, held, then falls steadily, never below the input" do
      m = Viz.step(Viz.meter(2), [1.0, 0.5], 50)
      assert m.levels == [1.0, 0.5]

      # Held for 150 ms (3 ticks of 50 ms) …
      m = run(m, List.duplicate([0.2, 0.0], 3))
      assert m.levels == [1.0, 0.5]

      # … then falls 2.0 heights/s: 0.1 per 50 ms tick, floored at the input.
      m = Viz.step(m, [0.2, 0.0], 50)
      assert_in_delta hd(m.levels), 0.9, 1.0e-9
      m = run(m, List.duplicate([0.2, 0.0], 20))
      assert m.levels == [0.2, 0.0]
    end

    test "near-silent input settles every bar to zero after 1.5 s, then nothing changes" do
      m = Viz.step(Viz.meter(3), [0.8, 0.5, 0.3], 50)
      refute Viz.settled?(m)

      m = run(m, List.duplicate([0.02, 0.01, 0.0], 29))
      refute Viz.settled?(m)
      assert Enum.any?(m.levels, &(&1 > 0.0))

      m = Viz.step(m, [0.02, 0.01, 0.0], 50)
      m = run(m, List.duplicate([0.02, 0.01, 0.0], 12))
      assert m.levels == [0.0, 0.0, 0.0]
      assert Viz.settled?(m)
      assert Viz.step(m, [0.02, 0.0, 0.01], 50) == m
      assert Viz.step(m, nil, 50) == m
    end

    test "no frame (nil) is silence; sound wakes a settled meter" do
      m = Viz.meter(2)
      assert Viz.settled?(m)
      m = Viz.step(m, [0.6, 0.0], 50)
      assert m.levels == [0.6, 0.0]
      refute Viz.settled?(m)
    end

    test "fits the input to the bar count and clamps it" do
      assert Viz.step(Viz.meter(3), [2.0], 50).levels == [1.0, 0.0, 0.0]
      assert Viz.step(Viz.meter(1), [0.5, 0.9], 50).levels == [0.5]
    end
  end

  describe "Spec.put_bars/3" do
    test "fills the keyed bars, keeping their count" do
      spec =
        {:column, [key: "root"],
         [
           Spec.bars([0.0, 0.0, 0.0], key: "viz"),
           Spec.bars([0.0], key: "other"),
           {:stack, [], [{:text, [], "x"}, Spec.bars([0.0, 0.0], key: "viz")]}
         ]}

      expected =
        {:column, [key: "root"],
         [
           {:bars, [key: "viz"], [0.5, 1.0, 0.0]},
           {:bars, [key: "other"], [0.0]},
           {:stack, [], [{:text, [], "x"}, {:bars, [key: "viz"], [0.5, 1.0]}]}
         ]}

      assert Spec.put_bars(spec, "viz", [0.5, 2.0]) == expected
    end

    test "has_bars?/2" do
      assert Spec.has_bars?({:row, [], [Spec.bars([0.0], key: "viz")]}, "viz")
      refute Spec.has_bars?(Spec.blank(), "viz")
    end
  end
end
