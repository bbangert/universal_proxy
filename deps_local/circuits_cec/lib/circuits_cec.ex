defmodule Circuits.CEC do
  @moduledoc """
  HDMI-CEC on Linux through the kernel CEC API (`/dev/cecN`).

  The ioctls are run by `cec_port`, a small C helper started as an Erlang
  port, which only moves raw kernel structs. Everything else is Elixir:

    * `Circuits.CEC.Struct` - the kernel structs (`cec_msg`,
      `cec_log_addrs`, `cec_event`, `cec_caps`, `cec_connector_info`)
    * `Circuits.CEC.Message` - CEC messages to and from tagged terms
    * `Circuits.CEC.Errno` - errno names
    * `Circuits.CEC.Port` - the helper's frame protocol
    * `Circuits.CEC.Transport` - the transport behaviour, with
      `Circuits.CEC.Transport.Port` (the helper) and
      `Circuits.CEC.Transport.Fake` (tests)

  The kernel needs CEC support for the HDMI driver, for example
  `CONFIG_DRM_VC4_HDMI_CEC=y` on Raspberry Pi with vc4 KMS.
  """

  @doc "True if this build has the `cec_port` helper (Linux targets only)."
  @spec supported?() :: boolean()
  defdelegate supported?, to: Circuits.CEC.Port, as: :available?
end
