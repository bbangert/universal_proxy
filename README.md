# Universal Proxy

A Nerves-based firmware that turns a Raspberry Pi (or other supported board) into
a **universal serial proxy** for [Home Assistant](https://www.home-assistant.io/).

The device appears as a native [ESPHome](https://esphome.io/) device on the
network, advertising itself over mDNS. USB serial adapters plugged into the board
are exposed to Home Assistant as **serial proxies** through the ESPHome Native
API. Home Assistant can then open, configure, and stream data from those serial
ports exactly as it would with an ESPHome device that has a built-in UART.

Additionally, the [Home Assistant Connect ZWA-2](https://www.home-assistant.io/connect/zwa-2/) USB Z-Wave
controller is supported as a **Z-Wave proxy**. The proxy speaks the Z-Wave
Serial API protocol locally, handling latency-sensitive ACK/NAK/CAN responses at
the device while forwarding complete frames to Home Assistant over the network.

The device also acts as a **Bluetooth proxy**: it relays nearby Bluetooth Low
Energy advertisements to Home Assistant over the ESPHome Native API (the same
model as ESPHome's `bluetooth_proxy` component), with optional active
connections so Home Assistant can reach BLE sensors, trackers, and locks that
are out of range of its own radio. On boards with more than one Bluetooth radio
(the onboard SoC radio plus any USB adapters), the bound radio is selectable
from the web UI.

This is useful for connecting RS-232, RS-485, TTL serial, or Z-Wave devices to
Home Assistant over the network -- and for extending Home Assistant's Bluetooth
range -- without needing a dedicated ESPHome microcontroller for each one.

## Features

- Speaks the ESPHome Native API (protobuf over TCP on port 6053)
- Automatic mDNS advertisement -- discovered by Home Assistant like any ESPHome device
- Serial proxy for TTL, RS-232, and RS-485 USB adapters
- Z-Wave proxy for USB Z-Wave controllers with local ACK handling
- Zigbee via the [Home Assistant Connect ZBT-2](https://www.home-assistant.io/connect/zbt-2/)
  over the ESPHome serial proxy -- Home Assistant discovers it by its USB
  identity and runs ZHA in PROTOCOL mode, with the EZSP/ASH ACKs sent locally on
  the device; the tty stays open across sessions so firmware updates
  (universal-silabs-flasher) work too. Host-tested and build-validated only, not
  yet tested on real hardware.
- **Tuya Bluetooth mesh lights** -- control Tuya "Beacon" (advertisement-mesh)
  bulbs and their groups from Home Assistant through a dedicated Bluetooth
  adapter, one HA light per bulb and group (see
  [Tuya Bluetooth mesh lights](#tuya-bluetooth-mesh-lights))
- Auto-detection for IRDroid / IR Toy USB infrared devices (VID `0x04D8`, PID `0xFD08`/`0xF58B`)
- **Bluetooth proxy** -- relays BLE advertisements to Home Assistant over the
  ESPHome Native API (passive scanning plus optional active GATT connections),
  driven by the on-device BlueZ stack. The web UI shows live stats and lets you
  pick which radio (onboard or USB) is bound. Works on every custom-system
  target -- the onboard-BT Pis plus USB BT dongles on `rpi`/`rpi2`/`x86_64`.
- **Sendspin audio playback** -- on the Raspberry Pi targets, each ALSA output
  (the onboard jack/HDMI plus hot-plugged **USB DACs**) is exposed as an
  independently discoverable [Sendspin](https://github.com/Sendspin/sendspin-cpp)
  player for synchronized multi-room audio with
  [Music Assistant](https://www.music-assistant.io/). USB sound cards appear in
  their physical USB slot in the web UI. See
  [Sendspin audio](#sendspin-audio).
- **Sendspin audio input** -- a USB capture card (line-in) becomes a Sendspin
  source that Music Assistant can pair with and play from (see
  [Sendspin audio](#sendspin-audio))
- **Bluetooth speakers and headphones** -- on `rpi4`, `rpi5` and `x86_64`, a
  radio set to the Audio role on the **Bluetooth** tab pairs A2DP speakers and
  headsets, which then play as Sendspin outputs
- **HDMI-CEC receiver control** -- on `rpi0_2`, `rpi3`, `rpi4` and `rpi5`, the
  Pi is a CEC playback device on each HDMI port (native `/dev/cecN` access via
  the in-repo `circuits_cec` library, no `cec-ctl`). A Sendspin stream starting
  on an HDMI output sends One Touch Play, so an AV receiver (or TV) in standby
  wakes and switches to the Pi's input first, and the output's volume and mute
  can follow the receiver's. Both are per-output toggles on the **Audio** tab.
  `UniversalProxy.Cec` also exposes standby, power/volume status and
  volume/mute key presses from IEx.
- **TV screen** -- on the same four boards the Pi's HDMI output shows a
  now-playing screen (artwork, track, progress, a visualizer) for the HDMI
  output's player, driven by the TV remote over HDMI-CEC and by a
  **TV display mode** select in Home Assistant (see
  [TV screen (HDMI)](#tv-screen-hdmi))
- **MilkDrop visualizer** -- on `rpi3`, `rpi4` and `rpi5`, music playing to
  the HDMI output can drive full-screen [projectM](https://github.com/projectM-visualizer/projectm)
  (MilkDrop) presets on the TV, with a preset browser and preset uploads in
  the web UI (see [MilkDrop visualizer (HDMI)](#milkdrop-visualizer-hdmi))
- **Bluetooth-audio transmitter control** -- FlooGoo FMA120 and Sennheiser
  BTD 700 dongles get full control drawers in the web UI (see
  [Supported USB devices](#supported-usb-devices))
- **USB backup drive** -- share a plugged-in USB drive over SMB as a
  Home Assistant network **backup target**, managed from the Overview drawer
  (see [Using a USB drive for Home Assistant backups](#using-a-usb-drive-for-home-assistant-backups))
- Device sensors, Reboot / Factory reset buttons and a firmware **update**
  entity in Home Assistant
- Wi-Fi setup over Bluetooth ([Improv](https://www.improv-wifi.com/)) when a
  Bluetooth target boots with no network
- Web UI for configuration (accessible at `http://<device-ip>`)
- USB hotplug detection -- plug/unplug serial adapters at any time
- DETS-backed persistent device configuration across reboots
- Graceful handling of unexpected USB disconnects during active sessions

## Supported USB devices

Everything below is hot-pluggable: devices are detected on insert, appear
on the web UI's Overview, and clean up on removal. On the Raspberry Pi 3 B+
and Pi 4 the Overview draws the board's four USB-A ports and shows each
device at its physical slot (devices behind a hub render as a tree under it);
on other boards connected devices are simply listed. Per-device settings
persist across reboots and replugs.

| Device / class | Examples | Capabilities |
|---|---|---|
| **Serial adapters** (TTL, RS-232, RS-485) | FTDI FT232R/FT232H/FT2232H/FT231X, Silicon Labs CP2102/CP2105, WCH CH340/CH9102, Prolific PL2303 | Exposed to Home Assistant as ESPHome **serial proxies**. Line settings (baud/framing) are remembered per port and served back to reconnecting clients; the port type (TTL / RS-232 / RS-485) is editable on the Overview. |
| **Z-Wave controllers** | Home Assistant Connect ZWA-2, Aeotec Z-Stick Gen5+ | **Z-Wave proxy**: the latency-sensitive Serial API ACK/NAK/CAN handshake runs locally on the device while complete frames stream to Home Assistant. |
| **Zigbee coordinators** | Home Assistant Connect ZBT-2 | Exposed as a USB serial proxy with its USB identity, so Home Assistant discovers it and runs ZHA over it; ASH ACKs are sent locally (PROTOCOL mode). Host-tested only, not yet validated on hardware. |
| **Infrared transceivers** | IRdroid IR Toy | Auto-detected and exposed to Home Assistant as **Infrared** entities for IR send/receive. |
| **Bluetooth (HCI) adapters** | Any `btusb`-supported dongle | Selectable radio for the **Bluetooth proxy** (BLE advertisement relay + active GATT connections) -- adds Bluetooth to boards without a usable onboard radio (`rpi`, `rpi2`, `x86_64`) or replaces a weak onboard one. |
| **USB DACs / sound cards** | Any class-compliant (`snd-usb-audio`) device, including hi-res DACs (up to 24-bit/96 kHz where supported) | Each output becomes an independently discoverable **Sendspin** player for synchronized multi-room audio; a capture (line-in) input becomes a **Sendspin** source. |
| **Bluetooth-audio transmitters** | FlooGoo FMA120, Sennheiser BTD 700 | Sendspin players (via their sound-card half) **plus a device control drawer** on the Overview -- details below. |
| **USB storage drives** | Any USB flash drive or SSD (ext4, exFAT, NTFS, FAT32) | Mounted as the device's **backup drive**, with an opt-in **SMB share** Home Assistant can use as a network backup target. Folder selection, formatting (to ext4), safe eject, and the share credentials all live in the drive's Overview drawer. |
| **USB hubs** | -- | Devices behind a hub render as an indented tree at the hub's slot; branded hubs are named. |

### Bluetooth-audio transmitter control drawers

Both supported dongles pair the audio output with a vendor-protocol control
channel, surfaced as a drawer on the dongle's Overview row. Preferences are
persisted and re-applied automatically when the dongle is replugged.

- **FlooGoo FMA120**: audio mode (High Quality / Gaming / Broadcast),
  headphone pairing (scan, discoverable, connect/forget from the paired
  list), A2DP vs LE Audio profile preference, active-codec + RSSI readout,
  Auracast broadcast settings (name, encryption, quality, USB volume), and
  status-LED toggle.
- **Sennheiser BTD 700**: audio mode (High Quality / Gaming / Broadcast),
  per-codec enable toggles (SBC, aptX, aptX Adaptive, aptX Lossless, aptX
  Lite, LC3 -- as supported by the dongle), connect/disconnect, live
  dongle / LE-audio / codec-in-use status, and the full Auracast surface:
  broadcast on/off, name, quality (16 kHz / 24 kHz / High), encryption +
  key, plus factory reset.

---

## For Users

### Installing firmware

1. Go to the [GitHub Releases](../../releases) page for this project.
2. Download the `.fw` firmware file for your board (e.g. `universal_proxy_rpi3.fw`).
3. Write it to a microSD card using [fwup](https://github.com/fwup-home/fwup) or [Etcher](https://www.balena.io/etcher/):

```bash
# Using fwup (Linux/macOS)
fwup universal_proxy_rpi3.fw
```

4. Insert the microSD card into your board, connect Ethernet, and power on.
5. The device will obtain an IP address via DHCP and be discoverable on your network.

### Upgrading firmware

#### From the web UI (in-app updates)

Open `http://<device>/system` and use the Firmware card, or install the
update from the device's **Firmware Update** entity in Home Assistant
(**Settings > Updates**). The device checks the configured GitHub repo for
the latest release matching its target (filename pattern
`universal_proxy_<target>.fw`) once a day and on demand, applies the firmware via `fwup --framing`, and reboots. With
signature verification turned on it first checks the release's signed
manifest ([docs/manifest-format.md](docs/manifest-format.md)) against the
Ed25519 public key baked into the rootfs; verification is off by default.
The boot-time `Nerves.Runtime.StartupGuard` will auto-revert if the new
firmware fails to come up healthy.

The first ConfigStore default targets `bbangert/universal_proxy`. To
point the device at a different fork, or to enable/disable signature
verification on a soak-testing device, SSH in and use the facade
(propagates to the live process without a restart):

```elixir
ssh user@universal_proxy.local
iex> UniversalProxy.FirmwareUpdate.update_config(repo: "myfork/proxy")
:ok
iex> UniversalProxy.FirmwareUpdate.update_config(verification_required: true)
:ok
iex> UniversalProxy.FirmwareUpdate.check()
:ok   # the next check uses the new repo
```

The web UI deliberately exposes **no form** for these — they're the
trust boundary and only live on the SSH/IEx surface.

#### Over the network with `mix upload`

```bash
mix upload universal_proxy.local
```

#### Manually with fwup (forks / dev workflow)

```bash
cat universal_proxy_rpi3.fw | ssh universal_proxy.local "fwup -aU -d /dev/rootdisk0 -t upgrade && reboot"
```

### Configuring serial devices

1. Open a browser and navigate to `http://universal_proxy.local` (or the device's IP address).
2. The **Overview** tab (`/`) lists each plugged-in USB serial adapter with
   its chipset and serial number. Adapters with a known chipset (see
   [Supported USB devices](#supported-usb-devices)) are auto-detected with a
   default type (TTL, or RS-232 for the PL2303) and advertised to Home
   Assistant as serial proxies straight away; an unknown adapter shows
   **Needs setup** and is not advertised until you pick its type.
3. To set an adapter's **port type** (TTL, RS-232, or RS-485), pick it in
   the adapter's **Type** column and confirm. The change drops in-flight
   frames and makes the ESPHome client rebind. Branded devices (Z-Wave
   sticks, IR transceivers) have a fixed type.

The port type and the last line settings (baud rate, framing) are remembered
per port and served back to reconnecting clients. The **Traffic** tab
(`/traffic`) shows a live view of the bytes flowing through each serial port.

The [Home Assistant Connect ZWA-2](https://www.home-assistant.io/connect/zwa-2/)
is **auto-detected** when plugged in -- no manual configuration needed. It
appears in the Overview with an "Auto-detected" badge. The proxy
opens the controller at 115200 baud, parses Z-Wave Serial API framing, and sends
ACK/NAK/CAN responses locally (avoiding network round-trip latency). Complete
frames are forwarded to Home Assistant's Z-Wave JS integration over the ESPHome
API. Only one Home Assistant instance can subscribe to the Z-Wave proxy at a
time. While a Z-Wave stick is held, the device also advertises a `_zwave._tcp`
mDNS service (TXT `protocol=esphome`, pointing at the ESPHome API port) so Z-Wave
JS UI's remote serial-port picker can find it.

The [Home Assistant Connect ZBT-2](https://www.home-assistant.io/connect/zbt-2/)
Zigbee coordinator is also **auto-detected**, by its USB product string. A ZWA-2
can share the same USB ID (`303A:4001`) and is told apart only by that string:
a stick whose product string says ZBT-2 is a Zigbee coordinator, and one without
a product string stays a Z-Wave stick. One ZBT-2 per device is exposed. The
device opens the stick's port once and holds it open, so sessions and
line-setting changes never close and reopen it (each reopen would toggle the
radio's reset lines); the resets a firmware flasher asks for on purpose are
still passed through. Home Assistant 2026.11 or later
discovers it from the serial proxy's USB identity and runs ZHA over it; the
EZSP/ASH ACKs are sent locally on the device (PROTOCOL mode), and firmware
updates go through Home Assistant's flasher. While it is held it
shows as "in use" in the Overview. ZBT-2 support is host-tested and build-validated
only; it has not yet been tested on real hardware.

IRDroid / IR Toy USB infrared devices are also **auto-detected** by USB ID
(VID `0x04D8`, PID `0xFD08` or `0xF58B`) and shown in the Overview with an
"Auto-detected" badge. When connected, these infrared devices are exposed to
Home Assistant via the ESPHome Native API as **Infrared entities**, supporting
infrared transmit and receive operations.

### Using a USB drive for Home Assistant backups

Plug in a USB drive and it appears on the Overview at its USB slot, showing
its capacity. The first data partition is mounted automatically (ext4, exFAT,
NTFS, and FAT32 are supported); ext4 and FAT32 volumes get an automatic
filesystem check and repair before mounting. One drive is mounted and shared
at a time.

From the drive's Overview drawer you can:

1. **Enable the SMB share** and pick (or create) the folder backups should
   land in. Sharing is opt-in per drive and remembered across replugs.
2. **Add it to Home Assistant**: go to **Settings > System > Storage**, add
   a network storage with a name of your choosing, usage *Backup*, and the
   Windows/Samba (CIFS) protocol, then copy the remaining fields -- server,
   share name (`usb_backup_<id>`, derived from the drive's serial number),
   username, and generated password -- straight from the drawer. The
   password can be revealed, copied, or regenerated at any time (update the
   credential in Home Assistant after regenerating).
3. **Format** the backup partition to ext4 (erasing its contents; a drive
   with no recognizable partition is formatted whole -- the button must be
   armed first) or **eject** it safely before unplugging.

The share requires Samba in the target's Nerves system, which every custom
target ships except `x86_64`. On targets without it, drives still mount and
show in the Overview but sharing is unavailable.

### Sendspin audio

On the Raspberry Pi targets every audio output -- the onboard jack and HDMI,
USB DACs, the sound-card half of a Bluetooth-audio transmitter, and paired
Bluetooth speakers -- runs its own [Sendspin](https://github.com/Sendspin)
player, advertised over mDNS so Music Assistant finds it. Players and inputs
speak Sendspin 1.0.0-rc1, which needs Music Assistant 2.10.7 or later;
earlier releases can't use them.

The **Audio** tab (`/audio`) has a card per output: rename (which briefly
re-advertises the player, so Music Assistant reconnects), volume, mute and
enable/disable. Music Assistant can use a player without pairing. To pair one
explicitly, open the card's details, **Show** its pairing token and paste it
into Music Assistant's Sendspin "Pairing token" option. Turning on **Pair
through Home Assistant** on one output instead lets Home Assistant hand that
output's token to Music Assistant over an encrypted API connection; only one
output can be selected at a time. On an HDMI output with a CEC receiver,
**Auto-wake receiver on playback** sends One Touch Play when a stream starts,
and **Control receiver volume** makes the output's volume and mute follow the
receiver's, up to a **Max volume**.

USB capture cards (line-in) are listed under **Audio inputs**, each as a
Sendspin source Music Assistant can play from. A source must be paired first,
either with its pairing token (in the card's details) or with a PIN: click
**Allow pairing**, start pairing in Music Assistant, and type in the PIN the
card shows. The details also list the servers the input is paired with, with
**Unpair**, **Unpair all** and **Regenerate** (a new pairing token).

The web UI is plain HTTP with no login: anyone who can open it can reveal a
pairing token, and a revealed token crosses the network in the clear. Holding
an input's token lets a server pair with it and stream its audio; regenerate
it (and unpair unknown servers) if it leaks.

### TV screen (HDMI)

On `rpi0_2`, `rpi3`, `rpi4` and `rpi5` the TV on the Pi's HDMI output shows
what the HDMI output's Sendspin player is playing. Home Assistant gets a
**TV display mode** select on the device:

| Mode | Screen |
|------|--------|
| Now Playing (default) | Artwork, title, artist and album, a progress bar, transport controls and a visualizer strip |
| Visualizer | A full-screen visualizer under a one-line title |
| MilkDrop | Full-screen MilkDrop presets (`rpi3`, `rpi4`, `rpi5`; see below) |
| Party QR | A party join card (a placeholder for now) |
| Off | A black screen |

With the TV remote (HDMI-CEC), Left / Right move between the previous,
play/pause and next controls and Select presses the focused one; Play, Pause,
Stop, Forward and Backward act directly; Up / Down step through the modes
(except Off); Exit goes back to Now Playing. While nothing plays, the screen
goes black after two minutes; playback, a remote key or a mode change wakes
it.

### MilkDrop visualizer (HDMI)

On `rpi3`, `rpi4` and `rpi5` the TV on the Pi's HDMI output can show MilkDrop
presets rendered by projectM, reacting to the music playing on that output.
projectM comes from the [bbangert/projectm](https://github.com/bbangert/projectm)
fork: the Pi 3 runs it on OpenGL ES 2.0 through the fork's ES 2.0 backend; the
Pi 4 and 5 use the ES 3.0 path, with the fork's blur passes rendered directly
into their textures (which avoids GPU hangs on the Pi 4).

To use it, set the device's **TV display mode** select in Home Assistant to
**MilkDrop** while music plays to the HDMI output. Presets rotate with short
blends. On the TV remote (HDMI-CEC):

| Key | Action |
|-----|--------|
| Left / Right | Previous / next preset |
| Select | Lock / unlock the current preset |
| Up / Down | Change display mode |

The preset pack (about 4.5 MB, ~35 MB extracted) downloads once to `/data`,
SHA-256 verified, the first time MilkDrop is selected, or earlier with the
**Download** button. Enabling the feature never downloads anything by itself;
only a box whose display mode is already MilkDrop fetches a missing pack at
boot. The download waits for the network and retries on its own.

The **MilkDrop visualizer** section of the web UI's **Audio** tab shows the
pack status and sets:

- **Change preset every** -- the rotation interval (10-120 s).
- **Minimum frame rate** -- 20 fps upward in 5 fps steps, up to 30 on the
  Pi 3 and 60 on the Pi 4 and 5. Presets that can't hold it are skipped;
  lowering it brings them back.
- **Include fast-flashing presets** -- off by default. These presets flash
  rapidly and may trigger seizures in people with photosensitive epilepsy;
  turning them on asks for confirmation.
- **Clear skipped presets** -- returns presets the device skipped at runtime
  to the rotation straight away, including while MilkDrop is on screen.

**Browse presets** (or `/audio/milkdrop`) lists every pack and uploaded
preset, with search and filters (uploaded, favourites, hidden, playlist,
skipped, fast-flashing) kept in the URL. Each preset can be:

- **played now** on the TV, or played and **locked** there (with nothing on
  screen, the lock applies to the next MilkDrop session);
- **favourited** -- favourites come up about three times as often;
- **hidden** -- never picked by rotation, though it can still be played by
  hand;
- added to a **playlist** -- with the playlist on, rotation picks only from it
  (falling back to everything, with a warning, if nothing on it can play).

A skipped preset played from the browser gets another try (it is skipped
again if it fails). Fast-flashing presets can't be played while **Include
fast-flashing presets** is off.

#### Uploading presets

The **Upload presets** form, on the Audio tab and the preset browser, takes
`.milk` files, or `.zip` files of `.milk` presets with their `.jpg`/`.png`
textures (anything else in a zip is ignored). Uploads are stored in
`/data/milkdrop/user/`, survive pack updates, join the rotation tagged
**Uploaded**, and can be deleted from the browser. A results table lists what
was added, replaced, unchanged or rejected, and why.

- Limits: 32 MiB per file and 20 files per upload; the library holds at most
  64 MiB, 500 presets and 256 textures, and an upload must leave
  max(200 MiB, 10%) of `/data` free.
- Zips are read with a hardened reader (no path traversal, symlinks, ZIP64,
  encryption or zip bombs), and every preset and texture is checked before it
  is stored.
- **Photosensitivity:** uploads are not screened for fast flashing and are not
  marked fast-flashing by default -- you are responsible for what you upload.
  Mark one fast-flashing in the browser to put it behind the fast-flashing
  setting.
- Uploads get the same runtime guards as pack presets: one that is too slow,
  fails to compile, hangs the GPU, freezes the renderer (nested expression
  loops) or crashes it is skipped, and replacing the file clears its skips.

Notes for the Pi 3:

- A 60-minute soak on a Pi 3 B+ held 59-64 °C with no throttling. A heatsink
  is recommended but not required. If the SoC gets too hot, MilkDrop drops to
  a lower resolution and, past that, shows the bar visualizer until the mode
  is chosen again.
- Presets too heavy for the Pi 3 were marked as skips by a sweep on a real
  device and never play there.
- Presets that hang the Pi 3's GPU are skipped automatically: when the GPU
  resets, and, if the hang reboots the Pi, on the next boot.
- On every board, a preset that freezes the renderer (no output for 30 s, or
  no answer within 10 s of starting to load) or crashes it is skipped, and the
  TV goes back to the regular display.

The Pi 4 and 5 have no device sweep yet: a runtime cost guard lowers the
resolution of, then skips, presets that can't hold their frame rate.

The pack is built from community MilkDrop presets
([bbangert/up-milkdrop-pack](https://github.com/bbangert/up-milkdrop-pack)),
which are presumed to be in the public domain, as with projectM's own preset
packs. To have a preset removed, [open an issue](https://github.com/bbangert/up-milkdrop-pack/issues).

### Tuya Bluetooth mesh lights

The device can control Tuya **Beacon Mesh** bulbs (Beacon v2 / "P2" -- the
advertisement-based Bluetooth mesh, not Tuya's GATT "paired BLE" bulbs) from
Home Assistant. Pairing and Tuya cloud login are not part of this: you pair the
bulbs in the Tuya or Smart Life app first, then give the device a JSON dump of
the mesh. It has only been hardware-validated on one product, Gardenreet RGBCW
G4 12 V bi-pin bulbs; other Beacon mesh bulbs may differ. It needs a
Bluetooth-enabled target (see [Supported targets](#supported-targets)).

1. **Dedicate a Bluetooth adapter.** Open the **Bluetooth** tab and set one
   radio's role to **Tuya mesh**. The option appears only when the device has at
   least two radios, because nothing else may use the mesh radio -- the
   Bluetooth proxy, audio and Wi-Fi setup run on your other radios. For example,
   keep the onboard radio as the Bluetooth proxy and add a USB dongle for the
   mesh. Only one radio can hold the role.
2. **Upload the dump.** In the Tuya mesh card, choose the JSON file and click
   **Upload dump**. It describes the mesh: its `beaconKey` and `seq`, each bulb's
   MAC, `localKey`, `nodeId` and optional `label`, and any groups (`localId`,
   `name`, `members`). It contains the mesh's secret keys, which are stored only
   on the device and never shown in the UI. This device does not produce the
   file; it only reads it. Uploading a *different* mesh replaces the stored
   inventory, so the UI shows which bulbs will be added and removed and asks you
   to confirm first. Bulbs are matched by MAC, so ones that stay keep their Home
   Assistant devices; groups from the old mesh are recreated as new devices.
   Re-uploading the same mesh just updates it.
3. **Check the status.** The card shows Running / Not set up / Idle with a hint,
   the radio's state, and each bulb's reachability and last-seen time.
   **Clear inventory** removes the stored mesh.

In Home Assistant, each bulb and each group becomes a sub-device of the Universal
Proxy device. A bulb has a **Light** (on/off, brightness, colour temperature and
RGB colour), a **Connectivity** sensor, and a **Last seen** sensor; a group has a
**Light** that commands all its members. Colour-temperature range is set in the
card under **Colour temperature** (Warmest / Coolest in Kelvin, with an
**Invert** switch for bulbs that show warm as cool); changing it briefly
reconnects Home Assistant. Groups can be created, renamed, deleted and have their
members edited from the card while the mesh is running.

Known limits:

- A light's state in Home Assistant is optimistic: what was last sent to it and
  accepted, or what the bulb last reported, so a light stays unknown in Home
  Assistant until it has a state.
- Effects, transitions and flashing are ignored.
- Using the Tuya or Smart Life app after uploading can move the bulbs' sequence
  counter past the device's, and they then ignore its commands. If control stops
  working, export a fresh dump after your last app use and upload it. If the
  dump's counter is far ahead of the device's, the upload keeps the device's
  counter unless you choose **Adopt the dump's counter…** in the upload dialog
  and then **Adopt counter and upload**.

### Editing the device name

1. Go to the **Discovery** tab (`/discovery`).
2. Edit the **Friendly name** (shown on Home Assistant's integrations page)
   and the **ESPHome device name**. The hostname shown follows the device
   name: the device answers mDNS as `<device name>.local`.
3. Save; the mDNS advertiser restarts with the new names.

Out of the box the device name is `universal-proxy-<mac>` and the friendly
name `Universal Proxy <MAC>`, where `<mac>` is the last three bytes of the
device's MAC address, so several devices on one network don't collide in Home
Assistant. `universal_proxy.local` also works while there is only one device
on the network. The Area and Advertise controls on the tab are not saved yet.

### Adding to Home Assistant

Once the device is powered on and connected to the network:

1. Home Assistant should auto-discover it via mDNS under **Settings > Devices & Services**.
2. If not, manually add an ESPHome integration pointing to `universal-proxy-<mac>.local`,
   `universal_proxy.local` or the IP.
3. No API password or encryption key is needed to add it. The API starts
   unencrypted; when Home Assistant connects it provisions an encryption key,
   which the device keeps from then on. The **Security** tab shows whether the
   connection is encrypted and can **Reset** the key (back to plaintext until
   Home Assistant provisions a new one). It also has the device's SSH
   access key (see [Connecting to a running device](#connecting-to-a-running-device)).
4. Serial adapters appear as serial proxies on the device. An auto-detected ZWA-2 appears as a Z-Wave proxy. An auto-detected ZBT-2 appears as a Zigbee serial proxy, and Tuya mesh bulbs and groups appear as sub-devices.
   The device also has diagnostic sensors (CPU temperature, memory, uptime,
   network, Bluetooth and audio activity, USB storage), Reboot and Factory
   Reset buttons, the firmware update entity and, with an HDMI TV screen, the
   **TV display mode** select.

---

## For Developers

### Prerequisites

- Docker (for the devcontainer)
- VS Code or Cursor with the Dev Containers extension
- Alternatively: Elixir 1.20+ and Erlang/OTP 29 (the versions pinned in `.mise.toml`), and Nerves tooling installed locally

### Getting started with the devcontainer

1. Clone the repository:

```bash
git clone https://github.com/<owner>/universal_proxy.git
cd universal_proxy
```

2. Open the project in VS Code or Cursor.
3. When prompted, click **Reopen in Container** (or run the `Dev Containers: Reopen in Container` command).
4. The container will build and install all dependencies automatically, including:
   - Elixir and Erlang (via mise)
   - Nerves tooling and bootstrap
   - fwup for firmware packaging
   - protobuf compiler

The devcontainer is preconfigured with `MIX_TARGET=rpi3`. Change this in
`.devcontainer/devcontainer.json` if targeting a different board.

### Project structure

```
lib/
  universal_proxy/
    uart/                  # UART subsystem (Server, Store, SettingsStore, History, Supervisor)
    bluetooth/             # Bluetooth lifecycle: Settings, Manager, RadioMonitor, Stats, Radios,
                           #   AudioManager (A2DP speakers); the BlueZ stack is the `bluez` package
    audio/                 # Sendspin audio: Enumerate, per-output Server/Store, Player,
                           #   input/ (capture-card sources), Home Assistant pairing
    sendspin/              # Sendspin wire protocol, Noise and pairing for the Elixir source client
    cec/                   # HDMI-CEC: Enumerate (cecN <-> ALSA card), Server, VolumeLink
    display/               # TV screen on the HDMI output (Emerge) + MilkDrop handover
    milk_drop/             # MilkDrop preset pack, Store, user presets and uploads, Index
    fma120/, btd700/       # Bluetooth-audio transmitter control channels
    tuya_mesh/             # Tuya Beacon mesh lights (with tuya_beacon_mesh/ for the protocol)
    firmware_update/       # In-app firmware update flow (nerves_github_updater)
    storage/               # USB backup drive: mount, capacity, opt-in SMB share (smbd)
    esphome/               # ESPHome Native API adapters (espex) + Supervisor
      serial_proxy/        # Serial proxy
      zwave_proxy/         # Z-Wave proxy
      zigbee_proxy/        # ZBT-2 Zigbee (ASH) support
      infrared/            # IR proxy
      entity_provider/     # Home Assistant entities (sensors, buttons, update, select)
  universal_proxy_web/
    live/                  # Phoenix LiveView pages: Overview, Traffic, Audio (+ MilkDrop
                           #   preset browser), Bluetooth, Discovery, Security, System
c_src/
  sendspin_player/         # C++ Sendspin player (one process per output)
  milkdrop_renderer/       # C++ projectM renderer for the MilkDrop display mode
deps_local/                # In-repo libraries: circuits_cec, vendored mdns_lite fork
tools/milkdrop_pack/       # Host-only MilkDrop preset pack pipeline
priv/
  static/                  # Static web assets
docs/
  plans/                   # Historical architecture and design plans
  protocols/               # Tuya Beacon mesh protocol notes
```

### Building assets

The web UI uses Tailwind CSS and esbuild. To build assets:

```bash
# Install asset tools (first time only)
mix assets.setup

# Build CSS and JS
mix assets.build

# Build minified for production
mix assets.deploy
```

### Building firmware

The repo drives builds through [mise](https://mise.jdx.dev/) tasks (the
devcontainer sets these up). Build for a target with:

```bash
mix deps.get
mise run firmware -- rpi3
```

> The mise shell hook pins `MIX_TARGET`, so a bare `MIX_TARGET=rpi3 mix firmware`
> is **silently overridden** -- always go through `mise run firmware`. The task
> also pre-cleans stale per-target player binaries that would otherwise fail the
> Nerves rootfs scrubber.

The firmware file is written to `_build/rpi3_dev/nerves/images/universal_proxy.fw`.

**If you changed anything in the web UI** (HEEx, Tailwind classes, JS), rebuild
the assets first -- `mix firmware` packages whatever is already in
`priv/static/`, so new Tailwind classes won't reach the served CSS otherwise:

```bash
mix assets.deploy && mise run firmware -- rpi3
```

Other mise tasks: `mise run test` (host test suite),
`mise run test-circuits-cec` (the in-repo `circuits_cec` library's own tests,
which CI also runs) and `mise run mix-for -- <target> <task>` (run an
arbitrary mix task for a target).

### Writing to an SD card

Insert a microSD card and run:

```bash
mix burn
```

This uses `fwup` to write the firmware image. You may be prompted for your
password to access the SD card device.

### Uploading to a running device

If the device is already running Nerves firmware on the network:

```bash
mix upload universal_proxy.local
```

Or specify an IP address:

```bash
mix upload 192.168.1.100
```

The device will reboot with the new firmware automatically.

### Running tests

```bash
mise run test                 # full host suite
mise run test -- test/path_test.exs   # pass flags/paths through
```

> Tests run on the `host` target. A bare `MIX_TARGET=host mix test` is
> overridden by the mise hook -- use `mise run test`.

Dialyzer is a CI gate but runs **only** on the host target and isn't part of
the test alias. Because of the `MIX_TARGET` pin above, reproduce it through a
clean subshell:

```bash
mise exec -- sh -c 'MIX_TARGET=host MIX_ENV=dev mix dialyzer'
```

### Connecting to a running device

Access the Erlang shell over SSH:

```bash
ssh universal_proxy.local
```

On first boot the device also generates its own SSH access key; download the
private key from the **Security** tab and log in with it from any machine:

```bash
ssh -i universal_proxy universal_proxy.local
```

From the IEx shell, you can inspect the system, view logs, and interact with
the application directly:

```elixir
# View logs (device logs at :info by default;
# Logger.configure(level: :debug) to see debug output)
RingLogger.attach()

# Enumerate serial devices
Circuits.UART.enumerate()

# Check ESPHome config
UniversalProxy.ESPHome.config()
```

## Supported targets

Each release has a firmware file for every target below:

| Target | Board |
| ------ | ----- |
| `rpi`  | Raspberry Pi A+/B+ |
| `rpi0` | Raspberry Pi Zero |
| `rpi0_2` | Raspberry Pi Zero 2 W |
| `rpi2` | Raspberry Pi 2 |
| `rpi3` | Raspberry Pi 3 B/B+ |
| `rpi4` | Raspberry Pi 4 |
| `rpi5` | Raspberry Pi 5 |
| `bbb`  | BeagleBone Black |
| `mangopi_mq_pro` | MangoPi MQ Pro |
| `qemu_aarch64` | QEMU (64-bit Arm virtual machine) |
| `x86_64` | Generic x86_64 |

The `rpi*` and `x86_64` targets run this project's custom Nerves systems
([bbangert/nerves_systems_universal_proxy](https://github.com/bbangert/nerves_systems_universal_proxy),
adding BlueZ, USB audio and more); `bbb`, `mangopi_mq_pro` and `qemu_aarch64`
use the stock Nerves systems. Feature availability by target:

| Feature | Targets |
| ------- | ------- |
| Serial, Z-Wave, Zigbee and IR proxies | all |
| Bluetooth proxy, Tuya mesh lights | `rpi`, `rpi0`, `rpi0_2`, `rpi2`, `rpi3`, `rpi4`, `rpi5`, `x86_64` |
| Sendspin audio players | `rpi`, `rpi0`, `rpi0_2`, `rpi2`, `rpi3`, `rpi4`, `rpi5` |
| Bluetooth speakers (Audio radio role) | `rpi4`, `rpi5`, `x86_64` |
| HDMI-CEC and the TV screen | `rpi0_2`, `rpi3`, `rpi4`, `rpi5` |
| MilkDrop visualizer | `rpi3`, `rpi4`, `rpi5` |
| USB backup drive SMB share | `rpi`, `rpi0`, `rpi0_2`, `rpi2`, `rpi3`, `rpi4`, `rpi5` |
| USB slot map on the Overview | `rpi3`, `rpi4` |

**Bluetooth** is available on every target that ships the custom BlueZ-enabled
Nerves system: the onboard-BT Pis (`rpi0`, `rpi0_2`, `rpi3`, `rpi4`, `rpi5`)
and -- via a USB BT dongle -- `rpi`, `rpi2`, and `x86_64`, which have no onboard
radio. Only `rpi3` is hardware-validated so far; the rest share its design but
are unverified (`rpi4`/`rpi5` device trees; the USB-dongle-only targets have no
bench hardware). On a board with no radio yet, the subsystem idles in a benign
retry loop and binds a USB dongle when one is plugged in. The remaining targets
(`bbb`, `mangopi_mq_pro`, `qemu_aarch64`) compile the Bluetooth subsystem out
and run the rest normally.

## Learn more

- [ESPHome Native API protocol](https://developers.esphome.io/architecture/api/protocol_details/)
- [ESPHome Z-Wave proxy component](https://github.com/esphome/esphome/tree/dev/esphome/components/zwave_proxy)
- [Nerves documentation](https://hexdocs.pm/nerves/getting-started.html)
- [Phoenix LiveView](https://hexdocs.pm/phoenix_live_view/)
- [Circuits.UART](https://hexdocs.pm/circuits_uart/)
