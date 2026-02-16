defmodule UniversalProxy.ESPHome do
  @moduledoc """
  Public API for the ESPHome Native API subsystem.

  This component makes the device discoverable and controllable as an
  ESPHome device by listening on TCP port 6053 (configurable) and
  speaking the ESPHome plaintext protocol with protobuf-encoded messages.

  ## Examples

      # View current device identity
      UniversalProxy.ESPHome.config()

      # Update the device name at runtime
      UniversalProxy.ESPHome.update_config(name: "my-proxy", friendly_name: "My Proxy")

      # Check how many clients are connected
      UniversalProxy.ESPHome.connections()

      # Get the listening port
      UniversalProxy.ESPHome.port()

  """

  alias UniversalProxy.ESPHome.Server

  @doc """
  Returns the current ESPHome device configuration.

  ## Examples

      config = UniversalProxy.ESPHome.config()
      config.name
      #=> "universal-proxy"

  """
  @spec config() :: UniversalProxy.ESPHome.DeviceConfig.t()
  def config do
    Server.get_config()
  end

  @doc """
  Update the device configuration at runtime.

  Accepts a keyword list of fields to change. Only provided fields are
  updated; all others retain their current values.

  Note: changing the `:port` does not rebind the TCP listener. The port
  setting only takes effect on (re)start.

  Returns the updated config.

  ## Examples

      UniversalProxy.ESPHome.update_config(
        name: "my-device",
        friendly_name: "Living Room Proxy",
        mac_address: "AA:BB:CC:DD:EE:FF"
      )

  """
  @spec update_config(keyword()) :: UniversalProxy.ESPHome.DeviceConfig.t()
  def update_config(opts) when is_list(opts) do
    Server.update_config(opts)
  end

  @doc """
  Returns a list of PIDs for currently active client connections.

  ## Examples

      UniversalProxy.ESPHome.connections()
      #=> [#PID<0.456.0>, #PID<0.489.0>]

  """
  @spec connections() :: [pid()]
  def connections do
    Server.list_connections()
  end

  @doc """
  Returns the TCP port the ESPHome API is listening on.

  ## Examples

      UniversalProxy.ESPHome.port()
      #=> 6053

  """
  @spec port() :: non_neg_integer()
  def port do
    config().port
  end
end
