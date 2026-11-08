#!/usr/bin/env python3
"""Fake milkdrop_renderer for Display.MilkDrop tests.

Speaks the line-JSON protocol documented in UniversalProxy.Display.MilkDrop
("Renderer CLI contract" / "Line-JSON protocol"). Stays narrow on purpose:
only what the tests drive.

  startup        → {"event":"prepared","argv":[...],"skip":[...],"selection":S}
                   (argv, the --skip-file contents and the decoded
                   --selection-file, null when none, are test-only fields),
                   then with --selection-file the selection event below
  stdin commands → stdout events
    {"cmd":"take"}    → {"event":"presenting"}
    {"cmd":"release"} → {"event":"released"}
    {"cmd":"exit"}    → {"event":"exiting","reason":"requested"} + exit 0
    {"cmd":"next"|"prev"}  → {"event":"loading","preset":"p<N>.milk"}, then
                             {"event":"preset","file":"p<N>.milk","locked":B,"cause":...}
    {"cmd":"lock"|"unlock"}→ the same preset event with the new lock
    {"cmd":"reload_user"}  → {"event":"user_reloaded","presets":N,"added":A,
                             "removed":R,"rejected":0}, counted from
                             <user-dir>/manifest.json (none without one)
    {"cmd":"reload_selection"} → {"event":"selection","gen":N,"eligible":E,
                             "playlist_fallback":B,"hidden_fallback":B}, from
                             --selection-file over the catalog p0..p9.milk
    {"cmd":"play","preset":F,"lock":B}
                           → {"event":"loading","preset":F}, then
                             {"event":"preset","file":F,"locked":B,"cause":"play"};
                             for F in fake.json's "refuse" (F → reason)
                             {"event":"play_refused","preset":F,"reason":R}
                             (load_failed also emits skip, as the binary)
  test-only:
    {"cmd":"emit","line":"<raw>"} → <raw> verbatim on its own line
    {"cmd":"crash","status":N}    → exit N, no event
    {"cmd":"thermal"}             → {"event":"exiting","reason":"thermal"} + exit 0
    {"cmd":"ignore_eof"}          → on stdin EOF, hang instead of exiting
    {"cmd":"stall"}               → stop reading stdin (hang forever, silent)
    {"cmd":"hang_loading","preset":F}
                                  → {"event":"loading","preset":F}, then as stall
    {"cmd":"crash_on_loading","preset":F,"status":N}
                                  → {"event":"loading","preset":F} + exit N
    {"cmd":"stats","ms":N}        → {"event":"stats"} every N ms from then on

Startup behaviour for tests that don't hold the port (Display.State starts
it) comes from an optional <pack-dir>/fake.json:
    {"hold_prepared": true}       → no prepared until {"cmd":"prepare"}
    {"ignore": ["release", ...]}  → log those commands but don't act on them
    {"take_error": "<reason>"}    → answer take with an error event instead
    {"take_exit": N}              → exit N on take, no event
    {"ignore_eof": true}          → as the ignore_eof command, from the start
    {"startup_preset": F}         → loading F and preset F (cause start) before
                                    prepared, as the real binary's start
    {"take_hang_loading": F}      → answer take with loading F, then as stall
    {"refuse": {F: reason}}       → play F is refused with reason
    {"play_delay_ms": N}          → answer each play N ms after reading it
    {"play_delays": [N, ...]}     → the same for the first plays, in order

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
import threading
import time


_out = threading.Lock()


def emit_raw(line):
    with _out:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()


def emit(event):
    emit_raw(json.dumps(event))


def stall():
    while True:
        time.sleep(1)


def stats_every(ms):
    while True:
        time.sleep(ms / 1000.0)
        emit({"event": "stats", "fps": 30})


def user_files(user_dir):
    if user_dir is None:
        return set()
    try:
        with open(os.path.join(user_dir, "manifest.json")) as f:
            return {"user/" + p["file"] for p in json.load(f).get("presets", [])}
    except (OSError, ValueError):
        return set()


CATALOG = ["p%d.milk" % i for i in range(10)]


def read_selection(path):
    if path is None:
        return None
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


# PresetManager::rotation_pool() over the fake catalog (every preset
# eligible): the first non-empty of the unhidden playlist presets (while it
# is enabled), the unhidden ones (playlist_fallback iff the playlist is
# enabled), all of them (hidden_fallback).
def selection_event(sel):
    sel = sel or {}
    hidden = set(sel.get("hidden", []))
    playlist = set(sel.get("playlist", []))
    enabled = bool(sel.get("playlist_enabled"))
    unhidden = [p for p in CATALOG if p not in hidden]
    listed = [p for p in unhidden if p in playlist]
    event = {"event": "selection", "gen": sel.get("gen", 0),
             "playlist_fallback": False, "hidden_fallback": False}
    if enabled and listed:
        event["eligible"] = len(listed)
        return event
    event["playlist_fallback"] = enabled
    if unhidden:
        event["eligible"] = len(unhidden)
        return event
    event["eligible"] = len(CATALOG)
    event["hidden_fallback"] = len(CATALOG) > 0
    return event


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", required=True)
    parser.add_argument("--pack-dir", required=True)
    parser.add_argument("--user-dir")
    parser.add_argument("--selection-file")
    parser.add_argument("--ladder", required=True)
    parser.add_argument("--rotate-s", required=True, type=int)
    parser.add_argument("--min-fps", required=True, type=int)
    parser.add_argument("--skip-file", required=True)
    parser.add_argument("--high-frequency", action="store_true")
    parser.add_argument("--locked")
    parser.add_argument("--pcm-ring")
    parser.add_argument("--connector")
    parser.add_argument("--card")
    args = parser.parse_args()

    open(args.skip_file + ".spawned", "w").close()

    with open(args.skip_file) as f:
        skip = [line for line in f.read().split("\n") if line]

    cmd_log = args.skip_file + ".cmds"

    fake = {}
    fake_path = os.path.join(args.pack_dir, "fake.json")
    if os.path.exists(fake_path):
        with open(fake_path) as f:
            fake = json.load(f)
    ignore = set(fake.get("ignore", []))
    ignore_eof = bool(fake.get("ignore_eof"))

    preset = 0
    # The preset showing: what lock/unlock events name.
    current = "p0.milk"
    locked = args.locked is not None
    uploads = user_files(args.user_dir)

    def emit_preset(cause):
        emit({"event": "preset", "file": current, "locked": locked, "cause": cause})

    refuse = fake.get("refuse", {})
    play_delays = list(fake.get("play_delays", []))

    def prepared():
        emit({"event": "prepared", "argv": sys.argv[1:], "skip": skip,
              "selection": read_selection(args.selection_file)})
        if args.selection_file is not None:
            emit(selection_event(read_selection(args.selection_file)))

    if "startup_preset" in fake:
        current = fake["startup_preset"]
        emit({"event": "loading", "preset": fake["startup_preset"]})
        emit({"event": "preset", "file": fake["startup_preset"], "locked": locked,
              "cause": "start"})

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
        elif name == "take" and "take_hang_loading" in fake:
            emit({"event": "loading", "preset": fake["take_hang_loading"]})
            stall()
        elif name == "take" and "take_error" in fake:
            emit({"event": "error", "reason": fake["take_error"]})
        elif name == "take":
            emit({"event": "presenting", "modeset": False, "master_ms": 1})
        elif name == "prepare":
            prepared()
        elif name in ("next", "prev"):
            preset = preset + 1 if name == "next" else max(preset - 1, 0)
            current = "p%d.milk" % preset
            emit({"event": "loading", "preset": current})
            emit_preset(name)
        elif name == "reload_user":
            now = user_files(args.user_dir)
            emit({"event": "user_reloaded", "presets": len(now),
                  "added": len(now - uploads), "removed": len(uploads - now),
                  "rejected": 0})
            uploads = now
        elif name == "reload_selection":
            emit(selection_event(read_selection(args.selection_file)))
        elif name == "play":
            delay = play_delays.pop(0) if play_delays else fake.get("play_delay_ms", 0)
            time.sleep(delay / 1000.0)
            target = cmd["preset"]
            if target in refuse:
                if refuse[target] == "load_failed":
                    emit({"event": "loading", "preset": target})
                    emit({"event": "skip", "preset": target, "reason": "compile"})
                emit({"event": "play_refused", "preset": target, "reason": refuse[target]})
            else:
                locked = bool(cmd.get("lock"))
                current = target
                emit({"event": "loading", "preset": target})
                emit({"event": "preset", "file": target, "locked": locked, "cause": "play"})
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
            stall()
        elif name == "hang_loading":
            emit({"event": "loading", "preset": cmd["preset"]})
            stall()
        elif name == "crash_on_loading":
            emit({"event": "loading", "preset": cmd["preset"]})
            sys.exit(int(cmd["status"]))
        elif name == "stats":
            threading.Thread(target=stats_every, args=(int(cmd["ms"]),), daemon=True).start()


if __name__ == "__main__":
    main()
