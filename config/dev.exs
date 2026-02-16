import Config

# For development, we disable any cache and enable
# debugging and code reloading.
#
# The watchers configuration can be used to run external
# watchers to your application. For example, we use it
# with esbuild to bundle .js and .css sources.
config :universal_proxy, UniversalProxyWeb.Endpoint,
  # Binding to loopback ipv4 address prevents access from other machines.
  # Change to `ip: {0, 0, 0, 0}` to allow access from other machines.
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  debug_errors: true,
  secret_key_base: "sODMOCqDOBh6ykWCXcIW3Y19hDlM4b8Y99/ExyZPE6OeBEc7z+3FgbXlM/kqW2Vm"

# Asset watchers, code reloading, and live reload are host-only concerns.
# On Nerves targets (MIX_ENV=dev, MIX_TARGET!=host), the Esbuild and Tailwind
# applications are not started, so watchers must not be configured.
if Mix.target() == :host do
  config :universal_proxy, UniversalProxyWeb.Endpoint,
    code_reloader: true,
    watchers: [
      esbuild: {Esbuild, :install_and_run, [:default, ~w(--sourcemap=inline --watch)]},
      tailwind: {Tailwind, :install_and_run, [:default, ~w(--watch)]}
    ]

  # Watch static and templates for browser reloading.
  config :universal_proxy, UniversalProxyWeb.Endpoint,
    live_reload: [
      patterns: [
        ~r"priv/static/.*(js|css|png|jpeg|jpg|gif|svg)$"E,
        ~r"priv/gettext/.*(po)$"E,
        ~r"lib/universal_proxy_web/(controllers|live|components)/.*(ex|heex)$"E
      ]
    ]
end

# Enable dev routes for dashboard and mailbox
config :universal_proxy, dev_routes: true

# Do not include metadata nor timestamps in development logs
config :logger, :console, format: "[$level] $message\n"

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime
