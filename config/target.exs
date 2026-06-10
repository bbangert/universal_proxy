import Config

config :universal_proxy, UniversalProxyWeb.Endpoint,
  # Code Reloader and watchers cannot be used on target
  code_reloader: false,
  watchers: [],
  # Start the HTTP server on Nerves targets (mix firmware uses MIX_ENV=dev,
  # so runtime.exs prod block doesn't run; we must enable the server here)
  server: true,
  # Bind to all interfaces so the web UI is accessible on the network
  http: [ip: {0, 0, 0, 0}, port: 80],
  # Allow websocket connections from any origin (hostname, IP, .local)
  # so LiveView works when accessing via universal_proxy.local, nerves-xxxx.local, or IP
  check_origin: false

# Use Ringlogger as the logger backend and remove :console.
# See https://hexdocs.pm/ring_logger/readme.html for more information on
# configuring ring_logger.

config :logger, backends: [RingLogger]

# Use shoehorn to start the main application. See the shoehorn
# library documentation for more control in ordering how OTP
# applications are started and handling failures.

config :shoehorn, init: [:nerves_runtime, :nerves_pack]

# Nerves.Runtime.StartupGuard auto-calls validate_firmware/0 once the full
# supervision tree comes up, so the bootloader stops auto-reverting. That's
# normally what we want.
#
# DISABLED on rpi3 (Phase 0 BT bring-up): the Bluetooth init can fail in a
# way that still lets the rest of the app boot (web UI, SSH, etc.) just
# long enough that StartupGuard validates a firmware whose BT subsystem
# crash-loops. Once validated, the bootloader's two-slot auto-revert no
# longer fires — the Pi has to be SD-card reflashed to recover. Observed
# 2026-05-22. While the BT init is unstable, require explicit manual
# validation: SSH in, confirm `BlueHeron.HCI.Transport.setup_complete?/0`
# returns true and `Process.alive?(Process.whereis(BlueHeron.Observer))`,
# then call `Nerves.Runtime.validate_firmware/0`. Re-enable when Phase 0
# is green and BT is no longer the riskiest subsystem at boot.
#
# See the "StartupGuard" section of the nerves_runtime README:
# https://github.com/nerves-project/nerves_runtime#startupguard
config :nerves_runtime,
  startup_guard_enabled: Mix.target() != :rpi3

# Erlinit can be configured without a rootfs_overlay. See
# https://github.com/nerves-project/erlinit/ for more information on
# configuring erlinit.

# Advance the system clock on devices without real-time clocks.
config :nerves, :erlinit, update_clock: true

# Configure the device for SSH IEx prompt access and firmware updates
#
# * See https://hexdocs.pm/nerves_ssh/readme.html for general SSH configuration
# * See https://hexdocs.pm/ssh_subsystem_fwup/readme.html for firmware updates

keys =
  System.user_home!()
  |> Path.join(".ssh/id_{rsa,ecdsa,ed25519}.pub")
  |> Path.wildcard()
  |> case do
    [] ->
      # Fallback: use keys from ssh-agent when ~/.ssh has no key files
      # (e.g. when SSH is proxied into a dev container via agent forwarding)
      case System.cmd("ssh-add", ["-L"], stderr_to_stdout: true) do
        {output, 0} ->
          output
          |> String.split("\n", trim: true)
          |> Enum.filter(
            &String.starts_with?(&1, ["ssh-rsa ", "ssh-ed25519 ", "ssh-ecdsa ", "ssh-dss "])
          )

        _ ->
          []
      end

    key_files ->
      Enum.map(key_files, &File.read!/1)
  end

if keys == [],
  do:
    Mix.raise("""
    No SSH public keys found in ~/.ssh or ssh-agent. An ssh authorized key is needed to
    log into the Nerves device and update firmware on it using ssh.
    See your project's config.exs for this error message.
    """)

config :nerves_ssh,
  authorized_keys: keys

# Configure the network using vintage_net
#
# Update regulatory_domain to your 2-letter country code E.g., "US"
#
# See https://github.com/nerves-networking/vintage_net for more information
config :vintage_net,
  regulatory_domain: "00",
  config: [
    {"usb0", %{type: VintageNetDirect}},
    {"eth0",
     %{
       type: VintageNetEthernet,
       ipv4: %{method: :dhcp}
     }},
    {"wlan0", %{type: VintageNetWiFi}}
  ]

config :mdns_lite,
  # The `hosts` key specifies what hostnames mdns_lite advertises.  `:hostname`
  # advertises the device's hostname.local. For the official Nerves systems, this
  # is "nerves-<4 digit serial#>.local".  The `"nerves"` host causes mdns_lite
  # to advertise "nerves.local" for convenience. If more than one Nerves device
  # is on the network, it is recommended to delete "nerves" from the list
  # because otherwise any of the devices may respond to nerves.local leading to
  # unpredictable behavior.

  hosts: [:hostname, "universal_proxy"],
  ttl: 120,

  # Advertise the following services over mDNS.
  services: [
    %{
      protocol: "ssh",
      transport: "tcp",
      port: 22
    },
    %{
      protocol: "sftp-ssh",
      transport: "tcp",
      port: 22
    },
    %{
      protocol: "epmd",
      transport: "tcp",
      port: 4369
    },
    %{
      protocol: "http",
      transport: "tcp",
      port: 80
    }
    # ESPHome Native API mDNS service is registered dynamically by
    # `Espex.Mdns.MdnsLite` from the live device configuration.
  ]

# Bluetooth (Phase 0 spike — rpi3 only). Configures the vendored
# blue_heron transport so its OTP-application autostart can reach the
# Broadcom radio over `/dev/ttyS0` (miniUART on rpi3 with `dtoverlay=
# miniuart-bt`). Hardware flow control is the rpi3 BT-chip default.
# Phase 0b broadens to rpi4/rpi0/rpi0_2 (rpi4 device path differs).
if Mix.target() == :rpi3 do
  config :blue_heron,
    transport: [device: "/dev/ttyS0", speed: 115_200, flow_control: :hardware]
end

# Import target specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
# Uncomment to use target specific configurations

# import_config "#{Mix.target()}.exs"
