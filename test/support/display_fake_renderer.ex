defmodule UniversalProxy.Display.FakeRenderer do
  @moduledoc """
  A `UniversalProxy.Display.Renderer` for tests: each viewport is an `Agent`
  under the given supervisor, and every call is reported to the `:test_pid`
  start option as `{:fake_renderer, call, ...}`. An `:on_start` start
  option (a 0-arity fun) runs in the caller before the viewport starts.
  """

  @behaviour UniversalProxy.Display.Renderer

  @impl true
  def available?, do: true

  @impl true
  def start(supervisor, opts) do
    test_pid = Keyword.fetch!(opts, :test_pid)
    send(test_pid, {:fake_renderer, :start, opts})
    if on_start = opts[:on_start], do: on_start.()

    child = Supervisor.child_spec({Agent, fn -> test_pid end}, restart: :temporary)
    DynamicSupervisor.start_child(supervisor, child)
  end

  @impl true
  def push(viewport, spec) do
    send(Agent.get(viewport, & &1), {:fake_renderer, :push, viewport, spec})
    :ok
  end

  @impl true
  def set_display(viewport, power) do
    send(Agent.get(viewport, & &1), {:fake_renderer, :set_display, viewport, power})
    :ok
  end

  @impl true
  def set_viz(viewport, viz) do
    send(Agent.get(viewport, & &1), {:fake_renderer, :set_viz, viewport, viz})
    :ok
  end

  @impl true
  def stop(viewport) do
    send(Agent.get(viewport, & &1), {:fake_renderer, :stop, viewport})
    Agent.stop(viewport)
  end
end
