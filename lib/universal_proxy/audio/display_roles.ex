defmodule UniversalProxy.Audio.DisplayRoles do
  @moduledoc """
  Which audio output's `sendspin_player` carries the Sendspin display roles
  (metadata, controller, color, artwork, visualizer) for the HDMI TV UI,
  and the options it is started with.

  At most one output gets them: the first HDMI output whose DRM connector
  reports `connected`, preferring HDMI 0. When no connector reports
  `connected` (no DRM sysfs, or a TV that drops hotplug detect in standby)
  the lowest-numbered HDMI output is used, so a single-port Pi always puts
  the roles on its HDMI player. The choice is made when a player spawns;
  the roles are part of the binary's `client/hello`, so a later change of
  connector only takes effect on that output's next respawn.

  Configured under `config :universal_proxy, #{inspect(__MODULE__)}`:

    * `:enabled` - off by default; on for the display targets.
    * `:artwork_root` - artwork files go to `<root>/<output client_id>`
      (tmpfs `/tmp/up_artwork` on target).
    * `:artwork_size` - `{width, height}` the server scales artwork to.
    * `:artwork_keep` - how many displayed artwork files to keep.
    * `:viz_bins`, `:viz_rate`, `:viz_offset_ms` - visualizer spectrum bins,
      frames per second, and how far ahead of display time frames arrive.
  """

  alias UniversalProxy.Audio.Store

  @type player_opts :: %{
          artwork_dir: String.t(),
          artwork_size: {pos_integer(), pos_integer()},
          artwork_keep: pos_integer(),
          viz_bins: pos_integer(),
          viz_rate: pos_integer(),
          viz_offset_ms: non_neg_integer()
        }

  @type connector_status :: :connected | :disconnected | :unknown

  @defaults [
    enabled: false,
    artwork_size: {480, 480},
    artwork_keep: 8,
    viz_bins: 32,
    viz_rate: 20,
    viz_offset_ms: 100
  ]

  @doc "The effective config: application env over the defaults."
  @spec config() :: keyword()
  def config do
    Keyword.merge(@defaults, Application.get_env(:universal_proxy, __MODULE__, []))
  end

  @doc """
  The output key that should carry the display roles, or `nil` when no
  HDMI output is present. `status_fun` maps an HDMI port number to its
  DRM connector status.
  """
  @spec choose(
          [%{required(:key) => Store.output_key(), optional(any()) => any()}],
          (non_neg_integer() ->
             connector_status())
        ) ::
          Store.output_key() | nil
  def choose(outputs, status_fun) when is_function(status_fun, 1) do
    hdmi =
      outputs
      |> Enum.flat_map(fn %{key: key} ->
        case Store.hdmi_port(key) do
          nil -> []
          port -> [{port, key}]
        end
      end)
      |> Enum.sort()

    case Enum.find(hdmi, fn {port, _key} -> status_fun.(port) == :connected end) ||
           List.first(hdmi) do
      {_port, key} -> key
      nil -> nil
    end
  end

  @doc "The `Audio.Player` `:display_roles` option for an output."
  @spec player_opts(%{required(:client_id) => String.t(), optional(any()) => any()}, keyword()) ::
          player_opts()
  def player_opts(%{client_id: client_id}, cfg \\ config()) do
    %{
      artwork_dir:
        Path.join(Keyword.get(cfg, :artwork_root) || default_artwork_root(), client_id),
      artwork_size: Keyword.fetch!(cfg, :artwork_size),
      artwork_keep: Keyword.fetch!(cfg, :artwork_keep),
      viz_bins: Keyword.fetch!(cfg, :viz_bins),
      viz_rate: Keyword.fetch!(cfg, :viz_rate),
      viz_offset_ms: Keyword.fetch!(cfg, :viz_offset_ms)
    }
  end

  @doc """
  Status of the DRM connector for HDMI port `port` (`HDMI-A-<port + 1>`),
  read from `<drm_root>/card*-HDMI-A-<n>/status`.
  """
  @spec connector_status(non_neg_integer(), String.t()) :: connector_status()
  def connector_status(port, drm_root \\ "/sys/class/drm") do
    case Path.wildcard(Path.join(drm_root, "card*-HDMI-A-#{port + 1}/status")) do
      [] ->
        :unknown

      paths ->
        statuses = Enum.map(paths, &read_status/1)

        cond do
          :connected in statuses -> :connected
          :disconnected in statuses -> :disconnected
          true -> :unknown
        end
    end
  end

  defp read_status(path) do
    case File.read(path) do
      {:ok, "connected" <> _} -> :connected
      {:ok, "disconnected" <> _} -> :disconnected
      _ -> :unknown
    end
  end

  defp default_artwork_root, do: Path.join(System.tmp_dir!(), "up_artwork")
end
