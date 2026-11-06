import os
import struct
import tempfile
import unittest
import zlib

from milkpack import textures


def png(w, h):
    raw = b"".join(b"\x00" + b"\x00" * (w * 3) for _ in range(h))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def jpeg_header(w, h):
    """SOI, an APP0 segment and a baseline SOF0: enough for image_size."""
    app0 = b"\xff\xe0" + struct.pack(">H", 16) + b"JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
    sof0 = b"\xff\xc0" + struct.pack(">HBHHB", 11, 8, h, w, 1) + b"\x01\x11\x00"
    return b"\xff\xd8" + app0 + sof0 + b"\xff\xd9"


class TexturesTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()

    def write(self, name, data):
        with open(os.path.join(self.dir, name), "wb") as f:
            f.write(data)
        return os.path.join(self.dir, name)

    def test_index_lowercases_stems_and_prefers_jpg(self):
        self.write("VITRIOL.jpg", b"")
        self.write("grad.png", b"")
        self.write("grad.jpg", b"")
        self.write("notes.txt", b"")
        self.assertEqual(textures.index(self.dir), {"vitriol": "VITRIOL.jpg", "grad": "grad.jpg"})

    def test_image_size(self):
        self.assertEqual(textures.image_size(self.write("a.png", png(5, 3))), (5, 3))
        self.assertEqual(textures.image_size(self.write("b.jpg", jpeg_header(2500, 1250))), (2500, 1250))
        with self.assertRaises(ValueError):
            textures.image_size(self.write("c.jpg", b"nope"))

    def test_select_ships_sampled_and_milkdrop_minus_banned(self):
        available = {n: n + ".jpg" for n in ("seaweed", "cells", "worms", "heart", "pano_earth")}
        stems, missing = textures.select({"seaweed", "worms", "portal1", "grad3"}, {"cells", "heart", "worms"},
                                         available, {"worms", "portal1"})
        self.assertEqual(stems, ["cells", "heart", "seaweed"])
        self.assertEqual(missing, ["grad3"])

    def test_install_copies_small_and_scales_large(self):
        src = os.path.join(self.dir, "src")
        os.makedirs(src)
        with open(os.path.join(src, "Big.jpg"), "wb") as f:
            f.write(jpeg_header(4000, 1000))
        with open(os.path.join(src, "small.jpg"), "wb") as f:
            f.write(jpeg_header(256, 256))
        fake = self.write("fake_scale.py", (
            "#!/usr/bin/env python3\nimport struct, sys\nw = int(sys.argv[3])\n"
            "sof = b'\\xff\\xc0' + struct.pack('>HBHHB', 11, 8, w // 4, w, 1) + b'\\x01\\x11\\x00'\n"
            "open(sys.argv[2], 'wb').write(b'\\xff\\xd8' + sof + b'\\xff\\xd9')\n").encode())
        os.chmod(fake, 0o755)
        out = os.path.join(self.dir, "out")
        recs = textures.install(["big", "small"], {"big": "Big.jpg", "small": "small.jpg"}, src, out, 2048, fake)
        self.assertEqual(sorted(os.listdir(out)), ["big.jpg", "small.jpg"])
        self.assertEqual(recs[0], {"name": "big.jpg", "source": "Big.jpg", "size": [4000, 1000], "scaled": [2048, 512]})
        self.assertIsNone(recs[1]["scaled"])


if __name__ == "__main__":
    unittest.main()
