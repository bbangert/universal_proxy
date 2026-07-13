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
    └── main.cpp             ours — CLI args + JSON stdout/stdin
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

The vendored files carry one local fix vs. upstream:

- `alsa_pipe_sink.cpp::stop()` — join the playback thread unconditionally
  so a self-clearing `running_` (after an ALSA write error inside the
  playback loop) does not leave the `std::thread` joinable, which would
  otherwise trip `std::terminate` from the destructor. The change is
  flagged inline with a comment in `alsa_pipe_sink.cpp` and is intended
  to be sent upstream — once it merges, we can re-vendor verbatim and
  drop the divergence.

`main.cpp` is our own adaptation of upstream `src/main.cpp`. The shape stayed
close to upstream so future patches there can land here with minimal effort.
Differences:

- CLI args (`getopt_long`) replace the INI config file
- JSON status events on **stdout** replace upstream's stderr free-form logs
- JSON command lines on **stdin** for runtime volume / mute / shutdown
- Sets `SendspinClientConfig::server_port` from `--mdns-port` so multiple
  binary instances can bind distinct ports (first-class upstream since
  sendspin-cpp #61)

## sendspin-cpp pin

Pinned via `FetchContent` to a **commit SHA** in `CMakeLists.txt`
(`SENDSPIN_CPP_REF` cache var). Currently `0c2b4585...`, upstream main
post-PR #81 (after v0.6.1, no release tag yet). We pin to a SHA rather
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
./_build/sendspin_player --name "Test" --client-id "test-uuid"
```

## CLI surface

The flags must match what `UniversalProxy.Audio.Player` passes — see the
`@moduledoc` in `lib/universal_proxy/audio/player.ex` (added in Phase 3).

| Flag                       | Required | Description                                  |
| -------------------------- | -------- | -------------------------------------------- |
| `--name STR`               | yes      | Friendly display name                        |
| `--client-id STR`          | yes      | Stable unique client identifier (UUID)       |
| `--server URL`             | no       | Outbound Sendspin server WebSocket URL       |
| `--product STR`            | no       | Product id in `device_info` (node name, e.g. `universal-proxy-07507f`); vendor is fixed to `Universal Proxy`. Default `sendspin_player` |
| `--alsa-device STR`        | no       | ALSA device, e.g. `plughw:0,0` (default = system default) |
| `--mdns-port INT`          | no       | Local WebSocket listener port (default 8928) |
| `--initial-volume 0..100`  | no       | Startup volume (default 50)                  |
| `--log-level STR`          | no       | `none\|error\|warn\|info\|debug\|verbose`    |
| `--help` / `-h`            | no       | Print usage and exit                         |
| `--version` / `-V`         | no       | Print version and exit                       |

## Stdout events

Each event is a single line of JSON. The binary writes events at startup, on
connection state changes, on stream lifecycle changes, on volume/mute
changes, and on errors.

```jsonc
{"event":"started","version":"0.1.0","port":8928,"name":"Out 1","product":"universal-proxy-07507f","alsa_device":"plughw:0,0","formats":[{"codec":"flac","channels":2,"rate":48000,"bit_depth":16}]}
{"event":"listening","port":8928}          // WebSocket listener confirmed bound
{"event":"connected","server":"ws://music.local:8927/sendspin"}
{"event":"disconnected"}
{"event":"stream_start","sample_rate":48000,"channels":2,"bit_depth":16,"codec":"opus"}
{"event":"stream_end"}
{"event":"time_sync","error_us":42.3}     // only at log-level >= debug
{"event":"volume","value":80}
{"event":"mute","value":false}
{"event":"error","kind":"alsa_configure","msg":"..."}
{"event":"shutdown"}
```

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
the mDNS record next flaps.

## Stdin commands

```jsonc
{"cmd":"set_volume","value":75}
{"cmd":"set_muted","value":true}
{"cmd":"shutdown"}
```

The parser is strict on shape but lenient on whitespace. Unknown commands are
ignored silently.

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
