defmodule UniversalProxy.ESPHome.ZWave do
  @moduledoc """
  Public API for the Z-Wave proxy subsystem.

  Provides a clean interface for ESPHome connection handlers to interact
  with the Z-Wave proxy server. This module is a thin boundary layer that
  delegates to the underlying `UniversalProxy.ESPHome.ZWave.Server`.

  ## Examples

      # Check if a Z-Wave device is available
      UniversalProxy.ESPHome.ZWave.available?()

      # Subscribe a connection to receive Z-Wave frames
      {:ok, home_id_bytes} = UniversalProxy.ESPHome.ZWave.subscribe(self())

      # Send a frame from the client to the Z-Wave stick
      UniversalProxy.ESPHome.ZWave.send_frame(data)

      # Get the current home ID as uint32
      UniversalProxy.ESPHome.ZWave.home_id()

  """

  alias UniversalProxy.ESPHome.ZWave.Server

  @home_id_changed_topic "zwave:home_id_changed"

  defdelegate subscribe(pid), to: Server
  defdelegate unsubscribe(pid), to: Server
  defdelegate send_frame(data), to: Server
  defdelegate home_id(), to: Server
  defdelegate available?(), to: Server

  @doc """
  Returns the PubSub topic for Z-Wave home ID change broadcasts.
  """
  @spec home_id_changed_topic() :: String.t()
  def home_id_changed_topic, do: @home_id_changed_topic
end
