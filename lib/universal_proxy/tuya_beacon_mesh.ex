defmodule UniversalProxy.TuyaBeaconMesh do
  @moduledoc """
  Tuya **Beacon Mesh** (Beacon v2 / P2) — the advert-based mesh protocol
  used by bulbs such as the garden Beacon v2 set.

  This is **not** Tuya's GATT "paired BLE" / Tuya BLE product path, and
  not Thing Beacon Mesh. Name and namespace are deliberate so those are
  not conflated later.

  ## Drop-in JSON → control

  1. Decode the key dump: `Inventory.decode/1` (see
     `test/fixtures/tuya_beacon_mesh/example_inventory.json`).
  2. Start `Radio` on a dedicated adapter index (injectable `Bluez.*`).
  3. Start `Lights` with that inventory and radio; pass `on_persist:` to
     write the advanced `seq` (and any group edits) back to Settings.
  4. `Lights.set("path light 2", on: true, mode: :colour, colour: {300, 100, 100})`.

  ## Modules

  Pure:

    * `Crypto`, `Dp`, `P2`, `Carrier` — protocol codec
    * `Control` — friendly DPs → frames (`0x8001` source, ≥3 s on-air)
    * `Inventory` — JSON dump decode / validate (rejects duplicate node ids)
    * `Seq` — monotonic 16-bit SN counter

  Processes:

    * `Radio` — lease, discovery (`DuplicateData: true`), TX queue, RX fan-out
      (Bluez modules injectable; see `FakeBluez` in tests)
    * `Lights` — inventory-backed controller: set/ping/reset/group_set,
      report attribution by node→MAC, seq persistence callback

  Still host work for Universal Proxy: Settings storage of the inventory
  JSON, choosing the dedicated `hciN`, MQTT/HA discovery, and wiring a
  supervisor. Hardware lessons:
  `docs/protocols/notes/tuya_beacon_mesh_extraction.md`.

  Pairing / Tuya cloud login are intentionally absent — the dump is
  assumed to come from a Python script after the user pairs in the app.
  """
end
