defmodule UniversalProxy.ESPHome.BluetoothProxy do
  @moduledoc """
  `Espex.BluetoothProxy` adapter: bridges Home Assistant's active BLE
  connection + GATT requests to BlueZ via `Bluez.Gatt`.

  All required callbacks are cast-style facades over the Gatt GenServer —
  results flow asynchronously from `Bluez.Gatt` through `gatt_event/2`
  (wired as the Gatt `on_gatt_event:` opt in
  `UniversalProxy.Bluetooth.bluez_spec/0`) to the espex connection-handler
  pid (`subscriber`) captured at `connect/3`. Espex owns cross-client
  address locking and calls `disconnect/1` for every owned address when a
  client's socket closes, so this module holds no state.

  `gatt_event/2` is the espex boundary: it translates the lib-native Gatt
  events (see the `Bluez.Gatt` moduledoc for the contract)
  into `:espex_ble_*` messages, rebuilding `Espex.BluetoothProxy.*` structs
  from the neutral `Bluez.Gatt.*` ones. The match is
  deliberately exhaustive with NO catch-all: an unknown event is a contract
  violation and must crash loudly (in the Gatt server, whose supervisor
  restarts it), never be dropped silently.

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

  alias Bluez.{DevicePath, Gatt}

  # Mirrors Espex.BluetoothProxy.ErrorCodes.generic_error/0 (@moduledoc false).
  @err_generic -1

  @doc """
  Translate a lib-native `Bluez.Gatt` event to its espex
  message and deliver it to the subscriber. Passed to Gatt as the
  `on_gatt_event:` opt (see the moduledoc); runs in the Gatt server.
  """
  @spec gatt_event(pid(), tuple()) :: :ok
  def gatt_event(subscriber, event) do
    send(subscriber, translate(event))
    :ok
  end

  # One clause per Gatt event tag — exhaustive, no catch-all (see moduledoc).
  defp translate({:gatt_connection, address, result}),
    do: {:espex_ble_connection, address, result}

  defp translate({:gatt_service, address, service}),
    do: {:espex_ble_gatt_service, address, espex_service(service)}

  defp translate({:gatt_services_done, address}),
    do: {:espex_ble_gatt_services_done, address}

  defp translate({:gatt_read, address, handle, result}),
    do: {:espex_ble_gatt_read, address, handle, result}

  defp translate({:gatt_write, address, handle, result}),
    do: {:espex_ble_gatt_write, address, handle, result}

  defp translate({:gatt_notify, address, handle, result}),
    do: {:espex_ble_gatt_notify, address, handle, result}

  defp translate({:gatt_notify_data, address, handle, data}),
    do: {:espex_ble_gatt_notify_data, address, handle, data}

  defp translate({:gatt_pair, address, success?, code}),
    do: {:espex_ble_pair, address, success?, code}

  defp translate({:gatt_unpair, address, success?, code}),
    do: {:espex_ble_unpair, address, success?, code}

  defp translate({:gatt_clear_cache, address, success?, code}),
    do: {:espex_ble_clear_cache, address, success?, code}

  defp espex_service(%Gatt.Service{uuid: uuid, handle: handle, characteristics: chars}) do
    %Espex.BluetoothProxy.Service{
      uuid: uuid,
      handle: handle,
      characteristics: Enum.map(chars, &espex_characteristic/1)
    }
  end

  defp espex_characteristic(%Gatt.Characteristic{} = char) do
    %Espex.BluetoothProxy.Characteristic{
      uuid: char.uuid,
      handle: char.handle,
      properties: char.properties,
      descriptors: Enum.map(char.descriptors, &espex_descriptor/1)
    }
  end

  defp espex_descriptor(%Gatt.Descriptor{uuid: uuid, handle: handle}) do
    %Espex.BluetoothProxy.Descriptor{uuid: uuid, handle: handle}
  end

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
