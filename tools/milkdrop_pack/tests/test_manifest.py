import json
import unittest

from milkpack import manifest


class EntryTest(unittest.TestCase):
    def test_default_without_measurements(self):
        self.assertEqual(manifest.entry("a.milk"), {"file": "a.milk", "rpi3": {"rung": "640x360"}})
        self.assertEqual(manifest.entry("high_frequency/extreme/a.milk")["tags"], ["high_frequency", "extreme"])

    def test_trial_supplies_warp_comp_frame_ms_and_stall(self):
        e = manifest.entry("a.milk", trial={"warp_comp_ms": 27.46, "stall_ms": 180.4})
        self.assertEqual(e["rpi3"], {"rung": "640x360", "frame_ms": 27.5})
        self.assertEqual(e["compile_ms"], 180)

    def test_sweep_rung_and_timings_win(self):
        sweep = {"status": "ok", "rung": "480x270", "warmup_ms": 133.6, "cpu_ms": 15.04, "flip_ms": 48.0}
        e = manifest.entry("a.milk", sweep=sweep, trial={"warp_comp_ms": 12.0, "stall_ms": 999})
        # frame_ms stays the warp+comp estimate, never the whole-frame flip time.
        self.assertEqual(e["rpi3"], {"rung": "480x270", "frame_ms": 12.0})
        self.assertEqual(e["compile_ms"], 134)
        self.assertEqual(e["eval_ms"], 15.0)

    def test_sweep_skip(self):
        e = manifest.entry("a.milk", sweep={"status": "skip", "reason": "register_allocate"},
                           trial={"warp_comp_ms": 40.0})
        self.assertEqual(e["rpi3"], {"rung": "skip", "reason": "register_allocate"})
        self.assertNotIn("compile_ms", e)

    def test_failed_sweep_run_falls_back_to_default(self):
        e = manifest.entry("a.milk", sweep={"status": "error", "reason": "no_stats"})
        self.assertEqual(e["rpi3"], {"rung": "640x360"})


class DocumentTest(unittest.TestCase):
    def doc(self):
        return manifest.build("2026.11.1", ["b.milk", "high_frequency/a.milk"],
                              sweep={"b.milk": {"status": "skip", "reason": "budget"}})

    def test_build_is_sorted_and_valid(self):
        doc = self.doc()
        self.assertEqual([p["file"] for p in doc["presets"]], ["b.milk", "high_frequency/a.milk"])
        self.assertEqual(doc["format"], 1)
        self.assertEqual(manifest.validate(doc), [])

    def test_dumps_round_trips_one_preset_per_line(self):
        doc = self.doc()
        text = manifest.dumps(doc)
        self.assertEqual(json.loads(text), doc)
        self.assertEqual(len(text.splitlines()), 4)
        self.assertEqual(json.loads(manifest.dumps({"format": 1, "version": "x", "presets": []}))["presets"], [])

    def test_validate_rejects_what_the_renderer_or_pack_would(self):
        cases = [
            ({"format": 2, "version": "1", "presets": []}, "format"),
            ({"version": "../x", "presets": []}, "version"),
            ({"version": "1"}, "presets"),
            ({"version": "1", "presets": [{"file": "../a.milk"}]}, "invalid file"),
            ({"version": "1", "presets": [{"file": "a.milk"}, {"file": "a.milk"}]}, "duplicate"),
            ({"version": "1", "presets": [{"file": "a.milk", "tags": "x"}]}, "tags"),
            ({"version": "1", "presets": [{"file": "a.milk", "rpi3": {"rung": "big"}}]}, "rpi3"),
            ({"version": "1", "presets": [{"file": "a.milk", "rpi3": 3}]}, "rpi3"),
            ({"version": "1", "presets": [{"file": "a.milk", "rpi3": {"rung": "640x360", "frame_ms": "x"}}]},
             "frame_ms"),
            ({"version": "1", "presets": [{"file": "a.milk", "compile_ms": True}]}, "compile_ms"),
        ]
        for doc, expect in cases:
            problems = manifest.validate(doc)
            self.assertTrue(any(expect in p for p in problems), (doc, problems))

    def test_validate_accepts_the_readme_example(self):
        doc = {"format": 1, "version": "2026.11.1", "presets": [
            {"file": "Geiss - Chrome.milk", "tags": ["extreme"], "rpi3": {"rung": "640x360", "frame_ms": 22.0},
             "compile_ms": 120, "eval_ms": 2.4},
            {"file": "high_frequency/x.milk", "tags": ["high_frequency"],
             "rpi3": {"rung": "skip", "reason": "register_allocate"}},
            {"file": "y.milk", "rpi3": "skip"}, {"file": "z.milk", "rpi3": "480x270"}]}
        self.assertEqual(manifest.validate(doc), [])


if __name__ == "__main__":
    unittest.main()
