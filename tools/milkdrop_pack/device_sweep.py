#!/usr/bin/env python3
"""Measure every preset of a built pack on a Raspberry Pi 3 (the rpi3 sweep).

    tools/milkdrop_pack/device_sweep.py --host 192.168.2.102 --known-hosts ~/.ssh/md-sweep-known_hosts \\
        --tarball out/up-milkdrop-pack-2026.11.1.tar.gz --out sweep.jsonl

Copies the tarball to the device (sftp) and extracts it under --remote-dir,
then runs the device's own milkdrop_renderer once per preset, headless on the
render node (--headless-frames on /dev/dri/renderD128: no KMS, no DRM master,
so Emerge and the TV are untouched), locked on that preset with the test tone
as audio. Each run's events become one JSON line in --out (fps, flip/CPU
frame ms, the rung the cost guard settled on, skip reason, warm-up ms, ...),
which build_pack.py --device-sweep turns into the manifest's rpi3 fields.

Resumable: presets that already have an "ok" or "skip" record for this
tarball's SHA-256 in --out are not run again (errors are retried), so an
interrupted multi-hour sweep just continues.

Reboot-aware: some presets hang the vc4 GPU, the kernel resets it and the
whole Pi reboots. Each run reports the device's uptime and boot id first;
when a run fails, the sweep waits (--reboot-wait-s) for the device to come
back and compares them. A preset that took the device down is recorded as
a "skip" with reason "device_reset" (and never retried); other failures
stay "error".
Before each preset it waits for the SoC to cool below --cooldown-c, so the
renderer's thermal guard doesn't skew late results.

The device's SSH host key is verified (known_hosts, or --known-hosts FILE);
--insecure-no-host-key-check is for a throwaway dev device only.

The device is driven over nerves_ssh, which evaluates Elixir: never send
System.halt (it reboots the device). --dry-run prints the plan and the
Elixir for the first preset without connecting; --local-renderer runs a
renderer binary on this machine instead of over SSH.
"""

import argparse
import base64
import datetime
import json
import os
import subprocess
import sys
import tarfile
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from milkpack import sweep  # noqa: E402
from milkpack.tarball import sha256  # noqa: E402

# Marks a device copy extracted (and its manifest stripped) by this script.
MARKER_SUFFIX = " sweep-manifest"

BASE_SSH_OPTS = ["-o", "LogLevel=ERROR", "-o", "ConnectTimeout=15", "-o", "BatchMode=yes"]


def ssh_opts(opts):
    """ssh/sftp options. The device's host key is verified (against the
    user's known_hosts, or --known-hosts) unless --insecure-no-host-key-check:
    an impersonated device could feed fabricated measurements into the
    manifest."""
    if opts.insecure_no_host_key_check:
        keys = ["-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null"]
    elif opts.known_hosts:
        keys = ["-o", "StrictHostKeyChecking=yes", "-o", f"UserKnownHostsFile={os.path.expanduser(opts.known_hosts)}"]
    else:
        keys = ["-o", "StrictHostKeyChecking=yes"]
    return [*keys, *BASE_SSH_OPTS]


def renderer_args(opts, pack_dir, pid):
    return ["--mode", "1280x720@60", "--pack-dir", pack_dir, "--ladder", opts.ladder,
            "--rotate-s", "3600", "--skip-file", pack_dir + ".none.skip", "--card", opts.card,
            "--headless-frames", str(opts.frames), "--test-tone", "--high-frequency",
            "--stats-s", str(opts.stats_s), "--seed", "1", "--locked", pid]


def b64json(value):
    return base64.b64encode(json.dumps(value).encode()).decode()


def elixir_probe(remote_dir, version, digest):
    """Prints a JSON object: the renderer path, firmware UUID and whether the
    pack is already extracted for this digest."""
    return f'''
renderer = Path.join(:code.priv_dir(:universal_proxy) |> List.to_string(), "milkdrop_renderer/rpi3/milkdrop_renderer")
marker = Path.join("{remote_dir}", "{version}.sha256")
IO.puts(:json.encode(%{{
  renderer: renderer,
  renderer_ok: File.regular?(renderer),
  fw_uuid: Nerves.Runtime.KV.get_active("nerves_fw_uuid"),
  pack_ok: File.read(marker) == {{:ok, "{digest}{MARKER_SUFFIX}"}} and File.regular?(Path.join("{remote_dir}/{version}", "manifest.json"))
}}))'''


def elixir_extract(remote_dir, version, digest):
    """Extracts the pack and strips its manifest's rpi3 hints
    (sweep.sweep_manifest): the device copy is the sweep's own."""
    return f'''
dir = Path.join("{remote_dir}", "{version}")
File.rm_rf!(dir)
File.mkdir_p!(dir)
:ok = :erl_tar.extract(~c"{remote_dir}/{version}.tar.gz", [:compressed, {{:cwd, String.to_charlist(dir)}}])
manifest = Path.join(dir, "manifest.json")
doc = :json.decode(File.read!(manifest))
stripped = Enum.map(doc["presets"], &Map.drop(&1, {json.dumps(list(sweep.SWEEP_STRIPPED_KEYS))}))
File.write!(manifest, :json.encode(Map.put(doc, "presets", stripped)))
File.write!(Path.join("{remote_dir}", "{version}.sha256"), "{digest}{MARKER_SUFFIX}")
File.rm("{remote_dir}/{version}.tar.gz")
IO.puts("EXTRACTED " <> dir)'''


# Prints "BOOT <BEAM wall clock ms> <boot id or none>": the device's uptime
# (the BEAM starts with the system) and which boot it is.
BOOT_ELIXIR = '''
{up, _} = :erlang.statistics(:wall_clock)
boot = case File.read("/proc/sys/kernel/random/boot_id") do
  {:ok, id} -> String.trim(id)
  _ -> "none"
end
IO.puts("BOOT #{up} #{boot}")'''


def kmsg_reader(kmsg):
    """/bin/sh args that stream the kernel log (busybox has no dmesg -w):
    /dev/kmsg replays its whole buffer to a new reader, then blocks for
    new records."""
    return ["-c", 'exec cat "$0" 2>/dev/null', kmsg]


def elixir_run(renderer, args, timeout_ms, cooldown_c, cooldown_max_s, kmsg="/dev/kmsg", reader=None):
    """Prints the boot state, waits for the SoC to cool, runs the renderer,
    prints its output, "GPU_RESET n" (kernel "Resetting GPU" lines logged
    during the run, or "unknown" when the kernel log can't be read) and
    "EXIT_STATUS n" (or "EXIT_STATUS timeout" after a kill -9).

    The kernel log is read by a `reader` port (default: cat `kmsg`) started
    just before the renderer and killed after it. A marker record written
    to `kmsg` first marks where the run's records begin in the replay."""
    return f"""{BOOT_ELIXIR}
cool = fn cool, waited ->
  temp = case File.read("/sys/class/thermal/thermal_zone0/temp") do
    {{:ok, t}} -> String.to_integer(String.trim(t)) / 1000
    _ -> 0
  end
  if temp >= {cooldown_c} and waited < {cooldown_max_s} do
    Process.sleep(5000)
    cool.(cool, waited + 5)
  else
    IO.puts("COOLDOWN #{{waited}} #{{temp}}")
  end
end
cool.(cool, 0)
kmsg = "{kmsg}"
reader = :json.decode(Base.decode64!("{b64json(reader or kmsg_reader(kmsg))}"))
marker = "md_sweep run #{{System.os_time()}}-#{{:erlang.unique_integer([:positive])}}"
# Never create kmsg: a missing one means no kernel log.
kport = with true <- File.exists?(kmsg),
             :ok <- File.write(kmsg, "<6>" <> marker <> "\\n", [:append]) do
  try do
    Port.open({{:spawn_executable, "/bin/sh"}}, [:binary, :exit_status, {{:args, reader}}])
  rescue
    _ -> nil
  end
else
  _ -> nil
end
args = :json.decode(Base.decode64!("{b64json(args)}"))
port = Port.open({{:spawn_executable, "{renderer}"}}, [:binary, :exit_status, :stderr_to_stdout, {{:args, args}}])
{{:os_pid, os}} = Port.info(port, :os_pid)
loop = fn loop, acc, deadline ->
  receive do
    {{^port, {{:data, d}}}} -> loop.(loop, [acc, d], deadline)
    {{^port, {{:exit_status, s}}}} -> {{s, acc}}
  after max(deadline - System.monotonic_time(:millisecond), 0) ->
    System.cmd("kill", ["-9", Integer.to_string(os)])
    {{:timeout, acc}}
  end
end
{{st, out}} = loop.(loop, [], System.monotonic_time(:millisecond) + {timeout_ms})
IO.puts(IO.iodata_to_binary(out))
# The replay and anything logged since: read until 500 ms pass quietly
# (3 s at most), then stop the reader, which would otherwise block forever.
gpu = if kport do
  drain = fn drain, acc, cap ->
    left = cap - System.monotonic_time(:millisecond)
    if left <= 0 do
      acc
    else
      receive do
        {{^kport, {{:data, d}}}} -> drain.(drain, [acc, d], cap)
        {{^kport, {{:exit_status, _}}}} -> acc
      after min(500, left) -> acc
      end
    end
  end
  log = drain.(drain, [], System.monotonic_time(:millisecond) + 3000)
  case Port.info(kport, :os_pid) do
    {{:os_pid, kos}} -> System.cmd("kill", ["-9", Integer.to_string(kos)], stderr_to_stdout: true)
    _ -> :ok
  end
  try do
    Port.close(kport)
  rescue
    _ -> :ok
  end
  lines = log |> IO.iodata_to_binary() |> String.split("\\n")
  case Enum.find_index(lines, &String.contains?(&1, marker)) do
    nil -> "unknown"
    i -> lines |> Enum.drop(i + 1) |> Enum.count(&String.contains?(&1, "Resetting GPU")) |> Integer.to_string()
  end
else
  "unknown"
end
IO.puts("GPU_RESET " <> gpu)
IO.puts("EXIT_STATUS " <> to_string(st))"""


PROBE_TIMEOUT_S = 45


class Device:
    def __init__(self, opts):
        self.opts = opts
        self.target = f"{opts.user}@{opts.host}" if opts.user else opts.host

    def ssh(self, code, timeout):
        cmd = ["ssh", "-i", os.path.expanduser(self.opts.key), *ssh_opts(self.opts), self.target, code]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return proc.stdout + proc.stderr

    def state(self, timeout=PROBE_TIMEOUT_S):
        """The device's boot state ({"uptime_ms", "boot_id", "lo", "hi"}),
        or None while it doesn't answer within `timeout` seconds."""
        lo = time.monotonic()
        try:
            reply = self.ssh(BOOT_ELIXIR, timeout)
        except subprocess.TimeoutExpired:
            return None
        return observed(sweep.parse_boot(reply), lo, time.monotonic())

    def put(self, local, remote):
        batch = f'-mkdir {os.path.dirname(remote)}\nput "{local}" "{remote}"\n'
        cmd = ["sftp", "-i", os.path.expanduser(self.opts.key), *ssh_opts(self.opts), "-b", "-", self.target]
        subprocess.run(cmd, input=batch, text=True, check=True, capture_output=True, timeout=1800)


def read_pack(tarball):
    with tarfile.open(tarball, "r:gz") as tar:
        doc = json.load(tar.extractfile("manifest.json"))
    return doc["version"], [p["file"] for p in doc["presets"]]


# Verdicts that settle a preset; an "error" record (a timeout, a truncated
# reply, a crash) is retried by the next run.
DONE_STATUSES = ("ok", "skip")


def done_ids(out_path, digest):
    done = set()
    if os.path.exists(out_path):
        with open(out_path) as f:
            for line in f:
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if isinstance(rec, dict) and rec.get("pack_sha256") == digest \
                        and rec.get("status") in DONE_STATUSES:
                    done.add(rec.get("file"))
    return done


def repair_tail(out_path):
    """Make the sweep file safe to append to: an interrupted write can leave
    a partial last line, which the next record would be glued onto. A
    complete last record only lacks its newline; anything else is cut."""
    if not os.path.exists(out_path):
        return
    with open(out_path, "rb+") as f:
        data = f.read()
        if not data or data.endswith(b"\n"):
            return
        start = data.rfind(b"\n") + 1
        try:
            json.loads(data[start:].decode("utf-8"))
        except ValueError:
            print(f"warning: {out_path}: dropping a partial last line ({len(data) - start} bytes)",
                  file=sys.stderr)
            f.truncate(start)
            return
        f.write(b"\n")


def local_sweep_dir(pack_dir, view):
    """A view of an extracted pack at `view` for local sweeps: its presets,
    textures and shaders linked, with the stripped manifest (the pack
    itself is left alone)."""
    os.makedirs(view)
    for name in ("presets", "textures", "shaders"):
        if os.path.exists(os.path.join(pack_dir, name)):
            os.symlink(os.path.abspath(os.path.join(pack_dir, name)), os.path.join(view, name))
    with open(os.path.join(pack_dir, "manifest.json")) as f:
        doc = json.load(f)
    with open(os.path.join(view, "manifest.json"), "w") as f:
        json.dump(sweep.sweep_manifest(doc), f)
    return view


def run_local(opts, pack_dir, pid):
    args = renderer_args(opts, pack_dir, pid)
    try:
        proc = subprocess.run([opts.local_renderer, *args], capture_output=True, text=True,
                              timeout=opts.timeout)
        status = str(proc.returncode)
        out = proc.stdout + proc.stderr
    except subprocess.TimeoutExpired as e:
        out = e.stdout or ""
        status, out = "timeout", out.decode("utf-8", "replace") if isinstance(out, bytes) else out
    return out + f"\nEXIT_STATUS {status}\n"


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--tarball", required=True, help="the pack built by build_pack.py")
    p.add_argument("--out", required=True, help="sweep file (JSON Lines, appended)")
    p.add_argument("--host", help="the rpi3's address (nerves_ssh)")
    p.add_argument("--user", default="", help="SSH user (default: none, as nerves_ssh takes any)")
    p.add_argument("--key", default="~/.ssh/up_dev_key", help="SSH private key")
    keys = p.add_mutually_exclusive_group()
    keys.add_argument("--known-hosts", help="verify the device's host key against this file (default: ssh's own)")
    keys.add_argument("--insecure-no-host-key-check", action="store_true",
                      help="don't verify the host key (a throwaway dev device that's reflashed often)")
    p.add_argument("--remote-dir", default="/data/md-sweep", help="where the pack goes on the device")
    p.add_argument("--frames", type=int, default=600, help="headless frames per preset")
    p.add_argument("--stats-s", type=int, default=5, help="renderer stats interval")
    p.add_argument("--ladder", default="640x360,480x270", help="render ladder (the device's)")
    p.add_argument("--card", default="/dev/dri/renderD128", help="DRM node (keep the render node)")
    p.add_argument("--timeout", type=int, default=240, help="seconds per preset before kill -9")
    p.add_argument("--reboot-wait-s", type=int, default=300,
                   help="how long to wait for the device to come back after a failed run")
    p.add_argument("--reset-grace-s", type=int, default=20,
                   help="how long the device must stay up on the same boot after a failed or GPU-resetting "
                        "run before the next preset")
    p.add_argument("--cooldown-c", type=float, default=70.0, help="wait until the SoC is below this")
    p.add_argument("--cooldown-max-s", type=int, default=300, help="longest cooldown wait")
    p.add_argument("--only", action="append", default=[], help="sweep just this preset id (repeatable)")
    p.add_argument("--limit", type=int, help="stop after this many presets")
    p.add_argument("--dry-run", action="store_true", help="print the plan and the first preset's Elixir")
    p.add_argument("--local-renderer", help="run this renderer binary here instead of over SSH")
    p.add_argument("--local-pack-dir", help="extracted pack for --local-renderer")
    opts = p.parse_args(argv)

    digest = sha256(opts.tarball)
    version, ids = read_pack(opts.tarball)
    if opts.only:
        unknown = sorted(set(opts.only) - set(ids))
        if unknown:
            p.error(f"not in the pack: {unknown}")
        ids = [i for i in ids if i in set(opts.only)]
    done = done_ids(opts.out, digest)
    todo = [i for i in ids if i not in done]
    if opts.limit is not None:
        todo = todo[: opts.limit]
    remote_pack = f"{opts.remote_dir}/{version}"
    print(f"pack {version} ({digest[:12]}): {len(ids)} presets, {len(done & set(ids))} done, {len(todo)} to run",
          flush=True)

    if opts.dry_run:
        if todo:
            print("renderer args:", json.dumps(renderer_args(opts, remote_pack, todo[0])))
            print(elixir_run("<renderer>", renderer_args(opts, remote_pack, todo[0]), opts.timeout * 1000,
                             opts.cooldown_c, opts.cooldown_max_s))
        return 0

    with tempfile.TemporaryDirectory(prefix="md-sweep-") as scratch:
        return sweep_all(opts, p, digest, version, todo, remote_pack, scratch)


def sweep_all(opts, p, digest, version, todo, remote_pack, scratch):
    meta = {"pack_version": version, "pack_sha256": digest, "frames": opts.frames, "ladder": opts.ladder}
    device = None
    if opts.local_renderer:
        if not opts.local_pack_dir:
            p.error("--local-renderer needs --local-pack-dir")
        meta.update(renderer=opts.local_renderer, host="local")
        view = local_sweep_dir(opts.local_pack_dir, os.path.join(scratch, "pack"))
        runner = lambda pid: run_local(opts, view, pid)  # noqa: E731
    else:
        if not opts.host:
            p.error("--host is required (or --local-renderer)")
        dev = Device(opts)
        reply = dev.ssh(elixir_probe(opts.remote_dir, version, digest), 60)
        line = next((ln for ln in reply.splitlines() if ln.startswith("{")), None)
        if line is None:
            print(f"error: no answer from {opts.host}:\n{reply[-2000:]}", file=sys.stderr)
            return 1
        probe = json.loads(line)
        if not probe["renderer_ok"]:
            print(f"error: no renderer at {probe['renderer']} (is this rpi3 firmware with milkdrop_renderer?)",
                  file=sys.stderr)
            return 1
        if not probe["pack_ok"]:
            print(f"copying the pack to {opts.host}:{opts.remote_dir}", flush=True)
            dev.put(os.path.abspath(opts.tarball), f"{opts.remote_dir}/{version}.tar.gz")
            out = dev.ssh(elixir_extract(opts.remote_dir, version, digest), 600)
            if "EXTRACTED" not in out:
                print(f"error: extracting on the device failed:\n{out[-2000:]}", file=sys.stderr)
                return 1
        meta.update(renderer=probe["renderer"], fw_uuid=probe["fw_uuid"], host=opts.host)

        def runner(pid):
            code = elixir_run(probe["renderer"], renderer_args(opts, remote_pack, pid), opts.timeout * 1000,
                              opts.cooldown_c, opts.cooldown_max_s)
            try:
                return dev.ssh(code, opts.timeout + opts.cooldown_max_s + 60)
            except subprocess.TimeoutExpired as e:
                partial = e.stdout or ""
                partial = partial.decode("utf-8", "replace") if isinstance(partial, bytes) else partial
                return partial + "\nEXIT_STATUS ssh_timeout\n"

        device = dev

    repair_tail(opts.out)
    return sweep_presets(opts, todo, runner, meta, device)


# A run whose reply has no boot state never started (ssh couldn't connect):
# it is run again, a few times, before it counts as an error.
MAX_START_RETRIES = 2

# Clock-rate and rounding margin of the uptime comparison (no boot id).
UPTIME_SLACK_MS = 2_000


def observed(boot, lo, hi):
    """A parsed boot state with when it was sampled: some time between `lo`
    and `hi` (time.monotonic(), before the ssh call and after its reply)."""
    return {**boot, "lo": lo, "hi": hi} if boot else None


def rebooted(before, after):
    """Whether the device restarted between two boot states. The boot id
    decides when both have one. Otherwise only an uptime below what the
    device must have reached had it stayed up counts: the time between the
    two samples is at least `after["lo"] - before["hi"]`, as each was taken
    somewhere inside its ssh call."""
    if before["boot_id"] and after["boot_id"]:
        return before["boot_id"] != after["boot_id"]
    least_elapsed_ms = max(0.0, after["lo"] - before["hi"]) * 1000
    return after["uptime_ms"] + UPTIME_SLACK_MS < before["uptime_ms"] + least_elapsed_ms


def wait_for_device(device, budget_s, clock=None, sleep=None):
    """The device's boot state once it answers (polled with backoff until
    `budget_s` seconds have passed on `clock`), or None. Each probe is
    capped at the time left, so the wait never outlasts the budget by more
    than a one-second probe."""
    clock = clock or time.monotonic
    sleep = sleep or time.sleep
    deadline = clock() + budget_s
    delay, first = 5, True
    while True:
        remaining = deadline - clock()
        if remaining <= 0 and not first:
            return None
        first = False
        state = device.state(timeout=max(min(PROBE_TIMEOUT_S, remaining), 1))
        if state:
            return state
        remaining = deadline - clock()
        if remaining <= 0:
            return None
        pause = min(delay, remaining)
        print(f"device not answering; retrying in {pause:.0f}s ({budget_s - remaining:.0f}s of {budget_s}s)",
              flush=True)
        sleep(pause)
        delay = min(delay * 2, 60)


GRACE_POLL_S = 5


def settle(device, before, wait_s, grace_s, clock=None, sleep=None):
    """After a suspect run on boot state `before`: ("reset", state) if the
    device restarted, ("up", state) once it has answered on the same boot
    across probes spanning at least `grace_s` seconds (a GPU hang can take
    the Pi down seconds after a probe succeeded), or ("unreachable", None)
    when it stays silent for `wait_s`."""
    clock = clock or time.monotonic
    sleep = sleep or time.sleep
    first = wait_for_device(device, wait_s, clock, sleep)
    if first is None:
        return "unreachable", None
    if before is not None and rebooted(before, first):
        return "reset", first
    last = first
    while last["lo"] - first["hi"] < grace_s:
        sleep(GRACE_POLL_S)
        state = device.state() or wait_for_device(device, wait_s, clock, sleep)
        if state is None:
            return "unreachable", None
        if rebooted(first, state) or (before is not None and rebooted(before, state)):
            return "reset", state
        last = state
    return "up", last


def reset_record(rec, before, after, text):
    """`rec` (a failed or gpu_hang run) as the "skip" of a preset that reset
    the device."""
    rec.update(status="skip", reason="device_reset", error=rec.get("reason"),
               boot_before=before["boot_id"], boot_after=after["boot_id"],
               uptime_before_ms=before["uptime_ms"], uptime_after_ms=after["uptime_ms"],
               message=text.strip()[-200:])
    return rec


def sweep_presets(opts, todo, runner, meta, device=None):
    """Runs and records `todo`. With a `device`, a failed run or one that
    reset the GPU is settled before the next preset starts: the sweep waits
    for the device to answer and stay up on the same boot for
    --reset-grace-s, and a restart in that time is blamed on this preset."""
    last = None  # the latest boot state seen
    with open(opts.out, "a") as out:
        for n, pid in enumerate(todo, 1):
            retries = 0
            while True:
                started = time.monotonic()
                text = runner(pid)
                boot = observed(sweep.parse_boot(text), started, time.monotonic())
                rec = sweep.parse_run(pid, text)
                if device is None or (rec["status"] != "error" and not rec.get("gpu_resets")):
                    last = boot or last
                    break
                # A run that never started touched nothing: no grace for it.
                verdict, after = settle(device, boot or last, opts.reboot_wait_s,
                                        opts.reset_grace_s if boot else 0)
                if verdict == "unreachable":
                    rec["device"] = "unreachable"
                    break
                if verdict == "reset" and boot:
                    reset_record(rec, boot, after, text)
                last = after
                if boot is None and retries < MAX_START_RETRIES:
                    retries += 1
                    print(f"{pid}: the run did not start; trying again ({retries}/{MAX_START_RETRIES})", flush=True)
                    continue
                break
            rec.update(meta, at=datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
                       wall_s=round(time.monotonic() - started, 1))
            out.write(json.dumps(rec) + "\n")
            out.flush()
            print(f"[{n}/{len(todo)}] {rec['status']:5s} {rec.get('rung') or '-':8s} "
                  f"{rec.get('fps') or 0:5.1f} fps  {pid}" + (f"  ({rec.get('reason')})" if rec.get("reason") else ""),
                  flush=True)
            if rec.get("device") == "unreachable":
                print(f"error: the device did not come back within {opts.reboot_wait_s}s; stopping "
                      "(rerun to continue)", file=sys.stderr)
                return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
