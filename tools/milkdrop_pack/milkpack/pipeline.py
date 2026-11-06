"""The pack build, step by step (build_pack.py is the command line)."""

import datetime
import json
import os
import re
import shutil
import subprocess
import zipfile

from . import brightness, manifest, names, presets, sources, sweep as sweep_mod, tarball, textures, translate
from .sources import PipelineError

YYYYMMN_RE = re.compile(r"\A\d{4}\.\d{2}\.\d+\Z")
DEFAULT_CONTACT = "open an issue at https://github.com/bbangert/up-milkdrop-pack/issues"


class Report:
    """Counts per step, exclusions by reason and the review list."""

    def __init__(self):
        self.steps = []
        self.excluded = []
        self.review = []
        self.notes = []

    def step(self, name, **counts):
        self.steps.append({"step": name, **counts})
        print(f"[{name}] " + ", ".join(f"{k}={v}" for k, v in counts.items()), flush=True)

    def exclude(self, pid, reason, detail=""):
        detail = detail if len(detail) <= 200 else detail[:197] + "..."
        self.excluded.append({"file": pid, "reason": reason, "detail": detail})

    def by_reason(self):
        out = {}
        for e in self.excluded:
            out.setdefault(e["reason"], []).append(e)
        return out


# -- presets ------------------------------------------------------------------

def read_zip(zip_path, report):
    """[(source path, bytes)] for the zip's .milk files; thumbnails and
    anything else are dropped."""
    entries, jpg, other = [], 0, []
    with zipfile.ZipFile(zip_path) as z:
        for info in z.infolist():
            name = info.filename
            if info.is_dir():
                continue
            if name.startswith("/") or ".." in name.split("/"):
                raise PipelineError(f"unsafe zip entry {name!r}")
            lower = name.lower()
            if lower.endswith(".milk"):
                entries.append((name, z.read(info)))
            elif lower.endswith((".jpg", ".jpeg")):
                jpg += 1
            else:
                other.append(name)
    report.step("zip", milk=len(entries), jpg_thumbnails_dropped=jpg, other_dropped=len(other))
    return entries


def assign(entries, report):
    assigned, dropped = names.assign_ids(entries)
    for source, reason, detail in dropped:
        report.exclude(source, reason, detail)
    data = dict(entries)
    staged = {pid: data[src] for src, pid in assigned}
    renamed = sum(1 for src, pid in assigned if src != pid)
    hf = sum(1 for pid in staged if pid.startswith("high_frequency/"))
    ex = sum(1 for pid in staged if pid.startswith("high_frequency/extreme/"))
    report.step("names", presets=len(staged), renamed=renamed, dropped=len(dropped),
                high_frequency=hf, extreme=ex)
    return staged


def curate(staged, curation, report, pack_dir):
    """Hand exclusions (curation.json). Applied after the brightness screen,
    so the report shows whether the screen caught them on its own."""
    screened = {e["file"] for e in report.excluded}
    removed = []
    for pid, why in sorted(curation.get("excluded_presets", {}).items()):
        # Preset ids may start with "_" too (e.g. "_Flexi - mindblob ...").
        if pid == "_comment":
            continue
        if pid in screened:
            report.notes.append(f"curated exclusion {pid!r} was already excluded by the pipeline")
        elif pid in staged:
            removed.append(pid)
            report.exclude(pid, "curated", why)
        else:
            report.notes.append(f"curated exclusion {pid!r} is not in the pack")
    remove_presets(staged, removed, pack_dir)
    report.step("curated", presets=len(staged), excluded=len(removed))


def texture_policy(staged, available, curation, report):
    """Drop presets that sample a banned or unavailable texture; return the
    texture stems to ship."""
    banned = set(curation["banned_textures"]["names"])
    sampled_by = {}
    for pid, data in staged.items():
        _ref, sampled, _rand = presets.preset_textures(data)
        sampled_by[pid] = sampled
    sampled_all = set().union(*sampled_by.values()) if sampled_by else set()
    for pid in sorted(staged):
        bad = sorted(sampled_by[pid] & banned)
        missing = sorted(n for n in sampled_by[pid] - banned if n not in available)
        if bad:
            report.exclude(pid, "banned_texture", ",".join(bad))
            del staged[pid]
        elif missing:
            report.exclude(pid, "missing_texture", ",".join(missing))
            del staged[pid]
    still = set().union(*(sampled_by[p] for p in staged)) if staged else set()
    stems, _missing = textures.select(still, curation["milkdrop_textures"]["names"], available, banned)
    report.step("textures", presets=len(staged), sampled_names=len(sampled_all), shipped=len(stems))
    return stems


def apply_screen(staged, bright, cfg, report):
    """Record the brightness verdicts; return (too_bright, load_failed) ids.
    Every staged preset needs a verdict: a missing result or a render
    error (timeout, crash, GL failure) fails the build, and a rerun renders
    just those again (successes are cached)."""
    verdicts = {pid: brightness.verdict(bright.get(pid), cfg) for pid in staged}
    errors = sorted(p for p, v in verdicts.items() if v == "error")
    if errors:
        listed = "; ".join(f"{p}: {(bright.get(p) or {}).get('error', 'no result')}" for p in errors[:10])
        raise PipelineError(f"brightness screen: {len(errors)} preset(s) without a result ({listed}); "
                            "rerun to retry them, or --skip-brightness for a dev build")
    load_failed = sorted(p for p, v in verdicts.items() if v == "load_failed")
    for pid in load_failed:
        report.exclude(pid, "load_failed", bright[pid].get("message", ""))
    too_bright = sorted(p for p, v in verdicts.items() if v == "exclude")
    for pid in too_bright:
        r = bright[pid]
        report.exclude(pid, "too_bright", f"sat {r['sat']:.3f}, luma {r['luma']:.1f}")
    report.review = sorted(({"file": p, "sat": round(bright[p]["sat"], 4), "luma": round(bright[p]["luma"], 1)}
                            for p, v in verdicts.items() if v == "review"), key=lambda e: (-e["sat"], e["file"]))
    return too_bright, load_failed


def write_presets(staged, pack_dir):
    root = os.path.join(pack_dir, "presets")
    shutil.rmtree(root, ignore_errors=True)
    for pid, data in staged.items():
        path = os.path.join(root, *pid.split("/"))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)


def remove_presets(staged, ids, pack_dir):
    for pid in ids:
        staged.pop(pid, None)
        try:
            os.remove(os.path.join(pack_dir, "presets", *pid.split("/")))
        except FileNotFoundError:
            pass


# -- text files ----------------------------------------------------------------

def fill(template, values):
    with open(os.path.join(sources.TOOL_DIR, "templates", template)) as f:
        text = f.read()
    for key, value in values.items():
        text = text.replace(f"@{key}@", str(value))
    left = re.findall(r"@[A-Z_0-9]+@", text)
    if left:
        raise PipelineError(f"{template}: unfilled {sorted(set(left))}")
    return text


def exclusion_text(report):
    labels = {
        "banned_texture": "sample a banned texture",
        "missing_texture": "sample a texture that isn't available",
        "translate_failed": "a shader doesn't translate to GLSL ES 1.00",
        "too_bright": "whiteout in the brightness screen",
        "load_failed": "projectM can't load the preset (expression syntax)",
        "curated": "excluded by hand",
        "duplicate": "byte-identical duplicate after name normalisation",
        "invalid_name": "no valid file name after normalisation",
    }
    lines = []
    for reason, items in sorted(report.by_reason().items()):
        lines.append(f"{len(items)} preset(s): {labels.get(reason, reason)}:")
        for e in sorted(items, key=lambda e: e["file"]):
            detail = f" ({e['detail']})" if e["detail"] and reason in ("banned_texture", "missing_texture", "too_bright",
                                                                      "curated") else ""
            lines.append(f"  - {e['file']}{detail}")
    return "\n".join(lines) if lines else "Nothing."


def app_commit():
    proc = subprocess.run(["git", "-C", sources.REPO_ROOT, "rev-parse", "--short=12", "HEAD"],
                          capture_output=True, text=True)
    dirty = subprocess.run(["git", "-C", sources.REPO_ROOT, "status", "--porcelain", "--", "tools/milkdrop_pack"],
                           capture_output=True, text=True).stdout.strip()
    return (proc.stdout.strip() or "unknown") + ("-dirty" if dirty else "")


# -- the build -------------------------------------------------------------------

def default_version(today=None):
    today = today or datetime.date.today()
    return f"{today.year:04d}.{today.month:02d}.1"


def build(args):
    report = Report()
    curation = sources.load_json("curation.json")
    pins = sources.load_json("pins.json")
    version = args.version or default_version()
    if not manifest.VERSION_RE.match(version):
        raise PipelineError(f"version {version!r} is not path-safe")
    if not YYYYMMN_RE.match(version):
        report.notes.append(f"version {version} is not YYYY.MM.N")
    jobs = args.jobs or max(1, (os.cpu_count() or 2) // 2)
    out = os.path.abspath(args.out)
    work = os.path.abspath(args.work or os.path.join(out, "work"))
    os.makedirs(out, exist_ok=True)
    os.makedirs(work, exist_ok=True)
    log = os.path.join(work, "build.log")

    # Inputs.
    zip_sha = sources.check_zip(args.zip, args.allow_unpinned_zip)
    pm_commit = sources.projectm_pin()
    tex_commit = pins["texture_pack"]["commit"]
    tex_src = args.texture_pack or sources.git_checkout(
        pins["texture_pack"]["repo"], tex_commit, os.path.join(work, "src", "texture-pack"), log)
    pm_src = args.projectm_src or sources.git_checkout(
        pins["projectm"]["repo"], pm_commit, os.path.join(work, "src", "projectm"), log,
        pins["projectm"]["submodules"])
    for label, path, want in (("--texture-pack", args.texture_pack, tex_commit),
                              ("--projectm-src", args.projectm_src, pm_commit)):
        if path:
            head = subprocess.run(["git", "-C", path, "rev-parse", "HEAD"], capture_output=True, text=True)
            if head.stdout.strip() != want:
                report.notes.append(f"{label} {path} is at {head.stdout.strip() or '?'}, not the pin {want}")
            try:
                dirty = sources.dirty_paths(path)
            except PipelineError:
                dirty = ["?"]
            if dirty:
                report.notes.append(f"{label} {path} has local changes (or isn't a git checkout)")
    report.step("inputs", zip_sha256=zip_sha, projectm=pm_commit, texture_pack=tex_commit)

    translator = sources.build_translator(pm_src, os.path.join(work, "build-translator"), log, jobs)
    host = sources.build_host_tools(pm_src, os.path.join(work, "build-host"), log, jobs)
    check_exe = sources.build_manifest_check(os.path.join(work, "build-manifest-check"), log, jobs)

    # Presets and textures.
    staged = assign(read_zip(args.zip, report), report)
    tex_dir = os.path.join(tex_src, "textures")
    available = textures.index(tex_dir)
    stems = texture_policy(staged, available, curation, report)

    pack = os.path.join(work, "pack")
    shutil.rmtree(pack, ignore_errors=True)
    os.makedirs(pack)
    write_presets(staged, pack)
    tex_records = textures.install(stems, available, tex_dir, os.path.join(pack, "textures"),
                                   curation["max_texture_px"], host["scale"])
    scaled = [r for r in tex_records if r["scaled"]]
    report.step("textures_installed", files=len(tex_records), scaled=len(scaled),
                bytes=sum(os.path.getsize(os.path.join(pack, "textures", r["name"])) for r in tex_records))

    # Translation (first pass finds failures).
    rows = translate.pretranslate(translator, pack, os.path.join(work, "pretranslate-1.tsv"))
    failed = translate.failures(rows)
    for pid, why in sorted(failed.items()):
        report.exclude(pid, "translate_failed", why)
    remove_presets(staged, failed, pack)
    report.step("translate", presets=len(staged), failed=len(failed))

    # Brightness screen.
    bright_cfg = curation["brightness"]
    bright = {}
    if not args.skip_brightness:
        settings = {k: bright_cfg[k] for k in ("frames", "from", "size")}
        tool_id = brightness.tool_identity(host, pm_commit, os.path.join(pack, "textures"),
                                           curation["milkdrop_textures"]["names"])

        def progress(done, total, pid, result):
            if done % 50 == 0 or done == total:
                print(f"  brightness {done}/{total}", flush=True)

        bright = brightness.screen(host, pack, sorted(staged), settings, os.path.join(work, "brightness-cache.jsonl"),
                                   jobs, tool_id, progress)
        too_bright, load_failed = apply_screen(staged, bright, bright_cfg, report)
        if not args.no_snapshots:
            shutil.rmtree(os.path.join(out, "review"), ignore_errors=True)
            brightness.snapshots(host, pack, too_bright + [e["file"] for e in report.review], settings,
                                 os.path.join(out, "review"), jobs=jobs)
        remove_presets(staged, too_bright + load_failed, pack)
        report.step("brightness", presets=len(staged), too_bright=len(too_bright), load_failed=len(load_failed),
                    review=len(report.review))
    else:
        report.notes.append("brightness screen skipped (--skip-brightness)")

    curate(staged, curation, report, pack)

    # Final translation over exactly the shipped presets.
    rows = translate.pretranslate(translator, pack, os.path.join(work, "pretranslate.tsv"))
    if translate.failures(rows):
        raise PipelineError(f"translation failures on the final set: {translate.failures(rows)}")
    shader_count = len(os.listdir(os.path.join(pack, "shaders")))
    report.step("shaders", presets=len(staged), files=shader_count)

    # Manifest.
    sweep = sweep_mod.load_sweep(args.device_sweep)
    trial = sweep_mod.load_vc4_trial(args.vc4_trial)
    doc = manifest.build(version, staged.keys(), sweep, trial, args.default_rung)
    problems = manifest.validate(doc)
    if problems:
        raise PipelineError("manifest: " + "; ".join(problems[:10]))
    with open(os.path.join(pack, "manifest.json"), "w") as f:
        f.write(manifest.dumps(doc))
    checked = json.loads(subprocess.run([check_exe, os.path.join(pack, "manifest.json"), pack],
                                        capture_output=True, text=True, check=True).stdout)
    if checked["rejected"] or checked["missing"] or checked["presets"] != len(staged):
        raise PipelineError(f"renderer manifest check: {checked}")
    sources_line = []
    if sweep:
        sources_line.append(f"device sweep ({sum(1 for p in staged if p in sweep)} presets)")
    if trial:
        with_ms = sum(1 for e in doc["presets"] if "frame_ms" in e["rpi3"])
        sources_line.append(f"frame_ms (vc4 warp+comp GPU time) from the shader trial for {with_ms} presets")
    rpi3_source = " + ".join(sources_line) or f"none measured; every preset starts at {args.default_rung}"
    report.step("manifest", presets=checked["presets"], high_frequency=checked["high_frequency"],
                rpi3_skip=checked["rpi3_skip"], swept=sum(1 for p in staged if p in sweep),
                trial=sum(1 for p in staged if p in trial))

    # README / NOTICE.
    contact = args.contact or DEFAULT_CONTACT
    values = {
        "VERSION": version, "PRESETS": len(staged),
        "HIGH_FREQUENCY": checked["high_frequency"],
        "EXTREME": sum(1 for p in staged if p.startswith("high_frequency/extreme/")),
        "TEXTURES": len(tex_records), "SHADERS": shader_count, "APP_COMMIT": app_commit(),
        "ZIP_NAME": os.path.basename(args.zip), "ZIP_SHA": zip_sha,
        "EXCLUDED": len([e for e in report.excluded if e["reason"] != "duplicate"]),
        "TEXTURE_COMMIT": tex_commit, "PROJECTM_COMMIT": pm_commit,
        "MAX_TEXTURE_PX": curation["max_texture_px"],
        "BRIGHT_FRAMES": bright_cfg["frames"], "BRIGHT_FROM": bright_cfg["from"], "BRIGHT_SIZE": bright_cfg["size"],
        "BRIGHT_EXCLUDE_PCT": int(round(bright_cfg["exclude_sat_above"] * 100)),
        "BRIGHT_MIN_LUMA": bright_cfg["exclude_min_luma"],
        "RPI3_SOURCE": rpi3_source,
        "BANNED_TEXTURES": ", ".join(curation["banned_textures"]["names"]),
        "EXCLUSIONS": exclusion_text(report), "CONTACT": contact,
    }
    for name, template in (("README", "README.in"), ("NOTICE", "NOTICE.in")):
        with open(os.path.join(pack, name), "w") as f:
            f.write(fill(template, values))

    # Tarball.
    tar_path = os.path.join(out, f"up-milkdrop-pack-{version}.tar.gz")
    digest = tarball.create(pack, tar_path)
    problems = tarball.check(tar_path)
    if problems:
        raise PipelineError("tarball: " + "; ".join(problems[:10]))
    with open(tar_path + ".sha256", "w") as f:
        f.write(f"{digest}  {os.path.basename(tar_path)}\n")
    report.step("tarball", path=tar_path, bytes=os.path.getsize(tar_path), sha256=digest)

    result = {
        "version": version, "tarball": tar_path, "sha256": digest, "bytes": os.path.getsize(tar_path),
        "pins": {"projectm": pm_commit, "texture_pack": tex_commit, "zip_sha256": zip_sha},
        "steps": report.steps, "excluded": report.excluded, "review": report.review,
        "textures": tex_records, "notes": report.notes,
        "brightness": {pid: bright[pid] for pid in sorted(bright)},
    }
    with open(os.path.join(out, "report.json"), "w") as f:
        json.dump(result, f, indent=1)
    for note in report.notes:
        print("note:", note)
    return result

