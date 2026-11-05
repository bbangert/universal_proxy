# Emerge is a dependency of the Pi HDMI targets only (mix.exs).
if Code.ensure_loaded?(Emerge) do
  defmodule UniversalProxy.Display.Viewport do
    @moduledoc """
    The Emerge viewport process for the HDMI display, started by
    `UniversalProxy.Display.Renderer.Emerge`. It owns the native renderer and
    the DRM lease, and draws the latest `UniversalProxy.Display.Spec` it was
    sent.

    Messages:

      * `{:display_spec, spec}` — show `spec` (rerenders are coalesced, so a
        burst of specs draws only the latest).
      * `{:display_power, :on | :off}` — blank or unblank the screen. Blanking
        draws a black frame and keeps the DRM output on: turning the CRTC off
        on vc4 also stops HDMI audio and CEC. The current spec is kept and
        drawn again on unblank.
      * `{:display_viz, viz | nil}` — feed live visualizer frames from
        `viz.topic` into the spec's `"viz"` bars, or stop
        (`t:UniversalProxy.Display.Renderer.viz/0`).

    ## Visualizer

    The viewport subscribes to the visualizer topic only while it has a
    source and the screen is on. Frames arrive `lead_ms` ahead of the audio
    they belong to, so each waits in a small bounded buffer
    (`UniversalProxy.Display.Viz.buffer_push/4`) until it is due; a tick
    (`:viz_tick_ms`, 50 ms by default) draws the newest due frame and drops
    older ones, so frames arriving faster than the screen redraws are
    dropped rather than queued.
    When the mailbox backs up anyway, it steps down a
    `UniversalProxy.Display.Viz` tier (full → reduced → pulse → off),
    logs it, and tells the `:owner` (if any) as `{:viewport_viz_tier, pid,
    tier}`; at `:off` it unsubscribes. A new source starts at `:full` again.

    ## Output size

    The DRM backend reports the mode it set as a resize; the viewport tells
    the `:owner` as `{:viewport_size, pid, {width, height}}`.

    Start options: `:config` (an `%Emerge.Config{}`), `:spec`, `:viz_tick_ms`
    and `:owner`.
    """

    use Emerge

    require Logger

    alias UniversalProxy.Display.{Renderer, Spec, Viz}

    @pubsub UniversalProxy.PubSub
    @viz_key "viz"
    @default_tick_ms 50
    # Mailbox length at a tick that counts as falling behind.
    @backlog 50
    # Frames older than this are silence: the bars decay instead.
    @silence_ms 200
    @decay 0.6

    @impl Viewport
    def mount(opts) do
      config = Keyword.fetch!(opts, :config)

      state = %{
        spec: Keyword.fetch!(opts, :spec),
        power: :on,
        owner: Keyword.get(opts, :owner),
        tick_ms: Keyword.get(opts, :viz_tick_ms, @default_tick_ms),
        viz: nil,
        subscribed: nil,
        tier: :full,
        pending: [],
        frame: nil,
        frame_at: nil,
        heights: [],
        ticks: 0,
        tick_ref: nil
      }

      {:ok, state, config}
    end

    @impl Viewport
    def render(%{power: :off}), do: Renderer.Emerge.tree(Spec.blank())
    def render(%{spec: spec, heights: []}), do: Renderer.Emerge.tree(spec)

    def render(%{spec: spec, heights: heights}),
      do: Renderer.Emerge.tree(Spec.put_bars(spec, @viz_key, heights))

    @impl Viewport
    def handle_info({:display_spec, spec}, state),
      do: {:noreply, state |> Map.put(:spec, spec) |> sync_viz() |> Viewport.rerender()}

    def handle_info({:display_power, power}, state),
      do: {:noreply, state |> Map.put(:power, power) |> sync_viz() |> Viewport.rerender()}

    def handle_info({:display_viz, viz}, state) do
      state = if viz != state.viz, do: %{state | viz: viz, tier: :full}, else: state
      {:noreply, state |> sync_viz() |> Viewport.rerender()}
    end

    def handle_info({:sendspin_viz, key, frame}, %{subscribed: %{key: key}} = state)
        when is_map(frame),
        do: {:noreply, %{state | pending: Viz.buffer_push(state.pending, frame, now_ms())}}

    def handle_info(:viz_tick, %{subscribed: nil} = state),
      do: {:noreply, %{state | tick_ref: nil}}

    def handle_info(:viz_tick, state) do
      state = %{state | tick_ref: schedule_tick(state.tick_ms), ticks: state.ticks + 1}
      state = state |> maybe_degrade() |> take_due_frame()

      if state.subscribed && rem(state.ticks, Viz.tick_divisor(state.tier)) == 0 do
        {:noreply, redraw_bars(state)}
      else
        {:noreply, state}
      end
    end

    def handle_info(_message, state), do: {:noreply, state}

    # The output size (the DRM mode Emerge chose, again after a hotplug
    # modeset): the owner lays its screens out for it.
    @impl Viewport
    def handle_input({:resize, {width, height, _scale}}, state) do
      if state.owner, do: send(state.owner, {:viewport_size, self(), {width, height}})
      {:noreply, state}
    end

    def handle_input(_event, state), do: {:noreply, state}

    # ── Visualizer ─────────────────────────────────────────────────────

    # Subscribed only while there is a source, the screen is on, the spec
    # has bars to fill and the tier isn't :off.
    defp sync_viz(state) do
      wanted =
        if state.viz && state.power == :on && state.tier != :off &&
             Spec.has_bars?(state.spec, @viz_key),
           do: state.viz

      if wanted == state.subscribed do
        state
      else
        if state.subscribed, do: Phoenix.PubSub.unsubscribe(@pubsub, state.subscribed.topic)
        if wanted, do: Phoenix.PubSub.subscribe(@pubsub, wanted.topic)
        state = %{state | subscribed: wanted, pending: [], frame: nil, frame_at: nil, heights: []}

        if wanted && is_nil(state.tick_ref),
          do: %{state | tick_ref: schedule_tick(state.tick_ms)},
          else: state
      end
    end

    # Every tick, so frames that came due on a skipped (lower tier) tick are
    # superseded rather than drawn late.
    defp take_due_frame(state) do
      now = now_ms()

      case Viz.buffer_take(state.pending, now) do
        {nil, pending} -> %{state | pending: pending}
        {frame, pending} -> %{state | pending: pending, frame: frame, frame_at: now}
      end
    end

    defp redraw_bars(state) do
      heights =
        cond do
          state.frame_at && now_ms() - state.frame_at <= @silence_ms ->
            Viz.heights(state.frame, state.tier, bar_count(state.spec))

          state.heights == [] ->
            []

          true ->
            Viz.decay(state.heights, @decay)
        end

      if heights == state.heights,
        do: state,
        else: Viewport.rerender(%{state | heights: heights})
    end

    defp maybe_degrade(state) do
      {:message_queue_len, len} = Process.info(self(), :message_queue_len)

      if len > @backlog do
        drain_viz()
        tier = Viz.degrade(state.tier)

        Logger.warning(
          "[Display] viewport behind (#{len} queued): visualizer #{state.tier} -> #{tier}"
        )

        if state.owner, do: send(state.owner, {:viewport_viz_tier, self(), tier})
        # At :off the bars are cleared and the ticks stop: draw that once.
        %{state | tier: tier} |> sync_viz() |> Viewport.rerender()
      else
        state
      end
    end

    # Drops queued visualizer frames (bounded, so a flood can't pin us here).
    defp drain_viz(n \\ 500)
    defp drain_viz(0), do: :ok

    defp drain_viz(n) do
      receive do
        {:sendspin_viz, _key, _frame} -> drain_viz(n - 1)
      after
        0 -> :ok
      end
    end

    defp bar_count({:bars, attrs, heights}),
      do: if(Keyword.get(attrs, :key) == @viz_key, do: length(heights), else: 0)

    defp bar_count({tag, _attrs, children}) when tag in [:column, :row, :stack],
      do: Enum.reduce_while(children, 0, &first_count/2)

    defp bar_count(_node), do: 0

    defp first_count(child, 0) do
      case bar_count(child) do
        0 -> {:cont, 0}
        n -> {:halt, n}
      end
    end

    defp schedule_tick(ms), do: Process.send_after(self(), :viz_tick, ms)

    defp now_ms, do: System.monotonic_time(:millisecond)
  end
end
