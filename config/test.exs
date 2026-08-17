import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :universal_proxy, UniversalProxyWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "skPYVgOS63ZmbyfKrcf4OwImk+OQiYt/I5fCzPvFzMIeg2vq1HYvNxAyIkntZVKk",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# vintage_net (transitive of nerves_pack) writes /etc/resolv.conf at app
# startup. Redirect to a writable path so the test VM can boot in sandboxed
# environments (CI runners, devcontainers).
config :vintage_net, resolvconf: "/tmp/universal_proxy_test_resolv.conf"

# The application tree starts a singleton `Audio.Server` that polls
# enumeration every 5 s. On a Linux test host with ALSA outputs in
# `/proc/asound/cards` the default `Audio.Enumerate` would surface
# them and the Server would fork real `sendspin_player` binaries
# during the test suite — leaking mDNS, eating port 8928, and
# coupling the tests to host audio state. Stub it out; focused audio
# tests still supply their own `enumerate_module:` opt for
# deterministic test enumeration.
config :universal_proxy, :audio_enumerate_module, UniversalProxy.Audio.NullEnumerate

# Same hazard on the input side, and worse: the application-tree
# `Audio.Input.Server` would start a real `Audio.Input.Source` per capture
# card, each binding a listener port and registering an mDNS service for the
# duration of the suite. Focused input tests supply their own
# `enumerate_module:` opt.
config :universal_proxy, :audio_input_enumerate_module, UniversalProxy.Audio.NullEnumerate
