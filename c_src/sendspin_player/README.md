# sendspin_player

Small C++ binary that connects to a [Sendspin](https://github.com/Sendspin)
server, decodes audio (FLAC / Opus / PCM at 44.1 kHz and 48 kHz, stereo,
16-bit), and plays it through ALSA. One process per ALSA output. PCM never
crosses the BEAM boundary — Elixir talks to this binary only via
line-delimited JSON on stdin/stdout.

Built automatically by `Mix.Tasks.Compile.SendspinPlayer` (registered in
`mix.exs` `:compilers`) when `MIX_TARGET` is one of `host`, `rpi`, `rpi0`,
`rpi0_2`, `rpi2`, `rpi3`, `rpi4`, `rpi5`. Output lands at
`priv/sendspin_player/<MIX_TARGET>/sendspin_player`.

## Layout

```
c_src/sendspin_player/
├── CMakeLists.txt
├── LICENSE-sendspin-armv6   Apache-2.0 attribution copy for vendored files
├── README.md                this file
├── patches/
│   └── 0003-listener-bound-hook.patch
└── src/
    ├── alsa_pipe_sink.h     vendored from LeoLTM/sendspin-armv6
    ├── alsa_pipe_sink.cpp   vendored from LeoLTM/sendspin-armv6
    ├── display_roles.{h,cpp} ours — display roles (--display-roles)
    ├── artwork_store.{h,cpp} ours — artwork files and their retention
    ├── started_event.{h,cpp} ours — advertised formats + the `started` line
    ├── json_out.{h,cpp}     ours — JSON escaping + the guarded stdout writer
    ├── sha256.{h,cpp}       ours — artwork file names
    ├── pcm_tap.h            ours — PCM tap ring layout + reader (renderer copies it)
    ├── pcm_tap_writer.h     ours — PCM tap writer + S16 conversion
    └── main.cpp             ours — CLI args + JSON stdout/stdin
test/unit_tests.cpp          host unit tests (target sendspin_player_unit_tests,
                             run by test/sendspin_player_unit_test.exs)
```

## Vendoring

`alsa_pipe_sink.{h,cpp}` are vendored from
[`LeoLTM/sendspin-armv6@main`](https://github.com/LeoLTM/sendspin-armv6) under
Apache-2.0. Upstream does not place per-file copyright headers on these
files — attribution flows through `LICENSE-sendspin-armv6` (a copy of the
upstream LICENSE) which lives next to them in this directory. To pull a
newer revision, copy the source files **and** re-pull `LICENSE-sendspin-armv6`.
Do not add per-file headers locally.

### Local divergence

The vendored files carry two local fixes vs. upstream:

- `alsa_pipe_sink.cpp::stop()` — join the playback thread unconditionally
  so a self-clearing `running_` (after an ALSA write error inside the
  playback loop) does not leave the `std::thread` joinable, which would
  otherwise trip `std::terminate` from the destructor. The change is
  flagged inline with a comment in `alsa_pipe_sink.cpp` and is intended
  to be sent upstream — once it merges, we can re-vendor verbatim and
  drop the divergence.
- `alsa_pipe_sink.cpp::write()` — commit only whole PCM frames to the
  ring per call, so partial return counts are always frame-aligned.
  sendspin-cpp made this an explicit contract in #78 (a mid-frame
  count drifts its playtime estimate); upstream's byte-oriented write
  can return a mid-frame count when the ring fills exactly (the 2 MiB
  power-of-two capacity is not a multiple of 6-byte 24-bit-stereo
  frames). Also a candidate to send upstream.

`main.cpp` is our own adaptation of upstream `src/main.cpp`. The shape stayed
close to upstream so future patches there can land here with minimal effort.
Differences:

- CLI args (`getopt_long`) replace the INI config file
- JSON status events on **stdout** replace upstream's stderr free-form logs
  for anything the BEAM acts on. What is still written to **stderr** (the
  library's `E`/`W`/`I` lines such as `W SyncTask: Lost sync`, the sink's
  `AlsaPipeSink: underrun, recovering`, alsa-lib) is diagnostics only:
  `Audio.Player` merges it into the same pipe and logs every line that does
  not start with `{`. So a stdout line must always be a JSON object, and a
  stderr line must be written whole, in one call
- JSON command lines on **stdin** for runtime volume / mute / shutdown
- Sets `SendspinClientConfig::server_port` from `--mdns-port` so multiple
  binary instances can bind distinct ports (first-class upstream since
  sendspin-cpp #61)
- A file-backed `SendspinPersistenceProvider` (`src/file_persistence.*`)
  keeps the library's identity keypair and pairing state under
  `--state-dir`, and unpaired access is enabled (see *Identity and
  admission* below)
- The Pairing PSK token is written to `<state-dir>/pairing_token` (never
  to stdout/stderr) for the web UI to show on demand

## sendspin-cpp pin

Pinned via `FetchContent` to a **commit SHA** in `CMakeLists.txt`
(`SENDSPIN_CPP_REF` cache var). Currently `b95cf854...`, upstream
`v0.9.5`. We pin to a SHA rather
than a tag because git tags are mutable server-side; a retagged upstream
would otherwise silently flow into firmware. The friendly tag name (or
nearest-release note) lives in a comment beside the SHA for traceability.

The protocol is Experimental upstream — treat every minor bump as a
release-blocking review and re-validate the patch listed below.

### Retired patches (upstreamed)

Two patches were dropped at the `0c2b4585` bump because upstream now
provides the behavior first-class:

- **0001-configurable-ws-port** — superseded by upstream #61:
  `SendspinClientConfig::server_port` configures the listener port
  directly; `main.cpp` sets it from `--mdns-port` (the old patch read a
  `SENDSPIN_WS_PORT` env var). Needed because universal_proxy spawns one
  binary per ALSA output, so each instance must bind a distinct port.
- **0002-defer-registration-until-open** — superseded by upstream
  #80/#81 (fixing Ben's issue #75, the phantom-connection wedge):
  connections now enter a handshake "nursery" and are only admitted to
  the ConnectionManager once the WebSocket upgrade completes and
  `client/hello` arrives (prove-then-admit). This also covers the
  residual our patch could not: a post-upgrade-but-silent peer now
  times out in the nursery instead of occupying a slot forever, and a
  surplus peer gets a graceful `client/goodbye`.

### Patch: listener-bound hook

`patches/0003-listener-bound-hook.patch` (our sole remaining patch)
declares a weak `extern "C" sendspin_host_listener_bound(uint16_t)` and
calls it from `SendspinWsServer::start()` the moment `listen()` succeeds.
`main.cpp` defines the strong symbol and uses it to drive the `listening`
stdout event. The hook is authoritative where an external port probe is
not: a probe cannot tell OUR listener from a foreign or dying-predecessor
socket on the same port (which would advertise a player whose own listener
is still failing to bind — recreating the announce-before-bind race).
Weak linkage keeps the library linkable without a definition (upstream
examples, tests).

When bumping `SENDSPIN_CPP_REF`:

1. Resolve the tag to a SHA:
   `git ls-remote https://github.com/Sendspin/sendspin-cpp.git refs/tags/vX.Y.Z`
2. Update `CMakeLists.txt`'s `SENDSPIN_CPP_REF` cache var (keep the friendly
   tag in the inline comment for traceability)
3. `rm -rf _build/*/sendspin_player` — the WHOLE build dir per target.
   The pin itself now propagates into existing caches (`SENDSPIN_CPP_REF`
   is set with `FORCE`), but a clean dir guarantees FetchContent
   re-populates and the patch applies to a pristine tree rather
   than one carrying the previous version's patched state
4. Run `mix compile` — if the patch no longer applies cleanly, regenerate
   it from a real checkout at the new SHA (apply the edits, then
   `git diff > 0003-...patch`) and commit. The post-populate marker
   checks in `CMakeLists.txt` will `FATAL_ERROR` if the patch silently
   no-applies. Keep the two marker strings byte-identical to the
   `assert_patch_markers` arguments.
5. Verify the binary runs with `--mdns-port 18928` and binds correctly
   (e.g. `ss -tlnp | grep 18928`)
6. Run `mix test test/sendspin_player_contract_test.exs --include contract`
   to confirm the JSON event contract still holds
7. If upstream adds a first-class listener-bound callback, drop the patch
   and use their API directly

## Manual hacking

Outside Mix, configure and build by hand:

```sh
cd c_src/sendspin_player
cmake -B _build -S . -DCMAKE_BUILD_TYPE=Release
cmake --build _build -j
./_build/sendspin_player --name "Test" --state-dir /tmp/sendspin-test
```

## CLI surface

The flags must match what `UniversalProxy.Audio.Player` passes — see the
`@moduledoc` in `lib/universal_proxy/audio/player.ex` (added in Phase 3).

| Flag                       | Required | Description                                  |
| -------------------------- | -------- | -------------------------------------------- |
| `--name STR`               | yes      | Friendly display name                        |
| `--state-dir PATH`         | yes      | Per-output directory for the persisted identity keypair and pairing state, created `0700`. The Sendspin `client_id` is derived from the keypair and reported on `listening`; the pairing token is written to `pairing_token` in it |
| `--server URL`             | no       | Outbound Sendspin server WebSocket URL       |
| `--product STR`            | no       | Product id in `device_info` (node name, e.g. `universal-proxy-07507f`); vendor is fixed to `Universal Proxy`. Default `sendspin_player` |
| `--mac STR`                | no       | MAC for `device_info`, lowercase colon-separated. Pre-normalized by the Elixir side; empty/absent = library auto-detects from the active interface |
| `--alsa-device STR`        | no       | ALSA device, e.g. `plughw:0,0` (default = system default) |
| `--mdns-port INT`          | no       | Local WebSocket listener port (default 8928) |
| `--initial-volume 0..100`  | no       | Startup volume (default 50)                  |
| `--initial-static-delay-ms 0..5000` | no | Startup static output delay for multi-room sync; the server can adjust it at runtime (`static_delay` event reports changes for persistence). Default 0 |
| `--external-volume`        | no       | Start in external-volume mode (see *Stdin commands*) |
| `--display-roles`          | no       | Also take the metadata, controller, color, artwork and visualizer roles (see *Display roles*). Without it only the player role is registered |
| `--artwork-dir PATH`       | no       | Where displayed artwork is written (created `0755`). Without it, no artwork role |
| `--artwork-size WxH`       | no       | Size the server scales artwork to, each 16..2048 (default `480x480`) |
| `--artwork-keep 1..64`     | no       | Displayed artwork files kept in `--artwork-dir` (default 8) |
| `--viz-bins 1..128`        | no       | Visualizer spectrum bins (default 32) |
| `--viz-rate 1..60`         | no       | Visualizer frames per second (default 20) |
| `--viz-offset-ms 0..1000`  | no       | Deliver visualizer frames this far ahead of their display time (default 0) |
| `--pcm-tap-path PATH`      | no       | File the `pcm_tap` command maps the PCM tap ring at (see *PCM tap*). Without it `pcm_tap` fails |
| `--log-level STR`          | no       | `none\|error\|warn\|info\|debug\|verbose`    |
| `--help` / `-h`            | no       | Print usage and exit                         |
| `--version` / `-V`         | no       | Print version and exit                       |

## Stdout events

Each event is a single line of JSON. The binary writes events at startup, on
connection state changes, on stream lifecycle changes, on volume/mute
changes, and on errors.

```jsonc
{"event":"started","version":"0.1.0","port":8928,"name":"Out 1","product":"universal-proxy-07507f","alsa_device":"plughw:0,0","formats":[{"codec":"flac","channels":2,"rate":48000,"bit_depth":16}]}
{"event":"listening","port":8928,"client_id":"E8oqWSUo4DZKok0mgH32tIvrxxyc_Fzn-YfXfYm_mBM"} // listener bound
{"event":"connected","server":"ws://music.local:8927/sendspin"}
{"event":"disconnected"}
{"event":"stream_start","sample_rate":48000,"channels":2,"bit_depth":16,"codec":"opus"}
{"event":"stream_end"}
{"event":"time_sync","error_us":42.3}     // only at log-level >= debug
{"event":"volume","value":80}
{"event":"mute","value":false}
{"event":"volume_external","value":true}  // ack of set_volume_external / --external-volume
{"event":"pcm_tap","value":true}          // ack of pcm_tap
{"event":"pcm_tap","value":false,"ok":false,"error":"open: Permission denied"} // pcm_tap on failed
{"event":"error","kind":"alsa_configure","msg":"..."}
{"event":"error","kind":"pairing_token","msg":"..."}  // non-fatal; token itself never on stdout
{"event":"error","kind":"state_dir","msg":"..."}      // fatal: the identity cannot be kept (exits 1)
{"event":"error","kind":"oversize_line","msg":"..."}  // a line over the cap was dropped (a bug)
{"event":"shutdown"}
```

Every line is capped at 4000 bytes (the BEAM reads with `{:line, 4096}`);
a longer one is not written and the `oversize_line` error is emitted
instead. Every emitter bounds its own size so that never happens to a
valid event: `started` echoes `name`/`product`/`alsa_device` sanitized
and cut to 128 bytes each (worst case with the full hi-res format menu is
about 3.4 KB), and server-supplied text (titles, group names) is
sanitized and cut to 256/128 bytes. The unit tests check both worst
cases.

The `started` event's `formats` array is the menu of audio formats advertised
to the Sendspin server (the server picks one and encodes to it). It always
includes the baseline floor (FLAC/OPUS/PCM at 44.1/48 kHz, 16-bit). When the
`--alsa-device` is a hardware card (`plughw:N,0`/`hw:N,0`), the device is
probed at startup for the rates and bit depths it actually accepts, and the
matching hi-res FLAC + PCM entries (24/32-bit, up to 384 kHz) are added. A
probe failure or a non-card device (`default`) advertises the floor only.

The `listening` event fires once, when the WebSocket listener is confirmed
bound (signalled by the library itself via the patch-0003 hook —
sendspin-cpp binds lazily on its first `loop()` tick, so `started` does NOT
imply the port accepts connections yet). `Audio.Player` gates its mDNS
advertisement on this event: Music Assistant's discovery connect is one-shot
(aiosendspin `retry_initial_connection=False`), so advertising before the
listener is up hands MA a connection-refused that orphans the player until
the mDNS record next flaps. It also carries the Sendspin `client_id` (see
below), which `Audio.Player` advertises as the TXT `client_id` entry.

## Display roles

With `--display-roles` the binary also registers the metadata, controller,
color, artwork (one album slot, JPEG at `--artwork-size`, when
`--artwork-dir` is given) and visualizer (spectrum + loudness) roles, and
`started` carries `"display_roles":true`. The BEAM passes it to the one
HDMI output that drives the TV UI (`UniversalProxy.Audio.DisplayRoles`).
Extra events:

```jsonc
{"event":"metadata","title":"..","artist":"..","album_artist":"..","album":"..","year":1999,"track":3,"progress":{"track_progress":1234,"track_duration":200000,"playback_speed":1000,"progress_age_ms":0}}
{"event":"metadata_clear"}
{"event":"controller_state","supported_commands":["play","pause","next"],"volume":40,"muted":false,"repeat":"off","shuffle":false} // + "seek_max_ms" when known
{"event":"controller_clear"}
{"event":"controller_result","command":"next","ok":true}   // reply to the controller command
{"event":"group","playback_state":"playing","group_id":"..","group_name":".."}
{"event":"color","background_dark":[20,20,30],"primary":[200,40,40]} // also background_light, accent, on_dark, on_light
{"event":"color_clear"}
{"event":"artwork","slot":0,"path":"<dir>/<sha256>.jpg","format":"jpeg","width":480,"height":480,"bytes":51234,"seq":7,"lateness_ms":3}
{"event":"artwork_clear","slot":0}
{"event":"viz_enable","value":true}                         // ack of viz_enable
{"event":"viz","lead_ms":98,"loudness":180,"bins":[0,12,255]}
{"event":"viz_clear"}                                       // visualizer stream ended or cleared
```

Fields the server leaves out are omitted. `metadata`, `controller_state`,
`color` and `artwork`/`artwork_clear` fire on the main loop at the
server's timestamp. `track_progress` is the position at that timestamp;
`progress_age_ms` is how long before the event that was on the client
clock (non-zero when the update was delivered late), so the current
position is `track_progress + (progress_age_ms + elapsed) *
playback_speed / 1000`.

Artwork bytes are written on the library's decode thread to
`<artwork-dir>/<sha256>.<jpg|png>` via a dot-temp and rename; the
`artwork` event follows at display time (`seq` counts decoded images;
`width`/`height` are the requested size, which the server must deliver
exactly). The slot is ack-gated (`require_frame_done`, acked with
`frame_done()` after each `artwork`/`artwork_clear`), so the library holds
the next image's decode until the current one is shown. The binary owns
retention: it keeps the last `--artwork-keep` displayed files, deletes a
decoded image superseded before its display, and never deletes a file
that is pending display again (same content, same name).

`viz` frames come from the visualizer's drain thread, `--viz-offset-ms`
ahead of their display time, only while `viz_enable` is on (off at start).
Values are 0..255 (the library's 0..65535 shifted down); `bins` are
max-pooled to `--viz-bins` if the server sends more. `lead_ms` is relative
(display time minus now on the client clock), never an absolute
timestamp. The library has no runtime switch for the visualizer
subscription (its stream config is fixed in `client/state`), so
`viz_enable` gates only what this binary writes. Frames are written under one lock
with `viz_clear` and the `viz_enable` ack (`viz_gate.h`): no frame follows
a `viz_enable:false` ack, and none due before the latest stream
start/end/clear (plus 2 ms) is written, which binds each frame to its
stream by its delivery time since the listener API carries no stream id.

## Identity and admission

Since sendspin-cpp v0.9.0 (Sendspin 1.0.0-rc1) the `client_id` is not
configured. The library derives it as base64url (no padding) of a static
X25519 public key, generates that keypair on first start, and stores it
through the persistence provider. `FilePersistence` writes each library
blob as one file in `--state-dir` (dir `0700`, files `0600`, written via
temp file + fsync + rename), so the identity survives respawns and
reboots. A state dir that cannot be created fails the process (with a
`state_dir` error event, before `started`) before the
client starts, rather than letting it mint an identity it cannot keep. The
library only logs a failed save of a freshly generated keypair (a full or
read-only disk) and starts anyway, so the binary checks for that after
`start()` and exits with a `state_dir` error event before `listening`. A
`keypair` file that exists but cannot be read (permissions, I/O error) is
treated the same way: the library would mint a new identity, so
`FilePersistence` refuses to save over the unreadable file, leaving it
untouched, and the process exits with that error instead of changing the
`client_id`.

The library's output-delay blob is deliberately not stored: the BEAM side
already owns that value (persisted from the `static_delay` event and
passed back via `--initial-static-delay-ms`), and a stored blob would
outrank the CLI value.

The connection is Noise-encrypted. The player calls
`set_unpaired_access_enabled(true)` before `start()`, so a server that has
not paired with it can still admit it: Music Assistant approves a
player-only client that offers unpaired access without any setup step.

The library always advertises the `pairing_psk` method in `client/hello`.
It backs it with a Pairing PSK it generates on first start and stores
under the `pairing_psk` key, so `--state-dir` holds pairing secrets (the
PSK and any pairing records) as well as the identity key.

After a successful `start()` the binary writes `client.pairing_token()`
(the 107-character `SP:0…` string, RFC 4648 base32 with `2` mapped to
`9`) to `<state-dir>/pairing_token` through the same atomic `0600` write
path, rewriting it on every start so it follows the stored PSK. A server
that offers a "Pairing token" option (Music Assistant 2.10.7+) takes this
string to pair over the PSK instead of relying on unpaired access. The
token is a long-lived pairing secret, so it is never printed: the BEAM
side reads the file only when a user asks to see or copy it. If the token
is unavailable or the write fails, the binary emits a non-fatal
`pairing_token` error event (without the token) and keeps running.

We do not offer
the pairing-code methods (dynamic or static code); those would need UI to
show the code (`on_display_pairing_code`) and to confirm the pairing
window.

## Stdin commands

```jsonc
{"cmd":"set_volume","value":75}
{"cmd":"set_muted","value":true}
{"cmd":"set_volume_external","value":true}
{"cmd":"controller","value":3}      // --display-roles only
{"cmd":"viz_enable","value":true}   // --display-roles only
{"cmd":"pcm_tap","value":true}
{"cmd":"shutdown"}
```

`controller` sends a transport command through the controller role. The
value is sendspin-cpp's `SendspinControllerCommand`: 0 play, 1 pause, 2
stop, 3 next, 4 previous (others are dropped). The reply is a
`controller_result` event, `ok: false` when the library refused it (not in
the server's `supported_commands`, or no server connected).

The parser is strict on shape but lenient on whitespace. Unknown commands are
ignored silently.

`set_volume_external` hands volume to an outboard stage (an AVR driven over
HDMI-CEC). While it is on, the sink writes samples at unity gain and never
mutes them. Volume and mute are still stored, reported to the server and
emitted as `volume`/`mute` events exactly as in software mode. Turning it off resumes software scaling at the stored values. Default
off; `--external-volume` starts in it.

## PCM tap

`{"cmd":"pcm_tap","value":true}` maps the ring file at `--pcm-tap-path`
(created `0644` if missing; `Audio.Player` uses `/run/up-pcm-<client_id>`
on target, a tmpfs) and from then on the playback thread copies every
period it plays into it, **before** software volume, so the visualizer
does not follow the volume. `false` stops the copy and unmaps the ring;
the file stays. Off at start; while off the playback thread pays one
relaxed atomic load per period. The tap works with or without
`--display-roles`. Both are acked with a `pcm_tap` event; a failed `true`
(no path, `open`/`ftruncate`/`mmap` error) acks `value:false` with
`ok:false` and the error.

The ring is one file, little-endian, naturally aligned. The layout and a
reader live in `src/pcm_tap.h`, which a reader in another process (the
`milkdrop_renderer`) copies:

| Offset | Size | Field | |
| ------ | ---- | ----- | - |
| 0  | u32 | `magic` | `0x4D435055` ("UPCM"), written last at init |
| 4  | u16 | `version` | 1 |
| 6  | u16 | `header_bytes` | 64 |
| 8  | u32 | `seq` | seqlock over `epoch` + `sample_rate`, odd while changing |
| 12 | u32 | `epoch` | bumps on stream start, format change, flush, tap off/on |
| 16 | u32 | `sample_rate` | Hz, 0 = no stream |
| 20 | u16 | `channels` | 2 (mono duplicated; more than 2 keep the first two) |
| 22 | u16 | `format` | 1 = S16_LE interleaved (24/32-bit input keeps its top 16 bits) |
| 24 | u32 | `capacity_frames` | F = 65536 (~1.4 s at 48 kHz), power of two |
| 28 | u32 | `chunk_capacity` | C = 1024, power of two |
| 32 | u64 | `frames_reserved` | raised before samples are written |
| 40 | u64 | `frames_written` | the write index: total frames committed |
| 48 | u64 | `chunks_reserved` | raised before a record is written |
| 56 | u64 | `chunks_written` | total chunks committed |
| 64 | 24 × C | chunk records | `{u64 start_frame, i64 t_end_us, u32 frames, u32 epoch}` |
| 64 + 24·C (24640) | 4 × F | samples | `int16[F][2]`; frame `i` in slot `i % F` |

The counters never wrap (only slot offsets do); the 64-bit ones are
lock-free atomics. Each period played adds one chunk record (`n`-th chunk
in slot `n % C`): `t_end_us` is the `CLOCK_MONOTONIC_RAW` play time of its
last frame, `now_us() + snd_pcm_delay()` taken right after the
`snd_pcm_writei` that queued it, the same timestamp the sync feedback
uses. Within an epoch frame indices are contiguous, so frame `i` of a
record plays `(start_frame + frames - 1 - i) / sample_rate` before
`t_end_us`.

The writer is wait-free. A reader copies records and samples covered by
the `*_written` counters, then re-reads `seq` and the `*_reserved`
counters: if `seq` moved, or anything it copied is older than
`reserved - capacity`, the writer may have overwritten it mid-copy and
the read is discarded (`Status::Retry`). Readers use only records of the
current epoch, so after a new epoch they see no data until it has some.
`Reader::read_ending_at(t, n, ...)` returns the `n` frames ending at play
time `t`, zero-filled before the epoch's first frame and before any gap in
play times of over a chunk (an underrun; shorter gaps are taken as
timestamp jitter). It returns `NoData` when no PCM of the current epoch
plays at `t` (before the epoch, after the newest chunk, or over a chunk
into a gap), or when the window reaches back past the oldest chunk record
kept, whose history is then unknown (only with chunks shorter than
`F / C` frames).

Enabling maps the file on the main thread (with `MAP_POPULATE`) and
publishes the writer to the playback thread through an atomic pointer.
Disabling swaps the pointer to null, then waits out a playback-thread
use in flight (a `tap_busy_` flag the playback thread raises around each
commit, a one-period memcpy), so the playback thread itself never waits.
Re-enabling on a file of the same layout keeps its counters and starts a
new epoch, so a reader that kept it mapped resyncs. The reserved counters
never decrease: a writer killed mid-commit leaves them past the written
ones, over samples it may have overwritten, and the next writer continues
from them.

## Cross-target compilation

On Nerves targets, Mix sets `CC`, `CXX`, `CFLAGS`, `LDFLAGS`, and `STRIP` for
the active `nerves_system_*` toolchain. CMake honours `CC` / `CXX` from the
environment and the toolchain's sysroot supplies `libasound`. No CMake
toolchain file is needed.

If a future target's `nerves_system_*` rootfs does not include `alsa-lib`,
options are:

1. Vendor a derivative Nerves system with `BR2_PACKAGE_ALSA_LIB=y`
2. Statically link libasound (would require a static build inside the Buildroot)

## Licensing

- `alsa_pipe_sink.{h,cpp}` — Apache-2.0, attributed to
  [LeoLTM/sendspin-armv6](https://github.com/LeoLTM/sendspin-armv6) (see
  `LICENSE-sendspin-armv6`)
- `main.cpp`, `CMakeLists.txt`, patches — same Apache-2.0 license; copyright
  to the universal_proxy contributors
- `sendspin-cpp` — Apache-2.0, fetched at build time from
  [Sendspin/sendspin-cpp](https://github.com/Sendspin/sendspin-cpp)
