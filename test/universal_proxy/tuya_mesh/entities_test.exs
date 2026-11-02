defmodule UniversalProxy.TuyaMesh.EntitiesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Espex.DeviceConfig.Device
  alias Espex.Proto
  alias UniversalProxy.ESPHome.EntityProvider
  alias UniversalProxy.TuyaMesh.Entities

  @mac1 "DC23530FB34A"
  @mac2 "DC23533FCD62"
  @settings %{min_mireds: 154, max_mireds: 370, invert: false}

  # Two MACs whose light object ids share a crc32 (found by search).
  @colliding_a "BE9BA0D5BCDC"
  @colliding_b "536A4A2C1805"

  defp summary(overrides \\ %{}) do
    Map.merge(
      %{
        bulbs: [%{mac: @mac1, label: "path light 2"}, %{mac: @mac2, label: nil}],
        groups: [%{local_id: 1, name: "path and post"}],
        device_ids: %{{:bulb, @mac1} => 1, {:bulb, @mac2} => 2, {:group, 1} => 3}
      },
      overrides
    )
  end

  defp static_keys, do: Enum.map(EntityProvider.specs(), &EntityProvider.key_for(&1.object_id))

  describe "build/3" do
    test "one sub-device per bulb (label, else MAC) and per group, with the Store's ids" do
      assert Entities.build(summary(), @settings).devices == [
               %Device{id: 1, name: "path light 2"},
               %Device{id: 2, name: "DC:23:53:3F:CD:62"},
               %Device{id: 3, name: "path and post"}
             ]
    end

    test "an unnamed group is named after its id" do
      build = Entities.build(summary(%{groups: [%{local_id: 1, name: nil}]}), @settings)
      assert List.last(build.devices) == %Device{id: 3, name: "Group 1"}
    end

    test "static entity names and the object id scheme; keys are crc32(object_id)" do
      build = Entities.build(summary(), @settings)

      assert Enum.map(build.entities, &{&1.object_id, &1.type, &1.name, &1.device_id}) == [
               {"tuya_dc23530fb34a_light", :light, "Light", 1},
               {"tuya_dc23530fb34a_connectivity", :binary_sensor, "Connectivity", 1},
               {"tuya_dc23530fb34a_last_seen", :text_sensor, "Last seen", 1},
               {"tuya_dc23533fcd62_light", :light, "Light", 2},
               {"tuya_dc23533fcd62_connectivity", :binary_sensor, "Connectivity", 2},
               {"tuya_dc23533fcd62_last_seen", :text_sensor, "Last seen", 2},
               {"tuya_group_1_light", :light, "Light", 3}
             ]

      for e <- build.entities, do: assert(e.key == :erlang.crc32(e.object_id))

      assert build.keys[Entities.key_for("tuya_dc23530fb34a_light")] ==
               {:bulb, @mac1, :light}

      assert build.keys[Entities.key_for("tuya_group_1_light")] == {:group, 1, :light}
    end

    test "a rename changes only the sub-device name, never an entity's identity" do
      before = Entities.build(summary(), @settings)

      renamed =
        Entities.build(
          summary(%{
            bulbs: [%{mac: @mac1, label: "renamed"}, %{mac: @mac2, label: nil}],
            groups: [%{local_id: 1, name: "also renamed"}]
          }),
          @settings
        )

      assert renamed.entities == before.entities
      assert renamed.keys == before.keys
      refute renamed.devices == before.devices
    end

    test "ids and keys are stable across builds and independent of order" do
      a = Entities.build(summary(), @settings)
      b = Entities.build(summary(%{bulbs: Enum.reverse(summary().bulbs)}), @settings)

      assert a.keys == b.keys
      assert Enum.sort(a.devices) == Enum.sort(b.devices)
    end

    test "a bulb or group without a sub-device id is left out" do
      log =
        capture_log(fn ->
          build = Entities.build(summary(%{device_ids: %{{:bulb, @mac1} => 1}}), @settings)
          assert build.devices == [%Device{id: 1, name: "path light 2"}]
          assert Enum.all?(build.entities, &(&1.device_id == 1))
        end)

      assert log =~ "no sub-device id"
    end

    test "a duplicate or zero sub-device id is never advertised" do
      capture_log(fn ->
        build =
          Entities.build(
            summary(%{device_ids: %{{:bulb, @mac1} => 1, {:bulb, @mac2} => 1, {:group, 1} => 0}}),
            @settings
          )

        assert build.devices == [%Device{id: 1, name: "path light 2"}]
      end)
    end

    test "no mesh builds nothing" do
      assert %{devices: [], entities: [], keys: keys} = Entities.build(nil, @settings)
      assert keys == %{}
    end
  end

  describe "key collisions" do
    setup do
      bulbs = [%{mac: @colliding_a, label: "a"}, %{mac: @colliding_b, label: "b"}]
      ids = %{{:bulb, @colliding_a} => 1, {:bulb, @colliding_b} => 2}
      %{summary: %{bulbs: bulbs, groups: [], device_ids: ids}}
    end

    test "the fixture really collides" do
      assert Entities.key_for("tuya_be9ba0d5bcdc_light") ==
               Entities.key_for("tuya_536a4a2c1805_light")
    end

    test "between mesh entities: raises with on_collision: :raise", %{summary: summary} do
      assert_raise ArgumentError, ~r/tuya_536a4a2c1805_light.*collides/, fn ->
        Entities.build(summary, @settings, on_collision: :raise)
      end
    end

    test "between mesh entities: logs and leaves the later one out with :skip",
         %{summary: summary} do
      log =
        capture_log(fn ->
          build = Entities.build(summary, @settings, on_collision: :skip)
          ids = Enum.map(build.entities, & &1.object_id)
          # CRC32 is linear: equal-length object ids that collide keep
          # colliding under a shared suffix, so all three of b's do.
          assert ids == ~w(tuya_be9ba0d5bcdc_light tuya_be9ba0d5bcdc_connectivity
                           tuya_be9ba0d5bcdc_last_seen)
          assert length(build.devices) == 2
        end)

      assert log =~ "collides"
    end

    test "with the static entities (reserved keys)" do
      reserved = [Entities.key_for("tuya_dc23530fb34a_light")]

      assert_raise ArgumentError, fn ->
        Entities.build(summary(), @settings, reserved_keys: reserved, on_collision: :raise)
      end

      capture_log(fn ->
        build = Entities.build(summary(), @settings, reserved_keys: reserved)
        refute Map.has_key?(build.keys, hd(reserved))
      end)
    end

    test "the scheme doesn't collide with today's static entities" do
      build =
        Entities.build(summary(), @settings, reserved_keys: static_keys(), on_collision: :raise)

      assert length(build.entities) == 7
    end
  end

  describe "advertisements/1" do
    test "lights: color temperature or RGB, mireds from the settings, on their sub-device" do
      ads = Entities.advertisements(Entities.build(summary(), %{@settings | max_mireds: 400}))
      lights = Enum.filter(ads, &match?(%Proto.ListEntitiesLightResponse{}, &1))

      assert length(lights) == 3

      for light <- lights do
        assert light.supported_color_modes == [
                 :COLOR_MODE_COLOR_TEMPERATURE,
                 :COLOR_MODE_RGB
               ]

        assert light.min_mireds == 154.0
        assert light.max_mireds == 400.0
        assert light.name == "Light"
        assert light.device_id in [1, 2, 3]
        assert light.key == :erlang.crc32(light.object_id)
      end
    end

    test "connectivity binary sensor and timestamp text sensor per bulb" do
      ads = Entities.advertisements(Entities.build(summary(), @settings))

      assert [c1, c2] = Enum.filter(ads, &match?(%Proto.ListEntitiesBinarySensorResponse{}, &1))
      assert %{name: "Connectivity", device_class: "connectivity", device_id: 1} = c1
      assert %{device_id: 2} = c2

      assert [t1, _t2] = Enum.filter(ads, &match?(%Proto.ListEntitiesTextSensorResponse{}, &1))
      assert %{name: "Last seen", device_class: "timestamp", device_id: 1} = t1
      assert t1.entity_category == :ENTITY_CATEGORY_DIAGNOSTIC
    end

    test "every advertisement encodes" do
      for ad <- Entities.advertisements(Entities.build(summary(), @settings)),
          do: assert(is_binary(Protobuf.encode(ad)))
    end
  end

  describe "state_responses/2" do
    test "connectivity from reachable, last seen as ISO 8601 or missing; lights stay unknown" do
      build = Entities.build(summary(), @settings)
      seen = ~U[2026-11-02 12:34:56.789Z]

      live = %{
        @mac1 => %{reachable: true, last_seen: seen},
        @mac2 => %{reachable: false, last_seen: nil}
      }

      responses = Entities.state_responses(build, live)
      refute Enum.any?(responses, &match?(%Proto.LightStateResponse{}, &1))

      by_key = Map.new(responses, &{&1.key, &1})

      assert %Proto.BinarySensorStateResponse{state: true, device_id: 1} =
               by_key[Entities.key_for("tuya_dc23530fb34a_connectivity")]

      assert %Proto.BinarySensorStateResponse{state: false, device_id: 2} =
               by_key[Entities.key_for("tuya_dc23533fcd62_connectivity")]

      assert %Proto.TextSensorStateResponse{
               state: "2026-11-02T12:34:56+00:00",
               missing_state: false,
               device_id: 1
             } = by_key[Entities.key_for("tuya_dc23530fb34a_last_seen")]

      assert %Proto.TextSensorStateResponse{state: "", missing_state: true, device_id: 2} =
               by_key[Entities.key_for("tuya_dc23533fcd62_last_seen")]
    end

    test "a bulb with no live values is not connected and never seen" do
      responses = Entities.state_responses(Entities.build(summary(), @settings), %{})
      assert Enum.all?(responses, &(Map.get(&1, :state) in [false, ""]))
    end

    test "live values from a Resolver status" do
      status = %{
        bulbs: [
          %{mac: @mac1, label: "x", node_id: 2, last_seen: nil, reachable: true, checking: false}
        ],
        groups: []
      }

      assert Entities.live_from_status(status) == %{
               @mac1 => %{reachable: true, last_seen: nil}
             }

      assert Entities.live_from_status(:nonsense) == %{}
    end
  end

  describe "read/2" do
    defp sources(overrides) do
      Map.merge(
        %{
          supported?: true,
          role: fn -> {:ok, "AA:BB:CC:DD:EE:FF"} end,
          inventory: fn -> {:ok, summary()} end,
          settings: fn -> @settings end
        },
        overrides
      )
    end

    test "builds from the Store with a mesh role" do
      assert {:ok, %{devices: [_, _, _]}} = Entities.read(sources(%{}))
    end

    test "no role or no Bluetooth: no mesh" do
      assert {:ok, %{devices: []}} = Entities.read(sources(%{role: fn -> {:ok, nil} end}))
      assert {:ok, %{devices: []}} = Entities.read(sources(%{supported?: false}))
    end

    test "unreadable inputs are unknown, not empty" do
      assert :unknown = Entities.read(sources(%{role: fn -> {:error, :unavailable} end}))
      assert :unknown = Entities.read(sources(%{inventory: fn -> {:error, :unavailable} end}))

      assert :unknown =
               Entities.read(sources(%{inventory: fn -> {:error, :invalid_inventory} end}))

      assert :unknown = Entities.read(sources(%{inventory: fn -> exit(:noproc) end}))
      assert :unknown = Entities.read(sources(%{inventory: fn -> raise "boom" end}))
    end

    test "unreadable settings fall back to the defaults" do
      assert {:ok, %{settings: settings}} =
               Entities.read(sources(%{settings: fn -> exit(:x) end}))

      assert settings == UniversalProxy.TuyaMesh.Store.default_settings()
    end

    test "devices/1 is [] when unknown" do
      assert Entities.devices(sources(%{inventory: fn -> {:error, :unavailable} end})) == []
      assert length(Entities.devices(sources(%{}))) == 3
    end

    test "on this host (no Bluetooth) the defaults give no devices" do
      assert Entities.devices() == []
    end
  end

  describe "redaction" do
    test "nothing built carries key material" do
      keys = ["00112233445566778899aabbccddeeff", "abcdefghijklmnop"]
      build = Entities.build(summary(), @settings)

      text =
        inspect(
          {build, Entities.advertisements(build), Entities.state_responses(build, %{})},
          limit: :infinity,
          printable_limit: :infinity
        )

      for key <- keys, do: refute(text =~ key)
      # The build only ever sees the key-free summary fields.
      for e <- build.entities, do: assert(Map.keys(e) |> Enum.sort() == entity_fields())
    end
  end

  defp entity_fields, do: Enum.sort([:object_id, :key, :type, :name, :device_id, :target])
end
