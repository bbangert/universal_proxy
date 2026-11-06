import json
import os
import tempfile
import unittest

from milkpack import brightness

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

    def test_failures_are_errors_not_exclusions(self):
        self.assertEqual(self.verdict({"error": "timeout"}), "error")
        self.assertEqual(self.verdict(None), "error")


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
            f.write('{"key":"a","result":{"sat":0.1}}\nnot json\n{"nokey":1}\n')
        self.assertEqual(brightness.load_cache(path), {"a": {"sat": 0.1}})
        self.assertEqual(brightness.load_cache(path + ".missing"), {})


if __name__ == "__main__":
    unittest.main()
