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

    def test_shader_fallbacks_are_flagged_not_measured(self):
        self.assertEqual(self.verdict({"error": "shader_failed", "load_status": 2, "message": "x"}), "shader_failed")
        # A measurement of projectM's fallback shaders is not the preset's.
        self.assertEqual(self.verdict({"sat": 0.1, "luma": 50.0, "load_status": 2, "gl_error": 0}), "error")

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

    def test_shader_failed_survives_its_exit_status(self):
        out = {"error": "shader_failed", "load_status": 2, "stage": 1, "message": "array index must be < 4"}
        self.assertEqual(self.render({"print": out, "exit": 1}), out)
        self.assertEqual(brightness.classify(self.render({"print": out, "exit": 1}), 0.9, 0.5), "shader_failed")
        # Any other non-OK load status is a render error, not a verdict.
        other = self.render({"print": {"error": "load_status", "load_status": -1}, "exit": 1})
        self.assertEqual(brightness.classify(other, 0.9, 0.5), "error")

    def test_screen_caches_only_measurements_and_load_failures(self):
        pack = os.path.join(self.dir, "pack")
        specs = {"good.milk": {"print": GOOD}, "gl.milk": {"print": {**GOOD, "gl_error": 1282}},
                 "crash.milk": {"exit": 1}, "bad.milk": {"print": {"error": "load_failed"}, "exit": 1},
                 "shader.milk": {"print": {"error": "shader_failed", "load_status": 2}, "exit": 1}}
        for pid, spec in specs.items():
            write(os.path.join(pack, "presets", pid), json.dumps(spec))
        cache = os.path.join(self.dir, "cache.jsonl")
        results = brightness.screen(self.tools, pack, sorted(specs), self.settings, cache, 2, "t")
        self.assertEqual(results["good.milk"], GOOD)
        self.assertEqual((results["gl.milk"]["error"], results["crash.milk"]["error"]), ("gl_error", "exit 1"))
        self.assertEqual(results["shader.milk"]["error"], "shader_failed")
        with open(cache) as f:
            self.assertEqual(sorted(json.loads(line)["id"] for line in f), ["bad.milk", "good.milk"])


class SnapshotNameTest(unittest.TestCase):
    def test_names_are_unique_per_id(self):
        long_a, long_b = "x" * 130 + "a.milk", "x" * 130 + "b.milk"
        ids = ["A-B.milk", "A B.milk", "A_B.milk", "high_frequency/A B.milk", long_a, long_b]
        names = [brightness.snapshot_name(pid) for pid in ids]
        self.assertEqual(len(set(names)), len(ids))
        self.assertEqual(brightness.snapshot_name("A B.milk"), brightness.snapshot_name("A B.milk"))
        self.assertTrue(names[0].startswith("A_B-"))
        for name in names:
            self.assertRegex(name, r"\A[A-Za-z0-9_]{1,120}-[0-9a-f]{10}\Z")


class CacheTest(unittest.TestCase):
    def test_key_depends_on_content_settings_and_tool(self):
        s = {"frames": 600, "from": 150, "size": "640x360"}
        k = brightness.cache_key(b"preset", s, "t1")
        self.assertEqual(k, brightness.cache_key(b"preset", dict(s), "t1"))
        self.assertNotEqual(k, brightness.cache_key(b"preset2", s, "t1"))
        self.assertNotEqual(k, brightness.cache_key(b"preset", {**s, "frames": 300}, "t1"))
        self.assertNotEqual(k, brightness.cache_key(b"preset", s, "t2"))

    def test_tool_identity_covers_builds_textures_and_rand_pool(self):
        d = tmpdir(self)
        tools = {"bright": write(os.path.join(d, "md_bright"), b"bright"),
                 "seed": write(os.path.join(d, "libmd_seed.so"), b"seed")}
        tex = os.path.join(d, "textures")
        write(os.path.join(tex, "cells.jpg"), b"cells")

        def ident(pool=("cells",)):
            return brightness.tool_identity(tools, "pm1", tex, pool)

        base = ident()
        self.assertEqual(base, ident())
        self.assertNotEqual(base, brightness.tool_identity(tools, "pm2", tex, ("cells",)))
        self.assertNotEqual(base, ident(("cells", "heart")))
        changes = [(os.path.join(tex, "cells.jpg"), b"cells2"), (os.path.join(tex, "heart.jpg"), b"heart"),
                   (tools["seed"], b"seed2"), (tools["bright"], b"bright2")]
        seen = {base}
        for path, data in changes:
            write(path, data)
            seen.add(ident())
        self.assertEqual(len(seen), len(changes) + 1)

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
