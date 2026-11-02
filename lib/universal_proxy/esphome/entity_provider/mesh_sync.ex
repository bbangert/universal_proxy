defmodule UniversalProxy.ESPHome.EntityProvider.MeshSync do
  @moduledoc """
  The Tuya mesh half of `UniversalProxy.ESPHome.EntityProvider`: keeps the
  mesh's ESPHome sub-devices and entities (`UniversalProxy.TuyaMesh.Entities`)
  current, and Espex and Home Assistant in step with them. It is plain
  state the provider holds, fed the provider's messages (`handle_info/2`);
  it owns no process.

  ## Desired and applied

  `desired` is the latest build read from the Store, the mesh role and the
  mesh settings. It is what the provider advertises and what
  `ESPHome.Supervisor.start_espex/2` starts Espex with.

  Reads happen on the Store's `{:tuya_mesh_store, _}` and the Bluetooth
  Manager's `{:bluetooth_state, _}` broadcasts, debounced (`:debounce_ms`).
  A read that can't tell (`:unknown`: the Store or the Bluetooth settings
  down, an inventory that doesn't validate) keeps `desired` and is retried
  with backoff (`:retry_ms`, doubling to 30 s), so a recovered Store is
  caught up with even if it never broadcasts.

  A `desired` whose sub-devices or advertisements changed must be applied:
  `Espex.update_device_config(devices: ...)`, then `Espex.disconnect_clients/1`
  so Home Assistant reconnects and re-reads both. The two steps are pending
  work, each retried with backoff until it succeeds (an Espex that is down
  or mid-restart), and the reconnect runs once, after the update worked.

  Every `:check_ms` (30 s) the sub-devices Espex actually holds are compared
  with `desired`: an Espex that restarted on other ones (it read them just
  before a change, or fell back to its init-time ones) gets them applied.

  ## Never "no mesh" from not knowing

  Home Assistant deletes the sub-devices and entities a connection doesn't
  list, so a build that couldn't be read must never be advertised as an
  empty one. `source` says where `desired` came from: `:read` (this
  process read it), `:last_good` (inputs unreadable at start: the last
  build read in this boot, kept in `:persistent_term` per Espex server so
  it outlives provider and ESPHome restarts; it is only written when it
  changes), or `:none` (nothing known yet).

  With `:none`, `devices/1` is `{:error, :unknown}`, so Espex keeps the
  sub-devices `ESPHome.Supervisor.init/1` started it with
  (`boot_devices/1`, whose read is also kept as the last good build), and
  nothing is ever pushed to Espex or disconnected (the check tick only
  retries the read), and `advertisements/1` is `:defer` for up to
  `:defer_ms` (2 min) from start: the provider then refuses the connection
  and HA retries, rather than reconcile against a list without the mesh.
  After that window it advertises what it has (an inventory that can't be
  read for that long is a fault the user has to fix, and HA must not stay
  locked out of the device meanwhile). A stored inventory that stops
  validating is not this case: the Store serves its last key-free summary.

  ## Subscriptions

  The topics are held for as long as this runs, through PubSub restarts
  (same pattern as `UniversalProxy.TuyaMesh.Resolver`): the PubSub registry
  is monitored, a failed subscribe is retried every second, the check tick
  re-subscribes whatever is missing (never twice: `Registry.keys/2`), and
  every re-subscribe catches up with a fresh read and status snapshot, since
  whatever was broadcast meanwhile is lost. `:extra_topics` are held the
  same way for the provider (its firmware-progress topic). A subscription
  links the subscriber to the registry, so the provider traps exits while
  this holds its subscriptions; the registry's exit signals are ignored.
  """

  require Logger

  alias Espex.DeviceConfig.Device
  alias UniversalProxy.ESPHome.EntityProvider
  alias UniversalProxy.TuyaMesh
  alias UniversalProxy.TuyaMesh.{Entities, Store}

  @default_debounce_ms 1_000
  @default_retry_ms 1_000
  @max_retry_ms 30_000
  @default_check_ms 30_000
  @resubscribe_ms 1_000
  @default_defer_ms 120_000

  @type t :: %__MODULE__{}

  defstruct enabled?: false,
            subscribe?: true,
            server: Espex.Server,
            pubsub: UniversalProxy.PubSub,
            sources: %{},
            extra_topics: [],
            reserved_keys: [],
            on_collision: :skip,
            update_device_config: nil,
            disconnect_clients: nil,
            espex_devices: nil,
            debounce_ms: @default_debounce_ms,
            retry_ms: @default_retry_ms,
            check_ms: @default_check_ms,
            defer_ms: @default_defer_ms,
            defer_until: nil,
            desired: nil,
            source: :none,
            live: %{},
            status: nil,
            push: nil,
            pending: nil,
            read_timer: nil,
            read_backoff_ms: @default_retry_ms,
            apply_timer: nil,
            apply_backoff_ms: @default_retry_ms,
            sub_timer: nil,
            pubsub_mon: nil

  @doc """
  New state, nothing read or subscribed yet. `opts`: `:enabled?`,
  `:subscribe?`, `:server`, `:pubsub`, `:extra_topics`, `:sources` (`mesh_role`,
  `mesh_inventory`, `mesh_settings`, `mesh_status` funs), `:reserved_keys`,
  `:on_collision`, `:debounce_ms`, `:retry_ms`, `:check_ms`, `:defer_ms`, and the Espex
  seams `:update_device_config` (`(server, opts) -> :ok | {:error, _}`),
  `:disconnect_clients` (`(server) -> :ok`), `:espex_devices`
  (`(server) -> [Device.t()]`) and `:push` (`(server, struct) -> any`).
  Optional sources: `mesh_device_ids` (`-> Store.device_ids/1`),
  `mesh_light_states` (`-> [LightStateResponse]`, the Commander's) and
  `mesh_time_synced` (`-> boolean`).
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    retry_ms = Keyword.get(opts, :retry_ms, @default_retry_ms)

    %__MODULE__{
      enabled?: Keyword.get(opts, :enabled?, false),
      subscribe?: Keyword.get(opts, :subscribe?, true),
      server: Keyword.get(opts, :server, Espex.Server),
      pubsub: Keyword.get(opts, :pubsub, UniversalProxy.PubSub),
      sources: Keyword.get(opts, :sources, %{}),
      extra_topics: Keyword.get(opts, :extra_topics, []),
      reserved_keys: Keyword.get(opts, :reserved_keys, []),
      on_collision: Keyword.get(opts, :on_collision, :skip),
      update_device_config:
        Keyword.get(opts, :update_device_config, &Espex.update_device_config/2),
      disconnect_clients: Keyword.get(opts, :disconnect_clients, &Espex.disconnect_clients/1),
      espex_devices: Keyword.get(opts, :espex_devices, &espex_devices/1),
      push: Keyword.get(opts, :push, &push_state/2),
      debounce_ms: Keyword.get(opts, :debounce_ms, @default_debounce_ms),
      retry_ms: retry_ms,
      check_ms: Keyword.get(opts, :check_ms, @default_check_ms),
      defer_ms: Keyword.get(opts, :defer_ms, @default_defer_ms),
      desired: Entities.empty(),
      read_backoff_ms: retry_ms,
      apply_backoff_ms: retry_ms
    }
  end

  @doc """
  Subscribes, reads the mesh and the live values, and starts the check
  tick. Run before Espex starts: nothing is applied, since Espex is started
  with `devices/1`.
  """
  @spec start(t()) :: t()
  def start(%__MODULE__{enabled?: false} = t), do: t

  def start(t) do
    {t, _added} = if t.subscribe?, do: subscribe(t), else: {t, []}
    schedule_check(t)
    t = %{t | defer_until: now() + t.defer_ms}

    t =
      case read(t, false) do
        %{source: :none} = t -> seed_last_good(t)
        t -> t
      end

    read_live(t)
  end

  @doc """
  The desired build's sub-devices, or `{:error, :unknown}` when nothing is
  known yet (see the moduledoc).
  """
  @spec devices(t()) :: {:ok, [Device.t()]} | {:error, :unknown}
  def devices(%__MODULE__{enabled?: false}), do: {:ok, []}
  def devices(%{source: :none}), do: {:error, :unknown}
  def devices(t), do: {:ok, t.desired.devices}

  @doc """
  The desired build's advertisements, or `:defer` while nothing is known
  and the defer window is open (see the moduledoc).
  """
  @spec advertisements(t()) :: [struct()] | :defer
  def advertisements(%{enabled?: true, source: :none} = t) do
    if now() < t.defer_until, do: :defer, else: Entities.advertisements(t.desired)
  end

  def advertisements(t), do: Entities.advertisements(t.desired)

  @doc """
  The sub-devices to start Espex with before any provider runs: a fresh
  read (kept as the last good build), else the last good build of this
  boot (`[]` if none). `sources` as for
  `UniversalProxy.TuyaMesh.Entities.read/2`.
  """
  @spec boot_devices(GenServer.server(), map()) :: [Device.t()]
  def boot_devices(server \\ Espex.Server, sources \\ %{}) do
    case Entities.read(sources, EntityProvider.mesh_build_opts()) do
      {:ok, build} ->
        # Also the provider's last good build: one that then finds its
        # inputs unreadable advertises what Espex was started with.
        put_last_good(server, build)
        build.devices

      :unknown ->
        case last_good(server) do
          nil -> []
          build -> build.devices
        end
    end
  end

  @doc """
  Initial states of the desired build: connectivity and last seen from
  the latest live values, lights as the Commander last pushed them (only
  those of a current light entity, same key and sub-device).
  """
  @spec state_responses(t()) :: [struct()]
  def state_responses(t),
    do: Entities.state_responses(t.desired, t.live) ++ light_states(t)

  defp light_states(t) do
    lights = for %{type: :light} = e <- t.desired.entities, into: %{}, do: {e.key, e.device_id}

    for %{key: key, device_id: id} = response <- source(t, :mesh_light_states, [], []),
        Map.get(lights, key) == id,
        do: response
  end

  @doc "Entity key → target of the desired build."
  @spec keys(t()) :: %{non_neg_integer() => Entities.target()}
  def keys(t), do: t.desired.keys

  @doc "The desired build's entity with `key`, or `nil`."
  @spec entity(t(), non_neg_integer()) :: Entities.entity() | nil
  def entity(t, key), do: Enum.find(t.desired.entities, &(&1.key == key))

  @doc "The desired build's mesh settings."
  @spec settings(t()) :: Store.settings()
  def settings(t), do: t.desired.settings

  @doc """
  Handles a provider message: `{:ok, t}` when it was one of ours,
  `:unhandled` otherwise.
  """
  @spec handle_info(term(), t()) :: {:ok, t()} | :unhandled
  def handle_info(_msg, %__MODULE__{enabled?: false}), do: :unhandled

  # The registry's exit signals, trapped (see "Subscriptions"): its :DOWN
  # drives the re-subscribe.
  def handle_info({:EXIT, _pid, _reason}, %{subscribe?: true} = t), do: {:ok, t}

  def handle_info({:tuya_mesh_store, _event}, t), do: {:ok, arm_read(t, t.debounce_ms)}
  def handle_info({:bluetooth_state, _status}, t), do: {:ok, arm_read(t, t.debounce_ms)}

  def handle_info({:tuya_mesh_status, status}, t),
    do: {:ok, refresh_live(%{t | status: status})}

  def handle_info({:mesh_read, token}, %{read_timer: token} = t),
    do: {:ok, read(%{t | read_timer: nil}, true)}

  def handle_info({:mesh_apply, token}, %{apply_timer: token} = t),
    do: {:ok, apply_pending(%{t | apply_timer: nil})}

  def handle_info({:mesh_resubscribe, token}, %{sub_timer: token} = t),
    do: {:ok, ensure_subscribed(%{t | sub_timer: nil})}

  # The tick also re-derives the live values, so last seen appears once
  # the clock has synchronised even with no new status.
  def handle_info(:mesh_check, t) do
    schedule_check(t)
    t = if t.subscribe?, do: ensure_subscribed(t), else: t
    {:ok, t |> verify_applied() |> refresh_live()}
  end

  def handle_info({:DOWN, mon, :process, _pid, _reason}, %{pubsub_mon: {_pid2, mon}} = t),
    do: {:ok, ensure_subscribed(%{t | pubsub_mon: nil})}

  # Stale timer tokens.
  def handle_info({tag, _token}, t) when tag in [:mesh_read, :mesh_apply, :mesh_resubscribe],
    do: {:ok, t}

  def handle_info(_msg, _t), do: :unhandled

  # ── Read ─────────────────────────────────────────────────────────────

  defp arm_read(%{read_timer: token} = t, _delay) when is_reference(token), do: t

  defp arm_read(t, delay) do
    token = make_ref()
    Process.send_after(self(), {:mesh_read, token}, delay)
    %{t | read_timer: token}
  end

  # `apply?` is false only for the read before Espex starts.
  defp read(t, apply?) do
    case Entities.read(
           %{
             supported?: true,
             role: t.sources.mesh_role,
             inventory: t.sources.mesh_inventory,
             settings: t.sources.mesh_settings
           },
           reserved_keys: t.reserved_keys,
           on_collision: t.on_collision
         ) do
      {:ok, build} ->
        t = %{t | read_backoff_ms: t.retry_ms, source: :read}
        put_last_good(t.server, build)

        cond do
          same?(build, t.desired) -> t
          apply? -> apply_pending(%{t | desired: build, pending: :update})
          true -> %{t | desired: build}
        end

      :unknown ->
        Logger.debug("EntityProvider: Tuya mesh inputs unreadable; retrying")

        %{arm_read(t, t.read_backoff_ms) | read_backoff_ms: backoff(t.read_backoff_ms)}
    end
  end

  defp last_good_key(server), do: {__MODULE__, :last_good, server}

  defp last_good(server), do: :persistent_term.get(last_good_key(server), nil)

  # A persistent_term write costs a global GC pass when it replaces a term:
  # only when the build changed.
  defp put_last_good(server, build) do
    if last_good(server) != build, do: :persistent_term.put(last_good_key(server), build)
    :ok
  end

  defp seed_last_good(t) do
    case last_good(t.server) do
      nil ->
        Logger.warning(
          "EntityProvider: Tuya mesh unknown at start; deferring Home Assistant connections"
        )

        t

      build ->
        Logger.info("EntityProvider: Tuya mesh unknown at start; advertising the last good one")
        %{t | desired: build, source: :last_good}
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp same?(a, b),
    do: a.devices == b.devices and Entities.advertisements(a) == Entities.advertisements(b)

  # Without pushing: before Espex runs, or a catch-up whose values the
  # next status pushes anyway.
  defp read_live(t) do
    status = t.sources.mesh_status.()
    %{t | status: status, live: live_of(t, status)}
  rescue
    _e -> t
  catch
    :exit, _reason -> t
  end

  # ── Live values ──────────────────────────────────────────────────────

  # Last seen is hidden (missing_state) until the clock has synchronised:
  # a pre-sync wall clock would show 1970.
  defp live_of(t, status) do
    live = Entities.live_from_status(status)

    if source(t, :mesh_time_synced, [], &time_synced?/0),
      do: live,
      else: Map.new(live, fn {mac, v} -> {mac, %{v | last_seen: nil}} end)
  end

  # Pushes the connectivity and last-seen states that changed, each for
  # its bulb's current sub-device only.
  defp refresh_live(%{status: nil} = t), do: t

  defp refresh_live(t) do
    live = live_of(t, t.status)
    changed = for {mac, v} <- live, Map.get(t.live, mac) != v, do: mac

    if changed != [] and t.source != :none do
      ids = source(t, :mesh_device_ids, [], &Store.device_ids/0)

      entities =
        for %{target: {:bulb, mac, kind}} = e <- t.desired.entities,
            kind in [:connectivity, :last_seen],
            mac in changed,
            Map.get(ids, {:bulb, mac}) == e.device_id,
            do: e

      for response <- Entities.state_responses(%{t.desired | entities: entities}, live),
          do: t.push.(t.server, response)
    end

    %{t | live: live}
  end

  @doc """
  Whether the wall clock has synchronised (`NervesTime.synchronized?/0`);
  `true` where NervesTime isn't there (host builds).
  """
  @spec time_synced?() :: boolean()
  def time_synced? do
    # Built at runtime: NervesTime is a target-only dependency.
    nerves_time = Module.concat(["NervesTime"])

    if Code.ensure_loaded?(nerves_time) and function_exported?(nerves_time, :synchronized?, 0),
      do: nerves_time.synchronized?() == true,
      else: true
  end

  # An optional source: its value, else `default` (a value, or a fun to call).
  defp source(t, key, args, default) do
    fun = Map.get(t.sources, key) || default
    if is_function(fun), do: apply(fun, args), else: fun
  rescue
    _e -> if is_function(default), do: apply(default, args), else: default
  catch
    :exit, _reason -> if is_function(default), do: apply(default, args), else: default
  end

  # Espex's registry raises when it isn't started.
  defp push_state(server, struct) do
    Espex.push_state(server, struct)
  rescue
    ArgumentError -> :ok
  end

  # ── Apply ────────────────────────────────────────────────────────────

  # Only a build that was read (or the last good one) is ever pushed: an
  # unknown one is a placeholder, and pushing it would make HA delete the
  # mesh Espex still holds.
  defp apply_pending(%{source: :none} = t), do: t
  defp apply_pending(%{pending: nil} = t), do: t

  defp apply_pending(%{pending: :update} = t) do
    Logger.info("EntityProvider: Tuya mesh entities changed; updating Home Assistant")

    case espex(fn -> t.update_device_config.(t.server, devices: t.desired.devices) end) do
      :ok ->
        apply_pending(%{t | pending: :reconnect})

      error ->
        Logger.debug(
          "EntityProvider: mesh sub-device update failed (#{inspect(error)}); retrying"
        )

        retry_apply(t)
    end
  end

  defp apply_pending(%{pending: :reconnect} = t) do
    case espex(fn -> t.disconnect_clients.(t.server) end) do
      :ok ->
        %{t | pending: nil, apply_timer: nil, apply_backoff_ms: t.retry_ms}

      error ->
        Logger.debug(
          "EntityProvider: Home Assistant reconnect failed (#{inspect(error)}); retrying"
        )

        retry_apply(t)
    end
  end

  defp retry_apply(%{apply_timer: token} = t) when is_reference(token), do: t

  defp retry_apply(t) do
    token = make_ref()
    Process.send_after(self(), {:mesh_apply, token}, t.apply_backoff_ms)
    %{t | apply_timer: token, apply_backoff_ms: backoff(t.apply_backoff_ms)}
  end

  # Unknown: nothing to compare Espex with; only the read is retried.
  defp verify_applied(%{source: :none} = t), do: arm_read(t, t.read_backoff_ms)

  # An Espex that started on other sub-devices than `desired`.
  defp verify_applied(%{pending: nil} = t) do
    case espex(fn -> t.espex_devices.(t.server) end) do
      devices when is_list(devices) and devices != t.desired.devices ->
        Logger.info("EntityProvider: Espex holds other Tuya mesh sub-devices; updating")
        apply_pending(%{t | pending: :update})

      _same_or_down ->
        t
    end
  end

  defp verify_applied(t), do: t

  # Espex down or restarting: a call exits, its registry raises.
  defp espex(fun) do
    fun.()
  rescue
    ArgumentError -> {:error, :not_running}
  catch
    :exit, _reason -> {:error, :not_running}
  end

  defp espex_devices(server), do: Espex.Server.device_config(server).devices

  defp backoff(ms), do: min(ms * 2, @max_retry_ms)

  defp schedule_check(t), do: Process.send_after(self(), :mesh_check, t.check_ms)

  # ── Subscriptions ────────────────────────────────────────────────────

  defp topics(t),
    do: [Store.topic(), TuyaMesh.topic(), UniversalProxy.Bluetooth.state_topic() | t.extra_topics]

  defp ensure_subscribed(t) do
    case subscribe(t) do
      {t, []} -> t
      {t, _added} -> catch_up(t)
    end
  end

  # The topics it (re)subscribed to come back alongside the state.
  defp subscribe(t) do
    case subscribe_topics(t.pubsub, topics(t)) do
      {:ok, added} ->
        {monitor_pubsub(%{t | sub_timer: nil}), added}

      :error ->
        {arm_resubscribe(t), []}
    end
  end

  defp arm_resubscribe(%{sub_timer: token} = t) when is_reference(token), do: t

  defp arm_resubscribe(t) do
    token = make_ref()
    Process.send_after(self(), {:mesh_resubscribe, token}, @resubscribe_ms)
    %{t | sub_timer: token}
  end

  # Registry raises ArgumentError when it isn't running. Topics already held
  # are skipped: the registry is :duplicate and would deliver twice.
  defp subscribe_topics(pubsub, topics) do
    held = Registry.keys(pubsub, self())

    added =
      for topic <- topics, topic not in held do
        :ok = Phoenix.PubSub.subscribe(pubsub, topic)
        topic
      end

    {:ok, added}
  rescue
    ArgumentError -> :error
  end

  defp monitor_pubsub(t) do
    case {GenServer.whereis(t.pubsub), t.pubsub_mon} do
      {pid, {pid, _mon}} ->
        t

      {pid, previous} when is_pid(pid) ->
        with {_old, mon} <- previous, do: Process.demonitor(mon, [:flush])
        %{t | pubsub_mon: {pid, Process.monitor(pid)}}

      _none ->
        t
    end
  end

  defp catch_up(t), do: t |> arm_read(0) |> read_live()
end
