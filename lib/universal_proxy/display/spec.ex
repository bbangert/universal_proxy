defmodule UniversalProxy.Display.Spec do
  @moduledoc """
  A screen for the HDMI display, as plain data.

  A spec is a small tagged tree that a `UniversalProxy.Display.Renderer`
  turns into its own element tree. It holds no renderer structs, so views
  that build specs stay testable on host and visible to dialyzer even though
  the renderer library only exists on the display targets.

  Nodes:

    * `{:column, attrs, children}` / `{:row, attrs, children}` — lay children
      out vertically / horizontally.
    * `{:stack, attrs, [content | overlays]}` — `content` in the slot, each
      overlay painted over it, filling the same slot.
    * `{:text, attrs, string}`
    * `{:image, attrs, path}` — an absolute path to a PNG/JPEG file. The
      renderer only loads files under the directories it allows.
    * `{:bars, attrs, heights}` — a row of bars, bottom-aligned, each height a
      fraction `0.0..1.0` of the `:max_height` attr. `bar_mode: :height`
      (default) sizes each bar; `bar_mode: :offset` keeps every bar full
      height and slides it down inside the clipping row by a paint-only
      offset, so height changes need no relayout.
    * `:none` — renders nothing.

  Colours are `{r, g, b}` or `{r, g, b, alpha}` with bytes `0..255` and
  `alpha` in `0.0..1.0`. A `:background` or `:font_color` may also be
  `{:gradient, [color, ...], angle_degrees}` (0 points right, 90 down).
  """

  @type byte_value :: 0..255
  @type color ::
          {byte_value(), byte_value(), byte_value()}
          | {byte_value(), byte_value(), byte_value(), float()}
  @type paint :: color() | {:gradient, [color(), ...], number()}
  @type length :: :fill | :content | {:px, number()} | {:fill, number()}

  @type attr ::
          {:width, length()}
          | {:height, length()}
          | {:padding, number()}
          | {:spacing, number()}
          | {:background, paint()}
          | {:font_size, number()}
          | {:font_color, paint()}
          | {:font_weight, 100..900}
          | {:align_x, :left | :center | :right}
          | {:align_y, :top | :center | :bottom}
          | {:rounded, number()}
          | {:alpha, float()}
          | {:image_fit, :cover | :contain}
          | {:key, String.t()}
          | {:bar_width, number()}
          | {:max_height, number()}
          | {:color, paint()}
          | {:bar_mode, :height | :offset}
  @type attrs :: [attr()]

  @type t ::
          {:column | :row | :stack, attrs(), [t()]}
          | {:text, attrs(), String.t()}
          | {:image, attrs(), Path.t()}
          | {:bars, attrs(), [float()]}
          | :none

  @background {12, 14, 22}
  @foreground {240, 240, 245}
  @muted {150, 155, 170}
  @accent {80, 170, 255}

  @doc """
  A static "Now Playing" screen: artwork on the left, title/artist/album on
  the right and a visualizer strip underneath.

  Options (all optional): `:title`, `:artist`, `:album`, `:art` (image path),
  `:bars` (list of heights) or `:bar_count` (that many zero bars, default
  32), `:background`, `:accent`, `:size` (`{width, height}`, used to scale
  fonts and margins; default `{1280, 720}`).
  """
  @spec now_playing(keyword()) :: t()
  def now_playing(opts \\ []) do
    {width, height} = Keyword.get(opts, :size, {1280, 720})
    unit = height / 720
    margin = round(height * 0.05)
    art_size = round(height * 0.5)

    bars = Keyword.get_lazy(opts, :bars, fn -> zero_bars(Keyword.get(opts, :bar_count, 32)) end)
    bar_count = max(length(bars), 1)
    bar_area = width - 2 * margin
    bar_spacing = max(round(4 * unit), 1)
    bar_width = max((bar_area - bar_spacing * (bar_count - 1)) / bar_count, 1)

    art =
      case Keyword.get(opts, :art) do
        nil ->
          {:column,
           [
             key: "art",
             width: {:px, art_size},
             height: {:px, art_size},
             background: {:gradient, [{60, 70, 110}, {25, 30, 50}], 45},
             rounded: 12 * unit
           ], []}

        path ->
          {:image,
           [
             key: "art",
             width: {:px, art_size},
             height: {:px, art_size},
             image_fit: :cover,
             rounded: 12 * unit
           ], path}
      end

    text_block =
      {:column, [key: "meta", width: :fill, spacing: round(16 * unit), align_y: :center],
       [
         text("title", Keyword.get(opts, :title, "Nothing playing"), 54 * unit, @foreground,
           weight: 700
         ),
         text("artist", Keyword.get(opts, :artist, ""), 36 * unit, @foreground),
         text("album", Keyword.get(opts, :album, ""), 30 * unit, @muted)
       ]}

    {:column,
     [
       key: "root",
       width: :fill,
       height: :fill,
       padding: margin,
       spacing: margin,
       background: Keyword.get(opts, :background, @background)
     ],
     [
       {:row, [key: "top", width: :fill, height: :fill, spacing: margin], [art, text_block]},
       bars(bars,
         key: "viz",
         max_height: round(height * 0.18),
         bar_width: bar_width,
         spacing: bar_spacing,
         color: Keyword.get(opts, :accent, @accent)
       )
     ]}
  end

  @doc """
  A `{:bars, attrs, heights}` node with each height clamped to `0.0..1.0`.
  Non-numeric heights become `0.0`.
  """
  @spec bars([number()], attrs()) :: t()
  def bars(heights, attrs \\ []) when is_list(heights) do
    {:bars, attrs, Enum.map(heights, &clamp_unit/1)}
  end

  @doc "An all-black screen, drawn while the display is blanked."
  @spec blank() :: t()
  def blank, do: {:column, [width: :fill, height: :fill, background: {0, 0, 0}], []}

  @doc "`count` bars of height `0.0`."
  @spec zero_bars(non_neg_integer()) :: [float()]
  def zero_bars(count) when is_integer(count) and count >= 0, do: List.duplicate(0.0, count)

  @doc "Clamps a bar height to `0.0..1.0`."
  @spec clamp_unit(term()) :: float()
  def clamp_unit(value) when is_number(value), do: value |> max(0.0) |> min(1.0) |> Kernel.*(1.0)
  def clamp_unit(_value), do: 0.0

  defp text(key, content, size, color, extra \\ []) do
    weight = Keyword.get(extra, :weight)
    attrs = [key: key, font_size: size, font_color: color]
    attrs = if weight, do: attrs ++ [font_weight: weight], else: attrs
    {:text, attrs, content}
  end
end
