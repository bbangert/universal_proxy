"""manifest.json, in the format c_src/milkdrop_renderer/README.md
("Pack layout") documents and src/manifest.cpp parses.

Per preset: `file`, `tags`, `rpi3` and, when measured, `compile_ms` and
`eval_ms`. rpi3 data comes from, in order:

  * a device sweep record (device_sweep.py): `rung` (or "skip" + `reason`),
    `compile_ms` = the warm-up time, `eval_ms` = the CPU frame time
    (expression eval + GL submit, an upper bound on eval);
  * the vc4 shader trial (optional CSV): `frame_ms` = warp+comp GPU time.
    The renderer cuts instead of blending above 25 ms; the sweep's
    whole-frame headless time is deliberately not used there, since it
    overstates what a blend costs and would hard-cut most presets;
  * otherwise `{"rung": DEFAULT_RUNG}` and the runtime cost guard decides.
"""

import json
import re

from . import names
from .sweep import RUNG_RE

FORMAT = 1
DEFAULT_RUNG = "640x360"
VERSION_RE = re.compile(r"\A[0-9A-Za-z][0-9A-Za-z._-]*\Z")  # MilkDrop.Pack's @version_re


def entry(pid, sweep=None, trial=None, default_rung=DEFAULT_RUNG):
    e = {"file": pid}
    tags = names.tags_for(pid)
    if tags:
        e["tags"] = tags
    rpi3 = {"rung": default_rung}
    if sweep and sweep.get("status") == "skip":
        rpi3 = {"rung": "skip", "reason": sweep.get("reason") or "unknown"}
    elif sweep and sweep.get("status") == "ok" and RUNG_RE.match(sweep.get("rung") or ""):
        rpi3 = {"rung": sweep["rung"]}
    if rpi3["rung"] != "skip" and trial and trial.get("warp_comp_ms") is not None:
        rpi3["frame_ms"] = round(trial["warp_comp_ms"], 1)
    e["rpi3"] = rpi3
    if sweep and sweep.get("status") == "ok":
        if sweep.get("warmup_ms") is not None:
            e["compile_ms"] = int(round(sweep["warmup_ms"]))
        if sweep.get("cpu_ms") is not None:
            e["eval_ms"] = round(sweep["cpu_ms"], 1)
    elif trial and trial.get("stall_ms") is not None:
        e["compile_ms"] = int(round(trial["stall_ms"]))
    return e


def build(version, ids, sweep=None, trial=None, default_rung=DEFAULT_RUNG):
    sweep = sweep or {}
    trial = trial or {}
    return {
        "format": FORMAT,
        "version": version,
        "presets": [entry(pid, sweep.get(pid), trial.get(pid), default_rung) for pid in sorted(ids)],
    }


def dumps(doc):
    """JSON text with one preset per line (diffable, still compact)."""
    head = {k: v for k, v in doc.items() if k != "presets"}
    lines = [json.dumps(e, separators=(",", ":")) for e in doc["presets"]]
    body = ",\n  ".join(lines)
    text = json.dumps(head, separators=(",", ":"))[:-1]
    return text + ',"presets":[\n  ' + body + "\n]}\n"


def validate(doc):
    """Problems (strings) that would make the renderer drop an entry or the
    BEAM reject the pack; an empty list means it is clean."""
    errors = []
    if not isinstance(doc, dict):
        return ["manifest is not an object"]
    if doc.get("format", FORMAT) != FORMAT:
        errors.append(f"format {doc.get('format')!r} is not {FORMAT}")
    version = doc.get("version")
    if not isinstance(version, str) or not VERSION_RE.match(version):
        errors.append(f"version {version!r} is not path-safe ([0-9A-Za-z][0-9A-Za-z._-]*)")
    presets = doc.get("presets")
    if not isinstance(presets, list):
        return errors + ["no presets array"]
    seen = set()
    for i, e in enumerate(presets):
        where = f"presets[{i}]"
        if not isinstance(e, dict):
            errors.append(f"{where}: not an object")
            continue
        f = e.get("file")
        if not names.valid_id(f):
            errors.append(f"{where}: invalid file {f!r}")
        elif f in seen:
            errors.append(f"{where}: duplicate file {f!r}")
        seen.add(f)
        tags = e.get("tags", [])
        if not isinstance(tags, list) or not all(isinstance(t, str) for t in tags):
            errors.append(f"{where}: tags must be a list of strings")
        rpi3 = e.get("rpi3")
        if rpi3 is not None:
            rung = rpi3 if isinstance(rpi3, str) else rpi3.get("rung") if isinstance(rpi3, dict) else False
            if rung is False or (rung is not None and rung != "skip" and not RUNG_RE.match(str(rung))):
                errors.append(f"{where}: bad rpi3 {rpi3!r}")
            if isinstance(rpi3, dict) and not _num_or_absent(rpi3.get("frame_ms")):
                errors.append(f"{where}: rpi3.frame_ms must be a number")
        for key in ("compile_ms", "eval_ms"):
            if not _num_or_absent(e.get(key)):
                errors.append(f"{where}: {key} must be a number")
    return errors


def _num_or_absent(v):
    return v is None or (isinstance(v, (int, float)) and not isinstance(v, bool))
