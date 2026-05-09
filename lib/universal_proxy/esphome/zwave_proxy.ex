defmodule UniversalProxy.ESPHome.ZWaveProxy do
  @moduledoc """
  `Espex.ZWaveProxy` adapter and the GenServer that owns the Z-Wave UART
  port for the duration of the application's lifetime.

  This is the single owner of the Z-Wave serial port. It is NOT managed
  through the shared `UART.Server` because Z-Wave requires protocol-level
  handling (local ACK/NAK/CAN) rather than raw byte forwarding.

  ## Lifecycle

  - On init, if a Z-Wave port path is provided, opens `Circuits.UART`
    at 115200/8N1 and sends a GET_NETWORK_IDS command to discover the
    home ID.
  - Incoming UART bytes are fed through `Espex.ZWaveProxy.Parser`, which
    returns local ACK/NAK/CAN responses to write back to the UART, and
    complete frames to forward to the subscribed espex connection.
  - Only one connection may subscribe at a time (Z-Wave Serial API is
    single-master). The subscriber is monitored and auto-unsubscribed
    on crash.
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

  defstruct [
    :uart_pid,
    :port_path,
    :subscriber,
    :monitor_ref,
    parser: nil,
    home_id: <<0, 0, 0, 0>>
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

  # -- Server Callbacks --

  @impl GenServer
  def init(opts) do
    port_path = Keyword.get(opts, :port_path)

    state = %__MODULE__{
      parser: Parser.new(),
      port_path: port_path
    }

    if port_path do
      case open_port(port_path) do
        {:ok, uart_pid} ->
          state = %{state | uart_pid: uart_pid}
          request_home_id(state)
          Logger.info("Z-Wave proxy started on #{port_path}")
          {:ok, state}

        {:error, reason} ->
          Logger.warning("Z-Wave proxy failed to open #{port_path}: #{inspect(reason)}")
          {:ok, state}
      end
    else
      Logger.info("Z-Wave proxy started (no device configured)")
      {:ok, state}
    end
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

  def handle_call({:send_frame, data}, _from, state) do
    {:reply, write_frame(state, data), state}
  end

  @impl GenServer
  def handle_info({:circuits_uart, _port, {:error, reason}}, state) do
    Logger.warning("Z-Wave UART error: #{inspect(reason)}")
    cleanup_uart(state.uart_pid)
    {:noreply, %{state | uart_pid: nil, parser: Parser.new()}}
  end

  def handle_info({:circuits_uart, _port, data}, state) when is_binary(data) do
    {parser, actions} = Parser.feed(state.parser, data)
    state = %{state | parser: parser}
    state = execute_actions(state, actions)
    {:noreply, state}
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

  defp open_port(port_path) do
    with {:ok, pid} <- Circuits.UART.start_link(),
         :ok <-
           Circuits.UART.open(pid, port_path,
             speed: @uart_speed,
             data_bits: 8,
             stop_bits: 1,
             parity: :none,
             flow_control: :none,
             active: true
           ) do
      {:ok, pid}
    end
  end

  defp request_home_id(%{uart_pid: pid}) when pid != nil do
    Circuits.UART.write(pid, Frame.get_network_ids_command())
  end

  defp request_home_id(_state), do: :ok

  defp execute_actions(state, actions) do
    Enum.reduce(actions, state, &execute_action(&2, &1))
  end

  defp execute_action(state, {:send_response, byte}) do
    if state.uart_pid do
      Circuits.UART.write(state.uart_pid, <<byte>>)
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
      {:ok, new_home_id} when new_home_id != state.home_id ->
        Logger.info("Z-Wave home ID changed: #{inspect(new_home_id)}")

        if state.subscriber do
          send(state.subscriber, {:espex_zwave_home_id_changed, new_home_id})
        end

        %{state | home_id: new_home_id}

      _ ->
        state
    end
  end

  defp write_frame(%{uart_pid: nil}, _data), do: {:error, :unavailable}
  defp write_frame(_state, <<>>), do: {:error, :empty_frame}

  defp write_frame(%{uart_pid: pid}, data) when is_binary(data) do
    Circuits.UART.write(pid, data)
  end
end
