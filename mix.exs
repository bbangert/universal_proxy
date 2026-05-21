defmodule UniversalProxy.MixProject do
  use Mix.Project

  @app :universal_proxy
  @version "0.3.0"
  @all_targets [
    :bbb,
    :grisp2,
    :osd32mp1,
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
      elixir: "~> 1.19",
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
      extra_applications: [:logger, :runtime_tools],
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
      {:req, "~> 0.5"},

      # Static analysis
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},

      # UART/serial port enumeration
      {:circuits_uart, "~> 1.5"},

      # Supervised OS process management for the sendspin_player C++ binary
      {:muontrap, "~> 1.8"},

      # ESPHome Native API server library
      {:espex, "~> 0.1.2"},

      # Dependencies for all targets
      {:nerves, "~> 1.10", runtime: false},
      {:shoehorn, "~> 0.9.1"},
      {:ring_logger, "~> 0.11.0"},
      {:toolshed, "~> 0.4.0"},

      # Allow Nerves.Runtime on host to support development, testing and CI.
      # See config/host.exs for usage.
      {:nerves_runtime, "~> 0.13.0"},

      # Dependencies for all targets except :host
      {:nerves_pack, "~> 0.7.1", targets: @all_targets},

      # Vendored fork of mdns_lite — adds `MdnsLite.announce_all/0` so
      # services we publish via `add_mdns_service/1` actually trigger
      # unsolicited multicast announces per RFC 6762 §8.3. Upstream
      # 0.9.1 only emits records in reply to queries, which means peers
      # like Music Assistant's python-zeroconf don't notice newly
      # registered services until their next poll (60+ s). Track upstream
      # `nerves-networking/mdns_lite#213` for the eventual fix.
      {:mdns_lite, path: "deps_local/mdns_lite", override: true},

      # Dependencies for specific targets
      # NOTE: It's generally low risk and recommended to follow minor version
      # bumps to Nerves systems. Since these include Linux kernel and Erlang
      # version updates, please review their release notes in case
      # changes to your application are needed.
      {:nerves_system_bbb, "~> 2.19", runtime: false, targets: :bbb},
      {:nerves_system_grisp2, "~> 0.17", runtime: false, targets: :grisp2},
      {:nerves_system_osd32mp1, "~> 0.24", runtime: false, targets: :osd32mp1},
      {:nerves_system_mangopi_mq_pro, "~> 0.15", runtime: false, targets: :mangopi_mq_pro},
      {:nerves_system_qemu_aarch64, "~> 0.3", runtime: false, targets: :qemu_aarch64},
      {:nerves_system_rpi, "~> 2.0", runtime: false, targets: :rpi},
      {:nerves_system_rpi0, "~> 2.0", runtime: false, targets: :rpi0},
      {:nerves_system_rpi0_2, "~> 2.0", runtime: false, targets: :rpi0_2},
      {:nerves_system_rpi2, "~> 2.0", runtime: false, targets: :rpi2},
      {:nerves_system_rpi3, "~> 2.0", runtime: false, targets: :rpi3},
      {:nerves_system_rpi4, "~> 2.0", runtime: false, targets: :rpi4},
      {:nerves_system_rpi5, "~> 2.0", runtime: false, targets: :rpi5},
      {:nerves_system_x86_64, "~> 1.33.1", runtime: false, targets: :x86_64}
    ]
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
