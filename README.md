# Universal Proxy

A Nerves-based firmware that turns a Raspberry Pi (or other supported board) into
a **universal serial proxy** for [Home Assistant](https://www.home-assistant.io/).

The device appears as a native [ESPHome](https://esphome.io/) device on the
network, advertising itself over mDNS. USB serial adapters plugged into the board
are exposed to Home Assistant as **serial proxies** through the ESPHome Native
API. Home Assistant can then open, configure, and stream data from those serial
ports exactly as it would with an ESPHome device that has a built-in UART.

This is useful for connecting RS-232, RS-485, or TTL serial devices to Home
Assistant over the network without needing a dedicated ESPHome microcontroller
for each one.

## Features

- Speaks the ESPHome Native API (protobuf over TCP on port 6053)
- Automatic mDNS advertisement -- discovered by Home Assistant like any ESPHome device
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

Once the device is running, you can upload new firmware over the network:

```bash
mix upload universal_proxy.local
```

Or manually with fwup:

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
4. Configured serial adapters appear as serial proxy entities on the device.

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
    esphome/               # ESPHome Native API (Server, Connection, Protocol, Supervisor)
  universal_proxy_web/
    live/                  # Phoenix LiveView pages (Home, Connected Devices, ESPHome Config)
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

```bash
# Set your target board (already set in devcontainer)
export MIX_TARGET=rpi3

# Fetch dependencies
mix deps.get

# Build the firmware image
mix firmware
```

The firmware file is written to `_build/rpi3_dev/nerves/images/universal_proxy.fw`.

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
# Tests run on the host target
mix test
```

### Connecting to a running device

Access the Erlang shell over SSH:

```bash
ssh universal_proxy.local
```

From the IEx shell, you can inspect the system, view logs, and interact with
the application directly:

```elixir
# View debug logs
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

## Learn more

- [ESPHome Native API protocol](https://developers.esphome.io/architecture/api/protocol_details/)
- [Nerves documentation](https://hexdocs.pm/nerves/getting-started.html)
- [Phoenix LiveView](https://hexdocs.pm/phoenix_live_view/)
- [Circuits.UART](https://hexdocs.pm/circuits_uart/)
