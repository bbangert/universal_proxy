defmodule UniversalProxy.TuyaBeaconMesh do
  @moduledoc """
  Tuya **Beacon Mesh** (Beacon v2 / P2) — the advert-based mesh protocol
  used by bulbs such as the garden Beacon v2 set.

  This is **not** Tuya's GATT "paired BLE" / Tuya BLE product path, and
  not Thing Beacon Mesh. Name and namespace are deliberate so those are
  not conflated later.

  Portable core extracted from the Vagus garden-bulb prototype.

  ## What is here (ready to use)

    * `UniversalProxy.TuyaBeaconMesh.Crypto` — CRC-8/SMBUS, CRC-16/MODBUS, XXTEA, key rule
    * `UniversalProxy.TuyaBeaconMesh.Dp` — DP TLV encode/decode
    * `UniversalProxy.TuyaBeaconMesh.P2` — 26-byte frame codec + request builders
    * `UniversalProxy.TuyaBeaconMesh.Carrier` — AD type 0x03 advert wrap/unwrap
    * `UniversalProxy.TuyaBeaconMesh.Control` — friendly DPs (`on`/`colour`/…) →
      unicast/group frames, with the hardware-proven source address and
      minimum on-air time

  All of the above are pure (no I/O) and covered by ExUnit against the
  reference vectors plus a live capture from the garden bulbs.

  ## What is deliberately not here

  Pairing, Tuya cloud login, and vagus-memory persistence. The assumed
  path is: user pairs bulbs in the Tuya / Smart Life app, a Python script
  exports MAC / localKey / beaconKey / nodeId / label, and Universal Proxy
  imports that into Settings. See
  `docs/protocols/notes/tuya_beacon_mesh_extraction.md`.

  ## Still to build in Universal Proxy (next session)

    * Settings/import seam for the Python key dump
    * Dedicated-adapter radio (own `hciN`: discovery filter with
      `DuplicateData: true`, AdvertReceiver, Mgmt advertise) — do **not**
      share `Bluez.Client` with the ESPHome scanner
    * GenServer that holds bulb state, owns the mesh SN counter, fans DP
      reports into HA (MQTT discovery), and sends `Control` frames
    * Attribute reports by **MAC** (or a stable import id), never by
      nodeId alone — the cloud reuses node ids across re-pairings

  Hardware lessons that must survive the port are summarised in
  `docs/protocols/notes/tuya_beacon_mesh_extraction.md`. The AI-generated
  `docs/protocols/tuya_beacon_mesh.md` is partly wrong on addressing;
  trust the notes and the working code over the doc.
  """
end
