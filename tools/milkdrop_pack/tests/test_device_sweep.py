import argparse
import base64
import contextlib
import io
import json
import os
import re
import sys
import unittest
from unittest import mock

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

    def test_error_records_are_retried(self):
        write(self.out, json.dumps({"file": "a.milk", "status": "error", "reason": "no_stats",
                                    "pack_sha256": self.digest}) + "\n")
        _, out = self.sweep()
        self.assertIn("0 done, 2 to run", out)
        self.assertEqual(sorted(c[-1] for c in self.calls()), ["a.milk", "high_frequency/b.milk"])
        self.assertEqual({r["file"]: r["status"] for r in self.records()[1:]},
                         {"a.milk": "ok", "high_frequency/b.milk": "skip"})
        _, out = self.sweep()
        self.assertIn("2 done, 0 to run", out)

    def test_a_partial_last_line_is_cut_before_appending(self):
        self.sweep("--only", "a.milk")
        with open(self.out, "a") as f:
            f.write('{"file": "high_frequency/b.milk", "sta')
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.sweep()
        self.assertIn("partial last line", err.getvalue())
        self.assertEqual([r["file"] for r in self.records()], ["a.milk", "high_frequency/b.milk"])

    def test_a_complete_last_record_without_newline_is_kept(self):
        self.sweep("--only", "a.milk")
        with open(self.out) as f:
            data = f.read()
        with open(self.out, "w") as f:
            f.write(data.rstrip("\n"))
        _, out = self.sweep()
        self.assertIn("1 done, 1 to run", out)
        self.assertEqual([r["file"] for r in self.records()], ["a.milk", "high_frequency/b.milk"])

    def test_ssh_verifies_host_keys_unless_told_not_to(self):
        def opts(**kw):
            return device_sweep.ssh_opts(argparse.Namespace(**{"known_hosts": None,
                                                                "insecure_no_host_key_check": False, **kw}))

        default = opts()
        self.assertIn("StrictHostKeyChecking=yes", default)
        self.assertFalse(any(o.startswith("UserKnownHostsFile") for o in default))
        pinned = opts(known_hosts="/k/hosts")
        self.assertIn("StrictHostKeyChecking=yes", pinned)
        self.assertIn("UserKnownHostsFile=/k/hosts", pinned)
        insecure = opts(insecure_no_host_key_check=True)
        self.assertIn("StrictHostKeyChecking=no", insecure)
        self.assertIn("UserKnownHostsFile=/dev/null", insecure)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            self.sweep("--known-hosts", "/k", "--insecure-no-host-key-check")

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

    def test_the_run_reports_the_boot_state_first(self):
        code = device_sweep.elixir_run("/r", ["--locked", "a.milk"], 1000, 70, 300)
        self.assertLess(code.index("BOOT #{up}"), code.index("cool = fn"))
        self.assertIn(":erlang.statistics(:wall_clock)", code)
        self.assertIn("/proc/sys/kernel/random/boot_id", code)

    def test_elixir_carries_ids_as_base64(self):
        code = device_sweep.elixir_run("/r", ["--locked", 'we#{ird} "x".milk'], 1000, 70, 300)
        self.assertNotIn("we#{ird}", code)
        self.assertIn(device_sweep.b64json(["--locked", 'we#{ird} "x".milk']), code)


class FakeDevice(device_sweep.Device):
    """A device driven over ssh, answering by what the Elixir is for. Per
    preset, `behaviours` lists what each run does (default "ok"):

      ok          runs to the end
      reset       the Pi reboots mid-run; the connection drops and ssh
                  stays unanswered for `down` polls
      drop        the connection drops, the Pi stays up
      no_connect  ssh can't connect at all (the run never starts)
    """

    def __init__(self, behaviours=None, down=3, boot_ids=True):
        self.behaviours = {k: list(v) for k, v in (behaviours or {}).items()}
        self.down, self.boot_ids = down, boot_ids
        self.polls_left = 0
        self.uptime_ms = 600_000
        self.boot = 1
        self.runs = []

    def boot_line(self):
        self.uptime_ms += 1000
        return f"BOOT {self.uptime_ms} " + (f"boot-{self.boot}" if self.boot_ids else "none")

    def ssh(self, code, timeout):
        if "renderer_ok" in code:
            return json.dumps({"renderer": "/r", "renderer_ok": True, "fw_uuid": "u", "pack_ok": True})
        if "Port.open" not in code:
            if self.polls_left > 0:
                self.polls_left -= 1
                return "ssh: connect to host dev port 22: No route to host"
            return self.boot_line()
        args = json.loads(base64.b64decode(re.search(r'decode64!\("([^"]+)"\)', code).group(1)))
        pid = args[args.index("--locked") + 1]
        self.runs.append(pid)
        queue = self.behaviours.get(pid) or []
        behaviour = queue.pop(0) if queue else "ok"
        if behaviour == "no_connect":
            return "ssh: connect to host dev port 22: Connection refused"
        boot = self.boot_line()
        if behaviour == "reset":
            self.uptime_ms, self.boot, self.polls_left = 12_000, self.boot + 1, self.down
            return boot + "\nConnection to dev closed by remote host."
        if behaviour == "drop":
            return boot + "\nclient_loop: send disconnect: Broken pipe"
        stats = {"event": "stats", "fps": 30.0, "frames": 150, "flip_ms": 33.0, "frame_ms": 12.5,
                 "rung": "640x360", "temp_c": 60.0, "arm_mhz": 1200, "preset": pid, "warmups": 1,
                 "warmup_ms_max": 200.0, "shader_stages": 2, "cached_stages": 2}
        return "\n".join([boot, json.dumps({"event": "preset", "file": pid}), json.dumps(stats),
                          json.dumps({"event": "exiting", "reason": "headless_done"}), "EXIT_STATUS 0"])

    def put(self, local, remote):
        raise AssertionError("the pack is already on the device")


class RebootAwareSweepTest(unittest.TestCase):
    PRESETS = ("a.milk", "b.milk", "c.milk")

    def setUp(self):
        d = tmpdir(self)
        pack = tiny_pack(os.path.join(d, "pack"), self.PRESETS)
        self.tar = os.path.join(d, "up-milkdrop-pack-2026.11.1.tar.gz")
        tarball.create(pack, self.tar)
        self.out = os.path.join(d, "sweep.jsonl")

    def sweep(self, device, *extra):
        buf = io.StringIO()
        with mock.patch.object(device_sweep, "Device", lambda opts: device), \
                mock.patch.object(device_sweep.time, "sleep") as sleep, \
                contextlib.redirect_stdout(buf), contextlib.redirect_stderr(io.StringIO()):
            code = device_sweep.main(["--tarball", self.tar, "--out", self.out, "--host", "dev", *extra])
        self.sleeps = [c.args[0] for c in sleep.call_args_list]
        return code

    def records(self):
        with open(self.out) as f:
            return [json.loads(line) for line in f]

    def test_a_clean_sweep_asks_nothing_extra(self):
        dev = FakeDevice()
        self.assertEqual(self.sweep(dev), 0)
        self.assertEqual([r["status"] for r in self.records()], ["ok"] * 3)
        self.assertEqual(self.sleeps, [])

    def test_a_reset_mid_preset_is_a_skip_and_the_sweep_goes_on(self):
        dev = FakeDevice({"b.milk": ["reset"]}, down=3)
        self.assertEqual(self.sweep(dev), 0)
        recs = {r["file"]: r for r in self.records()}
        self.assertEqual(recs["a.milk"]["status"], "ok")
        b = recs["b.milk"]
        self.assertEqual((b["status"], b["reason"]), ("skip", "device_reset"))
        self.assertEqual((b["boot_before"], b["boot_after"]), ("boot-1", "boot-2"))
        self.assertGreater(b["uptime_before_ms"], b["uptime_after_ms"])
        self.assertEqual(b["error"], "no_stats")
        self.assertEqual(recs["c.milk"]["status"], "ok")
        self.assertEqual(dev.runs, ["a.milk", "b.milk", "c.milk"])
        self.assertEqual(self.sleeps, [5, 10, 20])  # down for three polls, backing off
        # The skip settles it: a rerun doesn't run it (and reboot the Pi) again.
        self.assertEqual(self.sweep(FakeDevice()), 0)
        self.assertEqual(len(self.records()), 3)

    def test_a_reset_is_seen_from_the_uptime_when_there_is_no_boot_id(self):
        dev = FakeDevice({"b.milk": ["reset"]}, down=0, boot_ids=False)
        self.sweep(dev)
        b = {r["file"]: r for r in self.records()}["b.milk"]
        self.assertEqual((b["status"], b["reason"], b["boot_before"]), ("skip", "device_reset", None))

    def test_a_dropped_connection_without_a_reboot_is_an_error(self):
        dev = FakeDevice({"b.milk": ["drop"]})
        self.sweep(dev)
        recs = {r["file"]: r for r in self.records()}
        self.assertEqual((recs["b.milk"]["status"], recs["b.milk"]["reason"]), ("error", "no_stats"))
        self.assertEqual((recs["a.milk"]["status"], recs["c.milk"]["status"]), ("ok", "ok"))
        self.assertEqual(self.sweep(FakeDevice()), 0)  # retried by the next run
        self.assertEqual(self.records()[-1]["status"], "ok")
        self.assertEqual(self.records()[-1]["file"], "b.milk")

    def test_a_run_that_never_started_is_tried_again_not_recorded(self):
        dev = FakeDevice({"b.milk": ["no_connect", "ok"]})
        self.sweep(dev)
        self.assertEqual([(r["file"], r["status"]) for r in self.records()],
                         [("a.milk", "ok"), ("b.milk", "ok"), ("c.milk", "ok")])
        self.assertEqual(dev.runs, ["a.milk", "b.milk", "b.milk", "c.milk"])

    def test_a_run_that_keeps_failing_to_start_is_an_error(self):
        dev = FakeDevice({"b.milk": ["no_connect"] * 3})
        self.sweep(dev)
        recs = {r["file"]: r for r in self.records()}
        self.assertEqual((recs["b.milk"]["status"], recs["b.milk"]["reason"]), ("error", "no_stats"))
        self.assertEqual(dev.runs.count("b.milk"), 3)

    def test_a_device_that_does_not_come_back_stops_the_sweep(self):
        dev = FakeDevice({"b.milk": ["reset"]}, down=10_000)
        self.assertEqual(self.sweep(dev, "--reboot-wait-s", "60"), 1)
        recs = self.records()
        self.assertEqual([(r["file"], r["status"]) for r in recs], [("a.milk", "ok"), ("b.milk", "error")])
        self.assertEqual(recs[1]["device"], "unreachable")
        self.assertEqual(dev.runs, ["a.milk", "b.milk"])  # nothing recorded for c.milk
        self.assertLessEqual(sum(self.sleeps), 60)

    def test_the_boot_state_parses(self):
        from milkpack import sweep

        self.assertEqual(sweep.parse_boot("noise\r\nBOOT 1234 abc-def\r\n"), {"uptime_ms": 1234, "boot_id": "abc-def"})
        self.assertEqual(sweep.parse_boot("BOOT 7 none"), {"uptime_ms": 7, "boot_id": None})
        self.assertIsNone(sweep.parse_boot("ssh: connect to host dev: refused"))
        self.assertEqual(sweep.parse_run("a.milk", "BOOT 7 x\nEXIT_STATUS timeout")["reason"], "no_stats")

    def test_device_resets_reach_the_manifest(self):
        from milkpack import manifest, sweep

        recs = [{"file": "a.milk", "status": "skip", "reason": "device_reset", "boot_before": "x"},
                {"file": "b.milk", "status": "skip", "reason": "gpu_hang"},
                {"file": "c.milk", "status": "ok", "rung": "640x360"}]
        write(self.out, "".join(json.dumps(r) + "\n" for r in recs))
        doc = manifest.build("2026.11.1", list(self.PRESETS), sweep.load_sweep(self.out))
        self.assertEqual(manifest.validate(doc), [])
        by = {p["file"]: p["rpi3"] for p in doc["presets"]}
        self.assertEqual(by["a.milk"], {"rung": "skip", "reason": "device_reset"})
        self.assertEqual(by["b.milk"], {"rung": "skip", "reason": "gpu_hang"})
        self.assertEqual(by["c.milk"], {"rung": "640x360"})


if __name__ == "__main__":
    unittest.main()
