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

  Identity is the MAC: 12 hex digits, optionally as `:`- or `-`-separated
  pairs, any case (stored upper-case, unseparated). Duplicate MACs or duplicate `nodeId`s are rejected —
  the cloud reuses node ids across re-pairings, and report attribution is
  by node id on the wire, so twins silently share one status entry.
  Duplicate labels, group ids and group names are rejected too, since
  they are what callers address bulbs and groups by.

  Every key must be usable as-is (`UniversalProxy.TuyaBeaconMesh.Crypto.parse_key/1`): 32
  hex chars, or 16 printable ASCII chars. Node ids are unicast addresses
  `0..0x7FFF` (`0x8000`/`0x8001` are the phone, `0xFFxx` groups and
  broadcast) and group ids `0..254` (`FF FF` is broadcast). A JSON dump
  may be at most #{64 * 1024} bytes.

  A field that is present is validated as given, whatever its value: a
  `"seq": false` or `"seq": null` is rejected, not read as an absent
  `seq` (which defaults to 0 and would reuse sequence numbers). Only the
  optional `label`/`name`, a bulb's `beaconKey`, `groups` and `members`
  read `null` as absent.

  `decode/1` also takes an already-decoded `t()` and re-validates it, so
  anything that reaches the radio has passed these checks. The structs'
  `Inspect` leaves the keys out.

  Errors identify the offending entry only by validated values (a
  normalised MAC, a node id, a group id) or a position, never by echoing
  input, so they carry no key material even when an entry is malformed.
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
    case fetch(map, [:beaconKey, :beacon_key]) do
      :error -> {:error, :missing_beacon_key}
      {:ok, value} -> if valid_key?(value), do: {:ok, value}, else: {:error, :bad_beacon_key}
    end
  end

  defp fetch_seq(map) do
    case fetch(map, [:seq, :seq_reserved]) do
      :error -> {:ok, 0}
      {:ok, n} when is_integer(n) and n >= 0 and n <= 65_535 -> {:ok, n}
      {:ok, _other} -> {:error, :bad_seq}
    end
  end

  defp fetch_bulbs(map, mesh_key) do
    case fetch(map, [:bulbs, :lights]) do
      {:ok, [_ | _] = raw} -> decode_bulbs(raw, mesh_key)
      {:ok, []} -> {:error, :no_bulbs}
      {:ok, _other} -> {:error, :bad_bulbs}
      :error -> {:error, :no_bulbs}
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
        {:error, {:duplicate_label, bulb.mac}}

      true ->
        :ok
    end
  end

  defp decode_bulb(row, mesh_key) when is_map(row) do
    with {:ok, mac} <- fetch_mac(row),
         {:ok, local_key} <- fetch_local_key(row, mac),
         {:ok, node_id} <- fetch_node_id(row, mac),
         {:ok, beacon_key} <- fetch_bulb_beacon_key(row, mac, mesh_key),
         {:ok, label} <- fetch_name(row, [:label, :name], {:bad_label, mac}) do
      {:ok,
       %Bulb{
         mac: mac,
         local_key: local_key,
         node_id: node_id,
         label: label,
         beacon_key: beacon_key
       }}
    end
  end

  defp decode_bulb(_row, _mesh_key), do: {:error, :bad_bulb}

  defp fetch_mac(row) do
    with {:ok, value} <- fetch(row, [:mac, :MAC]),
         {:ok, mac} <- normalize_mac(value) do
      {:ok, mac}
    else
      :error -> {:error, :bad_mac}
    end
  end

  defp fetch_local_key(row, mac) do
    case fetch(row, [:localKey, :local_key]) do
      :error ->
        {:error, {:missing_local_key, mac}}

      {:ok, value} ->
        if valid_key?(value), do: {:ok, value}, else: {:error, {:bad_local_key, mac}}
    end
  end

  defp fetch_bulb_beacon_key(row, mac, mesh_key) do
    case fetch(row, [:beaconKey, :beacon_key]) do
      :error ->
        {:ok, mesh_key}

      {:ok, nil} ->
        {:ok, mesh_key}

      {:ok, value} ->
        if valid_key?(value), do: {:ok, value}, else: {:error, {:bad_bulb_beacon_key, mac}}
    end
  end

  defp fetch_node_id(row, mac) do
    case fetch(row, [:nodeId, :node_id]) do
      :error -> {:error, {:missing_node_id, mac}}
      {:ok, n} when is_integer(n) -> check_node_id(n, mac)
      {:ok, bin} when is_binary(bin) -> bin |> Integer.parse() |> parsed_node_id(mac)
      {:ok, _other} -> {:error, {:bad_node_id, mac}}
    end
  end

  # An optional display name: absent or null is nil; anything but a
  # string is rejected.
  defp fetch_name(row, keys, error) do
    case fetch(row, keys) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, name} when is_binary(name) -> {:ok, name}
      {:ok, _other} -> {:error, error}
    end
  end

  defp parsed_node_id({n, ""}, mac), do: check_node_id(n, mac)
  defp parsed_node_id(_parsed, mac), do: {:error, {:bad_node_id, mac}}

  defp check_node_id(n, _mac) when n in 0..@max_node_id, do: {:ok, n}
  defp check_node_id(_n, mac), do: {:error, {:bad_node_id, mac}}

  defp fetch_groups(map, bulbs) do
    case fetch(map, [:groups]) do
      {:ok, raw} when is_list(raw) -> decode_groups(raw, MapSet.new(bulbs, & &1.mac))
      {:ok, nil} -> {:ok, []}
      :error -> {:ok, []}
      {:ok, _other} -> {:error, :bad_groups}
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
        {:error, {:duplicate_group_name, group.local_id}}

      true ->
        :ok
    end
  end

  defp decode_group(row, known) when is_map(row) do
    with {:ok, id} when is_integer(id) and id in 0..@max_group_id <-
           fetch(row, [:localId, :local_id, :id]),
         {:ok, name} <- fetch_name(row, [:name, :label], {:bad_group_name, id}),
         {:ok, members} when is_list(members) <- fetch_members(row),
         {:ok, macs} <- normalize_members(members, id, known) do
      {:ok, %Group{local_id: id, name: name, members: macs}}
    else
      {:error, _} = err -> err
      _bad -> {:error, :bad_group}
    end
  end

  defp decode_group(_row, _known), do: {:error, :bad_group}

  defp fetch_members(row) do
    case fetch(row, [:members]) do
      :error -> {:ok, []}
      {:ok, nil} -> {:ok, []}
      found -> found
    end
  end

  # A member that isn't a MAC is reported by its position: it may be
  # anything (a whole bulb object, keys and all).
  defp normalize_members(members, group_id, known) do
    members
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {m, index}, {:ok, acc} ->
      case normalize_mac(m) do
        {:ok, mac} ->
          if MapSet.member?(known, mac) do
            {:cont, {:ok, [mac | acc]}}
          else
            {:halt, {:error, {:unknown_group_member, group_id, mac}}}
          end

        :error ->
          {:halt, {:error, {:bad_group_member, group_id, index}}}
      end
    end)
    |> case do
      {:ok, macs} -> {:ok, macs |> Enum.reverse() |> Enum.uniq()}
      {:error, _} = err -> err
    end
  end

  # Only MAC-shaped input (12 hex digits, optionally `:`/`-` separated
  # pairs): a MAC is what errors report, so it must never be hex pulled
  # out of some other string, such as a key.
  defp normalize_mac(mac) when is_binary(mac) do
    if Regex.match?(~r/\A[0-9A-Fa-f]{2}(?:[:-]?[0-9A-Fa-f]{2}){5}\z/, mac),
      do: {:ok, mac |> String.replace(~r/[:-]/, "") |> String.upcase()},
      else: :error
  end

  defp normalize_mac(_), do: :error

  # The first of `keys` present in `map`, whatever its value (`false` and
  # `nil` included). Field names are atoms here; JSON input has them as
  # strings.
  defp fetch(map, keys) do
    Enum.find_value(keys, :error, fn key ->
      with :error <- Map.fetch(map, Atom.to_string(key)),
           :error <- Map.fetch(map, key),
           do: nil
    end)
  end
end
