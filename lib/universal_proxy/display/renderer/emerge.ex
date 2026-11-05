# Emerge is a dependency of the Pi HDMI targets only (mix.exs), so this module
# exists only where it compiled; config names it by atom.
if Code.ensure_loaded?(Emerge) do
  defmodule UniversalProxy.Display.Renderer.Emerge do
    @moduledoc """
    A `UniversalProxy.Display.Renderer` that draws with Emerge (Skia) straight
    to DRM/KMS, one `UniversalProxy.Display.Viewport` per display.

    `start/2` options:

      * `:api` — `:auto` (default; GL with a raster fallback at start when
        the NIF has GL), `:raster` (CPU drawing into KMS dumb buffers) or
        `:opengl`.
      * `:card` — the DRM card path. Default: the first `/dev/dri/card*`
        with a connected HDMI connector.
      * `:connector` — connector name. Default: the first connected HDMI one.
      * `:mode` — `nil` (default: Emerge picks, steered by
        `:preferred_size`), `:preferred` (the TV's preferred mode),
        `{width, height}` (the highest refresh at that size),
        `{width, height, refresh_hz}` (the nearest refresh) or an Emerge
        mode id string.
      * `:preferred_size` — `{width, height}` hint for automatic selection.
      * `:layer_cache_mb` — paint-layer cache budget in MiB (Emerge's default
        is 640). `:cache` — `:auto` (default: on for GPU, off for explicit
        raster), `true` or `false`.
      * `:raster_present` — `:auto` (default), `:cpu` or `:gpu_upload`.
      * `:diagnostics` — `true` collects `EmergeSkia.stats/2` counters;
        `:log` also logs a summary every ~5 s.
      * `:image_dirs` — directories image paths may come from (default
        `["/tmp/up_display"]`, created if missing).
      * `:spec` — the first `UniversalProxy.Display.Spec` to show.
    """

    @behaviour UniversalProxy.Display.Renderer

    alias Emerge.UI
    alias Emerge.UI.{Align, Background, Border, Color, Font, Nearby, Size, Space, Transform}
    alias UniversalProxy.Display.{Spec, State, Viewport}

    @mib 1024 * 1024
    @default_image_dirs ["/tmp/up_display"]
    @bar_attrs [:bar_width, :max_height, :color, :bar_mode]

    @impl true
    def available?, do: Code.ensure_loaded?(EmergeSkia.Native) and State.display_card?()

    @impl true
    def start(supervisor, opts) do
      with {:ok, config} <- config(opts) do
        spec = Keyword.get_lazy(opts, :spec, fn -> Spec.now_playing() end)

        child =
          Supervisor.child_spec({Viewport, [config: config, spec: spec]}, restart: :temporary)

        DynamicSupervisor.start_child(supervisor, child)
      end
    end

    @impl true
    def push(viewport, spec) do
      send(viewport, {:display_spec, spec})
      :ok
    end

    @impl true
    def set_display(viewport, power) when power in [:on, :off] do
      send(viewport, {:display_power, power})
      :ok
    end

    @impl true
    def stop(viewport) do
      GenServer.stop(viewport, :normal, 30_000)
    catch
      :exit, _ -> :ok
    end

    @doc "The Emerge renderer handle of a running viewport (for `EmergeSkia.stats/2`)."
    @spec renderer(pid()) :: term()
    def renderer(viewport), do: Emerge.renderer(viewport)

    @doc """
    DRM outputs per card: `%{card_path => {:ok, outputs} | {:error, reason}}`
    for every `/dev/dri/card*` (see `EmergeSkia.drm_outputs/1`).
    """
    @spec outputs(Path.t()) :: %{Path.t() => {:ok, [map()]} | {:error, term()}}
    def outputs(dri_dir \\ "/dev/dri") do
      dri_dir
      |> Path.join("card*")
      |> Path.wildcard()
      |> Enum.sort()
      |> Map.new(fn card -> {card, drm_outputs(card)} end)
    end

    @doc "The `%Emerge.Config{}` `start/2` would use for `opts`."
    @spec config(keyword()) :: {:ok, Emerge.Config.t()} | {:error, term()}
    def config(opts) do
      with {:ok, card, output} <- select_output(opts),
           {:ok, mode} <- select_mode(output, Keyword.get(opts, :mode)) do
        image_dirs = Keyword.get(opts, :image_dirs, @default_image_dirs)
        Enum.each(image_dirs, &File.mkdir_p/1)

        {:ok,
         %Emerge.Config{
           output: %Emerge.Config.DRM{
             card: card,
             connector: output.name,
             mode: mode,
             preferred_size: if(mode, do: nil, else: Keyword.get(opts, :preferred_size))
           },
           renderer: %Emerge.Config.Renderer{
             api: Keyword.get(opts, :api, :auto),
             raster_present: Keyword.get(opts, :raster_present, :auto),
             cache: cache_config(opts)
           },
           assets: %Emerge.Config.Assets{
             otp_app: :universal_proxy,
             decode_at_size: true,
             runtime_paths: %Emerge.Config.RuntimePaths{enabled: true, allowlist: image_dirs}
           },
           diagnostics: diagnostics_config(Keyword.get(opts, :diagnostics, false))
         }}
      end
    end

    @doc "Translates a `UniversalProxy.Display.Spec` into an Emerge element tree."
    @spec tree(Spec.t()) :: Emerge.tree()
    def tree(:none), do: UI.none()

    def tree({:column, attrs, children}),
      do: UI.column(attrs(attrs), Enum.map(children, &tree/1))

    def tree({:row, attrs, children}), do: UI.row(attrs(attrs), Enum.map(children, &tree/1))

    def tree({:stack, attrs, []}), do: UI.el(attrs(attrs), UI.none())

    def tree({:stack, attrs, [content | overlays]}) do
      UI.el(attrs(attrs) ++ Enum.map(overlays, &Nearby.in_front(tree(&1))), tree(content))
    end

    def tree({:text, attrs, string}), do: UI.el(attrs(attrs), UI.text(string))

    def tree({:image, attrs, path}), do: UI.image(attrs(attrs), {:path, path})

    def tree({:bars, attrs, heights}) do
      key = Keyword.get(attrs, :key, "bars")
      max_height = Keyword.get(attrs, :max_height, 100)
      bar_width = Keyword.get(attrs, :bar_width, 8)
      color = paint(Keyword.get(attrs, :color, {255, 255, 255}))
      mode = Keyword.get(attrs, :bar_mode, :height)

      bars =
        heights
        |> Enum.with_index()
        |> Enum.map(fn {height, index} ->
          UI.el(
            bar_attrs(
              mode,
              "#{key}-#{index}",
              bar_width,
              max(round(height * max_height), 2),
              max_height,
              color
            ),
            UI.none()
          )
        end)

      UI.row([Size.height(Size.px(max_height)) | attrs(attrs)], bars)
    end

    defp bar_attrs(:height, key, width, level, _max_height, color) do
      [
        UI.key(key),
        Size.width(Size.px(width)),
        Size.height(Size.px(level)),
        Background.color(color),
        Align.align_bottom()
      ]
    end

    # Every Emerge host clips its normal children (transforms included), so a
    # full-height bar moved down shows only its top `level` pixels, and
    # `move_y` is a paint-only attr: changing it refreshes without layout.
    defp bar_attrs(:offset, key, width, level, max_height, color) do
      [
        UI.key(key),
        Size.width(Size.px(width)),
        Size.height(Size.px(max_height)),
        Background.color(color),
        Transform.move_y(max_height - level)
      ]
    end

    defp attrs(attrs) do
      for {key, value} <- attrs, key not in @bar_attrs, do: attr(key, value)
    end

    defp attr(:width, length), do: Size.width(size_value(length))
    defp attr(:height, length), do: Size.height(size_value(length))
    defp attr(:padding, n), do: Space.padding(n)
    defp attr(:spacing, n), do: Space.spacing(n)
    defp attr(:background, paint), do: Background.color(paint(paint))
    defp attr(:font_size, n), do: Font.size(n)
    defp attr(:font_color, paint), do: Font.color(paint(paint))
    defp attr(:font_weight, weight), do: Font.weight(weight)
    defp attr(:align_x, :left), do: Align.align_left()
    defp attr(:align_x, :center), do: Align.center_x()
    defp attr(:align_x, :right), do: Align.align_right()
    defp attr(:align_y, :top), do: Align.align_top()
    defp attr(:align_y, :center), do: Align.center_y()
    defp attr(:align_y, :bottom), do: Align.align_bottom()
    defp attr(:rounded, radius), do: Border.rounded(radius)
    defp attr(:alpha, alpha), do: Transform.alpha(alpha)
    defp attr(:image_fit, fit), do: UI.image_fit(fit)
    defp attr(:key, key), do: UI.key(key)

    defp size_value(:fill), do: :fill
    defp size_value(:content), do: :content
    defp size_value({:px, n}), do: Size.px(n)
    defp size_value({:fill, weight}), do: Size.fill(weight)

    defp paint({:gradient, colors, angle}), do: Color.gradient(Enum.map(colors, &paint/1), angle)
    defp paint({r, g, b}), do: Color.color_rgb(r, g, b)
    defp paint({r, g, b, a}), do: Color.color_rgba(r, g, b, a)

    defp select_output(opts) do
      cards =
        case Keyword.get(opts, :card) do
          nil -> "/dev/dri" |> Path.join("card*") |> Path.wildcard() |> Enum.sort()
          card -> [card]
        end

      connector = Keyword.get(opts, :connector)

      found =
        Enum.find_value(cards, fn card ->
          with {:ok, outputs} <- drm_outputs(card),
               %{} = output <- pick_output(outputs, connector) do
            {:ok, card, output}
          else
            _ -> nil
          end
        end)

      found || {:error, {:no_output, connector || :connected_hdmi, cards}}
    end

    defp pick_output(outputs, nil) do
      outputs
      |> Enum.filter(&(&1.connected and String.starts_with?(&1.name, "HDMI")))
      |> Enum.sort_by(& &1.name)
      |> List.first()
    end

    defp pick_output(outputs, name), do: Enum.find(outputs, &(&1.name == name))

    defp select_mode(_output, nil), do: {:ok, nil}
    defp select_mode(_output, id) when is_binary(id), do: {:ok, id}

    defp select_mode(output, :preferred) do
      found(output, :preferred, Enum.find(output.modes, & &1.preferred))
    end

    defp select_mode(output, {width, height}) do
      mode =
        output.modes
        |> Enum.filter(&(&1.width == width and &1.height == height and not &1.interlaced))
        |> Enum.max_by(& &1.refresh_hz, fn -> nil end)

      found(output, {width, height}, mode)
    end

    defp select_mode(output, {width, height, refresh}) do
      mode =
        output.modes
        |> Enum.filter(&(&1.width == width and &1.height == height and not &1.interlaced))
        |> Enum.min_by(&abs(&1.refresh_hz - refresh), fn -> nil end)

      found(output, {width, height, refresh}, mode)
    end

    defp found(output, wanted, nil) do
      available = Enum.map(output.modes, &{&1.width, &1.height, &1.refresh_hz})
      {:error, {:mode_not_found, wanted, available}}
    end

    defp found(_output, _wanted, mode), do: {:ok, mode}

    defp cache_config(opts) do
      paint_layer =
        case Keyword.get(opts, :layer_cache_mb) do
          nil ->
            %Emerge.Config.PaintLayerCache{}

          mb ->
            bytes = round(mb * @mib)
            default = %Emerge.Config.PaintLayerCache{}

            %Emerge.Config.PaintLayerCache{
              max_bytes: bytes,
              max_entry_bytes: min(default.max_entry_bytes, bytes)
            }
        end

      %Emerge.Config.RendererCache{
        enabled: Keyword.get(opts, :cache, :auto),
        paint_layer: paint_layer
      }
    end

    defp diagnostics_config(true), do: %Emerge.Config.Diagnostics{stats: true}
    defp diagnostics_config(:log), do: %Emerge.Config.Diagnostics{stats: true, logs: [:stats]}
    defp diagnostics_config(_), do: %Emerge.Config.Diagnostics{}

    defp drm_outputs(card) do
      EmergeSkia.drm_outputs(drm_card: card)
    rescue
      error -> {:error, Exception.message(error)}
    end
  end
end
