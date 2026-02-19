defmodule UniversalProxy.ESPHome.Server do
  @moduledoc """
  GenServer that holds the ESPHome device configuration, tracks
  active client connections, and builds the serial proxy instance list
  from the UART config store.

  The device identity (name, MAC, version, etc.) is configurable at
  runtime via `update_config/1`. Active connections are tracked via
  process monitors so the registry stays clean when connections close.

  On init, reads saved UART configs from the Store and matches them
  against currently enumerated hardware to build a list of advertised
  serial proxy instances (used in `DeviceInfoResponse`).
  """

  use GenServer

  require Logger

  alias UniversalProxy.ESPHome.DeviceConfig
  alias UniversalProxy.Protos

  defstruct [:config, connections: MapSet.new(), serial_proxies: [], instance_map: %{}]

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

  @doc """
  Returns the list of `%SerialProxyInfo{}` structs for DeviceInfoResponse.
  """
  @spec serial_proxies() :: [Protos.SerialProxyInfo.t()]
  def serial_proxies do
    GenServer.call(__MODULE__, :serial_proxies)
  end

  @doc """
  Returns the instance map: `%{instance_index => %{path: ..., friendly_name: ..., serial: ...}}`.

  Used by connection handlers to resolve instance indices to device paths.
  """
  @spec instance_map() :: map()
  def instance_map do
    GenServer.call(__MODULE__, :instance_map)
  end

  # -- Server Callbacks --

  @impl true
  def init(opts) do
    config = DeviceConfig.new(opts)
    advertise_mdns(config)

    {proxies, inst_map} = build_serial_proxies()

    Logger.info("ESPHome server started (port #{config.port}, name #{inspect(config.name)}, #{length(proxies)} serial proxies)")

    {:ok, %__MODULE__{config: config, serial_proxies: proxies, instance_map: inst_map}}
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

  def handle_call(:serial_proxies, _from, state) do
    {:reply, state.serial_proxies, state}
  end

  def handle_call(:instance_map, _from, state) do
    {:reply, state.instance_map, state}
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

  defp build_serial_proxies do
    configs = UniversalProxy.UART.Store.all_configs()
    enumerated = Circuits.UART.enumerate()

    serial_to_path =
      enumerated
      |> Enum.filter(fn {_path, info} -> present?(info[:serial_number]) end)
      |> Enum.into(%{}, fn {path, info} -> {info[:serial_number], path} end)

    # Only include configs whose device is currently connected, excluding Z-Wave devices
    connected_configs =
      configs
      |> Enum.filter(fn config ->
        Map.has_key?(serial_to_path, config[:serial_number]) and
          config[:port_type] != :zwave
      end)
      |> Enum.sort_by(fn config -> config[:friendly_name] || "tty#{config[:serial_number]}" end)

    proxies =
      connected_configs
      |> Enum.map(fn config ->
        %Protos.SerialProxyInfo{
          name: config[:friendly_name] || "tty#{config[:serial_number]}",
          port_type: port_type_to_proto(config[:port_type] || :ttl)
        }
      end)

    instance_map =
      connected_configs
      |> Enum.with_index()
      |> Enum.into(%{}, fn {config, index} ->
        serial = config[:serial_number]
        {index, %{
          path: Map.get(serial_to_path, serial),
          friendly_name: config[:friendly_name] || "tty#{serial}",
          serial: serial
        }}
      end)

    Logger.info("ESPHome serial proxies: #{length(proxies)} configured, #{map_size(instance_map)} connected")

    {proxies, instance_map}
  rescue
    e ->
      Logger.warning("ESPHome failed to build serial proxies: #{inspect(e)}")
      {[], %{}}
  end

  defp port_type_to_proto(:ttl), do: :SERIAL_PROXY_PORT_TYPE_TTL
  defp port_type_to_proto(:rs232), do: :SERIAL_PROXY_PORT_TYPE_RS232
  defp port_type_to_proto(:rs485), do: :SERIAL_PROXY_PORT_TYPE_RS485
  defp port_type_to_proto(_), do: :SERIAL_PROXY_PORT_TYPE_TTL

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(s) when is_binary(s), do: String.trim(s) != ""
  defp present?(_), do: false

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
