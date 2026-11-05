defmodule UniversalProxy.Display.View do
  @moduledoc """
  Draws a `UniversalProxy.Display.Model` as a `UniversalProxy.Display.Spec`
  (plain data), one layout per `UniversalProxy.Display.Model.screen/1`:

    * `{:now_playing, overlay?}` — artwork, title/artist/album, a progress
      bar with elapsed/total time, the transport controls and a visualizer
      strip.
    * `{:visualizer, overlay?}` — a full-screen visualizer under a one-line
      title.
    * `:party_qr` / `:party_off` — the party join card (a placeholder until
      the QR code exists) or a "Party Mode is off" card.
    * `:blank` — a black frame.

  With `overlay?` the party QR sits in a corner over the view.

  The layout is computed for the output size (the viewport's reported
  mode, `model.size`), inside 5% overscan margins. Colours come from the
  `color@v1` palette (`UniversalProxy.Display.Theme`). Text is cut to its
  width with an ellipsis (`UniversalProxy.Display.TextFit`).

  The progress position is extrapolated to the `:now` option
  (`UniversalProxy.Display.Progress`), so the owner redraws on its own
  clock; `next_refresh/2` says when the view next changes with time alone.

  Visualizer bars are the `{:bars, _, _}` node keyed `"viz"`, drawn at
  zero: the viewport fills in live heights (`Spec.put_bars/3`). They use
  `bar_mode: :offset` inside a fixed-size row, so a height change is a
  paint-only update with no relayout.

  The focus ring on the transport controls shows only while a CEC TV is
  known to be there, since only a CEC remote can move it.

  Burn-in care: every block on a screen is shifted by the same few pixels
  (`UniversalProxy.Display.Drift`, a pure function of `:now`) every few
  minutes, inside the overscan margins. Idle screens blank to black
  (`UniversalProxy.Display.Model`).
  """

  alias UniversalProxy.Display.{Drift, Model, Progress, Spec, TextFit, Theme}

  @default_size {1280, 720}
  @default_bars 32

  @controls [:prev, :play_pause, :next]

  @doc """
  The spec for `model`, laid out for the output size the viewport reported
  (`model.size`). Options:

    * `:size` — `{width, height}` to use until the viewport reports one
      (default `{1280, 720}`).
    * `:bars` — visualizer bar count (default 32).
    * `:now` — monotonic ms the progress position is extrapolated to and
      the burn-in drift is taken at (default: the metadata's arrival, and
      no drift).
    * `:drift_period_ms` — how often the drift moves (default 3 min).
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

  @doc """
  Milliseconds after `:now` (an option, as for `render/2`) at which the
  rendered screen changes with time alone, or `nil` when it doesn't (a
  black frame, or no `:now`): the next whole second of a playing track's
  progress, or the next burn-in drift step.
  """
  @spec next_refresh(Model.t(), keyword()) :: pos_integer() | nil
  def next_refresh(%Model{} = model, opts \\ []) do
    now = Keyword.get(opts, :now)

    case {Model.screen(model), now} do
      {:blank, _now} ->
        nil

      {_screen, nil} ->
        nil

      {screen, now} ->
        drift = Drift.next_change_ms(now, drift_period(opts))

        tick =
          if match?({:now_playing, _overlay}, screen),
            do: model |> progress(now) |> Progress.next_tick_ms()

        if tick, do: min(tick, drift), else: drift
    end
  end

  # ── Layouts ──────────────────────────────────────────────────────────

  defp now_playing(model, ctx) do
    meta = model.metadata || %{}
    strip_height = round(ctx.height * 0.16)
    top_height = ctx.content_h - strip_height - ctx.margin
    art_size = min(round(ctx.height * 0.5), top_height)
    meta_width = ctx.content_w - art_size - ctx.margin_x

    text_block =
      {:column, [key: "meta", width: :fill, spacing: px(ctx, 12), align_y: :center],
       [
         line(ctx, "title", Map.get(meta, :title) || "Nothing playing", meta_width, 52,
           color: ctx.theme.foreground,
           bold: true
         ),
         line(ctx, "artist", Map.get(meta, :artist) || "", meta_width, 34,
           color: ctx.theme.foreground
         ),
         line(ctx, "album", album_line(meta), meta_width, 28, color: ctx.theme.muted),
         line(ctx, "status", status_line(model), meta_width, 24, color: ctx.theme.muted),
         progress_block(model, meta_width, ctx),
         transport(model, ctx)
       ]}

    {:column, root_attrs(ctx),
     drift(
       [
         {:row, [key: "top", width: :fill, height: {:px, top_height}, spacing: ctx.margin_x],
          [artwork(model, art_size, ctx), text_block]},
         viz_bars(ctx, strip_height)
       ],
       ctx
     )}
  end

  defp visualizer(model, ctx) do
    meta = model.metadata || %{}

    title =
      [Map.get(meta, :title), Map.get(meta, :artist)]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" — ")

    {:column, root_attrs(ctx),
     drift(
       [
         line(ctx, "title", title, ctx.content_w, 30, color: ctx.theme.muted),
         {:column, [key: "viz-area", width: :fill, height: :fill, align_y: :bottom],
          [viz_bars(ctx, round(ctx.height * 0.7))]}
       ],
       ctx
     )}
  end

  defp party_card(model, ctx) do
    party = if is_map(model.party), do: model.party, else: %{}
    qr_size = round(ctx.height * 0.5)

    {:column, root_attrs(ctx) ++ [align_x: :center],
     drift(
       [
         {:column, [key: "party", align_x: :center, align_y: :center, spacing: ctx.margin],
          [
            line(ctx, "party-title", Map.get(party, :name) || "Party Mode", ctx.content_w, 48,
              color: ctx.theme.foreground,
              bold: true
            ),
            qr(party, qr_size, ctx),
            line(
              ctx,
              "party-caption",
              Map.get(party, :caption) || Map.get(party, :url, ""),
              ctx.content_w,
              26,
              color: ctx.theme.muted
            )
          ]}
       ],
       ctx
     )}
  end

  defp message_card(title, detail, ctx) do
    {:column, root_attrs(ctx),
     drift(
       [
         {:column, [key: "message", align_x: :center, align_y: :center, spacing: px(ctx, 16)],
          [
            line(ctx, "message-title", title, ctx.content_w, 44,
              color: ctx.theme.foreground,
              bold: true
            ),
            line(ctx, "message-detail", detail, ctx.content_w, 26, color: ctx.theme.muted)
          ]}
       ],
       ctx
     )}
  end

  defp with_overlay(content, false, _model, _ctx), do: content

  defp with_overlay(content, true, model, ctx) do
    size = round(ctx.height * 0.22)

    corner =
      {:column,
       [
         key: "qr-overlay",
         width: :fill,
         height: :fill,
         padding: {ctx.margin, ctx.margin_x, ctx.margin, ctx.margin_x}
       ],
       drift(
         [
           {:column,
            [
              key: "qr-corner",
              align_x: :right,
              align_y: :top,
              spacing: px(ctx, 8),
              padding: px(ctx, 10),
              background: ctx.theme.track,
              rounded: px(ctx, 10)
            ],
            [
              qr(model.party, size, ctx),
              text("qr-hint", "Join the party", px(ctx, 20), ctx.theme.foreground)
            ]}
         ],
         ctx
       )}

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
           background: {:gradient, [ctx.theme.track, ctx.theme.background], 45},
           rounded: px(ctx, 12)
         ], []}
    end
  end

  # A track bar with the played part filled, and elapsed / total under it.
  # Without a duration (a live stream) only the elapsed time shows.
  defp progress_block(model, width, ctx) do
    case progress(model, ctx.now) do
      nil ->
        :none

      p ->
        bar_height = max(px(ctx, 8), 2)
        filled = round(width * Progress.fraction(p))
        times = progress_times(p, ctx)

        {:column, [key: "progress", width: {:px, width}, spacing: px(ctx, 8)],
         [
           {:row,
            [
              key: "progress-track",
              width: {:px, width},
              height: {:px, bar_height},
              background: ctx.theme.track,
              rounded: div(bar_height, 2)
            ],
            [
              {:column,
               [
                 key: "progress-fill",
                 width: {:px, filled},
                 height: :fill,
                 background: ctx.theme.accent,
                 rounded: div(bar_height, 2)
               ], []}
            ]},
           {:row, [key: "progress-times", width: :fill], times}
         ]}
    end
  end

  defp progress_times(p, ctx) do
    elapsed = text("elapsed", Progress.format(p.elapsed_ms), px(ctx, 22), ctx.theme.muted)

    if p.duration_ms do
      total =
        text("duration", Progress.format(p.duration_ms), px(ctx, 22), ctx.theme.muted,
          align_x: :right
        )

      [elapsed, total]
    else
      [elapsed]
    end
  end

  defp progress(%Model{metadata: meta, playback: playback}, now),
    do: Progress.at(meta, now, playback == :playing)

  # [prev, play/pause, next]. Every control has a ring of the same width so
  # moving focus never moves anything; only the focused one's is coloured.
  defp transport(model, ctx) do
    show_focus? = model.tv_presence == :present
    ring = max(px(ctx, 3), 2)
    icon = px(ctx, 40)

    controls =
      for id <- @controls do
        {ring_color, fill} =
          if show_focus? and model.focus == id,
            do: {ctx.theme.accent, ctx.theme.focus_fill},
            else: {ctx.theme.background, ctx.theme.background}

        {:column,
         [
           key: "ctl-#{id}",
           padding: px(ctx, 12),
           rounded: px(ctx, 14),
           border: {ring, ring_color},
           background: fill
         ],
         [
           {:icon,
            [
              key: "ctl-#{id}-icon",
              width: {:px, icon},
              height: {:px, icon},
              color: ctx.theme.foreground
            ], control_icon(id, model)}
         ]}
      end

    {:row, [key: "transport", spacing: px(ctx, 16)], controls}
  end

  # The play/pause control shows what Select would do.
  defp control_icon(:prev, _model), do: :previous
  defp control_icon(:next, _model), do: :next
  defp control_icon(:play_pause, %Model{playback: :playing}), do: :pause
  defp control_icon(:play_pause, _model), do: :play

  defp viz_bars(ctx, max_height) do
    area = ctx.content_w
    spacing = max(px(ctx, 4), 1)
    bar_width = max(div(area - spacing * (ctx.bars - 1), ctx.bars), 1)

    Spec.bars(Spec.zero_bars(ctx.bars),
      key: "viz",
      width: {:px, area},
      max_height: max_height,
      bar_width: bar_width,
      spacing: spacing,
      color: ctx.theme.accent,
      bar_mode: :offset
    )
  end

  defp qr(%{qr_path: path}, size, _ctx) when is_binary(path),
    do: {:image, [key: "qr", width: {:px, size}, height: {:px, size}, image_fit: :contain], path}

  defp qr(_party, size, ctx),
    do:
      {:column,
       [key: "qr", width: {:px, size}, height: {:px, size}, background: ctx.theme.foreground], []}

  defp album_line(meta) do
    case {Map.get(meta, :album), Map.get(meta, :year)} do
      {album, year} when is_binary(album) and album != "" and is_integer(year) ->
        "#{album} (#{year})"

      {album, _year} when is_binary(album) ->
        album

      _none ->
        ""
    end
  end

  defp status_line(%Model{playback: :playing} = model), do: group_name(model)

  defp status_line(%Model{playback: :paused} = model),
    do: Enum.join(Enum.reject(["Paused", group_name(model)], &(&1 == "")), " · ")

  defp status_line(_model), do: ""

  defp group_name(%Model{group: %{group_name: name}}) when is_binary(name), do: name
  defp group_name(_model), do: ""

  # A one-line text cut to `width`, at a 720p-relative font `size`.
  defp line(ctx, key, content, width, size, opts) do
    font = px(ctx, size)
    bold? = Keyword.get(opts, :bold, false)
    extra = if bold?, do: [font_weight: 700], else: []
    text(key, TextFit.fit(content, width, font, bold?), font, Keyword.fetch!(opts, :color), extra)
  end

  defp text(key, content, size, color, extra \\ []) do
    {:text, [key: key, font_size: size, font_color: color] ++ extra, content}
  end

  defp root_attrs(ctx) do
    [
      key: "root",
      width: :fill,
      height: :fill,
      padding: {ctx.margin, ctx.margin_x, ctx.margin, ctx.margin_x},
      spacing: ctx.margin,
      background: ctx.theme.background
    ]
  end

  # Shifts each block by the current burn-in offset (a paint-only move).
  defp drift(nodes, %{drift: {0, 0}}), do: nodes

  defp drift(nodes, ctx) do
    Enum.map(nodes, fn
      {tag, attrs, content} -> {tag, attrs ++ [move: ctx.drift], content}
      other -> other
    end)
  end

  defp drift_period(opts), do: Keyword.get(opts, :drift_period_ms) || Drift.default_period_ms()

  # ── Context ──────────────────────────────────────────────────────────

  defp context(model, opts) do
    {width, height} = model.size || Keyword.get(opts, :size) || @default_size
    # Overscan-safe: 5% of each axis on every side.
    margin_x = round(width * 0.05)
    margin = round(height * 0.05)

    %{
      width: width,
      height: height,
      unit: height / 720,
      margin_x: margin_x,
      margin: margin,
      content_w: width - 2 * margin_x,
      content_h: height - 2 * margin,
      bars: Keyword.get(opts, :bars) || @default_bars,
      now: Keyword.get(opts, :now),
      theme: Theme.from_palette(model.color),
      drift: Drift.offset(Keyword.get(opts, :now), 4 * height / 720, drift_period(opts))
    }
  end

  defp px(ctx, n), do: round(n * ctx.unit)
end
