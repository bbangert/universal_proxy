#!/usr/bin/env python3
"""Fake milkdrop_renderer for Display.MilkDrop tests.

Speaks the line-JSON protocol documented in UniversalProxy.Display.MilkDrop
("Renderer CLI contract" / "Line-JSON protocol"). Stays narrow on purpose:
only what the tests drive.

  startup        → {"event":"prepared","argv":[...],"skip":[...]}
                   (argv and the --skip-file contents are test-only fields)
  stdin commands → stdout events
    {"cmd":"take"}    → {"event":"presenting"}
    {"cmd":"release"} → {"event":"released"}
    {"cmd":"exit"}    → {"event":"exiting","reason":"requested"} + exit 0
    {"cmd":"next"|"prev"}  → {"event":"preset","file":"p<N>.milk","locked":B,"cause":...}
    {"cmd":"lock"|"unlock"}→ the same preset event with the new lock
  test-only:
    {"cmd":"emit","line":"<raw>"} → <raw> verbatim on its own line
    {"cmd":"crash","status":N}    → exit N, no event
    {"cmd":"thermal"}             → {"event":"exiting","reason":"thermal"} + exit 0
    {"cmd":"ignore_eof"}          → on stdin EOF, hang instead of exiting
    {"cmd":"stall"}               → stop reading stdin (hang forever)

Startup behaviour for tests that don't hold the port (Display.State starts
it) comes from an optional <pack-dir>/fake.json:
    {"hold_prepared": true}       → no prepared until {"cmd":"prepare"}
    {"ignore": ["release", ...]}  → log those commands but don't act on them
    {"take_error": "<reason>"}    → answer take with an error event instead
    {"take_exit": N}              → exit N on take, no event

It touches <skip-file>.spawned first thing, so tests can tell it was ever
started. Every stdin line is appended to <skip-file>.cmds, so tests can
check what was written. On stdin EOF it writes <skip-file>.eof and exits 0, as the
real binary must.

No external dependencies; stdout is flushed after every write.
"""
import argparse
import json
import os
import sys
import time


def emit_raw(line):
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def emit(event):
    emit_raw(json.dumps(event))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", required=True)
    parser.add_argument("--pack-dir", required=True)
    parser.add_argument("--ladder", required=True)
    parser.add_argument("--rotate-s", required=True, type=int)
    parser.add_argument("--skip-file", required=True)
    parser.add_argument("--high-frequency", action="store_true")
    parser.add_argument("--locked")
    parser.add_argument("--pcm-ring")
    parser.add_argument("--connector")
    args = parser.parse_args()

    open(args.skip_file + ".spawned", "w").close()

    with open(args.skip_file) as f:
        skip = [line for line in f.read().split("\n") if line]

    cmd_log = args.skip_file + ".cmds"
    ignore_eof = False

    fake = {}
    fake_path = os.path.join(args.pack_dir, "fake.json")
    if os.path.exists(fake_path):
        with open(fake_path) as f:
            fake = json.load(f)
    ignore = set(fake.get("ignore", []))

    preset = 0
    locked = args.locked is not None

    def emit_preset(cause):
        emit({"event": "preset", "file": "p%d.milk" % preset, "locked": locked,
              "cause": cause})

    def prepared():
        emit({"event": "prepared", "argv": sys.argv[1:], "skip": skip})

    if not fake.get("hold_prepared"):
        prepared()

    while True:
        line = sys.stdin.readline()
        if line == "":
            if ignore_eof:
                while True:
                    time.sleep(1)
            with open(args.skip_file + ".eof", "w") as f:
                f.write("eof\n")
            sys.exit(0)

        with open(cmd_log, "a") as f:
            f.write(line)

        try:
            cmd = json.loads(line)
        except ValueError:
            continue

        name = cmd.get("cmd")
        if name in ignore:
            continue
        if name == "take" and "take_exit" in fake:
            sys.exit(int(fake["take_exit"]))
        elif name == "take" and "take_error" in fake:
            emit({"event": "error", "reason": fake["take_error"]})
        elif name == "take":
            emit({"event": "presenting", "modeset": False, "master_ms": 1})
        elif name == "prepare":
            prepared()
        elif name in ("next", "prev"):
            preset = preset + 1 if name == "next" else max(preset - 1, 0)
            emit_preset(name)
        elif name in ("lock", "unlock"):
            locked = name == "lock"
            emit_preset(name)
        elif name == "thermal":
            emit({"event": "exiting", "reason": "thermal"})
            sys.exit(0)
        elif name == "release":
            emit({"event": "released"})
        elif name == "exit":
            emit({"event": "exiting", "reason": "requested"})
            sys.exit(0)
        elif name == "emit":
            emit_raw(cmd["line"])
        elif name == "crash":
            sys.exit(int(cmd["status"]))
        elif name == "ignore_eof":
            ignore_eof = True
        elif name == "stall":
            while True:
                time.sleep(1)


if __name__ == "__main__":
    main()
