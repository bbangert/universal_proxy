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
milkdrop_renderer --mode 1280x720 --pack-dir DIR --ladder 640x360,480x270
                  --rotate-s 20 --min-fps 20 --skip-file PATH
                  [--high-frequency] [--locked FILE] [--pcm-ring PATH]
                  [--connector HDMI-A-1] [--user-dir DIR] [--selection-file PATH]
```

| Option | Meaning |
|---|---|
| `--mode WxH[@Hz]` | The CRTC mode to present on. Keep Emerge's mode: a different pixel clock under a running HDMI audio stream leaves vc4's N/CTS stale, so the mode the CRTC scans out when the renderer starts (Emerge's) is used whenever it fits. `WxH` (what the BEAM passes): the CRTC's mode if it is that size and progressive, whatever its refresh (50, 60, 120 Hz); otherwise the connector's preferred mode at that size, else its highest refresh at that size. `WxH@Hz`: the CRTC's mode if it is that size, progressive and within 0.5 Hz; else the offered mode closest to Hz within 0.5 Hz (1280x720 comes at 60 and 59.94). No fitting mode: `exiting` `output`. |
| `--connector NAME` | The connector to present on, by its kernel name (`HDMI-A-1`, `HDMI-A-2`: `<type>-<n>`, 1..32 of `[A-Za-z0-9-]`); it must be connected, or `exiting` `output` — never another connector. Without it, the first connected HDMI connector. The BEAM passes the one Emerge drives. |
| `--card DEV` | The DRM card node to open (default `/dev/dri/card0`). The BEAM passes the one Emerge drives (the card whose sysfs entries have the connector), since that isn't card0 on every board. |
| `--pack-dir DIR` | The extracted preset pack (layout below). |
| `--ladder WxH,...` | Internal render resolutions, highest first, each smaller than the last. The renderer steps down per preset and skips a preset past the last rung. |
| `--rotate-s N` | Auto-rotation interval, seconds. |
| `--min-fps F` | The frame rate a preset must hold (default 20; 1..240); see "Cost guard". The BEAM passes the user's setting (20..30 on rpi3, 20..60 on rpi4/5, in steps of 5). |
| `--skip-file PATH` | Presets never to load: one preset id per line (`user/` ids included). A missing file is an empty list. |
| `--high-frequency` | Include `high_frequency/` presets (photosensitivity; off by default; see "Photosensitivity filter"). |
| `--locked FILE` | Start locked on this preset id (a pack or a `user/` one; hidden or off the playlist is fine). If it isn't eligible (a `high_frequency` one while they are off, skipped, an rpi3 `skip`, or unknown): `error` `locked_refused` (`message`: `<why>: <id>`) and an unlocked random start. |
| `--pcm-ring PATH` | The PCM tap ring (`/run/up-pcm-<client_id>`). Without it, or while it has no fresh audio, presets get silence. |
| `--user-dir DIR` | Uploaded presets (see "User presets"). Optional; a missing or bad `DIR/manifest.json` is no user presets, never fatal. |
| `--selection-file PATH` | Favourites, hidden presets and the playlist (see "Selection"). Optional; a missing file is an empty selection. |

Tuning and check knobs (not passed by the BEAM): `--blend S` (soft-cut
length, 0.5), `--interval N` (vblanks per frame: 2 on GLES2 builds, else 1), `--seed N`, `--av-offset-ms N` (added to the PCM
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
| `{"cmd":"take"}` | Poll `drmSetMaster` for up to 2 s, show the prepared frame with SetCrtc in the chosen mode, start presenting → `presenting`. On timeout: `error` `master_timeout`, still prepared. While the prepared preset is being replaced (it hung the GPU, see "Failure detection"), the take waits until a replacement has loaded (`no_presets` if none can be); a `release` drops it. |
| `{"cmd":"release"}` | Stop flipping (a pending flip lands first), `drmModeCloseFB` the front buffer so it stays scanned out (never RmFB the scanout framebuffer), drop master, **keep card0 open** → `released`. Also acked when not presenting. |
| `{"cmd":"exit"}` | Release if presenting → `exiting` (`requested`), close everything, exit 0. |
| `{"cmd":"next"}` / `{"cmd":"prev"}` | Forward / back in the history (a new random pick at its end; `prev` with nothing earlier does nothing). A lock stays on and moves to the new preset. |
| `{"cmd":"lock"}` / `{"cmd":"unlock"}` | Hold / resume rotation on the current preset. |
| `{"cmd":"set_rotate","value":N}` | Rotation interval in seconds (1..3600). |
| `{"cmd":"set_high_frequency","value":B}` | Include `high_frequency/` presets; turning it off while one is rendered (playing or blending out) cuts away at once (see "Photosensitivity filter"). |
| `{"cmd":"set_min_fps","value":F}` | The minimum frame rate (1..240), as `--min-fps`; the current value changes nothing. Otherwise levels settled this session are forgotten, and the current preset's next window is judged against the new floor; one whose level's interval can't present it at all is skipped at once (`skip` `budget`). |
| `{"cmd":"play","preset":ID,"lock":B}` | Load preset `ID` now, through the same warm-up as `next` (`loading`, then `preset` with `cause` `play`, or `skip`), then rotate on, or stay locked on it when `lock` is true (optional, default false). Any eligible preset may be played, hidden or off the playlist included. Refused at once, and again if that changed by the time it runs, with `play_refused`: `unknown` (not in the catalogue, or removed by `reload_user`), `skipped`, `high_frequency` (while they are off), `rpi3_skip` (GLES2 builds). A failed warm-up gives the usual `skip` and `play_refused` `load_failed`; the playing preset carries on (a failure after activation cuts to a rotation pick instead, as for any candidate) and no other candidate is tried. It goes into history like a `next` pick. A pending eject (skip, filter) waits for it and follows if it fails. While not presenting (prepared, released) it loads in the next loop round, or first thing in a `take` that follows it, so the take shows the played preset; other switches (`next`, `prev`) still wait for presenting. `ID` must be a valid preset id (below), else `bad_command`. |
| `{"cmd":"reload_user"}` | Re-read `--user-dir`'s manifest (see "User presets") → `user_reloaded`. A bad manifest keeps the user presets loaded and gives `error` `user_manifest`. |
| `{"cmd":"reload_selection"}` | Re-read `--selection-file` → `selection`. A bad file keeps the selection in force and gives `error` `selection`. |

A malformed or unknown command gives `error` with `reason: "bad_command"`.
Lines over 4096 bytes are dropped whole; the longest `play` (a 1024-byte id
with every byte escaped) fits.

### Events (stdout)

| Event | Fields |
|---|---|
| `prepared` | `mode` (the chosen mode, e.g. `1280x720@60`), `connector` (e.g. `HDMI-A-1`; with `--simulate-kms` the `--connector` given, if any), `mode_source` (how `mode` was chosen: `crtc` — the CRTC's at open, no modeset; `closest` — `WxH@Hz`'s nearest offered; `preferred` / `highest` — `WxH` without a fitting CRTC mode; absent in the check modes), `gl_renderer`, `gl_version`, `gles2`, `presets` (eligible count), `crtc_mode_valid` and `crtc_mode` (only when valid): what the CRTC scanned out when the card was opened. GL is up, the first preset warmed and a frame rendered; not master. |
| `presenting` | `modeset` (true = the mode set differs from the last one scanned out before the handover: the CRTC's at take if it still had one, else the one in `prepared`), `master_ms`, `crtc_lit` (the CRTC still had a mode at take; Emerge's stop detaches it, so this is normally false and SetCrtc re-enables the CRTC, at the same timing when `modeset` is false). |
| `released` | Ack for `release`. |
| `loading` | `preset` (preset id): about to load and warm up this preset; written before any GPU work for it (its level, preload, warm-up frame), for every candidate tried (a failed one is followed by `skip`). A vc4 GPU hang can reset the whole device (the kernel logs `[drm] Resetting GPU.` and the Pi reboots within seconds); the BEAM persists this so the preset is skipped after the reboot. A `preset` event that keeps the same preset (`lock`, `unlock`, `step_down`) has no `loading` before it. |
| `preset` | `file` (preset id), `locked`, `rung` (internal WxH), `cause` (`start`, `take`, `rotate`, `next`, `prev`, `play`, `eject`, `lock`, `unlock`, `step_down`), `cut` (true = no blend). `eject` is also the cut away from a `high_frequency` preset (it can name the preset already playing: its blend in was completed). Sent whenever the showing preset, its lock or its rung changes. |
| `skip` | `preset`, `reason`, optional `message` (the first line of the error), `fps` (with `budget`, when a window was measured: the preset's last measured frame rate rounded down to one decimal, which the BEAM keeps so a lower minimum can bring it back): the preset can't be drawn here (persist it for this pack version). Reasons: `register_allocate` (vc4 register allocation failed), `translate_error` / `compile_error` / `link_error` (a warp or composite shader failed and projectM fell back to its default), `shader_error` (another error-level projectM log during the warm-up), `load_failed` (unreadable or unparsable preset), `draw_dropped` (sentinel pixel untouched), `budget` (below the floor at the last rung), `gpu_hang` (the kernel reset the GPU while it was loading or showing; `message` is the kernel's line; see "Failure detection"). |
| `stats` | Every `--stats-s`, in every phase (the BEAM's liveness signal, see "Failure detection"): `fps` (presented), `frames`, `flip_ms` (mean flip-to-flip), `frame_ms` / `frame_ms_max` (CPU render + submit), `late` (flips past their slot), `rung`, `interval`, `temp_c`, `arm_mhz`, `gpu_ms` (only with `GL_EXT_disjoint_timer_query`, which vc4 lacks), `preset`, `pcm_ok` / `pcm_silent` (frames with ring audio / silence), `warmups`, `warmup_ms_max`, `shader_stages` / `cached_stages` (translated shader stages warmed up, and those read from the pack's shader cache), `stderr_discarded` (driver stderr bytes dropped). |
| `play_refused` | `preset`, `reason` (`unknown`, `skipped`, `high_frequency`, `rpi3_skip`, `load_failed`): a `play` that didn't happen. |
| `user_reloaded` | `presets` (live user presets), `added` (new ids, or ids back after a removal), `removed`, `rejected` (manifest entries dropped as malformed): `reload_user` done. |
| `selection` | `gen` (the file's), `eligible` (presets rotation picks from now), `playlist_fallback` (the playlist is on but nothing on it can rotate, so rotation uses every unhidden eligible preset), `hidden_fallback` (every eligible preset is hidden, so rotation ignores hidden): after `prepared` when there is a `--selection-file`, and after each `reload_selection`. |
| `error` | `reason`, optional `message`: a non-fatal problem (`bad_command`, `master_timeout`, `take_failed`, `driver`, `register_allocate`, `thermal_drop`, `locked_refused`, `user_manifest`, `selection`, …), or the cause just before a failing `exiting`. |
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
and `_exit`s with the same code. The budget starts at the decision, before
anything is written about it, and the watchdog's own log line and
`exiting` are best effort (non-blocking, ~150 ms at most), so a full
stdout or stderr can't hold the exit up. Commands after an `exit` (in the
same read or later) are ignored. The scanout is left as it is; the
renderer never RmFBs a framebuffer it doesn't own. The card fd is
non-blocking, and a flip event is only dispatched while one is awaited
(a `release` can consume the pending flip itself).

## Photosensitivity filter

While `high_frequency` presets are off (the default):

- no pick returns one: start, rotation, `next` / `prev` (history entries
  are passed over), `--locked` and `play` (refused, see above);
- the renderer tracks what projectM renders, the playing preset and,
  during a blend, the outgoing one, as `high_frequency` or not as they
  were loaded (a `reload_user` that clears an upload's tag doesn't change
  what is on screen; one that sets it counts at once). When either is
  `high_frequency` (the filter was just turned on, mid-blend in either
  direction), it cuts at once, never blends: to the playing preset when
  that one is eligible (its blend completes; one whose tag was cleared is
  reloaded as its file is now), else to a random eligible one. A frame rendered but
  not yet submitted is dropped, and no frame is rendered until the cut
  has happened (a failed batch holds the last frame on screen). A `take`
  cuts before its first frame.

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
`--skip-file`, `--locked`, `play`, the selection file and the `preset` /
`skip` events carry. A valid id is relative, has no `.`/`..`/empty segment
and no control characters, is valid UTF-8, ends in `.milk` and is at most
1024 bytes; others are dropped from the manifest. Ids under `user/` are
reserved for user presets: pack entries there are dropped (counted as
rejected).

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
| `compile_ms` | rpi3 shader compile time. Over 600 ms, rotation picks the preset at half weight: later in a deal on average (it is still played as often). |
| `eval_ms` | Per-frame expression eval time (informational). |

Unknown fields are ignored.

### User presets

Uploads live outside the pack (the BEAM never writes into it), in
`--user-dir`:

```
<user>/
  manifest.json       BEAM-generated, same format as the pack's; optional
  presets/            the uploaded .milk files
  textures/           their textures
```

- **Ids** are `user/` + the entry's `file`, which resolves to
  `<user>/presets/<file>`; one whose prefixed id isn't valid (too long) is
  rejected. A missing manifest (or no `--user-dir`) is no user presets; a
  malformed one is logged and reported (`error` `user_manifest`), and the
  pack plays alone. Never fatal.
- **Fields.** The BEAM writes `file`, `tags` and optionally `sha256` (the
  file's content hash; `rpi3`, `compile_ms` and the like are absent:
  uploads are not swept). A `high_frequency` tag puts
  an upload behind `--high-frequency` like a pack preset. The
  `high_frequency/` path rule applies to `file` as written, before the
  `user/` prefix; the BEAM writes flat names, so for uploads only the tag
  counts.
- **Shaders.** The pack's shader cache simply misses for them: they are
  translated at load (on rpi3 about 42 ms p50, 107 ms p99 more warm-up).
- **Textures.** The search path is `[<pack>/textures, <user>/textures]`:
  projectM takes the first file with a matching lowercase name, so a pack
  texture wins a clash. projectM rescans it at each preset load, so new
  uploads' textures need no restart, and its random textures
  (`sampler_randNN`) are drawn from both directories. It caches a texture
  by name once loaded, so when `reload_user` finds the manifest's
  `textures` list changed (a file or `sha256` added, replaced or gone) it
  sets the search path again, which rebuilds projectM's texture manager:
  later loads read the files afresh, and the preset playing keeps the
  textures it holds.
- **`reload_user`** re-reads the manifest. Entries are never erased or
  moved: new ids are appended, listed ones refreshed in place (their tags,
  e.g. a `high_frequency` toggle; an upload flagged `high_frequency` while
  rendered with the filter off is cut away at once), and ids no longer
  listed are tombstoned. A tombstoned preset is never picked again
  (rotation, `next`/`prev`, which pass over it, `play` → `unknown`); if it
  is playing it carries on until the next switch, and while locked it
  stays until `unlock`/`next` (then rotation moves on). An id that comes
  back revives its entry with the new fields; projectM reads the file at
  each load, so a replaced file plays its new content from its next load.
  A refreshed or revived id whose `sha256` differs (or is absent) is
  measured afresh by the cost guard at that load (its settled level and
  measured frame rate are forgotten); if it is playing, the old content
  keeps its level and its measurements no longer count for the id.
- **Skips** are by id: a `--skip-file` entry or a skip this session holds
  for a `user/` id like any other, for the whole session (a replaced file
  is retried at the next start, when the BEAM's skip file no longer lists
  it).

### Selection

`--selection-file` (BEAM-written, read whole, at most 1 MiB):

```json
{"gen": 12, "favourites": ["a.milk"], "hidden": ["user/b.milk"],
 "playlist": ["a.milk", "c.milk"], "playlist_enabled": true}
```

Every field is optional (`gen` 0, lists empty, playlist off). Ids that
aren't valid preset ids are dropped; unknown ones are kept, so a playlist
may name an upload a later `reload_user` adds. A wrong type, malformed JSON
or an oversize file is an `error` `selection`: at start nothing is applied,
on `reload_selection` the selection in force stays.

Precedence, applied on every pick:

- the skip list and the photosensitivity filter always apply (and on
  GLES2 the rpi3 `skip` verdict): those presets are not eligible;
- rotation (the timer, `next` past the end of history, ejects) picks
  from the first non-empty of: the eligible, unhidden presets on the
  playlist (while it is enabled); the eligible, unhidden ones (the
  `selection` event's `playlist_fallback`); every eligible one
  (`hidden_fallback`). A selection never ends rotation: only running out
  of eligible presets exits (`no_presets`);
- `next`/`prev` through history pass over hidden presets;
- favourites play three times as often: rotation deals one ticket per
  preset of the pool and three per favourite, spread so a preset's tickets
  aren't back to back, and never plays the same preset twice in a row,
  across deals too (unless it is the whole pool). So a preset plays at
  most every other pick: in tiny pools a favourite's share is capped
  there (with one other preset they alternate; with two others it plays
  about half the time instead of 3/5), and the tickets that can't be
  played are dropped rather than carried over without bound. The GLES2
  half weight for `compile_ms` over 600 only orders a deal (such presets
  come later in it on average);
- `play` and `--locked` may pick any eligible preset, hidden and
  off-playlist ones included.

A new selection re-deals rotation; the playing preset is left alone, even
if it is now hidden or off the playlist, until the next switch.

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

`--min-fps` (20 by default) is the frame rate a preset must hold, capped at
what the start interval can present (refresh / interval: 30 on rpi3 at
60 Hz). A window holds it at `--min-fps` − 1 or more: 20 fps = 3 vblanks
measures just under 20 with jitter (and at 59.94 Hz), so the default
accepts 19. Levels at interval ≥ 2 must reach that floor; a level whose
interval can't present it (refresh / interval below the floor, e.g. 30 fps
levels under a minimum of 35) is passed over. The interval-1 level must
also hold 90 % of the refresh while an interval-2 level could hold the
floor (a steady half rate beats a jittery full one); with a higher
minimum it needs only the floor. Below its floor, step down to the next
level that can present it; with none left, `skip` (`budget`, with the
measured `fps`). A preset keeps the level it settled on for the session,
until `set_min_fps` changes the floor.

**Warm-up (P8).** Before a preset is shown, projectM preloads it
(`projectm_preload_preset_file`): parse, translate (or read the shader
cache), compile, and one draw clipped to a pixel, so vc4's backend compile
(done at first draw, p50 175 ms) happens while the last presented frame
stays on screen and the playing preset is untouched. A clean preload is
activated (`projectm_activate_preloaded_preset`, blend or cut), one frame is
rendered off-screen at a frozen clock over the sentinel (below), and a
1-pixel readback waits for the GPU. A failed preload is discarded and the
playing preset carries on. So is a failed activation: the projectM fork
then discards the preloaded preset itself and keeps the playing one and any
running blend; the candidate is skipped (`load_failed`, with the message
projectM reported) and the next one is tried.

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
- **GPU resets.** Some presets hang the vc4 GPU on rpi3. The kernel logs
  `[drm] Resetting GPU.` (v3d: `Resetting GPU for hang.`) and usually
  recovers, but a reset can also take the whole device down about 7 s
  later. The renderer (root) follows `/dev/kmsg` from its end (opened
  non-blocking at start; unavailable means no watch, logged): it is read
  right after each warm-up's GPU wait and once per loop round. A reset
  seen after a warm-up fails that candidate (`skip` `gpu_hang`); one seen
  otherwise is blamed on the candidate whose warm-up failed within the
  last second, else on the preset showing, which gets `skip` `gpu_hang`
  and is never rendered again: its unsubmitted frame is dropped, no frame
  is rendered until a replacement has loaded (selection batches run each
  loop round, in every phase), and the switch is a cut, never a blend. A
  `take` waits for the replacement. The kernel log is also read before
  each round's commands, so a `take` never shows a preset whose reset was
  already logged. The `skip` goes out before anything else, so the BEAM
  can persist it before a fatal reset. Throttle: one `gpu_hang` skip per
  preset per run, and a reset within 3 s of the last one seen is taken as
  the same hang.
- **Device resets.** A fatal reset leaves no time for any of that, so the
  `loading` event, sent before each warm-up, lets the BEAM persist the
  preset being loaded and skip it (`device_reset`) after the reboot.
- **Hangs and crashes (BEAM side).** projectm-eval caps each `loop` and
  `while` at about 1 M iterations, but nested ones multiply, so a preset
  can stop the renderer's only thread for hours: no flips, no events, and
  neither the cost guard nor the exit guard runs. The BEAM takes a
  renderer that writes nothing for 30 s, or sends no `preset` or `skip`
  within 10 s of a `loading`, as hung: it skips the preset loading (else
  the one showing) with reason `hang` and SIGKILLs the renderer. A
  non-zero exit or a signal while a `loading` is unanswered, with no
  `exiting` before it, skips that preset with reason `crashed`.
- **Memory.** Preset `megabuf`s can reach about 256 MiB on rpi3, so the
  renderer sets its own `oom_score_adj` to 1000 at start: the OOM killer
  picks it rather than the BEAM (a kill mid-warm-up is a `crashed` skip).

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
connector and mode selection (`src/output_select.h`), manifest and skip list, the user manifest (`user/` ids,
reserved ids dropped, reloads with tombstones and stable entries), the selection file and its precedence (hidden,
playlist and its fallbacks, favourite tickets), `play` and its refusals, rotation and history, the photosensitivity
filter (picks, history, lock, blends in and out), preset selection
batches and exhaustion (a failed activation included), the switch state (held frames, cuts, a
`take` that waits for a replacement, recovery batches), the cost guard ladder, frame pacing, the poll-round
dispatch order (reset check before commands), the command drain (nothing after `exit`), the exit guard
(a hung shutdown still exits in budget, full stdout/stderr included), the
test tone's tempo,
the thermal guard, the stderr classifier and capture, the GPU reset
watch (kmsg parsing, following a file from its end, the throttle), and PCM ring
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
mode through a timer fd (60 Hz for a `WxH` mode). Pacing, the cost guard, warm-ups and the exit
paths run as on HDMI, so a release/exit sequence can be checked next to
Emerge.

`--test-tone` feeds a synthetic beat (120 BPM kick, hi-hat, sine sweep)
whenever the ring gives silence, for visual checks without a playing
stream.
