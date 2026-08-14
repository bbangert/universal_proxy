defmodule UniversalProxy.MixProject do
  use Mix.Project

  @app :universal_proxy
  @version "0.9.1"
  @all_targets [
    :bbb,
    :mangopi_mq_pro,
    :qemu_aarch64,
    :rpi,
    :rpi0,
    :rpi0_2,
    :rpi2,
    :rpi3,
    :rpi4,
    :rpi5,
    :x86_64
  ]

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      archives: [nerves_bootstrap: "~> 1.14"],
      # :sendspin_player runs BEFORE :app so the freshly built C++ binary
      # is in priv/ when :app finalises the application bundle. In dev/test
      # priv is a symlink (writes flow through regardless of order), but
      # release tooling that snapshots priv at the :app step would otherwise
      # miss it on a first compile.
      compilers: (Mix.compilers() -- [:app]) ++ [:sendspin_player, :app],
      listeners: listeners(Mix.target(), Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [{@app, release()}],
      aliases: aliases(),
      dialyzer: [
        plt_add_apps: [:mix],
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts",
        ignore_warnings: ".dialyzer_ignore.exs"
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind default", "esbuild default"],
      "assets.deploy": ["tailwind default --minify", "esbuild default --minify", "phx.digest"],
      # Convenience target: deploy assets, THEN build firmware. Without
      # the assets.deploy step, Tailwind class additions ship in source
      # but not in the served CSS — `mix firmware` embeds whatever
      # bundle is already in `priv/static/assets/` at build time.
      # Use this instead of bare `mix firmware` whenever frontend
      # tokens or class names have changed.
      "firmware.deploy": ["assets.deploy", "firmware"]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :runtime_tools, :ssh],
      mod: {UniversalProxy.Application, []}
    ]
  end

  def cli do
    [preferred_targets: [run: :host, test: :host]]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Phoenix LiveView
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.6", only: :dev, targets: :host},
      {:phoenix_live_view, "~> 1.0"},
      {:floki, ">= 0.30.0", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8"},
      {:esbuild, "~> 0.7", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.4", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:plug_cowboy, "~> 2.5"},
      {:req, "~> 0.7"},

      # Static analysis
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},

      # UART/serial port enumeration
      {:circuits_uart, "~> 1.5"},

      # ESPHome Native API server library
      {:espex, "~> 0.8"},

      # Dependencies for all targets
      {:nerves, "~> 1.10", runtime: false},
      {:shoehorn, "~> 0.9.1"},
      {:ring_logger, "~> 0.11.0"},
      {:toolshed, "~> 0.5"},

      # Allow Nerves.Runtime on host to support development, testing and CI.
      # See config/host.exs for usage.
      {:nerves_runtime, "~> 0.13.0"},

      # Dependencies for all targets except :host
      {:nerves_pack, "~> 0.7.1", targets: @all_targets},

      # Vendored fork of mdns_lite (upstream 0.9.2 + our patch) — adds
      # `MdnsLite.announce_all/0` + `goodbye_service/1` so services we
      # publish via `add_mdns_service/1` trigger unsolicited multicast
      # announces (RFC 6762 §8.3) and goodbyes (§10.1). Upstream 0.9.2
      # added an announce loop on *responder startup*, but that only
      # covers services present at boot — it doesn't announce services
      # registered dynamically afterward (our case: sendspin outputs
      # appearing at runtime), so the patch is still needed. Track
      # upstream `nerves-networking/mdns_lite#213` for a dynamic
      # announce-on-add API that would let us drop this fork.
      {:mdns_lite, path: "deps_local/mdns_lite", override: true},

      # blue_heron (the vendored raw-HCI fork) has been retired on rpi3 in
      # favour of the kernel BlueZ stack (`UniversalProxy.Bluez`): the two
      # cannot coexist on one chip, and blue_heron crash-loops at boot without
      # a transport. It's fully removed — no dependency, and the
      # deps_local/blue_heron submodule + .gitmodules entry have been dropped.

      # The BlueZ-over-D-Bus stack (daemons + scanning/GATT/pairing/audio
      # clients), extracted from this app into bbangert/bluez. All app wiring
      # flows through `UniversalProxy.Bluetooth.bluez_spec/0`. Available on
      # all targets so the adapters compile on host; only *started* on BT
      # targets. Also provides the app's D-Bus client (`Bluez.Rebus`, the
      # library's vendored+namespaced rebus fork) — improv's GATT/advert
      # exporters and the AudioManager use it directly, so the app carries
      # no rebus dependency of its own anymore.
      {:bluez, "~> 0.1"},

      # Improv-over-BLE Wi-Fi provisioning, extracted from this app into
      # bbangert/improv (same lineage as bluez above) and published as
      # hex improv 0.1.0 after HW validation on the interim git pin.
      {:improv, "~> 0.1"},

      # Firmware-update pipeline (GitHub-releases checker/installer,
      # fwup wrapper, Ed25519 signature verification), extracted from
      # this app into bbangert/nerves_github_updater (same lineage as
      # bluez/improv above) and published as hex nerves_github_updater
      # 0.1.0. The host wires it via the `UniversalProxy.FirmwareUpdate`
      # facade, which stays in-app.
      {:nerves_github_updater, "~> 0.1"},

      # Dependencies for specific targets
      # NOTE: It's generally low risk and recommended to follow minor version
      # bumps to Nerves systems. Since these include Linux kernel and Erlang
      # version updates, please review their release notes in case
      # changes to your application are needed.
      {:nerves_system_bbb, "~> 2.30", runtime: false, targets: :bbb},
      {:nerves_system_mangopi_mq_pro, "~> 0.17", runtime: false, targets: :mangopi_mq_pro},
      {:nerves_system_qemu_aarch64, "~> 0.4", runtime: false, targets: :qemu_aarch64}
    ] ++ up_nerves_systems()
  end

  # Custom Nerves systems (forks of upstream) with BlueZ + D-Bus and USB
  # support: kernel BT serdev/btusb + btbcm/rtl_bt firmware, USB-audio
  # (snd-usb-audio — DAC playback + ADC capture), dbus, bluez5-utils — so the
  # Bluetooth proxy and USB audio work on each custom-system target in
  # @up_systems_targets (the upstream systems above keep their stock images).
  # Prebuilt artifacts are pulled from the releases repo; no local buildroot
  # required (host must be linux/x86_64). rpi/rpi2 have no onboard BT but
  # support USB BT dongles; x86_64 omits the Pi-only BT firmware package. One
  # pinned tag for all of them — bump @up_systems_tag to cut a new release.
  @up_systems_tag "v0.1.6"
  @up_systems_targets [:rpi, :rpi0, :rpi0_2, :rpi2, :rpi3, :rpi4, :rpi5, :x86_64]

  defp up_nerves_systems do
    Enum.map(@up_systems_targets, fn target ->
      {:"nerves_system_#{target}",
       github: "bbangert/nerves_systems_universal_proxy",
       sparse: to_string(target),
       tag: @up_systems_tag,
       runtime: false,
       targets: target,
       override: true}
    end)
  end

  def release do
    [
      overwrite: true,
      # Erlang distribution is not started automatically.
      # See https://hexdocs.pm/nerves_pack/readme.html#erlang-distribution
      cookie: "#{@app}_cookie",
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]]
    ]
  end

  defp listeners(:host, :dev), do: [Phoenix.CodeReloader]
  defp listeners(_, _), do: []
end
