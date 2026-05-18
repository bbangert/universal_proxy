#!/usr/bin/env python3
"""Fake sendspin_player for Audio.Player tests.

Mimics the line-delimited JSON protocol of the real C++ binary:

  stdin commands  → stdout events

    {"cmd":"set_volume","value":N}   → {"event":"volume","value":N}
    {"cmd":"set_muted","value":B}    → {"event":"mute","value":B}
    {"cmd":"shutdown"}               → {"event":"shutdown_received"} + exit 0

On launch emits {"event":"started", "name":..., "client_id":..., "mdns_port":...,
"alsa_device":..., "server":...} so the test can verify CLI args were
forwarded correctly. Unknown commands are silently dropped, matching the
real binary's parse_command behaviour.

No external dependencies. sys.stdout is explicitly flushed after every
write so the BEAM port sees events line-by-line.
"""
import argparse
import json
import sys


def emit(event):
    sys.stdout.write(json.dumps(event) + "\n")
    sys.stdout.flush()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--server", default="")
    p.add_argument("--alsa-device", default="")
    p.add_argument("--name", default="")
    p.add_argument("--client-id", default="")
    p.add_argument("--mdns-port", type=int, default=0)
    p.add_argument("--initial-volume", type=int, default=50)
    p.add_argument("--log-level", default="info")
    args = p.parse_args()

    emit({
        "event": "started",
        "name": args.name,
        "client_id": args.client_id,
        "mdns_port": args.mdns_port,
        "alsa_device": args.alsa_device,
        "server": args.server,
        "initial_volume": args.initial_volume,
    })

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
            emit({"event": "shutdown_received"})
            return 0
        elif kind == "force_exit":
            # Test-only: simulate an abnormal binary exit (no
            # `shutdown_received` event, non-zero status). Drives the
            # `:exit_status` handling path in Audio.Player.
            return 7
        # Unknown commands: ignore, like the real binary.

    return 0


if __name__ == "__main__":
    sys.exit(main())
