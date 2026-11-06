"""Pre-translation of every warp/comp stage to GLSL ES 1.00 into
<pack>/shaders/<key>.glsl with the fork's projectM-pretranslate-presets
(c_src/milkdrop_renderer/README.md, "Shader cache")."""

import os
import shutil
import subprocess


def parse_rows(text):
    """The tool's TSV (path, stage, status, key, error) as
    {path: [{"stage", "status", "key", "error"}]}; "(default)" is the
    default composite shader, always written."""
    rows = {}
    lines = text.splitlines()
    for line in lines[1:] if lines and lines[0].startswith("path\t") else lines:
        parts = line.split("\t")
        if len(parts) < 4:
            continue
        path, stage, status, key = parts[:4]
        rows.setdefault(path, []).append(
            {"stage": stage, "status": status, "key": key, "error": parts[4] if len(parts) > 4 else ""})
    return rows


def failures(rows):
    """{preset id: "stage: error"} for presets with a failing stage."""
    out = {}
    for path, stages in rows.items():
        if path == "(default)":
            continue
        bad = [s for s in stages if s["status"] != "ok"]
        if bad:
            out[path] = f"{bad[0]['stage']}: {bad[0]['error']}".strip()
    return out


def pretranslate(exe, pack_dir, log_path):
    """Run the translator over <pack>/presets into a fresh <pack>/shaders.
    Returns the parsed rows."""
    shaders = os.path.join(pack_dir, "shaders")
    shutil.rmtree(shaders, ignore_errors=True)
    proc = subprocess.run([exe, "--target", "es100", pack_dir, os.path.join(pack_dir, "presets")],
                          capture_output=True, text=True)
    with open(log_path, "w") as f:
        f.write(proc.stdout)
        f.write(proc.stderr)
    if proc.returncode != 0:
        raise RuntimeError(f"projectM-pretranslate-presets exited {proc.returncode}: {proc.stderr[-2000:]}")
    return parse_rows(proc.stdout)


def used_keys(rows):
    return {s["key"] for stages in rows.values() for s in stages if s["status"] == "ok" and s["key"]}
