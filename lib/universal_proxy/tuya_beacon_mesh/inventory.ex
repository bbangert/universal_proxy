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
  Duplicate labels, group ids and group names are rejected too, since
  they are what callers address bulbs and groups by.

  Every key must be usable as-is (`UniversalProxy.TuyaBeaconMesh.Crypto.parse_key/1`): 32
  hex chars, or 16 printable ASCII chars. Node ids are unicast addresses
  `0..0x7FFF` (`0x8000`/`0x8001` are the phone, `0xFFxx` groups and
  broadcast) and group ids `0..254` (`FF FF` is broadcast). A JSON dump
  may be at most #{64 * 1024} bytes.

  `decode/1` also takes an already-decoded `t()` and re-validates it, so
  anything that reaches the radio has passed these checks. The structs'
  `Inspect` leaves the keys out.
  """

  alias UniversalProxy.TuyaBeaconMesh.Crypto

  @max_json_bytes 64 * 1024
  @max_node_id 0x7FFF
  @max_group_id 254

  defmodule Bulb do
    @moduledoc "One bulb of an `UniversalProxy.TuyaBeaconMesh.Inventory`."
    @derive {Inspect, except: [:local_key, :beacon_key]}
    @enforce_keys [:mac, :local_key, :node_id, :beacon_key]
    defstruct [:mac, :local_key, :node_id, :label, :beacon_key]

    @type t :: %__MODULE__{
            mac: String.t(),
            local_key: String.t(),
            node_id: 0..0x7FFF,
            label: String.t() | nil,
            beacon_key: String.t()
          }
  end

  defmodule Group do
    @moduledoc "One local group of an `UniversalProxy.TuyaBeaconMesh.Inventory`."
    @enforce_keys [:local_id, :members]
    defstruct [:local_id, :name, members: []]

    @type t :: %__MODULE__{local_id: 0..254, name: String.t() | nil, members: [String.t()]}
  end

  @derive {Inspect, except: [:beacon_key]}
  @enforce_keys [:beacon_key, :bulbs]
  defstruct [:beacon_key, seq: 0, bulbs: [], groups: []]

  @type bulb :: Bulb.t()
  @type group :: Group.t()

  @type t :: %__MODULE__{
          beacon_key: String.t(),
          seq: 0..65_535,
          bulbs: [bulb()],
          groups: [group()]
        }

  @doc """
  Decodes a JSON binary, an already-decoded map, or an existing `t()`
  (re-validated). Errors never carry key material.
  """
  @spec decode(binary() | map() | t()) :: {:ok, t()} | {:error, term()}
  def decode(json) when is_binary(json) and byte_size(json) > @max_json_bytes,
    do: {:error, :too_large}

  def decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} -> decode(map)
      # The error struct carries the whole input (keys included): keep
      # only the position.
      {:error, %Jason.DecodeError{position: position}} -> {:error, {:invalid_json, position}}
    end
  end

  def decode(%__MODULE__{} = inv), do: inv |> Map.from_struct() |> decode()

  def decode(map) when is_map(map) do
    with {:ok, beacon_key} <- fetch_mesh_key(map),
         {:ok, seq} <- fetch_seq(map),
         {:ok, bulbs} <- fetch_bulbs(map, beacon_key),
         {:ok, groups} <- fetch_groups(map, bulbs) do
      {:ok, %__MODULE__{beacon_key: beacon_key, seq: seq, bulbs: bulbs, groups: groups}}
    end
  end

  def decode(_other), do: {:error, :not_a_map}

  @doc "Like `decode/1` but raises on error."
  @spec decode!(binary() | map() | t()) :: t()
  def decode!(input) do
    case decode(input) do
      {:ok, inv} -> inv
      {:error, reason} -> raise ArgumentError, "bad inventory: #{inspect(reason)}"
    end
  end

  @doc "Encodes an inventory back to a JSON-friendly string-keyed map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{beacon_key: bk, seq: seq, bulbs: bulbs, groups: groups}) do
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

  @doc """
  Whether `key` is a usable Tuya key string: 32 hex chars, or 16
  printable ASCII chars (what `Crypto.parse_key/1` accepts, minus raw
  binaries that can't come from a dump).
  """
  @spec valid_key?(term()) :: boolean()
  def valid_key?(key) when is_binary(key) and byte_size(key) == 32,
    do: Crypto.parse_key(key) != :error

  def valid_key?(<<_::binary-size(16)>> = key),
    do: key |> :binary.bin_to_list() |> Enum.all?(&(&1 in 0x20..0x7E))

  def valid_key?(_key), do: false

  defp fetch_mesh_key(map) do
    case first(map, [:beaconKey, :beacon_key]) do
      nil -> {:error, :missing_beacon_key}
      value -> if valid_key?(value), do: {:ok, value}, else: {:error, :bad_beacon_key}
    end
  end

  defp fetch_seq(map) do
    case first(map, [:seq, :seq_reserved]) do
      nil -> {:ok, 0}
      n when is_integer(n) and n >= 0 and n <= 65_535 -> {:ok, n}
      _other -> {:error, :bad_seq}
    end
  end

  defp fetch_bulbs(map, mesh_key) do
    case first(map, [:bulbs, :lights]) || [] do
      [_ | _] = raw -> decode_bulbs(raw, mesh_key)
      _ -> {:error, :no_bulbs}
    end
  end

  defp decode_bulbs(raw, mesh_key) do
    raw
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn row, {:ok, acc, seen} ->
      with {:ok, bulb} <- decode_bulb(row, mesh_key),
           :ok <- check_unique(bulb, seen) do
        {:cont, {:ok, [bulb | acc], remember(seen, bulb)}}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, bulbs, _seen} -> {:ok, Enum.reverse(bulbs)}
      {:error, _} = err -> err
    end
  end

  defp remember(seen, bulb) do
    seen
    |> MapSet.put({:mac, bulb.mac})
    |> MapSet.put({:node, bulb.node_id})
    |> then(&if(bulb.label, do: MapSet.put(&1, {:label, bulb.label}), else: &1))
  end

  defp check_unique(bulb, seen) do
    cond do
      MapSet.member?(seen, {:mac, bulb.mac}) ->
        {:error, {:duplicate_mac, bulb.mac}}

      MapSet.member?(seen, {:node, bulb.node_id}) ->
        {:error, {:duplicate_node_id, bulb.node_id, bulb.mac}}

      bulb.label != nil and MapSet.member?(seen, {:label, bulb.label}) ->
        {:error, {:duplicate_label, bulb.label}}

      true ->
        :ok
    end
  end

  defp decode_bulb(row, mesh_key) when is_map(row) do
    with {:ok, mac} <- fetch_mac(row),
         {:ok, local_key} <- fetch_local_key(row, mac),
         {:ok, node_id} <- fetch_node_id(row, mac),
         {:ok, beacon_key} <- fetch_bulb_beacon_key(row, mac, mesh_key) do
      label = first(row, [:label, :name])

      {:ok,
       %Bulb{
         mac: mac,
         local_key: local_key,
         node_id: node_id,
         label: if(is_binary(label), do: label, else: nil),
         beacon_key: beacon_key
       }}
    end
  end

  defp decode_bulb(_row, _mesh_key), do: {:error, :bad_bulb}

  defp fetch_mac(row) do
    case normalize_mac(first(row, [:mac, :MAC])) do
      {:ok, mac} -> {:ok, mac}
      :error -> {:error, :bad_mac}
    end
  end

  defp fetch_local_key(row, mac) do
    case first(row, [:localKey, :local_key]) do
      nil -> {:error, {:missing_local_key, mac}}
      value -> if valid_key?(value), do: {:ok, value}, else: {:error, {:bad_local_key, mac}}
    end
  end

  defp fetch_bulb_beacon_key(row, mac, mesh_key) do
    case first(row, [:beaconKey, :beacon_key]) do
      nil -> {:ok, mesh_key}
      value -> if valid_key?(value), do: {:ok, value}, else: {:error, {:bad_bulb_beacon_key, mac}}
    end
  end

  defp fetch_node_id(row, mac) do
    case first(row, [:nodeId, :node_id]) do
      nil -> {:error, {:missing_node_id, mac}}
      n when is_integer(n) -> check_node_id(n, mac)
      bin when is_binary(bin) -> bin |> Integer.parse() |> parsed_node_id(mac)
      _other -> {:error, {:bad_node_id, mac}}
    end
  end

  defp parsed_node_id({n, ""}, mac), do: check_node_id(n, mac)
  defp parsed_node_id(_parsed, mac), do: {:error, {:bad_node_id, mac}}

  defp check_node_id(n, _mac) when n in 0..@max_node_id, do: {:ok, n}
  defp check_node_id(_n, mac), do: {:error, {:bad_node_id, mac}}

  defp fetch_groups(map, bulbs) do
    case first(map, [:groups]) || [] do
      raw when is_list(raw) ->
        known = MapSet.new(Enum.map(bulbs, & &1.mac))
        decode_groups(raw, known)

      _ ->
        {:error, :bad_groups}
    end
  end

  defp decode_groups(raw, known) do
    raw
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn row, {:ok, acc, seen} ->
      with {:ok, group} <- decode_group(row, known),
           :ok <- check_unique_group(group, seen) do
        seen = seen |> MapSet.put({:id, group.local_id}) |> MapSet.put({:name, group.name})
        {:cont, {:ok, [group | acc], seen}}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, groups, _seen} -> {:ok, Enum.reverse(groups)}
      {:error, _} = err -> err
    end
  end

  defp check_unique_group(group, seen) do
    cond do
      MapSet.member?(seen, {:id, group.local_id}) ->
        {:error, {:duplicate_group_id, group.local_id}}

      group.name != nil and MapSet.member?(seen, {:name, group.name}) ->
        {:error, {:duplicate_group_name, group.name}}

      true ->
        :ok
    end
  end

  defp decode_group(row, known) when is_map(row) do
    id = first(row, [:localId, :local_id, :id])
    name = first(row, [:name, :label])
    members = first(row, [:members]) || []

    with true <- is_integer(id) and id in 0..@max_group_id,
         true <- is_list(members),
         {:ok, macs} <- normalize_members(members, known) do
      {:ok, %Group{local_id: id, name: if(is_binary(name), do: name, else: nil), members: macs}}
    else
      false -> {:error, :bad_group}
      {:error, _} = err -> err
    end
  end

  defp decode_group(_row, _known), do: {:error, :bad_group}

  defp normalize_members(members, known) do
    members
    |> Enum.reduce_while({:ok, []}, fn m, {:ok, acc} ->
      case normalize_mac(m) do
        {:ok, mac} ->
          if MapSet.member?(known, mac) do
            {:cont, {:ok, [mac | acc]}}
          else
            {:halt, {:error, {:unknown_group_member, mac}}}
          end

        :error ->
          {:halt, {:error, {:bad_group_member, m}}}
      end
    end)
    |> case do
      {:ok, macs} -> {:ok, macs |> Enum.reverse() |> Enum.uniq()}
      {:error, _} = err -> err
    end
  end

  defp normalize_mac(mac) when is_binary(mac) do
    hex = mac |> String.replace(~r/[^0-9A-Fa-f]/, "") |> String.upcase()
    if byte_size(hex) == 12, do: {:ok, hex}, else: :error
  end

  defp normalize_mac(_), do: :error

  # Field names are atoms here; JSON input has them as strings.
  defp first(map, keys) do
    Enum.find_value(keys, fn key -> Map.get(map, Atom.to_string(key)) || Map.get(map, key) end)
  end
end
