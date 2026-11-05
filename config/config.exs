# This file is responsible for configuring your application and its
# dependencies.
#
# This configuration file is loaded before any dependency and is restricted to
# this project.
import Config

################################################################
## Phoenix Config
################################################################

# Configures the endpoint
config :universal_proxy, UniversalProxyWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: UniversalProxyWeb.ErrorHTML, json: UniversalProxyWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: UniversalProxy.PubSub,
  live_view: [signing_salt: "universal_proxy_salt"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.17.11",
  default: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "3.4.17",
  default: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

################################################################
## Nerves Config
################################################################

# Enable the Nerves integration with Mix
Application.start(:nerves_bootstrap)

config :universal_proxy, target: Mix.target()

# Customize non-Elixir parts of the firmware. See
# https://hexdocs.pm/nerves/advanced-configuration.html for details.

config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"

# Set the SOURCE_DATE_EPOCH date for reproducible builds.
# See https://reproducible-builds.org/docs/source-date-epoch/ for more information

config :nerves, source_date_epoch: "1771115147"

################################################################
## Common Config
################################################################

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# HDMI-CEC control of the AV receiver / TV on a Pi's HDMI link (see
# `UniversalProxy.Cec`). Off here; config/target.exs turns it on for firmware.
# `:receiver_la` is the CEC logical address commands go to (5 = Audio System,
# i.e. the AVR; the TV at 0 when nothing answers there). `:osd_name` is what
# the TV/AVR shows for our input (at most 14 bytes). `:system_audio_mode`
# also sends <System Audio Mode Request> on wake, which some AVRs need but
# which can take audio away from the TV. `:transport` is the
# `Circuits.CEC.Transport` (tests use the library's fake). `:volume_link` is
# the default for outputs without a `cec_volume` setting: their volume follows
# the receiver's (`UniversalProxy.Cec.VolumeLink`), which is read every
# `:volume_poll_ms` while linked.
config :universal_proxy, UniversalProxy.Cec,
  enabled: false,
  osd_name: "UniversalProxy",
  auto_wake: true,
  volume_link: true,
  volume_poll_ms: 3_000,
  receiver_la: 5,
  system_audio_mode: false,
  scan_interval_ms: 10_000,
  transport: Circuits.CEC.Transport.Port

# TV UI on a Pi's HDMI output (see `UniversalProxy.Display`). Off here;
# config/target.exs turns it on, with the Emerge renderer, for the Pi HDMI
# targets only. `:renderer` is a `UniversalProxy.Display.Renderer` module.
#
# `:ui` is the TV UI's single on switch (keep it in step with
# `UniversalProxy.Audio.DisplayRoles`' `:enabled`): with it on, the display
# follows the HDMI output's player, claims the TV remote's CEC keys, starts
# its viewport by itself and advertises the "TV display mode" select to
# Home Assistant. With it off the subsystem stays dormant (viewport by hand
# only). `:idle_ms` / `:party_idle_ms` are the idle-blank timeouts.
#
# `:milkdrop` turns on the MilkDrop visualizer (`UniversalProxy.MilkDrop`):
# it has effect only on rpi3/rpi4/rpi5 and stays false until the mode is
# validated on hardware.
config :universal_proxy, UniversalProxy.Display,
  enabled: false,
  renderer: UniversalProxy.Display.Renderer.Null,
  ui: false,
  milkdrop: false,
  idle_ms: 120_000,
  party_idle_ms: 600_000

# The MilkDrop preset pack the device downloads on first use
# (`UniversalProxy.MilkDrop.Pack`): a release asset pinned by version, URL
# and SHA-256. No pack is published yet, so nothing is pinned.
config :universal_proxy, UniversalProxy.MilkDrop.Pack,
  version: nil,
  url: nil,
  sha256: nil

# Sendspin display roles (metadata, controller, color, artwork, visualizer)
# for the HDMI TV UI, carried by one HDMI output's player (see
# `UniversalProxy.Audio.DisplayRoles`). Off here; config/target.exs turns it
# on for the display targets. `:artwork_root` defaults to the system tmp dir.
config :universal_proxy, UniversalProxy.Audio.DisplayRoles,
  enabled: false,
  artwork_size: {480, 480},
  artwork_keep: 8,
  viz_bins: 32,
  viz_rate: 20,
  viz_offset_ms: 100

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end
