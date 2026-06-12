defmodule UniversalProxy.ESPHome.BluetoothProxy do
  @moduledoc """
  `Espex.BluetoothProxy` adapter: bridges Home Assistant's active BLE
  connection + GATT requests to BlueZ via `UniversalProxy.Bluez.Gatt`.

  All required callbacks are cast-style facades over the Gatt GenServer —
  results flow asynchronously from `Bluez.Gatt` straight to the espex
  connection-handler pid (`subscriber`) captured at `connect/3`. Espex owns
  cross-client address locking and calls `disconnect/1` for every owned
  address when a client's socket closes, so this module holds no state.

  Wiring this module into `Espex.start_link/1` (see
  `UniversalProxy.ESPHome.Supervisor`) is what makes espex advertise
  `ACTIVE_CONNECTIONS` (0x02) and `REMOTE_CACHING` (0x04) to HA, and the
  exported `pair`/`unpair`/`clear_cache` callbacks add `PAIRING` (0x08)
  and `CACHE_CLEARING` (0x10) — feature-flag parity with ESP32 proxies
  (0x7F). The one optional callback deliberately NOT exported is
  `set_connection_params/2`: org.bluez has no per-connection parameter
  API, so espex auto-answers those requests with "not supported" (no
  feature bit depends on it).

  ## Defensiveness

  Like `UniversalProxy.ESPHome.BluetoothScanner`, every callback guards the
  window where the BT subtree isn't running (non-rpi3 targets never wire
  this module, but early boot / a crashed `Bluez` subtree can race a
  connected client). `GenServer.cast` to a dead name is already a silent
  `:ok`; the one synchronous callback (`connections_free/0`) catches the
  `:exit` and reports zero free slots.

  For `connect/3` a silent drop isn't acceptable — HA would wait out its
  own timeout — so a dead Gatt is reported immediately as a failed
  connection on the subscriber.
  """

  @behaviour Espex.BluetoothProxy

  alias UniversalProxy.Bluez.{DevicePath, Gatt}

  # Mirrors Espex.BluetoothProxy.ErrorCodes.generic_error/0 (@moduledoc false).
  @err_generic -1

  @impl Espex.BluetoothProxy
  def connect(address, opts, subscriber) do
    cond do
      # The wire carries uint64; only 48-bit MACs are real. Refuse here (and
      # again in Gatt, defensively) so crafted addresses never reach the
      # GenServer's DevicePath conversion.
      not DevicePath.valid?(address) ->
        send(subscriber, {:espex_ble_connection, address, {:error, @err_generic}})
        :ok

      is_nil(GenServer.whereis(Gatt)) ->
        send(subscriber, {:espex_ble_connection, address, {:error, @err_generic}})
        :ok

      true ->
        Gatt.connect(address, opts, subscriber)
    end
  end

  @impl Espex.BluetoothProxy
  def disconnect(address), do: Gatt.disconnect(address)

  @impl Espex.BluetoothProxy
  def gatt_get_services(address), do: Gatt.get_services(address)

  @impl Espex.BluetoothProxy
  def gatt_read(address, handle), do: Gatt.read(address, handle)

  @impl Espex.BluetoothProxy
  def gatt_write(address, handle, data, response?),
    do: Gatt.write(address, handle, data, response?)

  @impl Espex.BluetoothProxy
  def gatt_read_descriptor(address, handle), do: Gatt.read_descriptor(address, handle)

  @impl Espex.BluetoothProxy
  def gatt_write_descriptor(address, handle, data),
    do: Gatt.write_descriptor(address, handle, data)

  @impl Espex.BluetoothProxy
  def gatt_notify(address, handle, enable?), do: Gatt.notify(address, handle, enable?)

  # Like the GATT ops above, these only have a reply route (the subscriber
  # captured at connect/3) for addresses with a live connection; Gatt logs
  # and drops them otherwise, and a dead Gatt makes the cast a silent no-op
  # (HA times the request out — same posture as every other cast here).

  @impl Espex.BluetoothProxy
  def pair(address), do: Gatt.pair(address)

  @impl Espex.BluetoothProxy
  def unpair(address), do: Gatt.unpair(address)

  @impl Espex.BluetoothProxy
  def clear_cache(address), do: Gatt.clear_cache(address)

  @impl Espex.BluetoothProxy
  def connections_free do
    Gatt.connections_free()
  catch
    # Gatt not running (BT subtree down). No slots, honest limit.
    :exit, _reason -> {0, Gatt.max_connections()}
  end
end
