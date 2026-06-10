defmodule UniversalProxy.ESPHome.BluetoothScanner do
  @moduledoc """
  `Espex.BluetoothScanner` adapter: bridges the rpi3's passive BLE scan
  (`BlueHeron.Observer`) to Home Assistant through the ESPHome Native API.

  ## Shape — pure module functions over a Registry (no GenServer)

  Unlike `ZWaveProxy`, this adapter holds no state of its own. Espex calls
  `subscribe/1` / `unsubscribe/1` **in the connection-handler's own
  process** (`Espex.Connection` passes `self()`), so registering against a
  duplicate-key `Registry` records exactly the right pid and gets free
  auto-cleanup when that connection dies — `Registry` monitors registered
  processes. Advertisement fan-out is a single `Registry.dispatch/3` called
  inline from the `Observer` callback (`on_advertisement/1`): one ETS read
  plus N non-blocking `send/2`, no extra mailbox hop on the slow miniUART
  hot path.

  The `Registry` and the `Observer` are owned by the `UniversalProxy.Bluetooth`
  subtree (rpi3-only). This module is just the behaviour implementation that
  reads/writes that registry, so it compiles and unit-tests on the host with
  a registry started in the test — `BlueHeron` is an rpi3-only dep and is
  deliberately **not referenced** here (we pattern-match a plain map; a
  `%BlueHeron...Device{}` struct is a map and matches the same).

  ## Passive-only — `set_scanner_mode/1` is deliberately NOT implemented

  This is a passive scanner. `Espex.BluetoothScanner` makes
  `set_scanner_mode/1` optional, and espex only sets the `STATE_AND_MODE`
  (`0x40`) feature bit when the adapter exports it
  (`Espex.Connection` checks `function_exported?/3`). By omitting it we keep
  the advertised flags at `PASSIVE_SCAN | RAW_ADVERTISEMENTS` (`0x21`) and HA
  never sends `BluetoothScannerSetModeRequest`. Active scan / GATT is Phase 1+
  (`Espex.BluetoothProxy`) — out of scope here. `E4` asserts this stays false.

  ## Address byte order — pending hardware verification (plan Decision #5 / F4)

  `device.address` is forwarded as-is. blue_heron parses BD_ADDR as a 48-bit
  integer; HCI delivers it little-endian on the wire while HA expects an
  MSB-first MAC integer. If HA shows reversed MACs on hardware, swap the
  48 bits at the marked point in `on_advertisement/1`.
  """

  @behaviour Espex.BluetoothScanner

  require Logger

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
    # without waiting for a state transition.
    send(pid, {:espex_ble_scanner_state, :running, :passive, :passive})
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

  @doc """
  `BlueHeron.Observer` callback. Maps one advertised device to the espex
  advertisement tuple and fans it out to every subscribed connection.

  Accepts a plain map (the `Observer` passes a
  `BlueHeron.HCI.Event.LEMeta.AdvertisingReport.Device` struct, which is a
  map). Skips entries whose `:raw_data` is `nil` — only the verbatim
  over-the-air AD bytes (the vendored `raw_data` field, see VENDORED.md) can
  be forwarded to HA intact; the re-serialized parsed `:data` would corrupt
  unknown AD types such as BTHome's `0xFCD2`.
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
    # Decision #5 / F4: if HA shows reversed MACs, byte-swap `address` here.
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
