import json
import os
import tempfile
import unittest

from milkpack import brightness, sources

from .helpers import tmpdir, write

FIXTURES = os.path.join(os.path.dirname(__file__), "fixtures")


class ClassifyTest(unittest.TestCase):
    def setUp(self):
        with open(os.path.join(FIXTURES, "brightness.json")) as f:
            self.results = json.load(f)

    def verdict(self, result):
        return brightness.classify(result, 0.9, 0.5)

    def test_confirmed_whiteouts_are_excluded(self):
        # md_bright output for the two presets seen whiting out the TV.
        self.assertEqual(self.verdict(self.results["Waltra - Emitter.milk"]), "exclude")
        self.assertEqual(self.verdict(self.results["$$$ Royal - Mashup (383).milk"]), "exclude")

    def test_normal_presets_pass(self):
        self.assertEqual(self.verdict(self.results["Geiss - Planar Travel.milk"]), "ok")
        self.assertEqual(self.verdict(self.results["Isosceles mashup06.milk"]), "ok")

    def test_thresholds_are_strict(self):
        self.assertEqual(self.verdict({"sat": 0.9, "luma": 240}), "review")
        self.assertEqual(self.verdict({"sat": 0.90001, "luma": 240}), "exclude")
        self.assertEqual(self.verdict({"sat": 0.5, "luma": 200}), "ok")
        self.assertEqual(self.verdict({"sat": 0.50001, "luma": 200}), "review")

    def test_luma_gate_spares_saturated_colour(self):
        dark = {"sat": 0.97, "luma": 117.5}
        self.assertEqual(self.verdict(dark), "exclude")
        self.assertEqual(brightness.classify(dark, 0.9, 0.5, exclude_min_luma=200), "review")
        self.assertEqual(brightness.classify(self.results["Waltra - Emitter.milk"], 0.9, 0.5, 200), "exclude")

    def test_curation_excludes_only_true_whiteouts(self):
        cfg = sources.load_json("curation.json")["brightness"]
        self.assertEqual(cfg["exclude_min_luma"], 200)
        for pid in ("Waltra - Emitter.milk", "$$$ Royal - Mashup (383).milk"):
            self.assertEqual(brightness.verdict(self.results[pid], cfg), "exclude")
        self.assertEqual(brightness.verdict({"sat": 0.95, "luma": 200.0}, cfg), "exclude")
        self.assertEqual(brightness.verdict({"sat": 0.95, "luma": 199.0}, cfg), "review")
        self.assertEqual(brightness.verdict({"sat": 0.966, "luma": 117.5}, cfg), "review")
        self.assertEqual(brightness.verdict({"sat": 0.6, "luma": 250.0}, cfg), "review")
        self.assertEqual(brightness.verdict(self.results["Geiss - Planar Travel.milk"], cfg), "ok")

    def test_unloadable_presets_are_flagged(self):
        self.assertEqual(self.verdict({"error": "load_failed", "message": "syntax error"}), "load_failed")

    def test_failures_are_errors_not_exclusions(self):
        self.assertEqual(self.verdict({"error": "timeout"}), "error")
        self.assertEqual(self.verdict(None), "error")
        self.assertEqual(self.verdict({"sat": 0.0, "luma": 0.0, "gl_error": 1282}), "error")
        self.assertEqual(self.verdict({"sat": 0.1}), "error")


# Stands in for md_bright: the preset file holds what to print and the exit code.
FAKE_BRIGHT = r'''#!/usr/bin/env python3
import json, sys
args = sys.argv[1:]
spec = json.load(open(args[args.index("--preset") + 1]))
if spec.get("print") is not None:
    print(json.dumps(spec["print"]))
sys.exit(spec.get("exit", 0))
'''

GOOD = {"frames": 600, "from": 150, "luma": 37.9, "sat": 0.0002, "load_status": 0, "gl_error": 0}


class RenderTest(unittest.TestCase):
    def setUp(self):
        self.dir = tmpdir(self)
        bright = write(os.path.join(self.dir, "md_bright"), FAKE_BRIGHT)
        os.chmod(bright, 0o755)
        self.tools = {"bright": bright, "seed": ""}
        self.settings = {"frames": 600, "from": 150, "size": "640x360"}

    def render(self, spec):
        path = write(os.path.join(self.dir, "p.milk"), json.dumps(spec))
        return brightness.render(self.tools, path, self.dir, self.settings)

    def test_a_clean_run_is_a_measurement(self):
        self.assertEqual(self.render({"print": GOOD}), GOOD)

    def test_gl_errors_and_bad_exits_carry_no_metrics(self):
        for spec in ({"print": {**GOOD, "gl_error": 1282}}, {"print": GOOD, "exit": 1}, {"exit": -11},
                     {"print": {"frames": 600}}):
            result = self.render(spec)
            self.assertIn("error", result, spec)
            self.assertNotIn("sat", result, spec)
            self.assertEqual(brightness.classify(result, 0.9, 0.5), "error", spec)

    def test_load_failed_survives_its_exit_status(self):
        result = self.render({"print": {"error": "load_failed", "message": "syntax"}, "exit": 1})
        self.assertEqual(result, {"error": "load_failed", "message": "syntax"})

    def test_screen_caches_only_measurements_and_load_failures(self):
        pack = os.path.join(self.dir, "pack")
        specs = {"good.milk": {"print": GOOD}, "gl.milk": {"print": {**GOOD, "gl_error": 1282}},
                 "crash.milk": {"exit": 1}, "bad.milk": {"print": {"error": "load_failed"}, "exit": 1}}
        for pid, spec in specs.items():
            write(os.path.join(pack, "presets", pid), json.dumps(spec))
        cache = os.path.join(self.dir, "cache.jsonl")
        results = brightness.screen(self.tools, pack, sorted(specs), self.settings, cache, 2, "t")
        self.assertEqual(results["good.milk"], GOOD)
        self.assertEqual((results["gl.milk"]["error"], results["crash.milk"]["error"]), ("gl_error", "exit 1"))
        with open(cache) as f:
            self.assertEqual(sorted(json.loads(line)["id"] for line in f), ["bad.milk", "good.milk"])


class CacheTest(unittest.TestCase):
    def test_key_depends_on_content_settings_and_tool(self):
        s = {"frames": 600, "from": 150, "size": "640x360"}
        k = brightness.cache_key(b"preset", s, "t1")
        self.assertEqual(k, brightness.cache_key(b"preset", dict(s), "t1"))
        self.assertNotEqual(k, brightness.cache_key(b"preset2", s, "t1"))
        self.assertNotEqual(k, brightness.cache_key(b"preset", {**s, "frames": 300}, "t1"))
        self.assertNotEqual(k, brightness.cache_key(b"preset", s, "t2"))

    def test_load_cache_skips_bad_lines(self):
        path = os.path.join(tempfile.mkdtemp(), "c.jsonl")
        with open(path, "w") as f:
            f.write('{"key":"a","result":{"sat":0.1,"luma":20}}\nnot json\n{"nokey":1}\n'
                    '{"key":"b","result":{"sat":0.0,"luma":0.0,"gl_error":1282}}\n'
                    '{"key":"c","result":{"error":"timeout"}}\n')
        self.assertEqual(brightness.load_cache(path), {"a": {"sat": 0.1, "luma": 20}})
        self.assertEqual(brightness.load_cache(path + ".missing"), {})


if __name__ == "__main__":
    unittest.main()
