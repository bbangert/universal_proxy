defmodule UniversalProxy.Cec.Server do
  @moduledoc """
  Owns the HDMI-CEC adapter inventory.

  Every `UniversalProxy.Cec.Enumerate` scan (10 s by default) starts a
  `Circuits.CEC.Adapter` for each new `/dev/cecN` and stops the adapters
  whose device went away. Each adapter claims a Playback logical address and
  acts as the CEC follower by itself; the Server subscribes to it and keeps a
  record of what is known about the adapter and about the receiver on the
  far end of its HDMI link.

  Commands (`UniversalProxy.Cec.one_touch_play/2` and friends) go straight
  to the adapter through `UniversalProxy.Cec.Supervisor.registry/0`, so a
  slow receiver never blocks this server or the hotplug scan.

  ## Auto-wake

  Subscribed to the Sendspin state topic: a `stream_start` on an output
  whose ALSA card is paired with an adapter runs One Touch Play on it (Image
  View On, then Active Source), waking a receiver in standby and switching
  it to the Pi's input before audio reaches the link. Each output's
  `cec_auto_wake` setting (`UniversalProxy.Audio.update_config/2`) turns it
  on or off for that output; an output that has none follows `auto_wake` in
  the `UniversalProxy.Cec` env (default `true`).

  ## The receiver

  Commands address the receiver (`:receiver_la`, default 5), or the TV
  (logical address 0) once the adapter has found no device at that address
  or when `:receiver_la` is `nil`; the record's `receiver_target` is the
  address in use. Power and audio status are recorded only when they come from that device:
  a TV answering a power query reports its own state. A broadcast
  `<Standby>` puts every device in standby; a directed one counts only when
  it comes from the receiver.

  ## The TV

  Each adapter polls the TV (logical address 0) when it becomes
  configured; `UniversalProxy.Cec.TvPresence` turns those and the rechecks
  this server schedules into the record's `tv_presence` (`:present`,
  `:absent` or `:unknown`, with a 2-NACK rule). `tv_presence: false` turns
  the polling off; `:tv_timings` overrides the reducer's delays.

  ## Remote keys

  `claim_keys/2` routes the TV remote's keys on one adapter to a process
  as `{:cec_key, dev, key}` (see `UniversalProxy.Cec.Keys`). The server
  subscribes to the adapter with `handle: [:user_control_pressed, :play,
  :deck_control]`, so the adapter stops Feature-Aborting them, and
  re-subscribes that way whenever the adapter restarts. When the claimer
  exits or calls `release_keys/1`, the subscription drops the handles and
  the adapter answers those opcodes with `<Feature Abort>` again. Only keys
  sent to our logical address count, and only one process holds an
  adapter's keys: a new claim replaces the previous one.

  ## Adapter lifecycle

  Adapters are `:temporary` children of the `DynamicSupervisor`, named in
  the `Registry` by device path and monitored here, so a scan can never
  race the `DynamicSupervisor` into starting a second adapter under the
  same name. One that crashes is restarted after a per-device backoff:
  `:restart_ms` (1 s), doubling on each further crash up to
  `:restart_max_ms` (5 min), and forgotten once the adapter has stayed up
  for `:stable_ms` (60 s). A crash is logged the first time, when its
  reason changes and on each retry at the cap; the record's `backoff`
  shows the crash count, current delay and last reason. One that stopped
  because its device went away or couldn't be opened is started again by
  the next scan that still lists the device.

  Every adapter event is re-broadcast on `topic/0` as
  `{:cec_event, dev, event}` (the events are described in
  `Circuits.CEC.Adapter`), and whenever a record changes the whole
  `list_adapters/0` result follows as `{:cec_adapters, adapters}`.

  Dependencies are injectable through `start_link/1` options so host tests
  run without sysfs or `/dev/cecN`: `:enumerate` (a 0-arity fun),
  `:output_lookup` (output key -> `{:ok, %{card_index: n}}`), `:transport`
  and `:transport_opts` (a keyword list, or a fun from device path to one),
  `:pubsub` and `:task_supervisor`. The `UniversalProxy.Cec` env keys can be
  given as options too.
  """

  use GenServer

  require Logger

  alias Circuits.CEC.{Adapter, Message}
  alias UniversalProxy.Cec.{Enumerate, Keys, TvPresence}
  alias UniversalProxy.Cec.Supervisor, as: CecSupervisor

  @pubsub UniversalProxy.PubSub
  @audio_topic "sendspin:state"
  @events_topic "cec:events"
  @default_scan_ms 10_000
  @default_restart_ms 1_000
  @default_restart_max_ms 300_000
  @default_stable_ms 60_000
  @default_osd_name "UniversalProxy"
  @tv 0
  @unknown_receiver %{power: :unknown, volume: nil, muted: nil, updated_at: nil}
  @key_opcodes [:user_control_pressed, :play, :deck_control]

  @type power :: :on | :standby | :to_on | :to_standby | :unknown

  @type receiver :: %{
          power: power(),
          volume: 0..100 | nil,
          muted: boolean() | nil,
          updated_at: DateTime.t() | nil
        }

  @type adapter :: %{
          dev: String.t(),
          index: non_neg_integer(),
          hdmi_device: String.t() | nil,
          card_index: non_neg_integer() | nil,
          running?: boolean(),
          phys_addr: String.t() | nil,
          logical_address: 0..15 | nil,
          configured?: boolean(),
          active_source?: boolean(),
          receiver_presence: :present | :absent | :unknown,
          tv_presence: TvPresence.presence(),
          receiver_target: 0..15,
          receiver: receiver(),
          backoff: backoff() | nil
        }

  @type backoff :: %{crashes: pos_integer(), retry_in_ms: pos_integer(), reason: term()}

  defstruct adapters: %{},
            procs: %{},
            errors: %{},
            versions: %{},
            restart_timers: %{},
            key_handlers: %{},
            held_keys: %{},
            tv: %{},
            tv_timers: %{},
            tv_enabled: true,
            tv_timings: %{},
            enumerate: nil,
            output_lookup: nil,
            transport: Circuits.CEC.Transport.Port,
            transport_opts: [],
            osd_name: @default_osd_name,
            auto_wake: true,
            receiver_la: 5,
            system_audio_mode: false,
            scan_ms: @default_scan_ms,
            restart_ms: @default_restart_ms,
            restart_max_ms: @default_restart_max_ms,
            stable_ms: @default_stable_ms,
            pubsub: @pubsub,
            task_sup: UniversalProxy.TaskSupervisor

  # ── API ───────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "PubSub topic adapter events are re-broadcast on."
  @spec topic() :: String.t()
  def topic, do: @events_topic

  @spec list_adapters() :: [adapter()]
  def list_adapters, do: GenServer.call(__MODULE__, :list_adapters)

  @spec get_adapter(String.t()) :: {:ok, adapter()} | :error
  def get_adapter(dev), do: GenServer.call(__MODULE__, {:get_adapter, dev})

  @doc "Adapter paired with an ALSA card index (via the shared HDMI sysfs node)."
  @spec adapter_for_card(non_neg_integer()) :: {:ok, adapter()} | :error
  def adapter_for_card(card_index),
    do: GenServer.call(__MODULE__, {:adapter_for_card, card_index})

  @doc """
  The receiver's power version: it changes whenever the receiver reports
  its power state (including a `<Standby>` it sends) or the cache is
  cleared, but not on audio reports. Read it before a command whose power
  outcome goes to `note_receiver/4`.
  """
  @spec receiver_version(String.t()) :: non_neg_integer()
  def receiver_version(dev), do: GenServer.call(__MODULE__, {:receiver_version, dev})

  @doc """
  Record what a command delivered to `to` did to the far end. Applied only
  when `to` is the receiver right now (`:receiver`, or its logical address)
  or a broadcast, and when no power report or cache clear has happened
  since `version` (`receiver_version/1` before the command): the command's
  result reaches this server after the adapter's own events, so a newer
  power report wins.
  """
  @spec note_receiver(String.t(), Adapter.target(), non_neg_integer(), map()) :: :ok
  def note_receiver(dev, to, version, partial) when is_map(partial),
    do: GenServer.cast(__MODULE__, {:note_receiver, dev, to, version, partial})

  @doc """
  Sends the TV remote's keys on `dev` to `pid` as `{:cec_key, dev, key}`
  until `pid` exits or `release_keys/1`. Idempotent; replaces another
  process's claim. See "Remote keys" above.
  """
  @spec claim_keys(String.t(), pid()) :: :ok
  def claim_keys(dev, pid) when is_binary(dev) and is_pid(pid),
    do: GenServer.cast(__MODULE__, {:claim_keys, dev, pid})

  @doc "Drops the key claim on `dev`; the adapter Feature-Aborts the keys again."
  @spec release_keys(String.t()) :: :ok
  def release_keys(dev) when is_binary(dev), do: GenServer.cast(__MODULE__, {:release_keys, dev})

  @doc "Re-run discovery now (tests, or after a manual cable swap)."
  @spec rescan() :: :ok
  def rescan, do: GenServer.call(__MODULE__, :rescan)

  # ── GenServer ─────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    env = Application.get_env(:universal_proxy, UniversalProxy.Cec, [])
    get = fn key, default -> Keyword.get(opts, key, Keyword.get(env, key, default)) end

    state = %__MODULE__{
      enumerate: Keyword.get(opts, :enumerate, &Enumerate.list/0),
      output_lookup: Keyword.get(opts, :output_lookup, &UniversalProxy.Audio.get_output/1),
      transport: get.(:transport, Circuits.CEC.Transport.Port),
      transport_opts: get.(:transport_opts, []),
      osd_name: get.(:osd_name, @default_osd_name),
      auto_wake: get.(:auto_wake, true),
      receiver_la: get.(:receiver_la, 5),
      system_audio_mode: get.(:system_audio_mode, false),
      scan_ms: get.(:scan_interval_ms, @default_scan_ms),
      restart_ms: get.(:restart_ms, @default_restart_ms),
      restart_max_ms: get.(:restart_max_ms, @default_restart_max_ms),
      stable_ms: get.(:stable_ms, @default_stable_ms),
      tv_enabled: get.(:tv_presence, true),
      tv_timings: get.(:tv_timings, %{}),
      pubsub: Keyword.get(opts, :pubsub, @pubsub),
      task_sup: Keyword.get(opts, :task_supervisor, UniversalProxy.TaskSupervisor)
    }

    Phoenix.PubSub.subscribe(state.pubsub, @audio_topic)
    send(self(), :scan)
    {:ok, state}
  end

  @impl true
  def handle_call(:list_adapters, _from, state) do
    {:reply, sorted_adapters(state), state}
  end

  def handle_call({:get_adapter, dev}, _from, state),
    do: {:reply, Map.fetch(state.adapters, dev), state}

  def handle_call({:adapter_for_card, card_index}, _from, state),
    do: {:reply, find_by_card(state, card_index), state}

  def handle_call(:rescan, _from, state), do: {:reply, :ok, state |> scan() |> publish(state)}

  def handle_call({:receiver_version, dev}, _from, state),
    do: {:reply, Map.get(state.versions, dev, 0), state}

  @impl true
  def handle_cast({:claim_keys, dev, pid}, state) do
    case Map.get(state.key_handlers, dev) do
      %{pid: ^pid} ->
        {:noreply, state}

      previous ->
        if previous, do: Process.demonitor(previous.ref, [:flush])
        handler = %{pid: pid, ref: Process.monitor(pid)}
        state = %{state | key_handlers: Map.put(state.key_handlers, dev, handler)}
        {:noreply, state |> reset_keys(dev) |> apply_handles(dev)}
    end
  end

  def handle_cast({:release_keys, dev}, state) do
    case Map.pop(state.key_handlers, dev) do
      {nil, _handlers} ->
        {:noreply, state}

      {handler, handlers} ->
        Process.demonitor(handler.ref, [:flush])
        state = %{state | key_handlers: handlers}
        {:noreply, state |> reset_keys(dev) |> apply_handles(dev)}
    end
  end

  def handle_cast({:note_receiver, dev, to, version, partial}, state) do
    case Map.fetch(state.adapters, dev) do
      {:ok, adapter} ->
        if version == Map.get(state.versions, dev, 0) and
             reaches_receiver?(to, receiver_target(state, adapter)),
           do: {:noreply, state |> update_receiver(dev, partial) |> publish(state)},
           else: {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:scan, state) do
    Process.send_after(self(), :scan, state.scan_ms)
    {:noreply, state |> scan() |> publish(state)}
  end

  # A Sendspin stream starting on an HDMI output: wake + select the receiver.
  def handle_info({:sendspin_state, key, %{event: "stream_start"}}, state) do
    auto_wake(state, key)
    {:noreply, state}
  end

  def handle_info({:sendspin_state, _key, _event}, state), do: {:noreply, state}

  def handle_info({:cec, dev, event}, state) do
    new_state = state |> deliver_key(dev, event) |> apply_event(dev, event)
    Phoenix.PubSub.broadcast(state.pubsub, @events_topic, {:cec_event, dev, event})
    {:noreply, publish(new_state, state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state.procs, fn {_dev, {_pid, r}} -> r == ref end) do
      nil -> {:noreply, key_handler_down(state, ref)}
      {dev, _proc} -> {:noreply, state |> adapter_down(dev, reason) |> publish(state)}
    end
  end

  def handle_info({:tv_recheck, dev, token}, state) do
    case state.tv_timers do
      %{^dev => {_timer, ^token}} ->
        state = %{state | tv_timers: Map.delete(state.tv_timers, dev)}
        {:noreply, state |> tv_step(dev, &TvPresence.recheck/1) |> publish(state)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:restart, dev}, state) do
    state = %{state | restart_timers: Map.delete(state.restart_timers, dev)}

    if Map.has_key?(state.adapters, dev),
      do: {:noreply, state |> ensure_started(dev) |> publish(state)},
      else: {:noreply, state}
  end

  # Up for :stable_ms since it started: earlier crashes no longer count.
  def handle_info({:stable, dev, pid}, state) do
    case state.procs do
      %{^dev => {^pid, _ref}} ->
        {:noreply, state |> update_adapter(dev, &%{&1 | backoff: nil}) |> publish(state)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ── discovery ─────────────────────────────────────────────────────────

  defp scan(state) do
    present = safe_enumerate(state)

    removed = Map.keys(state.adapters) -- Map.keys(present)
    state = Enum.reduce(removed, state, &remove_adapter(&2, &1))

    Enum.reduce(present, state, fn {dev, info}, acc ->
      acc =
        case Map.fetch(acc.adapters, dev) do
          {:ok, existing} ->
            # Keep what we learned; refresh the sysfs-derived pairing.
            put_adapter(acc, %{
              existing
              | hdmi_device: info.hdmi_device,
                card_index: info.card_index
            })

          :error ->
            Logger.info(
              "CEC: found #{dev} (#{info.hdmi_device || "?"}, card #{inspect(info.card_index)})"
            )

            put_adapter(acc, new_record(info))
        end

      ensure_started(acc, dev)
    end)
  end

  defp safe_enumerate(state) do
    state.enumerate.()
  rescue
    e ->
      Logger.warning("CEC enumerate raised: #{Exception.message(e)}")
      %{}
  end

  defp new_record(info) do
    Map.merge(info, %{
      running?: false,
      phys_addr: nil,
      logical_address: nil,
      configured?: false,
      active_source?: false,
      receiver_presence: :unknown,
      tv_presence: :unknown,
      receiver: @unknown_receiver,
      backoff: nil
    })
  end

  # A device waiting out a crash backoff isn't started early by a scan.
  defp ensure_started(state, dev) do
    if Map.has_key?(state.procs, dev) or Map.has_key?(state.restart_timers, dev),
      do: state,
      else: start_adapter(state, dev)
  end

  defp start_adapter(state, dev) do
    opts = [
      device: dev,
      name: {:via, Registry, {CecSupervisor.registry(), dev}},
      transport: state.transport,
      transport_opts: transport_opts(state, dev),
      osd_name: state.osd_name,
      power_status: :on,
      receiver_la: state.receiver_la,
      system_audio_mode: state.system_audio_mode,
      tv_poll: state.tv_enabled
    ]

    spec = Supervisor.child_spec({Adapter, opts}, restart: :temporary)

    case DynamicSupervisor.start_child(CecSupervisor.adapter_supervisor(), spec) do
      {:ok, pid} -> attach(state, dev, pid)
      {:error, {:already_started, pid}} -> attach(state, dev, pid)
      {:error, reason} -> start_failed(state, dev, reason)
    end
  end

  defp transport_opts(%{transport_opts: fun}, dev) when is_function(fun, 1), do: fun.(dev)
  defp transport_opts(%{transport_opts: opts}, _dev), do: opts

  # A device that keeps failing to open is retried every scan; log only
  # when the reason changes.
  defp start_failed(state, dev, reason) do
    if Map.get(state.errors, dev) != reason do
      Logger.warning("CEC: adapter for #{dev} not started: #{inspect(reason)}")
    end

    %{state | errors: Map.put(state.errors, dev, reason)}
  end

  # The adapter may have emitted its state before we subscribed, so seed
  # the record from `info/1`. If it dies meanwhile, the DOWN cleans up.
  # Subscribing with the key handles re-applies a key claim to a restarted
  # adapter.
  defp attach(state, dev, pid) do
    ref = Process.monitor(pid)

    state = %{
      state
      | procs: Map.put(state.procs, dev, {pid, ref}),
        errors: Map.delete(state.errors, dev)
    }

    state = update_adapter(state, dev, &%{&1 | running?: true})
    Process.send_after(self(), {:stable, dev, pid}, state.stable_ms)

    try do
      :ok = Adapter.subscribe(pid, handle: handles_for(state, dev))
      info = Adapter.info(pid)

      state
      |> update_link(dev, &apply_summary(&1, info))
      |> tv_step(dev, &TvPresence.link(&1, info.configured?, info.phys_addr))
    catch
      :exit, _ -> state
    end
  end

  defp adapter_down(state, dev, reason) do
    state = %{state | procs: Map.delete(state.procs, dev)}

    state =
      if crash?(reason) do
        schedule_restart(state, dev, reason)
      else
        Logger.info("CEC: adapter #{dev} stopped (#{inspect(reason)})")
        state
      end

    state
    |> reset_keys(dev)
    |> update_link(dev, fn adapter ->
      %{
        adapter
        | running?: false,
          phys_addr: nil,
          logical_address: nil,
          configured?: false,
          active_source?: false,
          receiver_presence: :unknown
      }
    end)
    |> tv_step(dev, &TvPresence.link(&1, false, nil))
  end

  defp schedule_restart(state, dev, reason) do
    prev = state.adapters |> Map.get(dev, %{}) |> Map.get(:backoff)
    key = crash_key(reason)

    backoff =
      case prev do
        nil -> %{crashes: 1, retry_in_ms: state.restart_ms, reason: key}
        %{} -> next_backoff(prev, key, state.restart_max_ms)
      end

    cond do
      prev == nil or prev.reason != key ->
        Logger.warning(
          "CEC: adapter #{dev} crashed (#{inspect(reason)}); restarting in #{backoff.retry_in_ms} ms"
        )

      backoff.retry_in_ms >= state.restart_max_ms ->
        Logger.warning(
          "CEC: adapter #{dev} still crashing (#{backoff.crashes} times, last " <>
            "#{inspect(key)}); retrying every #{backoff.retry_in_ms} ms"
        )

      true ->
        Logger.debug("CEC: adapter #{dev} crashed again; restarting in #{backoff.retry_in_ms} ms")
    end

    timer = Process.send_after(self(), {:restart, dev}, backoff.retry_in_ms)
    state = %{state | restart_timers: Map.put(state.restart_timers, dev, timer)}
    update_adapter(state, dev, &%{&1 | backoff: backoff})
  end

  defp next_backoff(prev, key, max) do
    %{crashes: prev.crashes + 1, retry_in_ms: min(prev.retry_in_ms * 2, max), reason: key}
  end

  # Stack traces differ between otherwise identical crashes.
  defp crash_key({reason, stack}) when is_list(stack), do: reason
  defp crash_key(reason), do: reason

  defp crash?(:normal), do: false
  defp crash?(:shutdown), do: false
  defp crash?({:shutdown, _}), do: false
  defp crash?(_reason), do: true

  defp remove_adapter(state, dev) do
    Logger.info("CEC: #{dev} gone")

    case Map.fetch(state.procs, dev) do
      {:ok, {pid, ref}} ->
        Process.demonitor(ref, [:flush])
        _ = DynamicSupervisor.terminate_child(CecSupervisor.adapter_supervisor(), pid)

      :error ->
        :ok
    end

    case Map.fetch(state.restart_timers, dev) do
      {:ok, timer} -> _ = Process.cancel_timer(timer)
      :error -> :ok
    end

    state = cancel_tv_timer(state, dev)

    %{
      state
      | adapters: Map.delete(state.adapters, dev),
        tv: Map.delete(state.tv, dev),
        held_keys: Map.delete(state.held_keys, dev),
        procs: Map.delete(state.procs, dev),
        errors: Map.delete(state.errors, dev),
        restart_timers: Map.delete(state.restart_timers, dev)
    }
  end

  # ── auto-wake ─────────────────────────────────────────────────────────

  # The output lookup is a call into Audio.Server, so it runs in the task
  # with a snapshot of the card pairing rather than in this server. The
  # output's own auto-wake setting is read from the same lookup.
  defp auto_wake(state, key) do
    cards =
      for {dev, %{card_index: card, running?: true}} <- state.adapters,
          is_integer(card),
          into: %{},
          do: {card, dev}

    if cards != %{} do
      lookup = state.output_lookup
      default = state.auto_wake

      _ =
        Task.Supervisor.start_child(state.task_sup, fn ->
          wake(lookup, cards, key, default)
        end)
    end

    :ok
  end

  defp wake(lookup, cards, key, default) do
    with {:ok, %{card_index: card} = output} <- safe_lookup(lookup, key),
         {:ok, dev} <- Map.fetch(cards, card),
         true <- UniversalProxy.Cec.auto_wake?(output, default) do
      Logger.info("CEC: stream starting on card #{card}; One Touch Play via #{dev}")

      case UniversalProxy.Cec.one_touch_play(dev) do
        :ok -> :ok
        {:error, reason} -> Logger.info("CEC: One Touch Play via #{dev}: #{inspect(reason)}")
      end
    end
  end

  defp safe_lookup(lookup, key) do
    lookup.(key)
  catch
    :exit, _ -> :error
  end

  # ── state updates ─────────────────────────────────────────────────────

  defp apply_event(state, dev, {:state, summary}) do
    state
    |> update_link(dev, &apply_summary(&1, summary))
    |> tv_step(dev, &TvPresence.link(&1, summary.configured?, summary.phys_addr))
  end

  defp apply_event(state, dev, {:tv_poll, presence}),
    do: tv_step(state, dev, &TvPresence.observe(&1, presence))

  defp apply_event(state, dev, {:message, %Message{} = message}) do
    case Map.fetch(state.adapters, dev) do
      {:ok, adapter} -> apply_message(state, dev, message, receiver_target(state, adapter))
      :error -> state
    end
  end

  defp apply_event(state, _dev, _event), do: state

  defp apply_summary(adapter, summary) do
    %{
      adapter
      | phys_addr: Message.pa_to_string(summary.phys_addr),
        logical_address: List.first(summary.log_addrs),
        configured?: summary.configured?,
        active_source?: summary.active_source?,
        receiver_presence: summary.receiver
    }
  end

  # ── TV presence ───────────────────────────────────────────────────────

  # Runs one reducer step for `dev`, copies the presence into its record
  # and carries out the step's effects.
  defp tv_step(%{tv_enabled: false} = state, _dev, _fun), do: state

  defp tv_step(state, dev, fun) do
    if Map.has_key?(state.adapters, dev) do
      tv = Map.get_lazy(state.tv, dev, fn -> TvPresence.new(state.tv_timings) end)
      {tv, effects} = fun.(tv)

      state =
        %{state | tv: Map.put(state.tv, dev, tv)}
        |> update_adapter(dev, &%{&1 | tv_presence: tv.presence})

      Enum.reduce(effects, state, &tv_effect(&2, dev, &1))
    else
      state
    end
  end

  defp tv_effect(state, dev, :poll) do
    case Map.fetch(state.procs, dev) do
      {:ok, {pid, _ref}} -> Adapter.poll_tv(pid)
      :error -> :ok
    end

    state
  end

  defp tv_effect(state, dev, :cancel), do: cancel_tv_timer(state, dev)

  defp tv_effect(state, dev, {:recheck_in, ms}) do
    state = cancel_tv_timer(state, dev)
    token = make_ref()
    timer = Process.send_after(self(), {:tv_recheck, dev, token}, ms)
    %{state | tv_timers: Map.put(state.tv_timers, dev, {timer, token})}
  end

  defp cancel_tv_timer(state, dev) do
    case Map.pop(state.tv_timers, dev) do
      {nil, _timers} ->
        state

      {{timer, _token}, timers} ->
        _ = Process.cancel_timer(timer)
        %{state | tv_timers: timers}
    end
  end

  # ── remote keys ───────────────────────────────────────────────────────

  defp handles_for(state, dev),
    do: if(Map.has_key?(state.key_handlers, dev), do: @key_opcodes, else: [])

  defp apply_handles(state, dev) do
    case Map.fetch(state.procs, dev) do
      {:ok, {pid, _ref}} ->
        try do
          :ok = Adapter.subscribe(pid, handle: handles_for(state, dev))
        catch
          :exit, _ -> :ok
        end

      :error ->
        :ok
    end

    state
  end

  defp key_handler_down(state, ref) do
    case Enum.find(state.key_handlers, fn {_dev, handler} -> handler.ref == ref end) do
      nil ->
        state

      {dev, _handler} ->
        state = %{state | key_handlers: Map.delete(state.key_handlers, dev)}
        state |> reset_keys(dev) |> apply_handles(dev)
    end
  end

  defp reset_keys(state, dev), do: %{state | held_keys: Map.delete(state.held_keys, dev)}

  # Keys sent to our logical address go to the claimer, repeats dropped.
  defp deliver_key(state, dev, {:message, %Message{} = message}) do
    with %{pid: pid} <- Map.get(state.key_handlers, dev),
         {:ok, %{logical_address: la}} when is_integer(la) <- Map.fetch(state.adapters, dev),
         true <- message.to == la,
         kind when kind != :ignore <- Keys.classify(message.body) do
      now = System.monotonic_time(:millisecond)
      {key, held} = Keys.step(Map.get(state.held_keys, dev), kind, now)
      if key, do: send(pid, {:cec_key, dev, key})
      %{state | held_keys: Map.put(state.held_keys, dev, held)}
    else
      _ -> state
    end
  end

  defp deliver_key(state, _dev, _event), do: state

  # ── link ──────────────────────────────────────────────────────────────

  # Updates what is known about the link. When the link changes (a new
  # receiver target, physical address, configuration, or the adapter
  # stopping or starting), the device answering at the receiver's address
  # may be a different one, so the cached status is dropped.
  defp update_link(state, dev, fun) do
    case Map.fetch(state.adapters, dev) do
      {:ok, adapter} ->
        updated = fun.(adapter)

        if link(state, updated) == link(state, adapter),
          do: put_adapter(state, updated),
          else: state |> put_adapter(%{updated | receiver: @unknown_receiver}) |> bump(dev)

      :error ->
        state
    end
  end

  defp link(state, adapter) do
    {receiver_target(state, adapter), adapter.phys_addr, adapter.configured?, adapter.running?}
  end

  defp bump(state, dev), do: %{state | versions: Map.update(state.versions, dev, 1, &(&1 + 1))}

  defp reaches_receiver?(:receiver, _target), do: true
  defp reaches_receiver?(:broadcast, _target), do: true
  defp reaches_receiver?(15, _target), do: true
  defp reaches_receiver?(la, target) when is_integer(la), do: la == target

  defp reaches_receiver?(name, target) when is_atom(name) do
    Message.logical_address(name) in [target, 15]
  rescue
    FunctionClauseError -> false
  end

  defp reaches_receiver?(_to, _target), do: false

  # Where `:receiver` commands go right now (mirrors the adapter's rule).
  defp receiver_target(%{receiver_la: nil}, _adapter), do: @tv
  defp receiver_target(_state, %{receiver_presence: :absent}), do: @tv
  defp receiver_target(state, _adapter), do: state.receiver_la

  defp apply_message(state, dev, %Message{from: la, body: {:report_power_status, power}}, la),
    do: report(state, dev, %{power: power(power)})

  # Audio status doesn't move the power version: it doesn't supersede a
  # pending Standby's power transition.
  defp apply_message(state, dev, %Message{from: la, body: {:report_audio_status, m, v}}, la),
    do: update_receiver(state, dev, audio_status(m, v))

  defp apply_message(state, dev, %Message{to: 15, body: :standby}, _la),
    do: report(state, dev, %{power: :standby})

  defp apply_message(state, dev, %Message{from: la, body: :standby}, la),
    do: report(state, dev, %{power: :standby})

  defp apply_message(state, _dev, _message, _la), do: state

  @doc false
  @spec power(atom() | byte()) :: power()
  def power(power) when power in [:on, :standby, :to_on, :to_standby], do: power
  def power(_power), do: :unknown

  @doc false
  @spec audio_status(boolean(), non_neg_integer() | :unknown) :: %{
          volume: 0..100 | nil,
          muted: boolean()
        }
  def audio_status(muted, volume) when is_integer(volume) and volume in 0..100,
    do: %{volume: volume, muted: muted}

  def audio_status(muted, _volume), do: %{volume: nil, muted: muted}

  defp report(state, dev, partial), do: state |> update_receiver(dev, partial) |> bump(dev)

  defp update_receiver(state, dev, partial) do
    update_adapter(state, dev, fn adapter ->
      receiver =
        adapter.receiver
        |> Map.merge(Map.take(partial, [:power, :volume, :muted]))
        |> Map.put(:updated_at, DateTime.utc_now())

      %{adapter | receiver: receiver}
    end)
  end

  defp update_adapter(state, dev, fun) do
    case Map.fetch(state.adapters, dev) do
      {:ok, adapter} -> put_adapter(state, fun.(adapter))
      :error -> state
    end
  end

  # Broadcasts the adapter list when a callback changed any record.
  defp publish(new, old) do
    if new.adapters != old.adapters do
      Phoenix.PubSub.broadcast(new.pubsub, @events_topic, {:cec_adapters, sorted_adapters(new)})
    end

    new
  end

  defp sorted_adapters(state), do: state.adapters |> Map.values() |> Enum.sort_by(& &1.index)

  # `receiver_target` is derived on every write so the record always
  # names the device `receiver` describes (0 when it is the TV).
  defp put_adapter(state, adapter) do
    adapter = Map.put(adapter, :receiver_target, receiver_target(state, adapter))
    %{state | adapters: Map.put(state.adapters, adapter.dev, adapter)}
  end

  defp find_by_card(_state, nil), do: :error

  defp find_by_card(state, card_index) do
    case Enum.find(Map.values(state.adapters), &(&1.card_index == card_index)) do
      nil -> :error
      adapter -> {:ok, adapter}
    end
  end
end
