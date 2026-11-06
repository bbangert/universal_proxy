defmodule UniversalProxy.Display.Theme do
  @moduledoc """
  The TV UI's colours, taken from the Sendspin `color@v1` palette (the
  player's `color` event) when it has usable entries, else a default dark
  theme.

  The UI is always dark (a TV in a dim room, and less burn-in):

    * `:background` — the palette's `background_dark`, darkened until its
      relative luminance is at most #{0.08}.
    * `:foreground` — `on_dark`, unless it has less than 4.5:1 contrast
      with the background (WCAG AA for text); then near-white.
    * `:accent` — `primary`, else `accent`, the first with at least 3:1
      contrast (WCAG non-text); otherwise the better of the two lightened
      until it has, else the default accent.
    * `:muted` — secondary text, the foreground blended towards the
      background (kept at 4.5:1).
    * `:track` — the progress bar track (and the party caption's card),
      kept at 4.5:1 with the foreground and 3:1 with the accent;
      `:focus_fill` — a focused control's fill, kept at 3:1 with the
      foreground icon. Either falls back to the background.

  Every colour is an opaque `{r, g, b}`: translucency costs a read-back on
  the vc4 GPU and far more on CPU raster.
  """

  @type rgb :: {0..255, 0..255, 0..255}
  @type t :: %{
          background: rgb(),
          foreground: rgb(),
          muted: rgb(),
          accent: rgb(),
          track: rgb(),
          focus_fill: rgb()
        }

  @background {12, 14, 22}
  @foreground {240, 240, 245}
  @accent {80, 170, 255}
  @white {245, 245, 250}

  @max_background_luminance 0.08
  @text_contrast 4.5
  @accent_contrast 3.0

  @doc "The default theme (no palette)."
  @spec default() :: t()
  def default, do: from_palette(nil)

  @doc "The theme for a `color` event (a map of `[r, g, b]` entries), or the default."
  @spec from_palette(map() | nil) :: t()
  def from_palette(palette) do
    palette = if is_map(palette), do: palette, else: %{}

    background = palette |> rgb(:background_dark) |> darken_to(@background)

    foreground =
      readable(rgb(palette, :on_dark) || @foreground, background, @text_contrast, @white)

    accent =
      pick_accent([rgb(palette, :primary), rgb(palette, :accent)], background)

    %{
      background: background,
      foreground: foreground,
      muted: muted(foreground, background),
      accent: accent,
      track: track(foreground, accent, background),
      focus_fill: focus_fill(foreground, accent, background)
    }
  end

  @doc "WCAG contrast ratio between two colours (1.0..21.0)."
  @spec contrast(rgb(), rgb()) :: float()
  def contrast(a, b) do
    {hi, lo} = Enum.min_max_by([luminance(a), luminance(b)], &(-&1))
    (hi + 0.05) / (lo + 0.05)
  end

  @doc "WCAG relative luminance (0.0..1.0)."
  @spec luminance(rgb()) :: float()
  def luminance({r, g, b}), do: 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)

  @doc "`a` blended towards `b` by `t` (0.0 = `a`, 1.0 = `b`)."
  @spec blend(rgb(), rgb(), float()) :: rgb()
  def blend({r1, g1, b1}, {r2, g2, b2}, t) do
    mix = fn x, y -> round(x + (y - x) * t) end
    {mix.(r1, r2), mix.(g1, g2), mix.(b1, b2)}
  end

  # ── Pieces ───────────────────────────────────────────────────────────

  defp rgb(palette, name) do
    case Map.get(palette, name) do
      [r, g, b] when r in 0..255 and g in 0..255 and b in 0..255 -> {r, g, b}
      _other -> nil
    end
  end

  defp darken_to(nil, default), do: default
  defp darken_to(color, _default), do: darken(color, 12)

  defp darken(color, 0), do: color

  defp darken(color, steps) do
    if luminance(color) <= @max_background_luminance,
      do: color,
      else: darken(blend(color, {0, 0, 0}, 0.2), steps - 1)
  end

  defp readable(color, background, ratio, fallback),
    do: if(contrast(color, background) >= ratio, do: color, else: fallback)

  defp pick_accent(candidates, background) do
    candidates = Enum.reject(candidates, &is_nil/1)

    Enum.find(candidates, &(contrast(&1, background) >= @accent_contrast)) ||
      candidates
      |> Enum.map(&lighten(&1, background, 8))
      |> Enum.find(&(&1 && contrast(&1, background) >= @accent_contrast)) ||
      readable(@accent, background, @accent_contrast, @white)
  end

  # The progress track carries the accent fill and the party caption's
  # text; the lightest tint that keeps both readable, else the background.
  defp track(foreground, accent, background) do
    Enum.find(
      Enum.map([0.82, 0.88, 0.94], &blend(foreground, background, &1)),
      background,
      &(contrast(foreground, &1) >= @text_contrast and
          contrast(accent, &1) >= @accent_contrast)
    )
  end

  # A focused control's fill sits under its foreground-coloured icon.
  defp focus_fill(foreground, accent, background) do
    Enum.find(
      Enum.map([0.7, 0.8, 0.9], &blend(accent, background, &1)),
      background,
      &(contrast(foreground, &1) >= @accent_contrast)
    )
  end

  defp lighten(_color, _background, 0), do: nil

  defp lighten(color, background, steps) do
    if contrast(color, background) >= @accent_contrast,
      do: color,
      else: lighten(blend(color, {255, 255, 255}, 0.2), background, steps - 1)
  end

  # As dim as secondary text can be while staying readable.
  defp muted(foreground, background) do
    Enum.find([0.4, 0.3, 0.2, 0.1], foreground, fn t ->
      contrast(blend(foreground, background, t), background) >= @text_contrast
    end)
    |> case do
      t when is_float(t) -> blend(foreground, background, t)
      color -> color
    end
  end

  defp channel(c) do
    s = c / 255
    if s <= 0.03928, do: s / 12.92, else: :math.pow((s + 0.055) / 1.055, 2.4)
  end
end
