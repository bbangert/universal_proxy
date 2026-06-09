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

### FirmwareLoader: LMP `0x6119` is BCM4345C0, not C5 (the real Pi 3 B+ fix)

**File:** `lib/blue_heron/hci/transport/uart/firmware_loader.ex`

Upstream blue_heron's `@firmware_table` mapped LMP subversion
`0x6119 => "BCM4345C5.hcd"`. **This is wrong.** `0x6119` is the
`BCM4345C0` (Pi 3 B+ / 3 A+); `BCM4345C5` is `0x6606` (Pi 400 / CM4).
Verified three ways:

- Linux kernel `drivers/bluetooth/btbcm.c` `bcm_uart_subver_table`:
  `{ 0x6119, "BCM4345C0" }`, `{ 0x6606, "BCM4345C5" }`. The kernel
  matches on subver alone (no rev disambiguation) and builds the
  filename directly: `brcm/BCM4345C0.hcd`.
- `RPi-Distro/bluez-firmware` symlinks the Pi 3 B+ (and 3 A+) BT
  firmware to `BCM4345C0.hcd`; C5 is only for Pi 400 / CM4.
- This repo's own Nerves build tree:
  `deps/nerves_system_br/package/rpi-distro-bluez-firmware/rpi-distro-bluez-firmware.mk`
  symlinks `BCM4345C0.raspberrypi,3-model-b-plus.hcd → BCM4345C0.hcd`.

Why it presents as "silent after LaunchRAM": loading the C5 `.hcd`
onto C0 silicon still lets every `Write_RAM` (`0xFC4C`) and the final
`LaunchRAM` (`0xFC4E`) return `Command Complete status 0` (RAM writes
always ack), but the chip then relaunches into a wrong-variant image
and emits zero bytes for every subsequent HCI command. This burned
weeks of UART-layer debugging (see scratchpad) before the firmware
mapping was checked.

Fix: `0x6119 => "BCM4345C0.hcd"`, and add the correct `0x6606 =>
"BCM4345C5.hcd"`.

**Upstream-PR intent:** straightforward table correction against
blue_heron, citing the kernel `bcm_uart_subver_table`. Likely fixes
the long-standing "rpi3 post-firmware silent" reports (issue #21 /
PR #138 discussion, pxp9 Feb 2026).

### `UART.Framing.remove_framing/2` — drop per-frame STALLED warning

**File:** `lib/blue_heron/hci/transport/uart/framing.ex`

Upstream logged `:logger.warning(%{msg: "framing: STALLED", ...})` every
time `remove_framing/2` was called with a partial frame in the buffer.
That is the *normal* case for byte-by-byte UART arrival — the framer
accumulates bytes until a full HCI packet is present. On the receive
hot path under a continuous BLE advertisement stream it fires per chunk,
synchronously, inside the `Circuits.UART` GenServer's message loop. The
`Logger` call (made worse by a `Phoenix.LiveDashboard` PubSub backend
fanning out every log) can't keep up; the UART process's mailbox backs
up into the **millions** of messages (~150 MB) and pegs a CPU core, so
load climbs and memory leaks. Because it's `:warning`, raising the
`Logger` level to `:info` does not suppress it. Removed the log entirely
(partial-frame is not an error). **Upstream-PR intent:** delete or
demote to `:debug` upstream.

### `BroadcomInit` post-LaunchRAM sequence (Linux btbcm-equivalent)

**Files:**
- `lib/blue_heron/hci/transport/broadcom_init.ex` (post-firmware sequence)
- `lib/blue_heron/hci/transport.ex` (new `:uart_flush_rx`,
  `:uart_configure_resync`, and `:uart_break_wake` setup steps,
  plus restart-aware `Logger.info` at top of `init/1` so RingLogger
  can distinguish fresh boot from supervisor restart)
- `lib/blue_heron/hci/transport/uart.ex` (`flush/2` direction
  overload, `configure/2` passthrough, and `pulse_break/2`
  wrapper around `Circuits.UART.set_break/2`)

The default post-firmware sequence mirrors the Linux `btbcm` finalize
path: settle, flush host RX, then HCI Reset.

```
..hcd records..
{:delay, 250},              # Linux btbcm_patchram: 250ms after LaunchRAM
:uart_flush_rx,             # Circuits.UART.flush(:receive)
%ControllerAndBaseband.Reset{},   # first cmd against patched firmware
{:delay, 100}               # Linux btbcm_reset: 100ms after Reset
```

`:uart_configure_resync` (termios re-apply) and `:uart_break_wake`
(20ms UART BREAK) were added while misdiagnosing the wrong-firmware
silence above. They are **no longer in the default sequence** but
their `handle_continue/2` clauses are retained as opt-in helpers for
controllers that genuinely need a termios re-apply or a sleep-wake
BREAK. Each clause is wrapped in `try/catch` and logged at info — a
failure must not crash the transport GenServer (a crash here cascades
into max_restarts and ultimately a bootloop; see StartupGuard
discussion below).

`Circuits.UART.drain/1` is deliberately NOT used anywhere.
`tcdrain(3)` blocks until the TX buffer is empty, and on a freshly-
restarted BCM chip CTS may be temporarily de-asserted, in which
case drain blocks forever. The GenServer hosting the port stays
stuck in `handle_call`, every subsequent op times out, setup
fails, max_restarts fires, and the boot is unhealthy — observed
2026-05-22.

**Upstream-PR intent:** the 250ms/Reset/100ms sequence and the RX
flush are safe to upstream alongside the FirmwareLoader fix. The
configure_resync / break_wake helpers can stay downstream until a
controller is found that needs them.

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
