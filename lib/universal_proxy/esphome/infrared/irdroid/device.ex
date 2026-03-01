defmodule UniversalProxy.ESPHome.Infrared.Irdroid.Device do
  @moduledoc """
  IRDroid-specific device identification and entity factory.

  Encapsulates the USB vendor/product ID matching and per-PID capability
  mapping for the IRDroid / IR Toy family of USB infrared transceivers.
  """

  alias UniversalProxy.ESPHome.Infrared.Entity
  alias UniversalProxy.ESPHome.Infrared.Irdroid.DeviceWorker

  @vendor_id 0x04D8

  @known_product_ids %{
    0xFD08 => [:transmit],
    0xF58B => [:transmit, :receive]
  }

  @doc """
  Returns true if the enumeration info map matches a known IRDroid device.
  """
  @spec match?(map()) :: boolean()
  def match?(info) when is_map(info) do
    vid = parse_usb_id(info[:vendor_id])
    pid = parse_usb_id(info[:product_id])

    vid == @vendor_id and is_map_key(@known_product_ids, pid)
  end

  @doc """
  Build an `%Entity{}` from a saved UART config and enumeration info.

  The config comes from `UART.Store`, the info from `Circuits.UART.enumerate()`.
  """
  @spec build_entity(map(), String.t(), map()) :: Entity.t()
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
      worker_module: DeviceWorker
    )
  end

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
