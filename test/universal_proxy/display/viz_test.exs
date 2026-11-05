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

    test "holds at most max frames, dropping the oldest" do
      buffer = Enum.reduce(1..12, [], &Viz.buffer_push(&2, frame(&1, 1_000), &1))
      assert length(buffer) == 8
      assert Enum.map(buffer, fn {_due, f} -> hd(f.bins) end) == Enum.to_list(12..5//-1)
      assert length(Viz.buffer_push(buffer, frame(13), 0, 3)) == 3
    end
  end

  test "decay/2 shrinks heights and snaps tiny ones to zero" do
    assert Viz.decay([1.0, 0.012], 0.5) == [0.5, 0.0]
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
