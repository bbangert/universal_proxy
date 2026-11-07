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


class FakeClock:
    """A monotonic clock that only moves when a sleep or a probe takes time."""

    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class StubDevice:
    """Answers `state` once the clock reaches `up_at`; until then each probe
    takes `probe_s` (hanging to its timeout when that is longer)."""

    def __init__(self, clock, up_at=float("inf"), probe_s=0.5):
        self.clock, self.up_at, self.probe_s = clock, up_at, probe_s
        self.timeouts = []

    def state(self, timeout):
        self.timeouts.append(timeout)
        self.clock.now += min(self.probe_s, timeout)
        if self.clock.now >= self.up_at:
            return {"uptime_ms": 1000, "boot_id": "b", "lo": self.clock.now, "hi": self.clock.now}
        return None


class WaitForDeviceTest(unittest.TestCase):
    def wait(self, device, clock, budget_s):
        with contextlib.redirect_stdout(io.StringIO()):
            start = clock.now
            state = device_sweep.wait_for_device(device, budget_s, clock=clock, sleep=clock.sleep)
        return state, clock.now - start

    def test_a_300s_budget_polls_for_about_300s_with_fast_failing_probes(self):
        clock = FakeClock()
        dev = StubDevice(clock, up_at=clock.now + 250)
        state, _ = self.wait(dev, clock, 300)
        self.assertIsNotNone(state)  # a device back late in the budget is still found

        clock = FakeClock()
        dev = StubDevice(clock)
        state, elapsed = self.wait(dev, clock, 300)
        self.assertIsNone(state)
        self.assertGreaterEqual(elapsed, 300)
        self.assertLess(elapsed, 301)

    def test_a_60s_budget_is_not_overrun_by_slow_probes(self):
        clock = FakeClock()
        dev = StubDevice(clock, probe_s=1000)  # every probe hangs to its timeout
        state, elapsed = self.wait(dev, clock, 60)
        self.assertIsNone(state)
        self.assertLessEqual(elapsed, 61)
        self.assertTrue(all(t <= device_sweep.PROBE_TIMEOUT_S for t in dev.timeouts))
        self.assertEqual(dev.timeouts[0], 45)
        self.assertLessEqual(dev.timeouts[-1], 15)  # capped to what was left

    def test_a_zero_budget_still_probes_once(self):
        clock = FakeClock()
        dev = StubDevice(clock, probe_s=1000)
        state, elapsed = self.wait(dev, clock, 0)
        self.assertIsNone(state)
        self.assertEqual(len(dev.timeouts), 1)
        self.assertLessEqual(elapsed, 1)


class SettleTest(unittest.TestCase):
    def test_a_device_lost_mid_grace_is_unreachable_within_the_reboot_wait(self):
        clock = FakeClock()
        down_at = clock.now + 7

        class VanishingDevice:
            """Answers on one boot until `down_at`, then every ssh hangs to its timeout."""

            def __init__(self):
                self.timeouts = []

            def state(self, timeout=device_sweep.PROBE_TIMEOUT_S):
                self.timeouts.append(timeout)
                if clock.now < down_at:
                    clock.now += 0.5
                    return {"uptime_ms": 1000, "boot_id": "b", "lo": clock.now - 0.5, "hi": clock.now}
                clock.now += timeout
                return None

        dev = VanishingDevice()
        with contextlib.redirect_stdout(io.StringIO()):
            verdict, state = device_sweep.settle(dev, None, 60, 20, clock=clock, sleep=clock.sleep)
        self.assertEqual((verdict, state), ("unreachable", None))
        # From the first hung probe: the wait budget, plus at most one grace
        # poll and one capped probe.
        self.assertLessEqual(clock.now - down_at, 60 + device_sweep.GRACE_POLL_S + 1)
        self.assertTrue(all(t <= device_sweep.PROBE_TIMEOUT_S for t in dev.timeouts))


class FakeDevice(device_sweep.Device):
    """A device driven over ssh, answering by what the Elixir is for. Per
    preset, `behaviours` lists what each run does (default "ok"):

      ok          runs to the end
      reset       the Pi reboots mid-run; the connection drops and ssh
                  stays unanswered for `down` polls
      drop        the connection drops, the Pi stays up
      late_reset  the connection drops; the Pi answers `alive` more probes,
                  then reboots
      gpu         runs to the end, but the kernel reset the GPU (once)
      gpu_reset   as gpu, then the Pi answers `alive` probes and reboots
      no_connect  ssh can't connect at all (the run never starts)
    """

    def __init__(self, behaviours=None, down=3, boot_ids=True, connect_s=0, run_s=30, alive=1):
        self.behaviours = {k: list(v) for k, v in (behaviours or {}).items()}
        self.down, self.boot_ids, self.alive = down, boot_ids, alive
        self.reset_in = None  # probes left before a pending reboot
        self.connect_s, self.run_s = connect_s, run_s
        self.polls_left = 0
        self.clock = FakeClock()
        self.boot_at = self.clock.now - 600
        self.boot = 1
        self.runs = []

    def boot_line(self):
        uptime_ms = int((self.clock.now - self.boot_at) * 1000)
        return f"BOOT {uptime_ms} " + (f"boot-{self.boot}" if self.boot_ids else "none")

    def reboot(self):
        self.boot_at, self.boot, self.polls_left = self.clock.now - 12, self.boot + 1, self.down

    def ssh(self, code, timeout):
        if "renderer_ok" in code:
            return json.dumps({"renderer": "/r", "renderer_ok": True, "fw_uuid": "u", "pack_ok": True})
        if "Port.open" not in code:
            if self.reset_in is not None:
                self.reset_in -= 1
                if self.reset_in < 0:
                    self.reset_in = None
                    self.reboot()
            if self.polls_left > 0:
                self.polls_left -= 1
                return "ssh: connect to host dev port 22: No route to host"
            return self.boot_line()
        args = next(a for a in (json.loads(base64.b64decode(b)) for b in re.findall(r'decode64!\("([^"]+)"\)', code))
                    if "--locked" in a)
        pid = args[args.index("--locked") + 1]
        self.runs.append(pid)
        queue = self.behaviours.get(pid) or []
        behaviour = queue.pop(0) if queue else "ok"
        if behaviour == "no_connect":
            return "ssh: connect to host dev port 22: Connection refused"
        self.clock.now += self.connect_s
        boot = self.boot_line()
        self.clock.now += self.run_s
        if behaviour == "reset":
            self.reboot()
            return boot + "\nConnection to dev closed by remote host."
        if behaviour in ("late_reset", "gpu_reset"):
            self.reset_in = self.alive
        if behaviour in ("drop", "late_reset"):
            return boot + "\nclient_loop: send disconnect: Broken pipe"
        stats = {"event": "stats", "fps": 30.0, "frames": 150, "flip_ms": 33.0, "frame_ms": 12.5,
                 "rung": "640x360", "temp_c": 60.0, "arm_mhz": 1200, "preset": pid, "warmups": 1,
                 "warmup_ms_max": 200.0, "shader_stages": 2, "cached_stages": 2}
        return "\n".join([boot, json.dumps({"event": "preset", "file": pid}), json.dumps(stats),
                          json.dumps({"event": "exiting", "reason": "headless_done"}),
                          "GPU_RESET " + ("1" if behaviour.startswith("gpu") else "0"), "EXIT_STATUS 0"])

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
        clock = device.clock
        with mock.patch.object(device_sweep, "Device", lambda opts: device), \
                mock.patch.object(device_sweep.time, "monotonic", clock), \
                mock.patch.object(device_sweep.time, "sleep", side_effect=clock.sleep) as sleep, \
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

    def test_a_slow_ssh_connect_without_a_boot_id_is_not_a_reboot(self):
        # The run's boot state is sampled 60 s after its ssh call began.
        dev = FakeDevice({"b.milk": ["drop"]}, boot_ids=False, connect_s=60)
        self.sweep(dev)
        b = {r["file"]: r for r in self.records()}["b.milk"]
        self.assertEqual((b["status"], b["reason"]), ("error", "no_stats"))

    def test_a_reset_seconds_after_a_failed_run_is_blamed_on_it(self):
        for boot_ids in (True, False):
            with self.subTest(boot_ids=boot_ids):
                if os.path.exists(self.out):
                    os.remove(self.out)
                # Answers the first probe after the run, then goes down.
                dev = FakeDevice({"b.milk": ["late_reset"]}, boot_ids=boot_ids, alive=1)
                self.assertEqual(self.sweep(dev), 0)
                recs = {r["file"]: r for r in self.records()}
                b = recs["b.milk"]
                self.assertEqual((b["status"], b["reason"], b["error"]), ("skip", "device_reset", "no_stats"))
                self.assertEqual((recs["a.milk"]["status"], recs["c.milk"]["status"]), ("ok", "ok"))
                self.assertEqual(dev.runs, ["a.milk", "b.milk", "c.milk"])

    def test_a_gpu_reset_the_device_survived_skips_the_preset(self):
        dev = FakeDevice({"b.milk": ["gpu"]})
        self.assertEqual(self.sweep(dev), 0)
        recs = {r["file"]: r for r in self.records()}
        b = recs["b.milk"]
        self.assertEqual((b["status"], b["reason"], b["gpu_resets"], b["run_status"]), ("skip", "gpu_hang", 1, "ok"))
        self.assertEqual((recs["a.milk"]["gpu_resets"], recs["c.milk"]["status"]), (0, "ok"))
        self.assertEqual(dev.runs, ["a.milk", "b.milk", "c.milk"])
        self.assertEqual(self.sleeps, [5, 5, 5, 5])  # stayed up through the 20 s grace
        self.assertEqual(self.sweep(FakeDevice()), 0)  # settled: not run again
        self.assertEqual(len(self.records()), 3)

    def test_a_gpu_reset_that_takes_the_device_down_later_is_a_device_reset(self):
        dev = FakeDevice({"b.milk": ["gpu_reset"]}, alive=2)
        self.assertEqual(self.sweep(dev), 0)
        recs = {r["file"]: r for r in self.records()}
        b = recs["b.milk"]
        self.assertEqual((b["status"], b["reason"], b["error"], b["gpu_resets"]),
                         ("skip", "device_reset", "gpu_hang", 1))
        self.assertEqual((b["boot_before"], b["boot_after"]), ("boot-1", "boot-2"))
        self.assertEqual(recs["c.milk"]["status"], "ok")

    def test_the_grace_period_is_configurable(self):
        self.sweep(FakeDevice({"b.milk": ["drop"]}), "--reset-grace-s", "0")
        self.assertEqual(self.sleeps, [])
        os.remove(self.out)
        self.sweep(FakeDevice({"b.milk": ["drop"]}), "--reset-grace-s", "12")
        self.assertEqual(self.sleeps, [5, 5, 5])

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

    def test_an_uptime_reboot_needs_the_uptime_to_fall_behind_the_least_elapsed_time(self):
        def state(uptime_s, lo, hi, boot_id=None):
            return {"uptime_ms": uptime_s * 1000, "boot_id": boot_id, "lo": lo, "hi": hi}

        # Sampled 60 s into a 70 s call; probed right after: 10 s further on.
        before = state(660, lo=0, hi=70)
        self.assertFalse(device_sweep.rebooted(before, state(670, lo=70, hi=71)))
        # Delayed probe replies (sampled late in the call) aren't reboots either.
        self.assertFalse(device_sweep.rebooted(before, state(760, lo=71, hi=170)))
        self.assertFalse(device_sweep.rebooted(before, state(900, lo=200, hi=240)))
        # Up 200 s later with less uptime than that: it restarted.
        self.assertTrue(device_sweep.rebooted(before, state(30, lo=72, hi=73)))
        self.assertTrue(device_sweep.rebooted(before, state(800, lo=300, hi=301)))
        # The boot id decides whenever both states have one.
        self.assertFalse(device_sweep.rebooted(state(660, 0, 70, "a"), state(5, 72, 73, "a")))
        self.assertTrue(device_sweep.rebooted(state(660, 0, 70, "a"), state(900, 72, 73, "b")))

    def test_the_boot_state_parses(self):
        from milkpack import sweep

        self.assertEqual(sweep.parse_boot("noise\r\nBOOT 1234 abc-def\r\n"), {"uptime_ms": 1234, "boot_id": "abc-def"})
        self.assertEqual(sweep.parse_boot("BOOT 7 none"), {"uptime_ms": 7, "boot_id": None})
        self.assertIsNone(sweep.parse_boot("ssh: connect to host dev: refused"))
        self.assertEqual(sweep.parse_run("a.milk", "BOOT 7 x\nEXIT_STATUS timeout")["reason"], "no_stats")

    def test_swept_gpu_hangs_and_device_resets_reach_the_manifest(self):
        from milkpack import manifest, sweep

        self.sweep(FakeDevice({"a.milk": ["gpu"], "b.milk": ["late_reset"]}))
        doc = manifest.build("2026.11.1", list(self.PRESETS), sweep.load_sweep(self.out))
        self.assertEqual(manifest.validate(doc), [])
        by = {p["file"]: p for p in doc["presets"]}
        self.assertEqual(by["a.milk"]["rpi3"], {"rung": "skip", "reason": "gpu_hang"})
        self.assertNotIn("compile_ms", by["a.milk"])  # the hung run's timings aren't kept
        self.assertEqual(by["b.milk"]["rpi3"], {"rung": "skip", "reason": "device_reset"})
        self.assertEqual(by["c.milk"]["rpi3"], {"rung": "640x360"})

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
