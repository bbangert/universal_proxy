defmodule UniversalProxy.ESPHome.Infrared do
  @moduledoc """
  Public API for the infrared proxy subsystem.

  Provides a clean interface for ESPHome connection handlers to interact
  with infrared devices. This module is a thin boundary layer that delegates
  to the underlying `Infrared.Server`.

  ## Examples

      # List infrared entities for ListEntitiesRequest
      UniversalProxy.ESPHome.Infrared.list_entities()

      # Subscribe to receive infrared events
      UniversalProxy.ESPHome.Infrared.subscribe(self())

      # Transmit raw IR timings
      UniversalProxy.ESPHome.Infrared.transmit_raw(key, timings, carrier_frequency: 38000)

  """

  alias UniversalProxy.ESPHome.Infrared.Server

  defdelegate list_entities(), to: Server
  defdelegate transmit_raw(key, timings, opts), to: Server
  defdelegate subscribe(pid), to: Server
  defdelegate unsubscribe(pid), to: Server
end
