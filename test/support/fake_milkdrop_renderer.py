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
  test-only:
    {"cmd":"emit","line":"<raw>"} → <raw> verbatim on its own line
    {"cmd":"crash","status":N}    → exit N, no event
    {"cmd":"ignore_eof"}          → on stdin EOF, hang instead of exiting

Every stdin line is appended to <skip-file>.cmds, so tests can check what
was written. On stdin EOF it writes <skip-file>.eof and exits 0, as the
real binary must.

No external dependencies; stdout is flushed after every write.
"""
import argparse
import json
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
    args = parser.parse_args()

    with open(args.skip_file) as f:
        skip = [line for line in f.read().split("\n") if line]

    cmd_log = args.skip_file + ".cmds"
    ignore_eof = False

    emit({"event": "prepared", "argv": sys.argv[1:], "skip": skip})

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
        if name == "take":
            emit({"event": "presenting"})
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


if __name__ == "__main__":
    main()
