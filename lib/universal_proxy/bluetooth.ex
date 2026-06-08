defmodule UniversalProxy.Bluetooth do
  @moduledoc """
  Phase 0 Bluetooth spike supervisor.

  Starts `BlueHeron.Observer` once the vendored blue_heron supervision
  tree has come up. `blue_heron` registers itself as an OTP application
  (`mod: {BlueHeron.Application, []}`) and brings up Registry / SMP /
  Peripheral / HCI Transport on its own from `:blue_heron, :transport`
  config (see `config/target.exs`). We just need to start a subscriber
  that turns on LE scan and logs incoming adverts.

  Compile-time guarded: returns `:ignore` from `child_spec/1` on host
  and on any Nerves target outside Phase 0 scope, so this module
  doesn't fail the application supervisor on non-Pi targets where
  `:blue_heron` isn't even a dep.

  Phase 0 = `:rpi3` only. Phase 0b will broaden to rpi4/rpi0/rpi0_2
  (rpi4 needs a different device path; rpi0/0_2 share `/dev/ttyS0`
  with rpi3).
  """

  require Logger

  @phase_0_targets [:rpi3]

  if Mix.target() in @phase_0_targets do
    use Supervisor

    def start_link(opts \\ []) do
      Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
    end

    @impl Supervisor
    def init(_opts) do
      children = [
        {BlueHeron.Observer, callback: &log_advertisement/1}
      ]

      Supervisor.init(children, strategy: :one_for_one)
    end

    defp log_advertisement(device) do
      Logger.info("BLE adv: #{inspect(device, pretty: true, limit: :infinity)}")
    end
  else
    @doc false
    def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

    @doc false
    def start_link(_opts), do: :ignore
  end
end
