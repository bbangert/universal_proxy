defmodule UniversalProxy.ESPHome.ZWave.Server do
  @moduledoc """
  GenServer that manages the Z-Wave UART port and bridges between the
  frame parser and ESPHome client connections.

  This is the single owner of the Z-Wave serial port. It is NOT managed
  through the shared `UART.Server` because Z-Wave requires protocol-level
  handling (local ACK/NAK/CAN) rather than raw byte forwarding.

  ## Lifecycle

  - On init, if a Z-Wave port path is provided, opens `Circuits.UART`
    at 115200/8N1 and sends a GET_NETWORK_IDS command to discover the
    home ID.
  - Incoming UART bytes are fed through the pure `Parser`, which produces
    actions: local ACK/NAK/CAN responses are written back to the UART
    immediately, and complete frames are forwarded to the subscribed
    API connection.
  - Only one API connection may subscribe at a time (Z-Wave Serial API
    is single-master). The subscriber is monitored and auto-unsubscribed
    on crash.

  ## Client API

  All public functions are called by `ESPHome.Connection` dispatch clauses
  through the `ESPHome.ZWave` facade module.
  """

  use GenServer

  require Logger

  alias UniversalProxy.ESPHome.ZWave.{Frame, Parser}

  @pubsub UniversalProxy.PubSub
  @home_id_changed_topic "zwave:home_id_changed"
  @uart_speed 115_200

  defstruct [
    :uart_pid,
    :port_path,
    :subscriber,
    :monitor_ref,
    parser: nil,
    home_id: <<0, 0, 0, 0>>,
    home_id_ready: false
  ]

  # -- Client API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Subscribe the calling connection as the Z-Wave frame receiver.

  Only one subscriber is allowed at a time. Returns `{:ok, home_id_bytes}`
  on success, or `{:error, reason}` if already subscribed or unavailable.
  """
  @spec subscribe(pid()) :: {:ok, binary()} | {:error, :already_subscribed | :unavailable}
  def subscribe(pid) when is_pid(pid) do
    GenServer.call(__MODULE__, {:subscribe, pid})
  end

  @doc """
  Unsubscribe the calling connection.

  Returns `:ok` regardless of whether the pid was actually subscribed.
  """
  @spec unsubscribe(pid()) :: :ok
  def unsubscribe(pid) when is_pid(pid) do
    GenServer.call(__MODULE__, {:unsubscribe, pid})
  end

  @doc """
  Send a frame from the API client to the Z-Wave stick.

  Writes raw bytes to UART with duplicate single-byte response suppression.
  """
  @spec send_frame(binary()) :: :ok | {:error, term()}
  def send_frame(data) when is_binary(data) do
    GenServer.call(__MODULE__, {:send_frame, data})
  end

  @doc """
  Returns the current home ID as a uint32.
  """
  @spec home_id() :: non_neg_integer()
  def home_id do
    GenServer.call(__MODULE__, :home_id)
  end

  @doc """
  Returns whether a Z-Wave device is connected and the port is open.
  """
  @spec available?() :: boolean()
  def available? do
    GenServer.call(__MODULE__, :available?)
  end

  # -- Server Callbacks --

  @impl true
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

  @impl true
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
    result = write_frame(state, data)
    {:reply, result, state}
  end

  def handle_call(:home_id, _from, state) do
    {:reply, Frame.encode_home_id(state.home_id), state}
  end

  def handle_call(:available?, _from, state) do
    {:reply, state.uart_pid != nil, state}
  end

  @impl true
  def handle_info({:circuits_uart, _port, {:error, reason}}, state) do
    Logger.warning("Z-Wave UART error: #{inspect(reason)}")
    {:noreply, %{state | uart_pid: nil}}
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

  @impl true
  def terminate(_reason, state) do
    if state.uart_pid do
      try do
        Circuits.UART.close(state.uart_pid)
        Circuits.UART.stop(state.uart_pid)
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  # -- Private --

  defp open_port(port_path) do
    with {:ok, pid} <- Circuits.UART.start_link(),
         :ok <- Circuits.UART.open(pid, port_path,
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
    cmd = Frame.get_network_ids_command()
    Circuits.UART.write(pid, cmd)
  end

  defp request_home_id(_state), do: :ok

  defp execute_actions(state, actions) do
    Enum.reduce(actions, state, fn action, state ->
      execute_action(state, action)
    end)
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
      send(state.subscriber, {:zwave_frame, frame_data})
    end

    state
  end

  defp maybe_update_home_id(state, frame_data) do
    case Frame.extract_home_id(frame_data) do
      {:ok, new_home_id} ->
        if new_home_id != state.home_id do
          Logger.info("Z-Wave home ID changed: #{inspect(new_home_id)}")
          broadcast_home_id_changed(new_home_id)
          %{state | home_id: new_home_id, home_id_ready: true}
        else
          %{state | home_id_ready: true}
        end

      :error ->
        state
    end
  end

  defp broadcast_home_id_changed(home_id_bytes) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      @home_id_changed_topic,
      {:zwave_home_id_changed, home_id_bytes}
    )
  end

  defp write_frame(%{uart_pid: nil}, _data), do: {:error, :unavailable}

  defp write_frame(%{uart_pid: pid} = _state, data) when is_binary(data) do
    if byte_size(data) == 0 do
      {:error, :empty_frame}
    else
      Circuits.UART.write(pid, data)
    end
  end
end
