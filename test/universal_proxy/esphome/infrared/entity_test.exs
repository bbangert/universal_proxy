defmodule UniversalProxy.ESPHome.Infrared.EntityTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.ESPHome.Infrared.Entity
  alias UniversalProxy.Protos

  @base_attrs [
    serial_number: "ABC123",
    port_path: "/dev/ttyACM0",
    product_id: 0xF58B,
    name: "Test IR Device",
    capabilities: [:transmit, :receive],
    worker_module: SomeWorker
  ]

  describe "new/1" do
    test "builds entity with deterministic key from serial number" do
      entity = Entity.new(@base_attrs)

      assert entity.key == :erlang.phash2({"ABC123", "infrared"}, 0xFFFFFFFF)
      assert entity.object_id == "infrared_ABC123"
      assert entity.name == "Test IR Device"
      assert entity.serial_number == "ABC123"
      assert entity.port_path == "/dev/ttyACM0"
      assert entity.product_id == 0xF58B
      assert entity.capabilities == [:transmit, :receive]
      assert entity.worker_module == SomeWorker
    end

    test "same serial number always produces same key" do
      e1 = Entity.new(@base_attrs)
      e2 = Entity.new(Keyword.put(@base_attrs, :name, "Different Name"))

      assert e1.key == e2.key
    end

    test "different serial numbers produce different keys" do
      e1 = Entity.new(@base_attrs)
      e2 = Entity.new(Keyword.put(@base_attrs, :serial_number, "XYZ789"))

      refute e1.key == e2.key
    end

    test "defaults name to 'Infrared' when not provided" do
      attrs = Keyword.delete(@base_attrs, :name)
      entity = Entity.new(attrs)

      assert entity.name == "Infrared"
    end
  end

  describe "can_receive?/1" do
    test "true when capabilities include :receive" do
      entity = Entity.new(@base_attrs)
      assert Entity.can_receive?(entity)
    end

    test "false when capabilities do not include :receive" do
      entity = Entity.new(Keyword.put(@base_attrs, :capabilities, [:transmit]))
      refute Entity.can_receive?(entity)
    end
  end

  describe "can_transmit?/1" do
    test "true when capabilities include :transmit" do
      entity = Entity.new(@base_attrs)
      assert Entity.can_transmit?(entity)
    end

    test "false when capabilities do not include :transmit" do
      entity = Entity.new(Keyword.put(@base_attrs, :capabilities, [:receive]))
      refute Entity.can_transmit?(entity)
    end
  end

  describe "to_list_entities_response/1" do
    test "produces correct protobuf struct" do
      entity = Entity.new(@base_attrs)
      response = Entity.to_list_entities_response(entity)

      assert %Protos.ListEntitiesInfraredResponse{} = response
      assert response.key == entity.key
      assert response.object_id == "infrared_ABC123"
      assert response.name == "Test IR Device"
      assert response.icon == ""
      assert response.disabled_by_default == false
    end

    test "encodes transmit+receive as capability bitfield 0x03" do
      entity = Entity.new(@base_attrs)
      response = Entity.to_list_entities_response(entity)

      assert response.capabilities == 0x03
    end

    test "encodes transmit-only as capability bitfield 0x01" do
      entity = Entity.new(Keyword.put(@base_attrs, :capabilities, [:transmit]))
      response = Entity.to_list_entities_response(entity)

      assert response.capabilities == 0x01
    end

    test "encodes receive-only as capability bitfield 0x02" do
      entity = Entity.new(Keyword.put(@base_attrs, :capabilities, [:receive]))
      response = Entity.to_list_entities_response(entity)

      assert response.capabilities == 0x02
    end
  end
end
