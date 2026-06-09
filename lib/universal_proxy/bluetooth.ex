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
        # filter_duplicates: true → controller reports each device once per
        # scan window instead of every beacon, keeping the advert log (and
        # the UART/Logger load) sane in a busy RF environment.
        #
        # scan_params: ~10% duty cycle (window 30ms every 300ms). The
        # vendored default is window=interval=10ms = 100% duty (continuous
        # listening), which fire-hoses every advert over the rpi3 miniUART
        # and keeps the `circuits_uart` receive path hot (~8% of a core).
        # A 10% duty cycle cuts that ~6x (port CPU → ~1.3% of a core, BEAM
        # scheduler util 5.3% → 1%) while still discovering ~80 distinct
        # devices within seconds. Tunable per deployment in Phase 0b.
        {BlueHeron.Observer,
         callback: &log_advertisement/1,
         filter_duplicates: true,
         scan_params: [le_scan_interval: 0x01E0, le_scan_window: 0x0030]}
      ]

      Supervisor.init(children, strategy: :one_for_one)
    end

    # Compact, single-line advert log. The previous
    # `inspect(device, pretty: true, limit: :infinity)` emitted a large
    # multi-line blob per advert, which is heavy to format and floods the
    # log/LiveDashboard. Log just MAC, signed RSSI, and the local name.
    defp log_advertisement(%{address: address, rss: rss, data: data}) do
      Logger.info(
        "BLE adv #{format_mac(address)} rssi=#{signed_rssi(rss)}dBm#{name_suffix(data)}"
      )
    end

    defp format_mac(address) when is_integer(address) do
      address
      |> Integer.to_string(16)
      |> String.pad_leading(12, "0")
      |> String.replace(~r/..(?!$)/, "\\0:")
    end

    # rss arrives as a raw unsigned byte; RSSI is 8-bit two's complement.
    defp signed_rssi(rss) when rss > 127, do: rss - 256
    defp signed_rssi(rss), do: rss

    # AD structures: a local-name element starts with 0x08 (shortened) or
    # 0x09 (complete). Non-binary entries (e.g. manufacturer-data tuples)
    # are skipped.
    defp name_suffix(data) when is_list(data) do
      case Enum.find_value(data, fn
             <<t, rest::binary>> when t in [0x08, 0x09] -> rest
             _ -> nil
           end) do
        nil -> ""
        name -> " name=#{inspect(name)}"
      end
    end

    defp name_suffix(_), do: ""
  else
    @doc false
    def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

    @doc false
    def start_link(_opts), do: :ignore
  end
end
