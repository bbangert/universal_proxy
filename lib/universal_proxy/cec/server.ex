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
  it to the Pi's input before audio reaches the link. `auto_wake: false` in
  the `UniversalProxy.Cec` env turns it off.

  ## The receiver

  Commands address the receiver (`:receiver_la`, default 5), or the TV
  (logical address 0) once the adapter has found no device at that address.
  Power and audio status are recorded only when they come from that device:
  a TV answering a power query reports its own state. A broadcast
  `<Standby>` puts every device in standby; a directed one counts only when
  it comes from the receiver.

  ## Adapter lifecycle

  Adapters are `:temporary` children of the `DynamicSupervisor`, named in
  the `Registry` by device path and monitored here. One that crashes is
  restarted after `:restart_ms`. One that stopped because its device went
  away or couldn't be opened is started again by the next scan that still
  lists the device.

  Every adapter event is re-broadcast on `topic/0` as
  `{:cec_event, dev, event}` (the events are described in
  `Circuits.CEC.Adapter`).

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
  alias UniversalProxy.Cec.Enumerate
  alias UniversalProxy.Cec.Supervisor, as: CecSupervisor

  @pubsub UniversalProxy.PubSub
  @audio_topic "sendspin:state"
  @events_topic "cec:events"
  @default_scan_ms 10_000
  @default_restart_ms 1_000
  @default_osd_name "UniversalProxy"
  @tv 0

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
          receiver: receiver()
        }

  defstruct adapters: %{},
            procs: %{},
            errors: %{},
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

  @doc "Record something learned about the far end (from a command's result)."
  @spec note_receiver(String.t(), map()) :: :ok
  def note_receiver(dev, partial) when is_map(partial),
    do: GenServer.cast(__MODULE__, {:note_receiver, dev, partial})

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
      pubsub: Keyword.get(opts, :pubsub, @pubsub),
      task_sup: Keyword.get(opts, :task_supervisor, UniversalProxy.TaskSupervisor)
    }

    Phoenix.PubSub.subscribe(state.pubsub, @audio_topic)
    send(self(), :scan)
    {:ok, state}
  end

  @impl true
  def handle_call(:list_adapters, _from, state) do
    {:reply, state.adapters |> Map.values() |> Enum.sort_by(& &1.index), state}
  end

  def handle_call({:get_adapter, dev}, _from, state),
    do: {:reply, Map.fetch(state.adapters, dev), state}

  def handle_call({:adapter_for_card, card_index}, _from, state),
    do: {:reply, find_by_card(state, card_index), state}

  def handle_call(:rescan, _from, state), do: {:reply, :ok, scan(state)}

  @impl true
  def handle_cast({:note_receiver, dev, partial}, state) do
    {:noreply, update_receiver(state, dev, partial)}
  end

  @impl true
  def handle_info(:scan, state) do
    Process.send_after(self(), :scan, state.scan_ms)
    {:noreply, scan(state)}
  end

  # A Sendspin stream starting on an HDMI output: wake + select the receiver.
  def handle_info({:sendspin_state, key, %{event: "stream_start"}}, state) do
    if state.auto_wake, do: auto_wake(state, key)
    {:noreply, state}
  end

  def handle_info({:sendspin_state, _key, _event}, state), do: {:noreply, state}

  def handle_info({:cec, dev, event}, state) do
    state = apply_event(state, dev, event)
    Phoenix.PubSub.broadcast(state.pubsub, @events_topic, {:cec_event, dev, event})
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state.procs, fn {_dev, {_pid, r}} -> r == ref end) do
      nil -> {:noreply, state}
      {dev, _proc} -> {:noreply, adapter_down(state, dev, reason)}
    end
  end

  def handle_info({:restart, dev}, state) do
    if Map.has_key?(state.adapters, dev),
      do: {:noreply, ensure_started(state, dev)},
      else: {:noreply, state}
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
      receiver: %{power: :unknown, volume: nil, muted: nil, updated_at: nil}
    })
  end

  defp ensure_started(state, dev) do
    if Map.has_key?(state.procs, dev), do: state, else: start_adapter(state, dev)
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
      system_audio_mode: state.system_audio_mode
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
  defp attach(state, dev, pid) do
    ref = Process.monitor(pid)

    state = %{
      state
      | procs: Map.put(state.procs, dev, {pid, ref}),
        errors: Map.delete(state.errors, dev)
    }

    state = update_adapter(state, dev, &%{&1 | running?: true})

    try do
      :ok = Adapter.subscribe(pid)
      info = Adapter.info(pid)
      update_adapter(state, dev, &apply_summary(&1, info))
    catch
      :exit, _ -> state
    end
  end

  defp adapter_down(state, dev, reason) do
    state = %{state | procs: Map.delete(state.procs, dev)}

    if crash?(reason) do
      Logger.warning("CEC: adapter #{dev} crashed (#{inspect(reason)}); restarting")
      Process.send_after(self(), {:restart, dev}, state.restart_ms)
    else
      Logger.info("CEC: adapter #{dev} stopped (#{inspect(reason)})")
    end

    update_adapter(state, dev, fn adapter ->
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
  end

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

    %{
      state
      | adapters: Map.delete(state.adapters, dev),
        procs: Map.delete(state.procs, dev),
        errors: Map.delete(state.errors, dev)
    }
  end

  # ── auto-wake ─────────────────────────────────────────────────────────

  # The output lookup is a call into Audio.Server, so it runs in the task
  # with a snapshot of the card pairing rather than in this server.
  defp auto_wake(state, key) do
    cards =
      for {dev, %{card_index: card, running?: true}} <- state.adapters,
          is_integer(card),
          into: %{},
          do: {card, dev}

    if cards != %{} do
      lookup = state.output_lookup
      _ = Task.Supervisor.start_child(state.task_sup, fn -> wake(lookup, cards, key) end)
    end

    :ok
  end

  defp wake(lookup, cards, key) do
    with {:ok, %{card_index: card}} <- safe_lookup(lookup, key),
         {:ok, dev} <- Map.fetch(cards, card) do
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

  defp apply_event(state, dev, {:state, summary}),
    do: update_adapter(state, dev, &apply_summary(&1, summary))

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

  # Where `:receiver` commands go right now (mirrors the adapter's rule).
  defp receiver_target(%{receiver_la: nil}, _adapter), do: @tv
  defp receiver_target(_state, %{receiver_presence: :absent}), do: @tv
  defp receiver_target(state, _adapter), do: state.receiver_la

  defp apply_message(state, dev, %Message{from: la, body: {:report_power_status, power}}, la),
    do: update_receiver(state, dev, %{power: power(power)})

  defp apply_message(state, dev, %Message{from: la, body: {:report_audio_status, m, v}}, la),
    do: update_receiver(state, dev, audio_status(m, v))

  defp apply_message(state, dev, %Message{to: 15, body: :standby}, _la),
    do: update_receiver(state, dev, %{power: :standby})

  defp apply_message(state, dev, %Message{from: la, body: :standby}, la),
    do: update_receiver(state, dev, %{power: :standby})

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

  defp put_adapter(state, adapter),
    do: %{state | adapters: Map.put(state.adapters, adapter.dev, adapter)}

  defp find_by_card(_state, nil), do: :error

  defp find_by_card(state, card_index) do
    case Enum.find(Map.values(state.adapters), &(&1.card_index == card_index)) do
      nil -> :error
      adapter -> {:ok, adapter}
    end
  end
end
