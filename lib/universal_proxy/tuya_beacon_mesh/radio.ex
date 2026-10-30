defmodule UniversalProxy.TuyaBeaconMesh.Radio do
  @moduledoc """
  The board's single P2 radio: owns the controller lease, discovery and the
  advert receiver for one adapter, serialises transmissions, and fans
  received frames out to subscribers.

  `Bluez.Radio` and `Bluez.Mgmt` must already be running: they are shared
  infrastructure the host supervises, and this process never starts or
  links them. Setup (on start, and again after any loss):

    * checks the adapter through `Bluez.Mgmt` (*Read Advertising
      Features*), subscribes to `Bluez.Radio`'s lease-end notices and
      acquires the `:mgmt` lease for the adapter — this process is the
      lease holder, so only it may advertise;
    * opens its own system-bus connection (kept across retries) and starts
      LE discovery with `DuplicateData: true` on the adapter;
    * starts a linked `Bluez.AdvertReceiver` whose `on_report:` callback
      casts only AD 0x03 26-byte frames here.

  When any step fails — `Bluez.Radio`/`Bluez.Mgmt` not running, adapter
  missing, lease held by another process, D-Bus down — the radio stays up
  but not ready: whatever the attempt got (lease, discovery) is undone,
  the reason is logged once (`status/1`'s `:last_error`), and setup is
  retried after 2 s, doubling up to 30 s. The same happens at runtime when
  the lease ends, `Bluez.Radio` or the D-Bus connection goes down, the
  receiver exits, or `Bluez.Mgmt` stops accepting sends. While not ready,
  `send_frame/3` returns `{:error, :not_ready}` (queued frames are
  dropped); subscriptions are kept and deliver again once ready.

  On stop it takes any advert off air, stops the receiver and discovery
  and releases the lease. `Bluez.Radio`/`Bluez.Mgmt` are left running.

  ## TX

  `send_frame/3` queues a 26-byte frame for `duration_ms` of advertising
  (20/30 ms interval, connectable, no kernel `duration_ms:` — on a
  controller without hardware offload `Bluez.Mgmt` refuses a finite
  duration while another instance is registered, see its "Software
  rotation" section, so we stop on our own timer). One advert is on air at
  a time. Frames are sent with the app's queue classes
  (tuya_beacon_mesh.md §4.7): a `:control` send (pair, reset, group)
  drops queued `:normal` sends (DP, ping); it does not interrupt the
  advert already on air.

  ## RX

  `subscribe/3` registers a pid for `{:tuya_report, report}` messages,
  where `report` is `%{mac, address, frame, rssi}` (`mac` is the 12-hex
  advertiser address, `frame` the raw 26 bytes as received, hop bits
  intact). Filters: `:all`, `:unpaired` (frames `P2.parse_unpaired/1`
  accepts), or `{:mac, mac}`.

  Two kinds of duplicates are dropped before fan-out: the same
  `{address, P2.normalize(frame)}` seen within ~2 s (bulbs relay copies
  with decremented hop/TTL bits, which `normalize/1` erases), and echoes of
  our own recent transmissions (the last #{32} normalised frames sent)
  relayed back by bulbs. Echo dropping can be turned off with
  `drop_echoes: false` / `set_drop_echoes/2` — checking on hardware that
  a transmission was relayed needs that, since a relayed copy of our frame
  is exactly what it looks for.

  The `Bluez.*` modules are injectable (`:bluez_radio`, `:mgmt`,
  `:rebus`, `:dbus`, `:receiver` options) so the queue and fan-out logic
  is testable off-board.
  """

  use GenServer

  require Logger

  import Bitwise

  alias UniversalProxy.TuyaBeaconMesh.{Carrier, P2}

  @dedupe_ms 2_000
  @dedupe_max 1_024
  @recent_tx_max 32
  @retry_ms 2_000
  @max_retry_ms 30_000

  # Advertise errors that mean the lease or Bluez.Mgmt is gone, not that
  # this one frame was refused: re-run setup rather than keep sending.
  @fatal_advertise_errors [:lease_expired, :not_lease_holder, :not_running]

  # ── Client API ─────────────────────────────────────────────────────────

  @doc """
  Starts the radio for one adapter.

  Options: `:adapter_index` (default 0), `:name` (default
  `#{inspect(__MODULE__)}`), `:drop_echoes` (default `true`),
  `:retry_ms` (first setup retry delay, default #{@retry_ms}; doubles up
  to #{@max_retry_ms}), and the `Bluez.*` implementation modules
  `:bluez_radio`, `:mgmt`, `:rebus`, `:dbus`, `:receiver` (defaults are
  the real ones).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.get(opts, :adapter_index, 0)},
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc """
  Queues `frame` (26 bytes) for `duration_ms` of advertising. `:class` is
  `:normal` (default) or `:control`; a `:control` send drops queued
  `:normal` frames. Returns `:ok` once the frame is on air or queued,
  `{:error, :not_ready}` while setup is pending or being retried (see the
  moduledoc), `{:error, :not_running}` when the radio process is down,
  `{:error, :bad_frame}` for a non-26-byte frame.
  """
  @spec send_frame(binary(), non_neg_integer(), keyword()) ::
          :ok | {:error, :not_running | :not_ready | :bad_frame}
  def send_frame(frame, duration_ms, opts \\ [])

  def send_frame(<<_::binary-size(26)>> = frame, duration_ms, opts)
      when is_integer(duration_ms) and duration_ms >= 0 do
    server = Keyword.get(opts, :server, __MODULE__)
    class = Keyword.get(opts, :class, :normal)
    call(server, {:send_frame, frame, duration_ms, class}, {:error, :not_running})
  end

  def send_frame(frame, _duration_ms, _opts) when is_binary(frame),
    do: {:error, :bad_frame}

  @doc "Takes the current advert off air and empties the TX queue."
  @spec stop_tx(keyword()) :: :ok | {:error, :not_running}
  def stop_tx(opts \\ []) do
    call(Keyword.get(opts, :server, __MODULE__), :stop_tx, {:error, :not_running})
  end

  @doc """
  Subscribes `pid` to `{:tuya_report, report}` messages matching
  `filter` (`:all`, `:unpaired` or `{:mac, mac}`). The pid is monitored
  and dropped when it exits. Works while the radio is not ready; reports
  start once it is.
  """
  @spec subscribe(pid(), :all | :unpaired | {:mac, String.t()}, GenServer.server()) ::
          :ok | {:error, :not_running | :bad_filter}
  def subscribe(pid, filter, server \\ __MODULE__) when is_pid(pid) do
    case normalize_filter(filter) do
      {:ok, filter} -> call(server, {:subscribe, pid, filter}, {:error, :not_running})
      :error -> {:error, :bad_filter}
    end
  end

  @doc "Removes `pid`'s subscription, if any."
  @spec unsubscribe(pid(), GenServer.server()) :: :ok | {:error, :not_running}
  def unsubscribe(pid, server \\ __MODULE__) when is_pid(pid) do
    call(server, {:unsubscribe, pid}, {:error, :not_running})
  end

  @doc "Turns echo dropping (see the moduledoc) on or off at runtime."
  @spec set_drop_echoes(boolean(), keyword()) :: :ok | {:error, :not_running}
  def set_drop_echoes(drop?, opts \\ []) when is_boolean(drop?) do
    call(
      Keyword.get(opts, :server, __MODULE__),
      {:set_drop_echoes, drop?},
      {:error, :not_running}
    )
  end

  @doc """
  Radio state: whether setup completed (`:ready`) and why it last failed
  (`:last_error`, `nil` once ready), adapter index, lease held, discovery
  on, receiver listening, subscriber count, what's on air (`:tx`) and how
  many frames are queued (`:queued`).
  """
  @spec status(keyword()) :: {:ok, map()} | {:error, :not_running}
  def status(opts \\ []) do
    call(Keyword.get(opts, :server, __MODULE__), :status, {:error, :not_running})
  end

  # `catch :exit` idiom (see `Bluez`): not running → the given default.
  defp call(server, request, default) do
    GenServer.call(server, request)
  catch
    :exit, _reason -> default
  end

  defp normalize_filter(:all), do: {:ok, :all}
  defp normalize_filter(:unpaired), do: {:ok, :unpaired}

  defp normalize_filter({:mac, mac}) when is_binary(mac) do
    case normalize_mac(mac) do
      {:ok, mac} -> {:ok, {:mac, mac}}
      :error -> :error
    end
  end

  defp normalize_filter(_other), do: :error

  # "DC:23:53:0F:B3:4A", "dc23530fb34a" → "DC23530FB34A".
  defp normalize_mac(mac) do
    hex = mac |> String.replace(~r/[^0-9A-Fa-f]/, "") |> String.upcase()
    if byte_size(hex) == 12, do: {:ok, hex}, else: :error
  end

  defp mac_string(address) when is_integer(address) do
    address |> Integer.to_string(16) |> String.pad_leading(12, "0")
  end

  # ── GenServer ────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    # Trapping exits turns a crash of the linked AdvertReceiver into an
    # {:EXIT, rx, _} we answer by re-running setup, instead of taking this
    # process (and its subscriptions and queue) down with it. It also makes
    # a supervisor shutdown run terminate/2, so the advert, discovery and
    # lease are cleaned up explicitly; gen_server still honours the
    # parent's EXIT itself before handle_info sees it.
    Process.flag(:trap_exit, true)
    retry_ms = Keyword.get(opts, :retry_ms, @retry_ms)

    state = %{
      adapter_index: Keyword.get(opts, :adapter_index, 0),
      bluez_radio: Keyword.get(opts, :bluez_radio, Bluez.Radio),
      mgmt: Keyword.get(opts, :mgmt, Bluez.Mgmt),
      rebus: Keyword.get(opts, :rebus, Bluez.Rebus),
      dbus: Keyword.get(opts, :dbus, Bluez.DBus),
      receiver: Keyword.get(opts, :receiver, Bluez.AdvertReceiver),
      drop_echoes: Keyword.get(opts, :drop_echoes, true),
      ready: false,
      last_error: nil,
      retry_ms: retry_ms,
      backoff_ms: retry_ms,
      retry_timer: nil,
      radio_mon: nil,
      lease: nil,
      conn: nil,
      conn_mon: nil,
      rx: nil,
      rx_name: nil,
      discovering: false,
      subscribers: %{},
      dedupe: %{},
      recent_tx: [],
      tx_queue: :queue.new(),
      tx_current: nil
    }

    {:ok, state, {:continue, :setup}}
  end

  @impl GenServer
  def handle_continue(:setup, state), do: {:noreply, attempt_setup(state)}

  # ── Setup / retry ────────────────────────────────────────────────────

  defp attempt_setup(state) do
    case setup(state) do
      {:ok, state} ->
        if state.last_error != nil do
          Logger.info("#{inspect(__MODULE__)}: ready on hci#{state.adapter_index}")
        end

        %{state | ready: true, last_error: nil, backoff_ms: state.retry_ms}

      {:error, reason, state} ->
        state |> teardown() |> not_ready(reason)
    end
  end

  # Each step records what it got in the state it returns (also on error),
  # so teardown/1 can undo exactly that much.
  defp setup(state) do
    with {:ok, state} <- probe_mgmt(state),
         {:ok, state} <- watch_bluez_radio(state),
         {:ok, state} <- acquire(state),
         {:ok, state} <- connect(state),
         {:ok, state} <- start_discovery(state) do
      start_receiver(state)
    end
  end

  # A runtime loss while ready: undo everything and retry from the start
  # of the backoff (reason is new: last_error is nil while ready).
  defp lost(%{ready: true} = state, reason),
    do: not_ready(%{teardown(state) | backoff_ms: state.retry_ms}, reason)

  # Already retrying: the next attempt rebuilds whatever this was.
  defp lost(state, _reason), do: state

  defp not_ready(state, reason) do
    if reason != state.last_error do
      Logger.warning(
        "#{inspect(__MODULE__)}: hci#{state.adapter_index} not ready (#{inspect(reason)}), retrying"
      )
    end

    if state.retry_timer, do: Process.cancel_timer(state.retry_timer)
    timer = Process.send_after(self(), :retry_setup, state.backoff_ms)

    %{
      state
      | ready: false,
        last_error: reason,
        retry_timer: timer,
        backoff_ms: min(state.backoff_ms * 2, @max_retry_ms)
    }
  end

  # Takes everything setup got back down, except the D-Bus connection and
  # the Bluez.Radio subscription, which are reused by the next attempt.
  defp teardown(state) do
    state = stop_current(state)
    state = %{state | tx_queue: :queue.new(), ready: false}
    state = stop_receiver(state)
    state = stop_discovery(state)

    if state.lease != nil, do: state.bluez_radio.release(state.lease)
    %{state | lease: nil}
  end

  defp probe_mgmt(state) do
    case state.mgmt.read_advertising_features(state.adapter_index) do
      {:ok, _features} -> {:ok, state}
      {:error, reason} -> {:error, {:mgmt, reason}, state}
    end
  end

  # Subscribed before acquiring, so a lease end can't slip in between.
  defp watch_bluez_radio(%{radio_mon: nil} = state) do
    case state.bluez_radio.subscribe() do
      {:ok, pid} -> {:ok, %{state | radio_mon: Process.monitor(pid)}}
      {:error, reason} -> {:error, {:bluez_radio, reason}, state}
    end
  end

  defp watch_bluez_radio(state), do: {:ok, state}

  defp acquire(state) do
    case state.bluez_radio.acquire(adapter_index: state.adapter_index) do
      {:ok, lease} -> {:ok, %{state | lease: lease}}
      {:error, reason} -> {:error, {:lease, reason}, state}
    end
  end

  # The connection is bound to this process (rebus closes it when we
  # exit) but not linked, so it is monitored instead.
  defp connect(%{conn: nil} = state) do
    case rebus_connect(state) do
      {:ok, conn} when is_pid(conn) ->
        {:ok, %{state | conn: conn, conn_mon: Process.monitor(conn)}}

      other ->
        {:error, {:dbus_connect, other}, state}
    end
  end

  defp connect(state), do: {:ok, state}

  # Bluez.Rebus.connect/1 exits when its ConnectionSupervisor isn't up.
  defp rebus_connect(state) do
    state.rebus.connect(:system)
  catch
    :exit, reason -> {:exit, reason}
  end

  defp start_discovery(state) do
    filter = [{"Transport", {"s", "le"}}, {"DuplicateData", {"b", true}}]

    with {:ok, _} <- adapter_call(state, "SetDiscoveryFilter", "a{sv}", [filter]),
         {:ok, _} <- start_discovery_call(state) do
      {:ok, %{state | discovering: true}}
    else
      {:error, reason} -> {:error, {:discovery, reason}, state}
    end
  end

  defp start_discovery_call(state) do
    case adapter_call(state, "StartDiscovery", "", []) do
      # Already discovering for this connection: goal reached.
      {:error, "org.bluez.Error.InProgress"} -> {:ok, []}
      other -> other
    end
  end

  defp stop_discovery(%{discovering: true, conn: conn} = state) when conn != nil do
    _ = adapter_call(state, "StopDiscovery", "", [])
    %{state | discovering: false}
  end

  defp stop_discovery(state), do: %{state | discovering: false}

  defp adapter_call(state, member, signature, body) do
    path = "/org/bluez/hci#{state.adapter_index}"
    state.dbus.call(state.conn, path, "org.bluez.Adapter1", member, signature, body)
  end

  defp start_receiver(state) do
    radio = self()

    on_report = fn report ->
      for frame <- Carrier.frames(report.data) do
        GenServer.cast(
          radio,
          {:report, report.address, frame, report.rssi}
        )
      end
    end

    name = Module.concat(__MODULE__, "Rx#{state.adapter_index}")

    # `{:already_started, pid}` is not ours (not linked, not stopped on
    # teardown): an error like any other, retried.
    case state.receiver.start_link(
           name: name,
           adapter_index: state.adapter_index,
           on_report: on_report
         ) do
      {:ok, pid} -> {:ok, %{state | rx: pid, rx_name: name}}
      {:error, reason} -> {:error, {:receiver, reason}, state}
    end
  end

  # Unlinked first, so stopping it doesn't come back as an {:EXIT, ...}.
  defp stop_receiver(%{rx: rx} = state) when is_pid(rx) do
    Process.unlink(rx)

    try do
      GenServer.stop(rx, :normal, 2_000)
    catch
      :exit, _reason -> :ok
    end

    %{state | rx: nil, rx_name: nil}
  end

  defp stop_receiver(state), do: %{state | rx: nil, rx_name: nil}

  # ── TX ───────────────────────────────────────────────────────────────

  @impl GenServer
  def handle_call({:send_frame, _frame, _duration_ms, _class}, _from, %{ready: false} = state),
    do: {:reply, {:error, :not_ready}, state}

  def handle_call({:send_frame, frame, duration_ms, class}, _from, state) do
    state =
      if class == :control,
        do: %{state | tx_queue: drop_queued(state.tx_queue, :normal)},
        else: state

    job = %{frame: frame, duration_ms: duration_ms, class: class, norm: P2.normalize(frame)}
    state = maybe_start_next(%{state | tx_queue: :queue.in(job, state.tx_queue)})

    # Starting it may have found the lease gone (see maybe_start_next/1).
    {:reply, if(state.ready, do: :ok, else: {:error, :not_ready}), state}
  end

  def handle_call(:stop_tx, _from, state) do
    {:reply, :ok, stop_current(%{state | tx_queue: :queue.new()})}
  end

  def handle_call({:subscribe, pid, filter}, _from, state) do
    subscribers =
      case state.subscribers do
        %{^pid => _existing} ->
          Map.put(state.subscribers, pid, filter)

        _new ->
          Process.monitor(pid)
          Map.put(state.subscribers, pid, filter)
      end

    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: Map.delete(state.subscribers, pid)}}
  end

  def handle_call({:set_drop_echoes, drop?}, _from, state) do
    {:reply, :ok, %{state | drop_echoes: drop?}}
  end

  def handle_call(:status, _from, state) do
    status = %{
      ready: state.ready,
      last_error: state.last_error,
      adapter_index: state.adapter_index,
      lease_held: state.lease != nil and state.bluez_radio.valid?(state.lease),
      discovering: state.discovering,
      listening: state.rx_name != nil and state.receiver.listening?(state.rx_name),
      subscribers: map_size(state.subscribers),
      tx:
        case state.tx_current do
          nil -> nil
          %{class: class, instance: instance} -> %{class: class, instance: instance}
        end,
      queued: :queue.len(state.tx_queue)
    }

    {:reply, {:ok, status}, state}
  end

  @impl GenServer
  def handle_cast({:report, address, frame, rssi}, state) do
    {:noreply, fan_out(state, address, frame, rssi)}
  end

  @impl GenServer
  def handle_info({:tx_done, instance}, %{tx_current: %{instance: instance}} = state) do
    {:noreply, maybe_start_next(stop_current(state))}
  end

  def handle_info(:retry_setup, %{ready: false} = state),
    do: {:noreply, attempt_setup(%{state | retry_timer: nil})}

  # Bluez.Radio notifies every subscriber of every lease end; only ours
  # matters. Mgmt has already taken its adverts off air.
  def handle_info({:radio_lease_ended, ref}, %{lease: %{ref: ref}} = state) do
    {:noreply, lost(%{state | lease: nil}, :lease_ended)}
  end

  def handle_info({:DOWN, mon, :process, _pid, reason}, %{radio_mon: mon} = state) do
    state = %{state | radio_mon: nil, lease: nil}
    {:noreply, lost(state, {:bluez_radio_down, reason})}
  end

  # BlueZ drops a client's discovery session when its connection closes.
  def handle_info({:DOWN, mon, :process, _pid, reason}, %{conn_mon: mon} = state) do
    state = %{state | conn: nil, conn_mon: nil, discovering: false}
    {:noreply, lost(state, {:dbus_down, reason})}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
  end

  def handle_info({:EXIT, rx, reason}, %{rx: rx} = state) when is_pid(rx) do
    {:noreply, lost(%{state | rx: nil, rx_name: nil}, {:receiver_exit, reason})}
  end

  # The receiver is the only link we make, and the parent's EXIT never gets
  # here; anything else (an earlier receiver, a failed start_link) is stale.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    _ = teardown(state)
    :ok
  end

  defp drop_queued(queue, class) do
    :queue.filter(fn job -> job.class != class end, queue)
  end

  defp maybe_start_next(%{tx_current: nil, ready: true} = state) do
    case :queue.out(state.tx_queue) do
      {{:value, job}, queue} ->
        case state.mgmt.advertise(state.lease, Carrier.ad_bytes(job.frame), flags: [:connectable]) do
          {:ok, instance} ->
            timer = Process.send_after(self(), {:tx_done, instance}, job.duration_ms)

            %{
              state
              | tx_queue: queue,
                tx_current: Map.merge(job, %{instance: instance, timer: timer}),
                recent_tx: Enum.take([job.norm | state.recent_tx], @recent_tx_max)
            }

          {:error, reason} when reason in @fatal_advertise_errors ->
            lost(%{state | tx_queue: queue}, {:advertise, reason})

          {:error, reason} ->
            Logger.warning(
              "#{inspect(__MODULE__)}: advertise failed (#{inspect(reason)}), dropping frame"
            )

            maybe_start_next(%{state | tx_queue: queue})
        end

      {:empty, _queue} ->
        state
    end
  end

  defp maybe_start_next(state), do: state

  defp stop_current(%{tx_current: nil} = state), do: state

  defp stop_current(%{tx_current: current} = state) do
    Process.cancel_timer(current.timer)

    # Without a lease (it ended) Mgmt has already removed the instance.
    if state.lease != nil, do: state.mgmt.stop_advertising(state.lease, current.instance)
    %{state | tx_current: nil}
  end

  # ── RX ───────────────────────────────────────────────────────────────

  defp fan_out(state, address, frame, rssi) do
    norm = P2.normalize(frame)
    now = System.monotonic_time(:millisecond)
    key = {address, norm}

    cond do
      state.drop_echoes and norm in state.recent_tx ->
        state

      seen_recently?(state.dedupe, key, now) ->
        state

      true ->
        report = %{mac: mac_string(address), address: address, frame: frame, rssi: rssi}

        for {pid, filter} <- state.subscribers, match?(filter, report, frame) do
          Kernel.send(pid, {:tuya_report, report})
        end

        %{state | dedupe: remember(state.dedupe, key, now)}
    end
  end

  defp match?(:all, _report, _frame), do: true
  defp match?(:unpaired, _report, frame), do: match?({:ok, _}, P2.parse_unpaired(frame))
  defp match?({:mac, mac}, report, _frame), do: report.mac == mac

  defp seen_recently?(dedupe, key, now) do
    case dedupe do
      %{^key => seen_ms} -> now - seen_ms < @dedupe_ms
      _new -> false
    end
  end

  defp remember(dedupe, key, now) do
    dedupe = Map.put(dedupe, key, now)

    if map_size(dedupe) > @dedupe_max do
      Map.filter(dedupe, fn {_key, seen_ms} -> now - seen_ms < @dedupe_ms end)
    else
      dedupe
    end
  end

  # Keep the header type handy for callers sorting frames; not used in
  # queueing (queue classes are explicit, tuya_beacon_mesh.md §4.7).
  @doc false
  def frame_type(<<hdr, _::binary>>), do: hdr >>> 3 &&& 0xF
end
