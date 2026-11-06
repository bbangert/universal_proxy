defmodule UniversalProxy.MilkDrop.Supervisor do
  @moduledoc """
  MilkDrop's long-lived processes: `UniversalProxy.MilkDrop.Store` and
  `UniversalProxy.MilkDrop.Pack` (`:one_for_one`; neither calls the other).
  Pack shares a `:one_for_all` unit with the Task.Supervisor its download
  runs under, so a Pack crash stops a running download before the new
  Pack can start another on the same files.

  Returns `:ignore` unless `UniversalProxy.MilkDrop.enabled?/0` (a supported
  target with the `:milkdrop` flag on) or `start_link/1` is given
  `enabled: true`. `:store` and `:pack` are keyword opts passed to the
  children (tests use them to run beside the app's own tree).
  """

  use Supervisor

  alias UniversalProxy.MilkDrop

  @spec start_link(keyword()) :: Supervisor.on_start() | :ignore
  def start_link(opts \\ []) do
    {enabled?, opts} = Keyword.pop_lazy(opts, :enabled, &MilkDrop.enabled?/0)
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    if enabled? do
      Supervisor.start_link(__MODULE__, opts, name: name)
    else
      :ignore
    end
  end

  @impl true
  def init(opts) do
    children = [
      {MilkDrop.Store, Keyword.get(opts, :store, [])},
      pack_unit(Keyword.get(opts, :pack, []))
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # The installer writes `<version>.tar.gz.part`/`.tmp` and must not outlive
  # its Pack, so it is not fire-and-forget work for
  # `UniversalProxy.TaskSupervisor`: its own Task.Supervisor, started
  # first, is stopped (killing the download) whenever Pack dies.
  defp pack_unit(pack_opts) do
    {tasks, pack_opts} = Keyword.pop(pack_opts, :task_supervisor, MilkDrop.Pack.task_supervisor())

    children = [
      {Task.Supervisor, name: tasks},
      {MilkDrop.Pack, Keyword.put(pack_opts, :task_supervisor, tasks)}
    ]

    %{
      id: MilkDrop.Pack.Supervisor,
      type: :supervisor,
      start: {Supervisor, :start_link, [children, [strategy: :one_for_all]]}
    }
  end
end
