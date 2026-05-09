defmodule UniversalProxy.ESPHome.Infrared.Irdroid.Device do
  @moduledoc """
  IRDroid-specific implementation of the `Infrared.Device` behaviour.

  Encapsulates USB vendor/product ID matching, per-PID capability mapping,
  worker lifecycle, and transmit delegation for the IRDroid / IR Toy family
  of USB infrared transceivers.
  """

  @behaviour UniversalProxy.ESPHome.Infrared.Device

  alias UniversalProxy.ESPHome.Infrared.Irdroid.DeviceWorker
  alias UniversalProxy.ESPHome.Infrared.Server

  @vendor_id 0x04D8

  @known_product_ids %{
    0xFD08 => [:transmit],
    0xF58B => [:transmit, :receive]
  }

  @impl true
  def match?(info) when is_map(info) do
    vid = UniversalProxy.USB.parse_id(info[:vendor_id])
    pid = UniversalProxy.USB.parse_id(info[:product_id])

    vid == @vendor_id and is_map_key(@known_product_ids, pid)
  end

  @impl true
  def build_entity(config, _port_path, info) do
    pid = UniversalProxy.USB.parse_id(info[:product_id])
    serial = config[:serial_number]
    capabilities = Map.get(@known_product_ids, pid, [:transmit])

    Server.build_entity(
      serial_number: serial,
      name: config[:friendly_name] || "IRDroid / IR Toy",
      capabilities: capabilities
    )
  end

  @impl true
  def child_spec(entry, server_pid) do
    %{
      id: entry.entity.key,
      start: {DeviceWorker, :start_link, [[entry: entry, server_pid: server_pid]]},
      restart: :temporary
    }
  end

  @impl true
  defdelegate transmit(worker, timings, opts), to: DeviceWorker
end
