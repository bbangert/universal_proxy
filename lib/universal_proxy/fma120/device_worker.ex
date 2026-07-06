defmodule UniversalProxy.FMA120.DeviceWorker do
  @moduledoc """
  GenServer driving a single FlooGoo FMA120 over its CDC-ACM control port.

  One process per attached device, started under `FMA120.WorkerSupervisor`.
  Sole owner of the device's `Circuits.UART` session.

  ## Serialized command queue (mandatory, not an optimization)

  The firmware wedges if commands are pipelined, so the worker keeps exactly
  **one command in flight** at a time: it writes a frame, arms a per-command
  timeout, and refuses to send the next until the current one completes —
  via its `OK`/`ER`, its expected query reply, or the timeout. Callers block
  on `query/2` / `command/3`; the GenServer mailbox plus the queue serialize
  concurrent callers.

  ## Async, non-1:1 replies (constraint #2)

  Replies are event-driven, not strictly request/response. A query may
  volunteer extra `FD=` device rows, and many state queries return *nothing*
  when the dongle is idle (only `VR` always answers). So:

    * `FD`/state lines update an internal `state_cache` and are broadcast on
      `"fma120:state"` as they arrive, regardless of what's in flight.
    * A query completes on its matching header reply; a set-command completes
      on `OK`/`ER`; either completes on timeout (tolerated — no crash).

  ## Init handshake

  On open, the read-only handshake `VR → AM → ST → LA → LF → BM → BN → FN →
  FT → AC` is queued (each awaiting its reply/timeout), populating the
  `state_cache` and broadcasting state.
  """

  use GenServer

  require Logger

  alias UniversalProxy.FMA120.Protocol
  alias UniversalProxy.FMA120.Store

  # Two timeouts, picked per command in `maybe_send_next/1`:
  #   * queries (no payload) — short: idle state queries are legitimately
  #     silent (constraint #2), so don't block the queue waiting on them.
  #   * set-commands (payload) — longer: the dongle's first reply after an idle
  #     period can land past a couple seconds; a too-tight bound declares a
  #     false timeout (so the UI never sees the change) and lets the late reply
  #     desync the next command. Matches the vendor app's serial read timeout.
  @query_timeout 2_000
  @set_timeout 5_000

  # Wedge watchdog: VR always answers on a healthy channel, so consecutive VR
  # timeouts are the canary for a wedged control channel. Other commands time
  # out legitimately when the dongle is idle (constraint #2), so only VR
  # timeouts count toward the wedge threshold.
  @wedge_threshold 3
  @default_watchdog_interval 15_000
  @default_reauthorize_pause 1_000
  @default_sysfs_root "/sys/bus/usb/devices"

  # Captured at compile time so it works in releases without :mix.
  @target Mix.target()

  @pubsub UniversalProxy.PubSub
  @topic "fma120:state"

  # Read-only init handshake order (constraint: each awaits reply/timeout).
  @handshake ~w(VR AM ST LA LF BM BN FN FT AC)

  # Header → decoded-tag map for completing a *query* on its matching reply.
  # FD is intentionally absent: found-device rows are always async/volunteered.
  @reply_tags %{
    "VR" => :version,
    "AM" => :audio_mode,
    "ST" => :source_state,
    "LA" => :le_audio_state,
    "LF" => :le_preference,
    "BM" => :broadcast_mode,
    "BN" => :broadcast_name,
    "BE" => :broadcast_encryption,
    "AD" => :broadcast_address,
    "FN" => :paired_device,
    "FT" => :features,
    "AC" => :active_codec
  }

  defstruct [
    :uart_pid,
    :uart_module,
    :port_path,
    :usb_port,
    :key,
    :server_pid,
    store: Store,
    query_timeout: @query_timeout,
    set_timeout: @set_timeout,
    skip_handshake: false,
    watchdog_interval: @default_watchdog_interval,
    sysfs_root: @default_sysfs_root,
    reauthorize_pause: @default_reauthorize_pause,
    allow_reauthorize: @target != :host,
    buffer: "",
    in_flight: nil,
    queue: :queue.new(),
    state_cache: %{},
    seq: 0,
    consecutive_timeouts: 0,
    vr_timeouts: 0
  ]

  # -- Client API --

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  # Finite bound derived from the worker's own command budget: every queued
  # command completes via its reply or its per-command timer (query 2 s /
  # set 5 s, plus the 1 s wedge-recovery pause), so even a command parked
  # behind the 10-step init handshake resolves well inside this. A caller
  # timeout therefore means the worker itself is wedged — better to surface
  # `{:error, :timeout}` (see `FMA120.with_worker/2`) than hang the caller's
  # LiveView indefinitely, which is what `:infinity` did.
  @call_timeout_ms 15_000

  @doc "Query a bare header (e.g. `\"VR\"`). Routed through the serialized queue."
  @spec query(GenServer.server(), String.t()) :: {:ok, term()} | {:error, term()}
  def query(pid, header) when is_binary(header) do
    GenServer.call(pid, {:enqueue, header, nil}, @call_timeout_ms)
  end

  @doc "Send a set-command with a payload (integer hex-byte or string). Returns `:ok`/`{:error, _}`."
  @spec command(GenServer.server(), String.t(), 0..255 | binary()) :: :ok | {:error, term()}
  def command(pid, header, payload) when is_binary(header) do
    GenServer.call(pid, {:enqueue, header, payload}, @call_timeout_ms)
  end

  @doc "Fetch the worker's current cached protocol state."
  @spec get_state(GenServer.server()) :: map()
  def get_state(pid), do: GenServer.call(pid, :get_state)

  @doc """
  Fire-and-forget re-query of the given headers (results update the cache and
  broadcast on `\"fma120:state\"`). Used after connect/disconnect to refresh
  derived state without blocking the caller.
  """
  @spec refresh(GenServer.server(), [String.t()]) :: :ok
  def refresh(pid, headers) when is_list(headers), do: GenServer.cast(pid, {:refresh, headers})

  # -- Server Callbacks --

  @impl true
  def init(opts) do
    state = %__MODULE__{
      port_path: Keyword.fetch!(opts, :port_path),
      usb_port: Keyword.get(opts, :usb_port),
      key: Keyword.get(opts, :key),
      server_pid: Keyword.get(opts, :server_pid),
      uart_module: Keyword.get(opts, :uart_module, Circuits.UART),
      store: Keyword.get(opts, :store, Store),
      # `:cmd_timeout` is a legacy single-knob (tests) that sets both; otherwise
      # queries and set-commands get their own defaults.
      query_timeout: Keyword.get(opts, :query_timeout, opts[:cmd_timeout] || @query_timeout),
      set_timeout: Keyword.get(opts, :set_timeout, opts[:cmd_timeout] || @set_timeout),
      skip_handshake: Keyword.get(opts, :skip_handshake, false),
      watchdog_interval: Keyword.get(opts, :watchdog_interval, @default_watchdog_interval),
      sysfs_root: Keyword.get(opts, :sysfs_root, @default_sysfs_root),
      reauthorize_pause: Keyword.get(opts, :reauthorize_pause, @default_reauthorize_pause),
      allow_reauthorize: Keyword.get(opts, :allow_reauthorize, @target != :host)
    }

    {:ok, state, {:continue, :initialize}}
  end

  @impl true
  def handle_continue(:initialize, state) do
    case open_uart(state) do
      {:ok, uart_pid} ->
        state = %{state | uart_pid: uart_pid}
        # Queue the read-only handshake (internal commands, no `from`),
        # then re-apply any persisted preferences after the read phase.
        state =
          if state.skip_handshake do
            state
          else
            commands = Enum.map(@handshake, &{&1, nil}) ++ persisted_commands(state)
            Enum.reduce(commands, state, fn {h, p}, acc -> enqueue(acc, h, p, nil) end)
          end

        schedule_watchdog(state)
        {:noreply, maybe_send_next(state)}

      {:error, reason} ->
        Logger.error("FMA120 worker failed to open #{state.port_path}: #{inspect(reason)}")
        {:stop, {:init_failed, reason}, state}
    end
  end

  @impl true
  def handle_call({:enqueue, header, payload}, from, state) do
    {:noreply, state |> enqueue(header, payload, from) |> maybe_send_next()}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state.state_cache, state}
  end

  @impl true
  def handle_cast({:refresh, headers}, state) do
    state = Enum.reduce(headers, state, &enqueue(&2, &1, nil, nil))
    {:noreply, maybe_send_next(state)}
  end

  @impl true
  def handle_info({:circuits_uart, _port, data}, state) when is_binary(data) do
    {buffer, lines} = Protocol.feed(state.buffer, data)
    state = %{state | buffer: buffer}
    {:noreply, Enum.reduce(lines, state, &handle_line/2)}
  end

  def handle_info({:circuits_uart, _port, {:error, reason}}, state) do
    Logger.warning("FMA120 UART error on #{state.port_path}: #{inspect(reason)}")
    {:stop, {:uart_error, reason}, state}
  end

  def handle_info({:cmd_timeout, seq}, %{in_flight: %{seq: seq}} = state) do
    header = state.in_flight.header
    Logger.debug("FMA120 #{state.port_path} command timeout: #{header}")

    state = %{state | consecutive_timeouts: state.consecutive_timeouts + 1}
    state = bump_vr_timeout(state, header)
    state = complete_in_flight(state, {:error, :timeout})

    if state.vr_timeouts >= @wedge_threshold do
      Logger.error(
        "FMA120 #{state.port_path} wedged (#{state.vr_timeouts} consecutive VR timeouts); " <>
          "attempting USB re-authorize recovery"
      )

      # Callers parked in the queue would otherwise ride this abnormal
      # stop as exit({:wedged_recovered, {GenServer, :call, _}}) — fail
      # them with a clean tuple first (the in-flight caller already got
      # {:error, :timeout} via complete_in_flight above).
      state = drain_queue(state, {:error, :device_wedged})

      recover_wedged(state)
      {:stop, :wedged_recovered, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:cmd_timeout, _stale}, state), do: {:noreply, state}

  # Periodic canary: re-probe VR so a wedge is detected even when the device
  # is otherwise idle. Disabled when `watchdog_interval` is nil.
  def handle_info(:watchdog, state) do
    state = enqueue(state, "VR", nil, nil)
    schedule_watchdog(state)
    {:noreply, maybe_send_next(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.uart_pid do
      try do
        state.uart_module.close(state.uart_pid)
        state.uart_module.stop(state.uart_pid)
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  # -- Private: UART --

  defp open_uart(state) do
    with {:ok, pid} <- state.uart_module.start_link(),
         :ok <-
           state.uart_module.open(pid, state.port_path,
             speed: 921_600,
             data_bits: 8,
             stop_bits: 1,
             parity: :none,
             flow_control: :none,
             active: true
           ) do
      {:ok, pid}
    end
  end

  # -- Private: command queue --

  defp enqueue(state, header, payload, from) do
    %{state | queue: :queue.in({header, payload, from}, state.queue)}
  end

  # Reply `result` to every queued caller (refresh casts have from: nil)
  # and empty the queue. Used before an abnormal stop so blocked callers
  # get a clean error tuple instead of the raw stop reason.
  defp drain_queue(state, result) do
    state.queue
    |> :queue.to_list()
    |> Enum.each(fn {_header, _payload, from} ->
      if from, do: GenServer.reply(from, result)
    end)

    %{state | queue: :queue.new()}
  end

  # Write the next queued command only when nothing is in flight.
  defp maybe_send_next(%{in_flight: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, {header, payload, from}}, rest} ->
        seq = state.seq + 1
        frame = Protocol.encode(header, payload)

        case state.uart_module.write(state.uart_pid, frame) do
          :ok ->
            # Queries (no payload) may be legitimately silent → short timeout.
            # Set-commands should reply → longer timeout (avoids false timeout +
            # late-reply desync when the dongle is slow to answer).
            timeout = if is_nil(payload), do: state.query_timeout, else: state.set_timeout
            timer = Process.send_after(self(), {:cmd_timeout, seq}, timeout)

            %{
              state
              | queue: rest,
                seq: seq,
                in_flight: %{header: header, payload: payload, from: from, timer: timer, seq: seq}
            }

          {:error, reason} ->
            if from, do: GenServer.reply(from, {:error, reason})
            maybe_send_next(%{state | queue: rest})
        end

      {:empty, _} ->
        state
    end
  end

  defp maybe_send_next(state), do: state

  defp complete_in_flight(%{in_flight: nil} = state, _result), do: state

  defp complete_in_flight(%{in_flight: in_flight} = state, result) do
    if in_flight.timer, do: Process.cancel_timer(in_flight.timer)
    if in_flight.from, do: GenServer.reply(in_flight.from, result)

    {consecutive, vr_timeouts} =
      case result do
        {:error, :timeout} -> {state.consecutive_timeouts, state.vr_timeouts}
        # Any successful reply proves the channel is alive, so it clears the
        # wedge canary — `vr_timeouts` counts VR timeouts with no successful
        # command in between (i.e. genuinely consecutive), not a running tally.
        _ -> {0, 0}
      end

    %{state | in_flight: nil, consecutive_timeouts: consecutive, vr_timeouts: vr_timeouts}
    |> maybe_send_next()
  end

  # -- Private: wedge watchdog + USB re-authorize recovery --

  defp schedule_watchdog(%{watchdog_interval: nil}), do: :ok

  defp schedule_watchdog(%{watchdog_interval: interval}) do
    Process.send_after(self(), :watchdog, interval)
  end

  defp bump_vr_timeout(state, "VR"), do: %{state | vr_timeouts: state.vr_timeouts + 1}
  defp bump_vr_timeout(state, _header), do: state

  # Proven last-resort recovery for a wedged control channel: toggle the
  # device's `authorized` sysfs node off→on, forcing a fresh USB enumeration.
  # After this the worker stops; the Server's `:DOWN` handler re-opens a fresh
  # port. Guarded behind a target check so it's a no-op on host.
  defp recover_wedged(%{allow_reauthorize: false}), do: :ok
  defp recover_wedged(%{usb_port: nil}), do: :ok

  defp recover_wedged(state) do
    path = Path.join([state.sysfs_root, state.usb_port, "authorized"])

    case File.write(path, "0") do
      :ok ->
        Process.sleep(state.reauthorize_pause)

        case File.write(path, "1") do
          :ok ->
            :ok

          {:error, reason} ->
            # Worse than the wedge: the device is now de-authorized and we
            # failed to re-enable it. Surface it loudly.
            Logger.error(
              "FMA120 USB re-enable failed at #{path}: #{inspect(reason)} — " <>
                "device may be left de-authorized"
            )

            :error
        end

      {:error, reason} ->
        Logger.error("FMA120 USB re-authorize failed at #{path}: #{inspect(reason)}")
        :error
    end
  end

  # -- Private: persisted-preference re-apply --

  # Map persisted prefs to set-commands appended after the read handshake, so
  # a (re)connecting device gets the user's chosen settings re-applied.
  # BE (encryption) is skipped: only the boolean is persisted, never the
  # passphrase. Codec preference has no direct FlooCast set-command.
  defp persisted_commands(%{key: nil}), do: []

  defp persisted_commands(state) do
    case safe_get_config(state) do
      {:ok, cfg} ->
        [
          le_preference_command(cfg.le_preference),
          and_then(cfg.feature_flags, &{"FT", &1}),
          and_then(cfg.broadcast_mode, &{"BM", &1}),
          and_then(cfg.broadcast_name, &{"BN", &1})
        ]
        |> Enum.reject(&is_nil/1)

      :error ->
        []
    end
  end

  defp le_preference_command(:a2dp), do: {"LF", 0x00}
  defp le_preference_command(:lea), do: {"LF", 0x01}
  defp le_preference_command(_), do: nil

  defp and_then(nil, _fun), do: nil
  defp and_then(value, fun), do: fun.(value)

  defp safe_get_config(state) do
    Store.get_config(state.store, state.key)
  rescue
    e ->
      Logger.debug("FMA120 #{state.port_path} store read failed: #{inspect(e)}")
      :error
  catch
    # Store GenServer not running (e.g. test isolation) — expected, no log.
    :exit, _ -> :error
  end

  # -- Private: incoming line handling --

  defp handle_line(decoded, state) do
    state = update_cache(state, decoded)
    maybe_complete(state, decoded)
  end

  # Decide whether a decoded line completes the in-flight command.
  defp maybe_complete(%{in_flight: nil} = state, _decoded), do: state

  defp maybe_complete(state, :ok), do: complete_in_flight(state, :ok)

  defp maybe_complete(state, {:error, _code} = err), do: complete_in_flight(state, err)

  defp maybe_complete(%{in_flight: %{payload: nil, header: header}} = state, decoded)
       when is_tuple(decoded) do
    # A query (no payload) completes on its matching header reply. FD rows
    # are excluded from @reply_tags, so they never complete a query.
    if Map.get(@reply_tags, header) == elem(decoded, 0) do
      complete_in_flight(state, {:ok, decoded})
    else
      state
    end
  end

  defp maybe_complete(state, _decoded), do: state

  # -- Private: state cache + broadcast --

  defp update_cache(state, decoded) do
    case cache_partial(decoded, state.state_cache) do
      nil ->
        state

      partial ->
        cache = Map.merge(state.state_cache, partial)
        broadcast(state, partial)
        %{state | state_cache: cache}
    end
  end

  defp cache_partial({:version, v}, _cache), do: %{version: v}
  defp cache_partial({:audio_mode, m}, _cache), do: %{audio_mode: m}
  defp cache_partial({:source_state, s}, _cache), do: %{source_state: s}
  defp cache_partial({:le_audio_state, s}, _cache), do: %{le_audio_state: s}
  defp cache_partial({:le_preference, p}, _cache), do: %{le_preference: p}
  defp cache_partial({:broadcast_mode, m}, _cache), do: %{broadcast_mode: m}
  defp cache_partial({:broadcast_name, n}, _cache), do: %{broadcast_name: n}
  defp cache_partial({:broadcast_encryption, e}, _cache), do: %{broadcast_encryption: e}
  defp cache_partial({:broadcast_address, a}, _cache), do: %{broadcast_address: a}
  defp cache_partial({:features, f}, _cache), do: %{features: f}
  defp cache_partial({:active_codec, c}, _cache), do: %{active_codec: c}

  # Key the device map by MAC (stable + unique), NOT by `index`: the dongle
  # reuses index 0 across rows (and a bare `FN` list reply carries only an
  # index, no MAC), so keying by index made rows clobber each other. A row with
  # no MAC isn't a renderable device — ignore it so it can't wipe a real entry.
  defp cache_partial({tag, %{mac: mac} = device}, cache)
       when tag in [:found_device, :paired_device] and is_binary(mac) and mac != "" do
    devices = Map.get(cache, :devices, %{})
    %{devices: Map.put(devices, mac, device)}
  end

  defp cache_partial({tag, _device}, _cache) when tag in [:found_device, :paired_device], do: nil

  defp cache_partial(_other, _cache), do: nil

  # Broadcast a state partial keyed by the device key. Guarded so an
  # isolated worker (no PubSub running — host tests) doesn't crash on
  # broadcast: an unstarted PubSub registry raises ArgumentError. Only
  # that; a real broadcast failure must propagate, not vanish.
  defp broadcast(%{key: nil}, _partial), do: :ok

  defp broadcast(%{key: key}, partial) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:fma120_state, key, partial})
  rescue
    e in ArgumentError ->
      Logger.debug("FMA120 broadcast skipped (PubSub not running): #{Exception.message(e)}")
      :ok
  end
end
