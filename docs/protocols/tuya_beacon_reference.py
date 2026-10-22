#!/usr/bin/env python3
"""Reference implementation of the Tuya Bluetooth beacon protocols (Smart Life 7.12.0).

Companion to tuya_beacon_mesh.md in this directory. Every builder and parser here was
checked byte-for-byte against the app's own decompiled Java code; the vectors in
``_self_test`` were produced by that Java code. Run this file to re-check them.

Requires the ``cryptography`` package only for the AES-CFB (Thing Beacon Mesh) helpers.
"""
import struct

DELTA = 0x9E3779B9

def crc8(data: bytes) -> int:
    """CRC-8/SMBUS: poly 0x07, init 0x00, no reflection (bppqppq.bdpdqbp)."""
    crc = 0
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = ((crc << 1) ^ 0x07) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
    return crc

def crc16_modbus(data: bytes) -> bytes:
    """CRC-16/MODBUS, returned big-endian (bppqppq.pdqppqb)."""
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc.to_bytes(2, "big")

def _words(b: bytes):
    b = b + b"\x00" * (-len(b) % 4)
    return list(struct.unpack(">%dI" % (len(b) // 4), b))

def _mx(z, y, s, p, e, k):
    return ((((z >> 5) ^ (y << 2)) + ((y >> 3) ^ (z << 4))) ^ ((s ^ y) + (k[(p & 3) ^ e] ^ z))) & 0xFFFFFFFF

def xxtea_encrypt(data: bytes, key: bytes) -> bytes:
    """XXTEA with big-endian word packing (bpqpqqd.pdqppqb)."""
    v, k = _words(data), _words(key)
    n = len(v)
    rounds, s, z = 6 + 52 // n, 0, v[-1]
    for _ in range(rounds):
        s = (s + DELTA) & 0xFFFFFFFF
        e = (s >> 2) & 3
        for p in range(n):
            y = v[(p + 1) % n]
            v[p] = (v[p] + _mx(z, y, s, p, e, k)) & 0xFFFFFFFF
            z = v[p]
    return struct.pack(">%dI" % n, *v)

def xxtea_decrypt(data: bytes, key: bytes) -> bytes:
    v, k = _words(data), _words(key)
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

def frame_to_uuid16_list(frame: bytes):
    """How the phone advertises a frame: each byte pair [b0,b1] -> UUID16 0xb1b0 (qpbqpbq.bdpdqbp)."""
    return [frame[i] | (frame[i + 1] << 8) for i in range(0, len(frame) - 1, 2)]

def adv_ad_structure(frame: bytes) -> bytes:
    """Resulting AD element: Android writes UUID16s little-endian, so bytes are verbatim."""
    return bytes([len(frame) + 1, 0x03]) + frame


# ---------------------------------------------------------------- Beacon v2 ("P2") request frames
def build_p2_frame(frame_type: int, sub_cmd: int, src: bytes, dst: bytes, sn: int,
                   payload: bytes, key: bytes, mask: bytes) -> bytes:
    """26-byte P2 frame (pbddddb.qqdbbpp + pbbppqb).

    key  : 16-byte XXTEA key (a 16-char ASCII key is used as its bytes, 32-hex as decoded bytes)
    mask : 16-byte XOR mask applied to the encrypted half
    """
    assert len(src) == 2 and len(dst) == 2 and len(payload) <= 16
    p = payload.ljust(16, b"\x00")
    x = src + dst + sn.to_bytes(2, "big") + bytes([sub_cmd & 0xFF, crc8(p)])
    inner = bytearray(x + xxtea_encrypt(p, key))
    hdr = (((frame_type << 3) & 0xFF) + 3) & 0xFF
    crc = crc8(bytes([hdr & 0xFC]) + bytes(inner))
    for i in range(16):
        inner[8 + i] ^= mask[i]
    return bytes([hdr]) + bytes(inner) + bytes([crc])


def parse_p2_frame(frame: bytes, key: bytes, mask: bytes) -> dict:
    """Inverse of build_p2_frame; raises ValueError on CRC mismatch."""
    hdr, inner, crc = frame[0], bytearray(frame[1:25]), frame[25]
    for i in range(16):
        inner[8 + i] ^= mask[i]
    if crc8(bytes([hdr & 0xFC]) + bytes(inner)) != crc:
        raise ValueError("frame CRC mismatch")
    p = xxtea_decrypt(bytes(inner[8:24]), key)
    if crc8(p) != inner[7]:
        raise ValueError("payload CRC mismatch")
    return {"type": (hdr >> 3) & 0x1F, "src": bytes(inner[0:2]), "dst": bytes(inner[2:4]),
            "sn": int.from_bytes(inner[4:6], "big"), "sub_cmd": inner[6], "payload": p}


# ---------------------------------------------------------------- Thing Beacon Mesh (type 500)
def _aes_cfb(key: bytes, iv: bytes, data: bytes, encrypt: bool) -> bytes:
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms
    try:
        from cryptography.hazmat.decrepit.ciphers.modes import CFB
    except ImportError:  # older cryptography releases
        from cryptography.hazmat.primitives.ciphers.modes import CFB
    c = Cipher(algorithms.AES(key), CFB(iv))
    op = c.encryptor() if encrypt else c.decryptor()
    return op.update(data) + op.finalize()


def device_rand_iv(device_rand: bytes) -> bytes:
    """IV used with the pair key: 4-byte device random followed by 12 zero bytes."""
    assert len(device_rand) == 4
    return device_rand + b"\x00" * 12


def build_activation_frames(net_key: bytes, app_key: bytes, iv_index: int, unicast: int,
                            publish_addr: bytes, pair_key: bytes, device_rand: bytes, mac: bytes):
    """Two 26-byte legacy-advertising activation frames (BeaconMeshRequest.dbbpbbb)."""
    a = net_key + app_key + b"\x00" + iv_index.to_bytes(4, "big") + unicast.to_bytes(2, "big") \
        + publish_addr + b"\x00\x00"
    pt = a + bytes([crc8(a)])
    ct = _aes_cfb(pair_key, device_rand_iv(device_rand), pt, True)
    tail = mac[3:]
    return bytes([0x48]) + tail + ct[:22], bytes([0x50]) + tail + ct[22:44]


def build_activation_frame_ext(net_key: bytes, app_key: bytes, iv_index: int, unicast: int,
                               publish_addr: bytes, pair_key: bytes, device_rand: bytes, mac: bytes) -> bytes:
    """Single 50-byte extended-advertising activation frame (BeaconMeshRequest.ppdpppq/bpqqdpq).

    Note: this variant's CRC covers a leading 0x00 byte plus the 41 key bytes, and the
    plaintext is 0x00 | 41 bytes | crc (43 bytes) -- it has no trailing 0x0000 field.
    """
    a = net_key + app_key + b"\x00" + iv_index.to_bytes(4, "big") + unicast.to_bytes(2, "big") + publish_addr
    pt = b"\x00" + a + bytes([crc8(b"\x00" + a)])
    ct = _aes_cfb(pair_key, device_rand_iv(device_rand), pt, True)
    return bytes([0x68]) + mac + ct


def parse_unprovisioned_adv(payload: bytes):
    """26-byte AD-0x03 payload of an unactivated device (bqdbdbd.pdqppqb), or None."""
    if len(payload) != 26 or crc8(payload[:25]) != payload[25] or ((payload[0] >> 3) & 0xF) != 8:
        return None
    return {"version": payload[0] & 3, "mac": payload[1:7], "product_id": payload[7:15],
            "device_rand": payload[15:19], "auth": payload[19:23], "category": payload[23]}


def parse_activation_response(payload: bytes, pair_key: bytes, device_rand: bytes):
    """26-byte type-11 response (dddbppd.bdpdqbp), or None."""
    if len(payload) != 26 or crc8(payload[:25]) != payload[25] or ((payload[0] >> 3) & 0xF) != 11:
        return None
    pt = _aes_cfb(pair_key, device_rand_iv(device_rand), payload[7:25], False)
    mcu = pt[11:13]
    return {"mac": payload[1:7], "mesh_category": pt[0:2], "mesh_category_ext": pt[2:4],
            "version": "%d.%d" % (pt[4], pt[5]), "unicast": pt[6:8], "net_auth": pt[8:11],
            "mcu_version": "%d.%d.%d" % (mcu[0] >> 3, ((mcu[0] & 7) << 2) | (mcu[1] >> 6), mcu[1] & 0x3F)}


def key_bytes(key: str) -> bytes:
    """Tuya key-string rule: 16 chars -> ASCII bytes, 32 chars -> hex-decoded."""
    if len(key) == 16:
        return key.encode()
    if len(key) == 32:
        return bytes.fromhex(key)
    raise ValueError("key must be 16 ASCII chars or 32 hex chars")


# ---------------------------------------------------------------- DP encoding (P2 TLV)
DP_RAW, DP_BOOL, DP_VALUE, DP_STRING, DP_ENUM = 0, 1, 2, 3, 4

def encode_dp_p2(dps) -> bytes:
    """dps: iterable of (dp_id, dp_type, value_bytes); returns concatenated TLVs (<=16 bytes)."""
    out = b"".join(bytes([dp_id, (dp_type << 4) | (len(v) & 0x0F)]) + v for dp_id, dp_type, v in dps)
    if len(out) > 16:
        raise ValueError("P2 DP payload exceeds 16 bytes")
    return out


def decode_dp_p2(payload: bytes):
    """Parse P2 DP TLVs until a zero dp id (dqdpbpq / bbdbqqd)."""
    out, i = [], 0
    while i + 2 <= len(payload) and payload[i] != 0:
        dp_id, t, n = payload[i], payload[i + 1] >> 4, payload[i + 1] & 0x0F
        out.append((dp_id, t, payload[i + 2:i + 2 + n]))
        i += 2 + n
    return out


# ---------------------------------------------------------------- P2 pairing and receive
def build_p2_pair_frame(local_key: str, mac: bytes, node_id: bytes, beacon_key: bytes, round_: int) -> bytes:
    """P2Pair (pppbpdp): header 0x93, not masked, carries beaconKey encrypted with localKey."""
    inner = mac[2:6] + bytes([round_ & 0xFF]) + node_id + bytes([crc8(beacon_key)]) \
        + xxtea_encrypt(beacon_key, key_bytes(local_key))
    return bytes([0x93]) + inner + bytes([crc8(bytes([0x90]) + inner)])


def parse_p2_device_frame(frame: bytes, beacon_key: bytes):
    """Device->phone P2 frame (ddbbqqp + qpbdppq): unmask and decrypt with beaconKey.

    Returns None unless dst is 0x8000/0x8001 and both CRCs pass.
    """
    if len(frame) != 26 or frame[3:5] not in (b"\x80\x00", b"\x80\x01"):
        return None
    f = bytearray(frame)
    for i in range(16):
        f[9 + i] ^= beacon_key[i]
    if crc8(bytes([f[0] & 0xFC]) + bytes(f[1:25])) != f[25]:
        return None
    p = xxtea_decrypt(bytes(f[9:25]) , beacon_key)
    if crc8(p) != f[8]:
        return None
    return {"pair": bool(f[0] & 0x80), "cmd": (f[0] >> 3) & 0xF, "src": bytes(f[1:3]), "dst": bytes(f[3:5]),
            "sn": int.from_bytes(f[5:7], "big"), "sub_cmd": f[7], "payload": p}


def parse_p2_unprovisioned(payload: bytes):
    """Unpaired Beacon v2 device advert (qpbdppq.pdqppqb): pairBit=1, cmd=1."""
    if len(payload) != 26 or crc8(bytes([payload[0] & 0xFC]) + payload[1:25]) != payload[25]:
        return None
    if not (payload[0] & 0x80) or ((payload[0] >> 3) & 0xF) != 1 or payload[20] != 0:
        return None
    return {"srand": payload[1:5], "mac": payload[5:11], "pid": payload[11:19].decode("ascii", "replace").replace(" ", ""),
            "sv": "%d.%d" % (payload[19] >> 4, payload[19] & 0xF), "srand_encrypted": payload[21:25]}


# ---------------------------------------------------------------- P1 (Beacon v1) phone->device
def build_p1_frames(cmd: int, mac: bytes, sn: int, payload: bytes, key: str):
    """P1 frames (dqdpbpq.bdpdqbp). Returns list of (local_name_8_chars, uuid128_block_16_bytes).

    The phone sets its adapter name to the 8 chars and advertises the 16-byte block as one
    128-bit service UUID (AD 0x07); payload must be <=9 bytes or exactly 16 (two frames).
    """
    import base64
    k = key_bytes(key)
    name = base64.b64encode(mac)[:8]

    def block(seq, body, flag, tail=b""):
        p = bytearray(16)
        p[0], p[1] = cmd & 0xFF, crc8(mac)
        p[2:5] = (seq & 0xFFFFFF).to_bytes(3, "big")
        p[5:5 + len(body)] = body
        if tail:
            p[13] = tail[0]
        p[14] = crc8(bytes(p[1:14]))
        p[15] = flag
        return name.decode(), xxtea_encrypt(bytes(p), k)

    if len(payload) <= 9:
        return [block(sn, payload, 0x00)]
    if len(payload) == 16:
        return [block(sn, payload[:9], 0x80), block(sn + 1, payload[9:], 0x00, bytes([crc8(payload)]))]
    raise ValueError("P1 payload must be <=9 or exactly 16 bytes")


# ---------------------------------------------------------------- Thing Beacon Mesh: SIG proxy helpers
def build_proxy_wakeup_frame(src: int, seq: int, net_key: bytes, app_key: bytes) -> bytes:
    """0x70 proxy wake-up advert (bdqqqpq): AES-CFB(key=NetKey, IV=AppKey)."""
    p = b"\x00" + src.to_bytes(2, "big") + seq.to_bytes(4, "big") + b"\x00\x14" + bytes(9)
    ct = _aes_cfb(net_key, app_key, p + bytes([crc8(p)]), True)
    return b"\x70" + b"\xff\xfe\xff\xff\xff\xff" + ct


def encode_vendor_dp(dp_id: int, dp_type: str, value) -> bytes:
    """One dpRec for the Tuya vendor model 0x07D0:0004 (qpbddpb). No length byte for bool/value/enum."""
    if dp_type == "bool":
        return bytes([dp_id, 0x01, 1 if value else 0])
    if dp_type == "value":
        return bytes([dp_id, 0x02]) + int(value).to_bytes(4, "big", signed=True)
    if dp_type == "enum":
        return bytes([dp_id, 0x04, value & 0xFF])
    if dp_type == "string":
        b = value.encode()
        return bytes([dp_id, 0x03, len(b) & 0xFF]) + b
    if dp_type == "bitmap":
        n = 1 if value <= 0xFF else 2 if value <= 0xFFFF else 4
        return bytes([dp_id, 0x05, n]) + value.to_bytes(n, "big")
    b = bytes.fromhex(value) if isinstance(value, str) else bytes(value)  # raw
    return bytes([dp_id, 0x00, len(b) & 0xFF]) + b


def vendor_dp_set_access_pdu(dp_records: bytes, acked: bool = True) -> bytes:
    """Access-layer PDU for a DP write: C9 D0 07 01 <dpRec...> (acked) or CA D0 07 01 ... (unacked)."""
    return bytes([0xC9 if acked else 0xCA, 0xD0, 0x07, 0x01]) + dp_records



# ---------------------------------------------------------------- Virtual physical remote (no cloud)
# Not from the app: reconstructed by the beacon-cooked project (github.com/MadeinTaly/beacon-cooked,
# commit c5e281d) and physically confirmed by them on one P1 light. Frames are ordinary P1 frames.
REMOTE_PAIR_KEY = b"jngwRugsvwtGN00a"
REMOTE_TARGET = bytes.fromhex("eeeeeeeeee00")
REMOTE_KEY_SUFFIX = b"TuyaIoT-OS"


def remote_command_key(salt: bytes, sender: bytes) -> bytes:
    """Per-remote command key: XXTEA(salt(2) || sender[2:6] || "TuyaIoT-OS", REMOTE_PAIR_KEY).

    sender is the remote's static random BLE address, most significant byte first.
    """
    assert len(salt) == 2 and len(sender) == 6
    return xxtea_encrypt(salt + sender[2:6] + REMOTE_KEY_SUFFIX, REMOTE_PAIR_KEY)


def p1_adv_data(name: str, block: bytes) -> bytes:
    """Full 31-byte legacy AD payload as beacon-cooked sends it:
    Flags(0x01) | Complete Local Name (8 chars) | Complete 128-bit UUID list (one UUID)."""
    return b"\x02\x01\x01" + b"\x09\x09" + name.encode() + b"\x11\x07" + block


def build_remote_bind_adv(salt: bytes, sn: int) -> bytes:
    """One bind frame: P1 cmd 8, params 03 00 01 <salt> 00 00 00 00, keyed with REMOTE_PAIR_KEY."""
    (name, block), = build_p1_frames(8, REMOTE_TARGET, sn, b"\x03\x00\x01" + salt + bytes(4),
                                    REMOTE_PAIR_KEY.decode())
    return p1_adv_data(name, block)


def build_remote_dp_adv(salt: bytes, sender: bytes, sn: int, dp_payload: bytes) -> bytes:
    """One control frame: P1 cmd 7 (DP set) to REMOTE_TARGET with the per-remote key.

    dp_payload uses the P1 DP layout [dpId][dpType][len][value], at most 9 bytes.
    """
    (name, block), = build_p1_frames(7, REMOTE_TARGET, sn, dp_payload, remote_command_key(salt, sender).hex())
    return p1_adv_data(name, block)


# ---------------------------------------------------------------- self test
def _self_test() -> None:
    """Vectors generated by the app's decompiled Java (XXTEA/CRC copied verbatim, frame
    builders transcribed line by line). Keys and addresses are arbitrary test values."""
    H = bytes.fromhex
    k1 = H("0123456789abcdeffedcba9876543210")
    assert crc8(b"123456789") == 0xF4
    assert crc16_modbus(b"123456789") == H("4b37")
    assert xxtea_encrypt(H("00112233445566778899aabbccddeeff"), k1) == H("2cb628af2b144a8d17eb1e3d83d1b56f")
    assert xxtea_decrypt(H("2cb628af2b144a8d17eb1e3d83d1b56f"), k1) == H("00112233445566778899aabbccddeeff")

    # Beacon v2 (P2) control frame: type 1, subCmd 5 (DP set), src 0001 -> dst 8002, sn 0x1234.
    f = build_p2_frame(1, 5, H("0001"), H("8002"), 0x1234, H("01010101"), k1, H("a5" * 16))
    assert f == H("0b00018002123405c64f318331c42d21ffa70308a40769030074")
    assert parse_p2_frame(f, k1, H("a5" * 16))["sn"] == 0x1234
    assert build_p2_frame(2, 1, H("7fff"), H("0005"), 7, b"\x01", b"abcdefghijklmnop", bytes(16)) \
        == H("137fff000500070102ae24bdd3ca49b5952756a204bf1d01c0a8")
    assert build_p2_pair_frame("abcdefghijklmnop", H("dc234f001122"), H("0012"),
                               H("00112233445566778899aabbccddeeff"), 1) \
        == H("934f0011220100124d4800ec463257ed3da4d4b4df741887cd1e")
    assert encode_dp_p2([(1, DP_BOOL, b"\x01"), (3, DP_VALUE, (500).to_bytes(4, "big"))]) \
        == H("0111010324000001f4")

    # Beacon v1 (P1): (local name, 128-bit UUID block) pairs.
    assert build_p1_frames(7, H("dc234f001122"), 0xABCD, H("01010101"), "abcdefghijklmnop") \
        == [("3CNPABEi", H("d3a0d8423d4c47851d748ad77cabfe6f"))]
    assert build_p1_frames(2, H("dc234f001122"), 0, H("00112233445566778899aabbccddeeff"), "abcdefghijklmnop") \
        == [("3CNPABEi", H("637a1d073f186b6fe7523dacad75ed28")), ("3CNPABEi", H("c44b0653ae2bb523097d6f8bb2a8b042"))]

    # Thing Beacon Mesh activation and proxy wake-up (needs `cryptography`).
    try:
        import cryptography  # noqa: F401
    except ImportError:
        print("cryptography not installed: skipped AES-CFB vectors")
    else:
        net, app = H("00112233445566778899aabbccddeeff"), H("ffeeddccbbaa99887766554433221100")
        pair, rand, mac = H("0f0e0d0c0b0a09080706050403020100"), H("deadbeef"), H("dc234f001122")
        a, b = build_activation_frames(net, app, 0x12345678, 0x0102, b"\x00\x00", pair, rand, mac)
        assert a == H("48001122df74959c731b17d876b30c384cd38e31a70650edb7e5")
        assert b == H("500011227fe23a4049ece7275c4800803c72d1ccebebca912126")
        assert build_activation_frame_ext(net, app, 0x12345678, 0x0102, b"\x00\x00", pair, rand, mac) == H(
            "68dc234f001122df65a68d040a24c989a23f293bc2bd2055cf8e5a141e57c03134adf59e5f44afc88e0df0b1708c57dddf64")
        assert build_proxy_wakeup_frame(1, 1001, net, app) == H("70fffeffffffff7221383918a1a47d1ae3f2223bfa5b35e00dc2")
    assert vendor_dp_set_access_pdu(encode_vendor_dp(1, "bool", True)) == H("c9d00701010101")

    # Virtual remote: vectors produced by beacon-cooked's own codec (commit c5e281d).
    sender, salt = H("c2a1b2c3d4e5"), H("5a3c")
    assert remote_command_key(salt, sender) == H("c6c462deb281c0a1395fa872b24609d9")
    assert build_remote_bind_adv(salt, 20000) == H("020101090937753775377534411107785b0c026a2fa43402436d45c3ee1555")
    assert build_remote_dp_adv(salt, sender, 20001, H("01010101")) \
        == H("020101090937753775377534411107b2294a683bf7d5b8e49a4c0eea10c6d3")
    assert build_remote_dp_adv(salt, sender, 20003, H("0b000400006464")) \
        == H("020101090937753775377534411107874797e024ce7d9d0774ef3c13398c7f")
    print("all vectors match")


if __name__ == "__main__":
    _self_test()
