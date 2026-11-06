# MilkDrop preset pack pipeline

Builds `up-milkdrop-pack-<YYYY.MM.N>.tar.gz`, the preset pack the "MilkDrop"
TV display mode downloads (`UniversalProxy.MilkDrop.Pack`) and renders
(`c_src/milkdrop_renderer`, whose README defines the pack layout and the
manifest format). Host-only: nothing here is part of the firmware.

Publishing the tarball (a release in `bbangert/up-milkdrop-pack`, plus the
URL/SHA-256 pin in the app's config) is a separate, manual step.

## Inputs (pinned)

| Input | Pin | How it's obtained |
|---|---|---|
| Geiss `favorite_presets_2021_01_03.zip` | SHA-256 in `pins.json` | **by hand**: geisswerks.com refuses scripted downloads; pass `--zip` |
| projectM `presets-milkdrop-texture-pack` | commit in `pins.json` | `git fetch` by SHA |
| projectM fork `bbangert/projectm` | `PROJECTM_REF` in `c_src/milkdrop_renderer/CMakeLists.txt` (read from there, so the pack's shader cache keys match the renderer) | `git fetch` by SHA (+ `vendor/projectm-eval`) |

`curation.json` holds the policy: banned textures, MilkDrop's own texture
set (the `sampler_randNN` pool), the texture size limit, the brightness
thresholds and hand exclusions with reasons.

## Running

Needs Python 3.9+ (standard library only), git, cmake, ninja, a C++17
compiler and Mesa with EGL (llvmpipe; no GPU needed).

```sh
tools/milkdrop_pack/build_pack.py --zip ~/favorite_presets_2021_01_03.zip \
    --out /tmp/milkdrop-pack --version 2026.11.1 \
    [--device-sweep sweep.jsonl] [--vc4-trial shader-trial-vc4.csv]
```

Output in `--out`: the tarball, `<tarball>.sha256`, `report.json` (counts per
step, every exclusion with its reason, the brightness review list, texture
records, per-preset brightness) and `review/` (PNG frames of the excluded and
review-listed presets). `--work` (default `OUT/work`) keeps the checkouts,
builds and the brightness cache, so a rerun only renders changed presets.

## Steps

1. Read the zip: keep the `.milk` files, drop the 150×150 JPG thumbnails.
2. Normalise names to preset ids (ASCII, single spaces, trimmed segments,
   lowercase `.milk`; valid per the renderer's rules). Byte-identical
   duplicates are dropped; a clash with different content gets ` (2)`.
3. Tag `high_frequency/` presets `high_frequency` (off by default on the
   device) and `high_frequency/extreme/` ones also `extreme`.
4. Textures: find what each preset's shaders actually sample (comments
   stripped, `#define` aliases expanded, declarations ignored, as MilkDrop
   bound them). Presets that sample a banned texture (`portal1`, `Suff5`,
   `rose`, `skull`, `worms`) or one that isn't available are excluded. Ship
   the sampled textures plus MilkDrop's 21 originals (the random pool),
   lowercased; downscale anything over 2048 px (`pano_earth`, for vc4).
5. Pre-translate every warp/comp stage to GLSL ES 1.00 into
   `shaders/<key>.glsl` with the fork's `projectM-pretranslate-presets`
   (`-DENABLE_GLES2=ON -DBUILD_TRANSLATOR_HARNESS=ON`), textures in place.
   Presets with a failing stage are excluded.
6. Brightness screen: render each preset 600 frames at 640×360 with
   deterministic music-like PCM on the host reference (`host/md_bright`:
   projectM desktop GL on llvmpipe, RNG and clock pinned by `md_seed`).
   `sat` = mean fraction of pixels with a channel ≥ 250 over frames
   150–600, `luma` its mean Rec.601 luma. Only a true whiteout, `sat > 0.9`
   with `luma ≥ 200` (`exclude_min_luma`), is excluded; saturated but
   darker colour and anything with `sat > 0.5` go on the review list (look
   at `review/`, add to `curation.json` if needed).
   Presets projectM can't load at all (expression syntax errors) are
   excluded too. A render that fails (timeout, crash, GL or EGL error)
   fails the build; a rerun renders only those again, since successes are
   cached (`--skip-brightness` skips the screen, for dev builds only).
7. Hand exclusions from `curation.json` (after the screen, so the report
   shows whether the screen caught them), then a final translation pass
   over exactly the shipped presets.
8. `manifest.json` (see "rpi3 fields"), checked by `manifest.validate` and
   by the renderer's own parser (`milkdrop_manifest_check`, built from
   `c_src/milkdrop_renderer`): no entry may be dropped or missing.
9. `README` and `NOTICE` from `templates/` (origin, "presumed public
   domain, removed on request", texture provenance, banned textures, the
   pins, every exclusion, how to request a removal: by default "open an issue at
   https://github.com/bbangert/up-milkdrop-pack/issues", `--contact` to change it).
10. A reproducible tarball (sorted, mtime 0, root-owned, gzip without a
    timestamp): `manifest.json` at the root, only regular files and
    directories with safe relative paths (what `MilkDrop.Pack` accepts),
    plus its SHA-256.

### rpi3 fields

- `rpi3.rung` (or `"skip"` + `reason`), `compile_ms` (warm-up) and
  `eval_ms` (CPU frame time, an upper bound on expression eval) come from a
  device sweep file (`--device-sweep`).
- `rpi3.frame_ms` is the vc4 **warp+comp GPU** time from the shader trial
  CSV (`--vc4-trial`), never the sweep's whole-frame headless time: the
  renderer cuts instead of blending above 25 ms, and whole-frame times
  would hard-cut most presets where a 0.5 s blend looks fine.
- Without either, every preset gets `{"rung": "640x360"}` and the
  renderer's runtime cost guard decides.

## Device sweep (separate, hours)

`device_sweep.py` measures a built pack on an rpi3 running firmware with
`milkdrop_renderer`:

```sh
tools/milkdrop_pack/device_sweep.py --host <rpi3 address> --known-hosts ~/.ssh/md-sweep-known_hosts \
    --tarball /tmp/milkdrop-pack/up-milkdrop-pack-2026.11.1.tar.gz --out sweep.jsonl
tools/milkdrop_pack/build_pack.py ... --device-sweep sweep.jsonl   # rebuild with the results
```

The device's SSH host key is verified: against your `known_hosts` by
default, or against `--known-hosts FILE`. Enrol a device's key once, into
a dedicated file, from a network you trust (nerves_ssh keeps it in
`/data/nerves_ssh`, so it survives firmware updates but not a reflash that
wipes `/data`):

```sh
ssh-keyscan <rpi3 address> > ~/.ssh/md-sweep-known_hosts
ssh-keygen -lf ~/.ssh/md-sweep-known_hosts   # note the fingerprint
```

A sweep's results become the manifest's rpi3 hints, so an impersonated
device could ship fabricated measurements. **`--insecure-no-host-key-check`
skips verification**: use it only for the throwaway dev Pi, whose host key
changes on every reflash, and only on a network you trust:

```sh
tools/milkdrop_pack/device_sweep.py --host 192.168.2.148 --insecure-no-host-key-check \
    --tarball /tmp/milkdrop-pack/up-milkdrop-pack-2026.11.1.tar.gz --out sweep.jsonl
```

It copies the pack to `/data/md-sweep/` (sftp + `:erl_tar` on the device)
and strips that copy's manifest of its rpi3 hints (`rung`, `skip`,
`frame_ms`, `compile_ms`, `eval_ms`), so a pack rebuilt from an earlier
sweep is measured afresh: the renderer refuses `--locked` on an rpi3
`"skip"` entry. Then per preset it runs the device's renderer
(`<priv>/milkdrop_renderer/rpi3/milkdrop_renderer`) headless on
`/dev/dri/renderD128`: `--headless-frames 600 --locked <id> --test-tone
--high-frequency`. No KMS, no DRM master: Emerge and the TV are not
touched. It waits for the SoC to cool below 70 °C between presets and
appends one JSON line per preset to `--out` (fps, flip and CPU frame ms,
the rung the cost guard settled on, skip reason, warm-up ms, temperature).
Resumable: presets with an `ok` or `skip` record for this tarball's
SHA-256 are not rerun; `error` records (a timeout, a truncated reply) are
retried. `--dry-run` prints the plan and the Elixir it would send;
`--only ID` / `--limit N` sweep a subset. The device runs Elixir over
nerves_ssh; the script never sends `System.halt`.

## Tests

`mise run test -- test/milkdrop_pack_tools_test.exs` runs the Python unit
tests (`python3 -m unittest discover -s tests -t .` from this directory)
and installs a pipeline-built tarball through `MilkDrop.Pack` and the
renderer's manifest parser.
