defmodule UniversalProxy.TuyaBeaconMesh.Inventory do
  @moduledoc """
  Decode / validate the JSON dump that configures a Beacon Mesh.

  Expected shape (atom or string keys; both accepted):

      {
        "beaconKey": "<32-hex mesh key>",
        "seq": 0,
        "bulbs": [
          {
            "mac": "DC23530FB34A",
            "localKey": "<16-char or 32-hex>",
            "nodeId": 2,
            "label": "path light 2",
            "beaconKey": "<optional; defaults to mesh beaconKey>"
          }
        ],
        "groups": [
          {"localId": 1, "name": "path and post", "members": ["DC23530FB34A"]}
        ]
      }

  Identity is the MAC. Duplicate MACs or duplicate `nodeId`s are rejected —
  the cloud reuses node ids across re-pairings, and report attribution is
  by node id on the wire, so twins silently share one status entry.
  """

  @type bulb :: %{
          mac: String.t(),
          local_key: String.t(),
          node_id: non_neg_integer(),
          label: String.t() | nil,
          beacon_key: String.t()
        }

  @type group :: %{
          local_id: byte(),
          name: String.t() | nil,
          members: [String.t()]
        }

  @type t :: %{
          beacon_key: String.t(),
          seq: non_neg_integer(),
          bulbs: [bulb()],
          groups: [group()]
        }

  @doc "Decodes a JSON binary or an already-decoded map."
  @spec decode(binary() | map()) :: {:ok, t()} | {:error, term()}
  def decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} -> decode(map)
      {:error, reason} -> {:error, {:json, reason}}
    end
  end

  def decode(map) when is_map(map) do
    with {:ok, beacon_key} <- fetch_key(map, ["beaconKey", "beacon_key"]),
         {:ok, seq} <- fetch_seq(map),
         {:ok, bulbs} <- fetch_bulbs(map, beacon_key),
         {:ok, groups} <- fetch_groups(map, bulbs) do
      {:ok, %{beacon_key: beacon_key, seq: seq, bulbs: bulbs, groups: groups}}
    end
  end

  def decode(_other), do: {:error, :not_a_map}

  @doc "Like `decode/1` but raises on error."
  @spec decode!(binary() | map()) :: t()
  def decode!(input) do
    case decode(input) do
      {:ok, inv} -> inv
      {:error, reason} -> raise ArgumentError, "bad inventory: #{inspect(reason)}"
    end
  end

  @doc "Encodes an inventory back to a JSON-friendly string-keyed map."
  @spec to_map(t()) :: map()
  def to_map(%{beacon_key: bk, seq: seq, bulbs: bulbs, groups: groups}) do
    %{
      "beaconKey" => bk,
      "seq" => seq,
      "bulbs" =>
        Enum.map(bulbs, fn b ->
          %{
            "mac" => b.mac,
            "localKey" => b.local_key,
            "nodeId" => b.node_id,
            "label" => b.label,
            "beaconKey" => b.beacon_key
          }
        end),
      "groups" =>
        Enum.map(groups, fn g ->
          %{"localId" => g.local_id, "name" => g.name, "members" => g.members}
        end)
    }
  end

  defp fetch_key(map, keys) do
    case first(map, keys) do
      value when is_binary(value) and byte_size(value) in [16, 32] -> {:ok, value}
      nil -> {:error, :missing_beacon_key}
      _other -> {:error, :bad_beacon_key}
    end
  end

  defp fetch_seq(map) do
    case first(map, ["seq", "seq_reserved"]) do
      nil -> {:ok, 0}
      n when is_integer(n) and n >= 0 and n <= 65_535 -> {:ok, n}
      _other -> {:error, :bad_seq}
    end
  end

  defp fetch_bulbs(map, mesh_key) do
    raw = first(map, ["bulbs", "lights"]) || []

    if not is_list(raw) or raw == [] do
      {:error, :no_bulbs}
    else
      raw
      |> Enum.reduce_while({:ok, [], MapSet.new(), MapSet.new()}, fn row,
                                                                     {:ok, acc, macs, nodes} ->
        case decode_bulb(row, mesh_key) do
          {:ok, bulb} ->
            cond do
              MapSet.member?(macs, bulb.mac) ->
                {:halt, {:error, {:duplicate_mac, bulb.mac}}}

              MapSet.member?(nodes, bulb.node_id) ->
                {:halt, {:error, {:duplicate_node_id, bulb.node_id, bulb.mac}}}

              true ->
                {:cont,
                 {:ok, [bulb | acc], MapSet.put(macs, bulb.mac), MapSet.put(nodes, bulb.node_id)}}
            end

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, bulbs, _macs, _nodes} -> {:ok, Enum.reverse(bulbs)}
        {:error, _} = err -> err
      end
    end
  end

  defp decode_bulb(row, mesh_key) when is_map(row) do
    with {:ok, mac} <- normalize_mac(first(row, ["mac", "MAC"])),
         {:ok, local_key} <- fetch_local_key(row),
         {:ok, node_id} <- fetch_node_id(row) do
      beacon_key = first(row, ["beaconKey", "beacon_key"]) || mesh_key
      label = first(row, ["label", "name"])

      if is_binary(beacon_key) and byte_size(beacon_key) in [16, 32] do
        {:ok,
         %{
           mac: mac,
           local_key: local_key,
           node_id: node_id,
           label: if(is_binary(label), do: label, else: nil),
           beacon_key: beacon_key
         }}
      else
        {:error, {:bad_bulb_beacon_key, mac}}
      end
    end
  end

  defp decode_bulb(_row, _mesh_key), do: {:error, :bad_bulb}

  defp fetch_local_key(row) do
    case first(row, ["localKey", "local_key"]) do
      value when is_binary(value) and byte_size(value) in [16, 32] -> {:ok, value}
      nil -> {:error, :missing_local_key}
      _other -> {:error, :bad_local_key}
    end
  end

  defp fetch_node_id(row) do
    case first(row, ["nodeId", "node_id"]) do
      n when is_integer(n) and n in 0..0xFFFF ->
        {:ok, n}

      bin when is_binary(bin) ->
        case Integer.parse(bin) do
          {n, ""} when n in 0..0xFFFF -> {:ok, n}
          _ -> {:error, :bad_node_id}
        end

      nil ->
        {:error, :missing_node_id}

      _other ->
        {:error, :bad_node_id}
    end
  end

  defp fetch_groups(map, bulbs) do
    raw = first(map, ["groups"]) || []
    known = MapSet.new(Enum.map(bulbs, & &1.mac))

    if not is_list(raw) do
      {:error, :bad_groups}
    else
      raw
      |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
        case decode_group(row, known) do
          {:ok, group} -> {:cont, {:ok, [group | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, groups} -> {:ok, Enum.reverse(groups)}
        {:error, _} = err -> err
      end
    end
  end

  defp decode_group(row, known) when is_map(row) do
    id = first(row, ["localId", "local_id", "id"])
    name = first(row, ["name", "label"])
    members = first(row, ["members"]) || []

    with true <- is_integer(id) and id in 0..255,
         true <- is_list(members),
         {:ok, macs} <- normalize_members(members, known) do
      {:ok, %{local_id: id, name: if(is_binary(name), do: name, else: nil), members: macs}}
    else
      false -> {:error, :bad_group}
      {:error, _} = err -> err
    end
  end

  defp decode_group(_row, _known), do: {:error, :bad_group}

  defp normalize_members(members, known) do
    Enum.reduce_while(members, {:ok, []}, fn m, {:ok, acc} ->
      case normalize_mac(m) do
        {:ok, mac} ->
          if MapSet.member?(known, mac) do
            {:cont, {:ok, acc ++ [mac]}}
          else
            {:halt, {:error, {:unknown_group_member, mac}}}
          end

        :error ->
          {:halt, {:error, {:bad_group_member, m}}}
      end
    end)
  end

  defp normalize_mac(mac) when is_binary(mac) do
    hex = mac |> String.replace(~r/[^0-9A-Fa-f]/, "") |> String.upcase()
    if byte_size(hex) == 12, do: {:ok, hex}, else: :error
  end

  defp normalize_mac(_), do: :error

  defp first(map, keys) do
    Enum.find_value(keys, fn key ->
      Map.get(map, key) || Map.get(map, to_string(key)) ||
        (is_binary(key) && Map.get(map, String.to_atom(key)))
    end)
  end
end
