"""The brightness screen: whiteout presets (the TV shows a white field) are
excluded, bright-but-maybe-fine ones are listed for a look.

Each preset renders `frames` frames of synthetic music on the host reference
renderer (md_bright: projectM desktop GL on Mesa llvmpipe, pinned RNG/clock).
`sat` is the mean fraction of pixels with any channel >= 250 over frames
`from`..`frames` (the first seconds are a fade-in), `luma` the mean Rec.601
luma. Results are cached per preset content + settings, so a rerun only
renders what changed.
"""

import concurrent.futures
import hashlib
import json
import os
import subprocess

CACHE_VERSION = 1


def classify(result, exclude_above, review_above, exclude_min_luma=0.0):
    """'exclude' | 'review' | 'ok' | 'load_failed' | 'error' for one
    md_bright result. With exclude_min_luma, a saturated but dark picture
    (pure colour rather than white) is only reviewed, not excluded."""
    if result and result.get("error") == "load_failed":
        return "load_failed"
    if not result or "sat" not in result:
        return "error"
    if result["sat"] > exclude_above and result.get("luma", 255.0) >= exclude_min_luma:
        return "exclude"
    if result["sat"] > exclude_above:
        return "review"
    if result["sat"] > review_above:
        return "review"
    return "ok"


def verdict(result, cfg):
    """classify() with the thresholds of curation.json's "brightness"."""
    return classify(result, cfg["exclude_sat_above"], cfg["review_sat_above"], cfg["exclude_min_luma"])


def cache_key(preset_bytes, settings, tool_id):
    h = hashlib.sha256()
    h.update(json.dumps({"v": CACHE_VERSION, "settings": settings, "tool": tool_id}, sort_keys=True).encode())
    h.update(preset_bytes)
    return h.hexdigest()


def load_cache(path):
    cache = {}
    if os.path.exists(path):
        with open(path) as f:
            for line in f:
                try:
                    rec = json.loads(line)
                    cache[rec["key"]] = rec["result"]
                except (ValueError, KeyError):
                    continue
    return cache


def env_for(tools):
    env = dict(os.environ)
    env.update({
        "LD_PRELOAD": tools["seed"],
        "EGL_PLATFORM": "surfaceless",
        "LIBGL_ALWAYS_SOFTWARE": "1",
        "LP_NUM_THREADS": "2",
    })
    return env


def render(tools, preset_path, texture_dir, settings, extra=(), timeout=900):
    cmd = [tools["bright"], "--preset", preset_path, "--texture-path", texture_dir,
           "--size", settings["size"], "--frames", str(settings["frames"]), "--from", str(settings["from"]),
           *extra]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, env=env_for(tools), timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"error": "timeout"}
    for line in reversed(proc.stdout.splitlines()):
        if line.startswith("{"):
            try:
                result = json.loads(line)
                break
            except ValueError:
                continue
    else:
        result = {"error": f"exit {proc.returncode}", "stderr": proc.stderr[-300:]}
    return result


def screen(tools, pack_dir, ids, settings, cache_path, jobs, tool_id, progress=None):
    """{id: result} for every id (presets under <pack_dir>/presets), using
    and extending the cache at cache_path."""
    cache = load_cache(cache_path)
    texture_dir = os.path.join(pack_dir, "textures")
    todo, results = [], {}
    for pid in ids:
        path = os.path.join(pack_dir, "presets", pid)
        with open(path, "rb") as f:
            key = cache_key(f.read(), settings, tool_id)
        if key in cache:
            results[pid] = cache[key]
        else:
            todo.append((pid, path, key))
    done = 0
    with open(cache_path, "a") as cache_file, \
            concurrent.futures.ThreadPoolExecutor(max_workers=max(1, jobs)) as pool:
        futures = {pool.submit(render, tools, path, texture_dir, settings): (pid, key)
                   for pid, path, key in todo}
        for fut in concurrent.futures.as_completed(futures):
            pid, key = futures[fut]
            result = fut.result()
            results[pid] = result
            if "sat" in result or result.get("error") == "load_failed":
                cache_file.write(json.dumps({"key": key, "id": pid, "result": result}) + "\n")
                cache_file.flush()
            done += 1
            if progress:
                progress(done, len(todo), pid, result)
    return results


def snapshots(tools, pack_dir, ids, settings, out_dir, frames=(300, 600), jobs=4):
    """PNG frames of the given presets, for review by eye."""
    os.makedirs(out_dir, exist_ok=True)
    texture_dir = os.path.join(pack_dir, "textures")
    extra_for = {}
    for pid in ids:
        prefix = os.path.join(out_dir, "".join(c if c.isalnum() else "_" for c in pid[:-5])[:120])
        extra = ["--png-prefix", prefix]
        for f in frames:
            extra += ["--png-at", str(f)]
        extra_for[pid] = extra
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, jobs)) as pool:
        list(pool.map(lambda pid: render(tools, os.path.join(pack_dir, "presets", pid), texture_dir,
                                         settings, extra_for[pid]), ids))
