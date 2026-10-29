defmodule UniversalProxy.TuyaBeaconMesh.Radio do
  @moduledoc """
  The board's single P2 radio: owns the controller lease, discovery and the
  advert receiver for one adapter, serialises transmissions, and fans
  received frames out to subscribers.

  On start (see `start_link/1`) it:

    * starts `Bluez.Radio` and `Bluez.Mgmt` when they are not running (the
      firmware's Bluetooth stack does not run them by default), then
      acquires the `:mgmt` lease for the adapter — this process is the
      lease holder, so only it may advertise;
    * opens its own system-bus connection and starts LE discovery with
      `DuplicateData: true` on the adapter;
    * starts a linked `Bluez.AdvertReceiver` whose `on_report:` callback
      casts only AD 0x03 26-byte frames here.

  On stop it takes any advert off air, stops discovery and releases the
  lease. `Bluez.Radio`/`Bluez.Mgmt` are left running: they are shared
  infrastructure and hold nothing once the lease is gone.

  ## TX

  `send_frame/3` queues a 26-byte frame for `duration_ms` of advertising
  (20/30 ms interval, connectable, no kernel `duration_ms:` — the
  controller has no hardware offload, so we stop on our own timer; see
  plan 4.4). One advert is on air at a time. Frames are sent with the
  app's queue classes (doc §4.7): a `:control` send (pair, reset, group)
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
  with incremented hop bits, which `normalize/1` erases), and echoes of
  our own recent transmissions (the last #{32} normalised frames sent)
  relayed back by bulbs. Echo dropping can be turned off with
  `drop_echoes: false` / `set_drop_echoes/2` — the 4.5 TX proof needs
  that, since a relayed copy of our frame is exactly what it looks for.

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

  # ── Client API ─────────────────────────────────────────────────────────

  @doc """
  Starts the radio for one adapter.

  Options: `:adapter_index` (default 0), `:name` (default
  `#{inspect(__MODULE__)}`), `:drop_echoes` (default `true`), and the
  `Bluez.*` implementation modules `:bluez_radio`, `:mgmt`, `:rebus`,
  `:dbus`, `:receiver` (defaults are the real ones).
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
  `{:error, :not_running}` when the radio is down, `{:error, :bad_frame}`
  for a non-26-byte frame.
  """
  @spec send_frame(binary(), non_neg_integer(), keyword()) ::
          :ok | {:error, :not_running | :bad_frame}
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
  and dropped when it exits.
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
  Radio state: adapter index, lease held, discovery on, receiver
  listening, subscriber count, what's on air (`:tx`) and how many frames
  are queued (`:queued`).
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
    state = %{
      adapter_index: Keyword.get(opts, :adapter_index, 0),
      bluez_radio: Keyword.get(opts, :bluez_radio, Bluez.Radio),
      mgmt: Keyword.get(opts, :mgmt, Bluez.Mgmt),
      rebus: Keyword.get(opts, :rebus, Bluez.Rebus),
      dbus: Keyword.get(opts, :dbus, Bluez.DBus),
      receiver: Keyword.get(opts, :receiver, Bluez.AdvertReceiver),
      drop_echoes: Keyword.get(opts, :drop_echoes, true),
      lease: nil,
      conn: nil,
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
  def handle_continue(:setup, state) do
    case setup(state) do
      {:ok, state} -> {:noreply, state}
      {:error, reason} -> {:stop, reason, state}
    end
  end

  defp setup(state) do
    ensure_started(state.bluez_radio)
    ensure_started(state.mgmt)

    with {:ok, lease} <- acquire(state),
         {:ok, conn} <- connect(state),
         :ok <- start_discovery(state, conn),
         {:ok, rx, rx_name} <- start_receiver(state) do
      {:ok, %{state | lease: lease, conn: conn, rx: rx, rx_name: rx_name, discovering: true}}
    end
  end

  # The Bluetooth stack may already run these; either answer is fine.
  defp ensure_started(module) do
    case module.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp acquire(state) do
    case state.bluez_radio.acquire(adapter_index: state.adapter_index) do
      {:ok, lease} -> {:ok, lease}
      {:error, reason} -> {:error, {:lease, reason}}
    end
  end

  defp connect(state) do
    case state.rebus.connect(:system) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, {:dbus_connect, reason}}
    end
  end

  defp start_discovery(state, conn) do
    path = "/org/bluez/hci#{state.adapter_index}"
    filter = [{"Transport", {"s", "le"}}, {"DuplicateData", {"b", true}}]

    with {:ok, _} <-
           state.dbus.call(conn, path, "org.bluez.Adapter1", "SetDiscoveryFilter", "a{sv}", [
             filter
           ]),
         {:ok, _} <-
           state.dbus.call(conn, path, "org.bluez.Adapter1", "StartDiscovery", "", []) do
      :ok
    else
      {:error, reason} -> {:error, {:discovery, reason}}
    end
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

    case state.receiver.start_link(
           name: name,
           adapter_index: state.adapter_index,
           on_report: on_report
         ) do
      {:ok, pid} -> {:ok, pid, name}
      {:error, {:already_started, pid}} -> {:ok, pid, name}
      {:error, reason} -> {:error, {:receiver, reason}}
    end
  end

  # ── TX ───────────────────────────────────────────────────────────────

  @impl GenServer
  def handle_call({:send_frame, frame, duration_ms, class}, _from, state) do
    state =
      if class == :control,
        do: %{state | tx_queue: drop_queued(state.tx_queue, :normal)},
        else: state

    job = %{frame: frame, duration_ms: duration_ms, class: class, norm: P2.normalize(frame)}
    {:reply, :ok, maybe_start_next(%{state | tx_queue: :queue.in(job, state.tx_queue)})}
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

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    _ = stop_current(state)

    if state.conn != nil and state.discovering do
      _ =
        state.dbus.call(
          state.conn,
          "/org/bluez/hci#{state.adapter_index}",
          "org.bluez.Adapter1",
          "StopDiscovery",
          "",
          []
        )
    end

    if state.rx != nil and Process.alive?(state.rx) do
      try do
        GenServer.stop(state.rx, :normal, 2_000)
      catch
        :exit, _reason -> :ok
      end
    end

    if state.lease != nil, do: state.bluez_radio.release(state.lease)
    :ok
  end

  defp drop_queued(queue, class) do
    :queue.filter(fn job -> job.class != class end, queue)
  end

  defp maybe_start_next(%{tx_current: nil} = state) do
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

          {:error, reason} ->
            Logger.warning(
              "UniversalProxy.TuyaBeaconMesh.Radio: advertise failed (#{inspect(reason)}), dropping frame"
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
    _ = state.mgmt.stop_advertising(state.lease, current.instance)
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
  # queueing (queue classes are explicit, doc §4.7).
  @doc false
  def frame_type(<<hdr, _::binary>>), do: hdr >>> 3 &&& 0xF
end
