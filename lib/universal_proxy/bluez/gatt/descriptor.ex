defmodule UniversalProxy.Bluez.Gatt.Descriptor do
  @moduledoc """
  A GATT descriptor within a `UniversalProxy.Bluez.Gatt.Characteristic`.
  `handle` is the descriptor's own attribute handle.
  """

  alias UniversalProxy.Bluez.Gatt.Service

  @type t :: %__MODULE__{
          uuid: Service.uuid(),
          handle: non_neg_integer()
        }

  @enforce_keys [:uuid, :handle]
  defstruct [:uuid, :handle]
end
