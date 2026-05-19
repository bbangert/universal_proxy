# Sendspin Audio Architecture

The Sendspin subsystem turns each ALSA playback output on the device into
an independently discoverable [Sendspin](https://github.com/Sendspin/sendspin-cpp)
player for synchronized multi-room audio. Servers like
[Music Assistant](https://music-assistant.io/) can group these players
with players on other devices on the LAN.

## Protocol overview

Sendspin is a WebSocket-based protocol for low-latency synchronized
playback. Servers push encoded audio (FLAC, Opus, or raw PCM at 16-bit
44.1/48 kHz stereo) to player clients, each of which decodes locally and
uses `snd_pcm_delay()` feedback to align playback to a shared
microsecond-precision clock.

Each player advertises itself over mDNS as `_sendspin._tcp.local.` with
a `name=` TXT attribute carrying the user-visible friendly name. Servers
locate players via the same mDNS service type.

## Component layout

```
lib/universal_proxy/audio/
├── audio.ex            # public API
├── supervisor.ex       # rest_for_one supervision (mirrors UART.Supervisor)
├── enumerate.ex        # parses /proc/asound/cards
├── store.ex            # DETS persistence keyed by {slot_sub, vid, pid}
├── server.ex           # 5 s hotplug poller; spawns/kills Players
├── mdns_discovery.ex   # stub (see "Known limitations" below)
└── player.ex           # GenServer per OS process

c_src/sendspin_player/  # C++ binary, vendored from LeoLTM/sendspin-armv6
priv/sendspin_player/<MIX_TARGET>/sendspin_player  # build artifact

lib/universal_proxy_web/live/
├── audio_live.ex       # /audio page (per-output cards)
└── overview_live.ex    # +audio summary row
```

### Supervision tree

```
UniversalProxy.Audio.Supervisor (:rest_for_one)
├── UniversalProxy.Audio.PlayerSupervisor (DynamicSupervisor)
├── UniversalProxy.Audio.Store (GenServer + DETS)
├── UniversalProxy.Audio.MdnsDiscovery (GenServer, stub)
└── UniversalProxy.Audio.Server (GenServer, 5 s poller)
```

`Audio.Player` processes live under `PlayerSupervisor` with
`restart: :temporary`. `Audio.Server` owns their lifecycle: it
monitors each PID, respawns on the next poll if one dies, and
terminates them in response to `set_enabled(_, false)` or hotplug
removes.

## Binary architecture

`sendspin_player` is a thin C++ wrapper around `sendspin-cpp` (vendored
via FetchContent, pinned to a specific commit SHA). It:

- Connects to a server via WebSocket
- Decodes audio in-process (Opus, FLAC, raw PCM)
- Writes PCM to ALSA via direct `libasound` calls, using
  `snd_pcm_delay()` for the microsecond clock-sync feedback Sendspin
  requires
- Emits **line-delimited JSON events** on stdout
  (`connected` / `disconnected` / `stream_start` / `time_sync` / etc.)
- Reads **line-delimited JSON commands** on stdin
  (`set_volume` / `set_muted` / `shutdown`)

PCM never crosses the BEAM boundary: audio flows entirely inside the
binary from WebSocket to ALSA. The BEAM side sees only status events
and issues control commands.

See [c_src/sendspin_player/README.md](../../c_src/sendspin_player/README.md)
for the full CLI surface and the JSON wire format.

### Why not a NIF?

A NIF crash takes the whole BEAM down, which on Nerves triggers a
reboot. A Port (OS process) crash is OS-isolated — the failing binary
restarts via supervision while the rest of the firmware keeps running.

### Why not `MuonTrap.Daemon`?

Reviewed during Phase 3. `MuonTrap.Daemon` closes stdin and forwards
stdout through Logger — neither is workable for bidirectional JSON
IPC. Wrapping `muontrap` with `--capture-output` would require
implementing the byte-ack protocol; the wrapper's only real benefit
(cgroup discipline) doesn't pay back on Nerves where a BEAM crash
reboots the device and the kernel reaps orphaned child processes.

Direct `Port.open/2` with `{:line, 4096}` packet mode is what
`vintage_net` uses for similar bidirectional IPC.

## Lifecycle

```
hotplug poll (5 s) ─┐
                    ├──→ Server.refresh_outputs/1
user set_enabled ───┤    diffs enumerated set against state.outputs:
user update_config ─┤
                    │      ├─ add → DETS row + start Player
                    │      ├─ remove → stop Player (keep DETS row)
                    │      └─ unchanged + enabled + no Player → respawn
                    │
                    └──→ broadcast on sendspin:* topics
```

`Audio.Player` lifecycle inside its process:

1. `init/1` checks `priv/.../sendspin_player` exists; refuses with
   `{:binary_missing, path}` if not (Server marks the key as
   missing-binary so subsequent polls don't retry until user
   re-enables).
2. `Port.open/2` with the binary + CLI args. Process traps exits so
   `DynamicSupervisor.terminate_child/2` runs `terminate/2`.
3. Registers `_sendspin._tcp` via `MdnsLite.add_mdns_service/1`.
4. Parses stdout lines as JSON, broadcasts on `sendspin:state` with
   the parsed map plus key.
5. `terminate/2` sends `{"cmd":"shutdown"}`, waits up to 500 ms for
   the binary to exit gracefully, force-kills via `kill -9` if not,
   then removes the mDNS service.

## PubSub conventions

Three topics owned by `Audio.Server`:

| Topic | Tag | Payload |
|---|---|---|
| `"sendspin:output_added"` | `:sendspin_output_added` | merged output map |
| `"sendspin:output_removed"` | `:sendspin_output_removed` | `%{key: key}` |
| `"sendspin:state"` | `:sendspin_state` | `{key, partial}` |

`:sendspin_state` partials come from two sources:

- **Server-originated** (config writes): keys are
  `:friendly_name | :volume | :muted | :enabled`. Values are
  pre-normalized — volume clamped to 0..100, muted cast to boolean.
- **Binary-originated**: has an `:event` key plus event-specific
  payload. Subscribers should pattern-match on `:event` and ignore
  unknown values for forward compatibility.

`Audio.Server` itself subscribes to `"sendspin:state"` so binary-
emitted volume / mute events (Music Assistant slider, group sync,
etc.) get persisted to DETS — otherwise a respawn after `kill -9`
would restore stale BEAM-side values.

## Identity model

Outputs are keyed by `{slot_sub, vendor_id, product_id}` tuples. For
built-in SoC cards (3.5 mm jack, HDMI) the vid/pid are `nil` and
`slot_sub` is the ALSA card name (`"bcm2835 Headphones"`). The schema
is forward-compatible with USB DACs: when those land (custom Nerves
system with `CONFIG_SND_USB_AUDIO`), they'll fill in real vid/pid and
the same key shape carries through unchanged.

## Known limitations (v1)

### Reachable outputs

On stock `nerves_system_rpi3` and siblings, only outputs on the built-in
BCM2835 SoC enumerate:

- 3.5 mm headphone jack (always present, `dtparam=audio=on` required)
- HDMI audio (present when an HDMI display is attached)

### USB DACs are NOT supported

The stock Nerves Pi systems don't enable `CONFIG_SND_USB_AUDIO`. USB
DACs will not enumerate as ALSA cards no matter what userspace does.
Adding support requires a custom Nerves system with the kernel option
turned on.

### I2S DAC HATs are NOT supported

The stock systems ship no audio device-tree overlays. Even the
PCM5102A codec module present in the rootfs cannot be bound to a HAT
without an overlay (`hifiberry-dac.dtbo` etc.). Adding HAT support
requires a custom Nerves system shipping the matching `.dtbo` and
loading it via `dtoverlay=` in `config.txt`. For non-PCM5102A chips
(PCM512x / ES9038 / AKM) the codec driver also needs enabling in the
kernel defconfig.

### mDNS browse is stubbed

`mdns_lite 0.9.1` (transitively pinned via `nerves_pack`) exposes
`add_mdns_service`/`remove_mdns_service`/`gethostbyname` but no PTR
browser. `Audio.MdnsDiscovery.current_server/0` returns `:error`;
players sit in their WebSocket reconnect loop until a server URL is
configured manually. The hook is in place — when `mdns_lite` ships
browsing, swap the stub implementation for a real one.

## Adding support for new hardware

To unlock USB DACs or I2S DAC HATs:

1. **Fork the Nerves system** for the target board
   (`nerves_system_rpi3`, etc.).
2. **Edit `nerves_defconfig`** to enable `CONFIG_SND_USB_AUDIO=y` for
   USB DACs, or the codec driver (`CONFIG_SND_SOC_PCM512x=y`, etc.)
   for I2S HATs.
3. **Drop the device-tree overlay** into `priv/rootfs/etc/dtbs/` and
   add `dtoverlay=hifiberry-dac` (or similar) to the system's
   `config.txt`.
4. **Build the system** and point the firmware's `mix.exs` at it.
5. The existing `Audio.Enumerate` parser already handles USB vid/pid
   and additional cards. No code changes should be needed in
   `lib/universal_proxy/audio/*`.

Look up specific HAT compatibility before committing — some boards
(e.g. Allo BOSS2,
[raspberrypi/linux#5505](https://github.com/raspberrypi/linux/issues/5505))
have known regressions on kernel 6.x.
