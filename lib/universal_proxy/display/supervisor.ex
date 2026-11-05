defmodule UniversalProxy.Display.Supervisor do
  @moduledoc """
  HDMI display subtree: the `DynamicSupervisor` the viewport runs under and
  `UniversalProxy.Display.State`, which starts, watches and stops it.

  The viewport is a `:temporary` child, started by State, never restarted by
  the `DynamicSupervisor`. `:one_for_all` makes a State restart also take the
  viewport down, so the new State starts from a clean slate instead of
  inheriting a viewport (and its DRM lease) it doesn't monitor.

  Returns `:ignore` unless the `UniversalProxy.Display` env has
  `enabled: true` (config/target.exs, Pi HDMI targets) or `start_link/1` is
  given `enabled: true`. Other options go to `UniversalProxy.Display.State`;
  `:viewport_supervisor` names the `DynamicSupervisor` for both and
  `:state_name` names State (tests use these to run beside the app's own).
  """

  use Supervisor

  @viewport_supervisor UniversalProxy.Display.ViewportSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start() | :ignore
  def start_link(opts \\ []) do
    {enabled?, opts} = Keyword.pop_lazy(opts, :enabled, &UniversalProxy.Display.enabled?/0)
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    if enabled? do
      Supervisor.start_link(__MODULE__, opts, name: name)
    else
      :ignore
    end
  end

  @doc "The default `DynamicSupervisor` the viewport runs under."
  @spec viewport_supervisor() :: atom()
  def viewport_supervisor, do: @viewport_supervisor

  @impl true
  def init(opts) do
    opts = Keyword.put_new(opts, :viewport_supervisor, @viewport_supervisor)
    {state_name, opts} = Keyword.pop(opts, :state_name, UniversalProxy.Display.State)

    children = [
      {DynamicSupervisor, name: opts[:viewport_supervisor], strategy: :one_for_one},
      {UniversalProxy.Display.State, Keyword.put(opts, :name, state_name)}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
