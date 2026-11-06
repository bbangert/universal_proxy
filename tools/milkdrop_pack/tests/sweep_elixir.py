#!/usr/bin/env python3
"""The device sweep's Elixir for test/milkdrop_pack_tools_test.exs, which
evaluates it on the host against a fake renderer.

    sweep_elixir.py WORK_DIR VERSION SHA256  ->  {"probe", "extract", "run", "renderer"}
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import device_sweep  # noqa: E402
from tests.helpers import FAKE_RENDERER  # noqa: E402


class Opts:
    ladder = "640x360,480x270"
    card = "/dev/dri/renderD128"
    frames = 600
    stats_s = 5


def main(work, version, digest):
    remote = os.path.join(work, "remote")
    renderer = os.path.join(work, "fake_renderer")
    with open(renderer, "w") as f:
        f.write(FAKE_RENDERER)
    os.chmod(renderer, 0o755)
    args = device_sweep.renderer_args(Opts, f"{remote}/{version}", "Geiss - Chrome.milk")
    print(json.dumps({
        "probe": device_sweep.elixir_probe(remote, version, digest),
        "extract": device_sweep.elixir_extract(remote, version, digest),
        # Cooldown threshold far above any host's temperature.
        "run": device_sweep.elixir_run(renderer, args, 30_000, 1000, 0),
        "renderer": renderer,
        "remote": remote,
    }))


if __name__ == "__main__":
    main(*sys.argv[1:4])
