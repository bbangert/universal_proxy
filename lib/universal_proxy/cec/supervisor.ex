defmodule UniversalProxy.Cec.Supervisor do
  @moduledoc """
  HDMI-CEC subtree: a `DynamicSupervisor` for the per-adapter `cec-ctl -m`
  monitors plus the `UniversalProxy.Cec.Server` inventory.

  `:rest_for_one` so a Server restart re-creates its monitors from a clean
  slate (it re-discovers adapters on init). Returns `:ignore` unless the
  `UniversalProxy.Cec` env has `enabled: true` (set for targets, off on
  host/test), so a dev machine never spawns cec-ctl.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start() | :ignore
  def start_link(opts \\ []) do
    if enabled?() do
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

  @impl true
  def init(opts) do
    children = [
      {DynamicSupervisor, name: UniversalProxy.Cec.MonitorSupervisor, strategy: :one_for_one},
      {UniversalProxy.Cec.Server, opts}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
