defmodule UniversalProxy.ESPHome.Infrared.Entity do
  @moduledoc """
  Product-agnostic struct representing an infrared device exposed as an
  ESPHome entity.

  Any infrared product family (IRDroid, future devices) builds these via
  its own `Device` module. The generic `Infrared.Server` works exclusively
  with `%Entity{}` structs, never touching product-specific details.
  """

  alias UniversalProxy.Protos

  @type capability :: :transmit | :receive
  @type t :: %__MODULE__{
          key: non_neg_integer(),
          object_id: String.t(),
          name: String.t(),
          serial_number: String.t(),
          port_path: String.t(),
          product_id: non_neg_integer(),
          capabilities: [capability()],
          worker_module: module()
        }

  defstruct [
    :key,
    :object_id,
    :name,
    :serial_number,
    :port_path,
    :product_id,
    :capabilities,
    :worker_module
  ]

  @capability_transmit 0x01
  @capability_receive 0x02

  @doc """
  Build an entity from the required fields.

  `key` and `object_id` are derived deterministically from the serial number
  so they remain stable across reboots.
  """
  @spec new(keyword()) :: t()
  def new(attrs) do
    serial = Keyword.fetch!(attrs, :serial_number)

    %__MODULE__{
      key: :erlang.phash2({serial, "infrared"}, 0xFFFFFFFF),
      object_id: "infrared_#{serial}",
      name: Keyword.get(attrs, :name, "Infrared"),
      serial_number: serial,
      port_path: Keyword.fetch!(attrs, :port_path),
      product_id: Keyword.fetch!(attrs, :product_id),
      capabilities: Keyword.fetch!(attrs, :capabilities),
      worker_module: Keyword.fetch!(attrs, :worker_module)
    }
  end

  @doc """
  Convert to the protobuf message sent during `ListEntitiesRequest`.
  """
  @spec to_list_entities_response(t()) :: Protos.ListEntitiesInfraredResponse.t()
  def to_list_entities_response(%__MODULE__{} = entity) do
    %Protos.ListEntitiesInfraredResponse{
      object_id: entity.object_id,
      key: entity.key,
      name: entity.name,
      icon: "",
      disabled_by_default: false,
      entity_category: :ENTITY_CATEGORY_NONE,
      capabilities: capabilities_to_bitfield(entity.capabilities)
    }
  end

  @spec can_receive?(t()) :: boolean()
  def can_receive?(%__MODULE__{capabilities: caps}), do: :receive in caps

  @spec can_transmit?(t()) :: boolean()
  def can_transmit?(%__MODULE__{capabilities: caps}), do: :transmit in caps

  defp capabilities_to_bitfield(caps) do
    Enum.reduce(caps, 0, fn
      :transmit, acc -> Bitwise.bor(acc, @capability_transmit)
      :receive, acc -> Bitwise.bor(acc, @capability_receive)
      _, acc -> acc
    end)
  end
end
