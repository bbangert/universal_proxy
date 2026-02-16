defmodule UniversalProxy.UART.Server do
  @moduledoc """
  GenServer that manages a registry of opened UART ports.

  Each opened port gets its own `Circuits.UART` GenServer started under
  the `UniversalProxy.UART.PortSupervisor` DynamicSupervisor. This server
  tracks the mapping of port names to their PIDs and configurations, and
  monitors each UART process to clean up on unexpected exits.
  """

  use GenServer

  alias UniversalProxy.UART.PortConfig

  # -- Client API (called by UniversalProxy.UART public module) --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Open a serial port with the given options.

  Starts a `Circuits.UART` GenServer under the DynamicSupervisor,
  opens the named port, and registers it in the server state.

  Returns `{:ok, pid}` on success or `{:error, reason}` on failure.
  """
  @spec open_port(binary(), keyword()) :: {:ok, pid()} | {:error, term()}
  def open_port(port_name, opts \\ []) do
    GenServer.call(__MODULE__, {:open_port, port_name, opts})
  end

  @doc """
  Close a previously opened serial port.

  Closes the underlying `Circuits.UART` connection, stops the GenServer,
  and removes it from the registry.
  """
  @spec close_port(binary()) :: :ok | {:error, term()}
  def close_port(port_name) do
    GenServer.call(__MODULE__, {:close_port, port_name})
  end

  @doc """
  List all currently opened ports and their configurations.

  Returns a list of `{port_name, %PortConfig{}}` tuples.
  """
  @spec list_ports() :: [{binary(), PortConfig.t()}]
  def list_ports do
    GenServer.call(__MODULE__, :list_ports)
  end

  @doc """
  Get the configuration for a specific opened port.

  Returns `{:ok, %PortConfig{}}` or `{:error, :not_found}`.
  """
  @spec port_info(binary()) :: {:ok, PortConfig.t()} | {:error, :not_found}
  def port_info(port_name) do
    GenServer.call(__MODULE__, {:port_info, port_name})
  end

  # -- Server Callbacks --

  @impl true
  def init(_opts) do
    {:ok, %{ports: %{}}}
  end

  @impl true
  def handle_call({:open_port, port_name, opts}, _from, state) do
    if Map.has_key?(state.ports, port_name) do
      {:reply, {:error, :already_open}, state}
    else
      case start_and_open(port_name, opts) do
        {:ok, pid, config} ->
          ref = Process.monitor(pid)
          entry = %{pid: pid, config: config, monitor_ref: ref}
          new_state = put_in(state, [:ports, port_name], entry)
          {:reply, {:ok, pid}, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:close_port, port_name}, _from, state) do
    case Map.fetch(state.ports, port_name) do
      {:ok, %{pid: pid, monitor_ref: ref}} ->
        Process.demonitor(ref, [:flush])
        Circuits.UART.close(pid)
        Circuits.UART.stop(pid)
        new_state = %{state | ports: Map.delete(state.ports, port_name)}
        {:reply, :ok, new_state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list_ports, _from, state) do
    result =
      state.ports
      |> Enum.map(fn {name, %{config: config}} -> {name, config} end)
      |> Enum.sort_by(fn {name, _} -> name end)

    {:reply, result, state}
  end

  def handle_call({:port_info, port_name}, _from, state) do
    case Map.fetch(state.ports, port_name) do
      {:ok, %{config: config}} ->
        {:reply, {:ok, config}, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {port_name, _entry} =
      Enum.find(state.ports, {nil, nil}, fn {_name, %{monitor_ref: r}} -> r == ref end)

    if port_name do
      new_state = %{state | ports: Map.delete(state.ports, port_name)}
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # -- Private Helpers --

  defp start_and_open(port_name, opts) do
    config = PortConfig.new(port_name, opts)
    uart_opts = PortConfig.to_uart_opts(config)

    with {:ok, pid} <- DynamicSupervisor.start_child(
           UniversalProxy.UART.PortSupervisor,
           {Circuits.UART, []}
         ),
         :ok <- Circuits.UART.open(pid, port_name, uart_opts) do
      {:ok, pid, config}
    else
      {:error, _reason} = error ->
        error
    end
  end
end
