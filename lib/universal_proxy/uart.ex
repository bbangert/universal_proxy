defmodule UniversalProxy.UART do
  @moduledoc """
  Public API for the UART subsystem.

  Provides a clean interface for discovering serial ports, opening them
  with configurable settings, and querying which ports are currently open.

  This module is a thin boundary layer that delegates to the underlying
  `UniversalProxy.UART.Server` GenServer. All process mechanics are hidden
  behind this interface.

  ## Examples

      # Discover available serial ports
      UniversalProxy.UART.enumerate()

      # Open a port with custom settings
      {:ok, pid} = UniversalProxy.UART.open("/dev/ttyUSB0", speed: 115200, data_bits: 8)

      # List all opened ports
      UniversalProxy.UART.ports()

      # Get config for a specific port
      {:ok, config} = UniversalProxy.UART.port_info("/dev/ttyUSB0")

      # Close when done
      :ok = UniversalProxy.UART.close("/dev/ttyUSB0")

  """

  alias UniversalProxy.UART.Server

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

  @doc """
  Open a serial port with the given options.

  Starts a new `Circuits.UART` GenServer, opens the named port with the
  provided settings, and registers it for tracking.

  Returns `{:ok, pid}` on success or `{:error, reason}` on failure.

  ## Options

  All `Circuits.UART.uart_option()` values are supported:

    * `:speed` - baudrate (default: 9600)
    * `:data_bits` - 5, 6, 7, or 8 (default: 8)
    * `:stop_bits` - 1 or 2 (default: 1)
    * `:parity` - `:none`, `:even`, `:odd`, `:space`, `:mark`, `:ignore` (default: `:none`)
    * `:flow_control` - `:none`, `:hardware`, `:software` (default: `:none`)
    * `:framing` - a module or `{module, args}` implementing `Circuits.UART.Framing`
    * `:rx_framing_timeout` - milliseconds to wait for incomplete frames
    * `:active` - `true` or `false` for message-based or poll-based receiving (default: `true`)
    * `:id` - `:name` or `:pid` for active message identification (default: `:name`)

  Linux-only RS485 options:

    * `:rs485_enabled` - enable RS485 mode
    * `:rs485_rts_on_send` - enable RTS on send
    * `:rs485_rts_after_send` - enable RTS after send
    * `:rs485_rx_during_tx` - enable RX during TX (loopback)
    * `:rs485_terminate_bus` - enable bus termination
    * `:rs485_delay_rts_before_send` - milliseconds to delay RTS before send
    * `:rs485_delay_rts_after_send` - milliseconds to delay RTS after send

  ## Examples

      {:ok, pid} = UniversalProxy.UART.open("/dev/ttyUSB0", speed: 115200)
      {:error, :enoent} = UniversalProxy.UART.open("/dev/nonexistent")

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

  ## Examples

      :ok = UniversalProxy.UART.close("/dev/ttyUSB0")

  """
  @spec close(binary()) :: :ok | {:error, term()}
  def close(port_name) do
    Server.close_port(port_name)
  end

  @doc """
  List all currently opened ports and their configurations.

  Returns a list of `{port_name, %UniversalProxy.UART.PortConfig{}}` tuples,
  sorted by port name.

  ## Examples

      [
        {"/dev/ttyUSB0", %UniversalProxy.UART.PortConfig{speed: 115200, ...}},
        {"/dev/ttyUSB1", %UniversalProxy.UART.PortConfig{speed: 9600, ...}}
      ] = UniversalProxy.UART.ports()

  """
  @spec ports() :: [{binary(), UniversalProxy.UART.PortConfig.t()}]
  def ports do
    Server.list_ports()
  end

  @doc """
  Get the configuration for a specific opened port.

  Returns `{:ok, %UniversalProxy.UART.PortConfig{}}` if the port is open,
  or `{:error, :not_found}` if it is not tracked.

  ## Examples

      {:ok, config} = UniversalProxy.UART.port_info("/dev/ttyUSB0")
      config.speed
      #=> 115200

  """
  @spec port_info(binary()) :: {:ok, UniversalProxy.UART.PortConfig.t()} | {:error, :not_found}
  def port_info(port_name) do
    Server.port_info(port_name)
  end
end
