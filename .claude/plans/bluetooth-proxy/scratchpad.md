# Scratchpad: bluetooth-proxy

## 2026-05-22 wind-down: BREAK + ReadBdAddr also fail. miniUART is the leading suspect.

After confirming configure_resync runs cleanly but doesn't unblock
the chip, this session also tried:

1. **Bumped post-LaunchRAM delay 1500ms → 3000ms** (top of Pi 3 B+'s
   documented 1.5–3s init range). No effect — `setup_complete = false`,
   stuck on Reset with same retry loop.
2. **Web-research round** (`brcm_patchram_plus.c` + Linux `hci_bcm.c`)
   uncovered two important facts:
   - Linux kernel's `btbcm_initialize` post-firmware sequence **skips
     HCI Reset entirely**. The Reset is replaced by Read_BD_ADDR as the
     "did the patch take" sync point. brcm_patchram_plus userspace DOES
     send Reset (with a 4s SIGALRM timeout), but the kernel doesn't.
   - blue_heron issue #21 + PR #138 explicitly note Pi 3 B+ rpi3 path
     is **known broken** (pxp9 confirmed Feb 2026: "this does not fix
     the old implementation of rpi3"). PR #138's hardware-validation
     list only covers Pi Zero 2W (CYW43436S) and Pi Zero W (CYW43438).
3. **BREAK + Read_BD_ADDR experiment.** Added:
   - `BlueHeron.HCI.Transport.UART.pulse_break/2` wrapper around
     `Circuits.UART.set_break/2` (BREAK + sleep + un-BREAK).
   - `:uart_break_wake` setup step (pulses 20ms BREAK, try/catch + log).
   - Replaced post-firmware `%Reset{}` with `%ReadBdAddr{}` as the
     sync point, mirroring Linux btbcm.
   
   Result: chip still silent. `current = %ReadBdAddr{}`, same retry
   loop, zero UART rx bytes post-LaunchRAM CC.

### Falsified hypotheses

| Hypothesis | Test | Outcome |
|------------|------|---------|
| Termios re-apply at same baud | `:uart_configure_resync` (115200, hardware) | Logs `ok`; chip still silent |
| Insufficient settle time | Delay 1500ms → 3000ms | No change |
| Reset specifically broken post-firmware | Swap Reset → ReadBdAddr | Also silent |
| Sleep mode | 20ms UART BREAK before sync command | Doesn't wake chip |
| UpdateBaudrate sync (Linux's `bcm_set_baudrate`) | Tried earlier | Also silent |

### Strongest remaining hypothesis: miniUART vs PL011

`nerves_system_rpi3` activates `dtoverlay=miniuart-bt` so PL011 (the
high-quality UART) can serve the console at GPIO 14/15, leaving BT on
`/dev/ttyS0` = BCM2835 mini UART. Raspberry Pi OS does the OPPOSITE:
BT on PL011, console on miniUART (or no console). The miniUART has
documented limitations:

- Clock tied to VPU frequency (can drift under load)
- Tiny 8-byte FIFO
- Flow-control quirks at higher loads
- Documented to misbehave with certain framing patterns

Pre-firmware works because Write_RAM/LaunchRAM are slow, simple frames
the miniUART can decode. **Post-firmware the patched chip likely uses
different timing/burst patterns the miniUART can't decode**, hence
zero bytes arriving (not garbage — the miniUART can't even sync).

### Next-session work (DO NOT execute without re-planning)

1. **Probe nerves_system_rpi3's actual UART config** — `cat /proc/cmdline`,
   `cat /sys/devices/platform/soc/*.serial/...`, `dmesg | grep uart` to
   confirm `/dev/ttyS0` is the miniUART and `/dev/ttyAMA0` is the PL011
   serial console.
2. **Plan the BT-on-PL011 swap.** Will need to:
   - Set `dtoverlay=disable-bt` (NOT `miniuart-bt`) in nerves_system_rpi3
     config.txt, OR override via custom dtoverlay in this project.
   - Update `config/target.exs` BT transport `device: "/dev/ttyAMA0"`
     (not `/dev/ttyS0`).
   - Remove `console=ttyAMA0,115200` from kernel cmdline (no serial
     console; SSH-only).
   - Build, upload, validate.
3. **Optionally file a blue_heron upstream issue** describing the Pi 3 B+
   gap with what we've ruled out, referencing pxp9's Feb 2026 comment
   on #21. Title suggestion: "Pi 3 B+ BCM4345C5 post-LaunchRAM
   silent — miniUART suspected".

### Code on disk at end of session (4 vendored blue_heron files)

- `deps_local/blue_heron/lib/blue_heron/hci/transport.ex`:
  - Restart-aware logging at top of `init/1` (kept from earlier session).
  - `:uart_flush_rx` handle_continue clause (kept).
  - `:uart_configure_resync` handle_continue clause (NEW, this session).
  - `:uart_break_wake` handle_continue clause (NEW, this session).
- `deps_local/blue_heron/lib/blue_heron/hci/transport/uart.ex`:
  - `flush/2` direction overload (kept).
  - `configure/2` passthrough (kept).
  - `pulse_break/2` wrapper (NEW, this session) — set_break(true) +
    sleep + set_break(false), GenServer.call timeout = duration_ms + 5s.
- `deps_local/blue_heron/lib/blue_heron/hci/transport/broadcom_init.ex`:
  - vendor_init_commands sequence: DownloadMinidriver → hcd records →
    delay 3000ms → flush_rx → delay 200ms → configure_resync →
    delay 50ms → break_wake → delay 50ms → ReadBdAddr (NOT Reset).
  - Moduledoc rewritten to describe the current sequence + reasoning.
- `deps_local/blue_heron/VENDORED.md`: downstream-additions section
  updated to match (flush + termios resync + BREAK + ReadBdAddr).

These changes are **structurally correct, defensible improvements**.
Even if they don't unblock the chip on this Pi 3 B+ miniUART config,
they're what Linux btbcm does in its post-firmware path, plus belt-
and-suspenders defensive steps for the host UART layer. They'll
likely be needed once the underlying UART issue (most likely the
PL011 swap) is sorted.

Host verification at end of session: `MIX_TARGET=rpi3 mix compile
--warnings-as-errors --force` clean (only pre-existing upstream
warnings). `mise run test` 315/0/3 (no regressions; blue_heron
isn't loaded on host).

## 2026-05-22 next-next session: configure_resync DOES NOT FIX IT

**Test result:** firmware `network-can` (UUID `9a2d16aa`) booted cleanly.
`init_attempt = 1` confirms transport is on its first init (no restart).
RingLogger shows the new sequence executed end-to-end:

```
... 235 × UART rx 7B: 0x040E04014CFC00 (Write_RAM CCs)
[debug] UART rx 7B: 0x040E04014EFC00         (LaunchRAM CC)
[info] UART flush RX: starting
[info] UART flush RX: ok
[info] UART configure resync: starting (115200 8N1 :hardware)
[info] UART configure resync: ok
[warn] Setup command timeout: %Reset{}       (repeats forever)
```

So `Circuits.UART.configure/2` at the SAME baud (115200) and SAME flow
control (`:hardware`) returns `:ok`, but the chip is STILL silent —
no bytes on the UART after the LaunchRAM CC. The post-firmware Reset
times out and retries forever. `setup_complete = false`,
`current = %Reset{}`, 19 remaining setup commands queued behind it.

**Falsified:** termios re-apply at same baud is NOT sufficient.

Likely interpretations:

- `Circuits.UART.configure/2` may not trigger a real `tcsetattr` when
  all values match the current termios; the kernel can short-circuit.
  Need to force a real termios change.
- Or termios re-apply isn't the issue; the chip is actually waiting
  on a UART block reset that Linux gets via `serdev` (which goes
  deeper than just `tty_set_termios`).
- Or the chip *is* at a different post-firmware baud despite Linux
  using `init_speed = 115200` for BCM4345C5.

Next experiments (smallest blast radius first):

1. **Wobble baud** — `configure(speed: 9600, flow_control: :hardware)`
   then `configure(speed: 115_200, flow_control: :hardware)`. Forces
   two real `tcsetattr` calls regardless of kernel short-circuiting.
   Same blast radius as the current `:uart_configure_resync` step;
   just a different opt list.
2. **Bump post-firmware delay to 3000–5000ms** — current 1500ms +
   200 + 50 may not be enough. Cheap to try.
3. **Probe alternate bauds** — try `configure(speed: 921600)` then
   send Reset. If Reset's CC arrives at 921600, chip auto-switched
   despite Linux's data. If still silent, try `3_000_000`.
4. **Close + open UART port** — drastic but unambiguous. `state.transport`
   pid changes; need to plumb the new pid back into state and
   re-register the framer. Last resort.

The current code is correct as a building block — `:uart_configure_resync`
runs cleanly, doesn't crash, doesn't wedge boot. Future experiments
can layer additional steps on top of it (or replace the configure
opts to wobble the baud).

## 2026-05-22 next session: termios resync staged (NOT yet hardware-tested)

After confirming UpdateBaudrate ALSO hangs (chip is unresponsive to any
post-LaunchRAM command), implemented scratchpad option 1: a
`:uart_configure_resync` step that calls `Circuits.UART.configure(speed:
115_200, flow_control: :hardware)` to trigger host-side termios re-apply
between flush and Reset.

Sequence on disk now:
```
..hcd records..
{:delay, 1500},
:uart_flush_rx,             # existing — flush(:receive)
{:delay, 200},
:uart_configure_resync,     # NEW — configure at same baud/flow ctl
{:delay, 50},
%ControllerAndBaseband.Reset{}
```

The previous UpdateBaudrate (`0xFC18`) experiment is REMOVED from the
sequence — that one was a confound (chip wouldn't respond to it
either). Clean test of the termios-resync hypothesis.

Implementation:
- `transport.ex`: new `handle_continue(:setup_transport, %{setup_commands:
  [:uart_configure_resync | rest]} = state)` clause. Try/catch wraps the
  `UART.configure/2` call, Logger.info on entry, Logger.info on `:ok` or
  Logger.warning on non-`:ok`, continue to next setup step regardless
  (same blast-radius rule as `:uart_flush_rx` — a crash here cascades
  into supervisor restart loops).
- `broadcom_init.ex`: `vendor_init_commands/2` emits the new step.
  Moduledoc rewritten to describe the new sequence + why
  UpdateBaudrate is not in it.
- `VENDORED.md`: drain+flush section renamed to "flush + termios
  resync", history rewritten.

Host verification all green: `mise run test` 315/0/3, `mix format`
clean, `mix credo --strict` 0 issues, `MIX_TARGET=rpi3 mix compile
--warnings-as-errors --force` clean (only pre-existing upstream
warnings remain).

What's needed next (hardware step):
1. `rm -rf priv/sendspin_player/host && MIX_TARGET=rpi3 mix firmware`.
2. `MIX_TARGET=rpi3 ./upload.sh 192.168.2.102`.
3. Wait for boot (~14s for BT subtree alive).
4. SSH probe (use `-tt … '<single-line>; System.halt(0)'` per
   [[nerves-ssh-iex-probing]] — but NEVER from an `until` loop, see
   [[never-halt-in-ssh-probes]]):
   - `BlueHeron.HCI.Transport.setup_complete?/0` — must return `true`.
   - `Process.alive?(Process.whereis(BlueHeron.Observer))` — must be `true`.
   - `RingLogger.get/0` and look for:
     - `UART configure resync: ok` log line (confirms the new step ran).
     - `BLE adv:` lines from Observer's `log_advertisement/1` callback
       (confirms scan turned on AND a nearby device advertised).
5. If all three: `Nerves.Runtime.validate_firmware/0` over SSH (rpi3
   does NOT auto-validate while StartupGuard is disabled). Then we have
   a validated working BT firmware.
6. If `setup_complete? = false` after >30s, dump
   `:sys.get_state(BlueHeron.HCI.Transport).current` to see where it
   wedged. Likely candidates:
   - Reset still hangs → next experiment: `Circuits.UART.close/1` +
     re-open (scratchpad option 2).
   - configure_resync logged `:caught` → the call itself crashed; need
     to investigate why on actual hardware.
   - configure_resync logged `non-ok` → returned something other than
     `:ok`; surface in next iteration.

## 2026-05-22 late session: UpdateBaudrate also hangs

After adding `%VendorSpecific.UpdateBaudrate{baudrate: 115_200}` after
the flush_rx and before Reset (in `broadcom_init.ex`), AND increasing
the post-LaunchRAM delay to 1500ms, the chip STILL doesn't respond.
Now stuck on UpdateBaudrate (`0xFC18`) instead of Reset. So it's not
just Reset — the chip doesn't respond to ANY post-LaunchRAM HCI
command, regardless of how long we wait.

Empirical conclusions:

- Firmware download works (235 BCM4345C5.hcd records, all CCs received).
- UART flush(:receive) succeeds.
- 1500ms delay after LaunchRAM doesn't help.
- Chip post-firmware sends ZERO bytes back even when host sends 0xFC18
  or 0x0C03.

Likely cause: the chip's UART block enters a state post-LaunchRAM that
requires a host-side termios re-apply (Linux's `host_set_baudrate`
calls `serdev_device_set_baudrate` → `tty_set_termios`, which does
more than just set baud — it drops/re-arms the FIFOs and may toggle
RTS/DTR). `Circuits.UART.flush(:receive)` only clears the kernel RX
buffer; it does NOT re-apply termios.

Next session should try (in order, smallest blast radius first):

1. **Add a `:uart_configure_resync` step** that calls
   `Circuits.UART.configure(uart_pid, speed: 115_200, flow_control: :hardware)`
   between the firmware-load delay and the post-firmware Reset.
   Same baud as before — purely to trigger termios re-apply. The
   earlier observed "wedge" from this exact call was almost certainly
   the zombie SSH poll loop (see warning below), NOT configure
   itself. Try with `try/catch` + Logger.info on entry/exit to
   confirm.

2. If that doesn't work: **`Circuits.UART.close/1` + `Circuits.UART.open/3`**
   on the same port to fully reset the framer state and termios.
   Drastic but well-isolated.

3. **Check if chip auto-switched baud**: try `UART.configure(speed: 921600)`
   or `Circuits.UART.configure(speed: 3_000_000)` then send Reset.
   This is a guess (Linux's `bcm4345C5_device_data` doesn't set
   `no_uart_clock_set` but also doesn't explicitly say chip switches
   speed). Test cheaply by binary-searching common bauds.

Reference: full Linux `bcm_setup` sequence
([linux/drivers/bluetooth/hci_bcm.c](https://github.com/torvalds/linux/blob/master/drivers/bluetooth/hci_bcm.c)):

```
btbcm_initialize → loads firmware (= our hcd_commands)
if (speed) host_set_baudrate(hu, init_speed)   ← we don't do this
if (oper_speed) bcm_set_baudrate + host_set_baudrate  ← we skip operational bump
btbcm_finalize → btbcm_reset                    ← we try this and it hangs
```

The missing step is the **post-firmware `host_set_baudrate`** even
when the baud isn't changing. That's the experiment to run.

## 2026-05-22 clean-state findings (after zombie removed)

After killing the zombie SSH poll loop (see big warning below) and a hard
Pi power-cycle, re-uploaded `universal_proxy-bt-spike-1.fw` (UUID
`d2994124`, `shy-motion` — built with `universal-proxy-dev` SSH key
baked in, devkey for SSH access). Booted clean (14s to BT subtree
alive). RingLogger shows:

```
[info] Loading Broadcom firmware: BCM4345C5.hcd (235 records)
[info] UART flush RX: starting
[info] UART flush RX: ok
[warn] Setup command timeout: %Reset{}   (← repeats)
```

So the picture is now clear:

1. **First Reset (pre-firmware) works** — chip in ROM state responds.
2. **ReadLocalVersion works** — `manufacturer_name: 15` (Broadcom),
   `lmp_pal_subversion: 24857 = 0x6119`. This maps to **BCM4345C5.hcd**
   (not BCM4345C0 as earlier scratchpad notes assumed — the Pi 3 B+
   chip is BCM4345C5, with LMP subversion 0x6119, per
   `BlueHeron.HCI.Transport.UART.FirmwareLoader.@firmware_table`).
3. **Vendor init runs** — 235 raw_hci firmware records all complete.
4. **Our `:uart_flush_rx` patch runs and reports `:ok`** — flush
   succeeded.
5. **Post-LaunchRAM Reset still times out** — the original symptom is
   NOT fixed by RX-only flush. The chip really does need more than
   just a buffer flush after `LaunchRAM`.

Next experiments to try (one per iteration, smallest delta first):

A. **Longer delay** (currently 250ms post-LaunchRAM + flush + 100ms
   pre-Reset). Try 1500ms total. Cheapest possible change. If the
   chip just needs more time, this fixes it.
B. **Issue `UpdateBaudrate` (`0xFC18`)** via raw_hci before Reset.
   Linux's `bcm_set_baudrate` writes target baud to the chip via this
   command; even at the same baud, the chip may need this trigger to
   commit to its post-firmware state. blue_heron already has the
   `VendorSpecific.UpdateBaudrate` command struct.
C. **Close + reopen UART port** (drop and re-`UART.open`). Drastic;
   forces a fresh kernel-side state. Last resort because it changes
   the port pid.

The current `transport.ex` patch already has the framework for option
A and B (just a setup_command list edit). Option C needs more work.

## 🚨 IMPORTANT: 2026-05-22 zombie SSH poll loop corrupted prior findings

I (Claude) left an `until ssh ... 'IO.puts(...); System.halt(0)' ; do sleep
2; done` poll loop running in the background early on 2026-05-22, then
forgot about it. `System.halt(0)` halts BEAM; on Nerves erlinit reboots
the device. So every time the Pi finished booting, the zombie's next
iteration immediately rebooted it. Visible symptom from device console:
"Erlang has closed" at ~7-8s consistently, indistinguishable from a
real boot crash.

This poisoned hours of debugging. **Re-verify these findings before
relying on them — they may have been the zombie, not the firmware:**

- "Drain bootlooped the Pi" → maybe not; the symptom was actually the
  zombie's halt loop, not a `Circuits.UART.drain/1` hang. The
  *reasoning* about why drain is risky (CTS de-assertion blocking
  tcdrain) is still sound and worth avoiding, but the empirical
  validation was confounded.
- "StartupGuard validated a bootloop firmware" → also suspect. The
  "bootloop" may have been the zombie. The firmware probably booted
  fine and validated correctly; the apparent re-boot loop after
  validation was zombie-driven.
- "Homestar SSH key in nerves_ssh `authorized_keys` causes boot loop" →
  almost certainly false. The key has nothing to do with boot
  stability. Confounded with the zombie.

Verified safe findings (not affected by the zombie):
- `RingLogger.tail/1` truncates after `System.halt/0` (RingLogger is
  async). Still use `RingLogger.get/0`.
- The chipset is BCM4345/6 (BCM4345C0.hcd via blue_heron's
  `FirmwareLoader` map).
- `/dev/ttyS0` is the right BT UART path on rpi3 with `dtoverlay=miniuart-bt`.

Memory now records two lessons that came out of this:
[[never-halt-in-ssh-probes]] and [[nerves-ssh-iex-probing]] (updated).

## Dead Ends (DO NOT RETRY)

- **`Circuits.UART.drain/1` in the post-LaunchRAM resync step
  bootlooped the Pi 3 B+ (2026-05-22).** `tcdrain(3)` blocks until the
  TX buffer is empty, and on a freshly-restarted BCM chip CTS may be
  temporarily de-asserted, so drain blocks indefinitely. Even with
  try/catch on the caller side, the underlying `BlueHeron.HCI.Transport.
  UART` GenServer stays stuck in handle_call and all subsequent ops on
  that pid time out → setup fails → max_restarts → boot is unhealthy.
  Worse: the BT-side crash didn't actually take down the rest of the
  app — web UI + SSH came up "just enough" that
  `Nerves.Runtime.StartupGuard` VALIDATED the bootloop firmware before
  it crash-looped, locking the Pi into a state where SD-card reflash
  was the only recovery. **Use `Circuits.UART.flush/2` with `:receive`
  only — never `:drain`.**

- **Trusting `startup_guard_enabled: true` while iterating on BT init
  is unsafe (2026-05-22).** The guard validates the firmware once the
  whole supervision tree has come up. If BT init crashes its own
  subtree but the rest of the app boots, the guard validates a
  bootloop firmware. Set `startup_guard_enabled: false` for rpi3
  while iterating; manually validate via SSH after confirming
  `BlueHeron.HCI.Transport.setup_complete?/0` returns true. Done in
  `config/target.exs`.


- **Plain `ssh` + heredoc into nerves_ssh IEx hangs.** nerves_ssh on the Pi
  doesn't cleanly process stdin-fed multi-line IEx input without a PTY;
  the SSH never sees EOF and exits with code 144 after 2+ min.
  Workaround that works: `ssh -tt … '<single-line IEx>; System.halt(0)'`
  with `-tt` to force PTY allocation and `System.halt(0)` to make the
  remote IEx terminate the SSH session cleanly. Don't bother with
  heredoc-style probes.

- **`RingLogger.tail/1` over SSH-eval'd IEx truncates / cuts on
  `System.halt(0)`.** The tail function writes through the Logger
  group leader which is async, so the halt races and chops the
  output. Use `RingLogger.get/0` which returns entries as data and
  iterate explicitly with `IO.puts/1` before `System.halt(0)`. The
  entry shape is a **map** (`%{message:, level:, timestamp:, metadata:}`),
  NOT the older `{level, {Logger, msg, ts, md}}` tuple.

- **`flow_control: :none` on `/dev/ttyS0` rpi3 BT UART hung
  StartupGuard.** Tried as Risk-1 mitigation when the working-but-
  half-broken `:hardware` config produced a post-LaunchRAM Reset
  timeout. With `:none`, the new firmware came up but never reached
  `Nerves.Runtime.StartupGuard.run/1`'s "all applications started"
  state — the user power-cycled and the bootloader auto-reverted.
  Concrete dead-end **for this Pi 3 B+ BCM4345/6 chip**; if you
  retry `:none`, expect a forced revert. Root cause unconfirmed but
  most likely the chip *does* respect HW flow control, so disabling
  it makes the UART misframe in some way that wedges
  `BlueHeron.HCI.Transport`'s GenServer init.

## Decisions

- **A2 (2026-05-21): cherry-pick #138 + #139, in that order.**
  Reason: `/lib/firmware/brcm/` on 192.168.2.102 contains only WiFi
  (`brcmfmac*`) blobs — no `.hcd` files of any kind. So both the
  vendor-HCI-firmware-load machinery (#138) *and* the bundled `.hcd`
  blobs (#139) are required for the radio to come up.

## A1 findings (probed 2026-05-21 from dev container)

- **Chipset is BCM4345/6, not BCM43438** as the memory note claimed.
  dmesg: `brcmfmac: brcmf_fw_alloc_request: using brcm/brcmfmac43455-sdio
  for chip BCM4345/6` + `Firmware: BCM4345/6 wl0: Aug 29 2023... version
  7.45.265 (28bca26 CY) FWID 01-b677b91b`. Pi 3 B+ is BCM43455 internally;
  for blue_heron's vendor-HCI path that maps to `BCM4345C0.hcd` per
  PR #139's mapping table. Memory note `pi_hardware_testbed.md` could be
  updated post-spike but it's not load-bearing for this plan.
- **`/lib/firmware/brcm/` has 60+ `brcmfmac*` files** (WiFi firmware,
  CLM blobs, per-board variants) and **zero `.hcd` files**. nerves_system_rpi3
  ships BT firmware blobs nowhere on the rootfs — they must come from
  blue_heron #139.
- **`/dev/ttyS0` present** (mode 8576 chardev, major 6 / minor 1088).
  `/dev/serial1` is **absent** (`:enoent`).
  `/dev/ttyAMA0` is the **serial console** (`console=ttyAMA0,115200`
  in kernel cmdline) — do NOT use it for BT on rpi3 / nerves.
- **dmesg has no `hci`/`bluetooth` lines.** Only WiFi (brcmfmac)
  initialisation. Confirms: kernel does no BT bring-up; blue_heron
  owns the whole HCI lifecycle from userspace via `/dev/ttyS0`.

## Open Questions

- **Post-`LaunchRAM` HCI Reset hang on Pi 3 B+ (BCM4345/6).** Reset
  (opcode `0x0C03`) is sent 250 ms after `LaunchRAM` (opcode `0xFC4E`)
  per `BlueHeron.HCI.Transport.BroadcomInit.vendor_init_commands/2`,
  and never gets a response. Three candidate fixes to investigate:
  1. Longer post-LaunchRAM delay (>>250 ms). Cheap to try.
  2. `BroadcomInit` is missing an `UpdateBaudrate` step. Linux btbcm
     issues UpdateBaudrate twice — once to bump baud before firmware
     load (to speed up the ~63 KB transfer of BCM4345C0.hcd), and
     again after LaunchRAM. blue_heron's vendored sequence has the
     command module (`update_baudrate.ex`) but `BroadcomInit` doesn't
     reference it. The chip may be at a higher baud post-LaunchRAM
     and our 115200 host UART is now mismatched.
  3. The chip needs a USRT-side reset / config-pin toggle that
     blue_heron isn't doing (less likely on rpi3 where the BT chip
     just hangs off UART).

- **Stage E2 partial success worth keeping.** Even broken, on the
  `:hardware` build: `UniversalProxy.Bluetooth` PID alive, child
  `BlueHeron.Observer` alive, full `BlueHeron.Supervisor` tree up
  (Registry, HCI.Transport, Peripheral, SMP, Broadcaster, ACLBuffer,
  GATT). So D1/D2 wiring is correct end-to-end. Only the vendor-
  init sequence inside blue_heron is broken.

## Investigation: post-LaunchRAM Reset hang on BCM4345C0

The Linux kernel `btbcm`/`hci_bcm` drivers do an explicit
`host_set_baudrate(hu, init_speed)` between firmware download (`LaunchRAM`)
and the first post-firmware HCI Reset — even if the speed is the same
as during download. blue_heron's vendored `BroadcomInit.vendor_init_commands/2`
skips this resync and goes straight to `Reset` after a 250 ms delay.
On the Pi 3 B+ BCM4345C0 chip, that omission causes Reset to never get
a response. This finding came from a focused research subagent —
see plan Risk 1 + the agent's report in conversation history.

PR #138's author tested on RPi Zero 2W (CYW43436S) whose firmware is
much smaller and apparently doesn't need this resync. So #138 ships
with a path that's broken on the chip in this testbed.

### Naive resync attempt (2026-05-21) — DOES NOT WORK YET

Patched the vendored fork to add a `{:uart_configure, opts}` setup-step
+ `uart_opts` plumbing through `BlueHeron.HCI.Transport` state, with
`BroadcomInit.vendor_init_commands/3` inserting
`[{:uart_configure, opts}, {:delay, 100}]` before the post-LaunchRAM
`Reset{}`. Even with `try/rescue/catch` wrapping the
`BlueHeron.HCI.Transport.UART.configure/2` call and `Logger.info` on
both entry and result, the patched firmware **hung the boot** —
SSH never came up, Pi had to be power-cycled.

What's still mysterious:

- After the user manually checked on a previous patched boot,
  `setup_complete? = false`, `current = %Reset{}` (the FIRST one,
  19/20 setup commands pending). No `resync`-tagged log entries
  appeared in `RingLogger.get()`. So either the `{:uart_configure, _}`
  handle_continue clause never matched, OR the resync ran and the
  transport restarted from scratch — losing the log lines.
- `vendor_init_commands` arities `[1, 2, 3]` exported on the patched
  Pi → the new arity-3 IS in the firmware.
- `state.uart_opts = [device: "/dev/ttyS0", speed: 115200, flow_control:
  :hardware]` confirmed in running state.
- So the function call path *should* have inserted the resync step into
  setup_commands. But no log of it firing.
- The second, hardened patch (with try/catch + logger) ALSO hung the
  boot, so even with crash-safety the resync seems to wedge something
  earlier in the OTP supervision tree than I'd expect.

Hypotheses worth testing next time, in order:

1. **The patched module path may not be hit on the SECOND restart.**
   First restart: chip is fresh from power-on, firmware load happens,
   resync ran (or tried to), Reset times out, transport supervisor
   restarts the GenServer after max_restarts. Second restart: fresh
   `@default_setup_commands`, first `Reset` sent — but the CHIP is now
   in a half-initialised post-LaunchRAM state and won't respond to
   Reset at all. Add a `Logger.info("HCI Transport init: starting")`
   at the very top of `init/1` so we can see restart count in the log.
2. **The vendor_init prepend may be losing the resync step.** Check
   the actual `setup_commands` list contents (via `:sys.get_state`)
   *between* firmware-load and post-firmware Reset. Need to schedule a
   timer that dumps state mid-setup.
3. **`Circuits.UART.configure/2` may be blocking the UART port driver
   in a way that prevents the next `send_command` from going through.**
   Test by replacing `UART.configure/2` with a no-op (just `:timer.sleep(500)`
   in the {:uart_configure} step) and see whether boot completes and
   scan turns on. If that works, the issue is `configure`-specific and
   maybe we should `Circuits.UART.close + open` instead.
4. **Move the `Logger.info` to the calling site** in `maybe_vendor_init`
   so we can see in the log whether `vendor_init_commands/3` is
   actually being invoked with `uart_opts`, vs `vendor_init_commands/2`
   silently dropping back to no-resync.

The safer way forward is probably (3): swap UART.configure for a much
simpler "do nothing, just wait longer" first to confirm the timing
hypothesis. Only then introduce UART reconfiguration.

## Iteration safety lessons (2026-05-21)

Multiple flash-and-power-cycle cycles tonight. What I'd do differently:

- **Don't make BT init changes that can wedge `:blue_heron`'s
  `Application.start/2` without first proving the rest of the OTP tree
  starts.** If blue_heron blocks app start, `nerves_ssh` never comes
  up, the device looks bricked.
- **Use Tidewave or similar runtime probe** to confirm whether
  `{:uart_configure, _}` is reachable BEFORE flashing. We never proved
  the new handle_continue clause was wired correctly end-to-end.
- **Add a startup log line at the very top of HCI.Transport.init/1**
  so RingLogger can show restart count and timing on the next attempt.
- **Always set `nerves_fw_validation` mode to manual** during BT
  bring-up so a half-working firmware doesn't auto-validate and pin
  the bad slot. (Today both `corn-armor` and `dice-toy` builds had to
  be power-cycled past; the user lost a third firmware to auto-revert.)
- **Prefer SMALL, isolated changes per flash.** Tonight's patch
  combined: (a) `uart_opts` in state, (b) new `{:uart_configure, _}`
  handle_continue, (c) BroadcomInit arity-3 signature, (d) post-
  LaunchRAM resync. With even minimal try/catch coverage, *something*
  in that bundle still wedged boot. Smaller per-flash deltas would
  bisect faster.

## 2026-05-22 iteration: drain+flush attempt → bootloop → flush-RX-only pivot

What I tried (after research subagent reviewed Linux `btbcm`/`hci_bcm`):

1. Restart-aware logging at top of `HCI.Transport.init/1`
   (`:persistent_term` counter survives GenServer crashes but not VM
   restarts) — kept.
2. Replaced the previous `{:uart_configure, opts}` resync attempt
   with `:uart_drain_flush`: call `Circuits.UART.drain/1` then
   `Circuits.UART.flush/2(:both)` between the 250ms post-LaunchRAM
   delay and the Reset. Try/catch around both, log on failure.
3. Disabled `nerves_fw_validation`? NO — and that was the critical
   mistake. Built firmware (UUID `180ca3a7-cd5d-5648-9fa4-c6778d668db0`,
   `average-anger`), flashed via `./upload.sh`.

What happened:

- Firmware booted briefly long enough for `StartupGuard.run/1` to
  validate it. After validation, BT init still crashed (drain hung).
  Result: Pi entered a state where boot comes up, BT-related processes
  crash-loop, and the bootloader can no longer auto-revert. **User
  had to SD-card reflash to recover.**
- One screenshot captured mid-cycle showed `framing: STALLED` warnings
  in the system log. Those are NOT bugs — the framer logs partial
  state every time `remove_framing` is called with insufficient data,
  which happens naturally with byte-by-byte UART arrival. The framer
  parses the full frame once enough bytes accumulate.

What's now on disk (next firmware will pick these up):

- `transport.ex`: clause renamed `:uart_drain_flush` → `:uart_flush_rx`,
  body calls `BlueHeron.HCI.Transport.UART.flush(transport, :receive)`
  only. Drain is GONE.
- `transport/broadcom_init.ex`: emits `:uart_flush_rx` step (matching).
- `transport/uart.ex`: `flush/2` overload (`:receive`/`:transmit`/`:both`,
  default `:both` preserves backwards compat for the existing
  setup-command retry path). No `drain/1` wrapper.
- `config/target.exs`: `startup_guard_enabled: Mix.target() != :rpi3`.
  Future firmwares on rpi3 will NOT auto-validate. Manual validation
  required via `Nerves.Runtime.validate_firmware/0` over SSH after
  confirming `BlueHeron.HCI.Transport.setup_complete?/0` returns true.
- `VENDORED.md`: downstream-additions section rewritten to describe
  flush-RX (not drain+flush). Includes "do NOT call drain" warning.

Verification on host: `mise run test` 315/0/3, `mix format` clean,
`MIX_TARGET=rpi3 mix compile --warnings-as-errors --force` clean
(only pre-existing upstream type-system warnings remain).

What to do next session, assuming Pi has been SD-card reflashed:

1. `rm -rf priv/sendspin_player/host && MIX_TARGET=rpi3 mix firmware`.
2. `MIX_TARGET=rpi3 ./upload.sh 192.168.2.102`.
3. Wait for boot. SSH probe:
   - `BlueHeron.HCI.Transport.setup_complete?/0` — must be `true`.
   - `Process.alive?(Process.whereis(BlueHeron.Observer))` — must be `true`.
   - `RingLogger.get/0` — look for `BLE adv:` lines (Observer's
     `log_advertisement/1` callback). At least one phone or sensor
     nearby should advertise.
4. If all three: `Nerves.Runtime.validate_firmware/0`. THEN you have a
   validated working BT firmware.
5. If any fails: the bootloader will revert on next power cycle.
   Re-iterate. Do NOT validate a half-working firmware.

If flush-RX is still not enough (Reset still times out), next
hypothesis is "longer post-LaunchRAM delay" (250ms → 1500ms). After
that: actually issue `0xFC18 UpdateBaudrate` via HCI to force the
chip to commit to 115200 (Linux does this via the `bcm_set_baudrate`
+ `host_set_baudrate` pair). For that, do NOT call
`Circuits.UART.configure` from the transport GenServer — dispatch via
a one-shot Task that owns the configure call (avoids the original
re-entrancy wedge).

## Handoff

- Branch: main (no commits yet — code staged on working tree)
- Plan: .claude/plans/bluetooth-proxy/plan.md
- Pi state (2026-05-21 ~21:55): power-cycled by user after the
  hardened patched firmware (`dice-toy`) failed to come up. After
  power-cycle the Pi returned on UUID `ba4f9f2f` — NOT one of the
  four firmwares I flashed tonight (1fe1782e, 3157a4c7, 24119f3e,
  2eeb47c7), so this is likely an older pre-existing slot (probably
  the original 0.4.0 no-BT build the user had before this spike
  started). Bootloader behaviour worked as intended — unvalidated bad
  firmware did not survive the power cycle.
- Code on disk: all Stage A–D changes intact (correct, host-green).
  Stage C/D adds:
  - `lib/universal_proxy/bluetooth.ex` (Phase-0 rpi3-only Supervisor)
  - `lib/universal_proxy/application.ex` target_children wire
  - `config/target.exs` `:blue_heron` transport config (rpi3-only)
  - `deps_local/blue_heron/lib/blue_heron/observer.ex` (LE scan driver)
  - `deps_local/blue_heron/lib/blue_heron/hci/transport.ex` —
    `uart_opts` in state + `{:uart_configure, _}` handle_continue
    clause with try/catch + per-step Logger.info
  - `deps_local/blue_heron/lib/blue_heron/hci/transport/broadcom_init.ex`
    — arity-3 signature taking `uart_opts`, post-LaunchRAM resync
    `{:uart_configure, opts}` step inserted before Reset
  - `deps_local/blue_heron/VENDORED.md`
  - `mix.exs` (blue_heron path dep, targets-restricted)
- Tests: `mise run test` 315 pass, 0 fail, on host. `mix credo --strict`
  clean. Format clean.
- Hardware: blue_heron supervision tree starts under
  `UniversalProxy.Bluetooth` on rpi3; firmware download (`Write_RAM` +
  `LaunchRAM`) succeeds; everything past that is blocked on the
  resync issue described above.

- Next session: pick a hypothesis from the list above, start by adding
  a `Logger.info("HCI Transport init: starting (attempt #{...})")` at
  the top of `BlueHeron.HCI.Transport.init/1` so restart-vs-fresh-boot
  can be told apart in RingLogger. Then try hypothesis (3) — replace
  UART.configure call with a sleep, see if boot completes and scan
  turns on.
