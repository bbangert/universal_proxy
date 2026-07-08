defmodule UniversalProxy.ESPHome.ZWaveProxy do
  @moduledoc """
  `Espex.ZWaveProxy` adapter and the GenServer that owns the Z-Wave UART
  port for the duration of the application's lifetime.

  This is the single owner of the Z-Wave serial port. It is NOT managed
  through the shared `UART.Server` because Z-Wave requires protocol-level
  handling (local ACK/NAK/CAN) rather than raw byte forwarding.

  ## Lifecycle

  - On init, if a Z-Wave port path (or a `:resolver`) is provided, opens
    `Circuits.UART` at 115200/8N1 and sends GET_NETWORK_IDS to discover
    the home ID, retrying up to 5 times at 500 ms intervals (mirrors
    the ESPHome component's reconnect retry).
  - Incoming UART bytes are fed through the `Parser`, which returns local
    ACK/NAK/CAN responses to write back to the UART, and complete frames
    to forward to the subscribed espex connection.
  - Client frames that duplicate the response the proxy already sent
    locally (single-byte ACK/NAK/CAN) are suppressed, matching the
    ESPHome `last_response_` guard.
  - On UART error the port is closed, the home ID is cleared (and the
    subscriber notified with a zeroed ID, mirroring ESPHome's
    `clear_home_id_`), and a reopen loop re-resolves the port every 5 s
    via the `:resolver` — so a stick replugged (or first plugged after
    boot) attaches without restarting the supervision tree.
  - Only one connection may subscribe at a time (Z-Wave Serial API is
    single-master). The subscriber is monitored and auto-unsubscribed
    on crash.
  - All UART traffic is re-broadcast on the same PubSub topics
    `UART.Server` uses (`uart:port_opened`/`uart:port_closed` and
    `uart:<display_name>` `:uart_data` messages), so `UART.History`
    feeds the Overview throughput sparkline, the packets/min pill, and
    the Traffic tab for this port exactly like any proxied serial port.
    The display name comes from the resolver (the port's `ha_name`) so
    it matches the key the Overview subscribes with.
  """

  use GenServer

  @behaviour Espex.ZWaveProxy

  require Logger

  alias UniversalProxy.ESPHome.ZWaveProxy.{Frame, Parser}

  @uart_speed 115_200

  # GenServer call timeouts. Espex calls these from the connection
  # handler; a hung adapter must not stall connection setup, so we set
  # tight, per-call ceilings instead of the 5 s default. `:exit` from a
  # timeout or terminated server is caught and mapped to a sane default.
  @short_call_timeout 1_000
  @send_frame_timeout 3_000

  # Home-ID query retry cadence — mirrors the ESPHome component's
  # RECONNECT_DELAY_MS / MAX_QUERY_RETRIES.
  @home_id_retry_interval 500
  @max_home_id_retries 5

  # Port (re)open / hotplug rescan cadence.
  @reopen_interval 5_000

  @zero_home_id <<0, 0, 0, 0>>

  @pubsub UniversalProxy.PubSub

  defstruct [
    :uart_pid,
    :port_path,
    :display_name,
    :resolver,
    :subscriber,
    :monitor_ref,
    :reopen_timer,
    :home_id_timer,
    :last_open_error,
    parser: nil,
    home_id: @zero_home_id,
    home_id_ready: false,
    query_retries: 0,
    espex_server: Espex.Server
  ]

  # -- Adapter wiring --

  def start_link(opts \\ []) do
    gen_opts =
      case Keyword.get(opts, :name, __MODULE__) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @impl Espex.ZWaveProxy
  @spec available?(GenServer.server()) :: boolean()
  def available?(server \\ __MODULE__) do
    GenServer.call(server, :available?, @short_call_timeout)
  catch
    :exit, _ -> false
  end

  @impl Espex.ZWaveProxy
  @spec home_id(GenServer.server()) :: non_neg_integer()
  def home_id(server \\ __MODULE__) do
    GenServer.call(server, :home_id_int, @short_call_timeout)
  catch
    :exit, _ -> 0
  end

  @impl Espex.ZWaveProxy
  def feature_flags do
    if available?(), do: 0x01, else: 0
  end

  @impl Espex.ZWaveProxy
  @spec subscribe(GenServer.server(), pid()) ::
          {:ok, <<_::32>>} | {:error, :already_subscribed | :unavailable}
  def subscribe(server \\ __MODULE__, pid) when is_pid(pid) do
    GenServer.call(server, {:subscribe, pid}, @short_call_timeout)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @impl Espex.ZWaveProxy
  @spec unsubscribe(GenServer.server(), pid()) :: :ok
  def unsubscribe(server \\ __MODULE__, pid) when is_pid(pid) do
    GenServer.call(server, {:unsubscribe, pid}, @short_call_timeout)
  catch
    # Idempotent contract — a missing server is "already unsubscribed".
    :exit, _ -> :ok
  end

  @impl Espex.ZWaveProxy
  @spec send_frame(GenServer.server(), binary()) :: :ok | {:error, term()}
  def send_frame(server \\ __MODULE__, data) when is_binary(data) do
    GenServer.call(server, {:send_frame, data}, @send_frame_timeout)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc """
  The tty this proxy currently holds open, or `nil`.

  `UniversalProxy.Hardware` uses this to mark the port as in-use on the
  Overview (the Z-Wave port is opened directly, not through the shared
  `UART.Server`, so it is invisible to `UART.ports/0`). `subscribed`
  says whether an API client (Z-Wave JS) is attached right now.

  Note: `Hardware.list_ports/0` calls this by default, and this server's
  own port resolver calls `Hardware.list_ports/0` — that self-call exits
  with `:calling_self` immediately and is caught here, so the resolver
  simply sees "no claim" for its own row.
  """
  @spec claimed_port(GenServer.server()) ::
          %{tty_name: String.t(), display_name: String.t(), subscribed: boolean()} | nil
  def claimed_port(server \\ __MODULE__) do
    GenServer.call(server, :claimed_port, @short_call_timeout)
  catch
    :exit, _ -> nil
  end

  # -- Server Callbacks --

  @impl GenServer
  def init(opts) do
    state = %__MODULE__{
      parser: Parser.new(),
      port_path: Keyword.get(opts, :port_path),
      display_name: Keyword.get(opts, :display_name),
      resolver: Keyword.get(opts, :resolver),
      espex_server: Keyword.get(opts, :espex_server, Espex.Server)
    }

    if state.port_path || state.resolver do
      # Port open is deferred out of init: `Circuits.UART.open` can block
      # on a slow/misbehaving tty, and nothing here may hold up the
      # ESPHome supervisor's boot. A failed open schedules a retry rather
      # than crashing; matches the FMA120/irdroid worker pattern.
      {:ok, state, {:continue, :open_port}}
    else
      Logger.info("Z-Wave proxy started (no device configured)")
      {:ok, state}
    end
  end

  @impl GenServer
  def handle_continue(:open_port, state) do
    {:noreply, attempt_open(state)}
  end

  @impl GenServer
  def handle_call(:available?, _from, state) do
    {:reply, state.uart_pid != nil, state}
  end

  def handle_call(:home_id_int, _from, state) do
    {:reply, Frame.encode_home_id(state.home_id), state}
  end

  def handle_call({:subscribe, _pid}, _from, %{uart_pid: nil} = state) do
    Logger.warning("Z-Wave subscribe rejected: no device available")
    {:reply, {:error, :unavailable}, state}
  end

  def handle_call({:subscribe, pid}, _from, %{subscriber: sub} = state)
      when sub != nil and sub != pid do
    Logger.warning("Z-Wave subscribe rejected: already subscribed by #{inspect(sub)}")
    {:reply, {:error, :already_subscribed}, state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    if state.monitor_ref, do: Process.demonitor(state.monitor_ref, [:flush])
    ref = Process.monitor(pid)
    state = %{state | subscriber: pid, monitor_ref: ref}
    Logger.info("Z-Wave subscriber registered: #{inspect(pid)}")
    {:reply, {:ok, state.home_id}, state}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    if state.subscriber == pid do
      if state.monitor_ref, do: Process.demonitor(state.monitor_ref, [:flush])
      Logger.info("Z-Wave subscriber unregistered: #{inspect(pid)}")
      {:reply, :ok, %{state | subscriber: nil, monitor_ref: nil}}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call(:claimed_port, _from, state) do
    reply =
      if state.uart_pid && state.port_path do
        %{
          tty_name: Path.basename(state.port_path),
          display_name: state.display_name || Path.basename(state.port_path),
          subscribed: state.subscriber != nil
        }
      end

    {:reply, reply, state}
  end

  def handle_call({:send_frame, _data}, _from, %{uart_pid: nil} = state) do
    {:reply, {:error, :unavailable}, state}
  end

  def handle_call({:send_frame, <<>>}, _from, state) do
    {:reply, {:error, :empty_frame}, state}
  end

  def handle_call({:send_frame, data}, _from, state) do
    if Parser.duplicate_response?(state.parser, data) do
      # The proxy already ACK/NAKed this frame locally; forwarding the
      # client's copy would hand the module a duplicate it may
      # misattribute to the next frame in flight (ESPHome parity).
      {:reply, :ok, state}
    else
      {:reply, uart_write(state, data), state}
    end
  end

  @impl GenServer
  def handle_info({:circuits_uart, _port, {:error, reason}}, state) do
    Logger.warning("Z-Wave UART error: #{inspect(reason)}")
    cleanup_uart(state.uart_pid)
    broadcast_lifecycle(state, "uart:port_closed", :uart_port_closed)

    state =
      %{state | uart_pid: nil, parser: Parser.new(), home_id_ready: false, query_retries: 0}
      |> clear_home_id()
      |> schedule_reopen()

    {:noreply, state}
  end

  def handle_info({:circuits_uart, _port, data}, state) when is_binary(data) do
    broadcast_data(state, data, :rx)
    {parser, actions} = Parser.feed(state.parser, data)
    state = %{state | parser: parser}
    state = execute_actions(state, actions)
    {:noreply, state}
  end

  def handle_info(:zwave_reopen, state) do
    state = %{state | reopen_timer: nil}

    if state.uart_pid do
      {:noreply, state}
    else
      {:noreply, attempt_open(state)}
    end
  end

  def handle_info(:zwave_home_id_retry, state) do
    state = %{state | home_id_timer: nil}

    cond do
      state.uart_pid == nil or state.home_id_ready ->
        {:noreply, state}

      state.query_retries < @max_home_id_retries ->
        Logger.debug("Z-Wave querying home ID (retry #{state.query_retries + 1})")
        request_home_id(state)

        {:noreply, schedule_home_id_retry(%{state | query_retries: state.query_retries + 1})}

      true ->
        Logger.warning("Z-Wave failed to read home ID after #{@max_home_id_retries} retries")
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, %{monitor_ref: ref} = state) do
    Logger.info("Z-Wave subscriber #{inspect(pid)} down, auto-unsubscribing")
    {:noreply, %{state | subscriber: nil, monitor_ref: nil}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    if state.uart_pid do
      broadcast_lifecycle(state, "uart:port_closed", :uart_port_closed)
    end

    cleanup_uart(state.uart_pid)
    :ok
  end

  # -- Private --

  defp cleanup_uart(nil), do: :ok

  defp cleanup_uart(pid) when is_pid(pid) do
    try do
      Circuits.UART.close(pid)
      Circuits.UART.stop(pid)
    catch
      _, _ -> :ok
    end

    :ok
  end

  # Resolve (preferring the dynamic resolver — a replugged stick can come
  # back on a different tty) and open the port. On any failure, arm the
  # reopen timer so the next attempt happens without external prodding.
  defp attempt_open(state) do
    case resolve_port(state) do
      nil ->
        schedule_reopen(state)

      {port_path, display_name} ->
        case open_port(port_path) do
          {:ok, uart_pid} ->
            Logger.info("Z-Wave proxy started on #{port_path}")

            # port_path/display_name update to what actually opened — a
            # resolver-discovered stick would otherwise leave them nil
            # (or stale after a replug onto a different tty), and
            # claimed_port/1 reports them to the Overview and History.
            state = %{
              state
              | uart_pid: uart_pid,
                port_path: port_path,
                display_name: display_name,
                parser: Parser.new(),
                home_id_ready: false,
                query_retries: 0,
                last_open_error: nil
            }

            broadcast_lifecycle(state, "uart:port_opened", :uart_port_opened)
            request_home_id(state)
            schedule_home_id_retry(state)

          {:error, reason} ->
            # First (or changed) failure logs at warning; identical
            # repeats every @reopen_interval drop to debug to avoid spam.
            level = if reason == state.last_open_error, do: :debug, else: :warning
            Logger.log(level, "Z-Wave proxy failed to open #{port_path}: #{inspect(reason)}")
            schedule_reopen(%{state | last_open_error: reason})
        end
    end
  end

  # Returns `{open_target, display_name}` or nil. The resolver hands back
  # `%{path: ..., display_name: ...}` (the port's Overview `ha_name`, so
  # History throughput lands under the key the UI subscribes with); a
  # bare-string `port_path` (tests, manual wiring) falls back to its
  # basename as the display name.
  defp resolve_port(state) do
    case state.resolver && state.resolver.() do
      %{path: path, display_name: display} ->
        {path, display}

      path when is_binary(path) ->
        {path, Path.basename(path)}

      nil ->
        if state.port_path do
          {state.port_path, state.display_name || Path.basename(state.port_path)}
        end
    end
  end

  # Nothing to reopen when no port was ever configured and there's no
  # resolver to discover one.
  defp schedule_reopen(%{port_path: nil, resolver: nil} = state), do: state

  defp schedule_reopen(%{reopen_timer: nil} = state) do
    %{state | reopen_timer: Process.send_after(self(), :zwave_reopen, @reopen_interval)}
  end

  defp schedule_reopen(state), do: state

  defp schedule_home_id_retry(%{home_id_timer: nil} = state) do
    %{
      state
      | home_id_timer: Process.send_after(self(), :zwave_home_id_retry, @home_id_retry_interval)
    }
  end

  defp schedule_home_id_retry(state), do: state

  defp open_port(port_path) do
    with {:ok, pid} <- Circuits.UART.start_link() do
      case Circuits.UART.open(pid, port_path,
             speed: @uart_speed,
             data_bits: 8,
             stop_bits: 1,
             parity: :none,
             flow_control: :none,
             active: true
           ) do
        :ok ->
          {:ok, pid}

        {:error, reason} ->
          # Don't leak the UART process — the reopen loop would stack one
          # per failed attempt otherwise.
          cleanup_uart(pid)
          {:error, reason}
      end
    end
  end

  defp request_home_id(%{uart_pid: pid} = state) when pid != nil do
    uart_write(state, Frame.get_network_ids_command())
  end

  defp request_home_id(_state), do: :ok

  # All outbound bytes flow through here so every write is mirrored as a
  # `:tx` broadcast for the History throughput/traffic pipeline.
  defp uart_write(state, data) do
    result = Circuits.UART.write(state.uart_pid, data)
    if result == :ok, do: broadcast_data(state, data, :tx)
    result
  end

  # Mirror UART.Server's PubSub message shapes exactly — History and the
  # LiveViews consume both sources through one code path.
  defp broadcast_data(%{display_name: nil}, _data, _dir), do: :ok

  defp broadcast_data(%{display_name: name}, data, dir) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      "uart:#{name}",
      {:uart_data, %{name: name, data: data, timestamp: DateTime.utc_now(), dir: dir}}
    )
  end

  defp broadcast_lifecycle(%{display_name: nil}, _topic, _event), do: :ok

  # `owner:` extends UART.Server's payload shape (safe — every consumer
  # pattern-matches on a subset of keys). It tells `UART.History` this
  # port is held open outside `UART.Server`, so its grace eviction won't
  # unsubscribe a live port that `UART.named_ports/0` can never list.
  defp broadcast_lifecycle(state, topic, event) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      topic,
      {event, %{path: state.port_path, friendly_name: state.display_name, owner: :zwave_proxy}}
    )
  end

  defp execute_actions(state, actions) do
    Enum.reduce(actions, state, &execute_action(&2, &1))
  end

  defp execute_action(state, {:send_response, byte}) do
    if state.uart_pid do
      uart_write(state, <<byte>>)
    end

    state
  end

  defp execute_action(state, {:frame_complete, frame_data}) do
    state = maybe_update_home_id(state, frame_data)

    if state.subscriber do
      send(state.subscriber, {:espex_zwave_frame, frame_data})
    end

    state
  end

  defp maybe_update_home_id(state, frame_data) do
    case Frame.extract_home_id(frame_data) do
      {:ok, new_home_id} ->
        # Any valid GET_NETWORK_IDS response settles the retry loop, even
        # when the ID is unchanged.
        state = %{state | home_id_ready: true}
        put_home_id(state, new_home_id)

      :error ->
        state
    end
  end

  # Mirrors ESPHome's clear_home_id_: on device loss, zero the ID and
  # broadcast so every client's stored network identity resets.
  defp clear_home_id(state), do: put_home_id(state, @zero_home_id)

  defp put_home_id(%{home_id: home_id} = state, home_id), do: state

  defp put_home_id(state, new_home_id) do
    Logger.info("Z-Wave home ID changed: #{inspect(new_home_id)}")

    # Broadcast to ALL espex connections, not just the frame subscriber.
    # HA's zwave_js discovery runs on a connection that never subscribes,
    # and a stick hot-plugged after HA connected must still be seen — the
    # subscriber-only send missed both (espex F4). Espex fans this out
    # via its connection registry.
    broadcast_home_id(state, new_home_id)

    %{state | home_id: new_home_id}
  end

  # `Registry.dispatch` raises ArgumentError when espex's registry isn't
  # started — which happens at boot: ZWaveProxy is the FIRST child of the
  # rest_for_one ESPHome tree, so the very first home-ID read can precede
  # Espex's registry. Rescue it (per the project's registry convention,
  # NOT catch :exit) and drop the broadcast: the auth-time push in espex
  # (`:client_connected`) re-delivers the current home ID to every client
  # once they connect, so nothing is permanently lost.
  defp broadcast_home_id(state, home_id) do
    Espex.push_zwave_home_id(state.espex_server, home_id)
  rescue
    ArgumentError -> :ok
  end
end
