defmodule UniversalProxy.TuyaMesh.Mesh do
  @moduledoc """
  The running mesh: `TuyaBeaconMesh.Radio` on the dedicated adapter, then
  `TuyaBeaconMesh.Lights` on the stored inventory, then the pinger
  `UniversalProxy.TuyaMesh.Presence`. Started (and stopped)
  only by `UniversalProxy.TuyaMesh.Resolver`, as a `:temporary` child of
  its DynamicSupervisor.

  `:rest_for_one`: Lights holds a subscription inside the Radio, so a
  Radio restart restarts Lights too (Lights would resubscribe on its own,
  but only after its backoff). Lights reads its inventory through
  `Store.load/1` on every start and writes through `Store.persist/2` (and,
  on a clean stop, `Store.tighten/3` as its `on_tighten`), so a
  restart resumes from the persisted `seq`; a Lights restart alone leaves
  the Radio running.
  An inventory that no longer validates makes Lights return `:ignore`,
  leaving the Radio idle.

  Presence comes last so that its crash restarts only itself, never Radio
  or Lights; a Radio or Lights restart restarts it too (its view of them
  is stale then). It shares this supervisor's restart budget, but every
  call it makes is wrapped, so only a bug can crash it.

  Radio's own child spec gives it a 10 s `shutdown` (its teardown makes
  blocking D-Bus and lease calls). Exceeding the restart budget stops this
  supervisor; the Resolver notices and tries again later, so a crashing
  mesh never escalates into the Bluez subtree.

  The Radio gets the role MAC as `:adapter_address`, so it refuses an
  adapter that took over the index (see `TuyaBeaconMesh.Radio`).

  The Radio's transport comes from the `:tuya_mesh_transport` app env:
  `:auto` (the default: the HCI user channel, falling back to BlueZ),
  `:user_channel` or `:bluez` (only that one; a debugging escape hatch).
  A `:transport` in the `:radio` options wins over it. A fallback is
  remembered for 10 min (`fallback_memory_ms`), so a mesh restarted
  meanwhile starts on BlueZ straight away.

  Options: `:adapter_index` (required), `:adapter_address`, `:radio`,
  `:lights` and `:presence` (keyword lists merged over the defaults; the
  Resolver passes `presence: [notify: self()]`), `:name`.
  """

  use Supervisor

  require Logger

  @fallback_memory_ms 600_000

  alias UniversalProxy.TuyaBeaconMesh.{Lights, Radio}
  alias UniversalProxy.TuyaBeaconMesh.Radio.Transport
  alias UniversalProxy.TuyaMesh.{Presence, Store}

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
        [
          adapter_index: index,
          adapter_address: Keyword.get(opts, :adapter_address),
          transport: transports(),
          # A fallback survives this subtree restarting the Radio, so it
          # can't loop through a failing user channel.
          fallback_memory_ms: @fallback_memory_ms,
          name: Radio
        ],
        Keyword.get(opts, :radio, [])
      )

    lights =
      Keyword.merge(
        [
          inventory: &Store.load/0,
          on_persist: &Store.persist/1,
          # A Lights without the seq lease ignores this option.
          on_tighten: &Store.tighten/2,
          # The Store's upload bound is derived from it.
          max_lease: Store.lights_max_lease(),
          radio: Keyword.fetch!(radio, :name),
          name: Lights
        ],
        Keyword.get(opts, :lights, [])
      )

    presence =
      Keyword.merge(
        [
          lights: Keyword.fetch!(lights, :name),
          radio: Keyword.fetch!(radio, :name),
          name: Presence
        ],
        Keyword.get(opts, :presence, [])
      )

    Supervisor.init([{Radio, radio}, {Lights, lights}, {Presence, presence}],
      strategy: :rest_for_one,
      max_restarts: 5,
      max_seconds: 60
    )
  end

  @doc false
  # The Radio's `:transport` for the `:tuya_mesh_transport` app env.
  @spec transports() :: [module()]
  def transports do
    case Application.get_env(:universal_proxy, :tuya_mesh_transport, :auto) do
      :auto ->
        [Transport.UserChannel, Transport.Bluez]

      :user_channel ->
        [Transport.UserChannel]

      :bluez ->
        [Transport.Bluez]

      other ->
        Logger.warning("TuyaMesh: unknown :tuya_mesh_transport #{inspect(other)}; using :auto")
        [Transport.UserChannel, Transport.Bluez]
    end
  end
end
