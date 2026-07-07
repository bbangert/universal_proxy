defmodule UniversalProxy.Bluez.Gatt.Characteristic do
  @moduledoc """
  A GATT characteristic within a `UniversalProxy.Bluez.Gatt.Service`.

  `handle` is the *value* handle (declaration + 1 — the bleak convention,
  see `UniversalProxy.Bluez.GattTree`); `properties` is the Core-spec
  characteristic-properties bitmask built by
  `UniversalProxy.Bluez.GattTree.properties_mask/1`.
  """

  alias UniversalProxy.Bluez.Gatt.{Descriptor, Service}

  @type t :: %__MODULE__{
          uuid: Service.uuid(),
          handle: non_neg_integer(),
          properties: non_neg_integer(),
          descriptors: [Descriptor.t()]
        }

  @enforce_keys [:uuid, :handle]
  defstruct [:uuid, :handle, properties: 0, descriptors: []]
end
