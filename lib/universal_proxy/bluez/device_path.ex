defmodule UniversalProxy.Bluez.DevicePath do
  @moduledoc """
  Convert between espex BLE addresses and BlueZ device object paths.

  Espex identifies peripherals by the 48-bit MAC packed MSB-first into a
  uint64 (`0xAABBCCDDEEFF`); BlueZ identifies them by object path
  (`/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF`). Pure and host-testable.

  Only `hci0` is supported — same single-adapter assumption as
  `UniversalProxy.Bluez.Client`.
  """

  @adapter_path "/org/bluez/hci0"
  @max_address 0xFFFFFFFFFFFF

  @doc "Object path of the BlueZ adapter all device paths hang off."
  @spec adapter_path() :: String.t()
  def adapter_path, do: @adapter_path

  @doc """
  Whether `address` is a representable 48-bit MAC. The wire type is uint64,
  so a hostile client can send values `from_address/1` would refuse —
  validate before converting.
  """
  @spec valid?(term()) :: boolean()
  def valid?(address),
    do: is_integer(address) and address >= 0 and address <= @max_address

  @doc """
  Build the device object path for a packed MAC address.

      iex> UniversalProxy.Bluez.DevicePath.from_address(0xAABBCCDDEEFF)
      "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF"
  """
  @spec from_address(non_neg_integer()) :: String.t()
  def from_address(address)
      when is_integer(address) and address >= 0 and address <= @max_address do
    octets =
      address
      |> Integer.to_string(16)
      |> String.pad_leading(12, "0")
      |> String.upcase()
      |> octet_pairs()

    "#{@adapter_path}/dev_#{Enum.join(octets, "_")}"
  end

  @doc """
  Parse a device object path back into a packed MAC address.

      iex> UniversalProxy.Bluez.DevicePath.to_address("/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF") == {:ok, 0xAABBCCDDEEFF}
      true

  Returns `:error` for anything that isn't an `hci0` device path (including
  child paths like `.../dev_X/service000a`).
  """
  @spec to_address(String.t()) :: {:ok, non_neg_integer()} | :error
  def to_address(@adapter_path <> "/dev_" <> rest) do
    with false <- String.contains?(rest, "/"),
         hex = String.replace(rest, "_", ""),
         true <- byte_size(hex) == 12,
         {address, ""} <- Integer.parse(hex, 16) do
      {:ok, address}
    else
      _ -> :error
    end
  end

  def to_address(path) when is_binary(path), do: :error

  defp octet_pairs(<<a::binary-size(2), rest::binary>>), do: [a | octet_pairs(rest)]
  defp octet_pairs(<<>>), do: []
end
