defmodule UniversalProxy.UART.Server do
  @moduledoc """
  GenServer that manages a registry of opened UART ports.

  Each opened port gets its own `Circuits.UART` GenServer started under
  the `UniversalProxy.UART.PortSupervisor` DynamicSupervisor. This server
  tracks the mapping of port names to their PIDs and configurations, and
  monitors each UART process to clean up on unexpected exits.

  On startup, reads saved configs from `UniversalProxy.UART.Store` that have
  `auto_open: true`, matches them against currently enumerated hardware by
  serial number, and opens the matching ports with their saved settings.

  Incoming UART data is broadcast to PubSub topic `"uart:<friendly_name>"`.
  """

  use GenServer

  require Logger

  alias UniversalProxy.UART.PortConfig

  @pubsub UniversalProxy.PubSub

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
    send(self(), :auto_open_devices)
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
  def handle_info(:auto_open_devices, state) do
    new_state = auto_open_devices(state)
    {:noreply, new_state}
  end

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

  defp auto_open_devices(state) do
    alias UniversalProxy.UART.Store

    configs = Store.auto_open_configs()

    if configs == [] do
      Logger.info("UART auto-open: no saved configs with auto_open enabled")
      state
    else
      enumerated = Circuits.UART.enumerate()

      # Build a lookup: serial_number -> device_path
      serial_to_path =
        enumerated
        |> Enum.filter(fn {_path, info} -> present?(info[:serial_number]) end)
        |> Enum.into(%{}, fn {path, info} -> {info[:serial_number], path} end)

      Enum.reduce(configs, state, fn config, acc ->
        serial = config[:serial_number]
        friendly_name = config[:friendly_name] || "tty#{serial}"

        case Map.fetch(serial_to_path, serial) do
          {:ok, path} ->
            opts = [
              speed: config[:speed] || 9600,
              data_bits: config[:data_bits] || 8,
              stop_bits: config[:stop_bits] || 1,
              parity: config[:parity] || :none,
              flow_control: config[:flow_control] || :none,
              friendly_name: friendly_name
            ]

            case start_and_open(path, opts) do
              {:ok, pid, port_config} ->
                ref = Process.monitor(pid)
                entry = %{pid: pid, config: port_config, monitor_ref: ref}
                Logger.info("UART auto-opened #{path} as #{friendly_name} (serial: #{serial})")
                broadcast_lifecycle("uart:port_opened", path, port_config)
                put_in(acc, [:ports, path], entry)

              {:error, reason} ->
                Logger.warning("UART failed to auto-open #{path} (#{friendly_name}): #{inspect(reason)}")
                acc
            end

          :error ->
            Logger.info("UART auto-open: device with serial #{serial} (#{friendly_name}) not currently connected")
            acc
        end
      end)
    end
  rescue
    e ->
      Logger.warning("UART auto-open enumeration failed: #{inspect(e)}")
      state
  end

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

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(s) when is_binary(s), do: String.trim(s) != ""
  defp present?(_), do: false
end
