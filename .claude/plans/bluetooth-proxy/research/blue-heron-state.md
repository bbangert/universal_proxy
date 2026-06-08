# blue_heron State — May 2026

Direct survey via the GitHub API on 2026-05-21.

## 1. Open PRs (as of today)

| Repo | PR | Title | Author | Opened | What it adds | Mergeable |
|------|----|-------|--------|--------|--------------|-----------|
| blue-heron/blue_heron | #142 | `Peripheral.add_services/1` (batch service registration) | elielgordondensity | 2026-05-14 | Avoid GATT-server rebuild storm when registering N services at startup | yes (no conflicts) |
| blue-heron/blue_heron | #141 | Configurable + current ATT MTU handling | elielgordondensity | 2026-05-10 | `peripheral: [local_mtu: 512]` config + `current_mtu/0` getter. Resolves issue #137 | yes |
| blue-heron/blue_heron | #140 | Chunk ACL packets by `acl_data_packet_length` | elielgordondensity | 2026-05-10 | Host-side ACL fragmentation so notifications larger than controller buffer get split | yes |
| blue-heron/blue_heron | **#139** | **Bundle Broadcom firmware + RPi 4 support** | TomHoenderdos | 2026-02-23 | Bundles `.hcd` blobs in `priv/firmware/brcm/` (BCM43430A1/B0, BCM4345C0/C5). Adds RPi 4 LMP subversion mapping `0x6119`. **Depends on #138.** **Draft.** | yes |
| blue-heron/blue_heron | **#138** | **Add Bluetooth support for RPi Zero 2W (Broadcom vendor HCI firmware load)** | TomHoenderdos | 2026-02-19 | Implements full Broadcom vendor-init: `ReadLocalVersion` → detect Broadcom (manufacturer 15) → `.hcd` parser → `DownloadMinidriver`/`UpdateBaudrate` → warm boot. Adds `VendorSpecific` OGF 0x3F group, `FirmwareLoader`, `BroadcomInit`. Backward-compatible. | yes |
| blue-heron/blue_heron | #136 | Fix bluez not connecting | lawik | 2026-02-11 | Targets the `blue_heron_transport_hcidev` path | yes |
| blue-heron/blue_heron | #135 | Update credo to 1.7.16 | lawik | 2026-02-11 | Compile under newer Elixir/OTP | yes |
| blue-heron/blue_heron | #134 | Fix cutoff points for 16/32/128 bit service UUID detection | schwarz | 2025-07-18 | Advertising-data parser bugfix | yes |

**Sub-repo status:**

- `blue_heron_transport_usb` — **archived** 2025-01-02 (consolidated into main repo in 0.5.x)
- `blue_heron_transport_uart` — **archived** 2025-01-02 (same)
- `blue_heron_transport_hcidev` — active, last pushed 2023-08-29 (Linux bluez-shim transport)
- `blue_heron_ti_wl18xx` — alive but last pushed 2022-08-23

## 2. Released vs. main vs. PRs

- **hex.pm:** `0.5.4` (published 2025-01-22 / 2025-03-31 retag).
- **main:** identical to 0.5.4 right now — repo `pushed_at` is 2025-03-31, so nothing has merged in over a year.
- **PRs only:** the entire Broadcom firmware-loading machinery (#138 + #139). Without these PRs applied as a fork/path dep, RPi 3B+/4/0W2 will not bring up the radio.

## 3. Capability inventory — the BIG finding

**blue_heron README explicitly lists role support:**

> - [x] BLE peripheral and GATT server support (Peripheral role)
> - [x] Support BLE beacons (Broadcaster role)
> - [ ] Scan for and connect to BLE peripheral devices (Central role)
> - [ ] GATT client support
>
> The current focus is on filling out the peripheral role.

**Mapping ESPHome BT Proxy RPCs against blue_heron capabilities:**

| ESPHome RPC | blue_heron status | Notes |
|-------------|-------------------|-------|
| Raw advertisement subscribe (passive scan) | ❌ | Requires Central / Observer role. Not implemented. |
| Scanner mode set (passive ↔ active ↔ off) | ❌ | Same. |
| Active connection (Connect / Disconnect) | ❌ | Central role connection setup is not implemented. |
| Connection slot accounting | ❌ | No central-role connection registry. |
| GATT services discovery | ❌ | GATT client not implemented (server-side discovery exists for Peripheral). |
| GATT read characteristic | ❌ | GATT client missing. |
| GATT write characteristic | ❌ | Same. |
| GATT notify subscribe/unsubscribe | ❌ | Same. (Peripheral can *send* notifications — opposite direction.) |
| GATT read/write descriptor | ❌ | Same. |
| Connection parameter update (from central) | ❌ | Same. |

The five recent PRs (#140/#141/#142 from elielgordondensity and #138/#139 from TomHoenderdos) are entirely about **Peripheral mode polish** and **target hardware bring-up**. None of them advance Central or GATT-client.

This is the headline finding: **the open PRs do not get us close to a working
BT proxy.** They get us a peripheral-only stack on Pi 3/4/0W2.

## 4. Maintainer signal (early 2026)

- **Last release: v0.5.4** (2025-03-31).
- **Last merge to main:** also 2025-03-31. The repo has been **dormant for 14 months on the maintainer side**.
- But — **community activity resumed in Feb 2026** (PRs #135/#136/#138/#139) and again in May 2026 (#140/#141/#142). New contributors (TomHoenderdos, elielgordondensity) are doing substantive work.
- **Issue triage:** 16 open issues, oldest from 2020 still unanswered (e.g. #22 "Simplify encoding/decoding"). Multi-year-old issues #25/#23/#21 still open. So while community PRs are flowing, **nobody is actively merging them**.
- Risk: depending on upstream blue_heron is risky. Realistic plan should assume a forked/path-dep workflow (consistent with how this project already vendors `mdns_lite` in `deps_local/`).

## 5. Bring-up notes for Pi onboard radios

- **Pi Zero W** (CYW43438): README claims this works out of the box without firmware load, but reality is mixed — depends on Nerves system shipping `brcm_patchram` or pre-loaded firmware.
- **Pi 3B / 3B+** (CYW43438 / CYW43455): #138 + #139 are required for the firmware download path. Without them, the radio is unusable from blue_heron.
- **Pi 4** (BCM4345C5, LMP subversion 0x6119): #139 specifically adds this mapping.
- **Pi Zero 2W** (BCM43430B0): #138 is the PR that adds this.
- **Wi-Fi coexistence:** the Pi onboard radios are combo chips sharing antenna. There's no documented blue_heron coexistence handling. Real-world reports on the Nerves forum suggest BT scan performance degrades while Wi-Fi is heavily used, but BT-only stays functional. If the device runs over Ethernet (as your testbed does), this is not a concern.

`brcm_patchram` / external firmware loading is **not needed** with #138 applied — the PR moves all of that into pure Elixir. Bundled `.hcd` files in `priv/firmware/brcm/` (per #139) eliminate the rootfs-overlay hassle entirely.

## 6. ESPHome `bluetooth_proxy_feature_flags` reference

Defined in ESPHome's `bluetooth_proxy.h`. Bit flags (uint32):

| Bit | Name | Meaning |
|-----|------|---------|
| 0 | `PASSIVE_SCAN` | Server supports forwarding passive scan advertisements |
| 1 | `ACTIVE_CONNECTIONS` | Server supports active GATT connections |
| 2 | `REMOTE_CACHING` | Server caches GATT services across reconnects (perf) |
| 3 | `PAIRING` | Server handles pairing requests on behalf of HA |
| 4 | `CACHE_CLEARING` | Server honours `bluetooth_clear_cache` requests |
| 5 | `RAW_ADVERTISEMENTS` | Server emits `BluetoothLERawAdvertisementsResponse` (the post-2025.8 format) |
| 6 | `STATE_AND_MODE` | Server supports the scanner-state RPC pair |

For the chosen scope (active proxy, deferred GATT writes, phase 1):
**Phase 1 flags:** `PASSIVE_SCAN | ACTIVE_CONNECTIONS | RAW_ADVERTISEMENTS | STATE_AND_MODE` = `0x63`.
Optionally add `REMOTE_CACHING` (`0x04`) if we cache services in DETS = `0x67`.

## 7. Risks / landmines beyond blue_heron

- **No upstream merge cadence.** Even if PRs #138/#139 are tested by their author, they may stay open indefinitely. Plan for a vendored fork.
- **Central role is entire new state machine.** ~peripheral.ex equivalent for the central side, plus connection manager, scan window/interval handling, address-type resolution (public vs random vs RPA), and L2CAP request routing.
- **GATT client** needs services discovery (primary services + characteristics + descriptors traversal), MTU exchange (Peripheral got it in #141 — Central needs parity), and write-without-response queue management.
- **ACL fragmentation on receive** — #140 fixes outbound. Inbound reassembly for large GATT notify payloads (common with BTHome / Xiaomi / ESPHome sensors) is uncertain — confirm before shipping.
- **Slot accounting** — ESPHome uses a hardcoded slot count (3 default, configurable up to ~9). Pi onboard chips support more than 3 concurrent connections in theory, but blue_heron's connection table would need explicit limits.
- **`SubscribeBluetoothConnectionsFreeResponse`** is sent eagerly to clients whenever slot count changes — needs a publisher in the adapter.
- **Advert batching:** ESPHome batches raw advertisements into `BluetoothLERawAdvertisementsResponse` (target ~16 per message based on `BLUETOOTH_PROXY_ADVERTISEMENT_BATCH_SIZE`). Sending one-message-per-advert is wire-inefficient.
- **Random Private Address resolution** — needed for pairing flows but **optional for phase 1**.

## 8. Where to fork from

If we go fork-and-vendor, start from `main` + cherry-pick #138 → #139 → #140 → #141 → #142 → #134. That gives us a peripheral-polished base on which to **implement** central role + GATT client. Author TomHoenderdos's PRs look high-quality (Claude-generated descriptions, tested on hardware, no conflicts).

## 9. Community-fork survey

Active forks (pushed since 2024-01-01) inspected on 2026-05-21:

| Fork | Last push | What's there beyond upstream |
|------|-----------|------------------------------|
| `DensityCo/blue_heron` | 2026-05-14 | Same org as `elielgordondensity` (PRs #140/#141/#142). Active development base for the recent Peripheral-mode PRs. |
| `adiibanez/blue_heron` | 2026-04-24 | Has a `multi-connection` branch (1 commit on top of v0.5.4) adding: multi-connection GATT *server*, Broadcom firmware loader, USB CDC transport, ACL buffer fixes, SMP refactor. Test coverage included. **Note:** "multi-connection" refers to multiple *clients* connected to a peripheral, NOT central role. |
| `TomHoenderdos/blue_heron` | 2026-03-02 | Source of PRs #138/#139 (Pi 3/0W2/4 firmware loading). |
| `lawik/blue_heron` | 2026-02-11 | Source of PRs #135/#136 (credo + bluez-transport fix). |
| `schwarz/blue_heron` | 2025-07-18 | Source of PR #134 (UUID detection). |
| `intuitivo-ai/blue_heron_intuitivo` | 2026-03-06 | Renamed fork of v0.5.4, no apparent role additions — likely a vendor copy. |

**Verdict: nobody has implemented Central role + GATT client publicly.** All active community work is concentrated on Peripheral mode quality + hardware bring-up. This means we cannot offload that work to upstream.

## 10. Surprise finding — HCI command structs already exist

`lib/blue_heron/hci/commands/le_controller/` already contains:

- `create_connection.ex`
- `create_connection_cancel.ex`
- `set_scan_parameters.ex`
- `set_scan_enable.ex`
- `set_random_address.ex`
- `read_buffer_size_v1.ex`
- `read_white_list_size.ex`
- `read_local_supported_features.ex`

So the **wire-level HCI primitives are there** — what's missing is the higher-level state machine that drives them and the `LEMeta.AdvertisingReport` / `LEMeta.EnhancedConnectionComplete` event handlers that complete the round-trip. That's good news: Phase 0 (scan + advertisement report) can be done without writing new HCI commands, only new event handlers + a thin GenServer driver.

## 11. Nerves system / UART layout for Pi onboard BT

Confirmed from `nerves_system_*` `config.txt` files (May 2026):

| System | UART config | BT tty |
|--------|-------------|--------|
| `nerves_system_rpi3` | `enable_uart=1`, `dtoverlay=miniuart-bt`, `core_freq=250` | `/dev/ttyS0` (miniUART) |
| `nerves_system_rpi0` | same as rpi3 | `/dev/ttyS0` |
| `nerves_system_rpi0_2` | same as rpi3 | `/dev/ttyS0` |
| `nerves_system_rpi4` | `enable_uart=1` (no overlay) | `/dev/ttyAMA0` (or whichever the BT chipset is wired to via DT) |

**Important:** Nerves Pi systems already enable BT by default, contrary to upstream Raspberry Pi OS which often ships with `dtoverlay=disable-bt`. **No device-tree changes are required** — this was a feared blocker that turns out to be a non-issue. The radio is sitting there waiting to be talked to.

Caveat: `/dev/ttyS0` is the slower miniUART (max ~460800 baud reliably). For BT 4.x this is fine; for BT 5 PHY/extended adv at full throughput it could be a bottleneck on Pi 3/0/0_2. Pi 4 doesn't have this issue.
