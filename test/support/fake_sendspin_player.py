#!/usr/bin/env python3
"""Fake sendspin_player for Audio.Player tests.

Mimics the line-delimited JSON wire protocol of the real C++ binary as
documented in c_src/sendspin_player/README.md ("Stdout events" /
"Stdin commands"). Stays narrow on purpose — only the events the
Player tests need to drive.

  startup       → {"event":"started","version":...,"port":...,"name":...,"alsa_device":...}
                  {"event":"volume","value":<initial_volume>}
                  {"event":"volume_external","value":true} (only with --external-volume)
                  {"event":"static_delay","value":<initial_static_delay_ms>}
                  (writes <state-dir>/pairing_token, 0600; never printed)
                  {"event":"listening","port":...,"client_id":...}
  stdin commands → stdout events
    {"cmd":"set_volume","value":N} → {"event":"volume","value":N}
    {"cmd":"set_muted","value":B}  → {"event":"mute","value":B}
    {"cmd":"set_volume_external","value":B} → {"event":"volume_external","value":B}
                                   (non-bool value dropped, like the real binary)
    {"cmd":"pcm_tap","value":B}    → {"event":"pcm_tap","value":B}, or with B true
                                     and no --pcm-tap-path the ok:false ack
                                     (no ring file is written)
    {"cmd":"shutdown"}             → {"event":"shutdown"} + exit 0
    {"cmd":"force_exit"}           → exit 7 (test-only; no event)

  with --display-roles (dropped otherwise, like the real binary):
    {"cmd":"controller","value":0..4} → {"event":"controller_result","command":..,"ok":true}
    {"cmd":"viz_enable","value":B}    → {"event":"viz_enable","value":B}
    {"cmd":"emit_display"}  → metadata, controller_state, group, color, and an
                              artwork event whose file is written to
                              --artwork-dir as <sha256>.jpg (test-only)
    {"cmd":"emit_viz"}      → one viz frame of --viz-bins bins, only while
                              viz_enable is on (test-only)

  test-only, any mode:
    {"cmd":"emit_event","event":{...}} → that event, verbatim

Unknown commands are silently dropped, matching the real binary's
parse_command behaviour.

No external dependencies. sys.stdout is explicitly flushed after every
write so the BEAM port sees events line-by-line.
"""
import argparse
import hashlib
import json
import os
import sys

# Hard-coded version string so the `started` event has a stable shape
# for assertions. The real binary substitutes its own VERSION here.
FAKE_VERSION = "0.0.0-fake"

# Stands in for the id the real binary derives from the keypair in
# --state-dir: base64url (no padding) of 32 bytes, so the same 43-char
# shape. Tests assert on this constant.
FAKE_CLIENT_ID = "ZmFrZS1zZW5kc3Bpbi1wbGF5ZXItaWQtMzJieXRlcyE"

# Same shape as the real binary's token ("SP:" + version "0" + 103 base32
# chars, 2 mapped to 9). Like the real one it is only ever written to
# <state-dir>/pairing_token, never to stdout/stderr.
FAKE_PAIRING_TOKEN = "SP:0" + ("FAKETOKEN" * 12)[:103]

CONTROLLER_COMMANDS = ["play", "pause", "stop", "next", "previous"]


def write_pairing_token(state_dir):
    """Mirror main.cpp: atomic 0600 write into a 0700 dir; a failure is a
    non-fatal `pairing_token` error event that never carries the token."""
    try:
        os.makedirs(state_dir, mode=0o700, exist_ok=True)
        tmp = os.path.join(state_dir, ".pairing_token.tmp")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(FAKE_PAIRING_TOKEN)
        os.replace(tmp, os.path.join(state_dir, "pairing_token"))
    except OSError:
        emit({"event": "error", "kind": "pairing_token",
              "msg": "failed to write the pairing token"})


def emit(event):
    sys.stdout.write(json.dumps(event) + "\n")
    sys.stdout.flush()


def emit_display(args, seq):
    """The display events a real server session produces, in a plausible
    order. The artwork bytes are written like the real binary does:
    content-named, via a dot-temp and rename."""
    emit({"event": "metadata", "title": "Fake Song", "artist": "Fake Artist",
          "album_artist": "Fake Artist", "album": "Fake Album", "year": 2001,
          "track": 3, "progress": {"track_progress": 1000,
                                   "track_duration": 200000,
                                   "playback_speed": 1000,
                                   "progress_age_ms": 250}})
    emit({"event": "controller_state",
          "supported_commands": ["play", "pause", "stop", "next", "previous"],
          "volume": 40, "muted": False, "repeat": "off", "shuffle": False})
    emit({"event": "group", "playback_state": "playing",
          "group_id": "fake-group", "group_name": "Fake Group"})
    emit({"event": "color", "background_dark": [10, 20, 30], "primary": [200, 40, 40]})
    if args.artwork_dir:
        data = ("fake-jpeg-%d" % seq).encode()
        sha = hashlib.sha256(data).hexdigest()
        path = os.path.join(args.artwork_dir, sha + ".jpg")
        tmp = os.path.join(args.artwork_dir, "." + sha + ".jpg.tmp")
        os.makedirs(args.artwork_dir, exist_ok=True)
        with open(tmp, "wb") as f:
            f.write(data)
        os.replace(tmp, path)
        width, height = (int(v) for v in args.artwork_size.split("x"))
        emit({"event": "artwork", "slot": 0, "path": path, "format": "jpeg",
              "width": width, "height": height, "bytes": len(data), "seq": seq,
              "lateness_ms": 0})


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--server", default="")
    p.add_argument("--alsa-device", default="")
    # Match the real binary's startup invariants (main.cpp parse_args):
    # `--name` and `--state-dir` are mandatory; passing an empty string
    # is a fatal error. Marking them required here means a regression
    # that drops either arg from `Audio.Player.build_cli_args/1`
    # surfaces as a non-zero exit from the fake, which Player.init
    # reports as `{:binary_exited, _}` and tests fail. The only thing the
    # fake writes to the state dir is the pairing token file.
    p.add_argument("--name", required=True)
    p.add_argument("--state-dir", required=True)
    p.add_argument("--product", default="sendspin_player")
    # Accepted like the real binary; NOT echoed in any event (it only
    # affects the client/hello device_info, which never hits stdout).
    p.add_argument("--mac", default="")
    p.add_argument("--mdns-port", type=int, default=0)
    p.add_argument("--initial-volume", type=int, default=50)
    p.add_argument("--initial-static-delay-ms", type=int, default=0)
    p.add_argument("--external-volume", action="store_true")
    p.add_argument("--display-roles", action="store_true")
    p.add_argument("--artwork-dir", default="")
    p.add_argument("--artwork-size", default="480x480")
    p.add_argument("--artwork-keep", type=int, default=8)
    p.add_argument("--viz-bins", type=int, default=32)
    p.add_argument("--viz-rate", type=int, default=20)
    p.add_argument("--viz-offset-ms", type=int, default=0)
    p.add_argument("--pcm-tap-path", default="")
    p.add_argument("--log-level", default="info")
    args = p.parse_args()

    # Empty-string defense: argparse `required=True` only checks
    # presence, not non-empty. Real binary explicitly rejects empties.
    if not args.name or not args.state_dir:
        sys.stderr.write("Error: --name and --state-dir must be non-empty\n")
        return 2

    # Match the real binary's `started` payload: event, version, port,
    # name, alsa_device (see c_src/sendspin_player/src/main.cpp:626-633).
    # state_dir, mdns_port (the CLI arg, same as port here), server,
    # and initial_volume are NOT echoed on `started`.
    started = {
        "event": "started",
        "version": FAKE_VERSION,
        "port": args.mdns_port,
        "name": args.name,
        "product": args.product,
        "alsa_device": args.alsa_device,
    }
    if args.display_roles:
        started["display_roles"] = True
    emit(started)
    viz_enabled = False
    artwork_seq = 0

    # Like the real binary, write the pairing token after start() and
    # before the initial `volume` event.
    write_pairing_token(args.state_dir)

    # Real binary emits a separate `volume` event after `started` to
    # publish the initial volume (main.cpp:642-649).
    emit({"event": "volume", "value": args.initial_volume})

    if args.external_volume:
        emit({"event": "volume_external", "value": True})

    # ...and a `static_delay` event publishing the server-adjustable static
    # output delay (the real binary reports get_output_delay_ms()).
    emit({"event": "static_delay", "value": args.initial_static_delay_ms})

    # ...and finally `listening`, once the WebSocket listener is bound
    # (the real binary probes the port from its main loop). This is
    # what gates Audio.Player's mDNS registration. Tests set
    # FAKE_SKIP_LISTENING=1 to simulate a binary whose listener never
    # comes up and assert that no mDNS advertisement happens, or
    # FAKE_LISTENING_PORT=N to report a bound port different from the
    # requested one (drives the wrong-port refusal path), or
    # FAKE_OMIT_CLIENT_ID=1 to leave `client_id` off the event.
    if os.environ.get("FAKE_SKIP_LISTENING") != "1":
        bound_port = int(os.environ.get("FAKE_LISTENING_PORT", args.mdns_port))
        listening = {"event": "listening", "port": bound_port}
        if os.environ.get("FAKE_OMIT_CLIENT_ID") != "1":
            listening["client_id"] = FAKE_CLIENT_ID
        emit(listening)

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            cmd = json.loads(line)
        except json.JSONDecodeError:
            continue

        if not isinstance(cmd, dict):
            continue

        kind = cmd.get("cmd")
        if kind == "set_volume":
            emit({"event": "volume", "value": cmd.get("value")})
        elif kind == "set_muted":
            emit({"event": "mute", "value": cmd.get("value")})
        elif kind == "set_volume_external":
            if isinstance(cmd.get("value"), bool):
                emit({"event": "volume_external", "value": cmd["value"]})
        elif kind == "pcm_tap":
            if isinstance(cmd.get("value"), bool):
                if cmd["value"] and not args.pcm_tap_path:
                    emit({"event": "pcm_tap", "value": False, "ok": False,
                          "error": "no --pcm-tap-path"})
                else:
                    emit({"event": "pcm_tap", "value": cmd["value"]})
        elif kind == "shutdown":
            emit({"event": "shutdown"})
            return 0
        elif kind == "force_exit":
            # Test-only: abnormal exit (non-zero status, no shutdown
            # event). Drives the `:exit_status` handling path in
            # Audio.Player.
            return 7
        elif kind == "emit_event" and isinstance(cmd.get("event"), dict):
            emit(cmd["event"])
        elif not args.display_roles:
            continue
        elif kind == "controller":
            value = cmd.get("value")
            if type(value) is int and 0 <= value < len(CONTROLLER_COMMANDS):
                emit({"event": "controller_result",
                      "command": CONTROLLER_COMMANDS[value], "ok": True})
        elif kind == "viz_enable":
            if isinstance(cmd.get("value"), bool):
                viz_enabled = cmd["value"]
                emit({"event": "viz_enable", "value": viz_enabled})
        elif kind == "emit_display":
            artwork_seq += 1
            emit_display(args, artwork_seq)
        elif kind == "emit_viz":
            if viz_enabled:
                emit({"event": "viz", "lead_ms": args.viz_offset_ms, "loudness": 128,
                      "bins": [(i * 8) % 256 for i in range(args.viz_bins)]})
        # Unknown commands: ignore, like the real binary.

    return 0


if __name__ == "__main__":
    sys.exit(main())
