defmodule UniversalProxy.MilkDrop.Supervisor do
  @moduledoc """
  MilkDrop's long-lived processes: `UniversalProxy.MilkDrop.Store` and
  `UniversalProxy.MilkDrop.Pack` (`:one_for_one`; neither calls the other).

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
      {MilkDrop.Pack, Keyword.get(opts, :pack, [])}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
