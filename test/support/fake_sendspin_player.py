#!/usr/bin/env python3
"""Fake sendspin_player for Audio.Player tests.

Mimics the line-delimited JSON wire protocol of the real C++ binary as
documented in c_src/sendspin_player/README.md ("Stdout events" /
"Stdin commands"). Stays narrow on purpose — only the events the
Player tests need to drive.

  startup       → {"event":"started","version":...,"port":...,"name":...,"alsa_device":...}
                  {"event":"volume","value":<initial_volume>}
  stdin commands → stdout events
    {"cmd":"set_volume","value":N} → {"event":"volume","value":N}
    {"cmd":"set_muted","value":B}  → {"event":"mute","value":B}
    {"cmd":"shutdown"}             → {"event":"shutdown"} + exit 0
    {"cmd":"force_exit"}           → exit 7 (test-only; no event)

Unknown commands are silently dropped, matching the real binary's
parse_command behaviour.

No external dependencies. sys.stdout is explicitly flushed after every
write so the BEAM port sees events line-by-line.
"""
import argparse
import json
import sys

# Hard-coded version string so the `started` event has a stable shape
# for assertions. The real binary substitutes its own VERSION here.
FAKE_VERSION = "0.0.0-fake"


def emit(event):
    sys.stdout.write(json.dumps(event) + "\n")
    sys.stdout.flush()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--server", default="")
    p.add_argument("--alsa-device", default="")
    # Match the real binary's startup invariants
    # (c_src/sendspin_player/src/main.cpp:236-241): `--name` and
    # `--client-id` are mandatory; passing an empty string is a
    # fatal error. Marking them required here means a regression
    # that drops either arg from `Audio.Player.build_cli_args/1`
    # surfaces as a non-zero exit from the fake, which Player.init
    # reports as `{:binary_exited, _}` and tests fail.
    p.add_argument("--name", required=True)
    p.add_argument("--client-id", required=True)
    p.add_argument("--mdns-port", type=int, default=0)
    p.add_argument("--initial-volume", type=int, default=50)
    p.add_argument("--log-level", default="info")
    args = p.parse_args()

    # Empty-string defense: argparse `required=True` only checks
    # presence, not non-empty. Real binary explicitly rejects empties.
    if not args.name or not args.client_id:
        sys.stderr.write("Error: --name and --client-id must be non-empty\n")
        return 2

    # Match the real binary's `started` payload: event, version, port,
    # name, alsa_device (see c_src/sendspin_player/src/main.cpp:626-633).
    # client_id, mdns_port (the CLI arg, same as port here), server,
    # and initial_volume are NOT echoed on `started`.
    emit({
        "event": "started",
        "version": FAKE_VERSION,
        "port": args.mdns_port,
        "name": args.name,
        "alsa_device": args.alsa_device,
    })

    # Real binary emits a separate `volume` event after `started` to
    # publish the initial volume (main.cpp:642-649).
    emit({"event": "volume", "value": args.initial_volume})

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
        elif kind == "shutdown":
            emit({"event": "shutdown"})
            return 0
        elif kind == "force_exit":
            # Test-only: abnormal exit (non-zero status, no shutdown
            # event). Drives the `:exit_status` handling path in
            # Audio.Player.
            return 7
        # Unknown commands: ignore, like the real binary.

    return 0


if __name__ == "__main__":
    sys.exit(main())
