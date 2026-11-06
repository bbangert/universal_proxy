"""The release tarball: reproducible (sorted entries, fixed mtime/owner/mode,
gzip without a timestamp) and limited to what UniversalProxy.MilkDrop.Pack
extracts (regular files and directories, relative paths without "..",
manifest.json at the root)."""

import gzip
import hashlib
import os
import tarfile

MTIME = 0
TOP_LEVEL = ("manifest.json", "README", "NOTICE", "presets", "textures", "shaders")


def _members(pack_dir):
    """(archive name, path) for the pack's top-level entries and everything
    under them, sorted. Refuses symlinks and other non-regular files."""
    out = []
    for top in TOP_LEVEL:
        path = os.path.join(pack_dir, top)
        if os.path.islink(path):
            raise ValueError(f"{path} is a symlink")
        if os.path.isfile(path):
            out.append((top, path))
        elif os.path.isdir(path):
            out.append((top, path))
            for root, dirs, files in os.walk(path):
                for name in dirs + files:
                    full = os.path.join(root, name)
                    if os.path.islink(full) or not (os.path.isfile(full) or os.path.isdir(full)):
                        raise ValueError(f"{full} is not a regular file or directory")
                    out.append((os.path.relpath(full, pack_dir).replace(os.sep, "/"), full))
        elif top == "manifest.json":
            raise ValueError(f"{pack_dir} has no manifest.json")
    return sorted(out)


def create(pack_dir, out_path):
    """Write the tarball; returns its SHA-256 (hex)."""
    tmp = out_path + ".tmp"
    with open(tmp, "wb") as raw, \
            gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=MTIME, compresslevel=9) as gz, \
            tarfile.open(fileobj=gz, mode="w", format=tarfile.PAX_FORMAT) as tar:
        for name, path in _members(pack_dir):
            info = tar.gettarinfo(path, arcname=name)
            info.mtime = MTIME
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            info.mode = 0o755 if info.isdir() else 0o644
            if info.isdir():
                tar.addfile(info)
            else:
                with open(path, "rb") as f:
                    tar.addfile(info, f)
    os.replace(tmp, out_path)
    return sha256(out_path)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def safe_name(name):
    parts = name.split("/")
    return bool(name) and not name.startswith("/") and ".." not in parts


def check(path):
    """Problems (strings) MilkDrop.Pack would refuse the tarball for."""
    problems = []
    has_manifest = False
    with tarfile.open(path, "r:gz") as tar:
        for m in tar.getmembers():
            name = m.name
            if not (m.isfile() or m.isdir()):
                problems.append(f"{name}: not a regular file or directory")
            if not safe_name(name):
                problems.append(f"{name}: unsafe path")
            if name == "manifest.json" and m.isfile():
                has_manifest = True
    if not has_manifest:
        problems.append("no manifest.json at the root")
    return problems


def listing(path):
    with tarfile.open(path, "r:gz") as tar:
        return [m.name for m in tar.getmembers()]


def read_member(path, name):
    with tarfile.open(path, "r:gz") as tar:
        return tar.extractfile(name).read()

