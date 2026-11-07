import contextlib
import io
import json
import os
import unittest

from milkpack import sweep

from .helpers import tmpdir, write

FIXTURES = os.path.join(os.path.dirname(__file__), "fixtures")


def ev(**kw):
    return json.dumps(kw)


def stats(preset, fps, rung="640x360", **kw):
    base = {"event": "stats", "fps": fps, "frames": 200, "flip_ms": 1000 / fps, "frame_ms": 15.0,
            "rung": rung, "temp_c": 55.0, "arm_mhz": 600, "preset": preset, "warmups": 0, "warmup_ms_max": 0.0,
            "shader_stages": 0, "cached_stages": 0}
    base.update(kw)
    return json.dumps(base)


class ParseRunTest(unittest.TestCase):
    def test_a_real_rpi3_run(self):
        with open(os.path.join(FIXTURES, "run_ok.log")) as f:
            rec = sweep.parse_run("Geiss - Chrome.milk", f.read())
        self.assertEqual(rec["status"], "ok")
        self.assertEqual(rec["rung"], "640x360")
        self.assertEqual(rec["fps"], 41.0)
        self.assertEqual(rec["warmup_ms"], 133.6)
        self.assertEqual(rec["shader_stages"], 2)
        self.assertAlmostEqual(rec["cpu_ms"], 15.2, places=1)
        self.assertAlmostEqual(rec["flip_ms"], 24.4, places=1)
        self.assertEqual(rec["exit"], "0")

    def test_skip_event_wins(self):
        text = "\n".join([
            ev(event="preset", file="a.milk", cause="start"),
            ev(event="skip", preset="a.milk", reason="register_allocate", message="Failed to register allocate"),
            ev(event="preset", file="b.milk", cause="eject"),
            stats("b.milk", 30),
            ev(event="exiting", reason="headless_done"), "EXIT_STATUS 0"])
        rec = sweep.parse_run("a.milk", text)
        self.assertEqual((rec["status"], rec["reason"]), ("skip", "register_allocate"))

    def test_steady_state_skips_the_first_window_and_takes_the_settled_rung(self):
        text = "\n".join([
            stats("a.milk", 18, warmups=1, warmup_ms_max=600.0, shader_stages=2),
            stats("a.milk", 22, rung="480x270"), stats("a.milk", 25, rung="480x270"),
            ev(event="exiting", reason="headless_done"), "EXIT_STATUS 0"])
        rec = sweep.parse_run("a.milk", text)
        self.assertEqual((rec["status"], rec["rung"], rec["fps"], rec["warmup_ms"]), ("ok", "480x270", 22, 600.0))

    def test_failures(self):
        self.assertEqual(sweep.parse_run("a.milk", "EXIT_STATUS timeout")["reason"], "no_stats")
        other = "\n".join([ev(event="preset", file="b.milk"), stats("b.milk", 30), "EXIT_STATUS 0"])
        self.assertEqual(sweep.parse_run("a.milk", other)["reason"], "not_shown")
        crashed = "\n".join([stats("a.milk", 30), ev(event="exiting", reason="gl"), "EXIT_STATUS 1"])
        rec = sweep.parse_run("a.milk", crashed)
        self.assertEqual((rec["status"], rec["reason"]), ("error", "exit_1_gl"))

    def test_a_run_needs_both_completion_markers(self):
        done = ev(event="exiting", reason="headless_done")
        cases = {
            "exit_none_none": [stats("a.milk", 30), stats("a.milk", 31)],
            "exit_none_headless_done": [stats("a.milk", 30), done],
            "exit_0_none": [stats("a.milk", 30), "EXIT_STATUS 0"],
            "exit_timeout_none": [stats("a.milk", 30), "EXIT_STATUS timeout"],
        }
        for reason, lines in cases.items():
            rec = sweep.parse_run("a.milk", "\n".join(lines))
            self.assertEqual((rec["status"], rec["reason"]), ("error", reason))
        ok = sweep.parse_run("a.milk", "\n".join([stats("a.milk", 30), done, "EXIT_STATUS 0"]))
        self.assertEqual(ok["status"], "ok")

    def test_a_gpu_reset_during_the_run_is_a_gpu_hang_skip_even_if_it_succeeded(self):
        done = ev(event="exiting", reason="headless_done")
        ok = [stats("a.milk", 30), stats("a.milk", 31), done]
        rec = sweep.parse_run("a.milk", "\n".join([*ok, "GPU_RESET 2", "EXIT_STATUS 0"]))
        self.assertEqual((rec["status"], rec["reason"], rec["gpu_resets"]), ("skip", "gpu_hang", 2))
        self.assertEqual((rec["run_status"], rec["run_reason"]), ("ok", None))
        self.assertEqual(rec["fps"], 31)
        timed_out = sweep.parse_run("a.milk", "GPU_RESET 1\nEXIT_STATUS timeout")
        self.assertEqual((timed_out["status"], timed_out["reason"]), ("skip", "gpu_hang"))
        self.assertEqual((timed_out["run_status"], timed_out["run_reason"]), ("error", "no_stats"))
        for tail in ("GPU_RESET 0", "GPU_RESET unknown", ""):
            rec = sweep.parse_run("a.milk", "\n".join([*ok, tail, "EXIT_STATUS 0"]))
            self.assertEqual(rec["status"], "ok", tail)
            self.assertEqual(rec["gpu_resets"], 0 if tail == "GPU_RESET 0" else None)


class LoadTest(unittest.TestCase):
    def test_sweep_file_later_lines_win(self):
        path = write(os.path.join(tmpdir(self), "s.jsonl"), "\n".join([
            json.dumps({"file": "a.milk", "status": "error"}), "# comment", "",
            json.dumps({"file": "../bad.milk", "status": "ok"}),
            json.dumps({"file": "a.milk", "status": "ok", "rung": "640x360"})]) + "\n")
        self.assertEqual(sweep.load_sweep(path), {"a.milk": {"file": "a.milk", "status": "ok", "rung": "640x360"}})
        self.assertEqual(sweep.load_sweep(None), {})

    def test_a_partial_last_line_is_skipped_but_not_one_in_the_middle(self):
        from milkpack.sources import PipelineError

        good = json.dumps({"file": "a.milk", "status": "ok", "rung": "640x360"})
        path = write(os.path.join(tmpdir(self), "s.jsonl"), good + "\n" + '{"file": "b.mi' + "\n\n")
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertEqual(list(sweep.load_sweep(path)), ["a.milk"])
        self.assertIn(":2: skipping a partial last line", err.getvalue())
        write(path, '{"file": "b.mi\n' + good + "\n")
        with self.assertRaisesRegex(PipelineError, ":1: invalid JSON"):
            sweep.load_sweep(path)

    def test_vc4_trial_csv_maps_to_normalised_ids(self):
        path = write(os.path.join(tmpdir(self), "t.csv"),
                     "idx,preset,folder,gpu_ms_warp_comp,switch_stall_ms\n"
                     "0,HDFX  New .milk,root,19.45,131.1\n"
                     "1,high_frequency/extreme/x  y.milk,high_frequency,,\n")
        self.assertEqual(sweep.load_vc4_trial(path), {
            "HDFX New.milk": {"warp_comp_ms": 19.45, "stall_ms": 131.1},
            "high_frequency/extreme/x y.milk": {"warp_comp_ms": None, "stall_ms": None}})


if __name__ == "__main__":
    unittest.main()
