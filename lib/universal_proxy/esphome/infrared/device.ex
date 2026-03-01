defmodule UniversalProxy.ESPHome.Infrared.Device do
  @moduledoc """
  Behaviour for infrared product-family modules.

  Each supported hardware family (IRDroid, future products) implements this
  behaviour to provide identification, worker lifecycle, and ESPHome-native
  transmit/receive translation. The generic `Infrared.Server` dispatches
  through these callbacks without knowing product-specific details.

  ## Receive contract

  Workers started via `child_spec/2` must send
  `{:infrared_receive, key, timings}` to the given `server_pid` when IR
  signals are received. Timings are signed microsecond integers (positive =
  mark, negative = space). This is a message protocol and cannot be
  expressed as a callback.
  """

  alias UniversalProxy.ESPHome.Infrared.Entity

  @doc "Returns true if the USB enumeration info matches this product family."
  @callback match?(info :: map()) :: boolean()

  @doc "Build an Entity from a saved UART config, port path, and enumeration info."
  @callback build_entity(config :: map(), port_path :: String.t(), info :: map()) :: Entity.t()

  @doc """
  Return a child spec for starting a worker process under the DynamicSupervisor.

  The worker must send `{:infrared_receive, key, timings}` to `server_pid`
  when IR signals are received (timings as signed microsecond integers,
  positive = mark, negative = space).
  """
  @callback child_spec(entity :: Entity.t(), server_pid :: pid()) :: Supervisor.child_spec()

  @doc """
  Transmit ESPHome-native IR timings through a running worker process.

  Timings are signed microsecond integers (positive = mark, negative = space).
  The implementation handles all translation to the device-specific wire protocol.

  Options: `:carrier_frequency` (Hz, default 38000), `:repeat_count` (default 1).
  """
  @callback transmit(worker :: pid(), timings :: [integer()], opts :: keyword()) ::
              :ok | {:error, term()}
end
