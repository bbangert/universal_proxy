import datetime
import os
import unittest
import zipfile

from milkpack import pipeline, sources
from milkpack.sources import PipelineError

from .helpers import tmpdir

CURATION = {
    "banned_textures": {"names": ["portal1", "worms"]},
    "milkdrop_textures": {"names": ["cells", "heart"]},
    "excluded_presets": {"_comment": "x", "Waltra - Emitter.milk": "too_bright: whiteout on the TV",
                         "Gone.milk": "not in the pack"},
}


def milk(*comp):
    return ("[preset00]\n" + "".join(f"comp_{i}=`{line}\n" for i, line in enumerate(comp, 1))).encode()


class Quiet(pipeline.Report):
    def step(self, name, **counts):
        self.steps.append({"step": name, **counts})


class StepsTest(unittest.TestCase):
    def test_read_zip_keeps_milk_and_drops_thumbnails(self):
        path = os.path.join(tmpdir(self), "p.zip")
        with zipfile.ZipFile(path, "w") as z:
            z.writestr("a.milk", b"1")
            z.writestr("a.jpg", b"jpg")
            z.writestr("high_frequency/", b"")
            z.writestr("high_frequency/b.MILK", b"2")
            z.writestr("readme.txt", b"?")
        report = Quiet()
        entries = pipeline.read_zip(path, report)
        self.assertEqual(sorted(n for n, _ in entries), ["a.milk", "high_frequency/b.MILK"])
        self.assertEqual(report.steps[0], {"step": "zip", "milk": 2, "jpg_thumbnails_dropped": 1, "other_dropped": 1})

    def test_read_zip_refuses_unsafe_entries(self):
        path = os.path.join(tmpdir(self), "p.zip")
        with zipfile.ZipFile(path, "w") as z:
            z.writestr("../evil.milk", b"1")
        with self.assertRaises(PipelineError):
            pipeline.read_zip(path, Quiet())

    def test_texture_policy_excludes_banned_and_missing_samplers(self):
        staged = {
            "portal.milk": milk("sampler sampler_portal1;", "ret = tex2D(sampler_portal1, uv);"),
            "declares_worms.milk": milk("sampler sampler_worms;", "ret = tex2D(sampler_main, uv);"),
            "missing.milk": milk("ret = tex2D(sampler_nosuch, uv);"),
            "seaweed.milk": milk("ret = tex2D(sampler_seaweed, uv);"),
        }
        available = {"seaweed": "seaweed.jpg", "cells": "cells.jpg", "heart": "heart.jpg", "worms": "worms.jpg",
                     "unused": "unused.jpg"}
        report = Quiet()
        stems = pipeline.texture_policy(staged, available, CURATION, report)
        self.assertEqual(sorted(staged), ["declares_worms.milk", "seaweed.milk"])
        self.assertEqual(stems, ["cells", "heart", "seaweed"])
        self.assertEqual({(e["file"], e["reason"], e["detail"]) for e in report.excluded},
                         {("portal.milk", "banned_texture", "portal1"), ("missing.milk", "missing_texture", "nosuch")})

    def test_curate_removes_and_notes(self):
        d = tmpdir(self)
        staged = {"Waltra - Emitter.milk": b"x", "Keep.milk": b"y"}
        pipeline.write_presets(staged, d)
        report = Quiet()
        pipeline.curate(staged, CURATION, report, d)
        self.assertEqual(list(staged), ["Keep.milk"])
        self.assertFalse(os.path.exists(os.path.join(d, "presets", "Waltra - Emitter.milk")))
        self.assertEqual(report.excluded[0]["reason"], "curated")
        self.assertTrue(any("Gone.milk" in n for n in report.notes))

    def test_curate_takes_ids_starting_with_an_underscore(self):
        d = tmpdir(self)
        pid = "_Flexi - mindblob [where it's at now].milk"
        staged = {pid: b"x", "Keep.milk": b"y"}
        pipeline.write_presets(staged, d)
        report = Quiet()
        pipeline.curate(staged, {"excluded_presets": {"_comment": "x", pid: "removal request"}}, report, d)
        self.assertEqual(list(staged), ["Keep.milk"])
        self.assertEqual(report.excluded, [{"file": pid, "reason": "curated", "detail": "removal request"}])
        self.assertFalse(os.path.exists(os.path.join(d, "presets", pid)))

    def test_curate_after_the_screen_caught_it(self):
        staged = {"Keep.milk": b"y"}
        report = Quiet()
        report.exclude("Waltra - Emitter.milk", "too_bright", "sat 0.999")
        pipeline.curate(staged, CURATION, report, tmpdir(self))
        self.assertEqual([e["reason"] for e in report.excluded], ["too_bright"])
        self.assertTrue(any("already excluded" in n for n in report.notes))

    def test_apply_screen_records_verdicts(self):
        cfg = {"exclude_sat_above": 0.9, "review_sat_above": 0.5, "exclude_min_luma": 200}
        bright = {"white.milk": {"sat": 0.99, "luma": 250.0}, "red.milk": {"sat": 0.97, "luma": 120.0},
                  "bad.milk": {"error": "load_failed", "message": "syntax"}, "ok.milk": {"sat": 0.1, "luma": 50.0},
                  "fallback.milk": {"error": "shader_failed", "load_status": 2, "message": "array index"}}
        report = Quiet()
        verdicts = pipeline.apply_screen(dict.fromkeys(bright, b""), bright, cfg, report)
        self.assertEqual(verdicts, (["white.milk"], ["bad.milk"], ["fallback.milk"]))
        self.assertIn({"file": "fallback.milk", "reason": "shader_failed", "detail": "array index"}, report.excluded)
        self.assertEqual([e["file"] for e in report.review], ["red.milk"])

    def test_apply_screen_fails_on_missing_or_failed_renders(self):
        cfg = {"exclude_sat_above": 0.9, "review_sat_above": 0.5, "exclude_min_luma": 200}
        for bright in ({"a.milk": {"sat": 0.1, "luma": 50.0}, "b.milk": {"error": "timeout"}},
                       {"a.milk": {"sat": 0.1, "luma": 50.0}, "b.milk": {"error": "gl_error", "gl_error": 1282}},
                       {"a.milk": {"sat": 0.1, "luma": 50.0}}):
            with self.assertRaises(PipelineError) as ctx:
                pipeline.apply_screen({"a.milk": b"", "b.milk": b""}, bright, cfg, Quiet())
            self.assertIn("b.milk", str(ctx.exception))

    def test_exclusion_text_and_detail_cap(self):
        report = Quiet()
        report.exclude("b.milk", "translate_failed", "x" * 500)
        report.exclude("a.milk", "banned_texture", "portal1")
        self.assertLessEqual(len(report.excluded[0]["detail"]), 200)
        text = pipeline.exclusion_text(report)
        self.assertIn("1 preset(s): sample a banned texture:\n  - a.milk (portal1)", text)
        self.assertIn("  - b.milk\n", text + "\n")
        self.assertEqual(pipeline.exclusion_text(Quiet()), "Nothing.")


class TemplatesTest(unittest.TestCase):
    def test_fill_needs_every_placeholder(self):
        with self.assertRaises(PipelineError):
            pipeline.fill("NOTICE.in", {"CONTACT": "x"})

    def test_templates_mention_the_licence_posture(self):
        with open(os.path.join(sources.TOOL_DIR, "templates", "NOTICE.in")) as f:
            notice = " ".join(f.read().split())
        self.assertIn("presumed public domain", notice)
        self.assertIn("removed on request", notice)
        self.assertIn("@BANNED_TEXTURES@", notice)
        self.assertIn("@CONTACT@", notice)

    def test_removal_requests_go_to_the_issue_tracker(self):
        self.assertEqual(pipeline.DEFAULT_CONTACT,
                         "open an issue at https://github.com/bbangert/up-milkdrop-pack/issues")
        self.assertNotIn("@", pipeline.DEFAULT_CONTACT)
        with open(os.path.join(sources.TOOL_DIR, "templates", "NOTICE.in")) as f:
            notice = f.read()
        self.assertIn("To have a preset or texture removed, @CONTACT@", notice)


class PinsTest(unittest.TestCase):
    def test_projectm_pin_is_the_renderers(self):
        pin = sources.projectm_pin()
        self.assertRegex(pin, r"\A[0-9a-f]{40}\Z")
        with open(os.path.join(sources.REPO_ROOT, "c_src", "milkdrop_renderer", "CMakeLists.txt")) as f:
            self.assertIn(f'"{pin}"', f.read())

    def test_projectm_pin_fails_loudly(self):
        path = os.path.join(tmpdir(self), "CMakeLists.txt")
        with open(path, "w") as f:
            f.write('set(PROJECTM_REF "main")\n')
        with self.assertRaises(PipelineError):
            sources.projectm_pin(path)

    def test_zip_must_match_the_pin(self):
        path = os.path.join(tmpdir(self), "x.zip")
        with open(path, "wb") as f:
            f.write(b"not the zip")
        with self.assertRaises(PipelineError):
            sources.check_zip(path)
        self.assertEqual(len(sources.check_zip(path, allow_unpinned=True)), 64)

    def test_default_version(self):
        self.assertEqual(pipeline.default_version(datetime.date(2026, 11, 6)), "2026.11.1")


if __name__ == "__main__":
    unittest.main()
