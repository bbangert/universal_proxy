defmodule UniversalProxy.USB do
  @moduledoc """
  Shared utilities for USB device identification.
  """

  @doc """
  Parse a USB vendor or product ID from various input formats.

  Accepts integers (returned as-is), binary strings (with optional `0x` prefix,
  or bare decimal/hex), and returns `nil` for empty, unrecognizable, or
  non-binary/non-integer input.

  ## Examples

      iex> UniversalProxy.USB.parse_id(0x04D8)
      0x04D8

      iex> UniversalProxy.USB.parse_id("0x04D8")
      0x04D8

      iex> UniversalProxy.USB.parse_id("1240")
      1240

      iex> UniversalProxy.USB.parse_id("04D8")
      0x04D8

      iex> UniversalProxy.USB.parse_id("")
      nil

      iex> UniversalProxy.USB.parse_id(nil)
      nil
  """
  @spec parse_id(term()) :: non_neg_integer() | nil
  def parse_id(value) when is_integer(value) and value >= 0, do: value
  def parse_id(value) when is_integer(value), do: nil

  def parse_id(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    cond do
      normalized == "" ->
        nil

      String.starts_with?(normalized, "0x") ->
        parse_int(String.trim_leading(normalized, "0x"), 16)

      true ->
        parse_int(normalized, 10) || parse_int(normalized, 16)
    end
  end

  def parse_id(_), do: nil

  defp parse_int(value, base) do
    case Integer.parse(value, base) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end
end
