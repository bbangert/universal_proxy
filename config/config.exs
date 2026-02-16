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

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end
