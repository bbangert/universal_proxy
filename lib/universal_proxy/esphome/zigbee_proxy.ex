defmodule UniversalProxy.ESPHome.ZigbeeProxy do
  @moduledoc """
  GenServer that owns the Home Assistant Connect ZBT-2's tty from USB
  attach to detach and serves ESPHome serial-proxy *sessions* on it.

  Like `UniversalProxy.ESPHome.ZWaveProxy` it is NOT managed through the
  shared `UART.Server`: ESPHome hardware opens its USB UART once when the
  device attaches and keeps it open across client sessions, and the ZBT-2
  needs that. Every close of a tty lowers DTR/RTS, which some ZBT-2
  bridge firmware wires to the radio's reset/boot lines, and every
  CONFIGURE that reopened the port would add a line-coding change, which
  the bridge reads as a signalling channel (magic bauds enter its
  bootloader).

  ## Lifecycle

  - On init it resolves the port through `:resolver` (the first connected
    `kind: :zigbee` row of `UniversalProxy.Hardware.list_ports/0`) and
    opens `Circuits.UART` at 460800 8N1, no flow control, `active: true`.
    The open raises DTR and RTS, which is the modem state cached at
    open. The UART is started with `Circuits.UART.start_link/0`, never
    under `UART.PortSupervisor`, so `UART.Server`'s orphan sweep can't
    reach it.
  - No port, or a failed open, arms a 5 s rescan that re-resolves each
    time, so a stick plugged in after boot (or replugged onto another
    tty) attaches without restarting the supervision tree.
  - On a UART error the tty is closed, the ASH acknowledger and the RX
    buffer are reset, `uart:port_closed` is broadcast, and the rescan
    starts. Sessions, the subscription and its mode survive the
    disconnect (upstream semantics: ACKs resume on reconnect without a
    new SET_MODE), but writes, configure and modem pins answer
    `{:error, :not_attached}` until the tty is back. A reopen starts from
    the default line settings and DTR=RTS=true again, as an ESPHome USB
    UART does on re-attach.
  - Exits are trapped so `terminate/2` closes the tty and broadcasts
    `uart:port_closed` on a supervisor shutdown. A crash of the linked
    UART process still stops this server.
  - All traffic is mirrored on `UART.Server`'s PubSub topics
    (`uart:port_opened`/`uart:port_closed` with `owner: :zigbee_proxy`,
    and `uart:<ha_name>` `:uart_data`), so `UART.History` feeds the
    Overview and Traffic tab like any proxied port. Locally generated
    ASH ACKs are `:tx` frames tagged `origin: :ash_ack`.

  ## Sessions vs the tty

  A session is one espex serial-proxy handle (`attach/3` returns its
  ref). Several may exist at once (espex opens a second handle for a
  non-owner's GET_MODEM_PINS); detaching one never closes the tty. A
  session's subscriber pid is monitored and its death detaches it.

  At most one session is *subscribed*: it receives the RX stream as
  `{:espex_serial_data, {:zigbee, ref}, binary}`, and only it may write
  or change the mode. A second live session's `subscribe/2` gets
  `{:error, :port_in_use}`; a subscribed session whose pid is already
  dead (its `:DOWN` not yet handled) is taken over. espex enforces the
  same single-owner rule one level up; this is the defensive copy.
  Configure and modem pins are accepted from any attached session, as
  espex only forwards them for the owner.

  While nobody is subscribed, RX bytes are kept in a 256-byte buffer
  (upstream `usb_uart`'s default FIFO), oldest bytes dropped on
  overflow, and delivered to the next session that subscribes before any
  new data. That also bridges the detach/attach window of an espex 0.12
  CONFIGURE.

  ## Line settings

  `attach/3` and `configure/3` take espex `open_opts`. Settings equal to
  the live ones are a no-op with no ioctl at all, since a repeated
  identical baud must not reach the bridge; otherwise exactly one
  `Circuits.UART.configure/2` is issued. A speed of 0 or less is refused
  (B0 would drop DTR). `flow_control: :hardware` is accepted (it does
  nothing on cdc_acm). On failure the old settings are kept.

  ## PROTOCOL mode (ASH)

  The subscribed session can switch the port to `:protocol` with
  `set_mode/3`, which runs `ZigbeeProxy.Ash` on the NCP → host stream:
  DATA frames are ACKed locally, the ACKs written to the UART *before*
  the bytes are forwarded, so the ACK is not stuck behind the network
  round-trip. The acknowledger is an observer only, the subscriber always
  gets the original bytes. The RAW → PROTOCOL edge resets it, PROTOCOL →
  RAW does not (stale numbering is dropped at the next enable), and a
  new subscription always starts in `:raw`; unsubscribing or detaching
  the subscribed session forces `:raw` silently.

  ## Modem lines

  `set_modem_pins/4` keeps a cached `%{rts, dtr}` and skips lines that
  don't change. `get_modem_pins/2` answers from the cache (the last
  requested state, as upstream). Circuits.UART can only set one line per
  ioctl, so a change of both lines is two calls, DTR first then RTS: the
  flasher's (dtr 0, rts 1) → (1, 0) step shows a transient (1, 1) on the
  wire, where upstream sends a single SET_CONTROL_LINE_STATE. The cache
  follows only the calls that succeeded.
  """

  # Circuits.UART.close/1 and stop/1 each wait up to 5 s, so terminate/2
  # can take ~10 s on a wedged UART; the child shutdown budget must exceed it.
  use GenServer, shutdown: 12_000

  require Logger

  alias UniversalProxy.ESPHome.ZigbeeProxy.Ash

  @typedoc "A session, as returned by `attach/3`."
  @type session :: reference()

  @type mode :: :raw | :protocol

  @type modem_pins :: %{rts: boolean(), dtr: boolean()}

  @type status :: %{attached?: boolean(), error?: boolean(), port: map() | nil}

  # Calls sit inside Home Assistant's 1 s serial-proxy open budget
  # (SUBSCRIBE, SET_MODE, CONFIGURE), so each gets a tight ceiling.
  @call_timeout 500
  # A write can legitimately take a while at a low bootloader baud; the
  # UART write gets its own ceiling, the call a little more.
  @uart_write_timeout 1_000
  # An ASH ACK is 5 bytes and is written from the RX handler, so a stuck
  # UART must not hold the owner for the full client-write ceiling.
  @ack_write_timeout 200
  @write_call_timeout 1_500

  @reopen_interval 5_000

  @rx_buffer_size 256

  @default_line %{speed: 460_800, data_bits: 8, stop_bits: 1, parity: :none, flow_control: :none}
  @default_modem %{rts: true, dtr: true}
  @line_keys [:speed, :data_bits, :stop_bits, :parity, :flow_control]

  @pubsub UniversalProxy.PubSub

  defstruct [
    :uart_pid,
    :port_path,
    :display_name,
    :port,
    :resolver,
    :reopen_timer,
    :last_open_error,
    :subscribed,
    error?: false,
    mode: :raw,
    sessions: %{},
    line: @default_line,
    modem: @default_modem,
    ash: nil,
    rx_buffer: <<>>,
    open_fun: nil
  ]

  def start_link(opts \\ []) do
    gen_opts =
      case Keyword.get(opts, :name, __MODULE__) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  # -- Public API --
  #
  # Every wrapper follows the project's `catch :exit` idiom, but a call
  # timeout is caught first and answered `{:error, :timeout}`, so a
  # wedged owner is not mistaken for an absent device.

  @doc """
  Start a session for `subscriber` and apply `opts` (espex `open_opts`)
  to the line. Fails with `:not_attached` when no tty is open.
  """
  @spec attach(GenServer.server(), keyword(), pid()) ::
          {:ok, session()}
          | {:error, :not_attached | :invalid_speed | :invalid_argument | :timeout | term()}
  def attach(server \\ __MODULE__, opts, subscriber) when is_list(opts) and is_pid(subscriber) do
    call(server, {:attach, opts, subscriber}, {:error, :not_attached})
  end

  @doc """
  End a session. The tty stays open. Detaching the subscribed session
  drops the subscription and returns the port to `:raw`. Idempotent.
  """
  @spec detach(GenServer.server(), session()) :: :ok | {:error, :timeout}
  def detach(server \\ __MODULE__, session) when is_reference(session) do
    call(server, {:detach, session}, :ok)
  end

  @doc """
  Make `session` the one that receives RX data, first delivering any
  bytes buffered while nobody was subscribed. Idempotent for the
  subscribed session; the subscription starts in `:raw`.
  """
  @spec subscribe(GenServer.server(), session()) ::
          :ok | {:error, :port_in_use | :unknown_session | :not_attached | :timeout}
  def subscribe(server \\ __MODULE__, session) when is_reference(session) do
    call(server, {:subscribe, session}, {:error, :not_attached})
  end

  @doc """
  Drop `session`'s subscription (if it holds it) and return the port to
  `:raw`. Idempotent.
  """
  @spec unsubscribe(GenServer.server(), session()) :: :ok | {:error, :timeout}
  def unsubscribe(server \\ __MODULE__, session) when is_reference(session) do
    call(server, {:unsubscribe, session}, :ok)
  end

  @doc """
  Switch the port between `:raw` and `:protocol` (ASH acknowledger).
  Only the subscribed session may; anyone else gets `:port_in_use`.
  """
  @spec set_mode(GenServer.server(), session(), mode()) ::
          :ok | {:error, :port_in_use | :invalid_argument | :not_attached | :timeout}
  def set_mode(server \\ __MODULE__, session, mode) when is_reference(session) do
    call(server, {:set_mode, session, mode}, {:error, :not_attached})
  end

  @doc """
  Write `data` to the tty. Only the subscribed session may write.
  """
  @spec write(GenServer.server(), session(), iodata()) ::
          :ok | {:error, :not_attached | :port_in_use | :timeout | term()}
  def write(server \\ __MODULE__, session, data) when is_reference(session) do
    call(server, {:write, session, data}, {:error, :not_attached}, @write_call_timeout)
  end

  @doc """
  Apply `opts` (espex `open_opts`) to the line for an existing session.
  Settings equal to the live ones touch nothing.
  """
  @spec configure(GenServer.server(), session(), keyword()) ::
          :ok
          | {:error,
             :not_attached
             | :unknown_session
             | :invalid_speed
             | :invalid_argument
             | :timeout
             | term()}
  def configure(server \\ __MODULE__, session, opts)
      when is_reference(session) and is_list(opts) do
    call(server, {:configure, session, opts}, {:error, :not_attached})
  end

  @doc """
  Set the RTS and DTR lines (espex argument order). Unchanged lines are
  skipped; a change of both sets DTR, then RTS.
  """
  @spec set_modem_pins(GenServer.server(), session(), boolean(), boolean()) ::
          :ok | {:error, :not_attached | :unknown_session | :timeout | term()}
  def set_modem_pins(server \\ __MODULE__, session, rts, dtr)
      when is_reference(session) and is_boolean(rts) and is_boolean(dtr) do
    call(server, {:set_modem_pins, session, rts, dtr}, {:error, :not_attached})
  end

  @doc """
  The last requested RTS/DTR state.
  """
  @spec get_modem_pins(GenServer.server(), session()) ::
          {:ok, modem_pins()} | {:error, :not_attached | :unknown_session | :timeout}
  def get_modem_pins(server \\ __MODULE__, session) when is_reference(session) do
    call(server, {:get_modem_pins, session}, {:error, :not_attached})
  end

  @doc """
  The live line settings as espex `open_opts`, for
  `c:Espex.SerialProxy.default_open_opts/1`: a lazy open with these is a
  no-op. Without a tty (or a reachable server) these are the settings the
  next open uses.
  """
  @spec current_opts(GenServer.server()) :: Espex.SerialProxy.open_opts()
  def current_opts(server \\ __MODULE__) do
    GenServer.call(server, :current_opts, @call_timeout)
  catch
    :exit, _ -> to_open_opts(@default_line)
  end

  @doc """
  The tty this proxy is holding open, for `UART.History` restart
  recovery (same shape and semantics as `ZWaveProxy.claimed_port/1`).
  `subscribed` says whether an API client is attached. Exits (server
  down, or `:calling_self` from the owner's own resolver path) read as
  "no claim".
  """
  @spec claimed_port(GenServer.server()) ::
          %{tty_name: String.t(), display_name: String.t(), subscribed: boolean()} | nil
  def claimed_port(server \\ __MODULE__) do
    GenServer.call(server, :claimed_port, @call_timeout)
  catch
    :exit, _ -> nil
  end

  @doc """
  Whether the tty is open, whether the last attempt to hold it failed,
  and the `Hardware` row it belongs to (kept while `error?`, nil when no
  ZBT-2 is resolved). A wedged server reports `error?: true`, a missing
  one `error?: false`.
  """
  @spec status(GenServer.server()) :: status()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status, @call_timeout)
  catch
    :exit, {:timeout, {GenServer, :call, _}} -> %{attached?: false, error?: true, port: nil}
    :exit, _ -> %{attached?: false, error?: false, port: nil}
  end

  defp call(server, msg, default, timeout \\ @call_timeout) do
    GenServer.call(server, msg, timeout)
  catch
    :exit, {:timeout, {GenServer, :call, _}} -> {:error, :timeout}
    :exit, _ -> default
  end

  # -- Server Callbacks --

  @impl GenServer
  def init(opts) do
    # Trap exits so terminate/2 closes the tty and broadcasts
    # `uart:port_closed` on a supervisor shutdown; the linked UART's own
    # crash is still fatal (the `{:EXIT, ...}` clause below).
    Process.flag(:trap_exit, true)

    state = %__MODULE__{
      ash: Ash.new(),
      port_path: Keyword.get(opts, :port_path),
      resolver: Keyword.get(opts, :resolver),
      # Seam for tests: an opener returning a fake UART pid. Every UART
      # operation here is a `Circuits.UART` GenServer call on that pid.
      open_fun: Keyword.get(opts, :open_fun) || (&open_port/1)
    }

    if state.port_path || state.resolver do
      # `Circuits.UART.open` can block on a misbehaving tty; keep it out
      # of init so the ESPHome supervisor's boot never waits on it.
      {:ok, state, {:continue, :open_port}}
    else
      {:ok, state}
    end
  end

  @impl GenServer
  def handle_continue(:open_port, state) do
    {:noreply, attempt_open(state)}
  end

  @impl GenServer
  def handle_call({:attach, _opts, _pid}, _from, %{uart_pid: nil} = state) do
    {:reply, {:error, :not_attached}, state}
  end

  def handle_call({:attach, opts, pid}, _from, state) do
    case apply_opts(state, opts) do
      {:ok, state} ->
        ref = make_ref()
        session = %{pid: pid, monitor: Process.monitor(pid)}
        Logger.debug("Zigbee proxy session #{inspect(ref)} attached for #{inspect(pid)}")
        {:reply, {:ok, ref}, put_in(state.sessions[ref], session)}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:detach, ref}, _from, state) do
    {:reply, :ok, drop_session(state, ref)}
  end

  def handle_call({:subscribe, ref}, _from, state) do
    cond do
      not Map.has_key?(state.sessions, ref) ->
        {:reply, {:error, :unknown_session}, state}

      state.subscribed == ref ->
        {:reply, :ok, state}

      state.subscribed != nil and Process.alive?(state.sessions[state.subscribed].pid) ->
        {:reply, {:error, :port_in_use}, state}

      true ->
        # A dead subscriber whose `:DOWN` is still queued: take over.
        state = if state.subscribed, do: drop_session(state, state.subscribed), else: state
        {:reply, :ok, flush_rx_buffer(%{state | subscribed: ref, mode: :raw})}
    end
  end

  def handle_call({:unsubscribe, ref}, _from, %{subscribed: ref} = state) do
    {:reply, :ok, release_subscription(state)}
  end

  def handle_call({:unsubscribe, _ref}, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call({:set_mode, _ref, mode}, _from, state) when mode not in [:raw, :protocol] do
    {:reply, {:error, :invalid_argument}, state}
  end

  def handle_call({:set_mode, ref, mode}, _from, %{subscribed: ref} = state) do
    state =
      case {state.mode, mode} do
        {:raw, :protocol} -> %{state | mode: :protocol, ash: Ash.reset(state.ash)}
        _ -> %{state | mode: mode}
      end

    {:reply, :ok, state}
  end

  def handle_call({:set_mode, _ref, _mode}, _from, state) do
    {:reply, {:error, :port_in_use}, state}
  end

  def handle_call({:write, _ref, _data}, _from, %{uart_pid: nil} = state) do
    {:reply, {:error, :not_attached}, state}
  end

  def handle_call({:write, ref, data}, _from, %{subscribed: ref} = state) do
    {:reply, uart_write(state, data), state}
  end

  def handle_call({:write, _ref, _data}, _from, state) do
    {:reply, {:error, :port_in_use}, state}
  end

  def handle_call({:configure, ref, opts}, _from, state) do
    with_attached_session(state, ref, fn ->
      case apply_opts(state, opts) do
        {:ok, state} -> {:ok, state}
        {:error, _} = error -> {error, state}
      end
    end)
  end

  def handle_call({:set_modem_pins, ref, rts, dtr}, _from, state) do
    with_attached_session(state, ref, fn ->
      {result, modem} = write_modem_lines(state.uart_pid, state.modem, %{rts: rts, dtr: dtr})
      {result, %{state | modem: modem}}
    end)
  end

  def handle_call({:get_modem_pins, ref}, _from, state) do
    with_attached_session(state, ref, fn -> {{:ok, state.modem}, state} end)
  end

  def handle_call(:current_opts, _from, state) do
    {:reply, to_open_opts(state.line), state}
  end

  def handle_call(:claimed_port, _from, state) do
    reply =
      if state.uart_pid && state.port_path do
        %{
          tty_name: Path.basename(state.port_path),
          display_name: state.display_name || Path.basename(state.port_path),
          subscribed: state.subscribed != nil
        }
      end

    {:reply, reply, state}
  end

  def handle_call(:status, _from, state) do
    {:reply, %{attached?: state.uart_pid != nil, error?: state.error?, port: state.port}, state}
  end

  @impl GenServer
  def handle_info({:circuits_uart, port, {:error, reason}}, %{uart_pid: pid} = state)
      when pid != nil do
    if current_tty?(state, port),
      do: handle_uart_error(state, pid, reason),
      else: {:noreply, state}
  end

  def handle_info({:circuits_uart, port, data}, %{uart_pid: pid} = state)
      when is_binary(data) and pid != nil do
    if current_tty?(state, port) do
      {state, acks} = deliver_rx(state, data)
      broadcast_data(state, data, :rx)
      if acks, do: broadcast_data(state, acks, :tx, origin: :ash_ack)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(:zigbee_reopen, state) do
    state = %{state | reopen_timer: nil}

    if state.uart_pid do
      {:noreply, state}
    else
      {:noreply, attempt_open(state)}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Enum.find(state.sessions, fn {_ref, session} -> session.monitor == monitor end) do
      {ref, _session} -> {:noreply, drop_session(state, ref)}
      nil -> {:noreply, state}
    end
  end

  # The linked UART process died abnormally: stop with it. Exits of a
  # UART already released by cleanup_uart/1 fall to the catch-all.
  def handle_info({:EXIT, pid, reason}, %{uart_pid: pid} = state) when reason != :normal do
    {:stop, reason, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp handle_uart_error(state, pid, reason) do
    Logger.warning("Zigbee proxy UART error: #{inspect(reason)}")
    cleanup_uart(pid)
    broadcast_lifecycle(state, "uart:port_closed", :uart_port_closed)

    state =
      %{
        state
        | uart_pid: nil,
          ash: Ash.reset(state.ash),
          rx_buffer: <<>>,
          line: @default_line,
          error?: true
      }
      |> schedule_reopen()

    {:noreply, state}
  end

  # Circuits.UART active messages carry the tty name ("ttyACM0"); a late
  # message from a previous UART must not reach the current session.
  defp current_tty?(%{port_path: path}, port) when is_binary(path) and is_binary(port),
    do: Path.basename(path) == Path.basename(port)

  defp current_tty?(_state, _port), do: false

  @impl GenServer
  def terminate(_reason, state) do
    if state.uart_pid do
      broadcast_lifecycle(state, "uart:port_closed", :uart_port_closed)
    end

    cleanup_uart(state.uart_pid)
    :ok
  end

  # -- Sessions --

  # `fun` returns `{reply, state}`; it runs only for a known session
  # while the tty is open.
  defp with_attached_session(state, ref, fun) do
    cond do
      not Map.has_key?(state.sessions, ref) ->
        {:reply, {:error, :unknown_session}, state}

      state.uart_pid == nil ->
        {:reply, {:error, :not_attached}, state}

      true ->
        {reply, state} = fun.()
        {:reply, reply, state}
    end
  end

  defp drop_session(state, ref) do
    case Map.pop(state.sessions, ref) do
      {nil, _sessions} ->
        state

      {session, sessions} ->
        Process.demonitor(session.monitor, [:flush])
        Logger.debug("Zigbee proxy session #{inspect(ref)} detached")
        state = %{state | sessions: sessions}
        if state.subscribed == ref, do: release_subscription(state), else: state
    end
  end

  # No `Ash` callback here: leaving PROTOCOL by losing the subscriber is
  # silent upstream, and the next RAW → PROTOCOL edge resets anyway.
  defp release_subscription(state), do: %{state | subscribed: nil, mode: :raw}

  defp flush_rx_buffer(%{rx_buffer: <<>>} = state), do: state

  defp flush_rx_buffer(state) do
    forward(state, state.rx_buffer)
    %{state | rx_buffer: <<>>}
  end

  # -- RX --

  # Returns the state and the ACK bytes written for this chunk (or nil).
  defp deliver_rx(%{subscribed: nil} = state, data) do
    {%{state | rx_buffer: append_bounded(state.rx_buffer, data)}, nil}
  end

  defp deliver_rx(%{mode: :protocol} = state, data) do
    {ash, acks} = Ash.feed(state.ash, data)
    state = %{state | ash: ash}

    # ACKs go to the NCP before the bytes go to the network.
    acks =
      case acks do
        [] -> nil
        acks -> write_acks(state, IO.iodata_to_binary(acks))
      end

    forward(state, data)
    {state, acks}
  end

  defp deliver_rx(state, data) do
    forward(state, data)
    {state, nil}
  end

  defp write_acks(state, acks) do
    case Circuits.UART.write(state.uart_pid, acks, @ack_write_timeout) do
      :ok ->
        acks

      {:error, reason} ->
        Logger.debug("Zigbee proxy ASH ACK write failed: #{inspect(reason)}")
        nil
    end
  end

  defp forward(state, data) do
    send(
      state.sessions[state.subscribed].pid,
      {:espex_serial_data, {:zigbee, state.subscribed}, data}
    )
  end

  defp append_bounded(buffer, data) do
    combined = buffer <> data
    excess = byte_size(combined) - @rx_buffer_size

    if excess > 0,
      do: binary_part(combined, excess, @rx_buffer_size),
      else: combined
  end

  # -- Line settings --

  defp apply_opts(state, opts) do
    with {:ok, line} <- normalise_opts(opts, state.line) do
      if line == state.line do
        {:ok, state}
      else
        case Circuits.UART.configure(state.uart_pid, Map.to_list(line)) do
          :ok -> {:ok, %{state | line: line}}
          {:error, _} = error -> error
        end
      end
    end
  end

  # Keys absent from `opts` keep their live value.
  defp normalise_opts(opts, current) do
    line = Map.merge(current, Map.new(Keyword.take(opts, @line_keys)))

    cond do
      not (is_integer(line.speed) and line.speed > 0) -> {:error, :invalid_speed}
      line.data_bits not in 5..8 -> {:error, :invalid_argument}
      line.stop_bits not in 1..2 -> {:error, :invalid_argument}
      line.parity not in [:none, :even, :odd] -> {:error, :invalid_argument}
      line.flow_control not in [:none, :hardware] -> {:error, :invalid_argument}
      true -> {:ok, line}
    end
  end

  defp to_open_opts(line), do: Enum.map(@line_keys, &{&1, Map.fetch!(line, &1)})

  # -- Modem lines --

  # Circuits.UART sets one line per ioctl, so DTR then RTS. Returns the
  # result and the cache updated for the calls that succeeded.
  defp write_modem_lines(uart_pid, current, wanted) do
    [dtr: &Circuits.UART.set_dtr/2, rts: &Circuits.UART.set_rts/2]
    |> Enum.reduce_while({:ok, current}, fn {line, setter}, {:ok, modem} ->
      value = Map.fetch!(wanted, line)

      if modem[line] == value do
        {:cont, {:ok, modem}}
      else
        case setter.(uart_pid, value) do
          :ok -> {:cont, {:ok, %{modem | line => value}}}
          {:error, _} = error -> {:halt, {error, modem}}
        end
      end
    end)
  end

  # -- Open / rescan --

  defp attempt_open(state) do
    case resolve_port(state) do
      nil ->
        schedule_reopen(%{state | port: nil, display_name: nil, error?: false})

      {port_path, display_name, port} ->
        case state.open_fun.(port_path) do
          {:ok, uart_pid} ->
            Logger.info("Zigbee proxy holding #{port_path}")

            state = %{
              state
              | uart_pid: uart_pid,
                port_path: port_path,
                display_name: display_name,
                port: port,
                line: @default_line,
                modem: @default_modem,
                ash: Ash.reset(state.ash),
                rx_buffer: <<>>,
                error?: false,
                last_open_error: nil
            }

            broadcast_lifecycle(state, "uart:port_opened", :uart_port_opened)
            state

          {:error, reason} ->
            level = if reason == state.last_open_error, do: :debug, else: :warning
            Logger.log(level, "Zigbee proxy failed to open #{port_path}: #{inspect(reason)}")
            schedule_reopen(%{state | port: port, error?: true, last_open_error: reason})
        end
    end
  end

  # `{tty, display_name, hardware_row | nil}` or nil. The resolver hands
  # back `%{path:, display_name:, port:}` (`port` optional); a bare
  # `:port_path` (tests, manual wiring) uses its basename as the name.
  defp resolve_port(state) do
    case state.resolver && state.resolver.() do
      %{path: path, display_name: display} = resolved ->
        {path, display, Map.get(resolved, :port)}

      nil ->
        # With a resolver, never fall back to a remembered path: after an
        # unplug that tty may be reassigned to a different device.
        if is_nil(state.resolver) and state.port_path do
          {state.port_path, state.display_name || Path.basename(state.port_path), state.port}
        end
    end
  end

  defp schedule_reopen(%{port_path: nil, resolver: nil} = state), do: state

  defp schedule_reopen(%{reopen_timer: nil} = state) do
    %{state | reopen_timer: Process.send_after(self(), :zigbee_reopen, @reopen_interval)}
  end

  defp schedule_reopen(state), do: state

  defp open_port(port_path) do
    with {:ok, pid} <- Circuits.UART.start_link() do
      case Circuits.UART.open(pid, port_path, Map.to_list(@default_line) ++ [active: true]) do
        :ok ->
          {:ok, pid}

        {:error, reason} ->
          cleanup_uart(pid)
          {:error, reason}
      end
    end
  end

  defp cleanup_uart(nil), do: :ok

  defp cleanup_uart(pid) when is_pid(pid) do
    # Separate guards: a failed close must not leave the linked UART
    # process alive (it would keep delivering data).
    guarded(fn -> Circuits.UART.close(pid) end)
    guarded(fn -> Circuits.UART.stop(pid) end)
    :ok
  end

  defp guarded(fun) do
    fun.()
  catch
    kind, reason ->
      Logger.debug("Zigbee proxy UART cleanup failed: #{inspect({kind, reason})}")
  end

  # -- TX / PubSub --

  defp uart_write(state, data) do
    result = Circuits.UART.write(state.uart_pid, data, @uart_write_timeout)
    if result == :ok, do: broadcast_data(state, IO.iodata_to_binary(data), :tx)
    result
  end

  # Mirrors UART.Server's `:uart_data` shape; extra keys (`origin:`) are
  # safe, every consumer matches on a subset.
  defp broadcast_data(state, data, dir, extra \\ [])

  defp broadcast_data(%{display_name: nil}, _data, _dir, _extra), do: :ok

  defp broadcast_data(%{display_name: name}, data, dir, extra) do
    payload =
      Map.merge(
        %{name: name, data: data, timestamp: DateTime.utc_now(), dir: dir},
        Map.new(extra)
      )

    Phoenix.PubSub.broadcast(@pubsub, "uart:#{name}", {:uart_data, payload})
  end

  defp broadcast_lifecycle(%{display_name: nil}, _topic, _event), do: :ok

  # `owner:` tells `UART.History` the port is held outside `UART.Server`.
  defp broadcast_lifecycle(state, topic, event) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      topic,
      {event, %{path: state.port_path, friendly_name: state.display_name, owner: :zigbee_proxy}}
    )
  end
end
