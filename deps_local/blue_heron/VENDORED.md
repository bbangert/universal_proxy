# Vendored: blue_heron

This is a vendored fork of [blue-heron/blue_heron](https://github.com/blue-heron/blue_heron).
It mirrors the existing `deps_local/mdns_lite/` pattern: long-lived path
dep, downstream changes documented here, upstream PRs filed in parallel
but **not depended on** for merge.

## Why vendored

Upstream is dormant on the maintainer side: last release `v0.5.4`
(2025-03-31), no merges in over a year as of 2026-05. The Broadcom
firmware-loading machinery that Universal Proxy needs to bring up the
onboard radio on Raspberry Pi 3/4/0_2 is stuck in **two community PRs**
that don't show signs of getting merged on the maintainer's schedule:

- [#138 — Add Bluetooth support for Raspberry Pi Zero 2W](https://github.com/blue-heron/blue_heron/pull/138)
- [#139 — Bundle Broadcom firmware and add RPi 4 support](https://github.com/blue-heron/blue_heron/pull/139)

Without these PRs the radio is unusable from blue_heron on the targets
Universal Proxy supports. Plus the BT-proxy work this project is doing
(scan driver, Central role, GATT client) needs to live somewhere — the
vendored fork is that home.

Treat this directory as the source of truth. Upstream-PR backports are
contributions, not the canonical copy.

## Source provenance

| Field                | Value |
|----------------------|-------|
| Source repo          | https://github.com/blue-heron/blue_heron |
| Fork repo            | https://github.com/bbangert/blue_heron |
| Fork branch          | `bluetooth-proxy-base` |
| Fork tip SHA         | `32bf7f2d4cb38b6b82c6bb7d59036d3279a6cbf0` |
| Forked from upstream | `7b0cc876ba5267d0f8560c5e6d9c928a397382e4` (= `v0.5.4` tag) |
| Vendored on          | 2026-05-21 |

## Applied upstream PRs

`bluetooth-proxy-base` is **TomHoenderdos's stacked PR branch**, used
verbatim per the [gap analysis recommendation](../../.claude/plans/bluetooth-proxy/gaps.md)
("fork from TomHoenderdos's branch directly so both PRs are pre-applied").
PR #139 is built on top of PR #138, so a literal cherry-pick of both
would create duplicate-commit conflicts; fast-forwarding to PR #139's
tip is equivalent and clean.

Commits applied on top of upstream `v0.5.4` (oldest → newest):

| SHA       | PR    | Title |
|-----------|-------|-------|
| `997d2d4` | #138  | Add Bluetooth support for Raspberry Pi Zero 2W |
| `bc98ad1` | #138  | Add tests for vendor-specific commands and Broadcom init |
| `45e8ecf` | #139  | Bundle Broadcom firmware and add RPi 4 support |
| `faaab26` | #139† | Fix ACL handle/flags bit-field serialization |
| `33b6e2e` | #139† | Add HCI host-to-controller flow control |
| `41985b3` | #139† | Add GATT Write Without Response support |
| `32bf7f2` | #139† | Log unhandled L2CAP signaling packets |

† PR #139's branch ships these as ride-along improvements alongside the
firmware-bundling commit. None affect the Central-role/scan path we
care about; all are benign and arguably useful (ACL bug fix,
flow-control, GATT WWR for peripheral, L2CAP diag logging).

### A2 decision (why both PRs, not just #138)

Probed [`192.168.2.102`](../../.claude/plans/bluetooth-proxy/scratchpad.md)
on 2026-05-21: `/lib/firmware/brcm/` contained only WiFi (`brcmfmac*`)
blobs and zero `.hcd` files. The bundled `BCM4345C0.hcd` (and the
others) from PR #139 is therefore required — `nerves_system_rpi3`
2.x ships no Broadcom HCI firmware on the rootfs.

## Downstream additions (this fork only — file upstream later)

Listed here when added. Each entry: file, rationale, "upstream-PR
intent" so we remember to backport. Mirror of how `deps_local/mdns_lite/`
documents downstream `announce_all/0` / `goodbye_service/1` (see
[memory:mdns_lite_vendored](../../.claude/projects/-workspaces-universal-proxy/memory/mdns_lite_vendored.md)).

### `BroadcomInit` post-LaunchRAM UART recovery sequence (Linux-equivalent)

**Files:**
- `lib/blue_heron/hci/transport/broadcom_init.ex` (post-firmware sequence)
- `lib/blue_heron/hci/transport.ex` (new `:uart_flush_rx`,
  `:uart_configure_resync`, and `:uart_break_wake` setup steps,
  plus restart-aware `Logger.info` at top of `init/1` so RingLogger
  can distinguish fresh boot from supervisor restart)
- `lib/blue_heron/hci/transport/uart.ex` (`flush/2` direction
  overload, `configure/2` passthrough, and `pulse_break/2`
  wrapper around `Circuits.UART.set_break/2`)

Symptom this addresses: on a Pi 3 B+ (BCM4345C5, LMP `0x6119`), the
firmware download completes — every `Write_RAM` (`0xFC4C`) and the
final `LaunchRAM` (`0xFC4E`) return `Command Complete status 0` — but
the chip then refuses to respond to **any** post-LaunchRAM HCI
command. `Reset (0x0C03)`, `UpdateBaudrate (0xFC18)`, and
`Read_BD_ADDR (0x1009)` all time out forever; the chip sends zero
bytes back. CYW43436S on RPi Zero 2W (which PR #138 was tested on)
doesn't exhibit this; its `bcm43430_device_data` sets quirks that
change init timing. The Pi 3 B+ BCM4345C5 path is a known unfixed
gap in blue_heron (issue #21 / PR #138 discussion, pxp9 Feb 2026
confirmation).

What this change does (mirrors Linux `btbcm`/`hci_bcm`):

1. Wait 3s for chip to relaunch from patch RAM (top of Pi 3 B+'s
   documented 1.5–3s init window).
2. Flush host UART RX so framer mid-frame state is clean.
3. Re-apply termios (mirrors `host_set_baudrate(hu, init_speed)` →
   `tty_set_termios` side effects: FIFO drop/re-arm).
4. Pulse a 20ms UART BREAK to wake the chip if its patch firmware
   enabled sleep mode by default.
5. Sync on `Read_BD_ADDR` (NOT Reset) — what Linux `btbcm_initialize`
   actually uses post-firmware. The kernel driver elides Reset
   entirely after LaunchRAM.

```
..hcd records..
{:delay, 3000},
:uart_flush_rx,             # Circuits.UART.flush(:receive)
{:delay, 200},
:uart_configure_resync,     # Circuits.UART.configure(115200, :hardware)
{:delay, 50},
:uart_break_wake,           # 20ms UART BREAK pulse
{:delay, 50},
%InformationalParameters.ReadBdAddr{}
```

Each new step has a dedicated `handle_continue/2` clause wrapped in
`try/catch` and logged at info — a failure must not crash the
transport GenServer (a crash here cascades into max_restarts and
ultimately a bootloop, see the StartupGuard discussion below).

`Circuits.UART.drain/1` is deliberately NOT used anywhere.
`tcdrain(3)` blocks until the TX buffer is empty, and on a freshly-
restarted BCM chip CTS may be temporarily de-asserted, in which
case drain blocks forever. The GenServer hosting the port stays
stuck in `handle_call`, every subsequent op times out, setup
fails, max_restarts fires, and the boot is unhealthy — observed
2026-05-22.

### Status on Pi 3 B+ as of 2026-05-22

These steps are necessary but **not yet sufficient** on this
hardware. After all four (flush + configure_resync + break_wake +
Read_BD_ADDR), the chip is still silent post-LaunchRAM. The
hypothesis under active investigation is **miniUART vs PL011**:
`nerves_system_rpi3` ships `dtoverlay=miniuart-bt` (BT on
`/dev/ttyS0` = BCM2835 mini UART; console on PL011). Raspberry Pi
OS does the opposite (BT on PL011 — higher quality, fewer quirks).
Pre-firmware works because Write_RAM/LaunchRAM frames are slow and
simple; post-firmware likely fails because the patched chip uses
timing or burst patterns the mini UART can't decode.

The above changes are kept because they are **structurally correct
mirrors of what Linux btbcm does**, plus belt-and-suspenders
defensive logging. They will be needed once the underlying UART
issue is resolved (most likely by switching BT to PL011).

**Upstream-PR intent:** file as one PR against blue_heron once the
spike confirms it works on real hardware. Title suggestion:
"Pi 3 B+ BCM4345C5 post-LaunchRAM recovery (mirrors Linux btbcm)".
Reference upstream issue #21 and the Feb 2026 pxp9 comment about
rpi3 not being fixed by #138.

### `BlueHeron.Observer` — LE scan driver (Central / Observer role)

**File:** `lib/blue_heron/observer.ex` (new)

Thin GenServer that subscribes to `BlueHeron.Registry`, waits for
`{:BLUETOOTH_EVENT_STATE, :HCI_STATE_WORKING}`, then issues
`SetScanParameters` + `SetScanEnable`. Fans out
`LEMeta.AdvertisingReport` events to a configured callback (one call
per device entry). Disables scan on `terminate/2` so the controller
doesn't keep scanning across supervisor restarts.

Parallels `BlueHeron.Peripheral` in shape. The HCI command structs
(`LEController.SetScanParameters`, `LEController.SetScanEnable`) and
the event decoder (`LEMeta.AdvertisingReport`) already exist upstream
— the only missing piece is the driver process. This module adds it.

**Upstream-PR intent:** file as a single PR against `blue-heron/blue_heron`
once the spike confirms it works on real hardware. README disclaims
Central + GATT-client — `Observer` is the smallest viable first step
toward Central, covering Observer role (scan-only) without touching
connect/disconnect or ATT.

### `BlueHeron.HCI.Event.LEMeta.AdvertisingReport` — pre-existing, no fork change

Worth noting since the upstream README says "Scan for and connect to
BLE peripheral devices (Central role)" is unimplemented: the decoder
for subevent `0x02` (with its `Device` sub-struct) is already present
at `lib/blue_heron/hci/events/le_meta/advertising_report.ex`. Auto-
dispatched via `BlueHeron.HCI.Event.LEMeta.list/0`, which scans
`Application.spec(:blue_heron, :modules)`. So `Observer` only needs to
subscribe; no dispatch-table edit required.

## Updating the vendored copy

1. In `~/src/blue_heron-fork` (or wherever your fork clone lives):
   `git fetch upstream && git rebase upstream/main` (or merge — pick one).
2. Force-push fork branch: `git push -f origin bluetooth-proxy-base`.
3. Re-vendor: from a clean fork checkout,
   `tar --exclude='.git' --exclude='.github' -cf - . | (cd deps_local && rm -rf blue_heron && mkdir blue_heron && tar -xf - -C blue_heron)`.
4. Update **Source provenance** table above (new SHAs, vendored-on
   date, new PRs applied).
5. Bump any obviously-affected entries in **Downstream additions**.
6. `mix deps.get && mix compile` (host) then
   `MIX_TARGET=rpi3 mix deps.compile blue_heron` to confirm the fork
   still builds clean for the spike target.
