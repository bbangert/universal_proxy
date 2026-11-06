"""The pack's textures/: what presets sample plus MilkDrop's own set (the
`sampler_randNN` pool), never a banned name, nothing over vc4's 2048 px."""

import os
import shutil
import struct
import subprocess

IMAGE_EXTS = (".jpg", ".jpeg", ".png", ".tga", ".bmp", ".dib")


def index(directory):
    """{lowercase stem: file name} for the images in `directory` (projectM
    matches textures on the lowercased stem). On a stem clash the
    MilkDrop extension order wins (jpg before png ...)."""
    found = {}
    for name in sorted(os.listdir(directory)):
        stem, ext = os.path.splitext(name)
        ext = ext.lower()
        if ext not in IMAGE_EXTS or not os.path.isfile(os.path.join(directory, name)):
            continue
        key = stem.lower()
        if key not in found or IMAGE_EXTS.index(ext) < IMAGE_EXTS.index(os.path.splitext(found[key])[1].lower()):
            found[key] = name
    return found


def image_size(path):
    """(width, height) of a JPEG or PNG, read from its header."""
    with open(path, "rb") as f:
        data = f.read(1 << 16)
        if data[:8] == b"\x89PNG\r\n\x1a\n":
            return struct.unpack(">II", data[16:24])
        if data[:2] != b"\xff\xd8":
            raise ValueError(f"{path}: not a JPEG or PNG")
        f.seek(2)
        while True:
            marker = f.read(2)
            if len(marker) < 2 or marker[0] != 0xFF:
                raise ValueError(f"{path}: no JPEG frame header")
            while marker[1] == 0xFF:
                marker = marker[:1] + f.read(1)
            code = marker[1]
            if code in (0xD8, 0x01) or 0xD0 <= code <= 0xD7:
                continue
            (length,) = struct.unpack(">H", f.read(2))
            if 0xC0 <= code <= 0xCF and code not in (0xC4, 0xC8, 0xCC):
                h, w = struct.unpack(">xHH", f.read(5))
                return w, h
            f.seek(length - 2, os.SEEK_CUR)


def select(sampled, milkdrop, available, banned):
    """Texture stems to ship: every sampled name we have, plus the MilkDrop
    set, minus banned names. Returns (stems, missing): `missing` are sampled
    names that are neither available nor banned."""
    banned = set(banned)
    wanted = (set(sampled) | set(milkdrop)) - banned
    stems = sorted(n for n in wanted if n in available)
    missing = sorted(n for n in set(sampled) - banned if n not in available)
    return stems, missing


def install(stems, available, src_dir, dst_dir, max_px, scale_exe):
    """Copy the textures to dst_dir as lowercase names; downscale (md_scale)
    any with a side over max_px. Returns one record per texture."""
    os.makedirs(dst_dir, exist_ok=True)
    records = []
    for stem in stems:
        name = available[stem]
        src = os.path.join(src_dir, name)
        dst = os.path.join(dst_dir, name.lower())
        w, h = image_size(src)
        rec = {"name": name.lower(), "source": name, "size": [w, h], "scaled": None}
        if max(w, h) > max_px:
            subprocess.run([scale_exe, src, dst, str(max_px), "92"], check=True, capture_output=True)
            rec["scaled"] = list(image_size(dst))
        else:
            shutil.copyfile(src, dst)
        records.append(rec)
    return records
