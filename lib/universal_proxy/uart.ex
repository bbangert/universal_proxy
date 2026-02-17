defmodule UniversalProxy.UART do
  @moduledoc """
  Public API for the UART subsystem.

  Provides a clean interface for discovering serial ports, opening them
  with configurable settings, writing data, and querying which ports are
  currently open. Also exposes the persistent config store for the
  Connected Devices UI.

  This module is a thin boundary layer that delegates to the underlying
  `UniversalProxy.UART.Server` and `UniversalProxy.UART.Store` GenServers.
  All process mechanics are hidden behind this interface.
  """

  alias UniversalProxy.UART.{Server, Store}

  # -- Hardware Enumeration --

  @doc """
  Enumerate available serial ports on the system.

  Returns a map of port names to their hardware information (vendor ID,
  product ID, manufacturer, serial number, description).

  Delegates directly to `Circuits.UART.enumerate/0`.
  """
  @spec enumerate() :: map()
  def enumerate do
    Circuits.UART.enumerate()
  end

  # -- Port Lifecycle (called by ESPHome connection handlers) --

  @doc """
  Open a serial port with the given options.

  Starts a new `Circuits.UART` GenServer, opens the named port with the
  provided settings, and registers it for tracking.

  Returns `{:ok, pid}` on success or `{:error, reason}` on failure.
  """
  @spec open(binary(), keyword()) :: {:ok, pid()} | {:error, term()}
  def open(port_name, opts \\ []) do
    Server.open_port(port_name, opts)
  end

  @doc """
  Close a previously opened serial port.

  Closes the underlying connection, stops the `Circuits.UART` GenServer,
  and removes it from the registry.

  Returns `:ok` on success or `{:error, :not_found}` if the port was not open.
  """
  @spec close(binary()) :: :ok | {:error, term()}
  def close(port_name) do
    Server.close_port(port_name)
  end

  @doc """
  Write binary data to an opened serial port.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec write(binary(), binary()) :: :ok | {:error, term()}
  def write(port_name, data) do
    Server.write_port(port_name, data)
  end

  # -- Port Queries --

  @doc """
  List all currently opened ports and their configurations.

  Returns a list of `{port_name, %UniversalProxy.UART.PortConfig{}}` tuples,
  sorted by port name.
  """
  @spec ports() :: [{binary(), UniversalProxy.UART.PortConfig.t()}]
  def ports do
    Server.list_ports()
  end

  @doc """
  Get the configuration for a specific opened port.

  Returns `{:ok, %UniversalProxy.UART.PortConfig{}}` if the port is open,
  or `{:error, :not_found}` if it is not tracked.
  """
  @spec port_info(binary()) :: {:ok, UniversalProxy.UART.PortConfig.t()} | {:error, :not_found}
  def port_info(port_name) do
    Server.port_info(port_name)
  end

  @doc """
  List opened ports with their friendly names.

  Returns a sorted list of maps with `:path`, `:friendly_name`, and `:speed`
  keys. Useful for display in the web UI.
  """
  @spec named_ports() :: [map()]
  def named_ports do
    Server.named_ports()
  end

  # -- Persistent Config API (delegates to UART.Store) --

  @doc """
  Save or update a persistent UART device configuration.

  The configuration is keyed by `serial_number` and persists across reboots.
  Only stores `port_type` (:ttl, :rs232, :rs485). Triggers an ESPHome
  supervisor restart to force client reconnects.
  """
  @spec save_config(String.t(), map()) :: :ok
  def save_config(serial_number, params) do
    Store.save_config(serial_number, params)
  end

  @doc """
  Delete a saved device configuration by serial number.

  Triggers an ESPHome supervisor restart to force client reconnects.
  """
  @spec delete_config(String.t()) :: :ok
  def delete_config(serial_number) do
    Store.delete_config(serial_number)
  end

  @doc """
  Look up a saved configuration by serial number.

  Returns `{:ok, config_map}` or `:error` if not found.
  """
  @spec get_config(String.t()) :: {:ok, map()} | :error
  def get_config(serial_number) do
    Store.get_config(serial_number)
  end

  @doc """
  List all saved device configurations.

  Returns a list of config maps (one per saved device).
  """
  @spec saved_configs() :: [map()]
  def saved_configs do
    Store.all_configs()
  end
end
