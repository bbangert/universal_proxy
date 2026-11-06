# milkdrop_renderer

Full-screen [projectM](https://github.com/projectM-visualizer/projectm)
(MilkDrop presets) on the HDMI output, for the "MilkDrop" TV display mode.
A port binary owned by `UniversalProxy.Display.MilkDrop`: it takes the
display over from Emerge (DRM master handover), renders presets driven by
the HDMI Sendspin player's PCM tap, and gives the display back.

Targets: **rpi3** (Mesa vc4, GLES 2.0 through our projectM fork's ES2
backend), **rpi4** and **rpi5** (Mesa v3d, the fork's unchanged GLES 3
path). The host builds only the GL-free core and its unit tests.

## Command line

```
milkdrop_renderer --mode 1280x720@60 --pack-dir DIR --ladder 640x360,480x270
                  --rotate-s 20 --skip-file PATH
                  [--high-frequency] [--locked FILE] [--pcm-ring PATH]
```

| Option | Meaning |
|---|---|
| `--mode WxH[@Hz]` | The CRTC mode to present on. Keep Emerge's mode (1280x720@60): a different pixel clock under a running HDMI audio stream leaves vc4's N/CTS stale. The mode the CRTC scans out when the renderer starts (Emerge's) is used when it fits (same size, progressive, within 0.5 Hz); else the closest offered mode that does (1280x720 comes at 60 and 59.94). |
| `--pack-dir DIR` | The extracted preset pack (layout below). |
| `--ladder WxH,...` | Internal render resolutions, highest first, each smaller than the last. The renderer steps down per preset and skips a preset past the last rung. |
| `--rotate-s N` | Auto-rotation interval, seconds. |
| `--skip-file PATH` | Presets never to load: one preset id per line. A missing file is an empty list. |
| `--high-frequency` | Include `high_frequency/` presets (photosensitivity; off by default). |
| `--locked FILE` | Start locked on this preset id. Ignored (unlocked) if it isn't eligible. |
| `--pcm-ring PATH` | The PCM tap ring (`/run/up-pcm-<client_id>`). Without it, or while it has no fresh audio, presets get silence. |

Tuning and check knobs (not passed by the BEAM): `--card DEV`
(`/dev/dri/card0`), `--blend S` (soft-cut length, 0.5), `--min-fps F` (the
floor a preset must hold, 19), `--interval N` (vblanks per frame: 2 on
GLES2 builds, else 1), `--seed N`, `--av-offset-ms N` (added to the PCM
target time, for A/V tuning), `--master-timeout-ms N` (2000), `--mesh WxH`
(48x36), `--stats-s N` (10), and `--headless-frames N` / `--simulate-kms` /
`--test-tone` (see "Checks").

A bad command line prints `error` (`reason: "usage"`) and `exiting`
events and exits 2.

## Protocol

One JSON object per line in each direction. stdout carries protocol lines
only, each under 4096 bytes (an oversize line is replaced by an
`error`/`oversize_line` event). The renderer's own log lines go to the
original stderr; driver output on fd 2 is captured (see "Failure
detection"). stdin EOF means exit, in every state.

### Commands (stdin)

| Command | Effect |
|---|---|
| `{"cmd":"take"}` | Poll `drmSetMaster` for up to 2 s, show the prepared frame with SetCrtc in the chosen mode, start presenting → `presenting`. On timeout: `error` `master_timeout`, still prepared. |
| `{"cmd":"release"}` | Stop flipping (a pending flip lands first), `drmModeCloseFB` the front buffer so it stays scanned out (never RmFB the scanout framebuffer), drop master, **keep card0 open** → `released`. Also acked when not presenting. |
| `{"cmd":"exit"}` | Release if presenting → `exiting` (`requested`), close everything, exit 0. |
| `{"cmd":"next"}` / `{"cmd":"prev"}` | Forward / back in the history (a new random pick at its end; `prev` with nothing earlier does nothing). A lock stays on and moves to the new preset. |
| `{"cmd":"lock"}` / `{"cmd":"unlock"}` | Hold / resume rotation on the current preset. |
| `{"cmd":"set_rotate","value":N}` | Rotation interval in seconds (1..3600). |
| `{"cmd":"set_high_frequency","value":B}` | Include `high_frequency/` presets; turning it off while one shows switches away at once. |

A malformed or unknown command gives `error` with `reason: "bad_command"`.

### Events (stdout)

| Event | Fields |
|---|---|
| `prepared` | `mode` (the chosen mode, e.g. `1280x720@60`), `gl_renderer`, `gl_version`, `gles2`, `presets` (eligible count), `crtc_mode_valid` and `crtc_mode` (only when valid): what the CRTC scanned out when the card was opened. GL is up, the first preset warmed and a frame rendered; not master. |
| `presenting` | `modeset` (true = the mode set differs from the last one scanned out before the handover: the CRTC's at take if it still had one, else the one in `prepared`), `master_ms`, `crtc_lit` (the CRTC still had a mode at take; Emerge's stop detaches it, so this is normally false and SetCrtc re-enables the CRTC, at the same timing when `modeset` is false). |
| `released` | Ack for `release`. |
| `preset` | `file` (preset id), `locked`, `rung` (internal WxH), `cause` (`start`, `take`, `rotate`, `next`, `prev`, `eject`, `lock`, `unlock`, `step_down`), `cut` (true = no blend). Sent whenever the showing preset, its lock or its rung changes. |
| `skip` | `preset`, `reason`, optional `message` (the first line of the error): the preset can't be drawn here (persist it for this pack version). Reasons: `register_allocate` (vc4 register allocation failed), `translate_error` / `compile_error` / `link_error` (a warp or composite shader failed and projectM fell back to its default), `shader_error` (another error-level projectM log during the warm-up), `load_failed` (unreadable or unparsable preset), `draw_dropped` (sentinel pixel untouched), `budget` (below the floor at the last rung). |
| `stats` | Every `--stats-s`: `fps` (presented), `frames`, `flip_ms` (mean flip-to-flip), `frame_ms` / `frame_ms_max` (CPU render + submit), `late` (flips past their slot), `rung`, `interval`, `temp_c`, `arm_mhz`, `gpu_ms` (only with `GL_EXT_disjoint_timer_query`, which vc4 lacks), `preset`, `pcm_ok` / `pcm_silent` (frames with ring audio / silence), `warmups`, `warmup_ms_max`, `shader_stages` / `cached_stages` (translated shader stages warmed up, and those read from the pack's shader cache), `stderr_discarded` (driver stderr bytes dropped). |
| `error` | `reason`, optional `message`: a non-fatal problem (`bad_command`, `master_timeout`, `take_failed`, `driver`, `register_allocate`, `thermal_drop`, …), or the cause just before a failing `exiting`. |
| `exiting` | `reason`: `requested`, `eof`, `signal`, `thermal` (exit 0), or a failure — `manifest`, `no_presets`, `output`, `gl`, `projectm`, `kms`, `output_lost` (exit 1), `usage` (exit 2). |

### Handover

1. Start the renderer while Emerge runs. It opens card0 (dropping master
   if it got it implicitly), builds GBM/EGL/GL and projectM, loads and
   warms the first preset and renders a frame — all without master — then
   prints `prepared`.
2. Stop Emerge, send `take`. The renderer polls `drmSetMaster` (2 ms
   steps, ≤ 2 s) and SetCrtc's the prepared frame → `presenting`.
3. Send `release`, start Emerge once `released` arrives (the renderer
   still holds card0, so fbcon doesn't relight the console in between),
   then send `exit`.

**Exit is bounded.** Once an exit is decided (`exit`, stdin EOF, a
failure) or SIGTERM/SIGINT arrives, a watchdog gives the shutdown 1 s:
`exiting` comes first, then teardown (projectM, GL, GBM, card0, the stderr
reader); past the budget the renderer logs, emits `exiting` if it hadn't
and `_exit`s with the same code. The scanout is left as it is; the
renderer never RmFBs a framebuffer it doesn't own. The card fd is
non-blocking, and a flip event is only dispatched while one is awaited
(a `release` can consume the pending flip itself).

## Pack layout

The pack is produced by the Phase 4 pipeline and extracted to
`/data/milkdrop/<version>/`:

```
<pack>/
  manifest.json       required
  presets/            the .milk files, possibly in subfolders (high_frequency/, ...)
  textures/           the texture search path (projectM matches lowercase basenames)
  shaders/<hash>.glsl pre-translated GLSL ES 1.00 (rpi3; see "Shader cache")
  README, NOTICE      provenance and licence notes
```

A **preset id** is the preset's path under `presets/`, e.g.
`Geiss - Chrome.milk` or `high_frequency/xyz.milk`. Ids are what
`--skip-file`, `--locked` and the `preset` / `skip` events carry. A valid id
is relative, has no `.`/`..`/empty segment and no control characters, ends
in `.milk` and is at most 1024 bytes; others are dropped from the manifest.

`manifest.json`:

```json
{
  "format": 1,
  "version": "2026.11.1",
  "presets": [
    {
      "file": "Geiss - Chrome.milk",
      "tags": ["extreme"],
      "rpi3": {"rung": "640x360", "frame_ms": 22.0},
      "compile_ms": 120,
      "eval_ms": 2.4
    },
    {"file": "high_frequency/x.milk", "tags": ["high_frequency"],
     "rpi3": {"rung": "skip", "reason": "register_allocate"}}
  ]
}
```

| Field | Meaning |
|---|---|
| `format` | Must be 1 when present. |
| `version` | The pack version (informational here; the BEAM keys skips by it). |
| `presets[].file` | The preset id (required). Duplicates and invalid ids are dropped. |
| `tags` | Strings. `high_frequency` (or a `high_frequency/` path) puts a preset behind `--high-frequency`. |
| `rpi3.rung` | The rpi3 sweep's verdict: the largest internal resolution that held the budget (`"WxH"`), or `"skip"` (with `reason`). GLES2 builds start the preset at the first ladder rung no larger than it and never play `skip` presets. GLES3 builds (rpi4/5) ignore `rpi3` and rely on the runtime guard. Shorthand: `"rpi3": "skip"` or `"rpi3": "640x360"`. |
| `rpi3.frame_ms` | Whole-frame vc4 time at that rung. Over 25 ms, a GLES2 build cuts to the preset instead of blending (a blend renders two presets). |
| `compile_ms` | rpi3 shader compile time. Over 600 ms, rotation picks the preset at half weight (it is still played). |
| `eval_ms` | Per-frame expression eval time (informational). |

Unknown fields are ignored.

### Shader cache

`shaders/` holds pre-translated preset shaders, `<key>.glsl`, where the key
is the SHA-256 of the translator version, the GLSL target, the shader stage,
the sampler declarations and the preprocessed HLSL. The renderer passes it
to `projectm_set_shader_cache_dir`; a missing file only costs a translation
at load, and other targets' files (rpi4/5 use GLSL ES 3.00) just miss. The
pack pipeline fills it with the fork's tool, with `textures/` in place
(texture names are part of the sampler declarations):

```
projectM-pretranslate-presets --target es100 <pack> <pack>/presets
```

(built with `-DBUILD_TRANSLATOR_HARNESS=ON`; it writes `<pack>/shaders/`).
The `stats` event's `cached_stages` shows the hit rate.

## How it renders

**Internal resolution.** projectM renders into an internal-resolution
FBO (the current rung), which is upscaled to the scanout size.

**Frame pipelining.** Up to three GBM buffers are in use: the one on
screen, one with a flip pending, and one being rendered. Frame N+1 is
rendered while flip N is pending, so CPU and GPU work overlap: a frame
costing 22–29 ms holds 30 fps instead of quantising to three vblanks as
a render-then-wait loop does.

**Pacing.** Frames are shown every `interval` vblanks (2 on rpi3 = 30 fps
at 60 Hz). After a flip lands at T, the next is submitted at
T + (interval − 1) · period + 2 ms, i.e. just after the vblank in between,
so it lands at T + interval · period, or later if the GPU isn't done (the
kernel waits on the buffer's fence). Each frame is rendered for its
predicted scanout time: the slot after the pending flip's.

**Frame rate.** projectM is told the presented rate (refresh / interval)
whenever the guard's level changes, so per-frame preset expressions keep
their speed at interval 2.

**Clock.** projectM time advances by the predicted presentation interval
(clamped to 1–100 ms per frame), excluding warm-up stalls, so animation
and blends don't jump after a hold.

**Cost guard.** CPU timers miss GPU-bound work (a noise preset measured
8.9 ms of CPU and ran at 20 fps), so the guard works on DRM flip-event
timestamps. Per preset, after 15 settle frames and outside blends, it
takes windows of 60 flips; the mean interval (worst one dropped) gives
the fps. Levels walk down a ladder of (rung, interval):

- interval 1 targets (rpi4/5): (r0, 1) must hold 90 % of the refresh,
  then (r0, 2), (r1, 2), …;
- rpi3: (r0, 2), (r1, 2), ….

Levels at interval ≥ 2 must hold `--min-fps` (19: 20 fps = 3 vblanks looks
fine, with jitter allowance). Below that, step down a level; below it at
the last level, `skip` (`budget`). A preset keeps the level it settled on
for the session.

**Warm-up (P8).** Before a preset is shown, projectM preloads it
(`projectm_preload_preset_file`): parse, translate (or read the shader
cache), compile, and one draw clipped to a pixel, so vc4's backend compile
(done at first draw, p50 175 ms) happens while the last presented frame
stays on screen and the playing preset is untouched. A clean preload is
activated (`projectm_activate_preloaded_preset`, blend or cut), one frame is
rendered off-screen at a frozen clock over the sentinel (below), and a
1-pixel readback waits for the GPU. A failed preload is discarded and the
playing preset carries on.

**PCM.** Each frame takes the 576 frames of audio whose last frame plays at
the frame's predicted scanout time. Flip times are CLOCK_MONOTONIC and the
ring's `t_end_us` is CLOCK_MONOTONIC_RAW, so a RAW − MONOTONIC offset is
sampled at start and every 10 s. No ring, no stream, an underrun gap or a
target more than a chunk past the newest audio reads as no data and gives
silence (presets decay); a read the writer overtook is retried. The ring is
reopened if the player replaces the file. `src/pcm_tap.h` is a verbatim copy of
`c_src/sendspin_player/src/pcm_tap.h` (a test keeps them identical).

## Failure detection

- **stderr.** fd 2 is redirected into a pipe drained by a thread (Mesa
  writes from the render thread; an undrained pipe would block it). Lines
  with `Failed to register allocate` count as register-allocation
  failures; the first line of `MESA: error`, `MESA-LOADER`, `libEGL error`
  messages is reported as an `error` event (at most 20 per run). Everything
  else — the ~420 KB QIR dump per failing shader in particular — is
  discarded, never forwarded.
- **Attribution.** Each warm-up writes a marker to fd 2 and waits for the
  reader to reach it, so a failure is pinned to the preset that caused it.
- **Sentinel pixel.** The internal target is cleared to magenta with alpha
  0 before the warm-up frame; if its centre pixel still holds that after
  the frame, the draw was dropped. projectM's output reaches our target
  through a final copy/blend, so this catches a dropped frame, not a single
  dropped preset stage; stderr is the primary channel for those.
- **projectM.** The preload's load result (the fork's
  `projectm_set_preset_load_result_event_callback` and return status)
  gives `translate_error`, `compile_error`, `link_error` or `load_failed`,
  with the failing stage and message; other error-level log messages during
  the warm-up give `shader_error`.

A failed preset is skipped and reported. A preload failure leaves the
playing preset (and its blend) alone, so the next pick blends in as usual;
a failure after activation holds projectM's blend slot, so the renderer
cuts past it. At most 8 candidates are tried in one go; then the loop runs
(commands, and frames of the playing preset unless a failed one was
activated) and selection resumes. Only when no eligible preset is left
does the renderer exit (`no_presets`).

stderr is synced before a warm-up's baseline is taken, so output of
earlier frames isn't pinned on the incoming preset; if a sync times out, a
register-allocation failure in that window is logged but not attributed.

## Thermal guard

`/sys/class/thermal/thermal_zone0/temp` is read once a second. At ≥ 78 °C
for 10 s the lowest allowed rung drops by one for the session (once,
`error` `thermal_drop`); at ≥ 83 °C the renderer releases and exits
(`exiting` `thermal`, exit 0). `stats` reports the temperature and the ARM
clock (`scaling_cur_freq`). A heatsink is recommended on rpi3.

## Building

`mix compile` builds it through `Mix.Tasks.Compile.MilkdropRenderer`
(device targets: rpi3 with `-DMILKDROP_GLES2=ON`, rpi4/rpi5 GLES 3; the
host: `-DMILKDROP_CORE_ONLY=ON`). projectM comes from
`bbangert/projectm` via FetchContent, pinned by SHA in `CMakeLists.txt`,
built static at -O2 with the playlist library off. The renderer needs the
fork's es2/1d APIs (shader cache, preload, load results).

To build against a local fork checkout instead of the pin:

```
MILKDROP_PROJECTM_SOURCE_DIR=/workspaces/projectm mise run firmware -- rpi3
```

CMake warns when the checkout's HEAD isn't the pinned SHA. projectM's ES2
build clamps the mesh to (w+1)·(h+1) ≤ 65536 (16-bit indices) and warns
above 254x256.

Unit tests (host, no GL): `test/milkdrop_renderer_unit_test.exs` builds
and runs `milkdrop_renderer_unit_tests` — protocol and JSON, options,
manifest and skip list, rotation and history, preset selection batches
and exhaustion, the cost guard ladder, frame pacing, the poll-round
dispatch order, the exit guard (a hung shutdown still exits in budget),
the thermal guard, the stderr classifier and capture, and PCM ring
alignment against sendspin_player's real ring writer.

## Checks

`--headless-frames N --card /dev/dri/renderD128` renders N frames
off-screen without KMS, flips or master (frames back to back, each waiting
for the GPU), with rotation, warm-ups, the guard and the skip paths
running, then exits with `exiting` `headless_done`. It doesn't touch card0,
so it can run next to Emerge to check a build or a pack on a device.

`--simulate-kms --card /dev/dri/renderD128` runs the normal protocol
(`prepared`, `take`, presenting, `release`, `exit`) without a display:
master and SetCrtc are simulated, and flips "land" at each vblank of the
mode through a timer fd. Pacing, the cost guard, warm-ups and the exit
paths run as on HDMI, so a release/exit sequence can be checked next to
Emerge.

`--test-tone` feeds a synthetic beat (120 BPM kick, hi-hat, sine sweep)
whenever the ring gives silence, for visual checks without a playing
stream.
