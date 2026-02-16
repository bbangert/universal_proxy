defmodule UniversalProxy.ESPHome.Server do
  @moduledoc """
  GenServer that holds the ESPHome device configuration and tracks
  active client connections.

  The device identity (name, MAC, version, etc.) is configurable at
  runtime via `update_config/1`. Active connections are tracked via
  process monitors so the registry stays clean when connections close.
  """

  use GenServer

  require Logger

  alias UniversalProxy.ESPHome.DeviceConfig

  defstruct [:config, connections: MapSet.new()]

  # -- Client API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the current device configuration.
  """
  @spec get_config() :: DeviceConfig.t()
  def get_config do
    GenServer.call(__MODULE__, :get_config)
  end

  @doc """
  Update the device configuration at runtime.

  Accepts a keyword list of fields to change. Returns the updated config.
  """
  @spec update_config(keyword()) :: DeviceConfig.t()
  def update_config(updates) when is_list(updates) do
    GenServer.call(__MODULE__, {:update_config, updates})
  end

  @doc """
  Register a new connection process for tracking.
  """
  @spec register_connection(pid()) :: :ok
  def register_connection(pid) when is_pid(pid) do
    GenServer.cast(__MODULE__, {:register_connection, pid})
  end

  @doc """
  Returns the list of active connection PIDs.
  """
  @spec list_connections() :: [pid()]
  def list_connections do
    GenServer.call(__MODULE__, :list_connections)
  end

  @doc """
  Returns the count of active connections.
  """
  @spec connection_count() :: non_neg_integer()
  def connection_count do
    GenServer.call(__MODULE__, :connection_count)
  end

  # -- Server Callbacks --

  @impl true
  def init(opts) do
    config = DeviceConfig.new(opts)
    advertise_mdns(config)
    Logger.info("ESPHome server started (port #{config.port}, name #{inspect(config.name)})")
    {:ok, %__MODULE__{config: config}}
  end

  @impl true
  def handle_call(:get_config, _from, state) do
    {:reply, state.config, state}
  end

  def handle_call({:update_config, updates}, _from, state) do
    new_config = struct!(state.config, updates)
    advertise_mdns(new_config)
    {:reply, new_config, %{state | config: new_config}}
  end

  def handle_call(:list_connections, _from, state) do
    {:reply, MapSet.to_list(state.connections), state}
  end

  def handle_call(:connection_count, _from, state) do
    {:reply, MapSet.size(state.connections), state}
  end

  @impl true
  def handle_cast({:register_connection, pid}, state) do
    Process.monitor(pid)
    new_connections = MapSet.put(state.connections, pid)
    Logger.info("ESPHome connection registered (#{MapSet.size(new_connections)} active)")
    {:noreply, %{state | connections: new_connections}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    new_connections = MapSet.delete(state.connections, pid)
    level = if reason == :normal, do: :info, else: :warning
    Logger.log(level, "ESPHome connection #{inspect(pid)} down: #{inspect(reason)} (#{MapSet.size(new_connections)} active)")
    {:noreply, %{state | connections: new_connections}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # -- Private helpers --

  defp advertise_mdns(config) do
    service = DeviceConfig.to_mdns_service(config)

    if Code.ensure_loaded?(MdnsLite) do
      try do
        MdnsLite.remove_mdns_service(service.id)
        MdnsLite.add_mdns_service(service)
        Logger.info("ESPHome mDNS service registered: #{service.protocol}.#{service.transport} port #{service.port}")
      rescue
        e ->
          Logger.warning("ESPHome mDNS registration failed: #{inspect(e)}")
      catch
        kind, reason ->
          Logger.warning("ESPHome mDNS registration error: #{inspect(kind)} #{inspect(reason)}")
      end
    else
      Logger.info("ESPHome mDNS not available (MdnsLite not loaded), skipping advertisement")
    end
  end
end
