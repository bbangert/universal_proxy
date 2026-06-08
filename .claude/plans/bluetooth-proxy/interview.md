# Brainstorm: Bluetooth Proxy for ESPHome → Home Assistant

**Topic:** Add Bluetooth proxy capability so this Nerves firmware exposes a
local BLE controller to Home Assistant via the ESPHome Native API
(BluetoothLERawAdvertisementsResponse + GATT proxy RPCs).

**Status:** Decision Point — research complete
**Slug:** bluetooth-proxy

---

## Coverage

| Dim   | Score | Notes |
|-------|-------|-------|
| What  | 2/2   | Active proxy, deferred GATT writes. Phase 1 = scan + read + services. Phase 2 = write/notify/descriptor I/O. |
| Why   | 1/2   | Implied parity with serial/Z-Wave/IR proxies; deeper motivation not probed. |
| Scope | 2/2   | Pi 3/3B+/4/0W/0W2 onboard radios. USB BT nice-to-have. Pi 5 out. PR baseline researched. |
| Where | 2/2   | Existing ESPHome.Supervisor pattern + new espex behaviour + forked blue_heron. |
| How   | 2/2   | UART HCI on Pi onboard; blue_heron forked with #138/#139 applied; per-connection process tree. |
| Edge  | 1/2   | Slot count, advert batching, coexistence, ACL reassembly identified. Counts not committed. |
| **Total** | **10/12** — sufficient | |

## Decisions

- **Q1 → Active proxy, deferred GATT writes.** Phase 1: passive scanning +
  GATT read + services discovery. Phase 2: GATT write + notify + descriptor I/O.
  Drives feature-flag bits we advertise in `DeviceInfoResponse`.
- **Q2 → Targets: Pi 3 / 3B+, Pi 4, Pi 0 W / 0 W2.** All onboard UART HCI.
  USB BT dongles nice-to-have, not blocking. Pi 5 out of scope.
- **Q3 → Research the PR landscape** (done — see `research/blue-heron-state.md`).
- **Q4 → MVP scope reduction: ship passive-scan first.** Phase 0 ships
  without any GATT-client implementation. Active GATT + writes stay on
  the roadmap as phases 1–2. Cuts ~70% of total implementation effort
  from the first shippable version.
- **Q5 → Fork strategy: vendor blue_heron, hex-dep espex.** Mirror the
  `deps_local/mdns_lite/` pattern for blue_heron (which has a real
  upstream-merge problem). espex stays a hex dep and we file PRs
  upstream first — fork only if maintainer is unresponsive.
- **Q6 → Phase 0 scope shrunk again: just compile + scan + console log.**
  No espex / ESPHome / Home Assistant integration in this first slice.
  Validates: vendored blue_heron compiles on rpi3, #138/#139 bring up
  the radio, scan starts, adverts arrive on the BEAM. Zero proxy work
  yet. The previous "MVP" (HA sees BTHome sensors) becomes Phase 0b.
- **Q7 → Activation: compile-time + Mix.target match.** Start blue_heron
  unconditionally on rpi3/rpi4/rpi0/rpi0_2 targets; skip on host and
  other Nerves systems. Hardcode `/dev/ttyS0` for the rpi3 spike. No
  runtime toggle, no ConfigStore wiring, no LiveView in Phase 0.

## Headline finding

The open blue_heron PRs do NOT cover what a BT proxy needs. They polish
**Peripheral mode** + add **Pi 3/4/0W2 firmware loading**. The ESPHome BT
proxy requires the opposite role — **Central + GATT client** — which
blue_heron's README explicitly disclaims and which no open PR is working
on. See `gaps.md` for the full breakdown.

## Artifacts

- `research/codebase-scan.md` — existing adapter patterns + espex BT surface
- `research/blue-heron-state.md` — open PRs, capability inventory, maintainer signal
- `gaps.md` — synthesis: what's needed beyond the PRs, with priority order

---

## Known facts (from initial scan)

- `espex ~> 0.1.2` is already vendored with **all Bluetooth protobuf messages**:
  `SubscribeBluetoothLEAdvertisementsRequest`, `BluetoothLERawAdvertisementsResponse`,
  `BluetoothDeviceRequest`, `BluetoothGATT*`, `BluetoothScannerSetModeRequest`,
  `BluetoothSetConnectionParamsRequest`, etc. Including feature-flag fields on
  `DeviceInfoResponse` (`bluetooth_proxy_feature_flags`, `bluetooth_mac_address`).
- **No `Espex.BluetoothProxy` behaviour module exists** — only
  `Espex.SerialProxy`, `Espex.ZWaveProxy`, `Espex.InfraredProxy`. So espex
  needs new behaviour + dispatch wiring.
- `UniversalProxy.ESPHome.Supervisor` is `:rest_for_one` over
  `ZWaveProxy → Infrared.Supervisor → Espex`. Pattern is clear to extend.
- `blue_heron` is **not** currently a dep. Will need to be added.
- Target list in `mix.exs`: rpi/rpi0/rpi0_2/rpi2/rpi3/rpi4/rpi5, bbb, grisp2,
  osd32mp1, mangopi_mq_pro, qemu_aarch64, x86_64.
- Memory note: testbed is **Pi 3 B+** at 192.168.2.102 (has onboard BT/BCM43438).

---

## Open questions

1. (current) Scope — full active GATT proxy vs passive-scan-only?
2. Which target boards must work? (rpi3/4/5 are easy; rpi0w has BT too)
3. Which blue_heron PRs are you tracking? (URLs / fork)
4. UART HCI vs USB HCI controller? (Pi-onboard is UART, USB BT dongles differ)
5. Coexistence with Wi-Fi (Pi onboard radio shares antenna)?
6. Connection slot count target? (ESPHome default is 3)
