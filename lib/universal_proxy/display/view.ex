defmodule UniversalProxy.Display.View do
  @moduledoc """
  Draws a `UniversalProxy.Display.Model` as a `UniversalProxy.Display.Spec`
  (plain data), one layout per `UniversalProxy.Display.Model.screen/1`:

    * `{:now_playing, overlay?}` — artwork, title/artist/album, the
      transport controls and a visualizer strip.
    * `{:visualizer, overlay?}` — a full-screen visualizer under a one-line
      title.
    * `:party_qr` / `:party_off` — the party join card (a placeholder until
      the QR code exists) or a "Party Mode is off" card.
    * `:blank` — a black frame.

  With `overlay?` the party QR sits in a corner over the view.

  Visualizer bars are the `{:bars, _, _}` node keyed `"viz"`, drawn at
  zero: the viewport fills in live heights (`Spec.put_bars/3`). They use
  `bar_mode: :offset` inside a fixed-size row, so a height change is a
  paint-only update with no relayout.

  The focus ring on the transport controls shows only while a CEC TV is
  known to be there, since only a CEC remote can move it.
  """

  alias UniversalProxy.Display.{Model, Spec}

  @background {12, 14, 22}
  @foreground {240, 240, 245}
  @muted {150, 155, 170}
  @accent {80, 170, 255}
  @focus_ring {255, 255, 255, 0.18}

  @default_size {1280, 720}
  @default_bars 32

  @controls [prev: "Previous", play_pause: nil, next: "Next"]

  @doc """
  The spec for `model`. Options: `:size` (`{width, height}` the layout is
  scaled to, default `{1280, 720}`) and `:bars` (visualizer bar count,
  default 32).
  """
  @spec render(Model.t(), keyword()) :: Spec.t()
  def render(%Model{} = model, opts \\ []) do
    ctx = context(model, opts)

    case Model.screen(model) do
      :blank -> Spec.blank()
      :party_qr -> party_card(model, ctx)
      :party_off -> message_card("Party Mode is off", "Turn it on in Music Assistant", ctx)
      {:now_playing, overlay?} -> model |> now_playing(ctx) |> with_overlay(overlay?, model, ctx)
      {:visualizer, overlay?} -> model |> visualizer(ctx) |> with_overlay(overlay?, model, ctx)
    end
  end

  # ── Layouts ──────────────────────────────────────────────────────────

  defp now_playing(model, ctx) do
    art_size = round(ctx.height * 0.45)
    meta = model.metadata || %{}

    text_block =
      {:column, [key: "meta", width: :fill, spacing: px(ctx, 14), align_y: :center],
       [
         text("title", Map.get(meta, :title) || "Nothing playing", px(ctx, 52), ctx.fg,
           font_weight: 700
         ),
         text("artist", Map.get(meta, :artist) || "", px(ctx, 34), ctx.fg),
         text("album", Map.get(meta, :album) || "", px(ctx, 28), @muted),
         text("status", status_line(model), px(ctx, 24), @muted),
         transport(model, ctx)
       ]}

    {:column, root_attrs(ctx),
     [
       {:row, [key: "top", width: :fill, height: :fill, spacing: ctx.margin],
        [artwork(model, art_size, ctx), text_block]},
       viz_bars(ctx, round(ctx.height * 0.16))
     ]}
  end

  defp visualizer(model, ctx) do
    meta = model.metadata || %{}

    title =
      [Map.get(meta, :title), Map.get(meta, :artist)]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" — ")

    {:column, root_attrs(ctx),
     [
       text("title", title, px(ctx, 30), @muted),
       {:column, [key: "viz-area", width: :fill, height: :fill, align_y: :bottom],
        [viz_bars(ctx, round(ctx.height * 0.7))]}
     ]}
  end

  defp party_card(model, ctx) do
    party = if is_map(model.party), do: model.party, else: %{}
    qr_size = round(ctx.height * 0.5)

    {:column, root_attrs(ctx) ++ [align_x: :center],
     [
       {:column, [key: "party", align_x: :center, align_y: :center, spacing: ctx.margin],
        [
          text("party-title", Map.get(party, :name) || "Party Mode", px(ctx, 48), ctx.fg,
            font_weight: 700
          ),
          qr(party, qr_size),
          text(
            "party-caption",
            Map.get(party, :caption) || Map.get(party, :url, ""),
            px(ctx, 26),
            @muted
          )
        ]}
     ]}
  end

  defp message_card(title, detail, ctx) do
    {:column, root_attrs(ctx),
     [
       {:column, [key: "message", align_x: :center, align_y: :center, spacing: px(ctx, 16)],
        [
          text("message-title", title, px(ctx, 44), ctx.fg, font_weight: 700),
          text("message-detail", detail, px(ctx, 26), @muted)
        ]}
     ]}
  end

  defp with_overlay(content, false, _model, _ctx), do: content

  defp with_overlay(content, true, model, ctx) do
    size = round(ctx.height * 0.22)

    corner =
      {:column, [key: "qr-overlay", width: :fill, height: :fill, padding: ctx.margin],
       [
         {:column,
          [
            key: "qr-corner",
            align_x: :right,
            align_y: :top,
            spacing: px(ctx, 8),
            padding: px(ctx, 10),
            background: {0, 0, 0, 0.6},
            rounded: px(ctx, 10)
          ], [qr(model.party, size), text("qr-hint", "Join the party", px(ctx, 20), ctx.fg)]}
       ]}

    {:stack, [key: "overlay-stack", width: :fill, height: :fill], [content, corner]}
  end

  # ── Pieces ───────────────────────────────────────────────────────────

  defp artwork(model, size, ctx) do
    case model.artwork do
      %{path: path} when is_binary(path) ->
        {:image,
         [
           key: "art",
           width: {:px, size},
           height: {:px, size},
           image_fit: :cover,
           rounded: px(ctx, 12)
         ], path}

      _none ->
        {:column,
         [
           key: "art",
           width: {:px, size},
           height: {:px, size},
           background: {:gradient, [{60, 70, 110}, {25, 30, 50}], 45},
           rounded: px(ctx, 12)
         ], []}
    end
  end

  defp transport(model, ctx) do
    show_focus? = model.tv_presence == :present

    controls =
      for {id, label} <- @controls do
        focused? = show_focus? and model.focus == id
        label = label || if(model.playback == :playing, do: "Pause", else: "Play")

        attrs =
          [key: "ctl-#{id}", padding: px(ctx, 10), rounded: px(ctx, 8)] ++
            if(focused?, do: [background: @focus_ring], else: [])

        {:column, attrs, [text("ctl-#{id}-label", label, px(ctx, 26), ctx.fg)]}
      end

    {:row, [key: "transport", spacing: px(ctx, 12)], controls}
  end

  defp viz_bars(ctx, max_height) do
    area = ctx.width - 2 * ctx.margin
    spacing = max(px(ctx, 4), 1)
    bar_width = max(div(area - spacing * (ctx.bars - 1), ctx.bars), 1)

    Spec.bars(Spec.zero_bars(ctx.bars),
      key: "viz",
      width: {:px, area},
      max_height: max_height,
      bar_width: bar_width,
      spacing: spacing,
      color: ctx.accent,
      bar_mode: :offset
    )
  end

  defp qr(%{qr_path: path}, size) when is_binary(path),
    do: {:image, [key: "qr", width: {:px, size}, height: {:px, size}, image_fit: :contain], path}

  defp qr(_party, size),
    do:
      {:column, [key: "qr", width: {:px, size}, height: {:px, size}, background: @foreground], []}

  defp status_line(%Model{playback: :playing} = model), do: group_name(model)

  defp status_line(%Model{playback: :paused} = model),
    do: Enum.join(Enum.reject(["Paused", group_name(model)], &(&1 == "")), " · ")

  defp status_line(_model), do: ""

  defp group_name(%Model{group: %{group_name: name}}) when is_binary(name), do: name
  defp group_name(_model), do: ""

  defp text(key, content, size, color, extra \\ []) do
    {:text, [key: key, font_size: size, font_color: color] ++ extra, content}
  end

  defp root_attrs(ctx) do
    [
      key: "root",
      width: :fill,
      height: :fill,
      padding: ctx.margin,
      spacing: ctx.margin,
      background: ctx.bg
    ]
  end

  # ── Context ──────────────────────────────────────────────────────────

  defp context(model, opts) do
    {width, height} = Keyword.get(opts, :size) || @default_size

    %{
      width: width,
      height: height,
      unit: height / 720,
      margin: round(height * 0.05),
      bars: Keyword.get(opts, :bars) || @default_bars,
      bg: palette(model.color, :background_dark, @background),
      fg: palette(model.color, :on_dark, @foreground),
      accent: palette(model.color, :primary, @accent)
    }
  end

  defp px(ctx, n), do: round(n * ctx.unit)

  # `color@v1` palette entries arrive as `[r, g, b]`.
  defp palette(%{} = color, name, default) do
    case Map.get(color, name) do
      [r, g, b] when r in 0..255 and g in 0..255 and b in 0..255 -> {r, g, b}
      _other -> default
    end
  end

  defp palette(_color, _name, default), do: default
end
