defmodule UniversalProxy.UART.PortConfig do
  @moduledoc """
  Data structure representing a UART port's identity and configuration.

  Mirrors all `Circuits.UART.uart_option()` fields and provides functions
  for constructing configs with sensible defaults and converting back to
  the keyword list format that `Circuits.UART.open/3` expects.
  """

  @type t :: %__MODULE__{
          name: binary(),
          speed: non_neg_integer(),
          data_bits: 5..8,
          stop_bits: 1..2,
          parity: :none | :even | :odd | :space | :mark | :ignore,
          flow_control: :none | :hardware | :software,
          framing: module() | {module(), [term()]} | nil,
          rx_framing_timeout: integer() | nil,
          active: boolean(),
          id: :name | :pid,
          rs485_enabled: boolean() | nil,
          rs485_rts_on_send: boolean() | nil,
          rs485_rts_after_send: boolean() | nil,
          rs485_rx_during_tx: boolean() | nil,
          rs485_terminate_bus: boolean() | nil,
          rs485_delay_rts_before_send: pos_integer() | nil,
          rs485_delay_rts_after_send: pos_integer() | nil
        }

  defstruct name: nil,
            speed: 9600,
            data_bits: 8,
            stop_bits: 1,
            parity: :none,
            flow_control: :none,
            framing: nil,
            rx_framing_timeout: nil,
            active: true,
            id: :name,
            rs485_enabled: nil,
            rs485_rts_on_send: nil,
            rs485_rts_after_send: nil,
            rs485_rx_during_tx: nil,
            rs485_terminate_bus: nil,
            rs485_delay_rts_before_send: nil,
            rs485_delay_rts_after_send: nil

  @uart_option_keys [
    :speed,
    :data_bits,
    :stop_bits,
    :parity,
    :flow_control,
    :framing,
    :rx_framing_timeout,
    :active,
    :id,
    :rs485_enabled,
    :rs485_rts_on_send,
    :rs485_rts_after_send,
    :rs485_rx_during_tx,
    :rs485_terminate_bus,
    :rs485_delay_rts_before_send,
    :rs485_delay_rts_after_send
  ]

  @doc """
  Build a new `%PortConfig{}` from a port name and keyword options.

  Applies sensible defaults for any option not provided:
  - speed: 9600
  - data_bits: 8
  - stop_bits: 1
  - parity: :none
  - flow_control: :none
  - active: true
  - id: :name

  ## Examples

      iex> config = UniversalProxy.UART.PortConfig.new("/dev/ttyUSB0", speed: 115200)
      iex> config.name
      "/dev/ttyUSB0"
      iex> config.speed
      115200
      iex> config.data_bits
      8

  """
  @spec new(binary(), keyword()) :: t()
  def new(name, opts \\ []) when is_binary(name) do
    fields = Keyword.take(opts, @uart_option_keys)
    struct!(__MODULE__, [{:name, name} | fields])
  end

  @doc """
  Convert a `%PortConfig{}` to the keyword list accepted by `Circuits.UART.open/3`.

  Strips any fields that are `nil` so only explicitly set options are passed
  to the underlying driver.
  """
  @spec to_uart_opts(t()) :: keyword()
  def to_uart_opts(%__MODULE__{} = config) do
    config
    |> Map.from_struct()
    |> Map.drop([:name])
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Keyword.new()
  end
end
