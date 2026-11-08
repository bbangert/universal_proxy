defmodule UniversalProxy.MilkDrop.Supervisor do
  @moduledoc """
  MilkDrop's long-lived processes (`:one_for_one`):
  `UniversalProxy.MilkDrop.UserPresets`, then
  `UniversalProxy.MilkDrop.Store` and `UniversalProxy.MilkDrop.Pack`.
  UserPresets starts first so the Store's start-up recovery can look up
  an upload's SHA-256 in its table (`UserPresets.sha256/2`, no call);
  UserPresets calls the Store (clean-up after a delete or replacement),
  its import task calls Pack (`status/0`, for the pack's texture names),
  and neither calls back. `UniversalProxy.MilkDrop.Index` starts last: it
  reads all three (each a `catch :exit` call) and subscribes to their
  broadcasts, and none of them calls it. UserPresets and Pack each share a `:one_for_all` unit with the
  Task.Supervisor their import or download runs under, so a crash stops
  that work before the restarted server touches the same files.

  Returns `:ignore` unless `UniversalProxy.MilkDrop.enabled?/0` (a supported
  target with the `:milkdrop` flag on) or `start_link/1` is given
  `enabled: true`. `:user_presets`, `:store`, `:pack` and `:index` are keyword opts
  passed to the children (tests use them to run beside the app's own
  tree).
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
      user_presets_unit(Keyword.get(opts, :user_presets, [])),
      {MilkDrop.Store, Keyword.get(opts, :store, [])},
      pack_unit(Keyword.get(opts, :pack, [])),
      {MilkDrop.Index, Keyword.get(opts, :index, [])}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # The installer writes `<version>.tar.gz.part`/`.tmp` and must not outlive
  # its Pack, so it is not fire-and-forget work for
  # `UniversalProxy.TaskSupervisor`: its own Task.Supervisor, started
  # first, is stopped (killing the download) whenever Pack dies.
  defp pack_unit(pack_opts),
    do: unit(MilkDrop.Pack, MilkDrop.Pack.Supervisor, pack_opts)

  # Likewise an import's task, which writes the staging directory a new
  # UserPresets deletes at start.
  defp user_presets_unit(opts),
    do: unit(MilkDrop.UserPresets, MilkDrop.UserPresets.Supervisor, opts)

  defp unit(server, id, opts) do
    {tasks, opts} = Keyword.pop(opts, :task_supervisor, server.task_supervisor())

    children = [
      {Task.Supervisor, name: tasks},
      {server, Keyword.put(opts, :task_supervisor, tasks)}
    ]

    %{
      id: id,
      type: :supervisor,
      start: {Supervisor, :start_link, [children, [strategy: :one_for_all]]}
    }
  end
end
