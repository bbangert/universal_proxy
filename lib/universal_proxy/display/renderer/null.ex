defmodule UniversalProxy.Display.Renderer.Null do
  @moduledoc """
  A `UniversalProxy.Display.Renderer` that draws nothing.

  The default renderer on host and on targets without an HDMI display. It
  reports itself unavailable, and every call succeeds without side effects,
  so the display logic can run anywhere.
  """

  @behaviour UniversalProxy.Display.Renderer

  @impl true
  def available?, do: false

  @impl true
  def start(_supervisor, _opts), do: {:ok, :null}

  @impl true
  def push(_handle, _spec), do: :ok

  @impl true
  def set_display(_handle, _power), do: :ok

  @impl true
  def set_viz(_handle, _viz), do: :ok

  @impl true
  def stop(_handle), do: :ok
end
