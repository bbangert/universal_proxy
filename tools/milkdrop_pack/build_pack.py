#!/usr/bin/env python3
"""Build the MilkDrop preset pack tarball (see README.md next to this file).

    tools/milkdrop_pack/build_pack.py --zip ~/favorite_presets_2021_01_03.zip \\
        --out /tmp/pack --version 2026.11.1 [--device-sweep sweep.jsonl] [--vc4-trial trial.csv]

Python 3.9+ standard library only; needs git, cmake, ninja, a C++17
compiler and Mesa (EGL + llvmpipe) for the host builds.
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from milkpack import manifest, pipeline  # noqa: E402
from milkpack.sources import PipelineError  # noqa: E402


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--zip", required=True, help="the geisswerks favorite_presets_2021_01_03.zip (download it by hand)")
    p.add_argument("--out", required=True, help="output directory (tarball, .sha256, report.json, review/)")
    p.add_argument("--work", help="work directory (checkouts, builds, caches); default OUT/work")
    p.add_argument("--version", help="pack version, YYYY.MM.N (default: this month's .1)")
    p.add_argument("--device-sweep", help="rpi3 sweep file from device_sweep.py (JSON Lines)")
    p.add_argument("--vc4-trial", help="shader-trial CSV with gpu_ms_warp_comp (rpi3.frame_ms)")
    p.add_argument("--default-rung", default=manifest.DEFAULT_RUNG, help="rpi3 rung for unswept presets")
    p.add_argument("--contact", help="removal-request contact for NOTICE")
    p.add_argument("--jobs", type=int, help="parallel brightness renders (default: CPUs / 2)")
    p.add_argument("--skip-brightness", action="store_true", help="skip the brightness screen (dev builds only)")
    p.add_argument("--no-snapshots", action="store_true", help="don't write review PNGs")
    p.add_argument("--texture-pack", help="use this texture-pack checkout instead of fetching the pin")
    p.add_argument("--projectm-src", help="use this projectM fork checkout instead of fetching the pin")
    p.add_argument("--allow-unpinned-zip", action="store_true", help="accept a zip whose SHA-256 isn't pinned")
    args = p.parse_args(argv)
    try:
        result = pipeline.build(args)
    except PipelineError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    print(f"{result['tarball']}\n{result['sha256']}  ({result['bytes']} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
