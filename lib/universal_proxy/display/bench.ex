# Emerge is a dependency of the Pi HDMI targets only (mix.exs).
if Code.ensure_loaded?(Emerge) do
  defmodule UniversalProxy.Display.Bench do
    @moduledoc """
    THROWAWAY SPIKE TOOL for the Emerge-on-HDMI renderer benchmarks
    (`.claude/plans/emerge-hdmi-gui`, Phase 1). Not part of the product; delete
    once the benchmark results are recorded.

    Drive it over SSH (the eval prints the returned map; never append
    `System.halt`):

        ssh -i ~/.ssh/up_dev_key up@192.168.2.148 'UniversalProxy.Display.Bench.probe()'
        ssh ... 'UniversalProxy.Display.Bench.run(scene: :bars, bars: 32, rate: 20, api: :raster, mode: {1280, 720})'

    `run/1` starts a viewport through `UniversalProxy.Display` (stopping any
    running one) with stats collection on, drives the scene, waits
    `:warmup` seconds, measures for `:duration` seconds and returns a map of
    Emerge stats, BEAM and OS counters. Options:

      * `:scene` — `:static` (B0: nothing changes), `:opaque` (solid rects +
        an opaque image), `:translucent_layer` (`:opaque` plus a 50%
        full-screen layer on top), `:text_gradient` (`:translucent_layer`
        plus text and gradients), `:bars` (Now Playing + `:bars` bars
        updated at `:rate` Hz from a seeded synthetic spectrum; bar heights
        are layout attrs, so every tick relayouts). Default `:bars`.
        Variants of `:bars` with the same spectrum:
          * `:bars_paint` — same screen, but each bar is full height inside
            the clipping bars row and its level is a paint-only `move_y`
            offset (`bar_mode: :offset`). The whole spec is still rebuilt
            and diffed by the viewport every tick; only paint attrs change.
          * `:bars_paint_lean` — `:bars_paint`'s tree, but the driver skips
            the viewport and sends `set_attrs` patches for the changed bars
            straight to the native renderer (Emerge has no public partial
            update: a viewport rerender always rebuilds, walks and diffs the
            whole tree). Node ids come from the viewport's diff state, which
            goes stale; harmless here since nothing else rerenders. The BEAM
            cost shows up as `driver_reductions`, not `viewport_reductions`.
          * `:bars_only` — just the `:bars` row (layout-affecting heights) on
            a solid background: no artwork or text.
      * `:rate` — updates per second. For the bar scenes the spectrum rate
        (default 20); for `:opaque`/`:translucent_layer`/`:text_gradient`
        a colour toggle that forces full repaints (default 1).
      * `:bars` — bar count (default 32). `:seed` — spectrum seed.
      * `:warmup`, `:duration` — seconds (default 10 and 30).
      * `:api` (`:auto`/`:raster`/`:opengl`), `:mode` (`{w, h}`,
        `{w, h, hz}`, `:preferred`, `nil`), `:layer_cache_mb`, `:cache`,
        `:raster_present`, `:card`, `:connector` — passed to
        `UniversalProxy.Display.Renderer.Emerge`.
      * `:keep` — leave the viewport running afterwards (default `false`).
      * `:raw_stats` — include the full Emerge stats snapshot.

    Emerge's stats give avg/min/max per stage (no percentiles).
    """

    alias UniversalProxy.Display
    alias UniversalProxy.Display.Renderer
    alias UniversalProxy.Display.Spec

    @image_dir "/tmp/up_display"
    @bar_scenes [:bars, :bars_paint, :bars_paint_lean, :bars_only]
    @user_hz 100

    @doc "What the display hardware and rootfs look like, without starting anything."
    @spec probe() :: map()
    def probe do
      %{
        dev_dri: ls("/dev/dri"),
        dev_dri_by_path: ls("/dev/dri/by-path"),
        proc_fb: read("/proc/fb"),
        outputs: Renderer.Emerge.outputs(),
        nif_loaded: Code.ensure_loaded?(EmergeSkia.Native),
        libs:
          Map.new(
            ~w(libEGL.so.1 libGLESv2.so.2 libgbm.so.1 libdrm.so.2),
            &{&1, Path.wildcard("/usr/lib/#{&1}") ++ Path.wildcard("/lib/#{&1}") != []}
          ),
        gbm_backends: ls("/usr/lib/gbm"),
        meminfo: meminfo(),
        temp_c: temp_c(),
        cpufreq_khz: cpufreq(),
        display: Display.status()
      }
    end

    @doc "Runs one benchmark window; see the moduledoc for options."
    @spec run(keyword()) :: map()
    def run(opts \\ []) do
      scene = Keyword.get(opts, :scene, :bars)
      warmup = Keyword.get(opts, :warmup, 10)
      duration = Keyword.get(opts, :duration, 30)
      rate = Keyword.get(opts, :rate, if(scene in @bar_scenes, do: 20, else: 1))
      size = Keyword.get(opts, :size, mode_size(Keyword.get(opts, :mode)))

      viewport_opts =
        opts
        |> Keyword.take([
          :api,
          :mode,
          :layer_cache_mb,
          :cache,
          :raster_present,
          :card,
          :connector,
          :preferred_size
        ])
        |> Keyword.merge(diagnostics: true, spec: first_spec(scene, size, opts))

      with {:ok, viewport} <- Display.start_viewport(viewport_opts),
           {:ok, renderer} <- await_renderer(viewport, 30_000) do
        driver = start_driver(viewport, scene, rate, size, opts)

        try do
          measure(viewport, renderer, driver, warmup, duration, opts)
          |> Map.merge(%{
            scene: scene,
            rate_hz: rate,
            bars: if(scene in @bar_scenes, do: Keyword.get(opts, :bars, 32)),
            warmup_s: warmup,
            duration_s: duration,
            options: Keyword.drop(viewport_opts, [:spec])
          })
        after
          if driver, do: Process.exit(driver, :kill)
          unless Keyword.get(opts, :keep, false), do: Display.stop_viewport()
        end
      else
        {:error, reason} ->
          Display.stop_viewport()
          %{error: reason}
      end
    end

    # -- measurement ----------------------------------------------------------

    defp measure(viewport, renderer, driver, warmup, duration, opts) do
      Process.sleep(warmup * 1000)
      :erlang.system_flag(:scheduler_wall_time, true)
      _ = stats(renderer, :reset)
      before = sample(viewport, driver)
      Process.sleep(duration * 1000)
      emerge = stats(renderer, :take)
      later = sample(viewport, driver)

      %{
        renderer_info: safe(fn -> EmergeSkia.renderer_info(renderer) end),
        emerge: summarize(emerge, Keyword.get(opts, :raw_stats, false)),
        beam: beam_delta(before, later),
        os: os_delta(before, later)
      }
    end

    defp sample(viewport, driver) do
      %{
        mono_ms: System.monotonic_time(:millisecond),
        proc: proc_self(),
        threads: threads(),
        system: proc_stat(),
        sched: :erlang.statistics(:scheduler_wall_time),
        viewport: process_info(viewport),
        driver: process_info(driver),
        meminfo: meminfo(),
        temp_c: temp_c(),
        cpufreq_khz: cpufreq()
      }
    end

    defp beam_delta(a, b) do
      %{
        viewport_reductions: delta(b.viewport[:reductions], a.viewport[:reductions]),
        viewport_queue_len: b.viewport[:message_queue_len],
        driver_reductions: delta(b.driver[:reductions], a.driver[:reductions]),
        scheduler_utilization: scheduler_utilization(a.sched, b.sched)
      }
    end

    defp os_delta(a, b) do
      seconds = (b.mono_ms - a.mono_ms) / 1000

      {utime, stime} = b.proc
      {utime0, stime0} = a.proc
      ticks = utime - utime0 + (stime - stime0)

      %{
        window_s: seconds,
        beam_cpu_pct_of_one_core: pct(ticks, seconds),
        beam_user_ticks: utime - utime0,
        beam_system_ticks: stime - stime0,
        threads_cpu_pct_of_one_core: thread_deltas(a.threads, b.threads, seconds),
        system_busy_pct_all_cores: system_busy(a.system, b.system),
        cma_free_kb: {a.meminfo["CmaFree"], b.meminfo["CmaFree"]},
        cma_total_kb: b.meminfo["CmaTotal"],
        mem_available_kb: {a.meminfo["MemAvailable"], b.meminfo["MemAvailable"]},
        temp_c: {a.temp_c, b.temp_c},
        cpufreq_khz: {a.cpufreq_khz, b.cpufreq_khz}
      }
    end

    defp summarize({:ok, snapshot}, raw?) do
      summary = %{
        rendering_api: snapshot[:rendering_api],
        frames: snapshot[:frames],
        timings:
          Map.take(snapshot[:timings] || %{}, [
            :render,
            :render_draw,
            :render_flush,
            :present_submit,
            :pipeline,
            :pipeline_tree,
            :pipeline_submit_to_swap,
            :layout,
            :refresh,
            :patch_tree_process
          ]),
        drm:
          Map.take(snapshot[:drm] || %{}, [
            :missed_vblanks,
            :page_flip_events,
            :kernel_page_flip_interval,
            :atomic_commit_ioctl,
            :egl_swap_buffers
          ]),
        pipeline: get_in(snapshot, [:counters, :pipeline]),
        renderer_cache: snapshot[:renderer_cache]
      }

      if raw?, do: Map.put(summary, :raw, snapshot), else: summary
    end

    defp summarize(other, _raw?), do: %{error: other}

    # `:take`/`:reset` can report draining while GPU samples finish.
    defp stats(renderer, command, attempts \\ 20) do
      case safe(fn -> EmergeSkia.stats(renderer, command) end) do
        {:error, _} = error when attempts <= 1 ->
          error

        {:error, _} ->
          Process.sleep(50)
          stats(renderer, command, attempts - 1)

        ok ->
          ok
      end
    end

    defp await_renderer(viewport, timeout_ms) do
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      do_await_renderer(viewport, deadline)
    end

    defp do_await_renderer(viewport, deadline) do
      renderer = safe(fn -> Renderer.Emerge.renderer(viewport) end)

      cond do
        not Process.alive?(viewport) ->
          {:error, :viewport_exited}

        renderer != nil and not match?({:error, _}, renderer) and
            match?({:ok, _}, safe(fn -> EmergeSkia.renderer_info(renderer) end)) ->
          {:ok, renderer}

        System.monotonic_time(:millisecond) > deadline ->
          {:error, :renderer_timeout}

        true ->
          Process.sleep(100)
          do_await_renderer(viewport, deadline)
      end
    end

    # -- scenes ---------------------------------------------------------------

    defp start_driver(_viewport, :static, _rate, _size, _opts), do: nil

    defp start_driver(viewport, scene, rate, size, opts) do
      seed = Keyword.get(opts, :seed, 1)
      bar_count = Keyword.get(opts, :bars, 32)
      period_ms = 1000 / max(rate, 0.001)

      {:ok, pid} =
        Task.Supervisor.start_child(UniversalProxy.TaskSupervisor, fn ->
          push = pusher(viewport, scene, size)
          :rand.seed(:exsss, {seed, seed + 1, seed + 2})
          start = System.monotonic_time(:millisecond)
          drive(push, scene, period_ms, start, 0, Spec.zero_bars(bar_count), push_state(scene))
        end)

      pid
    end

    defp drive(push, scene, period_ms, start, frame, bars, push_state) do
      bars = if scene in @bar_scenes, do: spectrum_step(bars, frame, period_ms), else: bars
      push_state = push.(frame, bars, push_state)

      next = start + round((frame + 1) * period_ms)
      Process.sleep(max(next - System.monotonic_time(:millisecond), 0))
      drive(push, scene, period_ms, start, frame + 1, bars, push_state)
    end

    defp push_state(:bars_paint_lean), do: %{}
    defp push_state(_scene), do: nil

    defp pusher(viewport, :bars_paint_lean, _size) do
      {renderer, targets} = lean_targets(viewport, System.monotonic_time(:millisecond) + 30_000)
      transport = EmergeSkia.Transport.for_renderer(renderer)

      # `push_state` is %{node_id => last move_y}: only changed bars are sent.
      fn _frame, bars, sent ->
        {patches, sent} =
          targets
          |> Enum.zip(bars)
          |> Enum.reduce({[], sent}, fn {{id, attrs, max_height}, height}, {patches, sent} ->
            offset = max_height - max(round(height * max_height), 2)

            if Map.get(sent, id) == offset,
              do: {patches, sent},
              else:
                {[{:set_attrs, id, Map.put(attrs, :move_y, offset)} | patches],
                 Map.put(sent, id, offset)}
          end)

        if patches != [] do
          :ok = transport.patch_tree(renderer, Emerge.Engine.Patch.encode(patches))
        end

        sent
      end
    end

    defp pusher(viewport, scene, size) do
      fn frame, bars, push_state ->
        Renderer.Emerge.push(viewport, scene_spec(scene, size, frame, bars))
        push_state
      end
    end

    # [{node_id, declared attrs, max_height}] for the `viz-N` bars, in order,
    # read from the viewport's diff state once the first tree is uploaded.
    defp lean_targets(viewport, deadline) do
      runtime = Emerge.Runtime.Viewport.runtime!(:sys.get_state(viewport))

      with %{vdom: %Emerge.Engine.VNode{} = vdom} <- runtime.diff_state,
           renderer when renderer != nil <- runtime.renderer,
           [_ | _] = bars <- bar_vnodes(vdom) do
        {renderer,
         Enum.map(bars, fn %{id: id, attrs: attrs} -> {id, attrs, lean_max_height(attrs)} end)}
      else
        _ ->
          if System.monotonic_time(:millisecond) > deadline,
            do: raise("bars_paint_lean: viewport never uploaded a tree with bars")

          Process.sleep(100)
          lean_targets(viewport, deadline)
      end
    end

    defp bar_vnodes(vdom) do
      vdom |> indexed_bar_vnodes() |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
    end

    defp indexed_bar_vnodes(%Emerge.Engine.VNode{key: "viz-" <> index} = vnode),
      do: [{String.to_integer(index), vnode}]

    defp indexed_bar_vnodes(%Emerge.Engine.VNode{children: children, nearby: nearby}) do
      Enum.flat_map(children ++ Enum.map(nearby, &elem(&1, 1)), &indexed_bar_vnodes/1)
    end

    # An `:offset` bar is declared at the full row height.
    defp lean_max_height(%{height: {:px, max_height}}), do: max_height

    defp lean_max_height(attrs),
      do: raise("bars_paint_lean: unexpected bar attrs #{inspect(attrs)}")

    defp first_spec(scene, size, opts) do
      scene_spec(scene, size, 0, Spec.zero_bars(Keyword.get(opts, :bars, 32)))
    end

    defp scene_spec(:bars, size, _frame, bars) do
      Spec.now_playing(
        size: size,
        title: "Benchmark Track Title",
        artist: "Synthetic Artist",
        album: "Deterministic Spectrum",
        art: cover_image(),
        bars: bars
      )
    end

    defp scene_spec(paint, size, frame, bars) when paint in [:bars_paint, :bars_paint_lean] do
      :bars |> scene_spec(size, frame, bars) |> put_bar_attrs(bar_mode: :offset)
    end

    defp scene_spec(:bars_only, size, frame, bars) do
      {:column, root_attrs, [_top, viz]} = scene_spec(:bars, size, frame, bars)
      {:bars, viz_attrs, heights} = viz

      {:column, Keyword.take(root_attrs, [:key, :width, :height, :padding, :background]),
       [{:bars, viz_attrs ++ [align_y: :bottom], heights}]}
    end

    defp scene_spec(:static, size, _frame, _bars), do: scene_spec(:opaque, size, 0, [])

    defp scene_spec(:opaque, {width, height}, frame, _bars) do
      tone = if rem(frame, 2) == 0, do: {20, 24, 40}, else: {40, 20, 24}
      opaque_base(tone, width, height)
    end

    defp scene_spec(:translucent_layer, size, frame, _bars) do
      {:stack, [key: "stack", width: :fill, height: :fill],
       [
         scene_spec(:opaque, size, frame, []),
         {:column, [key: "veil", width: :fill, height: :fill, background: {0, 0, 0, 0.5}], []}
       ]}
    end

    defp scene_spec(:text_gradient, {width, height} = size, frame, _bars) do
      {:stack, [key: "stack", width: :fill, height: :fill],
       [
         scene_spec(:opaque, size, frame, []),
         {:column,
          [
            key: "veil",
            width: :fill,
            height: :fill,
            padding: round(height * 0.05),
            spacing: 12,
            background: {:gradient, [{0, 0, 0, 0.2}, {30, 60, 120, 0.6}, {0, 0, 0, 0.7}], 90}
          ],
          for i <- 1..8 do
            {:text,
             [
               key: "line-#{i}",
               font_size: round(width / 40),
               font_color: {:gradient, [{255, 255, 255}, {120, 200, 255}], 0}
             ], "Line #{i}: The quick brown fox jumps over the lazy dog #{frame}"}
          end}
       ]}
    end

    defp put_bar_attrs({:bars, attrs, heights}, extra), do: {:bars, attrs ++ extra, heights}

    defp put_bar_attrs({kind, attrs, children}, extra) when kind in [:column, :row, :stack],
      do: {kind, attrs, Enum.map(children, &put_bar_attrs(&1, extra))}

    defp put_bar_attrs(node, _extra), do: node

    defp opaque_base(tone, width, height) do
      tile = round(height / 4)

      {:column, [key: "root", width: :fill, height: :fill, background: tone, spacing: 8],
       [
         {:row, [key: "tiles", spacing: 8],
          for i <- 1..max(div(width, tile + 8) - 1, 1) do
            {:column,
             [
               key: "tile-#{i}",
               width: {:px, tile},
               height: {:px, tile},
               background: {rem(i * 40, 255), 90, 160}
             ], []}
          end},
         {:image,
          [key: "cover", width: {:px, tile * 2}, height: {:px, tile * 2}, image_fit: :cover],
          cover_image()}
       ]}
    end

    # Music-like synthetic spectrum: a pink-ish tilt, a ~2 Hz pulse and
    # seeded noise, with fast attack and slow decay.
    defp spectrum_step(bars, frame, period_ms) do
      count = length(bars)
      t = frame * period_ms / 1000
      pulse = 0.55 + 0.45 * abs(:math.sin(t * :math.pi() * 2))

      bars
      |> Enum.with_index()
      |> Enum.map(fn {previous, i} ->
        tilt = 1.0 - 0.6 * i / max(count - 1, 1)
        target = Spec.clamp_unit(tilt * pulse * (0.35 + 0.65 * :rand.uniform()))

        if target > previous,
          do: previous + (target - previous) * 0.6,
          else: previous * 0.85
      end)
    end

    defp mode_size({w, h}), do: {w, h}
    defp mode_size({w, h, _hz}), do: {w, h}
    defp mode_size(_), do: {1280, 720}

    # A 512x512 opaque gradient PNG, written once.
    defp cover_image do
      path = Path.join(@image_dir, "bench_cover.png")

      unless File.exists?(path) do
        File.mkdir_p!(@image_dir)
        File.write!(path, png(512, 512))
      end

      path
    end

    defp png(width, height) do
      rows =
        for y <- 0..(height - 1), into: <<>> do
          row =
            for x <- 0..(width - 1), into: <<>> do
              <<div(x * 255, width), div(y * 255, height), 160>>
            end

          <<0, row::binary>>
        end

      header = <<width::32, height::32, 8, 2, 0, 0, 0>>

      <<137, 80, 78, 71, 13, 10, 26, 10>> <>
        chunk("IHDR", header) <>
        chunk("IDAT", :zlib.compress(rows)) <> chunk("IEND", <<>>)
    end

    defp chunk(type, data) do
      <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>
    end

    # -- OS / BEAM readings ---------------------------------------------------

    defp proc_self do
      case stat_fields(read("/proc/self/stat")) do
        {_comm, fields} -> {field(fields, 14), field(fields, 15)}
        nil -> {0, 0}
      end
    end

    # %{thread comm => utime + stime ticks}, summed over threads sharing a name.
    defp threads do
      "/proc/self/task/*/stat"
      |> Path.wildcard()
      |> Enum.reduce(%{}, fn path, acc ->
        case stat_fields(read(path)) do
          {comm, fields} ->
            Map.update(
              acc,
              comm,
              field(fields, 14) + field(fields, 15),
              &(&1 + field(fields, 14) + field(fields, 15))
            )

          nil ->
            acc
        end
      end)
    end

    defp thread_deltas(a, b, seconds) do
      b
      |> Enum.map(fn {comm, ticks} -> {comm, pct(ticks - Map.get(a, comm, 0), seconds)} end)
      |> Enum.reject(fn {_comm, pct} -> pct == 0.0 end)
      |> Enum.sort_by(fn {_comm, pct} -> -pct end)
    end

    # "pid (comm) state f4 f5 ..." -> {comm, fields} where fields[0] is field 3.
    defp stat_fields(nil), do: nil

    defp stat_fields(line) do
      case Regex.run(~r/^\d+ \((.*)\) (.*)$/s, String.trim(line)) do
        [_, comm, rest] -> {comm, String.split(rest, " ")}
        _ -> nil
      end
    end

    defp field(fields, n), do: fields |> Enum.at(n - 3, "0") |> String.to_integer()

    defp proc_stat do
      with line when is_binary(line) <- read("/proc/stat"),
           ["cpu" <> _ | values] <- line |> String.split("\n") |> hd() |> String.split() do
        numbers = Enum.map(values, &String.to_integer/1)
        idle = Enum.at(numbers, 3, 0) + Enum.at(numbers, 4, 0)
        {Enum.sum(numbers), idle}
      else
        _ -> {0, 0}
      end
    end

    defp system_busy({total0, idle0}, {total, idle}) when total > total0 do
      Float.round(100 * (1 - (idle - idle0) / (total - total0)), 1)
    end

    defp system_busy(_, _), do: nil

    defp scheduler_utilization(a, b) when is_list(a) and is_list(b) do
      a = Map.new(a, fn {id, active, total} -> {id, {active, total}} end)

      b
      |> Enum.filter(fn {id, _active, _total} -> id <= :erlang.system_info(:schedulers) end)
      |> Enum.map(fn {id, active, total} ->
        {active0, total0} = Map.get(a, id, {0, 0})
        if total > total0, do: (active - active0) / (total - total0), else: 0.0
      end)
      |> then(fn utils -> Float.round(100 * Enum.sum(utils) / max(length(utils), 1), 1) end)
    end

    defp scheduler_utilization(_, _), do: nil

    defp process_info(nil), do: []

    defp process_info(pid) do
      Process.info(pid, [:reductions, :message_queue_len]) || []
    end

    defp meminfo do
      case read("/proc/meminfo") do
        nil ->
          %{}

        text ->
          for line <- String.split(text, "\n", trim: true),
              [key, value | _] <- [String.split(line, [":", " "], trim: true)],
              into: %{} do
            {key, String.to_integer(value)}
          end
      end
    end

    defp temp_c do
      case read("/sys/class/thermal/thermal_zone0/temp") do
        nil -> nil
        text -> String.to_integer(String.trim(text)) / 1000
      end
    end

    defp cpufreq do
      case read("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq") do
        nil -> nil
        text -> String.to_integer(String.trim(text))
      end
    end

    defp pct(ticks, seconds) when seconds > 0,
      do: Float.round(100 * ticks / @user_hz / seconds, 1)

    defp pct(_ticks, _seconds), do: 0.0

    defp delta(b, a) when is_integer(a) and is_integer(b), do: b - a
    defp delta(_b, _a), do: nil

    defp read(path) do
      case File.read(path) do
        {:ok, text} -> text
        {:error, _} -> nil
      end
    end

    defp ls(dir) do
      case File.ls(dir) do
        {:ok, entries} -> Enum.sort(entries)
        {:error, reason} -> {:error, reason}
      end
    end

    defp safe(fun) do
      fun.()
    rescue
      error -> {:error, Exception.message(error)}
    catch
      :exit, _ -> {:error, :exit}
    end
  end
end
