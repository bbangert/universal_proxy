"""Pinned inputs: the Geiss zip (local), the texture pack and the projectM
fork (git, by commit), and the host builds made from the fork."""

import hashlib
import json
import os
import re
import subprocess

TOOL_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_ROOT = os.path.dirname(os.path.dirname(TOOL_DIR))


class PipelineError(Exception):
    pass


def load_json(name):
    with open(os.path.join(TOOL_DIR, name)) as f:
        return json.load(f)


def projectm_pin(cmake_path=None):
    """The fork SHA the renderer pins (PROJECTM_REF in its CMakeLists.txt),
    so the translator and the renderer can't drift apart."""
    pins = load_json("pins.json")
    path = cmake_path or os.path.join(REPO_ROOT, pins["projectm"]["pin_file"])
    with open(path) as f:
        text = f.read()
    m = re.search(r'set\(\s*PROJECTM_REF\s+"([0-9a-f]{40})"', text)
    if not m:
        raise PipelineError(f"no PROJECTM_REF SHA in {path}")
    return m.group(1)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def check_zip(path, allow_unpinned=False):
    expected = load_json("pins.json")["geiss_zip"]["sha256"]
    actual = sha256_file(path)
    if actual != expected and not allow_unpinned:
        raise PipelineError(
            f"{path}: sha256 {actual} is not the pinned {expected} (--allow-unpinned-zip to override)")
    return actual


def run(cmd, log=None, cwd=None, env=None):
    """Run a command; on failure raise with the tail of its output."""
    with open(log, "ab") if log else open(os.devnull, "wb") as out:
        out.write(("$ " + " ".join(cmd) + "\n").encode())
        out.flush()
        proc = subprocess.run(cmd, stdout=out, stderr=subprocess.STDOUT, cwd=cwd, env=env)
    if proc.returncode != 0:
        tail = ""
        if log:
            with open(log, "rb") as f:
                tail = f.read()[-3000:].decode("utf-8", "replace")
        raise PipelineError(f"{' '.join(cmd[:3])}... failed ({proc.returncode})\n{tail}")


def git_checkout(repo, commit, dest, log, submodules=()):
    """A checkout of `commit` at `dest`, fetched by SHA (content-addressed,
    so a moved branch or tag can't change the input). Reused when already
    there."""
    if os.path.isdir(os.path.join(dest, ".git")):
        head = subprocess.run(["git", "-C", dest, "rev-parse", "HEAD"], capture_output=True, text=True)
        if head.returncode == 0 and head.stdout.strip() == commit:
            return dest
    os.makedirs(dest, exist_ok=True)
    run(["git", "-C", dest, "init", "-q"], log)
    run(["git", "-C", dest, "fetch", "-q", "--depth", "1", repo, commit], log)
    run(["git", "-C", dest, "checkout", "-q", "--force", "FETCH_HEAD"], log)
    head = subprocess.run(["git", "-C", dest, "rev-parse", "HEAD"], capture_output=True, text=True)
    if head.stdout.strip() != commit:
        raise PipelineError(f"{repo}: checked out {head.stdout.strip()}, wanted {commit}")
    for sub in submodules:
        run(["git", "-C", dest, "submodule", "update", "--init", "--depth", "1", sub], log)
    return dest


def build_translator(src, build_dir, log, jobs):
    """projectM-pretranslate-presets from the fork, GLES 2.0 (GLSL ES 1.00)."""
    run(["cmake", "-S", src, "-B", build_dir, "-G", "Ninja", "-DCMAKE_BUILD_TYPE=Release",
         "-DENABLE_GLES=ON", "-DENABLE_GLES2=ON", "-DBUILD_TRANSLATOR_HARNESS=ON",
         "-DENABLE_SYSTEM_PROJECTM_EVAL=OFF", "-DENABLE_PLAYLIST=OFF", "-DBUILD_TESTING=OFF",
         "-DBUILD_SHARED_LIBS=OFF"], log)
    run(["cmake", "--build", build_dir, "--target", "projectM-pretranslate-presets", "-j", str(jobs)], log)
    exe = os.path.join(build_dir, "tests", "translator", "projectM-pretranslate-presets")
    if not os.access(exe, os.X_OK):
        raise PipelineError(f"no translator at {exe}")
    return exe


def build_host_tools(src, build_dir, log, jobs):
    """md_bright / md_seed / md_scale (host/CMakeLists.txt) against the fork."""
    run(["cmake", "-S", os.path.join(TOOL_DIR, "host"), "-B", build_dir, "-G", "Ninja",
         "-DCMAKE_BUILD_TYPE=Release", f"-DPROJECTM_SOURCE_DIR={src}"], log)
    run(["cmake", "--build", build_dir, "-j", str(jobs)], log)
    tools = {
        "bright": os.path.join(build_dir, "md_bright"),
        "seed": os.path.join(build_dir, "libmd_seed.so"),
        "scale": os.path.join(build_dir, "md_scale"),
    }
    for path in tools.values():
        if not os.path.exists(path):
            raise PipelineError(f"missing host tool {path}")
    return tools


def build_manifest_check(build_dir, log, jobs):
    """The renderer's own manifest parser as a CLI (milkdrop_manifest_check,
    a core-only target of c_src/milkdrop_renderer)."""
    src = os.path.join(REPO_ROOT, "c_src", "milkdrop_renderer")
    run(["cmake", "-S", src, "-B", build_dir, "-G", "Ninja", "-DMILKDROP_CORE_ONLY=ON"], log)
    run(["cmake", "--build", build_dir, "--target", "milkdrop_manifest_check", "-j", str(jobs)], log)
    return os.path.join(build_dir, "milkdrop_manifest_check")
