defmodule UniversalProxy.TuyaMesh.Mesh do
  @moduledoc """
  The running mesh: `TuyaBeaconMesh.Radio` on the dedicated adapter, then
  `TuyaBeaconMesh.Lights` on the stored inventory. Started (and stopped)
  only by `UniversalProxy.TuyaMesh.Resolver`, as a `:temporary` child of
  its DynamicSupervisor.

  `:rest_for_one`: Lights holds a subscription inside the Radio, so a
  Radio restart restarts Lights too (Lights would resubscribe on its own,
  but only after its backoff). Lights reads its inventory through
  `Store.load/1` on every start and writes through `Store.persist/2`, so a
  restart resumes from the persisted `seq`; a Lights restart alone leaves
  the Radio running.
  An inventory that no longer validates makes Lights return `:ignore`,
  leaving the Radio idle.

  Radio's own child spec gives it a 10 s `shutdown` (its teardown makes
  blocking D-Bus and lease calls). Exceeding the restart budget stops this
  supervisor; the Resolver notices and tries again later, so a crashing
  mesh never escalates into the Bluez subtree.

  The Radio gets the role MAC as `:adapter_address`, so it refuses an
  adapter that took over the index (see `TuyaBeaconMesh.Radio`).

  Options: `:adapter_index` (required), `:adapter_address`, `:radio` and `:lights` (keyword
  lists merged over the defaults, for tests), `:name`.
  """

  use Supervisor

  alias UniversalProxy.TuyaBeaconMesh.{Lights, Radio}
  alias UniversalProxy.TuyaMesh.Store

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :temporary
    }
  end

  @impl Supervisor
  def init(opts) do
    index = Keyword.fetch!(opts, :adapter_index)

    radio =
      Keyword.merge(
        [adapter_index: index, adapter_address: Keyword.get(opts, :adapter_address), name: Radio],
        Keyword.get(opts, :radio, [])
      )

    lights =
      Keyword.merge(
        [
          inventory: &Store.load/0,
          on_persist: &Store.persist/1,
          radio: Keyword.fetch!(radio, :name),
          name: Lights
        ],
        Keyword.get(opts, :lights, [])
      )

    Supervisor.init([{Radio, radio}, {Lights, lights}],
      strategy: :rest_for_one,
      max_restarts: 5,
      max_seconds: 60
    )
  end
end
