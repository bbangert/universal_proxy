defmodule UniversalProxy.Display.Supervisor do
  @moduledoc """
  HDMI display subtree: the `DynamicSupervisor` the viewport runs under, the
  `Task.Supervisor` the MilkDrop renderer's reaper runs under, and
  `UniversalProxy.Display.State`, which starts, watches and stops both.

  The viewport is a `:temporary` child, started by State, never restarted by
  the `DynamicSupervisor`. `:one_for_all` makes a State restart also take the
  viewport down, so the new State starts from a clean slate instead of
  inheriting a viewport (and its DRM lease) it doesn't monitor.

  The same goes for a MilkDrop renderer: State's restart first shuts the
  reaper's `Task.Supervisor` down, and its reaper SIGKILLs a renderer still
  running and waits until it is gone (`UniversalProxy.Display.MilkDrop`),
  so the new State never starts its viewport while the old renderer may
  still hold DRM master.

  Returns `:ignore` unless the `UniversalProxy.Display` env has
  `enabled: true` (config/target.exs, Pi HDMI targets) or `start_link/1` is
  given `enabled: true`. Other options go to `UniversalProxy.Display.State`;
  `:viewport_supervisor` and `:milkdrop_task_supervisor` name the
  supervisors for both and `:state_name` names State (tests use these to run
  beside the app's own).
  """

  use Supervisor

  @viewport_supervisor UniversalProxy.Display.ViewportSupervisor
  @milkdrop_task_supervisor UniversalProxy.Display.MilkDropTaskSupervisor

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

  @doc "The default `Task.Supervisor` the MilkDrop renderer's reaper runs under."
  @spec milkdrop_task_supervisor() :: atom()
  def milkdrop_task_supervisor, do: @milkdrop_task_supervisor

  @impl true
  def init(opts) do
    opts =
      opts
      |> Keyword.put_new(:viewport_supervisor, @viewport_supervisor)
      |> Keyword.put_new(:milkdrop_task_supervisor, @milkdrop_task_supervisor)

    {state_name, opts} = Keyword.pop(opts, :state_name, UniversalProxy.Display.State)

    # Started in this order and shut down in reverse: State, then the
    # reaper (the renderer gone), then the viewport supervisor.
    children = [
      {DynamicSupervisor, name: opts[:viewport_supervisor], strategy: :one_for_one},
      {Task.Supervisor, name: opts[:milkdrop_task_supervisor]},
      {UniversalProxy.Display.State, Keyword.put(opts, :name, state_name)}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
