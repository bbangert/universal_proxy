> **Analysis notes, not a spec.** Written during the reverse-engineering of Smart Life 7.12.0 and kept for detail
> that `../tuya_beacon_mesh.md` only summarises. `file:line` citations refer to a JADX 1.5.6 decompile of
> `base.apk` (SHA-256 `68b413e9…2e14`) that is not committed here. Some line numbers are known to be off;
> class and method names are reliable. Where these notes and the spec disagree, the spec wins.

# Tuya Bluetooth "Beacon" protocol v1 (P1) and v2 (P2): reverse-engineering notes

Source: JADX decompile of Tuya Smart Life 7.12.0.
Path shorthand: `B/` = `sources/com/thingclips/sdk/bluetooth/`. Other paths are relative to `sources/com/thingclips/`.
Citations use the form `file:line`. Everything here was read from code. Nothing was run against a device.
**UNVERIFIED** marks inference that the code does not prove.

---

## 0. Corrections to the "already established" brief

| Brief said | Code says |
|---|---|
| P1/P2 TX goes through `qpbqpbq` -> `bpbbpdd` (extended adv when >=25 UUIDs, two frames 50 ms apart), queue `pppppqd` | Those classes are the **Beacon-Mesh (SIG-mesh based) activation** path (`B/dqbpdbq.java:107-117` "thingble_BeaconMeshSenderTask", `B/qdddbpd.java:12` builds `pppppqd`, tag "BeaconWorkerQueueForTest"). **P1/P2 go through `ppbdqbd` -> `ppbqqdd` ("beacon_worker", `B/ppbqqdd.java:64`) -> `pbqppbb` ("tbeacon_AdvertiseSender") -> `qqdqbpb` ("thingble_BleAdvertiser")** (`B/ppbdqbd.java:12-14`, `B/ppbqqdd.java:80`, `B/pbqppbb.java:10`). All P1/P2 managers enqueue via `ppbdqbd.bdpdqbp()` (`B/qqpdddb.java:124,621`, `B/ddqpbqb.java:391`, `B/bddqqbb.java:281`, `B/ppqbqbb.java:248`). |
| Legacy adv, extended adv if >=25 UUIDs | `qqdqbpb` is **legacy only**: `AdvertiseData.Builder` + `startAdvertising` (`B/qqdqbpb.java:186-193,248`). Mode `2`=LOW_LATENCY, TX power `3`=HIGH, connectable, timeout = the request's send time (`B/qqdqbpb.java:278-288`). If the adapter supports multiple advertisements, the **same data is started on 2 advertising sets at once** (`B/qqdqbpb.java:163-170,246-249`). |
| The on-air 16-bit UUID mapping | Confirmed for P2: pair `[b0,b1]` -> UUID string `b1b0` -> `0000b1b0-0000-1000-8000-00805F9B34FB` (`B/pbqppbb.java:47-59`, `B/qqdqbpb.java:177-193`). On air (AD 0x03, little-endian) the frame bytes appear verbatim. 26 bytes = 13 UUIDs -> AD len 27, plus Android's flags = 31 bytes. |
| Trailing CRC over `[hdr&0xFC]+inner` | Correct, but it is computed **before** the XOR mask is applied (`B/pbddddb.java:50` precedes the mask loop at `:55-58`). |
| Constructor `pbddddb(devId, dst, key, mask)` | Confirmed: `(str=dqdbbqp "ownId/devId", str2=pbpqqdp dstAddr, str3=bpbbqdb XXTEA key, str4=qqpdpbp XOR mask)` (`B/pbddddb.java:14-19`). `srcAddr` (`bqqppqq`) is set afterwards via `bdpdqbp(String)` (`B/pbddddb.java:21-23`, called at `B/qqpdddb.java:123`). |

---

## 1. Primitives

### 1.1 CRC-8
`bppqppq.bdpdqbp(byte[] b, int n)` (`B/bppqppq.java:9-26`) is a 16-bit-register implementation of **CRC-8/SMBUS**: poly 0x07, init 0x00, no reflection, no xorout. I checked it against a reference CRC-8 in Python on random data. check("123456789") = 0xF4.

### 1.2 XXTEA
`B/bpqpqqd.java`:
- `pdqppqb(data,key)` = **encrypt** (`:11-13`, core `:38-61`). `bdpdqbp(data,key)` = **decrypt** (`:7-9`, core `:15-36`).
- Standard XXTEA (delta 0x9E3779B9, rounds = 6 + 52/n; n=4 gives 19 rounds, MX = `((z>>>5 ^ y<<2) + (y>>>3 ^ z<<4)) ^ ((sum^y) + (k[(p&3)^e] ^ z))`).
- Bytes -> words are **big-endian** (`:80`, `:96`). No length word is appended (`z=false`). Data is always exactly 16 bytes (4 words). The key is the first 16 bytes.

### 1.3 Key-string -> key-bytes rule (used everywhere)
- 16-char string -> `String.getBytes()` (raw ASCII).
- 32-char string -> hex-decode.
- Anything else -> fail.

Sources: `B/pbddddb.java:109-113` (P2 XXTEA key), `B/dqdpbpq.java:266-274` (P1 key). The **XOR mask** is always hex-decoded (`dpbdbpb.pdqppqb`, `B/pbddddb.java:51`), so it must be 32 hex chars. On P2 receive, the key is always hex-decoded (`B/ddbbqqp.java:124,164`). On P1 receive, the key is always `getBytes()` (`B/ddbbqqp.java:245`), so it must be the 16-char ASCII localKey.

### 1.4 Hex helpers
`dpbdbpb.pdqppqb(String)` decodes hex with the first char as the high nibble (`B/dpbdbpb.java:149-162`). `dpbdbpb.bppdpdq(int)` gives 2 bytes big-endian (`B/dpbdbpb.java:145-147`). `dpbdbpb.pbddddb(byte[])` gives lowercase hex (`B/dpbdbpb.java:36-49`).

---

## 2. Key material (Q1)

### 2.1 Where keys come from

| Name in code | Source | Cached as |
|---|---|---|
| **localKey** (per device, 16 ASCII chars) | `DeviceBean.getLocalKey()`. At activation it comes from `PreActivateResult.localKey` (P2, `thing.m.device.blu.preactive`) or `BLEActiveBean.localKey` (P1, `thing.m.device.beacon.active`) (`beacon/bean/PreActivateResult.java:5-8`, `beacon/bean/BLEActiveBean.java:5-17`) | device list |
| **beaconKey** (per home "beacon mesh") | `qqdqqpd.getBeaconKey(ownerId)`: `BeaconMeshBean.getAppKey()`, falling back to the DataKV `"BeaconKey_"+ownerId` (`B/qqdqqpd.java:63-74`, `B/dqddqdp.java:361-373`). BeaconMeshBean comes from home data (`ThingListDataBean.getBeacons()`, `sdk/home/OooOOO.java:843-844`; cached pref `s_home_data_beacon_list`, `sdk/home/OooOo00.java:13`) or from `thing.m.device.beacon.mesh.create` (`B/pqqpqpq.java:58-62`, stored at `B/dqddqdp.java:216-219`). The device receives its beaconKey at pairing (`PreActivateResult.beaconKey` for P2, `BLEActiveBean.beaconKey` for P1). | DataKV |
| **groupKey** (per group) | `GroupBean.getGroupKey()` from group cache (`B/qqpdddb.java:441,525`, `B/ddqpbqb.java:439,551-553`) | group cache |
| **secKey** (lock/NFC only) | `IThingNfcPlugin.findDeviceKeys(uid,devId).getSecKey()` (`B/qqpdddb.java:578-588`) | NFC plugin |

**UNVERIFIED:** `PreActivateResult.beaconKey` (sent to the device in P2Pair) and `BeaconMeshBean.appKey` (used by the phone for mask/RX) are probably the same value. They must be equal for RX decryption to work.

There is **no MD5/SHA derivation** for normal P1/P2 traffic. Keys are used as-is per §1.3. The only derivation is the RemoteAction HKDF (§2.3).

### 2.2 Constructor arguments per P2 request

`devId` slot = `deviceBean.getOwnerId()` (home/gid as decimal string). It is used only as the sn-counter key and RX parse-info key. It never goes on air.

| Request (class) | dst (`pbpqqdp`) | XXTEA key (`bpbbqdb`) | XOR mask (`qqpdpbp`) | src | Cite |
|---|---|---|---|---|---|
| P2Reset `dqdbdpd` | nodeId | localKey | beaconKey | cloud srcId | `B/qqpdddb.java:555` |
| P2Dps `dqdpqpq` (no ack) | nodeId | localKey | beaconKey | cloud srcId | `B/qqpdddb.java:347,476` |
| P2Dps group | `"FF"+group.localId` | **groupKey** | beaconKey | cloud srcId | `B/qqpdddb.java:525` -> `:347` |
| P2Dps w/ ack `pqpbpqd` | nodeId | localKey | beaconKey | cloud srcId | `B/qqpdddb.java:498` |
| P2Ping `dpdpqpd` (1..7 devs, one at a time) | nodeId | localKey | beaconKey | cloud srcId | `B/qqpdddb.java:234-243` |
| P2Ping broadcast (>=8 devs) | `"FFFF"` (`bpbbpbp.qppddqq`, `B/bpbbpbp.java:44`) | **beaconKey** | beaconKey | cloud srcId | `B/qqpdddb.java:294-299,513-518`, `B/dpdpqpd.java:141` |
| P2AddSub `qbqqdqq` | nodeId | localKey | beaconKey | cloud srcId | `B/qqpdddb.java:329` |
| P2RemoveSub `bqpqqbb` | nodeId | localKey | beaconKey | cloud srcId | `B/qqpdddb.java:369` |
| P2DismissGroup `qdppdpp` | `"FF"+localId` (`B/qdppdpp.java:213`) | **groupKey** | beaconKey | cloud srcId | `B/qqpdddb.java:441` |
| P2Pair `pppbpdp` | nodeId (from preactive) | **localKey** (ASCII) | n/a (not applied) | none | `B/bddqqbb.java:281` |
| RawBeaconDataSend `ddqbbqp` | `"FFFF"` | `hex(ASCII(str))` (so the key = the ASCII bytes of a caller-supplied 16-char string) | same | `dqddqqb.randomId` | `B/qqpdddb.java:614-619` |
| RemoteAction `dpddddp` | `"0001"` | HKDF key (§2.3) | same HKDF key | `"8001"` | `B/qqpdddb.java:598`, `B/dpddddp.java:113-126` |

`nodeId` = `JSON.parse(deviceBean.meta["beaconData"])["beaconNodeId"]` (`B/qqpdddb.java:277-285`). Device beacon version 2 is detected by `beaconData.beaconVer == "2"` (`B/dppdddb.java:161-175`). A P2 group is detected by `groupType == 7` (`B/dqddqqb.java:63-67`).

### 2.3 RemoteAction (NFC lock) key derivation, verbatim
`B/dpddddp.java:294-307`:
```
K = HKDF-SHA256( IKM  = UTF8(secKey + localKey),
                 salt = hexdecode( sha256_hex_lower( transactionId + devId ) ),
                 info = "SKPhone", L = 16 )
```
`qqbdddp` is RFC 5869: PRK = HMAC(salt, IKM), T(i) = HMAC(PRK, T(i-1)||info||i) (`B/qqbdddp.java:10-35`). `SHA256Util.sha256` returns lowercase hex (`smart/android/common/utils/SHA256Util.java`). K is used both as the AES key and as the XOR mask (`B/dpddddp.java:122-126`).

---

## 3. P2 (Beacon v2) frames (Q2)

### 3.1 Generic P2 phone->device frame (26 bytes, AD 0x03 as 13 x 16-bit UUIDs)

| Off | Len | Field | Notes |
|---|---|---|---|
| 0 | 1 | header | `(type<<3) + 3` normally (`B/pbddddb.java:45,79-81`). bit7 = pairBit, bits6..3 = type/cmd, bits1..0 = low bits (excluded from CRC). |
| 1 | 2 | srcAddr | hex string -> 2 bytes, as written (big-endian) |
| 3 | 2 | dstAddr | same |
| 5 | 2 | sn | big-endian 16-bit (`B/pbddddb.java:118-119`) |
| 7 | 1 | subCmd | `bdqqbqd()` |
| 8 | 1 | crcP | CRC8(plaintext 16 B) (`B/pbddddb.java:117`) |
| 9 | 16 | payloadY | `XXTEA_enc(pad0_16(payload), Kenc)` **XOR Kmask** |
| 25 | 1 | crcF | CRC8(`[hdr & 0xFC]` ++ bytes 1..24 **before** XOR) (`B/pbddddb.java:50`) |

Build order (`B/pbddddb.java:43-62,95-123`):
1. `inner = X(8) || XXTEA_enc(pad16(payload), Kenc)`.
2. `crcF = crc8([hdr&0xFC] || inner)`.
3. `inner[8..24) ^= Kmask`.
4. `frame = hdr || inner || crcF`.

The payload must be <=16 bytes (`:103`).

### 3.2 Header type / subCmd / payload per request

| Request | hdr | type | subCmd | payload (before 0-pad to 16) | Cite |
|---|---|---|---|---|---|
| P2Pair | **0x93** (`qbbdpbq()=0x90`, +3) | pairBit=1, type 2 | (no field, see 3.3) | special | `B/pppbpdp.java:271-280,301-304` |
| P2Reset | 0x0B | 1 | 0x01 | `02` | `B/dqdbdpd.java:163-190` |
| P2Dps (no ack) | 0x0B | 1 | 0x05 | DP TLVs (§3.4) | `B/dqdpqpq.java:17-45` |
| P2Dps (ack) | 0x0B | 1 | 0x06 | DP TLVs | `B/pqpbpqd.java:71-103` |
| P2AddSub | 0x0B | 1 | 0x01 | `A1 gg` (gg = first byte of group localId) | `B/qbqqdqq.java:98-131` |
| P2RemoveSub | 0x0B | 1 | 0x01 | `A2 g1 [g2 ...]` (concatenated 1-byte localIds) | `B/bqpqqbb.java:34-69` |
| P2Ping | 0x13 | 2 | 0x01 | `01` | `B/dpdpqpd.java:168-203` |
| P2DismissGroup | 0x13 | 2 | 0x01 | `A2 gg` (sent to dst FFgg) | `B/qdppdpp.java:219-242` |
| RawBeaconDataSend | `0x10 + i` (i = caller's low bits) | 2 | 0x05 | DP TLV with id 0x57 (87), type 0 raw: `57 0L <raw...>` | `B/ddqbbqp.java:165-232` |
| RemoteAction | **0x18** (low bits 0) | 3 | 0x21 | 16 B, §3.5 | `B/dpddddp.java:135-148,192-220` |

Meaning of `type` (bits 6..3) on TX. **UNVERIFIED semantics**, reading off usage:
- 1 = per-device/group "control" (reset, DP, group membership).
- 2 = query/broadcast-ish (ping, dismiss, raw) and also pair (with pairBit).
- 3 = remote/secure action (AES instead of XXTEA).

Low 2 bits: always 3 except RemoteAction (0) and Raw (caller). They are excluded from both CRCs (`&0xFC`), so they are probably a **TTL/relay hop counter** that relays may change. **UNVERIFIED**: no relay code is visible in the app.

### 3.3 P2Pair frame (26 bytes, not masked, no sn)
`B/pppbpdp.java:242-253,307-315`. Constructor `pppbpdp(localKey, homeIdStr, mac12hex, nodeId, beaconKey, round)` (`B/bddqqbb.java:281`).

| Off | Len | Field |
|---|---|---|
| 0 | 1 | 0x93 |
| 1 | 4 | `mac[2..6)`: bytes 2-5 of the 6-byte MAC field from the unprovisioned advert (`mac.substring(4)` of the 12-hex string) |
| 5 | 1 | round (retry counter 0..3) |
| 6 | 2 | assigned nodeId |
| 8 | 1 | CRC8(beaconKey 16 B) |
| 9 | 16 | `XXTEA_enc(beaconKey_bytes(hex), key = localKey.getBytes())` |
| 25 | 1 | CRC8(`[0x90]` ++ bytes 1..24) |

### 3.4 DP TLV encoding (`dqdpbpq.bdpdqbp(DpsCombine)`, `B/dqdpbpq.java:352-364`)
Each DP is `[dpId:1][(dpType<<4) | (len & 0x0F):1][value:len]`. DPs are concatenated, so the total must be <=16 bytes. Types and values come from `bdqqqdq.bdpdqbp(2, devId, dpsJson)` (`B/bdqqqdq.java:39-125`, all P1/P2 call sites pass `2`):

| type | schema | value bytes |
|---|---|---|
| 0 | raw | hex-decoded string |
| 1 | bool | 1 byte 0/1 |
| 2 | value (int) | 4 bytes **big-endian** (`pbbddbd.bppdpdq`, `B/pbbddbd.java:15-17`) |
| 3 | string | UTF-8 bytes |
| 4 | enum | 1 byte = index in schema `range` |
| 5 (RX only) | bitmap | big-endian int (`B/bbdbqqd.java:38-41`) |

Bitmap is not encodable on TX. Read-only DPs are rejected (`B/dppdddb.java:24-35`). Example: switch dp1=true and bright dp3=500 gives `01 11 01 03 24 00 00 01 F4` then 7 x 00.

### 3.5 RemoteAction payload (16 B, `B/dpddddp.java:192-215`)

| Off | Len | Field |
|---|---|---|
| 0 | 1 | 0x5F |
| 1 | 1 | 0x0E (`MqttWireMessage.MESSAGE_TYPE_DISCONNECT`=14, `smart/mqttclient/mqttv3/internal/wire/MqttWireMessage.java:22`) |
| 2 | 2 | BE: `memberId & 0x7FFF`, with `0x8000` set if admin |
| 4 | 4 | phoneKey (4 bytes) |
| 8 | 8 | hex-decode(transactionId, 16 hex chars) |

Encryption: **AES-128-CBC/NoPadding**. Key = HKDF K, IV = ASCII bytes of the 16-char transactionId (`B/dpddddp.java:255`, `smart/android/network/util/AESCBCUtil.java` encrypt(byte[],byte[],byte[])). Then XOR with K. CRC as usual. src=0x8001, dst=0x0001 (`B/qqpdddb.java:598`, `sdk/device/ddbdpdp.java:9`).

### 3.6 Sequence numbers (P2 TX)
`dqddqdp.qddqppb.pdqppqb(srcId)` (`B/dqddqdp.java:388-397`), called at `B/qqpdddb.java:114`:
- There is one counter per ownerId (home), persisted in DataKV under `ownerId + "_" + srcId`.
- First use: stored value + 1. If nothing is stored: -1 + 1 = 0.
- The value is saved, then returned, then incremented. It wraps to 0 when >= 65535.
- The sn is fixed when the request is queued, so repeated adverts of one request carry the same sn.

For Raw requests, the counter key is `randomId` (`B/qqpdddb.java:618`).

### 3.7 Source address (phone's own P2 address)
`dqddqdp.bdpdqbp(meshId, ownerId, cb)` (`B/dqddqdp.java:431-443`):
- Cached hex string in DataKV `"NodeId_"+ownerId`.
- Otherwise `thing.m.beacon.mesh.source.id.alloc {meshId}` returns an Integer (`B/pqqpqpq.java:52-56`). It is stored as `Integer.toHexString(n)` (`B/dqddqdp.java:280`).
- **Quirk/bug:** on the first allocation the callback receives `String.valueOf(n)` (decimal, `B/dqddqdp.java:281`), so that one request uses the decimal digits as hex. Later requests use the hex form.
- The address must be exactly 4 hex chars or the frame build fails (`B/pbddddb.java:103`). That implies allocated ids are in 0x1000-0xFFFF. **UNVERIFIED** server range.

Other source ids:
- Unactivated "raw" sender: `randomId = hex(0x6000 + rand(0x2000))`, i.e. 0x6000..0x7FFF (`B/dqddqqb.java:55-57`).
- RemoteAction: 0x8001.

---

## 4. P1 (Beacon v1) frames (Q3)

### 4.1 Builder
`qpppdqb.pbbppqb()` (`B/qpppdqb.java:43-53`) calls `dqdpbpq.bdpdqbp(cmd, macHex12, sn, payload, key)` (`B/dqdpbpq.java:258-327`). The P1 request has `bqqppqq()=0` (`B/bdpqppd.java:38-40`), so the sender uses mode 0: set the **adapter name** plus one **128-bit service UUID** (`B/pbqppbb.java:25-26,62-68`, `B/qqdqbpb.java:41-75,215-218,290-309`).

Internal 28-byte buffer (template at `B/dqdpbpq.java:318`):

| Off | Len | Field | On air |
|---|---|---|---|
| 0-1 | 2 | `09 09` | not used |
| 2 | 8 | first 8 chars of `Base64(mac 6 B)` | becomes BluetoothAdapter name -> AD 0x09 Complete Local Name |
| 10-11 | 2 | `17 07` | not used |
| 12 | 16 | encrypted block E | 128-bit service UUID (AD 0x07) |

Plaintext block P (16 B) before encryption:

| P off | Field |
|---|---|
| 0 | cmd (`qpbpqpq()`) |
| 1 | CRC8(mac 6 B), an implicit target address (`B/dqdpbpq.java:321`) |
| 2..4 | sn, 24-bit big-endian (`:322-324`) |
| 5..13 | payload, up to 9 bytes, zero padded (`:281`) |
| 14 | CRC8(P[1..14)), i.e. 13 bytes (`:282-284`) |
| 15 | 0x80 = "first of 2 frames", else 0x00 (`:325`, `ByteCompanionObject.MIN_VALUE`) |

`E = XXTEA_enc(P, key)` in place (`B/dqdpbpq.java:310-315`).

A **16-byte payload** is sent as 2 frames (`:288-305`):
- Frame A: sn, payload[0..9), P[15]=0x80.
- Frame B: sn+1, payload[9..16) at P[5..12), P[12]=0, P[13]=CRC8(payload 16 B), P[15]=0.

Payload lengths 10..15 or >16 are rejected (return null).

UUID byte order on air: the UUID string is built from E **reversed** (`dpbdbpb.qddqppb`, `B/dpbdbpb.java:113-136`). Android serialises 128-bit UUIDs little-endian, so **E appears verbatim** in AD 0x07. **UNVERIFIED**: this relies on standard Android framework behaviour, which is outside this decompile. On air: flags(3) + name(2+8) + uuid128(2+16) = 31 bytes. The sender polls every 300 ms, up to 3 s, for the adapter name change (`B/qqdqbpb.java:94-125,304-307`). The worker adds 400/1500 ms when a rename happened (`B/ppbqqdd.java:90-92`).

### 4.2 P1 keys and addresses
- Target address = device MAC uppercase without colons (`B/qpppdqb.java:16-20`).
- Group target = `"FFFFFFFFFF" + localId` (`B/ddqpbqb.java:298-300`, `B/ddqdppd.java:9`).
- Broadcast = `"FFFFFFFFFFFF"` (`B/qbdbdbd.java:136`).

| Request | class | cmd | payload | key | Cite |
|---|---|---|---|---|---|
| P1Pair | `bbbdqpb` | 2 | hex(beaconKey) = 16 B (2 frames). sn forced 0 | localKey | `B/bbbdqpb.java:10-52`, `B/ppqbqbb.java:246-249` |
| P1Reset | `bdpddpb` | 3 | `03` | localKey | `B/bdpddpb.java`, `B/ddqpbqb.java:619` |
| P1Ping single | `qbdbdbd` | 3 | `02` | localKey, mac=dev | `B/qbdbdbd.java:128-202`, `B/ddqpbqb.java:590` |
| P1Ping multi | `qbdbdbd` | 3 | `02` | beaconKey, mac=FF*6 | `B/ddqpbqb.java:593-605` |
| P1Dps | `dpppbdq` | 7 | `dpId, dpType, len, value` (**3-byte header, not nibble-packed**). Single DP, value <=6 B | localKey or groupKey | `B/dpppbdq.java:94-102`, `B/dqdpbpq.java:230-240`, `B/ddqpbqb.java:345-372` |
| P1AddSub | `qpqpppd` | 8 | `00 gg` | localKey | `B/qpqpppd.java:38-46` |
| P1Remove | `qpddppb` | 8 | `01 g1 [g2..]` | localKey | `B/qpddppb.java:57-64` |
| P1DismissGroup | `ddqdppd` | 8 | `01 gg` to FF..FFgg | groupKey | `B/ddqdppd.java:9-33` |
| P1BeaconAuth | `qqpbqpq` | 3 | `[6/7/8][0/1/2][mac6][group]` (9 B) | localKey | `B/qqpbqpq.java:250-280`, `B/dqdpbpq.java:242-256` |

P1 sends are only allowed if `beaconData.pv == "00"` (`B/ddqpbqb.java:314-320`). The device is two-way only if `beaconData.flag & 0x80 == 0` (`B/ddqpbqb.java:306-312`).

### 4.3 P1 sequence numbers
`qpppdqb.bpqqdpq()` (`B/qpppdqb.java:34-36`):
- Broadcast/group (mac starts FFFFFFFFFF): `currentTimeMillis % 0xFFFFFF`.
- Unicast: `pdqqqdq.bppdpdq(mac)` (`B/pdqqqdq.java:24-61`), a per-MAC counter persisted in DataKV. If missing, it starts at random 3..1002. It is reset to 3 on device add (`B/ddqpbqb.java:513`, `B/pdqqqdq.java:38-41`).

Resync: when the device replies cmd 4 / data[0]=0 ("SnReplyResp", data[1..4) = device sn, `B/pqqppdd.java`), the phone sets sn = that + 1 and **retries once** (`B/dbbbbqq.java:136-146`, `B/qpppdqb.java:74-76`, `B/ppbqqdd.java:125-137`).

---

## 5. Receive side (Q4)

All receive goes through `ddbbqqp` ("tbeacon_ReceiveManager"):
- Scanner: `ThingBleScanner` with tag "BeaconReceiveScanner" (`B/ddbbqqp.java:32-33`).
- Scan duration = request window + 10 s (`:315-320`). The general monitor window is 180 s (`:306`, `sdk/mqtt/bqbdbqb.java:9`).
- Identical raw scan records are deduplicated with an LRU of 100 (`:45-52`).
- Each record is tried as P2 first, then P1 (`:53-61`).

### 5.1 P2 RX: AD 0x03 (16-bit UUID list) of exactly 26 bytes
Parse: `qpbdppq.bppdpdq` (`B/qpbdppq.java:28-64`). The frame layout is the same as §3.1 (header, src, dst, sn BE, subCmd, crcP, enc16, crcF).

- Frames with pairBit=1 and cmd=1 are ignored here (those are unprovisioned adverts).
- **dst must be `8000` or `8001`** (`B/ddbbqqp.java:101`, `sdk/device/ddbdpdp.java:9`).
- Key lookup (`B/ddbbqqp.java:109-123`): an active request link keyed by src = request dst address, else the monitor parse-info for that nodeId (`B/qqpdddb.java:380-397`). In both cases the key is **beaconKey** (request links use the request's mask, `B/dbbbbqq.java:96-99`).
- CRC: copy the frame, XOR bytes 9..25 with K, then check CRC8(`[hdr&0xFC]` ++ bytes 1..24) == byte 25 (`B/ddbbqqp.java:124-134`, `B/qpbdppq.java:106-115`).
- Anti-replay, per (ownerId, src) (`B/ddbbqqp.java:135-155,170-179`):
  - Drop if sn == last.
  - Drop if last > sn and last-sn <= 55536.
  - Accept if sn > last or on wrap.
  - pairBit=1 frames reset the stored sn.
- Decrypt (`B/qpbdppq.java:118-131`): `P = XXTEA_dec(enc16 XOR K, K)`. Require CRC8(P) == crcP.
- Dispatch (`B/qpbdppq.java:132-167`):

| pairBit | cmd | subCmd | P[0] | class / meaning |
|---|---|---|---|---|
| 1 | 3 | any | | `qqbqppp` pair result: beaconExt = hex(P[0..4)) (`B/qqbqppp.java`) |
| 0 | 1 | 2 | 0x01 | `bbqdbpd` (probably ping ack, **UNVERIFIED**) |
| 0 | 1 | 2 | 0x02 | `pdpqddq` reset ack (`B/dqdbdpd.java:193-203`) |
| 0 | 1 | 2 | 0xA3 | `dbqpdqd` group list: P[1..9) up to 8 one-byte group ids, 0 = empty (`B/dbqpdqd.java:62-86`) |
| 0 | 1 | 7, 9, 10, 11 | | `qpqbbpp` DP report: P = DP TLVs as §3.4, parsed until id 0 (`B/dqdpbpq.java:179-191`). 7 vs 9/10/11 meaning **UNVERIFIED** |
| 0 | 3 | 0x22 | | RemoteControl resp (`B/ddbbqqp.java:156-162`) |

RemoteControl resp (`B/qpbdppq.java:170-198`):
- `P = AES-CBC-NoPad-dec(K=HKDF, IV=ASCII(transactionId), enc XOR K)`, with the CRC8 check.
- Layout (`beacon/receiver/RemoteControlBeaconResp.java:53-89`): `[cmd][len][result 0=ok,1 fail,2 anti-lock,3 trial-lock,4 already open][member BE16 w/ admin bit15][durationMs BE32]`.

DP values decode big-endian (`B/bbdbqqd.java:25-42`, `dpbdbpb.pppbppp` at `B/dpbdbpb.java:78-87`). Enum = range[index]. Reports are forwarded to the cloud with `thing.m.device.dp.report {devId, dps, sn, dpsTime}` (`B/ddbbppb.java:151,223-228`, `B/pqqpqpq.java:29-41`).

### 5.2 P1 RX: AD 0xFF, 29 bytes, company id bytes `07 D0` (0xD007)
`dbqqppp.bdpdqbp` (`B/dbqqppp.java:8-36`).

| Off (mfr data incl. CID) | Field |
|---|---|
| 0-1 | `07 D0` |
| 2 | bits7..6 = version (must be 0), bits5..0 = cmd |
| 3 | MAC (6) |
| 9 | sn (4, BE) |
| 13 | E (16) = XXTEA_enc(plain, localKey ASCII) |

The AD length byte is 0x1E, so the record fills all 31 bytes with no flags AD. That is why `dqdpbpq.bdpdqbp(byte[],String)` reads `scanRecord[2..31)` (`B/dqdpbpq.java:66-67`).

Decrypted plain = `[sn 4 BE, must equal header sn][data 10][2 bytes unused, UNVERIFIED]` (`B/dbqqppp.java:44-52`). Anti-replay: drop if sn <= last per MAC (`B/ddbbqqp.java:235-243`).

Dispatch (`B/dbqqppp.java:53-84`):

| cmd | data[0] | class / meaning |
|---|---|---|
| 4 | 0 | SnReply (data[1..4) = device sn) |
| 4 | 1, 3 | pair OK (`qqbqppp`) |
| 4 | 2 | `bbqdbpd` (**UNVERIFIED**) |
| 4 | 5 | reset ack |
| 4 | 6, 7, 8 | BeaconAuth event, layout in `B/ddqpbqb.java:218-296` |
| 5, 6 | | DP report: one DP `[id][type][len<=7][value]` (`B/dqdpbpq.java:335-350`) |
| 9 | 2 | group list: data[1..9) |

### 5.3 Scan-time identification of devices (config scanner `sdk/ble/core/manager/bdpdqbp.java:192-218`)
- **P1 unprovisioned:** mfr 0xD007, length 27 after the CID, version 0, **cmd 1**. Here the sn field is a *segment index 0..2*. The scanner collects 3 adverts per MAC, each raw 29 bytes as 58-hex (`B/pdbpbdq.java:37-45`, `B/dqdpbpq.java:50-92`). When all 3 are present it emits BLEScanDevBean deviceType 500, category 400, data = JSON array of the 3 hex strings (`B/dqdpbpq.java:329-333`).
- **P1 cmd 5** adverts at scan time mean "bound/share" devices (isBind=isShare=true, deviceType 500).
- **P2 unprovisioned:** AD 0x03, 26 bytes, valid CRC8, pairBit=1, cmd=1 (`B/qpbdppq.java:66-115`). Layout:

| Off | Field |
|---|---|
| 0 | hdr |
| 1 | srand (4) |
| 5 | MAC (6) |
| 11 | pid (8 printable ASCII; spaces stripped; `B/qddqppb.java:43-54`) |
| 19 | sv (version byte, shown as `hi.lo` nibbles) |
| 20 | flag (must be 0) |
| 21 | srandEncrypted (4) |
| 25 | crcF |

It emits deviceType 501 (`B/qpbdppq.java:16-26`).

### 5.4 Activation flows

**P2** (`B/bddqqbb.java`, tag "tbeacon_config_b2Activator"):
1. Get meshId: cached, or `thing.m.device.beacon.mesh.create` (gid). That also caches appKey as beaconKey (`B/bddqqbb.java:247-256`, `B/dqddqdp.java:416-429`).
2. Per device: `thing.m.device.blu.preactive` with `{meshId, mac, pid, isShare:false, type:1, protocolOpt: {sv, flag, srand, srandEncrypted, beaconVer:"2"}}`. The result is `{beaconNodeId, localKey, beaconKey, relyCloud}` (`B/qbdqpqq.java:27-42`). If relyCloud is set, the flow aborts with code 132 (`B/bddqqbb.java:121-124`).
3. Send P2Pair (§3.3), round 0 (`B/bddqqbb.java:258-260,279-282`).
4. The device answers with pairBit=1 cmd=3. The 4-byte `beaconExt` is decrypted with beaconKey (`B/bddqqbb.java:83-86`).
5. `thing.m.device.blu.active` with `{gid, mac, productId, sv, timeZone, bindUser:true, type:1, protocolOpt:{srand, beaconVer:"2", beaconExt}}`, which returns devId (`B/qbdqpqq.java:44-59`, `B/bddqqbb.java:264-274`).
6. `queryDev` to fetch the DeviceBean (`B/bddqqbb.java:283-285`).
7. Failed pairs are retried in rounds 1..3, about 1 s after all pending ones fail. After round 4 the result is error 205213 (`B/bddqqbb.java:217-239,299-310`). The exact retry wiring is UNVERIFIED (JADX merged bridge methods).

**P1** (`B/ppqbqbb.java`, tag "tbeacon_config_ConfigController"):
1. `thing.m.device.beacon.active` with `{gid, mac, encryptedData = JSON array of the 3 raw advert hex strings (or ["hex"] for share), ability:5, pv:"2.0", sv:"0", timeZone, bindUser:true, isShare}`. The result is BLEActiveBean `{devId, localKey, beaconKey, secKey, ...}` (`B/qbdqpqq.java:13-25`, `B/ppqbqbb.java:187-201`).
2. `queryDev`, then read `meta.beaconData`:
   - If `flag & 0x80`: one-way device, done.
   - Else if `pv=="00"`: send P1Pair with beaconKey (localKey-encrypted) and wait for cmd4/data 1|3 (`B/ppqbqbb.java:41-103,246-249`).
3. On failure the device is removed (`removeDevice`) and error 501 is returned.

Other cloud APIs:
- `thing.m.device.local.group.validate {devId, localIds, type:4}`: used when the device's 8 group slots are full, to remove stale ids (`B/pqqpqpq.java:43-50`, `B/qqpdddb.java:62-66,171-190`).
- `thing.m.device.dp.report`.

---

## 6. Grouping and addressing (Q5)

| | P1 | P2 |
|---|---|---|
| Device address | 6-byte MAC (implicit: Base64 name + CRC8(mac) in the block) | 16-bit nodeId from cloud (`beaconData.beaconNodeId`) |
| Group address | `FF FF FF FF FF gg` | `0xFFgg` |
| Broadcast | `FF*6` | `0xFFFF` |
| Phone source | n/a | cloud-allocated per home/mesh; 0x6000-0x7FFF random for raw; 0x8001 remote action |
| Device->phone dst | n/a | 0x8000 or 0x8001 |
| Unicast key | localKey | localKey (+ beaconKey mask) |
| Group key | groupKey | groupKey (+ beaconKey mask) |
| Broadcast key | beaconKey | beaconKey (+ beaconKey mask) |
| RX key | localKey | beaconKey (mask and XXTEA) |

- `gg` = group `localId`, one byte (2 hex chars). A device holds at most 8 group ids (A3 list).
- **meshId** is never on air. It only selects the cloud source-id pool and the preactive context. beaconKey is the mesh-wide key (BeaconMeshBean `{id, meshId, appKey}`, `smart/sdk/bean/BeaconMeshBean.java:5-7`).
- **Relay/TTL:** nothing in the app relays. The header's low 2 bits, excluded from CRC, are the likely TTL. **UNVERIFIED.**
- Response matching (`B/dbbbbqq.java:79-123`):
  - Each request with requestTime>0 registers a link keyed by its dst string (`pqpbpqd()` = `pbddddb()`). Ping also appends HMAC-SHA256(key 000001, sorted devIds) to make the key unique (`B/dpdpqpd.java:155-166,205-208`).
  - A received frame whose **src == request dst** is offered to `request.bdpdqbp(devId, resp)`, which returns 0 (done), 1 (ignore) or -1 (wrong) (`B/dbbbbqq.java:125-134`, `B/ppbqqdd.java:361-381`).
  - There is **no sn echo**. Only the address and the response class are matched.
  - Ping uses a broadcast listener that resolves devId via the monitor parse-info.

---

## 7. Timing (Q6)

Base request defaults (`B/bdpqppd.java:13-16`): sendTime 1500, perPackage 1500, requestTime 5000, min 1000.

The setter names are confusingly obfuscated:
- `qddqppb(long)` = sendTime
- `bppdpdq(long)` = perPackage
- `pdqppqb(long)` = requestTime (response window)
- `bdpdqbp(long)` = min wait
- `bdpdqbp(boolean)` = hasResponse
- `bdpdqbp(int)` = queue type (`B/bdpqppd.java:78-145`)

| Request | send | perPkg | window | min | ack? | qtype | Cite |
|---|---|---|---|---|---|---|---|
| P2Reset | 2000 | 1000 | 2000 | - | yes | 0 | `B/dqdbdpd.java:154-160` |
| P2DismissGroup | 2000 | - | 0 | - | no | 0 | `B/qdppdpp.java:212-216` |
| P2Dps | 3000 | - | 5000 | - | no (success at window end) | 2 | `B/dqdpqpq.java:9-15` |
| P2Dps ack | 1000 | - | 1000 | - | yes (DP report) | 2 | `B/pqpbpqd.java:61-68` |
| P2Ping | 2000 | - | 2000 (1 dev) / 5000 | 1000 | yes | 2 | `B/dpdpqpd.java:149-154` |
| P2Pair | 2000 | 2000 | 2000 | - | yes | 0 | `B/pppbpdp.java:249-252` |
| P2Add/RemoveSub | 5000 | - | 5000 | - | yes | 0 | `B/qbqqdqq.java:93-95`, `B/bqpqqbb.java:16-18` |
| Raw | 5000 | - | 0 | - | no | 2 | `B/ddqbbqp.java:159-161` |
| RemoteAction | 6000 | - | 6000 | 1500 | yes | 2 | `B/dpddddp.java:128-132` |
| P1Pair | 5000 | 1200 | 6000 | - | yes | 0 | `B/bbbdqpb.java:14-17` |
| P1Reset | 2000 | - | 2000 | - | timeout = success | 0 | `B/bdpddpb.java:13-15,38-47` |
| P1Dps | 3000 | - | 5000 | - | no | 2 | `B/dpppbdq.java:74-76` |
| P1Ping | min(n*1000+3000, 6000) | - | min(n*1000+6000, 10000) | 1000 | yes | 2 | `B/qbdbdbd.java:139-144` |
| P1Add/Remove | 5000 | - | 5000 | - | yes | 0 | `B/qpqpppd.java:14-16`, `B/qpddppb.java:16-18` |
| P1Dismiss | 2000 | - | 0 | - | no | 0 | `B/ddqdppd.java:11-12` |

Worker semantics (`B/ppbqqdd.java:159-251,71-123`):
- **Single frame:** one advertisement lasting `sendTime` ms. The Android adv timeout is set to that value, or 10000 if <=0 or >20000 (`B/qqdqbpb.java:282-285`).
- **Multi-frame (P1 16-byte payload):** each frame advertises for `perPackage`, repeated `max(1, sendTime/(frames*perPackage))` times, alternating A, B, A, B. P1Pair: 5000/(2*1200) = 2, so A,B,A,B, 1.2 s each.
- **Early stop:** an ack ends the wait early.
- **Ping:** waits at least `min` first.
- The receive window starts when the frame is built and runs `requestTime`. On expiry the result is a "timeout" error if hasResponse, else success (`B/dbbbbqq.java:50-68,115-119`).

Queue (`B/ppbqqdd.java:383-433`):
- A type-0 request cancels queued type-2 requests.
- A type-2 request cancels a queued type-2 request with the same dst, and shrinks the others' windows to their min.
- A running type-2 request is preempted (pings may finish first).

Retries:
- P2Pair: up to 4 rounds (§5.4).
- P1: one sn-resync retry.
- Ping: devices that do not answer a multi-device ping are re-pinged one at a time (`B/qqpdddb.java:251-256,304-323`).
- Normal DP/reset: no automatic retry.

---

## 8. Minimal reimplementation recipe (P2 control of a light)

1. Get from the cloud or a backup: `localKey` (16 ASCII), `beaconKey` (32 hex), `beaconNodeId` (4 hex), group `localId` + `groupKey`, and the phone source id (4 hex).
2. Build the payload, e.g. DP TLVs, with subCmd 0x05 (or 0x06 to request a DP-report ack), type 1, hdr 0x0B.
3. Build the frame as in §3.1. Advertise its 26 bytes as 13 16-bit UUIDs in AD 0x03 (BlueZ: raw adv data `02 01 06 1B 03 <26 bytes>`), connectable, about 20-100 ms interval, for about 1-3 s.
4. Scan for AD 0x03 with 26 bytes from the device:
   - Check dst 8000/8001.
   - Unmask with beaconKey and check the CRC.
   - Decrypt with XXTEA(beaconKey) and check crcP.
   - Parse subCmd 7/9/10/11 DP TLVs.
