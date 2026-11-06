"""rpi3 measurements: the device sweep's per-preset records (device_sweep.py
writes them) and the shader trial's vc4 CSV (warp+comp GPU time)."""

import csv
import json
import re

from . import names

RUNG_RE = re.compile(r"\A[1-9][0-9]{1,4}x[1-9][0-9]{1,4}\Z")

# The per-preset rpi3 hints a sweep must not start from: the renderer
# refuses --locked on an rpi3 "skip" entry, and a rung hint would bias the
# rung the cost guard settles on. The sweep runs on a copy of the manifest
# without them (device_sweep.py), so a pack rebuilt from earlier results
# is measured afresh.
SWEEP_STRIPPED_KEYS = ("rpi3", "compile_ms", "eval_ms")


def sweep_manifest(doc):
    """`doc` (a parsed manifest) with the rpi3 hints taken out."""
    presets = [{k: v for k, v in e.items() if k not in SWEEP_STRIPPED_KEYS} for e in doc["presets"]]
    return {**doc, "presets": presets}


def parse_run(pid, text):
    """One headless renderer run of `pid` (its stdout+stderr, plus an
    "EXIT_STATUS n" line) as a sweep record."""
    events = []
    exit_status = None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("EXIT_STATUS "):
            exit_status = line.split(" ", 1)[1]
        elif line.startswith("{"):
            try:
                events.append(json.loads(line))
            except ValueError:
                continue
    stats = [e for e in events if e.get("event") == "stats" and e.get("preset") == pid]
    skips = [e for e in events if e.get("event") == "skip" and e.get("preset") == pid]
    shown = [e.get("file") for e in events if e.get("event") == "preset"]
    exiting = [e.get("reason") for e in events if e.get("event") == "exiting"]
    # The first window holds start-up and the warm-up; later ones are steady.
    steady = stats[1:] or stats
    frames = sum(s.get("frames", 0) for s in steady)

    def mean(field):
        if not frames:
            return None
        return round(sum(s.get(field, 0) * s.get("frames", 0) for s in steady) / frames, 2)

    rec = {
        "file": pid,
        "fps": round(min(s.get("fps", 0) for s in steady), 2) if steady else None,
        "flip_ms": mean("flip_ms"),
        "cpu_ms": mean("frame_ms"),
        "rung": steady[-1].get("rung") if steady else None,
        "warmup_ms": max((s.get("warmup_ms_max", 0) for s in stats), default=None),
        "shader_stages": max((s.get("shader_stages", 0) for s in stats), default=None),
        "cached_stages": max((s.get("cached_stages", 0) for s in stats), default=None),
        "temp_c": max((s.get("temp_c", 0) for s in stats), default=None),
        "arm_mhz": min((s.get("arm_mhz", 0) for s in stats), default=None),
        "exiting": exiting[-1] if exiting else None,
        "exit": exit_status,
    }
    if skips:
        rec.update(status="skip", reason=skips[0].get("reason"), message=skips[0].get("message", "")[:200])
    elif not stats or (shown and pid not in shown):
        rec.update(status="error", reason="not_shown" if stats or shown else "no_stats")
    elif exit_status != "0" or not exiting or exiting[-1] != "headless_done":
        # Only a run that reports both its own end and a clean exit is
        # complete; a truncated reply can carry stats and neither marker.
        rec.update(status="error", reason=f"exit_{exit_status or 'none'}_{exiting[-1] if exiting else 'none'}")
    else:
        rec.update(status="ok")
    return rec


def load_sweep(path):
    """{id: record} from a sweep file (JSON Lines; a later line for the same
    preset wins, so reruns append)."""
    out = {}
    if not path:
        return out
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            rec = json.loads(line)
            if isinstance(rec, dict) and names.valid_id(rec.get("file")):
                out[rec["file"]] = rec
    return out


def load_vc4_trial(path):
    """{id: {"warp_comp_ms", "stall_ms"}} from the shader trial's CSV
    (research/shader-trial-vc4.csv): vc4 warp+comp GPU time at 640x360 and
    the preset-switch stall."""
    out = {}
    if not path:
        return out
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            pid = names.normalise_id(row.get("preset", ""))
            if not pid:
                continue

            def num(key):
                try:
                    return float(row.get(key) or "")
                except ValueError:
                    return None

            out[pid] = {"warp_comp_ms": num("gpu_ms_warp_comp"), "stall_ms": num("switch_stall_ms")}
    return out
