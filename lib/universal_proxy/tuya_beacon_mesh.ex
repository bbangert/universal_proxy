defmodule UniversalProxy.TuyaBeaconMesh do
  @moduledoc """
  Tuya **Beacon Mesh** (Beacon v2 / P2) — the advert-based mesh protocol.
  Hardware-validated on one product only: Gardenreet RGBCW G4 12 V bi-pin
  bulbs (product id `vd8o60wy`); other P2 products may differ.

  This is **not** Tuya's GATT "paired BLE" / Tuya BLE product path, and
  not Thing Beacon Mesh. Name and namespace are deliberate so those are
  not conflated later.

  ## Drop-in JSON → control

  1. The key dump is validated by `Inventory.decode/1` (see
     `test/fixtures/tuya_beacon_mesh/example_inventory.json`).
  2. Start `Radio` on a dedicated adapter index (injectable transport;
     the default Bluez one has injectable `Bluez.*` modules).
  3. Start `Lights` with a loader for the stored inventory (read on every
     start, so a restart resumes from the persisted `seq`) and the radio;
     pass `on_persist:` to write the advanced `seq` back to Settings (and
     optionally `on_tighten:` to hand back an unused lease on a clean stop).
  4. `Lights.set("path light 2", on: true, mode: :colour, colour: {300, 100, 100})`.

  ## Modules

  Pure:

    * `Crypto`, `Dp`, `P2`, `Carrier` — protocol codec
    * `Control` — friendly DPs → frames (`0x8001` source, ≥3 s on-air)
    * `Inventory` — JSON dump decode / validate (rejects duplicate node ids)
    * `Seq` — monotonic 16-bit SN counter with persisted leases

  Processes:

    * `Radio` — TX queue and frame windows, RX fan-out, setup retries and
      wedge detection, over a `Radio.Transport` (default
      `Radio.Transport.Bluez`: lease, discovery with `DuplicateData: true`;
      Bluez modules injectable, see `FakeBluez` in tests)
    * `Lights` — inventory-backed controller: set/ping/reset/group_set,
      report attribution by node→MAC, seq persistence callback

  The host wiring (inventory store, choosing the dedicated `hciN`,
  supervision, upload and status) is `UniversalProxy.TuyaMesh`. Hardware
  behaviour: `docs/protocols/tuya_beacon_mesh.md`
  §4.9; extraction notes: `docs/protocols/notes/tuya_beacon_mesh_extraction.md`.

  Pairing / Tuya cloud login are intentionally absent — the dump is
  assumed to come from a Python script after the user pairs in the app.
  """
end
