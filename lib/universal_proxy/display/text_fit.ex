defmodule UniversalProxy.Display.TextFit do
  @moduledoc """
  Cuts a line of text to fit a width, ending it with an ellipsis.

  Emerge has no text ellipsis, and a text leaf never wraps, so the view
  shortens long titles itself (anything still too wide is clipped by its
  container). Widths are estimated from per-character advances for the
  embedded Inter font, in ems, slightly on the wide side so a fitted line
  rarely clips.
  """

  @ellipsis "…"

  @doc """
  `text` shortened (with a trailing `…`) so it is at most `max_width` px
  wide at `font_size` px, `bold?` adding ~6% to every advance. Text that
  fits is returned unchanged.
  """
  @spec fit(String.t(), number(), number(), boolean()) :: String.t()
  def fit(text, max_width, font_size, bold? \\ false) when is_binary(text) do
    scale = font_size * if(bold?, do: 1.06, else: 1.0)
    budget = max_width / scale

    graphemes = String.graphemes(text)

    if em_width(graphemes) <= budget do
      text
    else
      room = budget - em(@ellipsis)

      {kept, _width} =
        Enum.reduce_while(graphemes, {[], 0.0}, fn g, {acc, width} ->
          w = width + em(g)
          if w <= room, do: {:cont, {[g | acc], w}}, else: {:halt, {acc, width}}
        end)

      (kept |> Enum.reverse() |> Enum.join() |> String.trim_trailing()) <> @ellipsis
    end
  end

  @doc "The estimated width of `text` in ems."
  @spec em_width(String.t() | [String.t()]) :: float()
  def em_width(text) when is_binary(text), do: text |> String.graphemes() |> em_width()
  def em_width(graphemes), do: Enum.reduce(graphemes, 0.0, &(em(&1) + &2))

  @narrow ~c"iljtfrI.,:;'|!()[] "
  @wide ~c"mwMW@%"

  defp em(<<c::utf8, _rest::binary>>) when c in @narrow, do: 0.34
  defp em(<<c::utf8, _rest::binary>>) when c in @wide, do: 0.9
  defp em(<<c::utf8, _rest::binary>>) when c in ?A..?Z, do: 0.7
  defp em(<<c::utf8, _rest::binary>>) when c in ?0..?9, do: 0.62
  defp em(<<c::utf8, _rest::binary>>) when c < 0x80, do: 0.58
  # CJK, Hangul, kana and fullwidth forms (drawn as tofu by Inter, still a full em).
  defp em(<<c::utf8, _rest::binary>>) when c in 0x1100..0x115F or c in 0x2E80..0xA4CF,
    do: 1.0

  defp em(<<c::utf8, _rest::binary>>) when c in 0xAC00..0xD7A3 or c in 0xF900..0xFAFF,
    do: 1.0

  defp em(<<c::utf8, _rest::binary>>) when c in 0xFF00..0xFF60 or c >= 0x1F000, do: 1.0
  defp em(_grapheme), do: 0.62
end
