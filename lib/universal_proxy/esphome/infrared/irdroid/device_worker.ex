defmodule UniversalProxy.ESPHome.Infrared.Irdroid.DeviceWorker do
  @moduledoc """
  GenServer managing a single IRDroid / IR Toy v2.5+ USB infrared device.

  One process per connected+configured device, started under the
  `Infrared.WorkerSupervisor` DynamicSupervisor. Sole owner of the
  device's UART session.

  ## Lifecycle

  - On init, opens `Circuits.UART`, sends reset + version query. If the
    entity supports receive, enters dedicated receive mode (`'m'`).
  - Incoming UART bytes are fed through the pure `Irdroid.Protocol` state
    machine. Received IR timings are forwarded to the `Infrared.Server`.
  - Transmit requests switch to TX mode (`'n'`), write the full payload
    synchronously, then switch back to RX mode.

  ## Concurrency

  `handle_call` blocks synchronously during transmit -- the GenServer
  mailbox naturally serializes concurrent callers. No deferred-reply or
  busy-rejection needed.
  """

  use GenServer

  require Logger

  alias UniversalProxy.ESPHome.Infrared.Entity
  alias UniversalProxy.ESPHome.Infrared.Irdroid.Protocol

  @tx_completion_timeout 5_000
  @mode_ack_timeout 2_000

  defstruct [
    :uart_pid,
    :port_path,
    :entity,
    :server_pid,
    protocol: Protocol.new(),
    current_mode: :idle
  ]

  # -- Client API --

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Transmit raw IR timings through this device."
  @spec transmit(pid(), [integer()], keyword()) :: :ok | {:error, term()}
  def transmit(pid, timings, opts \\ []) do
    GenServer.call(pid, {:transmit, timings, opts}, @tx_completion_timeout + 5_000)
  end

  # -- Server Callbacks --

  @impl true
  def init(opts) do
    entity = Keyword.fetch!(opts, :entity)
    server_pid = Keyword.fetch!(opts, :server_pid)

    state = %__MODULE__{
      port_path: entity.port_path,
      entity: entity,
      server_pid: server_pid
    }

    case open_uart(entity.port_path) do
      {:ok, uart_pid} ->
        state = %{state | uart_pid: uart_pid}
        state = initialize_device(state)
        {:ok, state}

      {:error, reason} ->
        Logger.error("IRDroid worker failed to open #{entity.port_path}: #{inspect(reason)}")
        {:stop, {:uart_open_failed, reason}}
    end
  end

  @impl true
  def handle_call({:transmit, timings, opts}, _from, state) do
    case do_transmit(state, timings, opts) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:circuits_uart, _port, data}, state) when is_binary(data) do
    {protocol, actions} = Protocol.feed(state.protocol, data)
    state = %{state | protocol: protocol}
    state = execute_actions(state, actions)
    {:noreply, state}
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

  # -- Private: initialization --

  defp open_uart(port_path) do
    with {:ok, pid} <- Circuits.UART.start_link(),
         :ok <-
           Circuits.UART.open(pid, port_path,
             speed: 115_200,
             data_bits: 8,
             stop_bits: 1,
             parity: :none,
             flow_control: :none,
             active: true
           ) do
      {:ok, pid}
    end
  end

  defp initialize_device(state) do
    uart_write(state, Protocol.reset())
    Process.sleep(50)
    uart_write(state, Protocol.get_version())
    Process.sleep(50)

    if Entity.can_receive?(state.entity) do
      enter_receive_mode(state)
    else
      state
    end
  end

  # -- Private: transmit sequence --

  defp do_transmit(state, timings, opts) do
    carrier = Keyword.get(opts, :carrier_frequency, 38_000)
    repeat = Keyword.get(opts, :repeat_count, 1)

    with {:ok, state} <- switch_to_transmit_mode(state),
         :ok <- uart_write(state, Protocol.encode_carrier(carrier)),
         payload = Protocol.encode_transmit(timings, repeat_count: repeat),
         :ok <- uart_write(state, payload),
         {:ok, state} <- await_tx_completion(state) do
      state = restore_receive_mode(state)
      {:ok, state}
    else
      {:error, reason} ->
        state = restore_receive_mode(state)
        {:error, reason, state}

      {:error, reason, state} ->
        state = restore_receive_mode(state)
        {:error, reason, state}
    end
  end

  defp switch_to_transmit_mode(state) do
    uart_write(state, Protocol.reset())
    Process.sleep(10)

    protocol = Protocol.set_idle(state.protocol)
    state = %{state | protocol: protocol, current_mode: :idle}

    uart_write(state, Protocol.enter_transmit_mode())

    case await_mode_ack(state) do
      {:ok, state} ->
        protocol = Protocol.set_transmit_mode(state.protocol)
        {:ok, %{state | protocol: protocol, current_mode: :transmit}}

      error ->
        error
    end
  end

  defp await_mode_ack(state) do
    receive do
      {:circuits_uart, _port, data} when is_binary(data) ->
        {protocol, actions} = Protocol.feed(state.protocol, data)
        state = %{state | protocol: protocol}

        if Enum.any?(actions, fn
             {:mode_entered, _} -> true
             _ -> false
           end) do
          {:ok, state}
        else
          state = execute_actions(state, actions)
          await_mode_ack(state)
        end

      {:circuits_uart, _port, {:error, reason}} ->
        Logger.warning("IRDroid UART error during mode ack on #{state.port_path}: #{inspect(reason)}")
        {:error, {:uart_error, reason}}
    after
      @mode_ack_timeout ->
        Logger.warning("IRDroid mode ack timeout on #{state.port_path}")
        {:error, :mode_ack_timeout}
    end
  end

  defp await_tx_completion(state) do
    receive do
      {:circuits_uart, _port, data} when is_binary(data) ->
        {protocol, actions} = Protocol.feed(state.protocol, data)
        state = %{state | protocol: protocol}

        cond do
          :tx_complete in actions ->
            {:ok, state}

          Enum.any?(actions, &match?({:tx_error, _}, &1)) ->
            {_, reason} = Enum.find(actions, &match?({:tx_error, _}, &1))
            {:error, reason, state}

          true ->
            await_tx_completion(state)
        end

      {:circuits_uart, _port, {:error, reason}} ->
        Logger.warning("IRDroid UART error during TX on #{state.port_path}: #{inspect(reason)}")
        {:error, {:uart_error, reason}, state}
    after
      @tx_completion_timeout ->
        Logger.warning("IRDroid TX completion timeout on #{state.port_path}")
        {:error, :tx_timeout, state}
    end
  end

  defp restore_receive_mode(state) do
    uart_write(state, Protocol.reset())
    Process.sleep(10)

    if Entity.can_receive?(state.entity) do
      enter_receive_mode(state)
    else
      protocol = Protocol.set_idle(state.protocol)
      %{state | protocol: protocol, current_mode: :idle}
    end
  end

  defp enter_receive_mode(state) do
    uart_write(state, Protocol.enter_receive_mode())
    protocol = state.protocol |> Protocol.set_idle()
    state = %{state | protocol: protocol, current_mode: :receive}

    receive do
      {:circuits_uart, _port, data} when is_binary(data) ->
        {protocol, actions} = Protocol.feed(state.protocol, data)
        state = %{state | protocol: protocol}

        if Enum.any?(actions, &match?({:mode_entered, _}, &1)) do
          protocol = Protocol.set_receive_mode(state.protocol)
          %{state | protocol: protocol}
        else
          state = execute_actions(state, actions)
          protocol = Protocol.set_receive_mode(state.protocol)
          %{state | protocol: protocol}
        end

      {:circuits_uart, _port, {:error, reason}} ->
        Logger.warning("IRDroid UART error entering RX mode on #{state.port_path}: #{inspect(reason)}")
        state
    after
      @mode_ack_timeout ->
        Logger.warning("IRDroid RX mode ack timeout on #{state.port_path}")
        state
    end
  end

  # -- Private: action execution --

  defp execute_actions(state, actions) do
    Enum.reduce(actions, state, &execute_action/2)
  end

  defp execute_action({:rx_timings, timings}, state) do
    send(state.server_pid, {:infrared_receive, state.entity.key, timings})
    state
  end

  defp execute_action({:version, hw, fw}, state) do
    Logger.info("IRDroid #{state.port_path} firmware: hw=#{hw} fw=#{fw}")
    state
  end

  defp execute_action({:mode_entered, version}, state) do
    Logger.debug("IRDroid #{state.port_path} mode entered: #{version}")

    if receive_pending?(state) do
      %{state | protocol: Protocol.set_receive_mode(state.protocol)}
    else
      state
    end
  end

  defp execute_action(:tx_complete, state) do
    Logger.debug("IRDroid #{state.port_path} transmit complete")
    state
  end

  defp execute_action({:tx_error, reason}, state) do
    Logger.warning("IRDroid #{state.port_path} transmit error: #{inspect(reason)}")
    state
  end

  defp execute_action(:rx_overflow, state) do
    Logger.warning("IRDroid #{state.port_path} RX overflow, re-entering receive mode")

    if Entity.can_receive?(state.entity) do
      enter_receive_mode(state)
    else
      state
    end
  end

  defp receive_pending?(state) do
    state.current_mode == :receive and state.protocol.mode == :idle
  end

  defp uart_write(%{uart_pid: pid}, data) when pid != nil do
    Circuits.UART.write(pid, data)
  end

  defp uart_write(_, _data), do: {:error, :no_uart}
end
