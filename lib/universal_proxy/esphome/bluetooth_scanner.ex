defmodule UniversalProxy.ESPHome.BluetoothScanner do
  @moduledoc """
  `Espex.BluetoothScanner` adapter: bridges the rpi3's passive BLE scan
  (BlueZ via `UniversalProxy.Bluez.Client`) to Home Assistant through the
  ESPHome Native API.

  ## Shape — pure module functions over a Registry (no GenServer)

  Unlike `ZWaveProxy`, this adapter holds no state of its own. Espex calls
  `subscribe/1` / `unsubscribe/1` **in the connection-handler's own
  process** (`Espex.Connection` passes `self()`), so registering against a
  duplicate-key `Registry` records exactly the right pid and gets free
  auto-cleanup when that connection dies — `Registry` monitors registered
  processes. Advertisement fan-out is a single `Registry.dispatch/3` called
  inline from `on_advertisement/1` (invoked by the BlueZ client): one ETS read
  plus N non-blocking `send/2`, no extra mailbox hop on the advert hot path.

  The `Registry` is owned by the `UniversalProxy.Bluetooth` subtree (rpi3-only,
  which also starts `UniversalProxy.Bluez`). This module is just the behaviour
  implementation that reads/writes that registry, so it compiles and
  unit-tests on the host with a registry started in the test. It is
  source-agnostic: `on_advertisement/1` takes a plain map, so the same code
  served the earlier blue_heron `Observer` and now the BlueZ client.

  ## Scanner mode — passive-only, but reports STATE_AND_MODE

  The scanner only ever runs passively (the BlueZ client only does LE
  discovery), but `set_scanner_mode/1` IS implemented: `:passive` is a no-op
  `:ok`, `:active` is honestly refused (`{:error, :not_supported}`).
  Exporting the optional callback makes espex advertise the `STATE_AND_MODE`
  (`0x40`) bit (`Espex.Connection` checks `function_exported?/3`), so the
  feature flags are `PASSIVE_SCAN | RAW_ADVERTISEMENTS | STATE_AND_MODE`
  (`0x61`). That is what lets Home Assistant track our
  `{:espex_ble_scanner_state, :running, :passive, :passive}` report and show
  the adapter as **"Auto (passive)"** rather than "No scanning". Active
  *connections* + GATT are Phase 1, served by the separate
  `UniversalProxy.ESPHome.BluetoothProxy` adapter — orthogonal to the
  scanner *mode*, which stays passive-only (we never send scan requests).

  ## Address byte order — validated on rpi3 (plan Decision #5 / F4)

  `address` is forwarded as-is: an MSB-first MAC integer (`0xAABBCCDDEEFF`),
  which is what HA expects and espex passes straight through.
  `UniversalProxy.Bluez.Advert` parses BlueZ's `"AA:BB:CC:DD:EE:FF"` string
  into that form (it matches what blue_heron produced, validated on rpi3
  against HA — no byte-swap needed).
  """

  @behaviour Espex.BluetoothScanner

  # Duplicate-key registry: every subscribed connection-handler pid is one
  # entry under the `:subscribers` key. Owned by `UniversalProxy.Bluetooth`.
  @registry __MODULE__.Registry

  @doc """
  Name of the duplicate-key `Registry` this adapter dispatches over.

  Referenced by `UniversalProxy.Bluetooth` when it starts the registry so
  the name lives in exactly one place.
  """
  @spec registry_name() :: module()
  def registry_name, do: @registry

  @impl Espex.BluetoothScanner
  @spec subscribe(pid()) :: :ok | {:error, :unavailable}
  def subscribe(pid) when is_pid(pid) do
    # Runs in the connection-handler process (espex passes self()), so the
    # Registry calls act on the correct pid and Registry auto-removes it when
    # the connection dies. Unregister-then-register makes subscribe
    # idempotent: a re-SUBSCRIBE on the same connection can't leave two
    # entries under the duplicate key (which would double-deliver adverts).
    Registry.unregister(@registry, :subscribers)
    Registry.register(@registry, :subscribers, nil)

    # Tell HA the scanner is already live so it starts ingesting adverts
    # without waiting for a state transition. espex calls subscribe/1 in the
    # subscriber's own process, so `self() == pid`; and Registry can only
    # register the calling process anyway, so we notify `self()` to keep
    # registration and the initial state acting on the same process. We
    # deliberately do NOT send to an arbitrary `pid` — that would split
    # delivery from registration if the espex invariant were ever violated.
    send(self(), {:espex_ble_scanner_state, :running, :passive, :passive})
    :ok
  rescue
    # An un-started registry raises ArgumentError ("unknown registry: ...")
    # — NOT an exit. Can really only happen on a non-BT target (where espex
    # is never wired to call us) or in the brief early-boot window before the
    # subtree is up; stay defensive regardless.
    ArgumentError -> {:error, :unavailable}
  end

  @impl Espex.BluetoothScanner
  @spec unsubscribe(pid()) :: :ok
  def unsubscribe(pid) when is_pid(pid) do
    Registry.unregister(@registry, :subscribers)
    :ok
  rescue
    # Idempotent: already gone (or registry not started) is success.
    ArgumentError -> :ok
  end

  @impl Espex.BluetoothScanner
  @spec set_scanner_mode(:passive | :active) :: :ok | {:error, :not_supported}
  # Passive-only scanner. This callback exists chiefly to flip on the
  # STATE_AND_MODE feature bit (see moduledoc) so HA shows "Auto (passive)".
  # Accept :passive (already our only mode); refuse :active honestly rather
  # than lie. HA shouldn't request :active — we don't advertise
  # ACTIVE_CONNECTIONS — but we handle it safely if it does.
  def set_scanner_mode(:passive), do: :ok
  def set_scanner_mode(:active), do: {:error, :not_supported}

  @doc """
  Maps one advertised device to the espex advertisement tuple and fans it out
  to every subscribed connection. Invoked by `UniversalProxy.Bluez.Client` per
  reconstructed advert.

  Accepts a plain map (`%{address:, rss:, address_type:, raw_data:}`). Skips
  entries whose `:raw_data` is `nil`. `raw_data` is the AD byte structure
  `UniversalProxy.Bluez.Advert` reconstructs from BlueZ's parsed properties —
  faithful for the manufacturer/service-data elements HA decoders use (e.g.
  BTHome's `0xFCD2`).
  """
  @spec on_advertisement(map()) :: :ok
  def on_advertisement(%{raw_data: nil}), do: :ok

  def on_advertisement(%{
        address: address,
        rss: rss,
        address_type: address_type,
        raw_data: raw_data
      })
      when is_binary(raw_data) do
    # Address byte order validated on rpi3 (F4) — forwarded as-is, no swap.
    rssi = signed_rssi(rss)

    Registry.dispatch(@registry, :subscribers, fn entries ->
      Enum.each(entries, fn {pid, _} ->
        send(pid, {:espex_ble_advertisement, address, rssi, address_type, raw_data})
      end)
    end)

    :ok
  rescue
    # Registry not started raises ArgumentError. Shouldn't happen — the
    # Observer only runs once the subtree (registry included) is up — but
    # never let a fan-out failure crash the Observer's scan loop.
    ArgumentError -> :ok
  end

  def on_advertisement(_other), do: :ok

  # rss arrives as a raw unsigned byte; RSSI is 8-bit two's complement.
  defp signed_rssi(rss) when is_integer(rss) and rss > 127, do: rss - 256
  defp signed_rssi(rss), do: rss
end
