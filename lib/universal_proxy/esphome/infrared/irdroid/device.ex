defmodule UniversalProxy.ESPHome.Infrared.Irdroid.Device do
  @moduledoc """
  IRDroid-specific implementation of the `Infrared.Device` behaviour.

  Encapsulates USB vendor/product ID matching, per-PID capability mapping,
  worker lifecycle, and transmit delegation for the IRDroid / IR Toy family
  of USB infrared transceivers.
  """

  @behaviour UniversalProxy.ESPHome.Infrared.Device

  alias UniversalProxy.ESPHome.Infrared.Entity
  alias UniversalProxy.ESPHome.Infrared.Irdroid.DeviceWorker

  @vendor_id 0x04D8

  @known_product_ids %{
    0xFD08 => [:transmit],
    0xF58B => [:transmit, :receive]
  }

  @impl true
  def match?(info) when is_map(info) do
    vid = parse_usb_id(info[:vendor_id])
    pid = parse_usb_id(info[:product_id])

    vid == @vendor_id and is_map_key(@known_product_ids, pid)
  end

  @impl true
  def build_entity(config, port_path, info) do
    pid = parse_usb_id(info[:product_id])
    serial = config[:serial_number]
    capabilities = Map.get(@known_product_ids, pid, [:transmit])

    Entity.new(
      serial_number: serial,
      port_path: port_path,
      product_id: pid,
      name: config[:friendly_name] || "IRDroid / IR Toy",
      capabilities: capabilities,
      device_module: __MODULE__
    )
  end

  @impl true
  def child_spec(entity, server_pid) do
    %{
      id: entity.key,
      start: {DeviceWorker, :start_link, [[entity: entity, server_pid: server_pid]]},
      restart: :transient
    }
  end

  @impl true
  defdelegate transmit(worker, timings, opts), to: DeviceWorker

  defp parse_usb_id(value) when is_integer(value), do: value

  defp parse_usb_id(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    cond do
      normalized == "" ->
        nil

      String.starts_with?(normalized, "0x") ->
        case Integer.parse(String.trim_leading(normalized, "0x"), 16) do
          {parsed, ""} -> parsed
          _ -> nil
        end

      true ->
        case Integer.parse(normalized, 10) do
          {parsed, ""} -> parsed
          _ ->
            case Integer.parse(normalized, 16) do
              {parsed, ""} -> parsed
              _ -> nil
            end
        end
    end
  end

  defp parse_usb_id(_), do: nil
end
