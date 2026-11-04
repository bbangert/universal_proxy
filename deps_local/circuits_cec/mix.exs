defmodule Circuits.CEC.MixProject do
  use Mix.Project

  @version "0.1.0"

  # The helper is built into $(MIX_APP_PATH)/priv, which is per target and
  # per env under _build. A priv/ directory in the source tree would make
  # Mix symlink it into _build instead, so every target would share one
  # directory and a host or foreign-arch binary could ship in firmware.
  if File.exists?(Path.join(__DIR__, "priv")) do
    Mix.raise(
      "circuits_cec: remove #{Path.join(__DIR__, "priv")}; the helper is built under _build"
    )
  end

  def project do
    [
      app: :circuits_cec,
      version: @version,
      elixir: "~> 1.15",
      description: "Linux HDMI-CEC (/dev/cecN) for Elixir via a small port helper",
      compilers: [:elixir_make | Mix.compilers()],
      make_targets: make_targets(Mix.env()),
      make_clean: ["clean"],
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [
        flags: [:missing_return, :extra_return, :unmatched_returns, :error_handling]
      ],
      package: [
        licenses: ["Apache-2.0", "BSD-3-Clause"],
        files: ["c_src", "lib", "LICENSES", "Makefile", "mix.exs", "NOTICE", "REUSE.toml"]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  # The test backend is a second build of cec_port with the ioctls stubbed
  # out. It goes to obj/, never priv/, so it can't end up in a release.
  defp make_targets(:test), do: ["all", "test-backend"]
  defp make_targets(_), do: ["all"]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:elixir_make, "~> 0.6", runtime: false},
      {:stream_data, "~> 1.1", only: :test},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false}
    ]
  end
end
