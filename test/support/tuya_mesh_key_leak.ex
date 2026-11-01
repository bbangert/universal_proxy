defmodule UniversalProxy.TuyaMesh.KeyLeak do
  @moduledoc """
  Test support: the example inventory in the representations a Store or
  Resolver request may carry it in, and an assertion that a text (a log, an
  inspected status) holds none of its keys in any encoding. Compile-only
  test support, never deployed.
  """

  import ExUnit.Assertions

  @fixture Path.join([__DIR__, "..", "fixtures", "tuya_beacon_mesh", "example_inventory.json"])
  @external_resource @fixture

  @beacon_key "00112233445566778899aabbccddeeff"
  @local_keys ["abcdefghijklmnop", "ponmlkjihgfedcba"]

  @doc "The example inventory dump as a JSON binary."
  def json, do: File.read!(@fixture)

  @doc "The same dump as a string-keyed map in snake_case (which decode also reads)."
  def snake_map do
    raw = Jason.decode!(json())

    %{
      "beacon_key" => raw["beaconKey"],
      "seq" => raw["seq"],
      "bulbs" =>
        Enum.map(raw["bulbs"], fn b ->
          %{"mac" => b["mac"], "local_key" => b["localKey"], "node_id" => b["nodeId"]}
        end)
    }
  end

  @doc "Refutes every encoding of every key of the example inventory in `text`."
  def refute_keys(text) when is_binary(text) do
    raw = Base.decode16!(@beacon_key, case: :lower)

    texts =
      [@beacon_key, String.upcase(@beacon_key), raw, inspect(raw), Base.encode64(raw)] ++
        [raw |> :binary.bin_to_list() |> Enum.join(", ")] ++
        Enum.flat_map(@local_keys, &[&1, Base.encode16(&1), Base.encode16(&1, case: :lower)])

    for secret <- texts do
      refute String.contains?(text, secret), "key material leaked: #{inspect(secret)}"
    end

    :ok
  end

  def refute_keys(term),
    do: refute_keys(inspect(term, limit: :infinity, printable_limit: :infinity))
end
