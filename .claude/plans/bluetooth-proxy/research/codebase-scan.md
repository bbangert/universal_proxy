# Codebase Scan — Bluetooth Proxy Integration Surface

Scan of `/workspaces/universal_proxy` and the vendored `deps/espex` to map
what already exists for ESPHome proxy adapters, and where Bluetooth would
plug in.

## 1. espex adapter behaviour contracts (the templates)

Existing behaviour modules in `deps/espex/lib/espex/`:

| Behaviour | File | Required callbacks |
|-----------|------|--------------------|
| `Espex.SerialProxy` | `serial_proxy.ex` | `list_instances/0`, `open/3`, `write/2`, `close/1` (+ optional `set_modem_pins/3`, `get_modem_pins/1`, `request/2`) |
| `Espex.ZWaveProxy` | `zwave_proxy.ex` | `available?/0`, `home_id/0`, `feature_flags/0`, `subscribe/1`, `unsubscribe/1`, `send_frame/1` |
| `Espex.InfraredProxy` | `infrared_proxy.ex` | `list_entities/0`, `transmit_raw/3`, `subscribe/1`, `unsubscribe/1` |

**No `Espex.BluetoothProxy` behaviour exists.** This is a major upstream
gap — see §3.

## 2. Dispatch wiring

`deps/espex/lib/espex/dispatch.ex` (459 lines) is the single dispatch table
that pattern-matches every incoming protobuf and calls into the configured
adapter. Handlers for serial / IR / Z-Wave are present:

- [dispatch.ex:145-194](deps/espex/lib/espex/dispatch.ex#L145-L194) — `SerialProxy*`
- [dispatch.ex:214-228](deps/espex/lib/espex/dispatch.ex#L214) — `InfraredRFTransmitRawTimingsRequest`
- [dispatch.ex:236-266](deps/espex/lib/espex/dispatch.ex#L236-L266) — `ZWaveProxyRequest` / `ZWaveProxyFrame`

**Bluetooth dispatch is absent.** The protobuf messages
(`SubscribeBluetoothLEAdvertisementsRequest`, `BluetoothDeviceRequest`,
`BluetoothGATTGetServicesRequest`, `BluetoothGATTReadRequest`,
`BluetoothGATTWriteRequest`, `BluetoothGATTReadDescriptorRequest`,
`BluetoothGATTWriteDescriptorRequest`, `BluetoothGATTNotifyRequest`,
`SubscribeBluetoothConnectionsFreeRequest`,
`UnsubscribeBluetoothLEAdvertisementsRequest`,
`BluetoothScannerSetModeRequest`,
`BluetoothSetConnectionParamsRequest`) decode cleanly because
`message_types.ex` registers them, but **no handle_request/2 clause exists
for any of them** — they will fall through to the catch-all and be ignored.

`device_config.ex` and `device_config/device.ex` have no
`bluetooth_proxy_feature_flags` or `bluetooth_mac_address` fields wired
into `DeviceInfoResponse` construction.

## 3. The "upstream espex" gap

Work that has to happen **in espex itself**, not in this project:

1. New `Espex.BluetoothProxy` behaviour module (callbacks: see §6).
2. ~12 new dispatch clauses in `dispatch.ex` for the BT* requests.
3. New per-connection state: subscriber registration for advert stream,
   GATT request correlation (each GATT op has a request id the client
   uses to match the response).
4. `DeviceConfig` extension to plumb `bluetooth_proxy_feature_flags` and
   `bluetooth_mac_address` into `DeviceInfoResponse`.
5. Outbound message templates for `BluetoothLERawAdvertisementsResponse`
   (batched), `BluetoothDeviceConnectionResponse`,
   `BluetoothDevicePairingResponse`, `BluetoothGATTServicesResponse`,
   `BluetoothGATTReadResponse`, `BluetoothGATTWriteResponse`,
   `BluetoothGATTNotifyDataResponse`, `BluetoothConnectionsFreeResponse`,
   `BluetoothScannerStateResponse`.
6. Encryption/auth re-check — bluetooth_mac_address is `(force) = true`
   in the proto, so the field is always serialized — confirm Noise/plain
   transport handles it.

**This is roughly comparable in size to the existing Z-Wave proxy
implementation in espex.** If we don't want to wait on upstream, we may
need to fork espex or contribute these modules ourselves.

## 4. Existing supervisor pattern to extend

`lib/universal_proxy/esphome/supervisor.ex` uses `:rest_for_one`:

```elixir
children = [
  {ZWaveProxy, port_path: zwave_port_path},
  Infrared.Supervisor,
  {Espex,
   device_config: device_config,
   serial_proxy: SerialProxy,
   zwave_proxy: ZWaveProxy,
   infrared_proxy: Infrared.Server,
   mdns: Espex.Mdns.MdnsLite}
]
```

The BT proxy slots in between `Infrared.Supervisor` and `Espex`:

```elixir
{Bluetooth.Supervisor, transport: bt_transport_opts},
{Espex, ..., bluetooth_proxy: Bluetooth.Server}
```

`:rest_for_one` means a BT crash takes down Espex but not the upstream
ZWave/IR adapters — same blast radius we already accept.

## 5. ConfigStore / DETS persistence pattern

`lib/universal_proxy/esphome/config_store.ex` is the template:

- DETS file at `/data/esphome_config.dets` on Nerves, `_build/` on host.
- `device_config_opts/0` returns the merged keyword list for `Espex.start_link`.
- `update_config/1` writes to DETS, then triggers `Supervisor.restart/0`.

A new `BluetoothProxy.ConfigStore` (or fields added to the existing one)
would persist: scanner mode (passive/active), allow-list of accepted MAC
addresses (optional — may not need one), connection slot count target,
adapter selection if multiple HCIs are present, max advert batch size.

## 6. Adapter process model — recommended for BT

By analogy with Z-Wave:

| Concern | Z-Wave today | Bluetooth recommendation |
|---------|--------------|--------------------------|
| Process | Singleton GenServer owns UART | Singleton supervisor owns HCI; child processes per active GATT connection |
| Subscription | Single subscriber, monitored | Single advert-stream subscriber per connection; multiple GATT op callers |
| Hardware events | UART byte stream → parser → frame fan-out | HCI events → advertisement decoder OR per-conn handler |
| State recovery | Re-issues `GET_NETWORK_IDS` on init | Re-load vendor firmware + reset HCI on init |

Sketch of `Espex.BluetoothProxy` callbacks (proposed):

```elixir
@callback available?() :: boolean()
@callback mac_address() :: <<_::48>>
@callback feature_flags() :: non_neg_integer()
@callback set_scanner_mode(:passive | :active | :off) :: :ok | {:error, term()}
@callback subscribe_advertisements(pid()) :: :ok
@callback unsubscribe_advertisements(pid()) :: :ok
@callback connections_free() :: {free :: non_neg_integer(), limit :: non_neg_integer()}
@callback connect(addr :: <<_::48>>, address_type :: integer(), opts :: keyword()) ::
            {:ok, conn_handle :: integer()} | {:error, term()}
@callback disconnect(conn_handle :: integer()) :: :ok
@callback get_services(conn_handle :: integer()) ::
            {:ok, [Espex.BluetoothProxy.Service.t()]} | {:error, term()}
@callback gatt_read(conn_handle :: integer(), handle :: integer()) ::
            {:ok, binary()} | {:error, term()}
# Phase 2:
@callback gatt_write(conn_handle, handle, binary(), response :: boolean()) :: :ok | {:error, term()}
@callback gatt_notify(conn_handle, handle, enable :: boolean()) :: :ok | {:error, term()}
@callback gatt_read_descriptor(conn_handle, handle) :: {:ok, binary()} | {:error, term()}
@callback gatt_write_descriptor(conn_handle, handle, binary()) :: :ok | {:error, term()}
@callback set_connection_params(conn_handle, min, max, latency, timeout) :: :ok | {:error, term()}
```

## 7. Hardware classification gap

`lib/universal_proxy/hardware.ex` only enumerates USB tty devices via
`Circuits.UART.enumerate/0` and classifies them by VID/PID. There is **no
detection for onboard BT controllers** — that requires probing
`/dev/serial1` (Pi UART HCI) or a `hci*` netdev, plus checking whether
the vendor firmware blob loaded successfully. New code needed:
`UniversalProxy.Hardware.Bluetooth.detect/0`.

## 8. UI patterns

`lib/universal_proxy_web/` follows a per-proxy LiveView page model:
overview, ZWave, audio, serial. A new `BluetoothLive` page would show:
discovered adverts (in-memory ring buffer), connected devices, slot
usage, scanner mode toggle, feature flags. Pattern is clear.

## 9. Telemetry / logging conventions

Existing adapters use plain `Logger` with no dedicated `:telemetry` events
(`grep -rn ":telemetry" lib/universal_proxy/esphome/` returns nothing
beyond the default Phoenix telemetry). A new BT adapter should match —
no new event taxonomy required at v1.

## 10. Confirmed: no Bluetooth code exists

`grep -rn "blue_heron\|bluetooth\|Bluetooth\|BluetoothLE\|bt_hci" lib/
config/ mix.exs` returns zero hits. Greenfield.

---

## Highest-leverage files to copy and adapt

1. **`lib/universal_proxy/esphome/zwave_proxy.ex`** — closest behavioural
   match: long-lived hardware adapter, single subscriber, restart-safe.
2. **`lib/universal_proxy/esphome/infrared/`** (Supervisor + Server) —
   model for a DynamicSupervisor + per-device child process tree, which
   we'll want for per-GATT-connection processes.
3. **`lib/universal_proxy/esphome/supervisor.ex`** — wiring template.
4. **`lib/universal_proxy/esphome/config_store.ex`** — DETS persistence
   pattern with restart-on-write.
5. **`deps/espex/lib/espex/zwave_proxy.ex`** — behaviour template to
   mirror when authoring `Espex.BluetoothProxy`.
