# Plan: Bluetooth Proxy — Phase 0 Spike (vendored blue_heron + radio bring-up + scan)

**Source:** [.claude/plans/bluetooth-proxy/interview.md](.claude/plans/bluetooth-proxy/interview.md)
**Slug:** `bluetooth-proxy`
**Depth:** standard (Phase 0 only; later phases sketched, not tasked)
**Target hardware:** Pi 3 B+ at `192.168.2.102` (existing testbed, BCM43438)
**Scope:** **Compile + scan + console log only.** No espex / ESPHome / HA integration in this plan. No GATT client. No LiveView. The next slice ("Phase 0b") will be its own plan after this lands.

---

## Done when

On the Pi 3 B+ testbed:

1. Firmware built from this branch boots cleanly.
2. The vendored `blue_heron` supervision tree starts under `UniversalProxy.Application` on `MIX_TARGET=rpi3`.
3. The Broadcom radio is brought up over `/dev/ttyS0` (vendor HCI firmware load succeeds; controller reports `Read Local Version` info).
4. LE scan is enabled at boot.
5. `Logger.info` lines containing decoded BLE advertisement reports stream into `RingLogger` as nearby BLE devices (phone, Bluetooth temp sensor, AirPods, etc.) advertise.
6. On host (`MIX_TARGET=host`) the compile path is clean: vendored blue_heron is **not** started, and the codebase still compiles and tests green.

**Not in scope (Phase 0b+):**

- `Espex.BluetoothProxy` behaviour, dispatch wiring, `bluetooth_proxy_feature_flags`, `bluetooth_mac_address`.
- Advertisement batching into `BluetoothLERawAdvertisementsResponse`.
- Central role connect/disconnect, GATT services / read / write / notify.
- Connection slot manager.
- LiveView page.
- Pi 4 / Pi 0 W / Pi 0 W2 / USB BT support (rpi3 only this phase).
- `ConfigStore` persistence for BT settings.

---

## Pre-flight (read before starting)

The four pre-Phase 0 risks from [gaps.md](.claude/plans/bluetooth-proxy/gaps.md) carry over verbatim. Re-stated here because they shape Tasks 1–3:

1. **#139 depends on #138.** Cherry-pick order matters. Reverse order produces conflicts.
2. **#139 is draft + Pi 4 untested.** Pi 3 B+ spike does not exercise the rpi4 `0x6119` LMP mapping introduced by #139 — that's deferred risk for Phase 0b on rpi4.
3. **brcm_patchram may already be in nerves_system_rpi3.** Before vendoring #139's bundled blobs, check `ls /lib/firmware/brcm/` on the running Pi. If `BCM43430A1.hcd` is already present, **the spike can succeed with only #138 applied** and we can defer #139.
4. **Forking risk.** blue_heron upstream is dormant 14 months. Treat `deps_local/blue_heron/` as long-lived, mirroring the existing [`mdns_lite` vendored pattern](deps_local/mdns_lite/).

---

## Tasks

### Stage A — Probe the testbed before touching code

The cheapest task: confirm Risk 3 on the actual hardware. Result determines whether we cherry-pick #138 only, or #138 + #139.

- [x] **A1 [hardware]** SSH probe done 2026-05-21 — see scratchpad. No `.hcd` files in `/lib/firmware/brcm/`; `/dev/ttyS0` present; ttyAMA0 is console; chipset is BCM4345/6 (not BCM43438).
  - [x] `ls /lib/firmware/brcm/` — only WiFi `brcmfmac*` blobs; **no `.hcd` files**
  - [x] `ls -l /dev/ttyS0 /dev/serial1 /dev/ttyAMA0` — `/dev/ttyS0` ✓, `/dev/serial1` enoent, `/dev/ttyAMA0` is serial console
  - [x] `dmesg | grep -iE "bcm|bluetooth|brcm|hci"` — WiFi init only; no bluetooth/hci lines
- [x] **A2 [decision]** Cherry-pick **#138 then #139** (both required because no bundled `.hcd` present). Recorded in scratchpad.

### Stage B — Vendor the fork

Mirror the existing `deps_local/mdns_lite/` pattern. The fork should live at `bbangert/blue_heron` on GitHub *and* be checked into `deps_local/blue_heron/` as a path dep.

- [x] **B1 [git]** Forked `blue-heron/blue_heron` → `bbangert/blue_heron`, cloned to `~/src/blue_heron`. pr-139 stacks on pr-138, so fast-forwarded `bluetooth-proxy-base` to `pr-139` tip (=7 commits on top of v0.5.4; equivalent to cherry-picking both PRs in order). Pushed `bluetooth-proxy-base` to fork. Tip: `32bf7f2`.
- [x] **B2 [vendor]** Copied fork into `deps_local/blue_heron/` (no `.git/`, no `.github/`). VENDORED.md captures source/SHA/PR list + A2 decision + downstream-additions placeholder.
- [x] **B3 [mix]** Added `:blue_heron` path dep in [`mix.exs`](mix.exs) targets-restricted to `[:rpi0, :rpi0_2, :rpi3, :rpi4]` (dropped `:rpi3a` — not in `@all_targets`).
- [x] **B4 [compile]** `mise run test` green (315 tests, 0 failures, blue_heron not loaded on host). `mix deps.compile blue_heron` on rpi3 builds clean (some upstream Elixir 1.19 type-system warnings in unrelated LongTermKeyRequest/AdvertisingReport serializers — pre-existing, not caused by our changes).

### Stage C — Add the LE scan plumbing inside the vendored fork

The HCI commands `LESetScanParameters` and `LESetScanEnable` already exist (per [research/blue-heron-state.md §10](.claude/plans/bluetooth-proxy/research/blue-heron-state.md)). The missing pieces are the **event-side parser** for `LEMeta.AdvertisingReport` and a thin **driver GenServer** that owns scan params and dispatches reports.

These changes live inside `deps_local/blue_heron/`, **not** in `lib/universal_proxy/`. Cleanest path to upstream later. Keep a "downstream changes" section in `VENDORED.md` (mirror of how `deps_local/mdns_lite/` documents `announce_all/0` + `goodbye_service/1`).

- [x] **C1 [bt]** Audit done — `BlueHeron.HCI.Event.LEMeta.AdvertisingReport` (subevent `0x02`) **already exists** at `deps_local/blue_heron/lib/blue_heron/hci/events/le_meta/advertising_report.ex` with `defparameters devices: [], num_reports: 0` and a `Device` sub-struct (`event_type`, `address_type`, `address`, `data`, `rss`). Pre-shipped by upstream — no decoder work needed.
- [x] **C2 [bt]** Skipped — see C1. Note: device field is named `rss` (not `rssi` as the plan supposed).
- [x] **C3 [bt]** Skipped — LEMeta dispatch is *not* a table; `BlueHeron.HCI.Event.LEMeta.list/0` discovers events at runtime via `Application.spec(:blue_heron, :modules) |> Enum.filter(...)`. Any module under `BlueHeron.HCI.Event.LEMeta.*` is auto-dispatched. Adding the module = wiring it.
- [x] **C4 [otp]** Added `BlueHeron.Observer` GenServer at `deps_local/blue_heron/lib/blue_heron/observer.ex`. Subscribes to `BlueHeron.Registry`, waits for `{:BLUETOOTH_EVENT_STATE, :HCI_STATE_WORKING}`, issues `SetScanParameters` + `SetScanEnable(true)`, fans out `LEMeta.AdvertisingReport` events to a configured callback per `Device` entry, disables scan in `terminate/2`. Compiled clean for `MIX_TARGET=rpi3`. Public API: `start_link(callback: fn/1[, scan_params: kw, filter_duplicates: bool])`.
- [x] **C5 [docs]** VENDORED.md "Downstream additions" section now lists `Observer` (with upstream-PR intent) and notes that `AdvertisingReport` was pre-existing (not a downstream add).

### Stage D — Wire Observer into the Universal Proxy application

The minimal integration is a single new module that starts blue_heron + Observer on rpi3 only, with `Logger.info` as the callback. No espex wiring; no ConfigStore; no PubSub fan-out.

- [x] **D1 [otp]** Created `lib/universal_proxy/bluetooth.ex` — Supervisor whose only child is `BlueHeron.Observer` (with `&log_advertisement/1` callback). Compile-time guarded to Phase-0 targets (`[:rpi3]`); off-target falls back to the proper `:ignore` stub pattern (`child_spec/1` returns a regular map, `start_link/1` returns `:ignore` — bare `:ignore` from `child_spec/1` is not a valid child spec and crashes the parent supervisor). Plan's "build spec for blue_heron + Observer as siblings under our `:rest_for_one` supervisor" doesn't apply — blue_heron is an OTP app with its own `BlueHeron.Application` autostart, not something we mount; transport opts go via `:blue_heron, :transport` Application config in `config/target.exs` (rpi3-guarded; `device: "/dev/ttyS0", speed: 115_200, flow_control: :hardware`). Phase 0b broadens beyond rpi3.
- [x] **D2 [app]** `UniversalProxy.Bluetooth` added to `target_children/0` in [`application.ex`](lib/universal_proxy/application.ex).
- [x] **D3 [verify-host]** `mise run test` green (315 tests, 0 failures). `mix format --check-formatted` clean. `mise run lint` (credo --strict) clean.

### Stage E — Hardware verification on Pi 3 B+

- [x] **E1 [build]** `mix firmware && ./upload.sh 192.168.2.102` — built and uploaded multiple times (see scratchpad). Note: `mise run test` regenerates `priv/sendspin_player/host/sendspin_player` which then breaks the Nerves rootfs scrubber on the next firmware build; `rm -rf priv/sendspin_player/host` before each `mix firmware`. Pre-existing project quirk, not BT-related.
- [x] **E2 [ssh]** PARTIAL: On the original (`:hardware` no-patch) firmware boot, all wiring was confirmed alive via `Supervisor.which_children/1`:
  - `Process.whereis(UniversalProxy.Bluetooth)` returns a pid ✓
  - Children: `[BlueHeron.Observer]` ✓
  - `BlueHeron.Supervisor` tree alive (HCI.Transport, Peripheral, SMP, Broadcaster, ACLBuffer, Registry, GATT) ✓
  - RingLogger via `RingLogger.get/0` (not `RingLogger.tail` — that gets cut by `System.halt`) shows the firmware-load happens cleanly: hundreds of `0xFC4C` Command Completes followed by a `0xFC4E` (LaunchRAM) CC.
  - But **`BlueHeron.HCI.Transport.setup_complete?/0` returns `false`** — the post-LaunchRAM `Reset` (opcode `0x0C03`) times out in a 5-second loop forever. No `BLE adv:` lines ever emitted.
- [ ] **E3 [scan]** BLOCKED on E2 — Observer never reaches scan-enable because `BlueHeron.HCI.Transport`'s setup never completes. Root cause and proposed fix tracked in scratchpad.
- [ ] **E4 [stability]** BLOCKED on E3.

### What's needed to unblock E3/E4

As of 2026-05-22 wind-down: the Linux-equivalent post-LaunchRAM
recovery sequence is implemented and verified to run cleanly on
hardware, but the BCM4345C5 on Pi 3 B+ remains silent. The current
vendor_init sequence (`{:delay, 3000} → :uart_flush_rx → {:delay,
200} → :uart_configure_resync → {:delay, 50} → :uart_break_wake →
{:delay, 50} → ReadBdAddr`) reproduces what Linux btbcm does, but
the chip still emits zero UART bytes after `LaunchRAM`.

Strongest remaining hypothesis (see [scratchpad.md](scratchpad.md)
"2026-05-22 wind-down" section): **miniUART vs PL011**.
`nerves_system_rpi3` activates `dtoverlay=miniuart-bt`, putting BT
on `/dev/ttyS0` = BCM2835 mini UART so PL011 can serve the console.
Raspberry Pi OS does the opposite (BT on PL011). The mini UART has
documented limitations that may be incompatible with the
post-firmware chip's UART behavior.

Next session work (DO NOT execute without re-planning):

1. Probe `nerves_system_rpi3`'s actual UART config on the running
   Pi: confirm `/dev/ttyS0` is mini UART, `/dev/ttyAMA0` is PL011,
   and whether `dtoverlay=miniuart-bt` is in `/boot/config.txt`.
2. Plan the BT-on-PL011 swap: update target.exs to use
   `/dev/ttyAMA0`, override nerves_system_rpi3's config.txt (or use
   `dtoverlay=disable-bt` and avoid `miniuart-bt`), remove the
   `console=ttyAMA0,115200` kernel cmdline so PL011 is free for BT.
   Accept that serial console moves to mini UART or disappears
   entirely (SSH-only).
3. Optionally file a blue_heron upstream issue documenting the
   Pi 3 B+ gap and the current recovery sequence on disk.

### Stage F — Document the spike result

- [x] **F1 [docs]** scratchpad updated with: A1 findings, A2 decision, the Linux btbcm investigation, the naive resync attempt failure, iteration-safety lessons, full handoff snapshot.
- [x] **F2 [memory]** Memory files written: chipset correction (Pi 3 B+ is BCM4345/6 not BCM43438), `RingLogger.tail` cuts on `System.halt` (use `RingLogger.get/0`), `mise run test` regenerates host sendspin_player binary that breaks Nerves firmware build, scripted `ssh` into nerves_ssh IEx needs `-tt` + `System.halt(0)`.

---

## Verification gates (the must-run-greens)

After each stage that touches code:

| Stage | Command | What we're checking |
|-------|---------|---------------------|
| B | `mix deps.get` | Vendored fork resolves |
| B | `mix compile` (host) | No drift from the cherry-picks |
| B | `MIX_TARGET=rpi3 mix deps.compile blue_heron` | Vendored fork builds for the spike target |
| C | `cd deps_local/blue_heron && MIX_TARGET=rpi3 mix compile` | Downstream additions compile against the existing tree |
| D | `mise run test` | Application boots cleanly on host (no regressions) |
| D | `mix format --check-formatted` | Style |
| D | `mix credo --strict` | If currently green; respect existing baseline if not |
| E | Hardware E1–E4 | The actual win condition |

`mise run test` is the canonical test command per [memory:test_command](../../memory/test_command.md). Do not invoke bare `MIX_TARGET=host mix test` — the mise shell hook silently overrides it.

---

## Risks (Phase 0 only)

Three questions worth holding in mind during implementation:

1. **What if `flow_control: :hardware` on `/dev/ttyS0` is wrong?** Symptom: vendor firmware-load command times out, controller never reports `Read Local Version`. Mitigation: try `:none` (the miniUART on rpi3 supports HW flow but most published examples disable it). Cost of being wrong: ~1 reflash cycle. **Probability:** medium.
2. **What if `AdvertisingReport` arrives as raw HCI bytes rather than the expected struct?** If C3 wires dispatch incorrectly, Observer's `handle_info` will match on a raw tuple instead of `%LEMeta.AdvertisingReport{}`. Mitigation: add a catch-all `handle_info(msg, state)` in Observer that `Logger.warning`s any unrecognised event so we can see what shape it's actually coming through as during E2/E3. **Probability:** medium (this is the most likely "first run fails" mode).
3. **What if Risk 3 from gaps.md is actually wrong and #139 is required on this kernel?** A1 will catch this — if `BCM43430A1.hcd` is absent, A2 picks the both-PRs path and we proceed. The risk is if A1 says "present" but it's a stale leftover from a different firmware. Mitigation: if E2 shows vendor-init failing despite #138-only build, redo Stage B with #139 included before declaring the spike broken.

---

## After Phase 0 (sketch — these are NOT tasks in this plan)

When E1–E4 are green, the next planning round (`/phx:plan` on a fresh "phase 0b" interview) covers:

- `Espex.BluetoothProxy` behaviour (upstream espex PR — fork as `deps_local/espex/` if maintainer is slow).
- Espex dispatch clauses for `SubscribeBluetoothLEAdvertisementsRequest` / `UnsubscribeBluetoothLEAdvertisementsRequest` / `BluetoothScannerSetModeRequest`.
- `DeviceInfoResponse` carries `bluetooth_proxy_feature_flags = 0x21` (PASSIVE_SCAN + RAW_ADVERTISEMENTS) + `bluetooth_mac_address` from the controller.
- `UniversalProxy.ESPHome.BluetoothProxy` adapter — singleton GenServer, owns the Observer subscription, batches adverts into `BluetoothLERawAdvertisementsResponse` (target 16 adverts/batch).
- Hardware detection (`UniversalProxy.Hardware.Bluetooth.detect/0`) + minimal LiveView (scanner toggle, MAC, scan log).
- HA discovers a BTHome v2 sensor end-to-end through this device.

Phases 1–3 (active connections, GATT client, writes/notify, pairing) are gated on Phase 0b succeeding, and on someone with BLE-stack expertise being available (per gaps §2 the central-role + GATT-client work is the load-bearing 4–6 weeks). These are not committed scope.

---

## File map (created / modified by this plan)

| Path | Change | Stage |
|------|--------|-------|
| `deps_local/blue_heron/` | New vendored fork | B |
| `deps_local/blue_heron/VENDORED.md` | New | B + C |
| `deps_local/blue_heron/lib/blue_heron/hci/event/le_meta/advertising_report.ex` | New (if missing) | C |
| `deps_local/blue_heron/lib/blue_heron/observer.ex` | New | C |
| `mix.exs` | Add `:blue_heron` path dep (targeted) | B |
| `lib/universal_proxy/bluetooth.ex` | New (compile-time-guarded) | D |
| `lib/universal_proxy/application.ex` | Add child in `target_children/0` | D |
| `.claude/plans/bluetooth-proxy/scratchpad.md` | Append findings | A, F |

No changes to `lib/universal_proxy/esphome/` in this phase. No changes to LiveView or routes. No new tests yet (host can't exercise BT; integration tests deferred to Phase 0b when there's an espex behaviour to fake).
