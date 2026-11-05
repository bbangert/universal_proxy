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

    Start options: `:config` (an `%Emerge.Config{}`) and `:spec`.
    """

    use Emerge

    alias UniversalProxy.Display.{Renderer, Spec}

    @impl Viewport
    def mount(opts) do
      config = Keyword.fetch!(opts, :config)
      {:ok, %{spec: Keyword.fetch!(opts, :spec), power: :on}, config}
    end

    @impl Viewport
    def render(%{power: :off}), do: Renderer.Emerge.tree(Spec.blank())
    def render(%{spec: spec}), do: Renderer.Emerge.tree(spec)

    @impl Viewport
    def handle_info({:display_spec, spec}, state),
      do: {:noreply, Viewport.rerender(%{state | spec: spec})}

    def handle_info({:display_power, power}, state),
      do: {:noreply, Viewport.rerender(%{state | power: power})}

    def handle_info(_message, state), do: {:noreply, state}
  end
end
