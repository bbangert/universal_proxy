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
  alias UniversalProxy.TuyaMesh
  alias UniversalProxy.TuyaMesh.{Entities, Store}

  @default_debounce_ms 1_000
  @default_retry_ms 1_000
  @max_retry_ms 30_000
  @default_check_ms 30_000
  @resubscribe_ms 1_000

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
            desired: nil,
            live: %{},
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
  `:on_collision`, `:debounce_ms`, `:retry_ms`, `:check_ms`, and the Espex
  seams `:update_device_config` (`(server, opts) -> :ok | {:error, _}`),
  `:disconnect_clients` (`(server) -> :ok`) and `:espex_devices`
  (`(server) -> [Device.t()]`).
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
      debounce_ms: Keyword.get(opts, :debounce_ms, @default_debounce_ms),
      retry_ms: retry_ms,
      check_ms: Keyword.get(opts, :check_ms, @default_check_ms),
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
    %{read(t, false) | live: read_live(t)}
  end

  @doc "The desired build's sub-devices."
  @spec devices(t()) :: [Device.t()]
  def devices(t), do: t.desired.devices

  @doc "The desired build's advertisements."
  @spec advertisements(t()) :: [struct()]
  def advertisements(t), do: Entities.advertisements(t.desired)

  @doc "Initial states of the desired build, from the latest live values."
  @spec state_responses(t()) :: [struct()]
  def state_responses(t), do: Entities.state_responses(t.desired, t.live)

  @doc "Entity key → target of the desired build."
  @spec keys(t()) :: %{non_neg_integer() => Entities.target()}
  def keys(t), do: t.desired.keys

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
    do: {:ok, %{t | live: Entities.live_from_status(status)}}

  def handle_info({:mesh_read, token}, %{read_timer: token} = t),
    do: {:ok, read(%{t | read_timer: nil}, true)}

  def handle_info({:mesh_apply, token}, %{apply_timer: token} = t),
    do: {:ok, apply_pending(%{t | apply_timer: nil})}

  def handle_info({:mesh_resubscribe, token}, %{sub_timer: token} = t),
    do: {:ok, ensure_subscribed(%{t | sub_timer: nil})}

  def handle_info(:mesh_check, t) do
    schedule_check(t)
    t = if t.subscribe?, do: ensure_subscribed(t), else: t
    {:ok, verify_applied(t)}
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
        t = %{t | read_backoff_ms: t.retry_ms}

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

  defp same?(a, b),
    do: a.devices == b.devices and Entities.advertisements(a) == Entities.advertisements(b)

  defp read_live(t) do
    t.sources.mesh_status.() |> Entities.live_from_status()
  rescue
    _e -> t.live
  catch
    :exit, _reason -> t.live
  end

  # ── Apply ────────────────────────────────────────────────────────────

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

  defp catch_up(t), do: %{arm_read(t, 0) | live: read_live(t)}
end
