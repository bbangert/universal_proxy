defmodule UniversalProxy.TuyaMesh.Entities do
  @moduledoc """
  The Home Assistant view of the Tuya mesh: ESPHome sub-devices and the
  entities on them, built from the Store's key-free inventory summary
  (`UniversalProxy.TuyaMesh.Store.inventory_summary/1`), its sub-device ids
  and the mesh settings.

  ## Identity

  Home Assistant's ESPHome unique id is `{mac}/{device_id}/{entity_type}/{name}`,
  so entity names are static and user labels live only on sub-device
  names: a rename changes a device name, never an entity's identity.

    * Every bulb is a sub-device named after its label (its MAC when it has
      none) with a "Light", a "Connectivity" binary sensor and a "Last
      seen" text sensor (`device_class: timestamp`, an ISO 8601 string; a
      float timestamp sensor resolves to about 128 s).
    * Every group is a sub-device named after the group with one "Light".

  Sub-device ids are the Store's persisted ids (allocated on every
  inventory write, never 0 and never reused), never derived here. A bulb or
  group without one is left out with a warning.

  Entity keys are `:erlang.crc32(object_id)` for the object ids
  `tuya_<mac>_light`, `tuya_<mac>_connectivity`, `tuya_<mac>_last_seen` and
  `tuya_group_<gid>_light` (`<mac>` lower-case hex without separators).
  Keys are checked against each other and against `:reserved_keys` (the
  provider's static entities). On a collision `build/3` raises with
  `on_collision: :raise`, or logs and leaves the later entity out with
  `:skip` (the default; the app config `:tuya_entity_collisions` picks it
  for the provider).

  Everything here is pure except `read/2` and `devices/1`, which gather the
  inputs (Bluetooth role, Store) and never raise or exit.
  """

  require Logger

  alias Espex.DeviceConfig.Device
  alias Espex.Proto
  alias UniversalProxy.Bluetooth.Settings, as: BluetoothSettings
  alias UniversalProxy.TuyaMesh.Store

  @color_modes [:COLOR_MODE_COLOR_TEMPERATURE, :COLOR_MODE_RGB]

  @type target ::
          {:bulb, String.t(), :light | :connectivity | :last_seen}
          | {:group, 0..254, :light}

  @type entity :: %{
          object_id: String.t(),
          key: non_neg_integer(),
          type: :light | :binary_sensor | :text_sensor,
          name: String.t(),
          device_id: pos_integer(),
          target: target()
        }

  @type t :: %{
          devices: [Device.t()],
          entities: [entity()],
          keys: %{non_neg_integer() => target()},
          settings: Store.settings()
        }

  @typedoc "Per-bulb live values, by MAC (from the Resolver's status)."
  @type live :: %{
          String.t() => %{reachable: boolean(), last_seen: DateTime.t() | nil}
        }

  @doc "The build with no mesh: no sub-devices, no entities."
  @spec empty() :: t()
  def empty,
    do: %{devices: [], entities: [], keys: %{}, settings: Store.default_settings()}

  @doc """
  Builds the sub-devices and entities. `summary` is a
  `Store.inventory_summary/1` result, or `nil` for no mesh. `opts`:
  `:reserved_keys` (keys already taken, default `[]`) and `:on_collision`
  (`:skip` or `:raise`, see the moduledoc).
  """
  @spec build(Store.inventory_summary() | nil, Store.settings(), keyword()) :: t()
  def build(summary, settings, opts \\ [])

  def build(nil, settings, _opts), do: %{empty() | settings: settings}

  def build(summary, settings, opts) do
    ids = summary.device_ids

    {devices, entities} =
      (Enum.map(summary.bulbs, &bulb_device(&1, ids)) ++
         Enum.map(summary.groups, &group_device(&1, ids)))
      |> Enum.reject(&is_nil/1)
      |> unique_devices()
      |> Enum.unzip()

    entities =
      entities
      |> List.flatten()
      |> check_keys(
        Keyword.get(opts, :reserved_keys, []),
        Keyword.get(opts, :on_collision, :skip)
      )

    %{
      devices: devices,
      entities: entities,
      keys: Map.new(entities, &{&1.key, &1.target}),
      settings: settings
    }
  end

  @doc "The `ListEntities*Response` advertisements of a build."
  @spec advertisements(t()) :: [struct()]
  def advertisements(%{entities: entities, settings: settings}),
    do: Enum.map(entities, &advertisement(&1, settings))

  @doc """
  Initial `*StateResponse`s of a build. Connectivity comes from `live`'s
  `reachable` (off for a bulb it doesn't know), last seen from its
  `last_seen` (`missing_state` when nil). Lights get none: the protocol
  has no unknown light state, so they stay unknown in HA until a real
  state is pushed rather than reading as a false "off".
  """
  @spec state_responses(t(), live()) :: [struct()]
  def state_responses(%{entities: entities}, live) do
    Enum.flat_map(entities, fn entity ->
      case state_response(entity, live) do
        nil -> []
        response -> [response]
      end
    end)
  end

  @doc "Per-bulb live values from a `UniversalProxy.TuyaMesh.status/1` map."
  @spec live_from_status(map()) :: live()
  def live_from_status(%{bulbs: bulbs}) when is_list(bulbs) do
    Map.new(bulbs, fn bulb ->
      {bulb.mac,
       %{reachable: Map.get(bulb, :reachable) == true, last_seen: Map.get(bulb, :last_seen)}}
    end)
  end

  def live_from_status(_status), do: %{}

  @doc "The object id of an entity target."
  @spec object_id(target()) :: String.t()
  def object_id({:bulb, mac, kind}), do: "tuya_#{mac_id(mac)}_#{kind}"
  def object_id({:group, gid, :light}), do: "tuya_group_#{gid}_light"

  @doc "The entity key of an object id."
  @spec key_for(String.t()) :: non_neg_integer()
  def key_for(object_id), do: :erlang.crc32(object_id)

  @doc "An ISO 8601 timestamp with an explicit offset, as HA's timestamp parser wants."
  @spec timestamp(DateTime.t()) :: String.t()
  def timestamp(%DateTime{} = dt) do
    dt
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace_suffix("Z", "+00:00")
  end

  # ── Inputs (impure, never raise) ─────────────────────────────────────

  @doc """
  Reads the inputs and builds: `{:ok, build}`, or `:unknown` when an input
  can't be read (the Bluetooth settings or the Store is down, or the stored
  inventory doesn't validate). Unknown is not "no mesh": a caller holding
  a build keeps it rather than dropping every sub-device from HA.

  No mesh role (or a target without Bluetooth) is `{:ok, empty}`. `sources`
  overrides `:supported?` (boolean), `:role` (`-> {:ok, mac | nil} |
  {:error, term()}`), `:inventory` (`-> Store.inventory_summary/1` result)
  and `:settings` (`-> settings`); `opts` go to `build/3`.
  """
  @spec read(map(), keyword()) :: {:ok, t()} | :unknown
  def read(sources \\ %{}, opts \\ []) do
    sources = Map.merge(default_sources(), sources)

    with true <- sources.supported?,
         {:ok, mac} when is_binary(mac) <- safe(sources.role),
         {:ok, summary} <- safe(sources.inventory) do
      {:ok, build(summary, safe(sources.settings) || Store.default_settings(), opts)}
    else
      false -> {:ok, empty()}
      {:ok, nil} -> {:ok, empty()}
      _unknown -> :unknown
    end
  end

  @doc "The sub-devices `read/2` gives, `[]` when unknown."
  @spec devices(map()) :: [Device.t()]
  def devices(sources \\ %{}) do
    case read(sources) do
      {:ok, build} -> build.devices
      :unknown -> []
    end
  end

  defp default_sources do
    %{
      supported?: UniversalProxy.Bluetooth.supported?(),
      role: &mesh_role/0,
      inventory: &Store.inventory_summary/0,
      settings: &Store.settings/0
    }
  end

  @doc """
  The `:tuya_mesh` role MAC, `{:ok, mac | nil}`, or `{:error, :unavailable}`
  while the Bluetooth settings store is down. Not `Bluetooth.roles/0`, whose
  fallback reads as "no role" and would drop every sub-device from HA.
  """
  @spec mesh_role() :: {:ok, String.t() | nil} | {:error, :unavailable}
  def mesh_role do
    {:ok, BluetoothSettings.tuya_adapter(BluetoothSettings.get())}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp safe(fun) do
    fun.()
  rescue
    e ->
      Logger.debug("TuyaMesh.Entities: input read raised: #{Exception.message(e)}")
      nil
  catch
    :exit, _reason -> nil
  end

  # ── Build ────────────────────────────────────────────────────────────

  defp bulb_device(%{mac: mac} = bulb, ids) do
    with_id(ids, {:bulb, mac}, fn id ->
      {%Device{id: id, name: bulb_name(bulb)},
       [
         entity({:bulb, mac, :light}, :light, "Light", id),
         entity({:bulb, mac, :connectivity}, :binary_sensor, "Connectivity", id),
         entity({:bulb, mac, :last_seen}, :text_sensor, "Last seen", id)
       ]}
    end)
  end

  defp group_device(%{local_id: gid} = group, ids) do
    with_id(ids, {:group, gid}, fn id ->
      {%Device{id: id, name: group_name(group)},
       [entity({:group, gid, :light}, :light, "Light", id)]}
    end)
  end

  defp with_id(ids, device_key, fun) do
    case Map.get(ids, device_key) do
      id when is_integer(id) and id > 0 ->
        fun.(id)

      _missing ->
        Logger.warning("TuyaMesh.Entities: no sub-device id for #{inspect(device_key)}; left out")
        nil
    end
  end

  # Store ids are unique by construction; a duplicate would merge two
  # objects into one HA device, so the later one is left out.
  defp unique_devices(pairs) do
    {kept, _seen} =
      Enum.reduce(pairs, {[], MapSet.new()}, fn {device, _entities} = pair, {kept, seen} ->
        if MapSet.member?(seen, device.id) do
          Logger.error("TuyaMesh.Entities: duplicate sub-device id #{device.id}; left out")
          {kept, seen}
        else
          {[pair | kept], MapSet.put(seen, device.id)}
        end
      end)

    Enum.reverse(kept)
  end

  defp entity(target, type, name, device_id) do
    object_id = object_id(target)

    %{
      object_id: object_id,
      key: key_for(object_id),
      type: type,
      name: name,
      device_id: device_id,
      target: target
    }
  end

  defp check_keys(entities, reserved, mode) when mode in [:skip, :raise] do
    {kept, _taken} =
      Enum.reduce(entities, {[], MapSet.new(reserved)}, fn entity, {kept, taken} ->
        if MapSet.member?(taken, entity.key) do
          collision(entity, mode)
          {kept, taken}
        else
          {[entity | kept], MapSet.put(taken, entity.key)}
        end
      end)

    Enum.reverse(kept)
  end

  defp collision(entity, :raise) do
    raise ArgumentError,
          "TuyaMesh entity key #{entity.key} (#{entity.object_id}) collides with another entity"
  end

  defp collision(entity, :skip) do
    Logger.error(
      "TuyaMesh.Entities: entity key #{entity.key} (#{entity.object_id}) collides with " <>
        "another entity; left out"
    )
  end

  defp bulb_name(%{label: label, mac: mac}) do
    if is_binary(label) and String.trim(label) != "", do: label, else: format_mac(mac)
  end

  defp group_name(%{name: name, local_id: gid}) do
    if is_binary(name) and String.trim(name) != "", do: name, else: "Group #{gid}"
  end

  defp mac_id(mac), do: mac |> String.replace(":", "") |> String.downcase()

  defp format_mac(mac) do
    case mac |> String.replace(":", "") |> String.upcase() do
      <<_::binary-size(12)>> = hex ->
        hex |> String.graphemes() |> Enum.chunk_every(2) |> Enum.map_join(":", &Enum.join/1)

      other ->
        other
    end
  end

  # ── Protos ───────────────────────────────────────────────────────────

  defp advertisement(%{type: :light} = e, settings) do
    %Proto.ListEntitiesLightResponse{
      object_id: e.object_id,
      key: e.key,
      name: e.name,
      device_id: e.device_id,
      supported_color_modes: @color_modes,
      min_mireds: settings.min_mireds * 1.0,
      max_mireds: settings.max_mireds * 1.0,
      entity_category: :ENTITY_CATEGORY_NONE
    }
  end

  defp advertisement(%{type: :binary_sensor} = e, _settings) do
    %Proto.ListEntitiesBinarySensorResponse{
      object_id: e.object_id,
      key: e.key,
      name: e.name,
      device_id: e.device_id,
      device_class: "connectivity",
      entity_category: :ENTITY_CATEGORY_DIAGNOSTIC
    }
  end

  defp advertisement(%{type: :text_sensor} = e, _settings) do
    %Proto.ListEntitiesTextSensorResponse{
      object_id: e.object_id,
      key: e.key,
      name: e.name,
      device_id: e.device_id,
      device_class: "timestamp",
      entity_category: :ENTITY_CATEGORY_DIAGNOSTIC
    }
  end

  defp state_response(%{type: :light}, _live), do: nil

  defp state_response(%{type: :binary_sensor, target: {:bulb, mac, _}} = e, live) do
    %Proto.BinarySensorStateResponse{
      key: e.key,
      device_id: e.device_id,
      state: get_in(live, [mac, :reachable]) == true,
      missing_state: false
    }
  end

  defp state_response(%{type: :text_sensor, target: {:bulb, mac, _}} = e, live) do
    case get_in(live, [mac, :last_seen]) do
      %DateTime{} = dt ->
        %Proto.TextSensorStateResponse{
          key: e.key,
          device_id: e.device_id,
          state: timestamp(dt),
          missing_state: false
        }

      _never ->
        %Proto.TextSensorStateResponse{
          key: e.key,
          device_id: e.device_id,
          state: "",
          missing_state: true
        }
    end
  end
end
