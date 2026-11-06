import io
import os
import tarfile
import unittest

from milkpack import tarball

from .helpers import tiny_pack, tmpdir, write


def raw_tar(path, members):
    """A .tar.gz with hand-made members: (name, type, data)."""
    with tarfile.open(path, "w:gz") as tar:
        for name, kind, data in members:
            info = tarfile.TarInfo(name)
            info.type = kind
            if kind == tarfile.SYMTYPE:
                info.linkname = data
                tar.addfile(info)
            elif kind == tarfile.DIRTYPE:
                tar.addfile(info)
            else:
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
    return path


class CreateTest(unittest.TestCase):
    def test_reproducible_with_manifest_at_the_root(self):
        d = tmpdir(self)
        pack = tiny_pack(os.path.join(d, "pack"))
        a = tarball.create(pack, os.path.join(d, "a.tar.gz"))
        os.utime(os.path.join(pack, "README"), (1, 1))
        b = tarball.create(pack, os.path.join(d, "b.tar.gz"))
        self.assertEqual(a, b)
        self.assertEqual(a, tarball.sha256(os.path.join(d, "a.tar.gz")))
        self.assertEqual(tarball.check(os.path.join(d, "a.tar.gz")), [])
        names = tarball.listing(os.path.join(d, "a.tar.gz"))
        self.assertIn("manifest.json", names)
        self.assertIn("presets/high_frequency/b.milk", names)
        self.assertIn("shaders/" + "0" * 64 + ".glsl", names)
        with tarfile.open(os.path.join(d, "a.tar.gz")) as tar:
            for m in tar.getmembers():
                self.assertEqual((m.uid, m.gid, m.mtime), (0, 0, 0))
                self.assertEqual(m.mode, 0o755 if m.isdir() else 0o644)

    def test_long_names_survive(self):
        d = tmpdir(self)
        long_id = "high_frequency/extreme/" + "x" * 180 + ".milk"
        pack = tiny_pack(os.path.join(d, "pack"), presets=(long_id,))
        path = os.path.join(d, "p.tar.gz")
        tarball.create(pack, path)
        self.assertIn("presets/" + long_id, tarball.listing(path))
        self.assertEqual(tarball.check(path), [])

    def test_refuses_symlinks_and_a_missing_manifest(self):
        d = tmpdir(self)
        pack = tiny_pack(os.path.join(d, "pack"))
        os.symlink("/etc/passwd", os.path.join(pack, "presets", "evil.milk"))
        with self.assertRaises(ValueError):
            tarball.create(pack, os.path.join(d, "x.tar.gz"))
        os.remove(os.path.join(pack, "presets", "evil.milk"))
        os.remove(os.path.join(pack, "manifest.json"))
        with self.assertRaises(ValueError):
            tarball.create(pack, os.path.join(d, "x.tar.gz"))

    def test_only_the_pack_layout_is_archived(self):
        d = tmpdir(self)
        pack = tiny_pack(os.path.join(d, "pack"))
        write(os.path.join(pack, "stray.log"), "x")
        path = os.path.join(d, "p.tar.gz")
        tarball.create(pack, path)
        self.assertNotIn("stray.log", tarball.listing(path))


class CheckTest(unittest.TestCase):
    def test_flags_what_milkdrop_pack_refuses(self):
        d = tmpdir(self)
        bad = raw_tar(os.path.join(d, "bad.tar.gz"), [
            ("manifest.json", tarfile.REGTYPE, b"{}"),
            ("../escape.milk", tarfile.REGTYPE, b"x"),
            ("/abs.milk", tarfile.REGTYPE, b"x"),
            ("presets/link.milk", tarfile.SYMTYPE, "/etc/passwd"),
            ("presets/dev", tarfile.CHRTYPE, b""),
        ])
        problems = tarball.check(bad)
        for needle in ("../escape.milk", "/abs.milk", "presets/link.milk", "presets/dev"):
            self.assertTrue(any(needle in p for p in problems), (needle, problems))

    def test_manifest_must_be_at_the_root(self):
        d = tmpdir(self)
        nested = raw_tar(os.path.join(d, "n.tar.gz"), [("pack/manifest.json", tarfile.REGTYPE, b"{}")])
        self.assertEqual(tarball.check(nested), ["no manifest.json at the root"])


if __name__ == "__main__":
    unittest.main()
