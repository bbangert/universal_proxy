defmodule UniversalProxy.Bluetooth do
  @moduledoc """
  Bluetooth subtree: owns the passive BLE scanner and the subscriber
  registry that feeds advertisements to Home Assistant.

  Two children, started `:rest_for_one` (registry first, Observer second):

    1. a duplicate-key `Registry`
       (`UniversalProxy.ESPHome.BluetoothScanner.registry_name/0`) holding
       every subscribed ESPHome connection-handler pid. Registry-up-before-
       Observer guarantees the Observer callback's `Registry.dispatch` never
       hits a missing table; if the registry crashes, `:rest_for_one`
       restarts the Observer too so it re-dispatches against a live table.
    2. `BlueHeron.Observer` — turns on LE scan and invokes
       `UniversalProxy.ESPHome.BluetoothScanner.on_advertisement/1` per
       advertised device, which fans the raw advert out over the registry.

  `blue_heron` registers itself as an OTP application
  (`mod: {BlueHeron.Application, []}`) and brings up Registry / SMP /
  Peripheral / HCI Transport on its own from `:blue_heron, :transport`
  config (see `config/target.exs`); we only add the scanner driver and the
  HA-facing fan-out registry on top.

  Compile-time guarded: `child_spec/1` returns `:ignore` on host and on any
  Nerves target outside BT scope, so this module is a no-op there (and
  `:blue_heron` isn't even a dep off-target). The advert fan-out adapter
  (`UniversalProxy.ESPHome.BluetoothScanner`) is itself unguarded so it can
  be unit-tested on the host against a registry started in the test.

  BT scope = `:rpi3` only for now. Broadening to rpi4/rpi0/rpi0_2 (rpi4
  needs a different device path; rpi0/0_2 share `/dev/ttyS0` with rpi3) is a
  later step — flip `@bluetooth_targets`.
  """

  require Logger

  alias UniversalProxy.ESPHome.BluetoothScanner

  @bluetooth_targets [:rpi3]

  # Compile-time constant: `Mix.target/0` is unavailable at runtime in a
  # Nerves release, so bake the predicate in. Single source of truth for
  # gating both this subtree and the espex `bluetooth_scanner:` wiring.
  @bluetooth_supported Mix.target() in @bluetooth_targets

  @doc """
  Whether this build targets BT-capable hardware (compile-time constant).

  `UniversalProxy.ESPHome.Supervisor` reads this to decide whether to wire
  the `bluetooth_scanner:` adapter into espex, so `:rpi3` is not hardcoded
  in two places.
  """
  @spec supported?() :: boolean()
  def supported?, do: @bluetooth_supported

  if @bluetooth_supported do
    use Supervisor

    def start_link(opts \\ []) do
      Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
    end

    @impl Supervisor
    def init(_opts) do
      children = [
        # Subscriber registry FIRST so the Observer callback's dispatch
        # always finds a live table. Duplicate keys: N connections fan out
        # under the single `:subscribers` key.
        {Registry, keys: :duplicate, name: BluetoothScanner.registry_name()},

        # filter_duplicates: true → controller reports each device once per
        # scan window instead of every beacon, keeping the UART/dispatch
        # load sane in a busy RF environment.
        #
        # scan_params: ~10% duty cycle (window 30ms every 300ms). The
        # vendored default is window=interval=10ms = 100% duty (continuous
        # listening), which fire-hoses every advert over the rpi3 miniUART
        # and keeps the `circuits_uart` receive path hot (~8% of a core).
        # A 10% duty cycle cuts that ~6x (port CPU → ~1.3% of a core, BEAM
        # scheduler util 5.3% → 1%) while still discovering ~80 distinct
        # devices within seconds. Tunable per deployment.
        {BlueHeron.Observer,
         callback: &BluetoothScanner.on_advertisement/1,
         filter_duplicates: true,
         scan_params: [le_scan_interval: 0x01E0, le_scan_window: 0x0030]}
      ]

      # rest_for_one: registry restart cascades to the Observer (which then
      # re-dispatches against the fresh table); an Observer restart leaves
      # the registry — and its subscribers — untouched.
      Supervisor.init(children, strategy: :rest_for_one)
    end
  else
    @doc false
    def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

    @doc false
    def start_link(_opts), do: :ignore
  end
end
