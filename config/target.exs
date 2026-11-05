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
  # Accept the websocket Origin only when it matches the request's own
  # host, so LiveView works via universal_proxy.local, nerves-xxxx.local or
  # an IP while other sites can't hijack the socket.
  check_origin: :conn

# Use Ringlogger as the logger backend and remove :console.
# See https://hexdocs.pm/ring_logger/readme.html for more information on
# configuring ring_logger.
#
# Default to :info. Nerves firmware builds in MIX_ENV=dev, where the
# Logger level would otherwise default to :debug — capturing very chatty
# debug output (notably espex's per-advertisement logging) into the ring
# buffer by default. Bump to :debug at runtime when troubleshooting via
# `Logger.configure(level: :debug)` or `RingLogger`.
config :logger, level: :info, backends: [RingLogger]

# Use shoehorn to start the main application. See the shoehorn
# library documentation for more control in ordering how OTP
# applications are started and handling failures.

config :shoehorn, init: [:nerves_runtime, :nerves_pack]

# Nerves.Runtime.StartupGuard auto-calls validate_firmware/0 once the full
# supervision tree comes up, so the bootloader stops auto-reverting and
# nerves_heart stops rebooting the (otherwise pending-validation) firmware.
#
# This was DISABLED on rpi3 during Phase 0 Bluetooth bring-up (2026-05-22)
# because a half-working BT subsystem could validate a crash-looping
# firmware before the BT subtree fell over. Phase 0 is now green and BT is
# stable, so it's re-enabled for all targets. (While disabled, every fresh
# flash stayed unvalidated, so nerves_heart rebooted it ~every 10 min until
# manually validated via `Nerves.Runtime.validate_firmware/0`.)
#
# See the "StartupGuard" section of the nerves_runtime README:
# https://github.com/nerves-project/nerves_runtime#startupguard
config :nerves_runtime,
  startup_guard_enabled: true

# Erlinit can be configured without a rootfs_overlay. See
# https://github.com/nerves-project/erlinit/ for more information on
# configuring erlinit.

# Targets whose Pi HDMI output can show the TV UI (`UniversalProxy.Display`,
# rendered with Emerge). Keep in sync with `@display_targets` in mix.exs,
# which limits the `:emerge` dependency to the same targets.
display_targets = [:rpi0_2, :rpi3, :rpi4, :rpi5]
display_target? = Mix.target() in display_targets

# Advance the system clock on devices without real-time clocks.
#
# On the display targets, also turn off Mesa's on-disk shader cache so GL
# rendering never writes cache files to the SD card. (`env` is a repeatable
# erlinit option; this adds to the system's own `-e` lines.)
config :nerves,
       :erlinit,
       [update_clock: true] ++
         if(display_target?, do: [env: "MESA_SHADER_CACHE_DISABLE=true"], else: [])

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

  # NOTE: at runtime `UniversalProxy.ESPHome.MdnsAdapter` re-sets this list
  # to also advertise the device's unique node name (e.g.
  # `universal-proxy-07507f.local`) — the MAC suffix isn't known at compile
  # time. `universal_proxy.local` stays as the documented single-device
  # convenience URL; with several proxies on one LAN any of them may answer
  # it, so the unique alias is the one to rely on.
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

# Bluetooth: the BlueZ migration (UniversalProxy.Bluez) drives the controller
# through the kernel (`hci0`) over D-Bus. blue_heron's raw mini-UART stack has
# been removed (it's no longer a dependency — see mix.exs): the two cannot
# coexist on one chip, and blue_heron crash-loops at boot without a transport.
# Hence no `:blue_heron` config here anymore.

# Audio enumerate: on target, union the local ALSA cards with connected A2DP
# headsets (via bluez-alsa) so a Bluetooth headset surfaces as a Sendspin
# output through the existing pipeline. Host/test stay on NullEnumerate
# (config/test.exs); host dev uses the bare ALSA Enumerate (default).
config :universal_proxy,
  audio_enumerate_module: UniversalProxy.Audio.Enumerate.Composite

# HDMI-CEC: the custom rpi0_2/rpi3/rpi4/rpi5 systems (>= v0.1.12) have the
# vc4 HDMI CEC driver. A target without it has no /dev/cecN, so the
# subsystem finds no adapters and starts nothing.
config :universal_proxy, UniversalProxy.Cec, enabled: true

# TV UI on the Pi HDMI output (`UniversalProxy.Display`), display targets only.
# Every other target leaves the subsystem off (config.exs) and has no
# `:emerge` dependency, so `:emerge` is configured only where it exists.
if display_target? do
  # Emerge only knows stock Nerves systems; on our custom systems it would
  # default to a headless-only NIF, so pick the variant explicitly. CPU raster
  # is always compiled in, so `drm: [:raster, :opengl]` fetches the single
  # `drm_opengl` NIF, which serves both `renderer: [api: :raster]` (CPU KMS
  # dumb buffers) and `:opengl`/`:auto` (GLES2 via GBM/EGL, falling back to
  # raster if GL fails to start). But that NIF has libgbm.so.1 as a hard
  # NEEDED, so it will not load on a rootfs without Mesa: rpi4/rpi5 ship
  # Mesa; rpi3/rpi0_2 do not yet, so they get the GPU-free `drm` NIF (raster
  # only) unless UP_DISPLAY_GL=1 is set for a build against a Mesa-enabled
  # system. Mix recompiles emerge when this changes, but the previous
  # variant's .so stays in _build/<target>_<env>/lib/emerge/priv/native and
  # would ship too: `mix deps.clean emerge --build` after switching.
  display_gl? =
    Mix.target() in [:rpi4, :rpi5] or System.get_env("UP_DISPLAY_GL") in ["1", "true"]

  config :emerge,
    compiled_backends: [drm: if(display_gl?, do: [:raster, :opengl], else: [:raster])]

  # `autostart: false` while the spike benchmarks drive the viewport by hand
  # (see `UniversalProxy.Display.Bench`).
  config :universal_proxy, UniversalProxy.Display,
    enabled: true,
    renderer: UniversalProxy.Display.Renderer.Emerge,
    autostart: false,
    # Emerge's paint-layer cache defaults to 640 MiB, far above the CMA
    # pool GL render targets come from; the 512 MB/1 GB boards get less.
    layer_cache_mb: if(Mix.target() in [:rpi3, :rpi0_2], do: 48, else: 128),
    # Ask for 720p on the A53 boards, where 1080p CPU raster is the main
    # frame-budget risk (an automatic-selection hint, not a pinned mode).
    preferred_size: if(Mix.target() in [:rpi3, :rpi0_2], do: {1280, 720}, else: nil)
end

# Sendspin display roles on the HDMI output's player, for the targets that
# will drive a TV UI. Still off (config.exs) until the TV UI ships: once on,
# Music Assistant streams visualizer data for that player all the time.
# Artwork lives on tmpfs.
if Mix.target() in [:rpi0_2, :rpi3, :rpi4, :rpi5] do
  config :universal_proxy, UniversalProxy.Audio.DisplayRoles, artwork_root: "/tmp/up_artwork"
end

# Import target specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
# Uncomment to use target specific configurations

# import_config "#{Mix.target()}.exs"
