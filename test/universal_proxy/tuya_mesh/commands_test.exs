defmodule UniversalProxy.TuyaMesh.CommandsTest do
  use ExUnit.Case, async: true

  alias Espex.Proto.LightCommandRequest, as: Req
  alias UniversalProxy.TuyaBeaconMesh.{Control, Dp}
  alias UniversalProxy.TuyaMesh.Commands

  @settings %{min_mireds: 154, max_mireds: 370, invert: false}
  @inverted %{@settings | invert: true}

  defp encoded_size(batch) do
    {:ok, dps} = Control.friendly_dps(batch)
    {:ok, bin} = Dp.encode(dps)
    byte_size(bin)
  end

  defp assert_fits(batches) do
    for batch <- batches, do: assert(encoded_size(batch) <= 16)
    batches
  end

  describe "on/off" do
    test "off is only DP1 = false, whatever else the command carries" do
      req = %Req{
        has_state: true,
        state: false,
        has_brightness: true,
        brightness: 0.5,
        has_color_mode: true,
        color_mode: :COLOR_MODE_RGB,
        has_rgb: true,
        red: 1.0
      }

      assert Commands.batches(req, @settings) == [[on: false]]
    end

    test "on alone is DP1 = true" do
      assert Commands.batches(%Req{has_state: true, state: true}, @settings) == [[on: true]]
    end

    test "a command with nothing mappable is no batch" do
      assert Commands.batches(%Req{}, @settings) == []
    end
  end

  describe "brightness" do
    test "0..1 maps to DP3 10..1000, never below 10" do
      for {b, dp} <- [{1.0, 1000}, {0.5, 500}, {0.0, 10}, {0.004, 10}, {1.5, 1000}] do
        assert Commands.batches(%Req{has_brightness: true, brightness: b}, @settings) ==
                 [[brightness: dp]]
      end
    end

    test "on + brightness is one frame" do
      req = %Req{has_state: true, state: true, has_brightness: true, brightness: 0.25}
      assert Commands.batches(req, @settings) == [[on: true, brightness: 250]]
    end

    test "a brightness alone follows the current colour mode into the colour's v" do
      current = %{2 => 1, 11 => <<120::16, 80, 100>>}
      req = %Req{has_brightness: true, brightness: 0.4}
      assert Commands.batches(req, @settings, current) == [[colour: {120, 80, 40}]]
    end

    test "a brightness alone in white mode, or with no known colour, is DP3" do
      req = %Req{has_brightness: true, brightness: 0.4}
      assert Commands.batches(req, @settings, %{2 => 0}) == [[brightness: 400]]
      assert Commands.batches(req, @settings, %{2 => 1}) == [[brightness: 400]]
    end
  end

  describe "colour temperature" do
    test "the mode is white, the mireds map warm → 0 and cool → 1000" do
      for {m, temp} <- [{370.0, 0}, {154.0, 1000}, {262.0, 500}, {500.0, 0}, {100.0, 1000}] do
        req = %Req{
          has_color_mode: true,
          color_mode: :COLOR_MODE_COLOR_TEMPERATURE,
          has_color_temperature: true,
          color_temperature: m
        }

        assert Commands.batches(req, @settings) == [[mode: :white, temp: temp]]
      end
    end

    test "invert flips the direction" do
      assert Commands.mireds_to_temp(370, @inverted) == 1000
      assert Commands.mireds_to_temp(154, @inverted) == 0

      assert Commands.mireds_to_temp(200, @inverted) ==
               1000 - Commands.mireds_to_temp(200, @settings)
    end

    test "a custom range is linear over it" do
      settings = %{min_mireds: 200, max_mireds: 300, invert: false}
      assert Commands.mireds_to_temp(250, settings) == 500
      assert Commands.mireds_to_temp(225, settings) == 750
    end

    test "temp_to_mireds inverts mireds_to_temp in both directions" do
      for settings <- [@settings, @inverted], m <- [154, 200, 262, 370] do
        temp = Commands.mireds_to_temp(m, settings)
        assert_in_delta Commands.temp_to_mireds(temp, settings), m, 0.5
      end
    end

    test "a colour temperature without color_mode still means white mode" do
      req = %Req{has_color_temperature: true, color_temperature: 370.0}
      assert Commands.batches(req, @settings) == [[mode: :white, temp: 0]]
    end

    test "the colour-temperature mode alone switches to white" do
      req = %Req{has_color_mode: true, color_mode: :COLOR_MODE_COLOR_TEMPERATURE}
      assert Commands.batches(req, @settings) == [[mode: :white]]
    end
  end

  describe "RGB" do
    test "RGB is colour mode with HSV, v from the colour brightness" do
      req = %Req{
        has_color_mode: true,
        color_mode: :COLOR_MODE_RGB,
        has_rgb: true,
        red: 1.0,
        green: 0.0,
        blue: 0.0,
        has_color_brightness: true,
        color_brightness: 0.5
      }

      assert Commands.batches(req, @settings) == [[mode: :colour, colour: {0, 100, 50}]]
    end

    test "v is brightness × colour brightness × the largest channel, at least 1" do
      req = %Req{
        has_rgb: true,
        red: 0.0,
        green: 0.5,
        blue: 0.0,
        has_brightness: true,
        brightness: 0.8,
        has_color_brightness: true,
        color_brightness: 0.5
      }

      assert [[mode: :colour, colour: {120, 100, 20}]] = Commands.batches(req, @settings)

      dark = %Req{has_rgb: true, red: 0.0, green: 0.0, blue: 0.0}
      assert [[mode: :colour, colour: {0, 0, 1}]] = Commands.batches(dark, @settings)
    end

    test "a brightness with RGB goes into v, never DP3" do
      req = %Req{
        has_state: true,
        state: true,
        has_rgb: true,
        red: 0.0,
        green: 0.0,
        blue: 1.0,
        has_brightness: true,
        brightness: 0.3
      }

      assert Commands.batches(req, @settings) == [
               [on: true, mode: :colour, colour: {240, 100, 30}]
             ]
    end

    test "the RGB mode with only a brightness keeps the current hue and saturation" do
      req = %Req{
        has_color_mode: true,
        color_mode: :COLOR_MODE_RGB,
        has_brightness: true,
        brightness: 0.6
      }

      current = %{2 => 1, 11 => <<200::16, 40, 90>>}
      assert Commands.batches(req, @settings, current) == [[mode: :colour, colour: {200, 40, 60}]]
    end

    test "RGB without a brightness keeps the current one" do
      req = %Req{has_rgb: true, red: 1.0, green: 1.0, blue: 0.0}

      assert [[mode: :colour, colour: {60, 100, 70}]] =
               Commands.batches(req, @settings, %{3 => 700})

      colour = %{2 => 1, 11 => <<10::16, 10, 25>>}
      assert [[mode: :colour, colour: {60, 100, 25}]] = Commands.batches(req, @settings, colour)
    end

    test "a colour brightness alone updates v in colour mode, keeping hue and saturation" do
      req = %Req{has_color_brightness: true, color_brightness: 0.5}
      current = %{2 => 1, 11 => <<120::16, 80, 100>>}
      assert Commands.batches(req, @settings, current) == [[colour: {120, 80, 50}]]

      # Meaningless outside colour mode, or without a known colour.
      assert Commands.batches(req, @settings, %{2 => 0, 11 => <<120::16, 80, 100>>}) == []
      assert Commands.batches(req, @settings, %{2 => 1}) == []
    end

    test "v comes from the kept components, so repeating a command is stable" do
      colour = %{2 => 1, 11 => <<120::16, 80, 100>>}
      half = %Req{has_color_brightness: true, color_brightness: 0.5}

      # Unknown components start as brightness v/100 and colour brightness 1.
      assert Commands.components(half, colour) == %{
               brightness: 1.0,
               color_brightness: 0.5,
               peak: 1.0
             }

      current =
        %{colour | 11 => <<120::16, 80, 50>>} |> Map.merge(Commands.components(half, colour))

      assert Commands.batches(half, @settings, current) == [[colour: {120, 80, 50}]]

      assert Commands.components(half, current) == %{
               brightness: 1.0,
               color_brightness: 0.5,
               peak: 1.0
             }
    end

    test "brightness then colour brightness compose" do
      current = %{2 => 1, 11 => <<0::16, 100, 100>>}
      dim = %Req{has_brightness: true, brightness: 0.5}
      assert Commands.batches(dim, @settings, current) == [[colour: {0, 100, 50}]]

      current = Map.merge(current, Commands.components(dim, current))
      half = %Req{has_color_brightness: true, color_brightness: 0.5}
      assert Commands.batches(half, @settings, current) == [[colour: {0, 100, 25}]]

      current = Map.merge(current, Commands.components(half, current))
      assert current[:brightness] == 0.5 and current[:color_brightness] == 0.5
      full = %Req{has_brightness: true, brightness: 1.0}
      assert Commands.batches(full, @settings, current) == [[colour: {0, 100, 50}]]
    end

    test "the RGB peak is kept, so a later brightness keeps the v ratio" do
      green = %Req{
        has_rgb: true,
        red: 0.0,
        green: 0.5,
        blue: 0.0,
        has_brightness: true,
        brightness: 0.5
      }

      assert Commands.batches(green, @settings) == [[mode: :colour, colour: {120, 100, 25}]]
      components = Commands.components(green)
      assert components == %{brightness: 0.5, color_brightness: 1.0, peak: 0.5}

      current =
        green |> Commands.entries(@settings) |> Commands.expected() |> Map.merge(components)

      same = %Req{has_brightness: true, brightness: 0.5}
      assert Commands.batches(same, @settings, current) == [[colour: {120, 100, 25}]]
      full = %Req{has_brightness: true, brightness: 1.0}
      assert Commands.batches(full, @settings, current) == [[colour: {120, 100, 50}]]

      r = Commands.state_response(Map.put(current, 1, true), @settings, 1, 1)
      assert %{brightness: 0.5, color_mode: :COLOR_MODE_RGB} = r
      assert {r.red, r.green, r.blue} == {0.0, 0.5, 0.0}
    end

    test "committed keeps only the components a sent DP shapes" do
      c = %{brightness: 0.3, color_brightness: 0.5, peak: 0.8}
      assert Commands.committed(c, %{1 => true, 2 => 0, 4 => 0}) == %{}
      assert Commands.committed(c, %{3 => 300}) == %{brightness: 0.3}
      assert Commands.committed(c, %{11 => <<0::16, 1, 2>>}) == c
    end

    test "components are untouched by off and by commands without a brightness" do
      assert Commands.components(%Req{has_state: true, state: false, has_brightness: true}) == %{}

      assert Commands.components(%Req{has_color_temperature: true, color_temperature: 300.0}) ==
               %{}
    end

    test "the RGB mode alone switches to colour" do
      req = %Req{has_color_mode: true, color_mode: :COLOR_MODE_RGB}
      assert Commands.batches(req, @settings) == [[mode: :colour]]
    end

    test "rgb_to_hs covers every sector, and hs_to_rgb inverts it" do
      for {rgb, hs} <- [
            {{1.0, 0.0, 0.0}, {0, 100}},
            {{1.0, 1.0, 0.0}, {60, 100}},
            {{0.0, 1.0, 0.0}, {120, 100}},
            {{0.0, 1.0, 1.0}, {180, 100}},
            {{0.0, 0.0, 1.0}, {240, 100}},
            {{1.0, 0.0, 1.0}, {300, 100}},
            {{1.0, 0.0, 0.004}, {0, 100}},
            {{1.0, 1.0, 1.0}, {0, 0}},
            {{1.0, 0.5, 0.5}, {0, 50}}
          ] do
        {r, g, b} = rgb
        assert Commands.rgb_to_hs(r, g, b) == hs

        {h, s} = hs
        {r2, g2, b2} = Commands.hs_to_rgb(h, s)
        assert_in_delta r2, r, 0.01
        assert_in_delta g2, g, 0.01
        assert_in_delta b2, b, 0.01
      end
    end
  end

  describe "splitting" do
    test "white with on and brightness is two frames: on, mode and temp first" do
      req = %Req{
        has_state: true,
        state: true,
        has_brightness: true,
        brightness: 1.0,
        has_color_mode: true,
        color_mode: :COLOR_MODE_COLOR_TEMPERATURE,
        has_color_temperature: true,
        color_temperature: 370.0
      }

      assert Commands.batches(req, @settings) |> assert_fits() == [
               [on: true, mode: :white, temp: 0],
               [brightness: 1000]
             ]
    end

    test "that same set is too long for one frame" do
      {:ok, dps} = Control.friendly_dps(on: true, mode: :white, temp: 0, brightness: 1000)
      assert Dp.encode(dps) == {:error, :too_long}
    end

    test "every combination fits in the fewest frames, on, mode and value first" do
      flags = [:state, :brightness, :temp, :rgb]

      for subset <- subsets(flags), subset != [] do
        req = request_for(subset)
        entries = Commands.entries(req, @settings)
        batches = req |> Commands.batches(@settings) |> assert_fits()

        total = Enum.sum(Enum.map(entries, &Commands.entry_size/1))
        assert length(batches) == div(total + 15, 16)
        assert List.flatten(batches) == entries

        keys = Keyword.keys(entries)
        assert keys == Enum.filter([:on, :mode, :temp, :colour, :brightness], &(&1 in keys))

        # Switched on, the first frame lights it in its mode and value.
        if :state in subset and (:temp in subset or :rgb in subset) do
          assert [{:on, true}, {:mode, _}, {value, _}] = hd(batches)
          assert value in [:temp, :colour]
        end
      end
    end

    test "split packs in order" do
      assert Commands.split(on: true, mode: :white, temp: 1, brightness: 10) == [
               [on: true, mode: :white, temp: 1],
               [brightness: 10]
             ]

      assert Commands.split(mode: :white, temp: 1, brightness: 10) == [
               [mode: :white, temp: 1, brightness: 10]
             ]

      assert Commands.split(brightness: 10, temp: 1) == [[brightness: 10, temp: 1]]
      assert Commands.split([]) == []
    end
  end

  describe "ignored fields" do
    test "transition and flash change nothing" do
      req = %Req{
        has_brightness: true,
        brightness: 0.5,
        has_transition_length: true,
        transition_length: 1000,
        has_flash_length: true,
        flash_length: 2000
      }

      assert Commands.batches(req, @settings) == [[brightness: 500]]
    end

    test "effects and white channels are ignored" do
      req = %Req{
        has_state: true,
        state: true,
        has_effect: true,
        effect: "rainbow",
        has_white: true,
        white: 1.0,
        has_cold_white: true,
        has_warm_white: true
      }

      assert Commands.batches(req, @settings) == [[on: true]]
    end
  end

  describe "expected and unconfirmed" do
    test "expected is the DP map Lights decodes reports into" do
      assert Commands.expected(on: true, brightness: 500, mode: :colour, colour: {1, 2, 3}) ==
               %{1 => true, 3 => 500, 2 => 1, 11 => <<1::16, 2, 3>>}
    end

    test "unconfirmed keeps the entries a DP map doesn't show" do
      entries = [mode: :white, temp: 0, brightness: 1000, on: true]

      assert Commands.unconfirmed(entries, %{2 => 0, 4 => 0, 3 => 999}) ==
               [brightness: 1000, on: true]

      assert Commands.unconfirmed(entries, %{1 => true, 2 => 0, 3 => 1000, 4 => 0}) == []
    end
  end

  describe "state_response/4" do
    test "unknown on/off is no state" do
      assert Commands.state_response(%{3 => 500}, @settings, 1, 2) == nil
    end

    test "white mode reports colour temperature and DP3 brightness" do
      r = Commands.state_response(%{1 => true, 2 => 0, 3 => 500, 4 => 0}, @settings, 7, 9)

      assert %{key: 7, device_id: 9, state: true, color_mode: :COLOR_MODE_COLOR_TEMPERATURE} = r
      assert r.brightness == 0.5
      assert r.color_temperature == 370.0
    end

    test "colour mode reports RGB at full value with v as the brightness" do
      r =
        Commands.state_response(
          %{1 => false, 2 => 1, 11 => <<240::16, 100, 30>>},
          @settings,
          7,
          9
        )

      assert %{state: false, color_mode: :COLOR_MODE_RGB, brightness: 0.3} = r
      assert {r.red, r.green, r.blue} == {0.0, 0.0, 1.0}
    end

    test "colour mode reports the kept components when known" do
      dps = %{1 => true, 2 => 1, 11 => <<0::16, 100, 25>>, brightness: 0.5, color_brightness: 0.5}
      r = Commands.state_response(dps, @settings, 7, 9)
      assert %{brightness: 0.5, color_brightness: 0.5, color_mode: :COLOR_MODE_RGB} = r
    end

    test "unknown values take neutral defaults" do
      r = Commands.state_response(%{1 => true}, @settings, 7, 9)
      assert r.color_mode == :COLOR_MODE_COLOR_TEMPERATURE
      assert r.brightness == 1.0
      assert r.color_temperature == 262.0
    end

    test "a command's DPs read back as what HA asked for" do
      req = %Req{
        has_state: true,
        state: true,
        has_rgb: true,
        red: 0.0,
        green: 1.0,
        blue: 0.0,
        has_brightness: true,
        brightness: 0.5
      }

      dps = req |> Commands.entries(@settings) |> Commands.expected()
      r = Commands.state_response(dps, @settings, 1, 1)
      assert %{state: true, color_mode: :COLOR_MODE_RGB, brightness: 0.5, green: 1.0} = r
    end
  end

  defp subsets([]), do: [[]]

  defp subsets([x | rest]) do
    tails = subsets(rest)
    tails ++ Enum.map(tails, &[x | &1])
  end

  defp request_for(subset) do
    Enum.reduce(subset, %Req{}, fn
      :state, r -> %{r | has_state: true, state: true}
      :brightness, r -> %{r | has_brightness: true, brightness: 0.5}
      :temp, r -> %{r | has_color_temperature: true, color_temperature: 300.0}
      :rgb, r -> %{r | has_rgb: true, red: 1.0, green: 0.2, blue: 0.0}
    end)
  end
end
