"""Preset ids: normalised pack-relative paths, valid for the renderer.

The renderer (c_src/milkdrop_renderer/src/manifest.cpp, valid_preset_file)
accepts an id that is relative, has no ".", ".." or empty segment, no
control character, ends in ".milk" and is at most 1024 bytes. We also keep
ids printable ASCII with single spaces and no leading/trailing space in any
segment (or before the extension), so they survive the protocol's text
sanitising, shells and the web UI unchanged.
"""

import re
import unicodedata

MAX_ID_BYTES = 1024
EXT = ".milk"


def normalise_segment(segment):
    """ASCII (NFKD, unencodable characters dropped), whitespace runs to one
    space, trimmed."""
    text = unicodedata.normalize("NFKD", segment).encode("ascii", "ignore").decode("ascii")
    text = "".join(" " if (ord(c) < 0x20 or ord(c) == 0x7F) else c for c in text)
    return re.sub(r"\s+", " ", text).strip()


def normalise_id(path):
    """The preset id for a pack-relative path ("a/b.milk"), or None when
    nothing valid is left. The extension is lowercased and the stem trimmed
    ("x .MILK" -> "x.milk")."""
    segments = [normalise_segment(s) for s in path.replace("\\", "/").split("/")]
    if not segments or not segments[-1].lower().endswith(EXT):
        return None
    stem = segments[-1][: -len(EXT)].rstrip()
    segments[-1] = stem + EXT
    candidate = "/".join(segments)
    return candidate if valid_id(candidate) and stem else None


def valid_id(file):
    """Mirror of the renderer's valid_preset_file plus the ASCII rule."""
    if not isinstance(file, str) or not file or file.startswith("/"):
        return False
    if len(file.encode("utf-8")) > MAX_ID_BYTES:
        return False
    if len(file) < len(EXT) + 1 or not file.endswith(EXT):
        return False
    if any(ord(c) < 0x20 or ord(c) > 0x7E for c in file):
        return False
    return all(seg not in ("", ".", "..") for seg in file.split("/"))


def assign_ids(entries):
    """Map source paths to unique ids.

    `entries` is a list of (source_path, content_bytes). Returns
    (assigned, dropped): assigned is a list of (source_path, id); dropped a
    list of (source_path, reason, detail). Two sources normalising to the
    same id keep the first (sorted by source path); an identical copy is
    dropped as a duplicate, a different one gets " (2)", " (3)", ...
    """
    assigned = []
    dropped = []
    by_id = {}
    for source, content in sorted(entries, key=lambda e: e[0]):
        pid = normalise_id(source)
        if pid is None:
            dropped.append((source, "invalid_name", ""))
            continue
        if pid in by_id:
            if by_id[pid] == content:
                dropped.append((source, "duplicate", pid))
                continue
            base = pid[: -len(EXT)]
            n = 2
            while f"{base} ({n}){EXT}" in by_id:
                n += 1
            pid = f"{base} ({n}){EXT}"
        by_id[pid] = content
        assigned.append((source, pid))
    return assigned, dropped


def tags_for(pid):
    """Tags derived from the pack layout: high_frequency/ (default-off,
    photosensitivity) and its extreme/ subfolder."""
    tags = []
    if pid.startswith("high_frequency/"):
        tags.append("high_frequency")
        if pid.startswith("high_frequency/extreme/"):
            tags.append("extreme")
    return tags
