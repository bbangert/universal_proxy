defmodule UniversalProxy.ESPHome.BluetoothScanner do
  @moduledoc """
  `Espex.BluetoothScanner` adapter: bridges the rpi3's passive BLE scan
  (BlueZ via `Bluez.Client`) to Home Assistant through the
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
  which also starts `Bluez`). This module is just the behaviour
  implementation that reads/writes that registry, so it compiles and
  unit-tests on the host with a registry started in the test. It is
  source-agnostic: `on_advertisement/1` takes a plain map, so the same code
  served the earlier blue_heron `Observer` and now the BlueZ client.

  ## Scanner mode — runtime passive/active switching

  `set_scanner_mode/1` delegates to `Bluez.Client.set_mode/1`,
  which swaps the BlueZ scan strategy at runtime: `:passive` uses an
  AdvertisementMonitor (no scan requests sent), `:active` uses
  `StartDiscovery` (SCAN_RSP data collected — ESP32-proxy parity). On
  success the new mode is broadcast to every subscribed connection as
  `{:espex_ble_scanner_state, :running, mode, mode}` so HA's UI tracks the
  switch on all its connections, not just the requesting one.

  Exporting the optional callback makes espex advertise the `STATE_AND_MODE`
  (`0x40`) bit (`Espex.Connection` checks `function_exported?/3`). The
  Client persists the configured mode (`Bluez.Client.configured_mode/0`),
  so `subscribe/1` reports whatever HA last chose — including across Client
  restarts. When the Client isn't running (host, early boot) `set_mode`'s
  `GenServer.call` exits; that is caught (`catch :exit` — NOT the registry's
  `ArgumentError` raise, a different failure mode) and surfaces as
  `{:error, :unavailable}`.

  ## Address byte order — validated on rpi3 (plan Decision #5 / F4)

  `address` is forwarded as-is: an MSB-first MAC integer (`0xAABBCCDDEEFF`),
  which is what HA expects and espex passes straight through.
  `Bluez.Advert` parses BlueZ's `"AA:BB:CC:DD:EE:FF"` string
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
    mode = Bluez.Client.configured_mode()
    send(self(), {:espex_ble_scanner_state, :running, mode, mode})
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
  @spec set_scanner_mode(:passive | :active) :: :ok | {:error, term()}
  # Runs in the requesting connection-handler process. The Client call blocks
  # until BlueZ actually switched (bounded by Client's set_mode timeout); on
  # success every subscriber — this connection included — learns the new mode.
  def set_scanner_mode(mode) when mode in [:passive, :active] do
    case Bluez.Client.set_mode(mode) do
      :ok ->
        broadcast_state(:running, mode, mode)
        :ok

      {:error, _reason} = error ->
        error
    end
  catch
    # Client not running (host, early boot, BT subtree down) or transition
    # timed out — GenServer.call exits; espex logs the error tuple.
    :exit, _reason -> {:error, :unavailable}
  end

  # Fan a scanner-state change out to every subscribed connection (the same
  # dispatch shape as on_advertisement/1).
  defp broadcast_state(state, mode, configured_mode) do
    Registry.dispatch(@registry, :subscribers, fn entries ->
      Enum.each(entries, fn {pid, _} ->
        send(pid, {:espex_ble_scanner_state, state, mode, configured_mode})
      end)
    end)

    :ok
  rescue
    # Registry not started — nobody to notify.
    ArgumentError -> :ok
  end

  @doc """
  Maps one advertised device to the espex advertisement tuple and fans it out
  to every subscribed connection. Invoked by `Bluez.Client` per
  reconstructed advert.

  Accepts a plain map (`%{address:, rss:, address_type:, raw_data:}`). Skips
  entries whose `:raw_data` is `nil`. `raw_data` is the AD byte structure
  `Bluez.Advert` reconstructs from BlueZ's parsed properties —
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
    # ads/s stat for the web tab — atomic counter bump, no-op when the
    # stats server isn't running.
    UniversalProxy.Bluetooth.Stats.bump_ad()

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
