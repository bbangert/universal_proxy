# Gap Analysis — What's Needed Beyond the Open blue_heron PRs

**Question asked:** assuming the open blue_heron PRs are merged/applied, what
else has to exist to ship Bluetooth proxy → ESPHome → Home Assistant?

**Short answer:** A lot. The open PRs are not on the critical path for a BT
proxy — they're peripheral-mode + Pi 3/4/0W2 hardware bring-up. The proxy
needs the *opposite* role (Central + GATT client), which **blue_heron
explicitly does not implement** today, plus a sizeable chunk of upstream
espex work and the local adapter.

---

## The shape of the work

```
┌──────────────────────────────────────────────────────────────────┐
│  Home Assistant                                                  │
│    ↑ ESPHome Native API (protobuf over TCP)                      │
│    ↑ BluetoothLERawAdvertisementsResponse, BluetoothGATT*Resp    │
└────────────────────┬─────────────────────────────────────────────┘
                     │
┌────────────────────┴─────────────────────────────────────────────┐
│  espex (vendored library, currently 0.1.2)                       │
│    • Protobuf MESSAGES present ✅                                 │
│    • Espex.BluetoothProxy behaviour ❌  <-- GAP 1 (upstream)      │
│    • Dispatch clauses for 12 BT requests ❌  <-- GAP 1            │
│    • DeviceInfoResponse bluetooth fields ❌  <-- GAP 1            │
└────────────────────┬─────────────────────────────────────────────┘
                     │
┌────────────────────┴─────────────────────────────────────────────┐
│  UniversalProxy.ESPHome.BluetoothProxy (new in this project)     │
│    • Adapter GenServer + DynamicSupervisor for connections ❌     │
│    • Connection slot manager ❌                                   │
│    • Advertisement batcher (16-per-batch) ❌                      │
│    • Service-discovery cache (DETS) ❌                            │
│    • LiveView config UI ❌                                        │
└────────────────────┬─────────────────────────────────────────────┘
                     │
┌────────────────────┴─────────────────────────────────────────────┐
│  blue_heron (forked / vendored)                                  │
│    • Peripheral role ✅                                           │
│    • Broadcaster role ✅                                          │
│    • Broadcom firmware load (Pi 3/4/0W2) — needs PRs #138 #139    │
│    • CENTRAL role ❌  <-- GAP 2 (the biggest)                     │
│    • GATT CLIENT ❌  <-- GAP 2                                    │
│    • ACL inbound reassembly — unverified ⚠                       │
│    • Random Private Address resolution ❌ (phase 1 OK without)    │
└──────────────────────────────────────────────────────────────────┘
```

---

## GAP 1 — espex BT proxy support (upstream library)

Roughly comparable in size to the existing Z-Wave proxy implementation in
espex. None of this exists today:

| Item | Notes |
|------|-------|
| `Espex.BluetoothProxy` behaviour module | ~12 callbacks. See proposed signatures in [codebase-scan.md §6](research/codebase-scan.md). |
| 12 `handle_request/2` clauses in `dispatch.ex` | SubscribeBluetoothLE…, BluetoothDeviceRequest, BluetoothGATT* (5), Scanner mode set, ConnectionParams, ConnectionsFree, Unsubscribe |
| Outbound message templates | BluetoothLERawAdvertisementsResponse (batched), DeviceConnection, DevicePairing, GATTServices, GATTRead, GATTWrite, GATTNotifyData, ConnectionsFree, ScannerState |
| Connection-state per-handler GATT request correlation | Each GATT op carries a `request_id` for response matching |
| `DeviceConfig` extension | `bluetooth_proxy_feature_flags` + `bluetooth_mac_address` plumbed into `DeviceInfoResponse` |
| Tests | dispatch-table coverage at the level of existing zwave_proxy tests |

**Path of least resistance:** fork espex into `deps_local/espex/` (same
pattern this project uses for `mdns_lite`) and contribute upstream in
parallel. Don't block on upstream merge.

## GAP 2 — blue_heron Central role + GATT client (the biggest gap)

This is the load-bearing missing piece. blue_heron's README explicitly
disclaims both roles. Open PRs #138-#142 do not move this forward.

**Helpful surprise:** the **HCI command structs already exist** in
`lib/blue_heron/hci/commands/le_controller/` — `create_connection.ex`,
`create_connection_cancel.ex`, `set_scan_parameters.ex`, `set_scan_enable.ex`,
`set_random_address.ex`, etc. So the wire-level primitives are done.
Missing is the higher-level driver + event handling + GATT client.

| Sub-area | What's missing | Approx scope |
|---------|----------------|--------------|
| LE Advertising Report event handler | Parse incoming LE Meta `AdvertisingReport` / `ExtendedAdvertisingReport`, fan out to subscribers | Medium |
| Scan driver | GenServer that owns scan window/interval, toggles enable, multiplexes subscribers | Small |
| LE Connection initiation | Use existing `LECreateConnection` command + handle `LEMeta.EnhancedConnectionComplete` events. State machine for in-flight connects. | Medium |
| Connection registry | Track connection handles, peer addr, MTU per connection, slot count | Medium |
| L2CAP signalling (central side) | Connection parameter update request handling, channel routing | Medium |
| GATT client state machine | Discover services → discover characteristics by service → discover descriptors. Standard ATT request/response sequence | **Large** — comparable to peripheral implementation |
| ATT client requests | `ReadByGroupType` (services), `ReadByType` (characteristics), `FindInformation` (descriptors), `ReadRequest`, `WriteRequest`/`WriteCommand`, `Handle Value Notification` handler | Medium |
| MTU exchange on central side | Mirror of #141's peripheral logic, but as initiator | Small |
| ACL inbound reassembly | Continuation fragments (PB flag) glued back together before ATT decode | Small but easy to miss |
| Disconnect handling + cleanup | `LEDisconnect`, dispose connection registry entry, notify subscribers | Small |

**Phase 0 (MVP) only needs the top three rows** — scan driver + advertising-report handler + subscriber fan-out. Everything else is Phase 1+.

**Estimated effort:** 4–6 weeks of focused work for a competent BLE
implementer to get phase 1 (scan + connect + services + read) reliable.
Phase 2 (write + notify + descriptors) is another 2–3 weeks.

## GAP 3 — local project adapter

Once GAP 1 + GAP 2 are addressed, the project-side adapter is the
smallest piece, but still non-trivial:

| Component | File (proposed) | Effort |
|-----------|----------------|--------|
| Adapter implementing `Espex.BluetoothProxy` | `lib/universal_proxy/esphome/bluetooth_proxy.ex` | M |
| Per-connection process tree | `lib/universal_proxy/esphome/bluetooth/{supervisor,connection}.ex` | M |
| Advertisement ring buffer + batcher | `lib/universal_proxy/esphome/bluetooth/advertisement_batcher.ex` | S |
| Hardware detection | `lib/universal_proxy/hardware/bluetooth.ex` (probe `/dev/serial1`, runtime HCI bring-up status) | S |
| Config schema additions | extend `ESPHome.ConfigStore` with scanner mode, slot count, optional MAC allow-list | XS |
| LiveView UI | `lib/universal_proxy_web/live/bluetooth_live.ex` + components for slot meter, scan log, connected devices | M |
| Telemetry / logger metadata | match existing adapter conventions | XS |

## GAP 4 — Nerves system / firmware concerns

| Item | Notes |
|------|-------|
| `.hcd` firmware blobs | Solved by #139 (bundled in priv/). |
| Pi UART layout | **Already correct on Nerves.** rpi3/rpi0/rpi0_2 use `dtoverlay=miniuart-bt` + `core_freq=250` and expose BT on `/dev/ttyS0`. rpi4 enables UART without an overlay and BT lives on `/dev/ttyAMA0`. No device-tree work needed — what I initially feared as the trickiest non-code step is a non-issue. |
| miniUART baud limit | `/dev/ttyS0` on rpi3/0/0_2 is the slower miniUART (max ~460800 reliably). Fine for BT 4.x, marginal for BT 5 extended adv at full throughput. Pi 4 is unaffected. |
| HCI reset on supervisor restart | Adapter `:rest_for_one` restart must release and re-bring-up the HCI without leaving the chip in a half-initialised state. |
| Wi-Fi coexistence | Combo radio. If WiFi is heavy, BT scan throughput drops. For your testbed (Ethernet), N/A. For users with WiFi-only deployments, worth documenting. |

## GAP 5 — operational concerns

| Item | Notes |
|------|-------|
| Pairing / bonding | ESPHome's `PAIRING` flag implies the proxy handles SMP. blue_heron has SMP code (peripheral side) — needs review for central role. Phase 2 at earliest. |
| Service cache (REMOTE_CACHING) | Speeds up reconnects to known devices. Stash service tree per peer MAC in DETS. Optional for phase 1 but cheap. |
| Resilience to controller wedging | Watchdog that resets the HCI if no events received for N seconds while expected. Common pain point on Broadcom radios. |
| Permissions on `/dev/serial1` | Nerves runs as root by default, but document for non-Nerves derivatives. |

---

## DECISIONS

- **Fork strategy:** vendor `blue_heron` into `deps_local/blue_heron/`
  (mirroring the existing `deps_local/mdns_lite/` pattern). Keep `espex`
  as a hex dep and file BluetoothProxy support as upstream PRs first.
- **Phase 0 (spike):** compile + scan + console log only. No espex /
  ESPHome / HA integration. Done = on a Pi 3 B+, the vendored
  blue_heron with #138/#139 applied brings up the radio at boot and
  logs incoming advertisement reports via Logger.
- **Phase 0b (the previous MVP):** wire to espex via a new
  BluetoothProxy behaviour. HA discovers a BTHome v2 sensor end-to-end.

### Pre-Phase 0 risks (read before starting)

1. **#139 depends on #138.** Cherry-pick in order: `git cherry-pick <138-sha> <139-sha>`. Reverse order will produce conflicts. Alternative: fork from TomHoenderdos's branch directly so both PRs are pre-applied. Recorded in [research/blue-heron-state.md §1](research/blue-heron-state.md) (the PR table) and §8.
2. **#139 is still in draft.** Author's test plan checklist shows `[ ] Hardware test on RPi 4` unchecked. Pi 3 B+ spike doesn't exercise the RPi 4 LMP-subversion mapping (`0x6119`) introduced by #139, so this is **deferred risk** — relevant once Phase 0b moves to rpi4. Re-verify before promoting Phase 0 to rpi4.
3. **brcm_patchram may already be in nerves_system_rpi3.** [research/blue-heron-state.md L72](research/blue-heron-state.md) flags this ambiguity. Before vendoring #139's bundled blobs, check `ls /lib/firmware/brcm/` on a stock nerves_system_rpi3 image. If `BCM43430A1.hcd` is already present, **the spike can succeed with only #138 applied** (`.hcd` parser + vendor HCI commands), and you can defer #139 to Phase 0b or skip it entirely on that target.
4. **Forking risk:** blue_heron upstream has been dormant on the maintainer side for 14 months. Treat `deps_local/blue_heron/` as a long-lived vendored dep, not a temporary shim. Upstream PRs should still be filed (consistent with the [mdns_lite vendored memory note](../../memory/mdns_lite_vendored.md)) but don't budget on merge cadence.

### Phase 0 (spike) — radio bring-up + scan

Smallest possible slice:

1. **Fork blue_heron** to `bbangert/blue_heron`. Cherry-pick **#138 first**, then **#139** (order is required — see Risk 1 above). Vendor as `deps_local/blue_heron/` with `override: true` in mix.exs.
   - **Optimisation:** before applying #139, run the spike on Pi 3 B+ with only #138 applied. If `/lib/firmware/brcm/BCM43430A1.hcd` is already present in nerves_system_rpi3, the spike succeeds without #139 and you can skip the bundled-firmware diff entirely (Risk 3).
2. **Add `BlueHeron.HCI.Event.LEMeta.AdvertisingReport` parser** if not present (verify by inspection — `LEMeta` event modules already exist for ConnectionComplete; AdvertisingReport may need adding).
3. **Add `BlueHeron.Observer` GenServer** — thin module that owns scan params, toggles `LESetScanEnable`, dispatches incoming advertising reports to a subscribed pid (or `Logger.info` for the spike).
4. **Add minimal `UniversalProxy.Bluetooth` boot integration** — starts the blue_heron supervision tree on rpi3 target only, subscribes Observer to log adverts.
5. **Verification on Pi 3 B+:** SSH in, watch `RingLogger` output, see real BLE adverts streaming from your phone or any BLE device.

### Phase 0b (MVP) — passive scan wired to HA

Builds on Phase 0. Adds the proxy:

1. **Upstream espex first:** file a PR adding `Espex.BluetoothProxy` behaviour with `available?/0`, `mac_address/0`, `feature_flags/0`, `subscribe_advertisements/1`, `unsubscribe_advertisements/1`, `set_scanner_mode/1`.
2. **espex dispatch (in PR):** three new clauses — `SubscribeBluetoothLEAdvertisementsRequest`, `UnsubscribeBluetoothLEAdvertisementsRequest`, `BluetoothScannerSetModeRequest`. Plus `DeviceInfoResponse` gets `bluetooth_proxy_feature_flags = 0x21` (PASSIVE_SCAN + RAW_ADVERTISEMENTS) and `bluetooth_mac_address` populated.
3. **If upstream is slow:** vendor espex temporarily; revert when merged.
4. **In this project:** `UniversalProxy.ESPHome.BluetoothProxy` adapter — singleton GenServer that owns the blue_heron Observer subscription, batches adverts into `BluetoothLERawAdvertisementsResponse` messages (target 16 adverts/batch).
5. **Hardware detection:** `UniversalProxy.Hardware.Bluetooth.detect/0` — probe HCI bring-up status (UART layout is already handled by the Nerves system — see gaps §4).
6. **LiveView page:** basic — scanner on/off, MAC, live scan log (in-memory ring buffer). No connected-devices UI yet.
7. **Demo:** HA discovers a BTHome v2 sensor through this device.

### Phase 1 (post-MVP) — GATT read + services

10. blue_heron: Central connect/disconnect + GATT services discovery + GATT read.
11. espex: remaining ~6 BT dispatch clauses + outbound message templates.
12. Adapter: per-connection process tree + connection slot manager + service-discovery cache.

### Phase 2 — writes + notify + descriptors

13. blue_heron: GATT write (with/without response), notify subscribe, descriptor read/write.
14. espex: corresponding outbound templates.
15. Adapter: notify fan-out, write queue.

### Phase 3 (optional) — pairing + bonding

16. SMP central-side work in blue_heron.
17. `PAIRING` feature flag, key persistence.

---

## Worth verifying before committing

- Can phase 1 ship without ever touching the active-connection RPCs? Many BTHome v2 / iBeacon / temp+humidity use cases work with raw advertisements alone. If you'd be happy shipping at step 4 above, your work scope shrinks by ~70%.
- Is there an existing community fork of blue_heron with Central role half-done that we should know about?  (Worth one more web search.)
- Confirm Nerves rpi3/rpi4/rpi0_2 system configs free `/dev/ttyAMA0` for BT (default is "no").
