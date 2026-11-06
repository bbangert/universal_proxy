#!/usr/bin/env python3
"""Build a small pack tarball with the pipeline's own name, manifest and
tarball code (no GL, no downloads), for test/milkdrop_pack_tools_test.exs.

    make_fixture_pack.py OUT_DIR  ->  prints {"tarball", "sha256", "version", "presets"}
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from milkpack import manifest, names, tarball  # noqa: E402

SOURCES = [
    "Geiss  -  Chrome .milk",
    "$$$ Royal - Mashup (109).milk",
    "high_frequency/suksma - feeling ignore.milk",
    "high_frequency/extreme/" + "Bdrv Aderrasi - Accelerator (Orbital Migraine) " * 3 + ".milk",
    "A Tribute to Martin - Ft Flexi - AdamFX - StahlRegen - Krash - Rovastar -  Hd in Milk T.milk",
]


def main(out_dir):
    pack = os.path.join(out_dir, "pack")
    assigned, dropped = names.assign_ids([(s, s.encode()) for s in SOURCES])
    assert not dropped, dropped
    ids = [pid for _, pid in assigned]
    for pid in ids:
        path = os.path.join(pack, "presets", *pid.split("/"))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write("[preset00]\nMILKDROP_PRESET_VERSION=201\n")
    os.makedirs(os.path.join(pack, "textures"), exist_ok=True)
    os.makedirs(os.path.join(pack, "shaders"), exist_ok=True)
    with open(os.path.join(pack, "textures", "cells.jpg"), "wb") as f:
        f.write(b"\xff\xd8\xff\xd9")
    with open(os.path.join(pack, "shaders", "ab" * 32 + ".glsl"), "w") as f:
        f.write("void main() { gl_FragColor = vec4(0.0); }\n")
    for name in ("README", "NOTICE"):
        with open(os.path.join(pack, name), "w") as f:
            f.write(name + "\n")
    sweep = {ids[0]: {"status": "ok", "rung": "480x270", "warmup_ms": 140.2, "cpu_ms": 9.81},
             ids[1]: {"status": "skip", "reason": "register_allocate"}}
    trial = {ids[0]: {"warp_comp_ms": 21.04, "stall_ms": 150.0}, ids[2]: {"warp_comp_ms": 30.0, "stall_ms": 700.0}}
    doc = manifest.build("2026.11.1", ids, sweep, trial)
    assert manifest.validate(doc) == []
    with open(os.path.join(pack, "manifest.json"), "w") as f:
        f.write(manifest.dumps(doc))
    tar = os.path.join(out_dir, "up-milkdrop-pack-2026.11.1.tar.gz")
    digest = tarball.create(pack, tar)
    assert tarball.check(tar) == []
    print(json.dumps({"tarball": tar, "sha256": digest, "version": "2026.11.1", "presets": sorted(ids)}))


if __name__ == "__main__":
    main(sys.argv[1])
