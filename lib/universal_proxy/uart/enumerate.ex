defmodule UniversalProxy.UART.Enumerate do
  @moduledoc """
  Shared helpers for safely calling `Circuits.UART.enumerate/0` and
  building a `serial_number → path` map from its output.

  `Circuits.UART.enumerate/0` reads from `/sys` and can fail in unusual
  environments (CI containers, missing udev rules, permission issues).
  These helpers wrap the call so callers don't have to repeat the same
  fallback + filter logic.
  """

  require Logger

  @doc """
  Wrap `Circuits.UART.enumerate/0` so failures return `%{}` instead of
  raising. Logs at warning level so unexpected failures aren't silent.
  """
  @spec safe() :: map()
  def safe do
    Circuits.UART.enumerate()
  rescue
    e ->
      Logger.warning("UART enumerate failed: #{Exception.format(:error, e, __STACKTRACE__)}")

      %{}
  end

  @doc """
  Build a `%{serial_number => path}` map from `Circuits.UART.enumerate/0`
  output, skipping entries with a missing or blank serial number.
  """
  @spec serial_to_path(map()) :: %{String.t() => String.t()}
  def serial_to_path(enumerated) when is_map(enumerated) or is_list(enumerated) do
    enumerated
    |> Enum.filter(fn {_path, info} -> present?(info[:serial_number]) end)
    |> Enum.into(%{}, fn {path, info} -> {info[:serial_number], path} end)
  end

  @doc "True when the value is a non-empty, non-whitespace binary."
  @spec present?(term()) :: boolean()
  def present?(s) when is_binary(s), do: String.trim(s) != ""
  def present?(_), do: false
end
