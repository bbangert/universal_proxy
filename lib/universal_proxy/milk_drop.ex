defmodule UniversalProxy.MilkDrop do
  @moduledoc """
  The MilkDrop (projectM) visualizer: a TV display mode drawn by the
  `milkdrop_renderer` port binary from a self-hosted preset pack.

  Three pieces live here:

    * `UniversalProxy.MilkDrop.Store` — DETS settings (rotation interval,
      high-frequency presets, locked preset) and the per-pack-version
      runtime skip list;
    * `UniversalProxy.MilkDrop.Pack` — downloads, verifies and extracts the
      pinned preset pack into `root/0`;
    * `UniversalProxy.Display.MilkDrop` — the renderer's Port owner, started
      by the display while the mode is active (not part of this subtree).

  `UniversalProxy.MilkDrop.Supervisor` runs Store + Pack only when
  `enabled?/0`: a supported target (`#{inspect(~w(rpi3 rpi4 rpi5)a)}`, a
  compile-time constant) **and** `config :universal_proxy,
  UniversalProxy.Display, milkdrop: true`. The flag is false everywhere
  until the mode is validated on hardware. Host tests start the subtree
  with `enabled: true` instead.

  ## PubSub (`UniversalProxy.PubSub`)

    * `settings_topic/0` (`"milkdrop:settings"`) —
      `{:milkdrop_settings, settings}` and
      `{:milkdrop_skipped, version, %{preset => reason}}`;
    * `pack_topic/0` (`"milkdrop:pack"`) — `{:milkdrop_pack, status}` on
      every `UniversalProxy.MilkDrop.Pack` status change (including
      download progress), and `{:milkdrop_pack_started, status}` each time
      a Pack process starts.
  """

  @supported_targets ~w(rpi3 rpi4 rpi5)a

  # `Mix.target/0` is unavailable at runtime in a Nerves release, so the
  # predicate is baked in at compile time.
  @supported Mix.target() in @supported_targets

  @settings_topic "milkdrop:settings"
  @pack_topic "milkdrop:pack"

  @doc "Whether this build targets hardware the renderer supports (compile-time constant)."
  @spec supported?() :: boolean()
  def supported?, do: @supported

  @doc """
  Whether the MilkDrop subsystem should run: a supported target and the
  `UniversalProxy.Display` `:milkdrop` flag on (read at runtime). Always
  false on other targets; host tests start the subtree with
  `enabled: true` instead.
  """
  @spec enabled?() :: boolean()
  if @supported do
    def enabled?, do: Keyword.get(UniversalProxy.Display.config(), :milkdrop, false) == true
  else
    def enabled?, do: false
  end

  @doc "PubSub topic for Store changes (see the moduledoc)."
  @spec settings_topic() :: String.t()
  def settings_topic, do: @settings_topic

  @doc "PubSub topic for Pack status changes (see the moduledoc)."
  @spec pack_topic() :: String.t()
  def pack_topic, do: @pack_topic

  @doc """
  Directory holding the extracted pack(s), download temporaries and the
  Store's DETS file: `/data/milkdrop` on Nerves, `_build/milkdrop` on the
  host.
  """
  @spec root() :: String.t()
  def root do
    if File.dir?("/data") do
      "/data/milkdrop"
    else
      Path.join([File.cwd!(), "_build", "milkdrop"])
    end
  end
end
