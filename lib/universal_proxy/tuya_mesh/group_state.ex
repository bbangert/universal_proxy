defmodule UniversalProxy.TuyaMesh.GroupState do
  @moduledoc """
  A group light's state from its members', following Home Assistant's
  light-group rules. Pure.

  Members are DP maps as `UniversalProxy.TuyaMesh.Commands` keeps them
  (DP id → value, plus the `:brightness`, `:color_brightness` and `:peak`
  components). Only members whose on/off (DP1) is known count:

    * **on** if any member is on; with no member known, unknown (`nil`);
    * over the members that are **on**: the mode is the majority (white on
      a tie), brightness the mean, colour temperature the mean of those
      that have one, hue the circular mean and saturation the mean of
      those in colour mode.

  The result is a DP map of the same shape, so
  `Commands.state_response/4` turns it into the group's state: DP1, DP2,
  DP3 and the `:brightness` component carry the mean brightness, DP4 the
  mean temperature, DP11 the mean colour at that brightness (colour
  brightness and peak 1).
  """

  alias UniversalProxy.TuyaMesh.Commands

  @doc "The group's DP map from its members', or `nil` when none is known."
  @spec aggregate([Commands.dps()]) :: Commands.dps() | nil
  def aggregate(members) do
    known = Enum.filter(members, &is_boolean(Map.get(&1, 1)))
    on = Enum.filter(known, &(Map.get(&1, 1) == true))

    cond do
      known == [] -> nil
      on == [] -> %{1 => false}
      true -> on_state(on)
    end
  end

  defp on_state(on) do
    colour = Enum.filter(on, &(mode(&1) == :colour))
    white = on -- colour
    brightness = mean(Enum.map(on, &brightness/1))

    %{
      1 => true,
      2 => if(length(colour) > length(white), do: 1, else: 0),
      3 => (brightness * 1000) |> round() |> max(10) |> min(1000),
      brightness: brightness,
      color_brightness: 1.0,
      peak: 1.0
    }
    |> put_temp(on, white)
    |> put_colour(colour, brightness)
  end

  # Colour mode needs a colour to show; anything else reads as white.
  defp mode(dps) do
    case {Map.get(dps, 2), colour(dps)} do
      {1, {_h, _s, _v}} -> :colour
      _white -> :white
    end
  end

  defp colour(dps) do
    case Map.get(dps, 11) do
      <<h::16, s, v>> when h in 0..359 and s in 0..100 and v in 0..100 -> {h, s, v}
      _none -> nil
    end
  end

  # A member's brightness as HA sees it: the kept component in colour mode
  # (else the colour's v), DP3 otherwise.
  defp brightness(dps) do
    case {mode(dps), Map.get(dps, :brightness), Map.get(dps, 3)} do
      {:colour, b, _dp3} when is_number(b) -> b
      {:colour, _b, _dp3} -> elem(colour(dps), 2) / 100
      {:white, _b, dp3} when is_integer(dp3) -> min(max(dp3, 10), 1000) / 1000
      _unknown -> 1.0
    end
  end

  # Members in white mode first; when none has a temperature, any on
  # member that has one.
  defp put_temp(acc, on, white) do
    temps =
      case temps(white) do
        [] -> temps(on)
        found -> found
      end

    if temps == [], do: acc, else: Map.put(acc, 4, round(mean(temps)))
  end

  defp temps(members), do: members |> Enum.map(&Map.get(&1, 4)) |> Enum.filter(&is_integer/1)

  defp put_colour(acc, [], _brightness), do: acc

  defp put_colour(acc, members, brightness) do
    colours = Enum.map(members, &colour/1)
    hue = circular_mean(Enum.map(colours, &elem(&1, 0)))
    sat = colours |> Enum.map(&elem(&1, 1)) |> mean() |> round()
    v = (brightness * 100) |> round() |> max(1) |> min(100)
    Map.put(acc, 11, <<hue::16, sat, v>>)
  end

  @doc "The circular mean of hues in degrees, 0..359."
  @spec circular_mean([number()]) :: 0..359
  def circular_mean(hues) do
    {x, y} =
      Enum.reduce(hues, {0.0, 0.0}, fn h, {x, y} ->
        rad = h * :math.pi() / 180
        {x + :math.cos(rad), y + :math.sin(rad)}
      end)

    deg = :math.atan2(y, x) * 180 / :math.pi()
    deg |> round() |> Integer.mod(360)
  end

  defp mean(values), do: Enum.sum(values) / length(values)
end
