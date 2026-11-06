defmodule UniversalProxy.Display.ThemeTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Display.Theme

  defp readable?(theme) do
    Theme.contrast(theme.foreground, theme.background) >= 4.5 and
      Theme.contrast(theme.muted, theme.background) >= 4.5 and
      Theme.contrast(theme.accent, theme.background) >= 3.0 and
      Theme.contrast(theme.foreground, theme.track) >= 4.5 and
      Theme.contrast(theme.accent, theme.track) >= 3.0 and
      Theme.contrast(theme.foreground, theme.focus_fill) >= 3.0
  end

  test "the default theme is dark and readable" do
    theme = Theme.default()
    assert Theme.from_palette(nil) == theme
    assert Theme.from_palette(%{}) == theme
    assert Theme.luminance(theme.background) <= 0.08
    assert readable?(theme)
  end

  test "uses a readable palette as given" do
    theme =
      Theme.from_palette(%{
        background_dark: [20, 20, 30],
        on_dark: [235, 235, 235],
        primary: [200, 60, 60],
        accent: [60, 200, 60]
      })

    assert theme.background == {20, 20, 30}
    assert theme.foreground == {235, 235, 235}
    assert theme.accent == {200, 60, 60}
  end

  test "falls back to the accent entry when primary is too dark" do
    theme =
      Theme.from_palette(%{
        background_dark: [20, 20, 30],
        primary: [30, 20, 40],
        accent: [90, 220, 140]
      })

    assert theme.accent == {90, 220, 140}
  end

  test "fixes palettes that would be unreadable" do
    for palette <- [
          %{background_dark: [240, 240, 240], on_dark: [250, 250, 250], primary: [255, 255, 255]},
          %{background_dark: [10, 10, 10], on_dark: [20, 20, 20], primary: [15, 10, 10]},
          %{background_dark: [128, 30, 30], on_dark: [140, 40, 40], primary: [130, 30, 30]},
          %{background_dark: [0, 0, 0], primary: [0, 0, 255]},
          # Derived tints that used to fail: caption on the track 3.33:1,
          # focus icon on its fill 2.07:1.
          %{background_dark: [76, 76, 76], on_dark: [190, 190, 190], accent: [255, 255, 255]}
        ] do
      theme = Theme.from_palette(palette)
      assert Theme.luminance(theme.background) <= 0.08, inspect(palette)
      assert readable?(theme), inspect({palette, theme})
    end
  end

  test "ignores malformed entries" do
    theme = Theme.from_palette(%{background_dark: [300, 0, 0], on_dark: "white", primary: [1, 2]})
    assert theme == Theme.default()
  end

  test "contrast/2 is the WCAG ratio" do
    assert_in_delta Theme.contrast({0, 0, 0}, {255, 255, 255}), 21.0, 0.01
    assert_in_delta Theme.contrast({255, 255, 255}, {0, 0, 0}), 21.0, 0.01
    assert Theme.contrast({100, 100, 100}, {100, 100, 100}) == 1.0
  end
end
