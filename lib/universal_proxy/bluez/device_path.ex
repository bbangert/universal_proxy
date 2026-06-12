defmodule UniversalProxy.Bluez.DevicePath do
  @moduledoc """
  Convert between espex BLE addresses and BlueZ device object paths.

  Espex identifies peripherals by the 48-bit MAC packed MSB-first into a
  uint64 (`0xAABBCCDDEEFF`); BlueZ identifies them by object path
  (`/org/bluez/hciX/dev_AA_BB_CC_DD_EE_FF`). Host-testable; the only
  process-external input is the adapter path below.

  ## Adapter path

  Which `hciX` the whole BlueZ subtree drives is decided at subtree start:
  `UniversalProxy.Bluetooth.Manager` resolves the selected radio MAC and
  publishes the adapter object path as `:persistent_term`
  (`adapter_path_key/0`) **before** (re)starting the subtree, so every
  read here is consistent for the lifetime of a subtree incarnation
  (crash-restarts re-read the unchanged term). The default — term never
  written, e.g. host tests — is `/org/bluez/hci0`.

  Reading the term costs nanoseconds, so callers just call
  `adapter_path/0` per use rather than caching it.
  """

  @adapter_path_key {UniversalProxy.Bluez, :adapter_path}
  @default_adapter_path "/org/bluez/hci0"
  @max_address 0xFFFFFFFFFFFF

  @doc """
  Object path of the BlueZ adapter all device paths hang off — wherever
  `UniversalProxy.Bluetooth.Manager` pointed the subtree, `/org/bluez/hci0`
  by default.
  """
  @spec adapter_path() :: String.t()
  def adapter_path, do: :persistent_term.get(@adapter_path_key, @default_adapter_path)

  @doc """
  The `:persistent_term` key the adapter path is published under. Written
  exclusively by `UniversalProxy.Bluetooth.Manager` (and tests).
  """
  @spec adapter_path_key() :: tuple()
  def adapter_path_key, do: @adapter_path_key

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

    "#{adapter_path()}/dev_#{Enum.join(octets, "_")}"
  end

  @doc """
  Parse a device object path back into a packed MAC address.

      iex> UniversalProxy.Bluez.DevicePath.to_address("/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF") == {:ok, 0xAABBCCDDEEFF}
      true

  Returns `:error` for anything that isn't a device path under the current
  adapter (including child paths like `.../dev_X/service000a`).
  """
  @spec to_address(String.t()) :: {:ok, non_neg_integer()} | :error
  def to_address(path) when is_binary(path) do
    prefix = adapter_path() <> "/dev_"

    with true <- String.starts_with?(path, prefix),
         rest = binary_part(path, byte_size(prefix), byte_size(path) - byte_size(prefix)),
         false <- String.contains?(rest, "/"),
         hex = String.replace(rest, "_", ""),
         true <- byte_size(hex) == 12,
         {address, ""} <- Integer.parse(hex, 16) do
      {:ok, address}
    else
      _ -> :error
    end
  end

  defp octet_pairs(<<a::binary-size(2), rest::binary>>), do: [a | octet_pairs(rest)]
  defp octet_pairs(<<>>), do: []
end
