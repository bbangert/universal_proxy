> **Analysis notes, not a spec.** Written during the reverse-engineering of Smart Life 7.12.0 and kept for detail
> that `../tuya_beacon_mesh.md` only summarises. `file:line` citations refer to a JADX 1.5.6 decompile of
> `base.apk` (SHA-256 `68b413e9…2e14`) that is not committed here. Some line numbers are known to be off;
> class and method names are reliable. Where these notes and the spec disagree, the spec wins.

> **Correction:** these notes call this family "type 500". That label is wrong.
> In the app, device type 500 (`TYPE_THING_BEACON_MESH`) is what the **P1** scan
> parser assigns, and P2 is type 501. The SIG-provisioned family described here
> comes from the `BeaconMesh*` scan path and has neither type. See §1 of the spec.

# Tuya "Thing Beacon Mesh" (BLEScanDevBean type 500, `config_type_beacon_mesh`) — protocol notes

Source: JADX decompile of Smart Life 7.12.0. All paths are relative to
`src/sources/com/thingclips/sdk/` unless they start with `smart/`. `bt/` = `bluetooth/`.
Every claim has a `file:line` citation. Anything inferred and not read directly in code is marked **UNVERIFIED**.

## 0. Executive summary

* "Beacon mesh" is a **Tuya-specific provisioning (activation) channel** that replaces SIG PB-ADV/PB-GATT
  provisioning. It runs over 16-bit-UUID-list advertisements (AD type 0x03), with a GATT
  helper path through an already-reachable unprovisioned device.
* Activation hands the node a **standard SIG Mesh NetKey, AppKey, IV index and unicast address**
  (`beacon/core/transfer/bdpdqbp.java:437-467`). From then on the node is an ordinary
  **SIG Mesh node in the user's Tuya SIG mesh**. The cloud registers it with the same
  `m.thing.ble.mesh.join` call and options as the normal SIG-mesh activator
  (`bt/qbpqppd.java:618-658` vs `bt/qdqbppp.java:684-690`).
* **Commands/state after activation use standard SIG Mesh.** The app connects to a GATT proxy (service 0x1828,
  Data In 0x2ADD and Data Out 0x2ADE, `bt/ddbbqdb.java:17-19`, `bt/ddbdbqq.java:87-95`)
  and sends SIG network PDUs encrypted with NetKey/AppKey. DPs use the **Tuya vendor model
  0x07D0:0x0004** (`bt/pbqpdbd.java:55` = 131072004 = 0x07D00004), with opcodes 0xC8–0xCE
  plus company ID 0x07D0. Lights additionally use SIG Generic OnOff, Light Lightness, CTL and HSL models.
  No type-500-specific command frame exists. The beacon-mesh scan receiver only parses
  activation and recover responses (`bt/bqpdppq.java:45-79`).
* Before connecting, the SIG-mesh client broadcasts a **"proxy wake-up" frame over the 16-bit-UUID
  channel** (0x70 header, `bt/bdqqqpq.java:161-247`, sent from `bt/ppppqbb.java:216`).
  It is encrypted with AES-CFB, using the NetKey as key and the AppKey as IV.
* The `tbeacon_*` classes (`BeaconMeshBean`, `bt/ppbqqdd.java` "tbeacon_BeaconWorker", `bt/qqdqqpd.java`,
  `bt/dqddqqb.java`) belong to the **older Tuya "Beacon" (v1/v2, config type 400) product family**.
  They are not type 500, so do not mix them up. `ppbqqdd.writeBeaconFrameSync` (`bt/ppbqqdd.java:71-123`) feeds the
  `pbqppbb` "tbeacon_AdvertiseSender". Type 500 uses the `pppppqd` worker and the `qpbqpbq` sender instead.

## 1. Air carrier and frame-type byte

Every 16-bit-UUID-channel frame (both directions) starts with a header byte:
`type = (hdr >> 3) & 0x0F`, `version = hdr & 0x03` (`bt/qdbpqqq.java:36-39`, `bt/dddbppd.java:41`).
On receive, the app takes the AD structure with type 0x03 from the scan record (`bt/dddbppd.java:117-144`).
It requires exactly 26 bytes, with byte 25 = CRC-8 over bytes 0..24 (`bt/dddbppd.java:146-159`).
CRC-8 uses poly 0x07, init 0x00, no reflection (`bt/bppqppq.java:9-26`, identical in `bt/pbpqbbd.java:22-38`).
Identical scan records are de-duplicated with an LRU(100) (`bt/bqpdppq.java:53-54`).

| hdr byte | type | dir | meaning | source |
|---|---|---|---|---|
| 0x40 \| ver | 8 | dev→ | unprovisioned advert | `bt/qdbpqqq.java:38` |
| 0x48 | 9 | phone→ | activation req, legacy, part 1 | `beacon/core/transfer/bdpdqbp.java:530` |
| 0x50 | 10 | phone→ | activation req, legacy, part 2 | same |
| 0x58 | 11 | dev→ | activation response | `bt/dddbppd.java:23-25` |
| 0x60 | 12 | phone→ | recover req (byte7=0x01) / reset req (byte7=0x00) | `bt/bqbdpqd.java:90-92`, `bt/ddbdpqb.java:351-353` |
| 0x60 | 12 | dev→ | recover response | `bt/qqpbpdq.java:21-23` |
| 0x68 | 13 | phone→ | activation req, extended adv / proxy (50 B) | `beacon/core/transfer/bdpdqbp.java:332` |
| 0x70 | 14 | phone→ | SIG-mesh proxy wake-up | `bt/bdqqqpq.java:215` |

AES used everywhere below is `AES/CFB/NoPadding` (CFB128, no padding) (`bt/pdqppqb.java:16-30`).

## 2. Activation flow (ThingBeaconMeshActivatorImpl and friends)

### 2.1 Discovery and "auth"/encryptValue
* Unprovisioned adverts are parsed in `bt/bqdbdbd.java:53-67` / `bt/qdbpqqq.java:29-63` (26-byte layout already established).
  Each parsed advert goes into `BeaconMeshScanCache` and **also into the pre-request manager**
  (`bt/bqdbdbd.java:60-64`).
* **`auth` = `encryptValue` is the 4-byte field at advert offset 19..22, copied verbatim**
  (`bt/qdbpqqq.java:47-52`, `searchDeviceBean.setAuth(hex(bArr5))`). It goes to the cloud unchanged as
  `encryptValue` (`beaconmesh/bean/BeaconMeshPairKeyGetInfo.java:11-15`, `bt/qbpqppd.java:527`).
  The app never computes or checks it. **UNVERIFIED**: on the device it is presumably a MAC/HMAC over
  deviceRand keyed by a per-device secret that the cloud verifies before releasing `pairKey`. Nothing in the app shows this.
* "Generation" of a device = `MAC|auth|deviceRand` (`beacon/core/transfer/BeaconMeshScanCache.java:58-60`).
  If deviceRand changes, the cached pairKey becomes invalid. The request then fails with `DEVICE_RAND_CHANGED`
  (`beacon/core/transfer/bdpdqbp.java:415-435`) and gets requeued, at most 3 times per MAC (`bt/bppppdb.java:31,172-205`).

### 2.2 Pre-request (BeaconMeshPreReqManager, `bt/bpbqpqd.java`)
* This runs only when the user has exactly one SIG mesh (`bt/bpbqpqd.java:138-143`).
* Each scanned device without cached creds goes onto a wait list. When the list reaches **≥10 devices**
  it calls `m.thing.device.pair.key.batch.get` v2.0 (`bt/bpbqpqd.java:159-160,177-199`).
* The result goes into the cache as `meshId|MAC|auth|rand → nodeId, pairKey` (`bt/bpbqpqd.java:63-89`).
  The activator uses this cache if every device in the batch hits it (`bt/qbpqppd.java:325-369, 746-748`).

### 2.3 Cloud APIs (`bt/ppbbqbb.java`)
| API | ver | params | response | cite |
|---|---|---|---|---|
| `m.thing.device.pair.key.batch.get` | 2.0 | `number`=N, `meshId`, `data`=JSON `[{mac,deviceRandom,encryptValue}]` | `{pairKeyBatchVOList:[{mac,pairKey,errorCode,success}], nodeIds:[int,…]}` (nodeIds in request order) | `:197-204`; parse `bt/qbpqppd.java:109-131` |
| `m.thing.device.pair.key.get` | 1.0 | `mac`,`deviceRandom`,`encryptValue` | pairKey (single) | `:188-195` |
| `m.thing.device.pair.key.batch.get` | 1.0 | `data` | – | `:206-211` |
| `m.thing.device.group.common.local.id.alloc` | 1.0 | `parentId`=meshId, `type`=3, `num` | JSON array of hex strings (local IDs) | `:238-245`; call `bt/qbpqppd.java:546` |
| `m.thing.ble.mesh.join` | 3.1 | meshId, nodeId, productKey, uuid, devKey, mac, options, ver, modules | DeviceBean | `bt/qbdpdpp.java:28,185-198` |
| `thing.m.sig.ir.local.id.relation.save` | 1.0 | devId, localId | bool | `bt/ppbbqbb.java:340-346`, `bt/bppppqp.java:10` |
| `thing.m.sig.mesh.iv.index.report` | 1.0 | meshId, ivIndex | bool | `bt/ppbbqbb.java:365-369`, `bt/qbdpdpp.java:25,204-207` |
| `thing.m.sig.mesh.source.id.alloc` | 1.0 | meshId | phone's provisioner unicast | `bt/ppbbqbb.java:41,271-274` |

* **The node ID (unicast) is allocated by the cloud** inside the batch pair-key response (`nodeIds`), not by the phone.
  It is checked for count equality (`bt/qbpqppd.java:112-116`).
* **pairKey** is a hex string that the app hex-decodes into the 16-byte AES key (`beacon/core/transfer/bdpdqbp.java:371`).

### 2.4 Ordered steps (`bt/qbpqppd.java`, orchestrated by `bt/bppppdb.java` "MeshActivateManager")
1. `bppppdb.pollTask` takes up to **10** beacon-mesh devices per batch (`bt/bppppdb.java:399`).
   With ≥5 queued and no proxy connected, the first device becomes the **GATT helper ("proxy")**
   (`bt/bppppdb.java:385-397`). The app connects to it first (`bt/bppppdb.java:268-273`).
   Devices without auth/rand go to the normal SIG-mesh activator `pbbpdqp` (`bt/bppppdb.java:247-251, 375-383`).
2. `startActivator`: refresh each device from the scan cache (newest rand). Then either use the pre-req cache
   or call `getNodeIdAndKey` (batch API) (`bt/qbpqppd.java:719-753`).
3. For every device with `success && pairKey`: commit the credential to the scan cache, frozen per generation
   (`bt/qbpqppd.java:140-149`).
4. If category bit0 ("needs publish address") is set, allocate local IDs with
   `group.common.local.id.alloc(type=3)`. **pubAddress = localId + 0x4000** (`bt/qbpqppd.java:538-548, 672-679`).
   **UNVERIFIED**: local IDs are 0x8000-range, which would make pubAddress a 0xC000-range SIG group address.
5. For each device, `dqbpdbq.pdqppqb()` → `sendActivateData` (`bt/dqbpdbq.java:74-118`):
   * If the device advertises category bit1 (recover) **and** the cloud already has a device with this
     MAC in this mesh, send **RecoverRequest** first (`bt/dqbpdbq.java:58-72, 102-105`).
     If recover fails with anything other than cancel or rand-changed, it falls back to normal activation (`bt/dqbpdbq.java:31-44`).
   * If the GATT helper is connected, send through it with requestTime 3000 ms (`bt/dqbpdbq.java:110-114`).
     Otherwise use phone advertising (`bt/dqbpdbq.java:116-117`).
6. Activation response (type 11) arrives. It must match the MAC and the unicast as hex of 2 BE bytes
   (`beacon/core/transfer/bdpdqbp.java:99-119`). The pubAddress gets attached (`:114`).
7. `startJoin` (`bt/qbpqppd.java:599-659`) → `IThingBlueMesh.addSubDev` → `m.thing.ble.mesh.join`, with:
   * `uuid`=MAC, `mac`=MAC, `nodeId`=unicast hex from response, `ver`="fwMajor.fwMinor",
     `productKey`= 8-byte productId as a string (`bt/qbpbbpq.java:62-67`), **`devKey` = ""** (`bt/qbpqppd.java:656`).
   * `options` JSON (`bt/qbpqppd.java:619-653`):
     `isFK` = meshCategoryExt[1]&1; `companyId`="07d0"; `vendorId`="07d0"; `meshCategory`; `meshCategoryExt`;
     `targetOwnerId`=homeId; `serviceLayerData`={"pubAddress": "%04x" of (pubAddress−0x4000)};
     `otaGroupUpgradeEnable` = (meshCategoryExt[0]>>6)&1.
   * `modules` = `[{type:9, softVer:<mcuVersion>}]` when an MCU version is present (`bt/qbpqppd.java:630-636`;
     key name `softVer` from `hardware/qbpppdb.java:98`).
   * 30 s join watchdog (`bt/qbpqppd.java:47, 293-299, 253-271`).
8. On join success: if the server did not already bind it (`z==false`), save the local ID through
   `thing.m.sig.ir.local.id.relation.save` (`bt/qbpqppd.java:799-811, 487-495, 591-596`).
   Then `onSuccess` and analytics events (`bt/qbpqppd.java:427-462`). Recover success skips the join and reuses the
   existing cloud DeviceBean (`bt/qbpqppd.java:188-190`, `bt/bqbdpqd.java:97-118`).
9. Devices that fail with `CloudError_*` get a **reset frame** through the helper, staggered 300 ms apart
   (`bt/bppppdb.java:207-228, 330-332, 164-170`). On `stopActivator` the app disconnects the helper
   and restarts the SIG-mesh client (`bt/bppppdb.java:448-453`).

### 2.5 Timing (phone-advertising path)
| knob | value | cite |
|---|---|---|
| per-frame time when frames alternate (no multi-adv) | 600 ms | `beacon/core/transfer/bdpdqbp.java:92`, loop `bt/pppppqd.java:167-193` |
| total send time | 6000 ms (both frames at once if multi-adv; alternating 600 ms ×5 rounds otherwise) | `beacon/core/transfer/bdpdqbp.java:93`, `bt/pppppqd.java:172-176, 194-201` |
| receive window (request timeout) | 8000 ms (`bpddddq.ppdpppq`) | `beacon/core/transfer/bdpdqbp.java:94`, `bt/bpddddq.java:17`, `bt/bbqqdbq.java:94-123` |
| proxy-path receive window | 3000 ms | `bt/dqbpdbq.java:111`, `bt/ddbdpqb.java:306-318` |
| ext-adv used when | device category bit2, Android ≥ 8, `isLeExtendedAdvertisingSupported`, max adv len ≥ 50 | `beacon/core/transfer/bdpdqbp.java:225-244` |
| cloud-join watchdog | 30 000 ms | `bt/qbpqppd.java:47` |
| retries | none per frame. Timeout → `TIMEOUT` error (`beacon/core/transfer/bdpdqbp.java:130-135`). Rand-changed requeue ≤3. recover→normal fallback | as above |
| scanner keep-alive after window | +10 s duration, stop 5 s after last window | `bt/bqpdppq.java:201-217, 232-239` |

### 2.6 Frame layouts (phone → device)

**Activation plaintext P44** (`beacon/core/transfer/bdpdqbp.java:437-467`), confirmed as established:

| off | len | field |
|---|---|---|
| 0 | 16 | NetKey |
| 16 | 16 | AppKey |
| 32 | 1 | 0x00 (**UNVERIFIED** meaning; analogous to SIG provisioning "flags") |
| 33 | 4 | IV index, BE (`bt/qbqqpbb.java:198-200`) |
| 37 | 2 | unicast, BE (`bt/qbqqpbb.java:325-327`) |
| 39 | 2 | publish address BE, or 00 00 when category bit0 = 0 (`:87-91`) |
| 41 | 2 | 00 00 |
| 43 | 1 | CRC-8 over bytes 0..42 |

The ciphertext is `AES-CFB(key=pairKey, IV=deviceRand(4)||0^12)` (`:367-371`).
Legacy frames: `0x48 | MAC[3..5] | C[0..21]` and `0x50 | MAC[3..5] | C[22..43]` (`:246-272, 517-550`).

**Extended / proxy 50-byte frame** (`beacon/core/transfer/bdpdqbp.java:137-223, 314-336`):
`0x68 | MAC(6) | AES-CFB(pairKey, rand||0^12)( P43 )`, where
`P43 = 0x00 | NetKey | AppKey | 0x00 | IV(4) | unicast(2) | pub(2) | CRC8(over the preceding 42 bytes)`.
This layout has a leading 0x00 and no trailing 00 00.

**Recover request** (`bt/bqbdpqd.java:68-95, 120-170`): 26 B =
`0x60 | MAC(6) | 0x01 | AES-CFB(pairKey, rand||0^12)( nodeId(2, from cloud DeviceBean.nodeId hex) | NID(1) | 0^14 | CRC8 )`.
NID = SIG k2(NetKey, P=0x00).NID (`bt/bqbdpqd.java:132`, `sigmesh/util/SecureUtils.java:30,205`).

**Reset request** (`bt/ddbdpqb.java:330-356, 406-517`): 26 B =
`0x60 | MAC(6) | 0x00 | AES-CFB(pairKey, rand||0^12)( unicast(2) | netAuth(3) | 0^12 | CRC8 )`,
with `netAuth = SHA-256( lowercase(hex(NetKey)+hex(AppKey)) as ASCII )[0..2]` (`bt/ddbdpqb.java:440-450`).
**UNVERIFIED**: that the 3-byte `netAuth` in the activation response is computed the same way.
The app never checks the response's netAuth.

### 2.7 Device → phone responses
**Activation response, type 11** (`bt/dddbppd.java:27-111`), confirmed: `0x58 | MAC(6) | E(18) | CRC8`.
Decrypt E with AES-CFB(pairKey, rand||0^12) to get:

| off | len | field (ddqqbbq getter) |
|---|---|---|
| 0 | 2 | meshCategory (`bppdpdq()`) |
| 2 | 2 | meshCategoryExt (`qddqppb()`): [0] bit6 = OTA group upgrade; [1] bit0 = isFK, bit1 and bit3 feature flags (`bt/dpqpppd.java:24-34`) |
| 4 | 1+1 | fw major, minor → `ver` |
| 6 | 2 | unicast, BE (`qpppdqb()`) |
| 8 | 3 | netAuth |
| 11 | 2 | MCU version: 5 bits major, 5 bits minor, 6 bits patch (`:94-96`); 0.0.0 means absent |
| 13 | 5 | unused / **UNVERIFIED** |

**Recover response, type 12** (`bt/qqpbpdq.java:25-88`): `0x60 | MAC(6) | cmd(1) | E(18)` with a CRC check over 25 bytes.
Decrypted byte 0 == 0x00 means success.

### 2.8 Proxy (GATT-helper) path — `BeaconMeshProxySender` (`bt/ddbdpqb.java`), `beaconMesh_ProxyDeviceActions` (`bt/pppbbbb.java`)
* The helper is an **unprovisioned beacon-mesh device** reached over Tuya BLE GATT. It is not a SIG proxy.
  It uses service **0xFD50**, write char `00000001-0000-1001-8001-00805F9B07D0`,
  and notify char `00000002-0000-1001-8001-00805F9B07D0` (`bt/pppbbbb.java:193-204`). MTU requested is 247 (`:220`).
  Connect timeouts are 8/10/16 s with 3 retries and service discovery at 3 s ×3 (`:281`).
* Write = one Tuya-BLE "X2" frame (`bt/pppbbbb.java:248-267`, `bt/bpbpddd.java:110-118`):
  * Inner: `sn(4 BE) | ack_sn(4)=0 | code(2)=0x801B | len(2) | data | CRC16(2 BE)`.
    CRC16 is MODBUS: init 0xFFFF, reflected poly 0xA001 (`bt/pbqpqdp.java:161-174`, `bt/bppqppq.java:28-41`).
    sn starts at 2 and increments (`bt/pppbbbb.java:42,265`).
  * Security flag 0, so the inner frame is prefixed with 0x00 and not encrypted (`bt/pbqpqdp.java:15-24`; `getSecretKey` returns null, `bt/pppbbbb.java:273-276`).
  * Fragmenting (`bt/ppbpdqd.java:7-30`): each fragment = `varint(fragIdx)`. The first fragment also carries
    `varint(totalLen) | 0x20` (protocol version 2 << 4). Only fragment [0] is written, so the whole thing must fit in MTU-3.
* `data` (`bt/ddbdpqb.java:519-535`):

| off | len | value |
|---|---|---|
| 0 | 2 | 00 00 |
| 2 | 2 | 90 00 (**UNVERIFIED** semantics, "sub-command") |
| 4 | 2 | 00 00 |
| 6 | 2 | 00 00 |
| 8 | 2 | 00 00 |
| 10 | 1 | 01 |
| 11 | 1 | payload len |
| 12 | n | payload: 50-byte 0x68 ext frame (activation) or 26-byte 0x60 frame (recover/reset) (`:387-404`) |

* Response: notify with Tuya code **0x801C** (32796) → `GetDevDataRep.result` (`bt/pppbbbb.java:130-145`).
  `result = hdr(2) | len(1) | 26-byte type-11 or type-12 frame`, parsed **without** the CRC check
  (`bt/ddbdpqb.java:160-220`). **UNVERIFIED**: hdr(2) = flag + subCmd (`bt/qbqppdb.java:36` toString).
  The response may also arrive as an advertisement, because a scan receive window is registered too (`bt/dqdbqdd.java:91-112`).

## 3. Command path after activation (THE answer to Q2)

**There is no type-500-specific control channel. Control is standard SIG Mesh with Tuya vendor-model payloads.**

### 3.1 Bearer
* The SIG-mesh client scans for service **0x1828** and connects (`bt/bdbqpbb.java:36,128`, "thingmesh_SigMeshConnectModule").
  It writes proxy PDUs to **0x2ADD** (`bt/ddbdbqq.java:87-95`) with SIG proxy SAR
  (first|0x40, cont|0x80, last|0xC0) (`bt/ddbdbqq.java:60-85`).
* Notifications on 0x2ADE: proxy type 0 = Network PDU, type 1 = Secure Network Beacon (`bt/qqpqpqd.java:664-697`).
* Before connecting, `startClient` sends the wake-up frame (§3.5) (`bt/ppppqbb.java:212-226`).
  It is also sent before OTA (`bt/ppqqqbp.java:446`).
* **No AD type 0x2A (ADV bearer) transmit path exists.** The only advertisers are the 16-bit-UUID
  senders (`bt/qpbqpbq.java`, `bt/pbqppbb.java`), and the SIG pre-control sender (§3.6).

### 3.2 Network/transport
* This is a full SIG Mesh stack (an nRF-Mesh-style port: `AccessMessage`, `ControlMessage`, `SecureUtils` k2/k4).
* Access PDU = opcode bytes + params (`bt/bpbbqdb.java:49-68`). Vendor opcode encoding is
  `[(op & 0x3F) | 0xC0, company & 0xFF, company >> 8]`, so for Tuya it is `xx D0 07` (`bt/qbqqpbb.java:541-546`).
* App key AKF=1. AID = k4(AppKey) (`bt/pqbbbpq.java:54`, `SecureUtils.qddqppb`).
* Default **TTL = 8** (`sigmesh/bean/Message.java:25`).
* SEQ is one per-mesh 24-bit counter that wraps to 1 above 0xFFFFFF (`sigmesh/bean/MeshTransferBean.java:43-50`).
  It is restored from storage **+1000** at connect (`bt/qqpqpqd.java:212`).
  The **TID uses the same counter** (`bt/dpqdqbp.java:47-53`).
* SRC = the phone's provisioner address, from the cloud `thing.m.sig.mesh.source.id.alloc` and persisted as `sig_mesh_address` (`bt/ppdddqb.java:20`).
* IV index is applied with `dpqdqbp.bdpdqbp(meshId, iv)` (`bt/dpqdqbp.java:209-217`).

### 3.3 DP write (Tuya vendor model 0x07D0:0004)
Model ID 0x07D00004 (`bt/pbqpdbd.java:55`). The model is chosen per category from the 4-hex "pcc"
(`bt/bbqqpqb.java:33-41`):
* 3rd char == '2' → vendor DP parser `bbpppdq`
* leading "01" → light parser (SIG models)
* leading "02" → switch/electrician parser `bpbbqqp` (Generic OnOff per element)
* anything else → light parser.
**UNVERIFIED**: that DeviceBean.category equals the meshCategory reported at activation.

| opcode (1st byte) | bytes on air | meaning | params | cite |
|---|---|---|---|---|
| 0xC9 | C9 D0 07 | DP set, acked (status 0xCD) | `01 \| dpRec…` | `bt/qpbddpb.java:14-16,119,130` |
| 0xCA | CA D0 07 | DP set, unacked | same | `bt/pbbpdbb.java:9` |
| 0xC8 | C8 D0 07 | DP set with TID (status 0xCB `tid,status`) | `tid(1) \| 01 \| dpRec…` | `bt/bqddpdq.java:17-18,127-146`, `sigmesh/provisioner/ThingVendorTidModelStatus.java` |
| 0xCC | CC D0 07 | DP query (→0xCD) | `(05 if "z" else 01) \| count \| dpId…` | `bt/bdbpppd.java:17,54` |
| 0xCD | CD D0 07 | dev→ report/status | `cmdType \| …` | `bt/bpbdbdb.java:79-125` |
| 0xCE | CE D0 07 | dev→ TID report | – | `bt/bpbdbdb.java:85-88` |

The TID form (0xC8) is used only when the device flag `dpqpppd.pdqppqb` is set and the DP record payload is longer than 8 bytes
(`sigmesh/parse/ThingSigMeshParser.java:281-295`). The flag requires a MAC prefix DC23/DC24/BC23
and meshCategoryExt[1] bit3 (`bt/dpqpppd.java:24-28`, `bt/qqqdqdb.java:8-14`).

**dpRec** encoding (`bt/qpbddpb.java:54-122`). Note that there is **no length byte for bool, value or enum**:

| DP type | type byte | layout |
|---|---|---|
| raw | 0x00 | `dpId \| 00 \| len \| bytes` |
| bool | 0x01 | `dpId \| 01 \| 00/01` |
| value | 0x02 | `dpId \| 02 \| int32 BE` |
| string | 0x03 | `dpId \| 03 \| len \| utf8` |
| enum | 0x04 | `dpId \| 04 \| index(1)` |
| bitmap | 0x05 | `dpId \| 05 \| len(1/2/4) \| value BE` |

Example: switch dp1=on, acked, to node 0x0005 → access PDU `C9 D0 07 01 01 01 01`.

### 3.4 Lights (SIG models, `sigmesh/parse/bdpdqbp.java`)
* `switch_led`/`switch_N` → Generic OnOff Set 0x8202 / Unack 0x8203 with `onoff, tid`. dst = node + element index.
  Get 0x8201, Status 0x8204 (`bt/pdbbpqd.java`, `bt/dbbpbbq.java`, `sigmesh/parse/ThingSigMeshParser.java` map).
* `bright_value` → Light Lightness Set 0x824C / Unack 0x824D, params `lightness LE16, tid`,
  with lightness = ceil(v/max·65535) clamped to 1..65535 (`sigmesh/parse/bdpdqbp.java:388-405`, `bt/dddddpb.java:34-48`).
* `temp_value` → 0x8264 / 0x8265 (CTL Temperature), temp = 800 + scaled·19200, clamped to 800..20000 (`sigmesh/parse/bdpdqbp.java:230-246`).
* `colour_data` (HHHHSSSSVVVV) → HSL Set 0x8276 / Unack 0x8277 (`:247-282`).
* `work_mode` → vendor 0xC9/0xCA with a single byte: white 0, colour 1, scene 2, music 3 (`bt/dpbdbpq.java`, `bt/bpqbqdd.java`).

### 3.5 Proxy wake-up frame (`getProxyWakeUpBeaconData`, `bt/bdqqqpq.java:161-247`)
26 bytes in AD 0x03: `0x70 | FF FE FF FF FF FF | AES-CFB(key=NetKey, IV=AppKey)( P19 )`. P19 is:

| off | len | field |
|---|---|---|
| 0 | 1 | 0x00 |
| 1 | 2 | phone SRC address BE (`sig_mesh_address`, `bt/qpdbpbd.java:169-171`) |
| 3 | 4 | seq BE = stored `sig_mesh_seq_proxy` + 1 (`bt/bqddbqd.java:48-58`, `bt/ppdddqb.java:25`) |
| 7 | 2 | 00 14 (**UNVERIFIED**: 20 = wake seconds) |
| 9 | 9 | zeros |
| 18 | 1 | CRC-8 over bytes 0..17 |

* The frame is advertised for 20 000 ms (`bt/bdqqqpq.java:133`). The seq is persisted on success (`:75`).
* Re-send is suppressed for 20 s after a successful send, 3 s if another frame pre-empted it, and 1 s if the send did not succeed (`:150-159, 117-123`).
* The SIG-mesh client stops it on connect, error or timeout (`bt/ppppqbb.java:105-126, 188`).

### 3.6 Pre-activation identify (flash/on/off) — `MeshAdvPreControl`
For type-500 scan results, `ThingBleBeaconPreCtrl` routes to `pqddpqp` (`ble/core/prectrl/ThingBleBeaconPreCtrl.java:53-66`).
`pqddpqp` calls `bbbdbqb` and `ppbbbpd`, and the frame goes out as 16-bit UUIDs (`bt/pbqppbb.java` type 1). The 26-byte frame (`bt/ppbbbpd.java:13-52`) is:
`MAC(6) | sn(2 BE, random) | cmd(1)=1 | XXTEA_BE(key=07D01433A954A460AD1689E6594F07DA)( P16 ) | sum8`, where:
* `P16` = 12 bytes `0x012345678998765432102314`, with the params overwriting the start, then `| MAC[5] | sn(2) | cmd`.
* `sum8` = (Σmac + Σenc + Σsn + cmd) mod 256.
* Params are on `01 00`, off `00 00`, toggle `02 00`, flash `03 n` (`bt/pqddpqp.java`, flash/on/off/reverse).
* XXTEA uses delta 0x9E3779B9 with big-endian word packing (`bt/dddpbpd.java:38-84`).
**UNVERIFIED**: whether type-500 firmware honours this. The cipher came from the SIG-mesh path.

## 4. Status receive path (Q3)
1. GATT 0x2ADE notify → proxy SAR reassembly → `qqpqpqd.bdpdqbp(byte[])` (`bt/qqpqpqd.java:664-697`).
2. Network decrypt with NetKey and IV, then lower/upper transport (AppKey) in `pqbbbbd`/`dbbqppd` (`bt/dbbqppd.java:455-500`).
3. Dispatch in `bt/bpbdbdb.java:64-130`:
   * Vendor opcode 0xCD with cmdType 1 or 5 → `ThingVendorModelStatus` (DP report, same dpRec format; type sizes in `sigmesh/provisioner/ThingVendorModelStatus.java:100-` and the parse at `:117`).
   * cmdType 2 → time request, 3 → DST request, 7 → proxy-set status, 0x80 → heartbeat (dp on/off), 0x82 → group list, 0x90 → fittings.
   * 0xCB → TID ack. 0xCE → TID report.
   * SIG statuses: 0x8204 OnOff, 0x824E Lightness, CTL, HSL and others.
4. `bbqqpqb.bdpdqbp(status, meshId)` picks the parser and turns the result into a dps JSON. The node is found with `src & 0xFFF8`, the element = `src & 7`
   (`bt/bbpppdq.java:79-128`, `sigmesh/parse/ThingSigMeshParser.java` GenericOnOff branch). The parser updates the DP cache and listeners (`bt/qqpqpqd.java:705-712`).
* Beacon-mesh adverts (types 11/12) are parsed only during activation receive windows (`bt/bqpdppq.java:45-79`).
  Other matches only refresh the scan cache (`bt/qdbpqqq.java:15-27`).

## 5. Relay, TTL, SEQ, IV, groups (Q4)
* **TTL**: 8 by default for outgoing messages (`sigmesh/bean/Message.java:25`). Publication default is 127 (`sigmesh/util/PublicationSettings.java:15`).
* **SEQ**: see §3.2. The wake-up frame has its own `sig_mesh_seq_proxy` counter (`bt/ppdddqb.java:25`).
* **IV index**:
  * Initial IV comes from SigMeshBean (cloud) and is put into the activation plaintext (`beacon/core/transfer/bdpdqbp.java:70`).
  * At runtime, a Secure Network Beacon received through the proxy updates the local IV (`bt/qqpqpqd.java:673-675, 700-703`).
  * If newIV > stored and newIV − stored < 42, the app reports `thing.m.sig.mesh.iv.index.report(meshId, ivIndex)` (`bt/qqpqpqd.java:676-679, 559-563`).
  * The app never initiates an IV update itself. **UNVERIFIED** (not found).
* **Relay**: there is no app-side relay config for type 500. A `RELAY_PROXY_TIMEOUT` exists in `bt/bbbddqb.java:35`, but no relay-set message was found for beacon mesh. **UNVERIFIED**.
* **Groups**:
  * Adding a device sends Config Model Subscription Add (0x801B) **with the DevKey**, for SIG models 0x1000/0x1300/0x1306/0x1307/0x1303 plus vendor 0x07D00004 (lights), or vendor + 0x1000 per element (switches) (`bt/pdbppbd.java:805-830`).
  * The group address is the group's cloud localId (`thing.m.device.ble.mesh.local.id.alloc`, `bt/ppbbqbb.java:247-251`).
  * **Caveat**: activation registers `devKey=""` (`bt/qbpqppd.java:656`), and group add fails with "10203 Invalid device" when devKey is empty (`bt/pdbppbd.java:777-782`).
    **UNVERIFIED** whether the cloud assigns or derives a DevKey for type-500 nodes. Without one, SIG config messages cannot be built.
  * Category bit0 devices (remotes/switches) instead get a **publish address** (0xC000 range, §2.4 step 4) baked in at activation.

## 6. Reimplementation checklist (Linux/BlueZ)
1. Scan AD 0x03 and parse type-8 adverts. Get pairKey and nodeId from the cloud (needs a Tuya session).
2. Advertise 0x48/0x50 frames as 16-bit UUID lists (or 0x68 extended). Listen up to 8 s for type 11 and decrypt it.
3. Register with `m.thing.ble.mesh.join` (v3.1).
4. Control: act as a standard SIG Mesh proxy client on 0x1828, using the NetKey, AppKey, IV, an allocated SRC, and a persisted SEQ.
   Optionally send the 0x70 wake-up advert first.
5. Send vendor `C9 D0 07 01 <dpRec>` to the unicast address. Parse `CD D0 07 01 <dpRec…>` reports.
