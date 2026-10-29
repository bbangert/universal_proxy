# Tuya Beacon Mesh extraction notes (2026-10-29)

Portable core on this branch: `UniversalProxy.TuyaBeaconMesh.*`.

This is Tuya's **Beacon Mesh** family (Beacon v2 / P2 advert mesh) — not
Tuya GATT "paired BLE", and not Thing Beacon Mesh. Proven on ten garden
Beacon v2 bulbs under a Vagus hot patch; pairing / cloud / vagus-memory
deliberately left behind.

## Import shape (Python → Settings)

Per bulb, the next session needs at least:

```json
{
  "mac": "DC23530FB34A",
  "localKey": "<16-char or 32-hex>",
  "beaconKey": "<32-hex mesh key>",
  "nodeId": 2,
  "label": "path light 2"
}
```

Plus one mesh-level `beaconKey` (same for every bulb on the mesh) and a
persisted monotonic `seq` counter (16-bit, wrap at 65536). Do **not** use the
cloud `sourceId` as a frame source.

Identity for HA entities and report attribution must be the MAC (or a stable
import id). **Never key runtime state by `nodeId` alone** — the Tuya cloud
reallocates node ids on re-pair and will happily hand out a duplicate (seen
live: two bulbs both node 10; reports were credited to the wrong one while
keyed control still worked).

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
Own:

- D-Bus `Adapter1.SetDiscoveryFilter` (LE, `DuplicateData: true`) +
  Start/StopDiscovery on `/org/bluez/hciN` via `Bluez.Rebus`
- `Bluez.AdvertReceiver` with `adapter_index: N`
- `Bluez.Radio` + `Bluez.Mgmt` for TX

`main` must be on bluez ≥ 0.4.0 (already the board version).

## Not extracted (and why)

| Left behind | Reason |
|---|---|
| `Cloud` / `Cloud.Sign` / Pairing | User pairs in the Tuya app; Python dumps keys |
| `Store` (vagus-memory) | UP Settings seam replaces it |
| `Radio` / `Bulbs` GenServers / facade | Host-specific; rewrite against UP conventions (`Task.Supervisor`, `catch :exit`, PubSub) |
| MQTT / HA discovery | Explicit next-session work |

## Source

Prototyped under the Vagus `tuya-ble-bulbs` task
(`…/pairing/dev/lib/vagus/tuya/`, Phases 0–8). Tests here are the pure-module
suite (`crypto_dp`, `p2`, `carrier`) plus `control`; fixtures are the reference
vectors and a live P2 frame capture from 2026-10-25.
