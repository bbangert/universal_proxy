defmodule UniversalProxy.Cec.Supervisor do
  @moduledoc """
  HDMI-CEC subtree: a `Registry` naming each `Circuits.CEC.Adapter` by its
  device path, the `DynamicSupervisor` the adapters run under, the
  `UniversalProxy.Cec.Server` that starts, watches and stops them, and the
  `UniversalProxy.Cec.VolumeLink` that ties HDMI outputs' volume to their
  receivers, with the `Task.Supervisor` its jobs run under.

  The Server owns the adapters' lifecycle (they are `:temporary` children,
  restarted by the Server, never by the `DynamicSupervisor`), so
  `:one_for_all` makes a Server restart also restart the adapters and their
  registry: the new Server rediscovers from a clean slate instead of
  inheriting adapters it doesn't monitor. Restarting an adapter keeps its
  logical-address claim, which is kernel adapter state, so this causes no
  bus traffic. VolumeLink holds no state it can't rebuild from the other
  two and the audio outputs, so it restarts with them.

  Returns `:ignore` unless the `UniversalProxy.Cec` env has `enabled: true`
  (config/target.exs) or `start_link/1` is given `enabled: true`.
  `volume_link:` takes the `UniversalProxy.Cec.VolumeLink` options, or
  `false` to leave it out. Other options go to `UniversalProxy.Cec.Server`.
  """

  use Supervisor

  @registry UniversalProxy.Cec.AdapterRegistry
  @adapter_supervisor UniversalProxy.Cec.AdapterSupervisor
  @task_supervisor UniversalProxy.Cec.TaskSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start() | :ignore
  def start_link(opts \\ []) do
    {enabled?, opts} = Keyword.pop_lazy(opts, :enabled, &enabled?/0)

    if enabled? do
      Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
    else
      :ignore
    end
  end

  @spec enabled?() :: boolean()
  def enabled? do
    :universal_proxy
    |> Application.get_env(UniversalProxy.Cec, [])
    |> Keyword.get(:enabled, false)
  end

  @doc "The registry adapters are named in, keyed by device path."
  @spec registry() :: atom()
  def registry, do: @registry

  @doc "The `DynamicSupervisor` adapters run under."
  @spec adapter_supervisor() :: atom()
  def adapter_supervisor, do: @adapter_supervisor

  @doc "The `Task.Supervisor` the volume link's jobs run under."
  @spec task_supervisor() :: atom()
  def task_supervisor, do: @task_supervisor

  @impl true
  def init(opts) do
    {volume_link, opts} = Keyword.pop(opts, :volume_link, [])

    # The volume link's runs and polls press keys and hold adapter calls
    # for the link that started them, so they live and die with the
    # subtree (not under the app-wide fire-and-forget TaskSupervisor).
    link =
      if volume_link == false,
        do: [],
        else: [
          {Task.Supervisor, name: @task_supervisor},
          {UniversalProxy.Cec.VolumeLink, volume_link}
        ]

    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @adapter_supervisor, strategy: :one_for_one},
      {UniversalProxy.Cec.Server, opts}
      | link
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
