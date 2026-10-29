# Tuya Beacon Mesh extraction notes (2026-10-29)

Portable stack on this branch: `UniversalProxy.TuyaBeaconMesh.*`.

This is Tuya's **Beacon Mesh** family (Beacon v2 / P2 advert mesh) — not
Tuya GATT "paired BLE", and not Thing Beacon Mesh. Proven on ten garden
Beacon v2 bulbs under a Vagus hot patch; pairing / cloud / vagus-memory
deliberately left behind.

## Drop-in JSON → control

Example: `test/fixtures/tuya_beacon_mesh/example_inventory.json`.

```elixir
{:ok, inv} = UniversalProxy.TuyaBeaconMesh.Inventory.decode(File.read!("dump.json"))

{:ok, _} = UniversalProxy.TuyaBeaconMesh.Radio.start_link(adapter_index: 1)

{:ok, _} =
  UniversalProxy.TuyaBeaconMesh.Lights.start_link(
    inventory: inv,
    on_persist: fn inv -> Settings.put(:tuya_beacon_mesh, Inventory.to_map(inv)) end
  )

UniversalProxy.TuyaBeaconMesh.Lights.set("path light 2", on: true)
```

`Inventory.decode/1` rejects duplicate MACs and duplicate `nodeId`s — the
cloud reuses node ids across re-pairings, and wire reports only carry the
node id, so twins would silently share one status entry.

Persist the inventory whenever `on_persist` fires so the advanced `seq`
survives restarts (never go backwards).

## Hardware-proven protocol facts

These override `docs/protocols/tuya_beacon_mesh.md` where they conflict (that
doc is AI-generated and partly wrong on addressing):

| Fact | Detail |
|---|---|
| Phone source | `0x8001` only. Cloud `sourceId` frames are ignored but still advance SN trackers. |
| Unicast keying | XXTEA = `localKey`, XOR mask = mesh `beaconKey`. |
| Group keying | Destination `FFgg`, both key and mask = `beaconKey` (bulbs never learn a distinct groupKey). |
| Sequence | One per-source SN for the whole mesh; forward window ≥ ~900; never reuse or go backwards. |
| On-air time | ≥ 3 s per unicast frame (scan duty cycle + relays). Hop bits start at 3. |
| Reports | DP reports arrive as subCmd 7 to `8000`/`8001`, decrypted with `beaconKey`. |
| localKey | Rotates on re-pair with a new srand (P1 "static authkey" does **not** carry to P2). |
| Factory reset | 5 consecutive power cycles on one bulb; OTA `reset` also works once keys are known. |

DP ids confirmed on these bulbs (AK80x set): 1 on/off, 2 mode, 3 brightness
10..1000, 4 temp 0..1000, 11 HSV raw `<<h::16, s, v>>`.

## Radio ownership in Universal Proxy

Beacon Mesh needs a **dedicated** Bluetooth adapter index, shared with nothing.
Do not use `Bluez.Client` (singleton bound to the ESPHome scanner's adapter).
`Radio` already opens discovery with `DuplicateData: true` on `/org/bluez/hciN`
via injectable `Bluez.Rebus` / `Bluez.DBus` / `Bluez.AdvertReceiver` /
`Bluez.Radio` / `Bluez.Mgmt`. `main` must be on bluez ≥ 0.4.0.

`Bluez.Radio` and `Bluez.Mgmt` are shared infrastructure: the host must
supervise them; `Radio` never starts or links them. Until they (and the
adapter, lease and D-Bus) are available, and again after any runtime loss,
`Radio` stays up as not-ready (`status/1` → `ready: false, last_error: …`,
`send_frame/3` → `{:error, :not_ready}`) and retries setup with a 2 s → 30 s
backoff. `Lights` resubscribes to a restarted `Radio` by name.

## What's here vs left out

| Included | Left out |
|---|---|
| Crypto, Dp, P2, Carrier, Control | Cloud / Cloud.Sign / Pairing |
| Inventory (JSON), Seq | vagus-memory Store |
| Radio GenServer (injectable Bluez) | MQTT / HA discovery (host wiring) |
| Lights GenServer (set/ping/reset/group_set + reports) | Full group create/dismiss persistence UI |

Extra group radio helpers still live on `P2` / `Control` if the host wants
them; Lights can grow to call them without new protocol code.

## Source

Prototyped under the Vagus `tuya-ble-bulbs` task. Fixtures: reference
vectors + live P2 capture 2026-10-25 + example inventory JSON.
