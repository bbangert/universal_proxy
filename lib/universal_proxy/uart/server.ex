defmodule UniversalProxy.UART.Server do
  @moduledoc """
  GenServer that manages a registry of opened UART ports.

  Each opened port gets its own `Circuits.UART` GenServer started under
  the `UniversalProxy.UART.PortSupervisor` DynamicSupervisor. This server
  tracks the mapping of port names to their PIDs and configurations, and
  monitors each UART process to clean up on unexpected exits.

  Ports are opened and closed exclusively by ESPHome clients via serial
  proxy protocol messages. There is no auto-open behaviour.

  Incoming UART data is broadcast to PubSub topic `"uart:<friendly_name>"`.
  """

  use GenServer

  require Logger

  alias UniversalProxy.UART.PortConfig

  @pubsub UniversalProxy.PubSub

  # -- Client API --

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
  Write binary data to an opened serial port.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec write_port(binary(), binary()) :: :ok | {:error, term()}
  def write_port(port_name, data) do
    GenServer.call(__MODULE__, {:write_port, port_name, data})
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
  List opened ports with their friendly names for display.

  Returns a sorted list of maps with `:path`, `:friendly_name`, and `:speed`.
  """
  @spec named_ports() :: [map()]
  def named_ports do
    GenServer.call(__MODULE__, :named_ports)
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
          broadcast_lifecycle("uart:port_opened", port_name, config)
          {:reply, {:ok, pid}, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:close_port, port_name}, _from, state) do
    case Map.fetch(state.ports, port_name) do
      {:ok, %{pid: pid, config: config, monitor_ref: ref}} ->
        Process.demonitor(ref, [:flush])
        Circuits.UART.close(pid)
        Circuits.UART.stop(pid)
        new_state = %{state | ports: Map.delete(state.ports, port_name)}
        broadcast_lifecycle("uart:port_closed", port_name, config)
        {:reply, :ok, new_state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:write_port, port_name, data}, _from, state) do
    case Map.fetch(state.ports, port_name) do
      {:ok, %{pid: pid}} ->
        result = Circuits.UART.write(pid, data)
        {:reply, result, state}

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

  def handle_call(:named_ports, _from, state) do
    result =
      state.ports
      |> Enum.map(fn {path, %{config: config}} ->
        %{
          path: path,
          friendly_name: config.friendly_name || path,
          speed: config.speed
        }
      end)
      |> Enum.sort_by(& &1.friendly_name)

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
  def handle_info({:circuits_uart, port_name, data}, state) do
    case Map.fetch(state.ports, port_name) do
      {:ok, %{config: config}} ->
        friendly_name = config.friendly_name || port_name

        message = %{
          name: friendly_name,
          data: data,
          timestamp: DateTime.utc_now()
        }

        Phoenix.PubSub.broadcast(@pubsub, "uart:#{friendly_name}", {:uart_data, message})

      :error ->
        Logger.debug("UART data from untracked port: #{port_name}")
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {port_name, entry} =
      Enum.find(state.ports, {nil, nil}, fn {_name, %{monitor_ref: r}} -> r == ref end)

    if port_name do
      if entry, do: broadcast_lifecycle("uart:port_closed", port_name, entry.config)
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

  defp broadcast_lifecycle(topic, port_name, config) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      topic,
      {String.to_atom(String.replace(topic, ":", "_")),
       %{path: port_name, friendly_name: config.friendly_name || port_name}}
    )
  end
end
