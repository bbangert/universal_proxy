# Tuya Beacon Mesh extraction notes (2026-10-29)

Portable stack on this branch: `UniversalProxy.TuyaBeaconMesh.*`.

This is Tuya's **Beacon Mesh** family (Beacon v2 / P2 advert mesh) — not
Tuya GATT "paired BLE", and not Thing Beacon Mesh. Proven on ten Beacon v2
bulbs under a Vagus hot patch; pairing / cloud / vagus-memory deliberately
left behind.

**Tested on one product only:** the Gardenreet RGBCW G4 LED bulb, 12 V
low-voltage bi-pin (ten bulbs, Tuya product id `vd8o60wy`, AK80x DP set).
Other P2 products may differ, in DP ids and timing in particular.

## Drop-in JSON → control

Example: `test/fixtures/tuya_beacon_mesh/example_inventory.json`.

```elixir
{:ok, _} = UniversalProxy.TuyaBeaconMesh.Radio.start_link(adapter_index: 1)

{:ok, _} =
  UniversalProxy.TuyaBeaconMesh.Lights.start_link(
    # Read in init, so a restarted Lights resumes from the persisted seq.
    inventory: fn -> Settings.fetch(:tuya_beacon_mesh) end,
    on_persist: fn inv -> Settings.put(:tuya_beacon_mesh, Inventory.to_map(inv)) end
  )

UniversalProxy.TuyaBeaconMesh.Lights.set("path light 2", on: true)
```

`Inventory.decode/1` rejects duplicate MACs and duplicate `nodeId`s — the
cloud reuses node ids across re-pairings, and wire reports only carry the
node id, so twins would silently share one status entry. It also rejects
keys that aren't 32 hex / 16 printable ASCII chars, reserved node and group
ids, and duplicate labels and group ids or names.

Pass a **loader** as `inventory:`, not the decoded data: a child spec's
data is frozen at supervisor start, so a crash-restart would rewind `seq`
and reuse SNs. `on_persist` must return `:ok` only once the write is
durable; anything else blocks sending (`{:error, :persist_failed}`) until a
later write succeeds. A bad stored inventory makes `Lights` `:ignore` its
start instead of failing boot. Give the `Radio` child `shutdown: 10_000`
(its `child_spec/1` does).

## Hardware-proven protocol facts

`docs/protocols/tuya_beacon_mesh.md` is now authoritative: §4.9 collects
everything the bulbs showed, and §9.1 the radio side. Short list, with
pointers:

- Phone source is `0x8001` only; cloud `sourceId` frames are ignored but
  still advance the bulbs' SN trackers (§4.1, §4.9).
- Unicast keyed localKey/beaconKey; group `FFgg` keyed beaconKey/beaconKey,
  no distinct groupKey (§4.1, §4.9).
- One SN for the whole mesh; bulbs drop anything not ahead of the highest
  they've heard; forward jumps of ~900 accepted; never reuse or go backwards
  (§4.3, §4.9).
- ≥ 3 s on air per frame (§4.7, §4.9).
- Header bits 1–0 are a hop TTL: we send 3, relaying bulbs decrement it
  (§4.2).
- DP reports arrive as subCmd 7 to `8000`/`8001`, keyed beaconKey/beaconKey
  (§4.6, §4.9).
- localKey rotates on re-pair with a new srand (§7.1).
- Factory reset: 5 consecutive power cycles; OTA `reset` also works once
  keys are known (§4.9).

DP ids confirmed on the Gardenreet bulbs only (AK80x set; table in §4.9): 1
on/off, 2 mode, 3 brightness 10..1000, 4 temp 0..1000, 11 HSV raw
`<<h::16, s, v>>`.

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

Prototyped under the Vagus `tuya-ble-bulbs` task. Fixtures: the P2 reference
vectors (`vectors.json`, P2 section only; the cloud-signing vectors stay with
the cloud code that was left out) + live P2 capture 2026-10-25 + example
inventory JSON.
