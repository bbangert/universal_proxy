#!/usr/bin/env python3
"""The device sweep's Elixir for test/milkdrop_pack_tools_test.exs, which
evaluates it on the host against a fake renderer.

    sweep_elixir.py WORK_DIR VERSION SHA256  ->  {"probe", "extract", "run", "run_skip", "run_kmsg", ...}
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
    kmsg = os.path.join(work, "kmsg")
    with open(kmsg, "w") as f:
        f.write("6,1,100,-;Booting Linux\n4,2,200,-;vc4-drm soc:gpu: [drm] Resetting GPU.\n")
    args = device_sweep.renderer_args(Opts, f"{remote}/{version}", "Geiss - Chrome.milk")
    print(json.dumps({
        "probe": device_sweep.elixir_probe(remote, version, digest),
        "extract": device_sweep.elixir_extract(remote, version, digest),
        # Cooldown threshold far above any host's temperature.
        "run": device_sweep.elixir_run(renderer, args, 30_000, 1000, 0),
        # The fixture marks this one rpi3 "skip"; the sweep copy must not.
        "run_skip": device_sweep.elixir_run(
            renderer, device_sweep.renderer_args(Opts, f"{remote}/{version}", "$$$ Royal - Mashup (109).milk"),
            30_000, 1000, 0),
        # The kernel log: a stand-in file with a reset logged before the
        # run, read by a reader that adds one during it and then blocks.
        "run_kmsg": device_sweep.elixir_run(renderer, args, 30_000, 1000, 0, kmsg, [
            "-c", 'cat "$0"; echo "4,9,9,-;vc4-drm soc:gpu: [drm] Resetting GPU."; exec sleep 600', kmsg]),
        # A kernel log that takes the marker but can't be read back.
        "run_kmsg_unreadable": device_sweep.elixir_run(renderer, args, 30_000, 1000, 0, kmsg,
                                                       ["-c", "exec cat /nonexistent/kmsg 2>/dev/null"]),
        "renderer": renderer,
        "kmsg": kmsg,
        "remote": remote,
    }))


if __name__ == "__main__":
    main(*sys.argv[1:4])
