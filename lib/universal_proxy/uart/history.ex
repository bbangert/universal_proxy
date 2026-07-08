defmodule UniversalProxy.UART.History do
  @moduledoc """
  Bounded per-port frame history for the Traffic LiveView.

  Subscribes to `Phoenix.PubSub` lifecycle and per-port `:uart_data`
  topics, keeps the most recent `@max_per_port` frames per
  `friendly_name`, and serves snapshots to LV consumers on mount while
  also forwarding live frames to them. Buffers are in-memory only —
  they survive LV reconnects and full page reloads but are lost on
  BEAM restart.

  ## Why a dedicated process

  TrafficLive used to subscribe to `uart:<friendly_name>` directly,
  which meant frames received while no LV was mounted were dropped.
  Routing all data frames through this server gives a single bounded
  store that any number of LV instances can seed from.

  ## Subscribe semantics

  `subscribe_and_snapshot/0` is a single `GenServer.call` that
  atomically registers the caller in the subscriber set and returns a
  snapshot of every buffered frame. Because the call is serialised
  through the GenServer mailbox alongside `:uart_data` messages, every
  frame is delivered to a given subscriber **exactly once** — either
  in the snapshot reply or as a live `{:uart_history_frame, frame}`
  message, never both, never neither.
  """

  use GenServer

  require Logger

  alias UniversalProxy.UART

  @pubsub UniversalProxy.PubSub
  @max_per_port 100
  @throughput_window 24
  @throughput_tick_ms 1_000
  @packet_rate_window 60
  @packet_rate_topic "uart:packet_rate"
  # Grace window between `:uart_port_closed` and the actual eviction
  # of a port's buffer + PubSub subscription. Keeps history visible
  # for a transient unplug while bounding the long-tail leak from
  # unique friendly_names that never come back.
  @port_eviction_grace_ms 5 * 60 * 1_000
  @max_subscriber_mailbox 1_000

  @type frame :: %{
          id: pos_integer(),
          name: String.t(),
          data: binary(),
          timestamp: DateTime.t(),
          dir: :rx | :tx
        }

  @typedoc """
  One per-second throughput sample. `{rx_bytes, tx_bytes}` accumulated
  during a single tick window.
  """
  @type sample :: {non_neg_integer(), non_neg_integer()}

  # -- Client API --

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    auto_tick? = Keyword.get(opts, :auto_tick, true)

    # The Z-Wave proxy broadcasts on the same topics as UART.Server but
    # its port never appears in `UART.named_ports/0` — the eviction
    # check consults this claim so a live Z-Wave port isn't evicted
    # (and unsubscribed!) five minutes after a close/reopen cycle.
    # Injectable for tests.
    zwave_claim =
      Keyword.get(opts, :zwave_claim, &UniversalProxy.ESPHome.ZWaveProxy.claimed_port/0)

    GenServer.start_link(__MODULE__, %{auto_tick?: auto_tick?, zwave_claim: zwave_claim},
      name: name
    )
  end

  @doc """
  Register the caller as a live subscriber and return the current
  buffered frames across all ports, ordered oldest-first by frame id.
  """
  @spec subscribe_and_snapshot(GenServer.server()) :: [frame()]
  def subscribe_and_snapshot(server \\ __MODULE__) do
    GenServer.call(server, :subscribe_and_snapshot)
  end

  @doc """
  Detach the caller from the subscriber set. Idempotent.
  """
  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(server \\ __MODULE__) do
    GenServer.cast(server, {:unsubscribe, self()})
  end

  @doc """
  Register the caller as a live throughput subscriber for the named
  port and return the current rolling samples (newest-first,
  `@throughput_window` long). Subsequent ticks are delivered as
  `{:uart_throughput, %{name: name, samples: samples}}` messages.

  Atomic in the same sense as `subscribe_and_snapshot/1`: the snapshot
  and registration are serialised through the GenServer mailbox so a
  caller never double-counts the same tick.
  """
  @spec throughput_subscribe_and_snapshot(GenServer.server(), String.t()) :: [sample()]
  def throughput_subscribe_and_snapshot(server \\ __MODULE__, name) when is_binary(name) do
    GenServer.call(server, {:throughput_subscribe_and_snapshot, name})
  end

  @doc """
  Detach the caller from the named port's throughput subscriber set.
  Idempotent.
  """
  @spec throughput_unsubscribe(GenServer.server(), String.t()) :: :ok
  def throughput_unsubscribe(server \\ __MODULE__, name) when is_binary(name) do
    GenServer.cast(server, {:throughput_unsubscribe, self(), name})
  end

  @doc """
  Total frame count across all ports over the last `@packet_rate_window`
  seconds (i.e. "packets per minute"). Cheap to call — just an Enum.sum
  over a 60-element list inside the GenServer.

  Pair with `Phoenix.PubSub.subscribe(UniversalProxy.PubSub,
  "uart:packet_rate")` to receive `{:uart_packet_rate, count}` messages
  on every 1-second tick.
  """
  @spec packets_per_minute(GenServer.server()) :: non_neg_integer()
  def packets_per_minute(server \\ __MODULE__) do
    GenServer.call(server, :packets_per_minute)
  end

  @doc """
  PubSub topic used to broadcast `{:uart_packet_rate, count}` on each
  tick. Exposed so callers don't hard-code the string.
  """
  @spec packet_rate_topic() :: String.t()
  def packet_rate_topic, do: @packet_rate_topic

  # -- Server callbacks --

  @impl true
  def init(opts) do
    Phoenix.PubSub.subscribe(@pubsub, "uart:port_opened")
    Phoenix.PubSub.subscribe(@pubsub, "uart:port_closed")

    if Map.get(opts, :auto_tick?, true) do
      :timer.send_interval(@throughput_tick_ms, self(), :throughput_tick)
    end

    # The already-open-port snapshot needs a cross-process call into
    # UART.Server, which must not happen in init: it would couple this
    # process's startup to the Server being up already (a fragile
    # supervisor-ordering dependency). The port_opened/port_closed
    # subscriptions above are live before the continue runs, so no
    # open/close event can slip between snapshot and subscription.
    {:ok,
     %{
       buffers: %{},
       subscribed_topics: MapSet.new(),
       subscribers: %{},
       throughput: %{},
       throughput_subscribers: %{},
       packet_buckets: List.duplicate(0, @packet_rate_window),
       next_id: 1,
       zwave_claim: Map.fetch!(opts, :zwave_claim)
     }, {:continue, :subscribe_open_ports}}
  end

  @impl true
  def handle_continue(:subscribe_open_ports, state) do
    open_names = open_friendly_names()

    new_names =
      open_names
      |> Enum.reject(&MapSet.member?(state.subscribed_topics, &1))
      |> MapSet.new()

    Enum.each(new_names, &Phoenix.PubSub.subscribe(@pubsub, "uart:#{&1}"))

    {:noreply, %{state | subscribed_topics: MapSet.union(state.subscribed_topics, new_names)}}
  end

  @impl true
  def handle_call(:subscribe_and_snapshot, {pid, _ref}, state) do
    state = ensure_subscriber(state, pid)

    snapshot =
      state.buffers
      |> Map.values()
      |> Enum.concat()
      |> Enum.sort_by(& &1.id)

    {:reply, snapshot, state}
  end

  def handle_call({:throughput_subscribe_and_snapshot, name}, {pid, _ref}, state) do
    state = state |> ensure_throughput_entry(name) |> ensure_throughput_subscriber(name, pid)
    {:reply, get_in(state.throughput, [name, :samples]), state}
  end

  def handle_call(:packets_per_minute, _from, state) do
    {:reply, Enum.sum(state.packet_buckets), state}
  end

  @impl true
  def handle_cast({:unsubscribe, pid}, state) do
    {:noreply, drop_subscriber(state, pid)}
  end

  def handle_cast({:throughput_unsubscribe, pid, name}, state) do
    {:noreply, drop_throughput_subscriber(state, name, pid)}
  end

  @impl true
  def handle_info({:uart_port_opened, %{friendly_name: name}}, state) do
    state =
      if MapSet.member?(state.subscribed_topics, name) do
        state
      else
        Phoenix.PubSub.subscribe(@pubsub, "uart:#{name}")
        %{state | subscribed_topics: MapSet.put(state.subscribed_topics, name)}
      end

    {:noreply, state}
  end

  # Keep the buffer & subscription on close so the LV can still show
  # the most recent frames of a port that just disconnected — but
  # schedule a delayed eviction so a never-returning port doesn't
  # leak its buffer + PubSub subscription forever. If the port comes
  # back inside the grace window the `:evict` message will find it
  # in `UART.named_ports/0` and bail.
  def handle_info({:uart_port_closed, %{friendly_name: name}}, state) do
    Process.send_after(self(), {:evict_port, name}, @port_eviction_grace_ms)
    {:noreply, state}
  end

  def handle_info({:uart_port_closed, _info}, state), do: {:noreply, state}

  def handle_info({:evict_port, name}, state) do
    if port_still_absent?(state, name) do
      {:noreply, evict_port(state, name)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:uart_data, msg}, state) do
    frame = Map.put(msg, :id, state.next_id)

    buffers =
      Map.update(state.buffers, msg.name, [frame], fn buf ->
        # Newest at the tail; trim from the head when over the cap.
        # Append is O(n) but the cap is small (@max_per_port).
        case buf ++ [frame] do
          over when length(over) > @max_per_port -> Enum.drop(over, length(over) - @max_per_port)
          ok -> ok
        end
      end)

    throughput = accumulate_throughput(state.throughput, msg)
    # Only count RX so "packets/min" matches the conventional
    # "incoming frames" reading instead of doubling on full-duplex
    # links where every write echoes through `UART.Server`'s TX
    # broadcast. Per-direction byte counts are still captured in
    # `throughput` above.
    packet_buckets =
      if msg.dir == :rx, do: bump_head(state.packet_buckets), else: state.packet_buckets

    for {pid, _ref} <- state.subscribers do
      bounded_send(pid, {:uart_history_frame, frame})
    end

    {:noreply,
     %{
       state
       | buffers: buffers,
         throughput: throughput,
         packet_buckets: packet_buckets,
         next_id: state.next_id + 1
     }}
  end

  # Roll every tracked port's pending byte counts into the head of its
  # sample ring once per second, then push the new sample list to that
  # port's throughput subscribers. Ports with no subscribers still tick
  # so the snapshot returned on the next subscribe reflects real time.
  #
  # Also rolls the global packet-rate bucket window and broadcasts the
  # current packets/min on the shared topic.
  def handle_info(:throughput_tick, state) do
    # Step 1 (pure): compute the new throughput map.
    new_throughput =
      Map.new(state.throughput, fn {name, %{current: current, samples: samples}} ->
        new_samples = [current | Enum.take(samples, @throughput_window - 1)]
        {name, %{current: {0, 0}, samples: new_samples}}
      end)

    # Step 2 (effects): fan out per-port samples to subscribers.
    Enum.each(new_throughput, fn {name, %{samples: samples}} ->
      for {pid, _ref} <- Map.get(state.throughput_subscribers, name, %{}) do
        bounded_send(pid, {:uart_throughput, %{name: name, samples: samples}})
      end
    end)

    packet_buckets = [0 | Enum.take(state.packet_buckets, @packet_rate_window - 1)]
    packets_per_minute = Enum.sum(packet_buckets)

    # Offload the broadcast onto a TaskSupervisor child so a slow
    # PubSub backend can't stall the tick — `Phoenix.PubSub.broadcast/3`
    # walks every subscriber synchronously, and we don't want frame
    # ingestion blocked by that as subscriber count grows.
    Task.Supervisor.start_child(UniversalProxy.TaskSupervisor, fn ->
      Phoenix.PubSub.broadcast(
        @pubsub,
        @packet_rate_topic,
        {:uart_packet_rate, packets_per_minute}
      )
    end)

    {:noreply, %{state | throughput: new_throughput, packet_buckets: packet_buckets}}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    state =
      case Map.get(state.subscribers, pid) do
        ^ref -> drop_subscriber(state, pid)
        _ -> state
      end

    {:noreply, drop_throughput_subscriptions_for(state, pid)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # -- Helpers --

  defp ensure_subscriber(state, pid) do
    case Map.get(state.subscribers, pid) do
      nil ->
        ref = Process.monitor(pid)
        %{state | subscribers: Map.put(state.subscribers, pid, ref)}

      _existing ->
        state
    end
  end

  defp drop_subscriber(state, pid) do
    case Map.pop(state.subscribers, pid) do
      {nil, _subs} ->
        state

      {ref, subs} ->
        Process.demonitor(ref, [:flush])
        %{state | subscribers: subs}
    end
  end

  defp open_friendly_names do
    UART.named_ports() |> Enum.map(& &1.friendly_name)
  end

  # Send only when the receiver's mailbox is short enough to keep up.
  # A backgrounded LV tab whose websocket is congested can otherwise
  # accumulate per-frame messages indefinitely under sustained
  # throughput, snowballing the LV's `handle_info` cost. Above the
  # threshold we drop with a debug log — the LV gets a partial view
  # until it catches up but the History process stays responsive.
  # `Process.info(pid, :message_queue_len)` returns `nil` if the pid
  # is already dead; the `:DOWN` handler will clean up shortly.
  defp bounded_send(pid, msg) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, len} when len < @max_subscriber_mailbox ->
        send(pid, msg)

      {:message_queue_len, _len} ->
        Logger.debug(fn ->
          "history: dropping #{inspect(elem(msg, 0))} for slow subscriber #{inspect(pid)}"
        end)

      nil ->
        :ok
    end
  end

  defp port_still_absent?(state, name) do
    not (Enum.any?(UART.named_ports(), &(&1.friendly_name == name)) or
           zwave_port_name(state) == name)
  end

  defp zwave_port_name(%{zwave_claim: claim_fun}) do
    case claim_fun.() do
      %{display_name: name} -> name
      _ -> nil
    end
  end

  # Drop every trace of `name` from state and the PubSub topic. Any
  # throughput subscribers still holding a monitor for this port get
  # their refs flushed so a later `:DOWN` doesn't process empty work.
  defp evict_port(state, name) do
    Phoenix.PubSub.unsubscribe(@pubsub, "uart:#{name}")

    case Map.get(state.throughput_subscribers, name) do
      nil ->
        :ok

      subs ->
        Enum.each(subs, fn {_pid, ref} -> Process.demonitor(ref, [:flush]) end)
    end

    %{
      state
      | subscribed_topics: MapSet.delete(state.subscribed_topics, name),
        buffers: Map.delete(state.buffers, name),
        throughput: Map.delete(state.throughput, name),
        throughput_subscribers: Map.delete(state.throughput_subscribers, name)
    }
  end

  # The shape we initialise a throughput entry to — zero-filled `current`
  # plus a zero-filled rolling window. Centralised so
  # `ensure_throughput_entry/2` and `accumulate_throughput/2` can't
  # silently drift apart.
  defp empty_throughput_entry do
    %{current: {0, 0}, samples: List.duplicate({0, 0}, @throughput_window)}
  end

  # Lazily insert a fresh sample ring for `name` so the first tick after
  # subscribe (or first incoming byte) has somewhere to land.
  defp ensure_throughput_entry(state, name) do
    case Map.get(state.throughput, name) do
      nil ->
        %{state | throughput: Map.put(state.throughput, name, empty_throughput_entry())}

      _ ->
        state
    end
  end

  defp ensure_throughput_subscriber(state, name, pid) do
    subs = Map.get(state.throughput_subscribers, name, %{})

    case Map.get(subs, pid) do
      nil ->
        ref = Process.monitor(pid)
        new_subs = Map.put(subs, pid, ref)
        %{state | throughput_subscribers: Map.put(state.throughput_subscribers, name, new_subs)}

      _existing ->
        state
    end
  end

  defp drop_throughput_subscriber(state, name, pid) do
    subs = Map.get(state.throughput_subscribers, name, %{})

    case Map.pop(subs, pid) do
      {nil, _} ->
        state

      {ref, new_subs} ->
        Process.demonitor(ref, [:flush])
        %{state | throughput_subscribers: Map.put(state.throughput_subscribers, name, new_subs)}
    end
  end

  # Called from the :DOWN handler. The ref that fired is already gone,
  # but a multi-port subscriber holds one ref per port — those N-1
  # remaining refs will each fire their own DOWN and re-enter this
  # handler as no-ops. Flush them now via `Process.demonitor(..,
  # [:flush])` so we don't process redundant work for an already-dead
  # pid.
  defp drop_throughput_subscriptions_for(state, pid) do
    new_subs =
      Map.new(state.throughput_subscribers, fn {name, subs} ->
        case Map.pop(subs, pid) do
          {nil, unchanged} ->
            {name, unchanged}

          {ref, remaining} ->
            Process.demonitor(ref, [:flush])
            {name, remaining}
        end
      end)

    %{state | throughput_subscribers: new_subs}
  end

  # Increment the head bucket of the packet-rate ring without rolling
  # the window. Rolling happens once per tick in :throughput_tick.
  defp bump_head([head | rest]), do: [head + 1 | rest]
  defp bump_head([]), do: [1]

  defp accumulate_throughput(throughput, %{name: name, data: data, dir: dir}) do
    bytes = byte_size(data)
    entry = Map.get(throughput, name, empty_throughput_entry())
    {rx, tx} = entry.current

    new_current =
      case dir do
        :rx -> {rx + bytes, tx}
        :tx -> {rx, tx + bytes}
        _ -> {rx, tx}
      end

    Map.put(throughput, name, %{entry | current: new_current})
  end
end
