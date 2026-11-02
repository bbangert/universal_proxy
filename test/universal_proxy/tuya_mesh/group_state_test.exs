defmodule UniversalProxy.TuyaMesh.GroupStateTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.TuyaMesh.GroupState

  defp white(on, bri, temp), do: %{1 => on, 2 => 0, 3 => bri, 4 => temp}
  defp colour(on, h, s, v), do: %{1 => on, 2 => 1, 11 => <<h::16, s, v>>}

  test "no member known is unknown" do
    assert GroupState.aggregate([]) == nil
    assert GroupState.aggregate([%{3 => 500}, %{}]) == nil
  end

  test "all known members off is off" do
    assert GroupState.aggregate([white(false, 500, 0), %{3 => 1}]) == %{1 => false}
  end

  test "on when any member is on; brightness is the mean over on members" do
    agg =
      GroupState.aggregate([white(true, 1000, 0), white(true, 500, 1000), white(false, 10, 0)])

    assert %{1 => true, 2 => 0, 3 => 750, 4 => 500, brightness: 0.75} = agg
    refute Map.has_key?(agg, 11)
  end

  test "the mode is the majority among on members, white on a tie" do
    reds = [colour(true, 0, 100, 100), colour(true, 0, 100, 100), white(true, 1000, 0)]
    assert %{2 => 1} = GroupState.aggregate(reds)

    tie = [colour(true, 0, 100, 100), white(true, 1000, 0)]
    assert %{2 => 0} = GroupState.aggregate(tie)

    # Off members don't vote.
    assert %{2 => 0} =
             GroupState.aggregate([
               white(true, 1000, 0) | List.duplicate(colour(false, 0, 1, 1), 3)
             ])
  end

  test "hue is the circular mean, saturation the mean, v the mean brightness" do
    agg = GroupState.aggregate([colour(true, 350, 100, 100), colour(true, 10, 50, 50)])
    assert <<0::16, 75, 75>> = agg[11]
    assert agg.brightness == 0.75
  end

  test "a colour member's kept brightness counts over its v" do
    member = Map.put(colour(true, 120, 100, 25), :brightness, 0.5)
    assert %{brightness: 0.5} = GroupState.aggregate([member])
  end

  test "colour temperature comes from white members, else any on member that has one" do
    assert %{4 => 200} =
             GroupState.aggregate([
               white(true, 1000, 200),
               Map.put(colour(true, 0, 1, 1), 4, 900)
             ])

    assert %{4 => 900} = GroupState.aggregate([Map.put(colour(true, 0, 1, 1), 4, 900)])
  end

  test "circular_mean wraps" do
    assert GroupState.circular_mean([359, 1]) == 0
    assert GroupState.circular_mean([90, 180]) == 135
    assert GroupState.circular_mean([270]) == 270
  end
end
