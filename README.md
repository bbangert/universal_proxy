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
- Auto-detection for IRDroid / IR Toy USB infrared devices (VID `0x04D8`, PID `0xFD08`/`0xF58B`)
- **Bluetooth proxy** -- relays BLE advertisements to Home Assistant over the
  ESPHome Native API (passive scanning plus optional active GATT connections),
  driven by the on-device BlueZ stack. The web UI shows live stats and lets you
  pick which radio (onboard or USB) is bound. Works on every custom-system
  target -- the onboard-BT Pis plus USB BT dongles on `rpi`/`rpi2`/`x86_64`.
- **Sendspin audio playback** -- each ALSA output (the onboard jack/HDMI plus
  hot-plugged **USB DACs**) is exposed as an independently discoverable
  [Sendspin](https://github.com/Sendspin/sendspin-cpp) player for synchronized
  multi-room audio. USB sound cards appear in their physical USB slot in the web
  UI. See [docs/plans/10_sendspin_audio.md](docs/plans/10_sendspin_audio.md).
- Web UI for configuration (accessible at `http://<device-ip>`)
- USB hotplug detection -- plug/unplug serial adapters at any time
- DETS-backed persistent device configuration across reboots
- Graceful handling of unexpected USB disconnects during active sessions

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

Open `http://<device>/system` and use the Firmware card. The device polls
the configured GitHub repo for the latest release matching its target
(filename pattern `universal_proxy_<target>.fw`), verifies the detached
Ed25519 signature against a public key baked into the rootfs, applies
the firmware via `fwup --framing`, and reboots. The boot-time
`Nerves.Runtime.StartupGuard` will auto-revert if the new firmware
fails to come up healthy.

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
2. Go to the **Connected Devices** tab (`/devices`).
3. Each plugged-in USB serial adapter is listed with its description and serial number.
4. Click **Configure** on a device to assign its **port type** (TTL, RS-232, or RS-485).
5. Click **Save**. The device is now advertised to Home Assistant as a serial proxy.

To remove a device from Home Assistant, click **Delete** on its configuration.

Saving or deleting a configuration automatically restarts the ESPHome server,
causing Home Assistant to reconnect and pick up the updated device list.

The [Home Assistant Connect ZWA-2](https://www.home-assistant.io/connect/zwa-2/)
is **auto-detected** when plugged in -- no manual configuration needed. It
appears in the Connected Devices list with an "Auto-detected" badge. The proxy
opens the controller at 115200 baud, parses Z-Wave Serial API framing, and sends
ACK/NAK/CAN responses locally (avoiding network round-trip latency). Complete
frames are forwarded to Home Assistant's Z-Wave JS integration over the ESPHome
API. Only one Home Assistant instance can subscribe to the Z-Wave proxy at a
time.

IRDroid / IR Toy USB infrared devices are also **auto-detected** by USB ID
(VID `0x04D8`, PID `0xFD08` or `0xF58B`) and shown in Connected Devices with an
"Auto-detected" badge. When connected, these infrared devices are exposed to
Home Assistant via the ESPHome Native API as **Infrared entities**, supporting
infrared transmit and receive operations.

### Editing ESPHome device configuration

1. Go to the **ESPHome Config** tab (`/esphome-config`).
2. The current device identity is shown (name, friendly name, MAC address, model, etc.).
3. Click **Edit** to modify any field.
4. Click **Save & Reload** to apply changes, or **Cancel** to discard.

The device name and friendly name control how the device appears in Home
Assistant's integrations list. The MAC address is auto-detected from the
Ethernet interface on first boot.

### Adding to Home Assistant

Once the device is powered on and connected to the network:

1. Home Assistant should auto-discover it via mDNS under **Settings > Devices & Services**.
2. If not, manually add an ESPHome integration pointing to `universal_proxy.local` (or the IP).
3. No API password is required.
4. Configured serial adapters appear as serial proxy entities on the device. An auto-detected ZWA-2 appears as a Z-Wave proxy.

---

## For Developers

### Prerequisites

- Docker (for the devcontainer)
- VS Code or Cursor with the Dev Containers extension
- Alternatively: Elixir 1.19+, Erlang/OTP 27+, and Nerves tooling installed locally

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
    uart/                  # UART subsystem (Server, Store, PortConfig, Supervisor)
    bluetooth/             # Bluetooth lifecycle: Settings, Manager, RadioMonitor, Stats, Radios
    bluez/                 # BlueZ/D-Bus stack: Client (scanner), Gatt, Agent, DeviceCache
    audio/                 # Sendspin audio: Enumerate, per-output Server/Store, Player
    firmware_update/       # In-app firmware update flow
    esphome/               # ESPHome Native API adapters + Supervisor
      serial_proxy/        # Serial proxy
      zwave_proxy/         # Z-Wave proxy
      infrared/            # IR proxy
  universal_proxy_web/
    live/                  # Phoenix LiveView pages: Overview, Traffic, Audio,
                           #   Bluetooth, Discovery, Security, System
priv/
  protos/                  # ESPHome protobuf definitions (api.proto, api_options.proto)
  static/                  # Static web assets
docs/
  plans/                   # Architecture and design plans
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

### Regenerating protobuf bindings

If you update `priv/protos/api.proto`, regenerate the Elixir bindings:

```bash
mix protobuf
```

This is also run automatically as part of `mix compile`.

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

Other mise tasks: `mise run test` (host test suite) and
`mise run mix-for -- <target> <task>` (run an arbitrary mix task for a target).

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

This project supports all standard Nerves targets:

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
| `x86_64` | Generic x86_64 |

**Bluetooth** is available on every target that ships the custom BlueZ-enabled
Nerves system: the onboard-BT Pis (`rpi0`, `rpi0_2`, `rpi3`, `rpi4`, `rpi5`)
and -- via a USB BT dongle -- `rpi`, `rpi2`, and `x86_64`, which have no onboard
radio. Only `rpi3` is hardware-validated so far; the rest share its design but
are unverified (`rpi4`/`rpi5` device trees; the USB-dongle-only targets have no
bench hardware). On a board with no radio yet, the subsystem idles in a benign
retry loop and binds a USB dongle when one is plugged in. The remaining targets
(`bbb`, etc.) compile the Bluetooth subsystem out and run the rest normally.

## Learn more

- [ESPHome Native API protocol](https://developers.esphome.io/architecture/api/protocol_details/)
- [ESPHome Z-Wave proxy component](https://github.com/esphome/esphome/tree/dev/esphome/components/zwave_proxy)
- [Nerves documentation](https://hexdocs.pm/nerves/getting-started.html)
- [Phoenix LiveView](https://hexdocs.pm/phoenix_live_view/)
- [Circuits.UART](https://hexdocs.pm/circuits_uart/)
