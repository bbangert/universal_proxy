import os
import shutil
import tempfile

# Stands in for milkdrop_renderer --headless-frames: records its argv and
# prints the events a real run would (high_frequency/b.milk is "skipped").
FAKE_RENDERER = r'''#!/usr/bin/env python3
import json, sys
args = sys.argv[1:]
open(sys.argv[0] + ".calls", "a").write(json.dumps(args) + "\n")
pid = args[args.index("--locked") + 1]
def out(**kw): print(json.dumps(kw, separators=(",", ":")))
out(event="preset", file=pid, locked=True, rung="640x360", cause="start", cut=True)
if pid.startswith("high_frequency/"):
    out(event="skip", preset=pid, reason="register_allocate", message="Failed to register allocate")
else:
    for fps in (40.0, 30.0, 31.0):
        out(event="stats", fps=fps, frames=150, flip_ms=1000 / fps, frame_ms=12.5, rung="640x360",
            temp_c=60.0, arm_mhz=1200, preset=pid, warmups=1, warmup_ms_max=200.0, shader_stages=2,
            cached_stages=2)
out(event="exiting", reason="headless_done")
'''


def tmpdir(test):
    path = tempfile.mkdtemp(prefix="milkpack-")
    test.addCleanup(shutil.rmtree, path, True)
    return path


def write(path, data=b""):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb" if isinstance(data, bytes) else "w") as f:
        f.write(data)
    return path


def tiny_pack(root, presets=("a.milk", "high_frequency/b.milk")):
    """A minimal extracted pack: manifest, presets, a texture, a shader."""
    from milkpack import manifest

    for pid in presets:
        write(os.path.join(root, "presets", *pid.split("/")), b"[preset00]\nMILKDROP_PRESET_VERSION=201\n")
    write(os.path.join(root, "textures", "cells.jpg"), b"\xff\xd8\xff\xd9")
    write(os.path.join(root, "shaders", "0" * 64 + ".glsl"), "void main() {}\n")
    write(os.path.join(root, "README"), "readme\n")
    write(os.path.join(root, "NOTICE"), "notice\n")
    write(os.path.join(root, "manifest.json"), manifest.dumps(manifest.build("2026.11.1", presets)))
    return root
