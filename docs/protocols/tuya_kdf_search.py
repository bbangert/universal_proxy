#!/usr/bin/env python3
"""Offline search for how a Tuya Beacon v2 bulb derives its localKey.

Background (see tuya_beacon_mesh.md, section 4.5): when a v2 bulb is paired,
the app sends the bulb's advertised ``srand`` and ``srandEncrypted`` to the
cloud and receives a 16-character ``localKey``. The bulb must already know that
key, because the pairing frame is encrypted with it. So either:

* A. the localKey is a fixed per-device secret (the factory ``authkey``), or
* B. the bulb and the cloud both compute ``localKey = KDF(authkey, srand)``.

B is confirmed on hardware (Gardenreet RGBCW G4 bulbs, product id
``vd8o60wy``): the localKey rotates every time a bulb is reset and re-paired
with a new ``srand``. The KDF itself is still unknown; this tool searches for
it by testing a set of plausible constructions against samples from **your own
bulb**. It needs:

* the bulb's ``authkey`` (16 or 32 ASCII characters, read from its flash), and
* several samples, each a ``srand`` (4 bytes, hex) with the ``localKey`` the
  cloud returned for it, optionally with the advert's ``srandEncrypted``.

A construction counts as a match only if it reproduces **every** sample. One
sample can match by coincidence for a short output, so give at least three.

The candidates use only the primitives Tuya's beacon firmware exposes (MD5,
AES, XXTEA) plus SHA-256 and HMAC, combined with the truncations Tuya's code
habitually uses (hex[0:16], hex[8:24], and so on). A miss means the KDF is
outside this set, not that it doesn't exist.

Nothing here touches the network or a device.

Usage:
  tuya_kdf_search.py --authkey <key> --sample <srand>:<localKey>[:<srandEncrypted>] ...
  tuya_kdf_search.py --self-test

AES needs the ``cryptography`` package; without it the AES candidates are
skipped and the rest still run.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import itertools
import string
import struct
import sys

# ---------------------------------------------------------------- primitives
DELTA = 0x9E3779B9


def _words(b: bytes):
    b = b + b"\x00" * (-len(b) % 4)
    return list(struct.unpack(">%dI" % (len(b) // 4), b))


def _mx(z, y, s, p, e, k):
    return ((((z >> 5) ^ (y << 2)) + ((y >> 3) ^ (z << 4))) ^ ((s ^ y) + (k[(p & 3) ^ e] ^ z))) & 0xFFFFFFFF


def xxtea_enc(data: bytes, key: bytes) -> bytes:
    """Tuya's XXTEA: big-endian word packing, no length word (bluetooth.bpqpqqd)."""
    v, k = _words(data), _words(key[:16].ljust(16, b"\x00"))
    n = len(v)
    s, z = 0, v[-1]
    for _ in range(6 + 52 // n):
        s = (s + DELTA) & 0xFFFFFFFF
        e = (s >> 2) & 3
        for p in range(n):
            y = v[(p + 1) % n]
            v[p] = (v[p] + _mx(z, y, s, p, e, k)) & 0xFFFFFFFF
            z = v[p]
    return struct.pack(">%dI" % n, *v)


def xxtea_dec(data: bytes, key: bytes) -> bytes:
    v, k = _words(data), _words(key[:16].ljust(16, b"\x00"))
    n = len(v)
    rounds = 6 + 52 // n
    s, y = (rounds * DELTA) & 0xFFFFFFFF, v[0]
    for _ in range(rounds):
        e = (s >> 2) & 3
        for p in range(n - 1, -1, -1):
            z = v[(p - 1) % n]
            v[p] = (v[p] - _mx(z, y, s, p, e, k)) & 0xFFFFFFFF
            y = v[p]
        s = (s - DELTA) & 0xFFFFFFFF
    return struct.pack(">%dI" % n, *v)


try:
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

    def aes_ecb(key: bytes, block: bytes, decrypt: bool = False) -> bytes:
        c = Cipher(algorithms.AES(key[:16].ljust(16, b"\x00")), modes.ECB())
        op = c.decryptor() if decrypt else c.encryptor()
        return op.update(block) + op.finalize()

    HAVE_AES = True
except ImportError:  # pragma: no cover
    HAVE_AES = False


def _pad16(b: bytes) -> bytes:
    return b[:16].ljust(16, b"\x00")


# ---------------------------------------------------------------- inputs
def key_forms(authkey: str):
    """Ways the firmware might feed the authkey in."""
    forms = {"authkey16": authkey[:16].encode()}
    if len(authkey) > 16:
        forms["authkey_full"] = authkey.encode()
    return forms


def srand_forms(srand: bytes):
    """Ways the firmware might feed the 4-byte device random in."""
    return {
        "srand": srand,
        "srand_rev": srand[::-1],
        "srand_hex": srand.hex().encode(),
        "srand_HEX": srand.hex().upper().encode(),
        "srand_x4": srand * 4,
    }


# ---------------------------------------------------------------- constructions
def raw_outputs(k: bytes, s: bytes):
    """(name, bytes) for every construction over one key form and one srand form."""
    yield "md5(k|s)", hashlib.md5(k + s).digest()
    yield "md5(s|k)", hashlib.md5(s + k).digest()
    yield "md5(k_s)", hashlib.md5(k + b"_" + s).digest()
    yield "sha256(k|s)", hashlib.sha256(k + s).digest()
    yield "sha256(s|k)", hashlib.sha256(s + k).digest()
    yield "hmac_md5(k,s)", hmac.new(k, s, hashlib.md5).digest()
    yield "hmac_md5(s,k)", hmac.new(s, k, hashlib.md5).digest()
    yield "hmac_sha256(k,s)", hmac.new(k, s, hashlib.sha256).digest()
    yield "hmac_sha256(s,k)", hmac.new(s, k, hashlib.sha256).digest()
    blk = _pad16(s)
    yield "xxtea_enc(s,k)", xxtea_enc(blk, k)
    yield "xxtea_dec(s,k)", xxtea_dec(blk, k)
    yield "xxtea_enc(k,s)", xxtea_enc(_pad16(k), _pad16(s))
    yield "xxtea_enc(md5(s),k)", xxtea_enc(hashlib.md5(s).digest(), k)
    if HAVE_AES:
        yield "aes_enc(s,k)", aes_ecb(k, blk)
        yield "aes_dec(s,k)", aes_ecb(k, blk, decrypt=True)
        yield "aes_enc(k,s)", aes_ecb(_pad16(s), _pad16(k))
        yield "aes_enc(md5(s),k)", aes_ecb(k, hashlib.md5(s).digest())


_ALPHABETS = {
    "alnum": string.digits + string.ascii_letters,
    "printable94": "".join(chr(c) for c in range(33, 127)),
}


def as_key_strings(raw: bytes):
    """(name, 16-char string) renderings Tuya code tends to use."""
    h = raw.hex()
    for name, sl in (("hex[0:16]", h[0:16]), ("hex[8:24]", h[8:24]), ("hex[16:32]", h[16:32])):
        if len(sl) == 16:
            yield name, sl
            yield name + ".upper", sl.upper()
    yield "b64[0:16]", base64.b64encode(raw).decode()[:16]
    if len(raw) >= 16 and all(32 < b < 127 for b in raw[:16]):
        yield "ascii[0:16]", raw[:16].decode()
    for an, alpha in _ALPHABETS.items():
        if len(raw) >= 16:
            yield f"map_{an}", "".join(alpha[b % len(alpha)] for b in raw[:16])


def as_challenge(raw: bytes):
    """(name, 4 bytes) renderings for the advertised srandEncrypted."""
    yield "first4", raw[:4]
    yield "last4", raw[-4:]
    if len(raw) >= 8:
        yield "bytes[4:8]", raw[4:8]


# ---------------------------------------------------------------- search
def candidates(authkey: str, srand: bytes):
    for (kn, k), (sn, s) in itertools.product(key_forms(authkey).items(), srand_forms(srand).items()):
        for cn, raw in raw_outputs(k, s):
            yield f"{cn} k={kn} s={sn}", raw


def search(authkey: str, samples):
    """samples: list of (srand bytes, localKey str, srandEncrypted bytes|None).

    Returns (static_match, localkey_matches, challenge_matches).
    """
    static = all(lk == authkey[:16] for _, lk, _ in samples)
    lk_hits = None
    ch_hits = None
    for srand, local_key, srand_enc in samples:
        found_lk, found_ch = set(), set()
        for name, raw in candidates(authkey, srand):
            for rn, ks in as_key_strings(raw):
                if ks == local_key:
                    found_lk.add(f"{name} -> {rn}")
            if srand_enc is not None:
                for rn, cb in as_challenge(raw):
                    if cb == srand_enc:
                        found_ch.add(f"{name} -> {rn}")
        lk_hits = found_lk if lk_hits is None else lk_hits & found_lk
        if srand_enc is not None:
            ch_hits = found_ch if ch_hits is None else ch_hits & found_ch
    return static, sorted(lk_hits or ()), (sorted(ch_hits) if ch_hits is not None else None)


def _parse_sample(text: str):
    parts = text.split(":")
    if len(parts) not in (2, 3):
        raise argparse.ArgumentTypeError("sample must be srand:localKey[:srandEncrypted]")
    srand = bytes.fromhex(parts[0])
    if len(srand) != 4:
        raise argparse.ArgumentTypeError("srand must be 4 bytes (8 hex chars)")
    if len(parts[1]) != 16:
        raise argparse.ArgumentTypeError("localKey must be 16 characters")
    enc = bytes.fromhex(parts[2]) if len(parts) == 3 else None
    if enc is not None and len(enc) != 4:
        raise argparse.ArgumentTypeError("srandEncrypted must be 4 bytes (8 hex chars)")
    return srand, parts[1], enc


# ---------------------------------------------------------------- self test
def _self_test() -> None:
    """Plant a few known constructions in synthetic samples and check the search finds them."""
    authkey = "TESTAUTHKEY000000000000000000000"
    srands = [bytes.fromhex(x) for x in ("1a2b3c4d", "deadbeef", "00ff10ee", "7f000001")]
    planted = [
        ("md5(k|s) k=authkey16 s=srand -> hex[8:24]",
         lambda s: hashlib.md5(authkey[:16].encode() + s).hexdigest()[8:24]),
        ("xxtea_enc(s,k) k=authkey16 s=srand -> hex[0:16]",
         lambda s: xxtea_enc(_pad16(s), authkey[:16].encode()).hex()[0:16]),
        ("hmac_sha256(k,s) k=authkey16 s=srand_hex -> map_alnum",
         lambda s: "".join(_ALPHABETS["alnum"][b % 62]
                           for b in hmac.new(authkey[:16].encode(), s.hex().encode(), hashlib.sha256).digest()[:16])),
    ]
    challenge = lambda s: xxtea_enc(_pad16(s), authkey[:16].encode())[:4]  # noqa: E731
    for expect, fn in planted:
        samples = [(s, fn(s), challenge(s)) for s in srands]
        static, lk, ch = search(authkey, samples)
        assert not static
        assert expect in lk, (expect, lk)
        assert "xxtea_enc(s,k) k=authkey16 s=srand -> first4" in ch, ch
    # Scheme A: localKey is just the authkey.
    static, _, _ = search(authkey, [(s, authkey[:16], None) for s in srands])
    assert static
    print("self-test passed: planted constructions recovered"
          + ("" if HAVE_AES else " (AES candidates skipped: cryptography not installed)"))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--authkey", help="the bulb's authkey from its flash (16 or 32 chars)")
    ap.add_argument("--sample", action="append", type=_parse_sample, default=[],
                    help="srand:localKey[:srandEncrypted], repeat for each pairing of the same bulb")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args(argv)
    if a.self_test:
        _self_test()
        return 0
    if not a.authkey or not a.sample:
        ap.error("--authkey and at least one --sample are required")
    if len(a.sample) < 3:
        print("warning: fewer than 3 samples; a single match can be a coincidence", file=sys.stderr)

    static, lk, ch = search(a.authkey, a.sample)
    if static:
        print("Scheme A: every localKey equals authkey[0:16]. No KDF is involved.")
    if lk:
        print(f"localKey constructions matching all {len(a.sample)} samples:")
        for h in lk:
            print("  ", h)
    elif not static:
        print("No localKey candidate matched every sample.")
    if ch is not None:
        if ch:
            print("srandEncrypted constructions matching all samples:")
            for h in ch:
                print("  ", h)
        else:
            print("No srandEncrypted candidate matched (check the authkey first).")
    if not HAVE_AES:
        print("note: AES candidates skipped (install 'cryptography')", file=sys.stderr)
    return 0 if (static or lk) else 1


if __name__ == "__main__":
    sys.exit(main())
