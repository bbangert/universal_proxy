defmodule UniversalProxy.BTD700.DeviceWorker do
  @moduledoc """
  GenServer driving a single Sennheiser BTD 700 over its hidraw control
  channel. One process per attached dongle, started under
  `BTD700.WorkerSupervisor`.

  ## Dual-fd design (constraint: `:raw` fds are process-bound)

  The worker owns the **writer** fd itself (opened in
  `handle_continue/2`). It then `spawn_link`s a reader child that opens
  its **own** fd and blocks in `Transport.read/2` forever, forwarding
  every report to the worker as `{:hid_report, bin}` — hidraw fans input
  reports out to every open fd on the node, but a `:raw` fd can only be
  read by the process that opened it (see `BTD700.Transport`'s
  moduledoc). The reader closes its fd in an `after` clause on every exit
  path it takes itself (normal errors, `:enodev`/`:eio`); the worker never
  touches the reader's fd. When the reader exits (any non-`:normal`
  reason, notably `{:shutdown, :device_gone}` on unplug), the link takes
  this worker down with it — `BTD700.Server`'s `:DOWN` handling owns
  restart policy, not this module.

  ## Serialized command queue

  Exactly **one command in flight** at a time: `:queue` of
  `{cmd, args, from}`. `from` is a real `GenServer` "from" tuple for a
  blocking caller, or `nil` for a fire-and-forget re-query — both the
  `refresh/2` cast and the periodic wedge-watchdog poll below use `nil`;
  only a truthy `from` gets `GenServer.reply/2`.

  Because responses arrive as reader messages rather than inline reads,
  the upstream reference driver's retry-attempt/event-starvation
  conflation (event reports draining the same read loop a response would
  otherwise occupy, exhausting a fixed attempt budget before the real
  reply is ever seen) is **structurally absent** here: async events and
  responses are just different messages in this GenServer's mailbox, so
  the in-flight command's completion never competes with event traffic
  for "the next read".

  ## Init handshake

  On open, the read-only handshake (firmware version through sink
  transport, in the plan's fixed order) is queued, followed by any
  persisted preferences from `BTD700.Store` mapped to their `set_*`
  commands. `get_broadcast_key` and gaming status (`0x17`, unsendable —
  `Protocol` has no encoder for it) are never queried.

  ## Wedge watchdog

  A `get_dongle_state` self-poll (`from: nil`) runs every 30 s.
  `@wedge_threshold` (3) **consecutive** timeouts of `get_dongle_state`
  specifically (any successful reply in between resets the count — the
  same "any live traffic proves the channel isn't wedged" logic FMA120
  uses for its `VR` canary; and, like FMA120's `VR`, this counts *any*
  `get_dongle_state` timeout, whether it came from the watchdog, the init
  handshake, or a caller — there's no separate "watchdog-only" tag)
  escalate to `recover_wedged/1`: drain the queue with
  `{:error, :device_wedged}`, then toggle the device's sysfs `authorized`
  attribute off then on. The kernel drops the hidraw node on de-authorize,
  which unblocks the reader's parked read with `:enodev` for a clean
  teardown — never attempt to close the reader's fd directly.
  """

  use GenServer

  require Logger

  import Bitwise

  alias UniversalProxy.BTD700.Protocol
  alias UniversalProxy.BTD700.Store
  alias UniversalProxy.BTD700.Transport

  @query_timeout 2_000
  @set_timeout 5_000

  # Consecutive `get_dongle_state` timeouts (not any-command timeouts —
  # other getters legitimately go unanswered when the dongle is idle, per
  # protocol-payloads.md) before we declare the channel wedged. Mirrors
  # FMA120's `VR`-keyed wedge canary.
  @wedge_threshold 3
  @default_watchdog_interval 30_000
  @default_reauthorize_pause 1_000
  @default_sysfs_root "/sys/bus/usb/devices"

  # Captured at compile time so it works in releases without :mix.
  @target Mix.target()

  @pubsub UniversalProxy.PubSub
  @topic "btd700:state"

  # Read-only init handshake, in the plan's fixed order. Deliberately
  # excludes `get_broadcast_key` (the worker never reads the Auracast key —
  # the UI only needs the `encryption` boolean from `get_broadcast_info`)
  # and there is no atom for gaming status (`0x17`) at all: `Protocol`
  # defines no encoder for it, so it is unsendable by construction (a
  # blocked read on that command is uninterruptible — see
  # `research/hw-probe.md` and `research/beam-hidraw-io.md`).
  @handshake ~w(
    get_firmware_version get_audio_mode get_supported_codecs get_codec_in_use
    get_dongle_state get_le_audio_state get_audio_quality get_broadcast_info
    get_broadcast_name get_sink_transport
  )a

  # Getter atom -> the bare atom `Protocol.decode/1` tags its response with
  # (setters/triggers echo back their own atom unchanged — see
  # `Protocol`'s `@response_ids` comment on why that's true by
  # construction). Used to match an in-flight command to its reply.
  @response_atom_for_getter %{
    get_audio_mode: :audio_mode,
    get_supported_codecs: :supported_codecs,
    get_codec_in_use: :codec_in_use,
    get_dongle_state: :dongle_state,
    get_le_audio_state: :le_audio_state,
    get_audio_quality: :audio_quality,
    get_broadcast_info: :broadcast_info,
    get_broadcast_key: :broadcast_key,
    get_broadcast_name: :broadcast_name,
    get_firmware_version: :firmware_version,
    get_sink_transport: :sink_transport
  }

  defstruct [
    :device_path,
    :usb_port,
    :key,
    :server_pid,
    :writer_fd,
    :reader_pid,
    transport_module: Transport,
    store: Store,
    query_timeout: @query_timeout,
    set_timeout: @set_timeout,
    skip_handshake: false,
    watchdog_interval: @default_watchdog_interval,
    sysfs_root: @default_sysfs_root,
    reauthorize_pause: @default_reauthorize_pause,
    allow_reauthorize: @target != :host,
    in_flight: nil,
    queue: :queue.new(),
    state_cache: %{},
    seq: 0,
    watchdog_timeouts: 0
  ]

  # -- Client API --

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  # Every queued command completes via its reply or its own timer (query
  # 2 s / set 5 s, plus a 1 s wedge-recovery pause) so even a call parked
  # behind the full init handshake resolves well inside this bound. A
  # caller timeout past this means the worker itself is wedged.
  @call_timeout_ms 15_000

  @doc """
  Send a command (getter, setter, or trigger). Routed through the serialized
  queue. `args` is normally a binary, but — like the persisted-prefs re-apply
  path (`resolve_args/2`) — may instead be a 1-arity fun of this worker's
  internal state, resolved at send time rather than enqueue time. The
  `BTD700` boundary's `set_audio_mode/2` relies on this: the transport byte
  paired with a persisted audio-mode preference isn't itself a stored
  preference, so it must be read from `state_cache` at the moment the
  command is actually written, not when the caller enqueues it.
  """
  @spec command(GenServer.server(), atom(), binary() | (term() -> binary())) ::
          {:ok, term()} | {:error, term()}
  def command(pid, cmd, args \\ <<>>)
      when is_atom(cmd) and (is_binary(args) or is_function(args, 1)) do
    GenServer.call(pid, {:enqueue, cmd, args}, @call_timeout_ms)
  end

  @doc "Fetch the worker's current cached protocol state."
  @spec get_state(GenServer.server()) :: map()
  def get_state(pid), do: GenServer.call(pid, :get_state)

  @doc """
  Fire-and-forget re-query of a single getter (result updates the cache and
  broadcasts on `"btd700:state"`). Used after a setter's ack (which carries
  no parsed payload) so the UI never shows a stale pre-write value.
  """
  @spec refresh(GenServer.server(), atom()) :: :ok
  def refresh(pid, cmd) when is_atom(cmd), do: GenServer.cast(pid, {:refresh, cmd})

  # -- Server Callbacks --

  @impl true
  def init(opts) do
    state = %__MODULE__{
      device_path: Keyword.fetch!(opts, :device_path),
      usb_port: Keyword.get(opts, :usb_port),
      key: Keyword.get(opts, :key),
      server_pid: Keyword.get(opts, :server_pid),
      transport_module: Keyword.get(opts, :transport_module, Transport),
      store: Keyword.get(opts, :store, Store),
      query_timeout: Keyword.get(opts, :query_timeout, @query_timeout),
      set_timeout: Keyword.get(opts, :set_timeout, @set_timeout),
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
    with {:ok, writer_fd} <- state.transport_module.open(state.device_path),
         state = %{state | writer_fd: writer_fd},
         {:ok, reader_pid} <- start_reader(state) do
      state = %{state | reader_pid: reader_pid}

      state =
        if state.skip_handshake do
          state
        else
          commands = Enum.map(@handshake, &{&1, <<>>}) ++ persisted_commands(state)
          Enum.reduce(commands, state, fn {cmd, args}, acc -> enqueue(acc, cmd, args, nil) end)
        end

      schedule_watchdog(state)
      {:noreply, maybe_send_next(state)}
    else
      {:error, reason} ->
        Logger.error("BTD700 worker failed to open #{state.device_path}: #{inspect(reason)}")
        {:stop, {:init_failed, reason}, state}
    end
  end

  @impl true
  def handle_call({:enqueue, cmd, args}, from, state) do
    {:noreply, state |> enqueue(cmd, args, from) |> maybe_send_next()}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state.state_cache, state}
  end

  @impl true
  def handle_cast({:refresh, cmd}, state) do
    {:noreply, state |> enqueue(cmd, <<>>, nil) |> maybe_send_next()}
  end

  @impl true
  def handle_info({:hid_report, bin}, state) do
    {:noreply, handle_report(state, Protocol.decode(bin))}
  end

  def handle_info({:cmd_timeout, seq}, %{in_flight: %{seq: seq}} = state) do
    cmd = state.in_flight.cmd
    Logger.debug("BTD700 #{state.device_path} command timeout: #{cmd}")

    state = bump_watchdog_timeout(state, cmd)
    state = complete_in_flight(state, {:error, :timeout})

    if state.watchdog_timeouts >= @wedge_threshold do
      Logger.error(
        "BTD700 #{state.device_path} wedged (#{state.watchdog_timeouts} consecutive " <>
          "get_dongle_state timeouts); attempting USB re-authorize recovery"
      )

      # Callers still parked in the queue would otherwise ride the abnormal
      # stop below as a raw exit — fail them with a clean tuple first (the
      # in-flight caller already got {:error, :timeout} via
      # complete_in_flight above).
      state = drain_queue(state, {:error, :device_wedged})
      recover_wedged(state)
      {:stop, :wedged_recovered, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:cmd_timeout, _stale}, state), do: {:noreply, state}

  # Periodic canary: re-probe dongle state so a wedge is detected even when
  # the device is otherwise idle. Disabled when `watchdog_interval` is nil.
  def handle_info(:watchdog, state) do
    state = enqueue(state, :get_dongle_state, <<>>, nil)
    schedule_watchdog(state)
    {:noreply, maybe_send_next(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.writer_fd do
      try do
        state.transport_module.close(state.writer_fd)
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  # -- Private: reader child --

  defp start_reader(state) do
    parent = self()
    transport = state.transport_module
    path = state.device_path

    {:ok, spawn_link(fn -> reader_loop(parent, transport, path) end)}
  end

  # The reader never returns: it either loops in `read_forever/3` or
  # `exit/1`s (device gone, open failure, unknown read error).
  @spec reader_loop(pid(), module(), String.t()) :: no_return()
  defp reader_loop(parent, transport, path) do
    case transport.open(path) do
      {:ok, fd} ->
        try do
          read_forever(parent, transport, fd)
        after
          # Runs on every exit path *this process itself* takes (the
          # normal cases below). A forced kill via the worker link (e.g.
          # wedge recovery's re-authorize propagating back, or the worker
          # crashing) skips Elixir-level unwinding entirely — but a `:raw`
          # fd is process-bound, so the runtime reclaims it the moment its
          # owning process dies either way. The worker itself must never
          # close this fd.
          transport.close(fd)
        end

      {:error, reason} ->
        exit({:shutdown, {:reader_open_failed, reason}})
    end
  end

  defp read_forever(parent, transport, fd) do
    case transport.read(fd, 64) do
      {:ok, data} ->
        send(parent, {:hid_report, data})
        read_forever(parent, transport, fd)

      :eof ->
        exit({:shutdown, :device_gone})

      {:error, reason} when reason in [:enodev, :eio] ->
        exit({:shutdown, :device_gone})

      {:error, reason} ->
        exit({:shutdown, {:device_error, reason}})
    end
  end

  # -- Private: command queue --

  defp enqueue(state, cmd, args, from) do
    %{state | queue: :queue.in({cmd, args, from}, state.queue)}
  end

  # Reply `result` to every queued caller (refresh casts and the watchdog
  # poll have `from: nil`, so they're skipped) and empty the queue. Used
  # before an abnormal stop so blocked callers get a clean error tuple
  # instead of the raw stop reason.
  defp drain_queue(state, result) do
    state.queue
    |> :queue.to_list()
    |> Enum.each(fn {_cmd, _args, from} ->
      if from, do: GenServer.reply(from, result)
    end)

    %{state | queue: :queue.new()}
  end

  # Write the next queued command only when nothing is in flight.
  defp maybe_send_next(%{in_flight: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, {cmd, args, from}}, rest} ->
        seq = state.seq + 1
        args = resolve_args(args, state)
        frame = Protocol.encode(cmd, args)

        case state.transport_module.write(state.writer_fd, frame) do
          :ok ->
            timer = Process.send_after(self(), {:cmd_timeout, seq}, timeout_for(cmd, state))

            %{
              state
              | queue: rest,
                seq: seq,
                in_flight: %{cmd: cmd, args: args, from: from, timer: timer, seq: seq}
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

  # A queued command may carry a 1-arity fun instead of a binary — resolved
  # against the state at SEND time, not enqueue time. The one-in-flight
  # queue guarantees every handshake response ahead of a persisted setter
  # has already been merged into `state_cache` when the setter is sent.
  defp resolve_args(args, _state) when is_binary(args), do: args
  defp resolve_args(args, state) when is_function(args, 1), do: args.(state)

  # Getters (idle state may legitimately never answer) get the short
  # timeout; setters/triggers get the longer one — same split as FMA120.
  defp timeout_for(cmd, state) do
    if cmd |> Atom.to_string() |> String.starts_with?("get_") do
      state.query_timeout
    else
      state.set_timeout
    end
  end

  defp complete_in_flight(%{in_flight: nil} = state, _result), do: state

  defp complete_in_flight(%{in_flight: in_flight} = state, result) do
    if in_flight.timer, do: Process.cancel_timer(in_flight.timer)
    if in_flight.from, do: GenServer.reply(in_flight.from, result)

    # Any successful completion proves the channel is alive, clearing the
    # wedge canary; a timeout leaves whatever the caller already bumped
    # (see the {:cmd_timeout, seq} handler) untouched.
    watchdog_timeouts =
      case result do
        {:error, :timeout} -> state.watchdog_timeouts
        _ -> 0
      end

    %{state | in_flight: nil, watchdog_timeouts: watchdog_timeouts}
    |> maybe_send_next()
  end

  defp bump_watchdog_timeout(state, :get_dongle_state),
    do: %{state | watchdog_timeouts: state.watchdog_timeouts + 1}

  defp bump_watchdog_timeout(state, _cmd), do: state

  # -- Private: incoming report handling --

  defp handle_report(
         %{in_flight: %{cmd: cmd} = in_flight} = state,
         {:response, resp_atom, payload}
       ) do
    if Map.get(@response_atom_for_getter, cmd, cmd) == resp_atom do
      # Setter acks carry no parsed body (`%{}`) — completing the call is
      # all they're good for. Caching/broadcasting them would litter the
      # state cache with `:set_*` keys; UI freshness after a setter comes
      # from the boundary's send_and_refresh re-query instead.
      state
      |> maybe_cache_and_broadcast(cmd, resp_atom, payload)
      |> complete_in_flight({:ok, payload})
    else
      # Stale response: doesn't match what's in flight. Because replies
      # arrive as messages rather than inline reads, this can only happen
      # from a genuinely late/duplicate report — never from the retry-
      # attempt-budget exhaustion the upstream driver is prone to (there is
      # no read-attempt budget to exhaust here). Drop it; the in-flight
      # command still resolves on its own reply or its own timer.
      Logger.debug(
        "BTD700 #{state.device_path} stale response #{resp_atom} while #{in_flight.cmd} in flight, dropped"
      )

      state
    end
  end

  defp handle_report(state, {:response, resp_atom, payload}) do
    # No in-flight command at all (e.g. a very late reply after a
    # completed/timed-out call) — still worth caching, never worth acking.
    cache_and_broadcast(state, resp_atom, payload)
  end

  defp handle_report(state, {:event, evt, payload}) do
    # Async events are never acked: 0xFD (the ack marker) is never sent by
    # this driver or by any known consumer of the protocol.
    cache_and_broadcast(state, evt, payload)
  end

  defp handle_report(state, :ignore), do: state

  defp handle_report(state, {:unknown, bin}) do
    Logger.debug("BTD700 #{state.device_path} unknown report: #{inspect(bin)}")
    state
  end

  # -- Private: state cache + broadcast --

  defp maybe_cache_and_broadcast(state, cmd, resp_atom, payload) do
    if Map.has_key?(@response_atom_for_getter, cmd) do
      cache_and_broadcast(state, resp_atom, payload)
    else
      state
    end
  end

  # The Auracast key must never reach the state cache or the PubSub topic
  # (LiveView merges broadcasts straight into socket assigns). Nothing in
  # the app queries it today — this guard keeps the invariant even if a
  # future caller sends :get_broadcast_key through the public command/3
  # (the caller still gets the key in its transient reply; it just never
  # lands anywhere persistent).
  defp cache_and_broadcast(state, :broadcast_key, _payload), do: state

  defp cache_and_broadcast(state, field, payload) do
    partial = %{field => payload}
    broadcast(state, partial)
    %{state | state_cache: Map.merge(state.state_cache, partial)}
  end

  # Guarded so an isolated worker (no PubSub running — host tests) doesn't
  # crash on broadcast: an unstarted PubSub registry raises ArgumentError.
  # Only that; a real broadcast failure must propagate, not vanish.
  defp broadcast(%{key: nil}, _partial), do: :ok

  defp broadcast(%{key: key}, partial) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:btd700_state, key, partial})
  rescue
    e in ArgumentError ->
      Logger.debug("BTD700 broadcast skipped (PubSub not running): #{Exception.message(e)}")
      :ok
  end

  # -- Private: wedge watchdog + USB re-authorize recovery --

  defp schedule_watchdog(%{watchdog_interval: nil}), do: :ok

  defp schedule_watchdog(%{watchdog_interval: interval}) do
    Process.send_after(self(), :watchdog, interval)
  end

  # Proven (FMA120) last-resort recovery for a wedged control channel:
  # toggle the device's `authorized` sysfs node off -> on, forcing a fresh
  # USB enumeration. This worker stops right after; the Server's `:DOWN`
  # handler re-opens against the freshly enumerated device. No-op on host
  # or when there's no usb_port to re-authorize.
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
            # Worse than the wedge: now de-authorized and failed to
            # re-enable. Surface it loudly.
            Logger.error(
              "BTD700 USB re-enable failed at #{path}: #{inspect(reason)} — " <>
                "device may be left de-authorized"
            )

            :error
        end

      {:error, reason} ->
        Logger.error("BTD700 USB re-authorize failed at #{path}: #{inspect(reason)}")
        :error
    end
  end

  # -- Private: persisted-preference re-apply --

  # Map persisted prefs (`BTD700.Store`) to set-commands appended after the
  # read handshake, so a (re)connecting device gets the user's chosen
  # settings re-applied. The Auracast broadcast key is never re-applied —
  # it is never persisted in the first place (`Store`'s moduledoc); only
  # the `broadcast_encryption` boolean round-trips.
  defp persisted_commands(%{key: nil}), do: []

  defp persisted_commands(state) do
    case safe_get_config(state) do
      {:ok, cfg} ->
        [
          audio_mode_command(cfg.audio_mode),
          codec_mask_command(cfg.codec_mask),
          broadcast_info_command(cfg),
          broadcast_name_command(cfg.broadcast_name)
        ]
        |> Enum.reject(&is_nil/1)

      :error ->
        []
    end
  end

  # Inverse of `Protocol`'s private `@audio_modes` decode map — Protocol
  # exposes no public atom->wire encoder for enums (only raw-binary
  # `encode/2`), so this mapping is kept in sync by hand.
  @audio_mode_wire %{high_quality: 0, gaming: 1, broadcast: 2}

  # Inverse of `Protocol`'s private `@transport_modes` decode map (same
  # kept-in-sync-by-hand rationale as `@audio_mode_wire`).
  @transport_wire %{disconnected: 0, classic: 1, le_audio: 2, multipoint: 3}

  defp audio_mode_command(nil), do: nil

  # Persisted prefs never capture a transport preference (only `audio_mode`
  # is stored — see `Store`'s moduledoc), and 0 is a real enum value
  # (disconnected), not an "auto" placeholder — so the re-applied mode is
  # paired with the CURRENT transport, read from the handshake's
  # `get_audio_mode` response via deferred args (see `resolve_args/2`).
  defp audio_mode_command(mode) do
    case Map.fetch(@audio_mode_wire, mode) do
      {:ok, wire} -> {:set_audio_mode, fn state -> <<wire, current_transport_wire(state)>> end}
      :error -> nil
    end
  end

  # Falls back to 0 only when the handshake's audio_mode never decoded
  # (e.g. a `%{raw: _}` short-payload response).
  defp current_transport_wire(state) do
    with %{transport: transport} <- Map.get(state.state_cache, :audio_mode),
         {:ok, wire} <- Map.fetch(@transport_wire, transport) do
      wire
    else
      _ -> 0
    end
  end

  # Bit positions mirror Protocol's private `@codec_bits` (decode
  # direction) — duplicated here for the same reason as `@audio_mode_wire`.
  @codec_bit_position %{
    sbc: 0,
    aptx: 1,
    aptx_adaptive: 2,
    aptx_lossless: 3,
    aptx_lite: 4,
    lc3: 5
  }

  defp codec_mask_command(nil), do: nil
  defp codec_mask_command([]), do: nil

  defp codec_mask_command(codecs) when is_list(codecs) do
    mask =
      Enum.reduce(codecs, 0, fn codec, acc ->
        case Map.fetch(@codec_bit_position, codec) do
          {:ok, bit} -> acc ||| 1 <<< bit
          :error -> acc
        end
      end)

    {:set_codec_mask, <<mask::16-little>>}
  end

  @broadcast_state_wire %{off_private: 0, on_public: 1}
  @broadcast_quality_wire %{standard_16k: 0, standard_24k: 1, high: 2}

  # Only re-applied once broadcast has actually been configured
  # (`broadcast_state` non-nil); `broadcast_quality` defaults to the lowest
  # setting if the user only ever touched state/encryption.
  defp broadcast_info_command(%{broadcast_state: nil}), do: nil

  defp broadcast_info_command(cfg) do
    with {:ok, state_byte} <- Map.fetch(@broadcast_state_wire, cfg.broadcast_state),
         {:ok, quality_byte} <-
           Map.fetch(@broadcast_quality_wire, cfg.broadcast_quality || :standard_16k) do
      encryption_byte = if cfg.broadcast_encryption, do: 1, else: 0
      {:set_broadcast_info, <<state_byte, encryption_byte, quality_byte>>}
    else
      :error -> nil
    end
  end

  defp broadcast_name_command(nil), do: nil
  defp broadcast_name_command(""), do: nil
  defp broadcast_name_command(name) when is_binary(name), do: {:set_broadcast_name, name}

  defp safe_get_config(state) do
    Store.get_config(state.store, state.key)
  rescue
    e ->
      Logger.debug("BTD700 #{state.device_path} store read failed: #{inspect(e)}")
      :error
  catch
    # Store GenServer not running (e.g. test isolation) — expected, no log.
    :exit, _ -> :error
  end
end
