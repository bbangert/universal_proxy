defmodule UniversalProxy.Display.Renderer do
  @moduledoc """
  What `UniversalProxy.Display` needs from a screen renderer.

  A renderer starts a viewport (one process driving one display) under the
  display's `DynamicSupervisor`, shows `UniversalProxy.Display.Spec` trees on
  it and stops it. The module comes from config
  (`config :universal_proxy, UniversalProxy.Display, renderer: ...`), so
  always-compiled code never references a target-only renderer directly:

    * `UniversalProxy.Display.Renderer.Null` — the default; draws nothing.
    * `UniversalProxy.Display.Renderer.Emerge` — Skia on DRM/KMS via Emerge,
      compiled only on the Pi HDMI targets.

  `push/2` and `set_display/2` are asynchronous messages: callers never block
  on the renderer.
  """

  alias UniversalProxy.Display.Spec

  @typedoc "A running viewport, as returned by `c:start/2`."
  @type handle :: term()

  @doc "Whether this renderer can drive a display on this system right now."
  @callback available?() :: boolean()

  @doc """
  Starts a viewport under `supervisor` (a `DynamicSupervisor`) as a
  `:temporary` child. Options are renderer-specific; `:spec` is the first
  screen to show.
  """
  @callback start(Supervisor.supervisor(), keyword()) :: {:ok, handle()} | {:error, term()}

  @doc "Shows `spec` on the viewport, replacing what it showed before."
  @callback push(handle(), Spec.t()) :: :ok

  @doc "Turns the display output on or off (blank) without stopping the viewport."
  @callback set_display(handle(), :on | :off) :: :ok

  @doc "Stops the viewport."
  @callback stop(handle()) :: :ok
end
