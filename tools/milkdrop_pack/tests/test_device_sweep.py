import contextlib
import io
import json
import os
import sys
import unittest

from milkpack import tarball

from .helpers import FAKE_RENDERER, tiny_pack, tmpdir, write

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import device_sweep  # noqa: E402


class DeviceSweepTest(unittest.TestCase):
    def setUp(self):
        d = tmpdir(self)
        self.pack = tiny_pack(os.path.join(d, "pack"))
        self.tar = os.path.join(d, "up-milkdrop-pack-2026.11.1.tar.gz")
        self.digest = tarball.create(self.pack, self.tar)
        self.renderer = write(os.path.join(d, "fake_renderer"), FAKE_RENDERER)
        os.chmod(self.renderer, 0o755)
        self.out = os.path.join(d, "sweep.jsonl")

    def sweep(self, *extra):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            code = device_sweep.main(["--tarball", self.tar, "--out", self.out, "--local-renderer", self.renderer,
                                      "--local-pack-dir", self.pack, *extra])
        return code, buf.getvalue()

    def records(self):
        with open(self.out) as f:
            return [json.loads(line) for line in f]

    def calls(self):
        with open(self.renderer + ".calls") as f:
            return [json.loads(line) for line in f]

    def test_runs_each_preset_headless_and_records_it(self):
        code, _ = self.sweep()
        self.assertEqual(code, 0)
        recs = {r["file"]: r for r in self.records()}
        self.assertEqual(recs["a.milk"]["status"], "ok")
        self.assertEqual((recs["a.milk"]["rung"], recs["a.milk"]["fps"], recs["a.milk"]["warmup_ms"]),
                         ("640x360", 30.0, 200.0))
        self.assertEqual((recs["high_frequency/b.milk"]["status"], recs["high_frequency/b.milk"]["reason"]),
                         ("skip", "register_allocate"))
        for r in recs.values():
            self.assertEqual((r["pack_version"], r["pack_sha256"]), ("2026.11.1", self.digest))
        args = self.calls()[0]
        for flag in ("--headless-frames", "--high-frequency", "--test-tone", "--locked"):
            self.assertIn(flag, args)
        self.assertEqual(args[args.index("--card") + 1], "/dev/dri/renderD128")

    def test_resumes_without_rerunning(self):
        self.sweep("--limit", "1")
        self.assertEqual(len(self.records()), 1)
        self.sweep()
        self.assertEqual(sorted(r["file"] for r in self.records()), ["a.milk", "high_frequency/b.milk"])
        self.assertEqual(len(self.calls()), 2)
        _, out = self.sweep()
        self.assertIn("2 done, 0 to run", out)
        self.assertEqual(len(self.calls()), 2)

    def test_the_sweep_feeds_the_manifest(self):
        from milkpack import manifest, sweep

        self.sweep()
        doc = manifest.build("2026.11.1", ["a.milk", "high_frequency/b.milk"], sweep.load_sweep(self.out))
        self.assertEqual(manifest.validate(doc), [])
        by = {p["file"]: p for p in doc["presets"]}
        self.assertEqual(by["a.milk"]["rpi3"], {"rung": "640x360"})
        self.assertEqual((by["a.milk"]["compile_ms"], by["a.milk"]["eval_ms"]), (200, 12.5))
        self.assertEqual(by["high_frequency/b.milk"]["rpi3"], {"rung": "skip", "reason": "register_allocate"})

    def test_a_pack_built_from_earlier_results_is_measured_afresh(self):
        # Rebuilt with an earlier sweep: a.milk was skipped on the rpi3 and
        # c.milk settled on the lower rung.
        d = tmpdir(self)
        earlier = {"a.milk": {"status": "skip", "reason": "register_allocate"},
                   "c.milk": {"status": "ok", "rung": "480x270", "warmup_ms": 100.0, "cpu_ms": 9.0}}
        self.pack = tiny_pack(os.path.join(d, "pack"), ("a.milk", "c.milk"), earlier)
        with open(os.path.join(self.pack, "manifest.json")) as f:
            before = f.read()
        self.assertIn('"skip"', before)
        self.digest = tarball.create(self.pack, self.tar)
        code, _ = self.sweep()
        self.assertEqual(code, 0)
        recs = {r["file"]: r for r in self.records()}
        self.assertEqual((recs["a.milk"]["status"], recs["a.milk"]["rung"]), ("ok", "640x360"))
        self.assertEqual(recs["c.milk"]["status"], "ok")
        with open(os.path.join(self.pack, "manifest.json")) as f:
            self.assertEqual(f.read(), before)

    def test_sweep_manifest_drops_the_rpi3_hints(self):
        from milkpack import manifest, sweep

        doc = manifest.build("2026.11.1", ["a.milk", "high_frequency/b.milk"],
                             {"a.milk": {"status": "skip", "reason": "x"},
                              "high_frequency/b.milk": {"status": "ok", "rung": "480x270", "cpu_ms": 9.0}},
                             {"high_frequency/b.milk": {"warp_comp_ms": 20.0}})
        stripped = sweep.sweep_manifest(doc)
        self.assertEqual(stripped["presets"], [{"file": "a.milk"},
                                               {"file": "high_frequency/b.milk", "tags": ["high_frequency"]}])
        self.assertEqual((stripped["format"], stripped["version"]), (1, "2026.11.1"))
        self.assertIn("rpi3", doc["presets"][0])

    def test_dry_run_connects_to_nothing(self):
        code, out = self.sweep("--dry-run", "--only", "a.milk")
        self.assertEqual(code, 0)
        self.assertIn("1 to run", out)
        self.assertIn("Port.open", out)
        self.assertNotIn("System.halt", out)
        self.assertFalse(os.path.exists(self.renderer + ".calls"))
        self.assertFalse(os.path.exists(self.out))

    def test_elixir_carries_ids_as_base64(self):
        code = device_sweep.elixir_run("/r", ["--locked", 'we#{ird} "x".milk'], 1000, 70, 300)
        self.assertNotIn("we#{ird}", code)
        self.assertIn(device_sweep.b64json(["--locked", 'we#{ird} "x".milk']), code)


if __name__ == "__main__":
    unittest.main()
