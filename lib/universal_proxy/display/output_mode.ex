defmodule UniversalProxy.Display.OutputMode do
  @moduledoc """
  Picks the display mode the renderer pins, from the connector's advertised
  modes (`EmergeSkia.drm_outputs/1` maps: `:width`, `:height`,
  `:refresh_hz`, `:preferred`, `:interlaced`), reads a mode's size, and
  finds the DRM card a connector belongs to (`connector_card/3`).

  The renderer always passes an explicit mode instead of a size hint, so it
  knows the output size up front: Emerge's DRM backend reports the size
  only as a resize event emitted while it starts, before the viewport's
  input subscription is live, so that first report never arrives.

  `choose/2` mirrors Emerge's automatic selection: the mode closest to the
  wanted size (the TV's preferred mode's size without a hint), then the
  highest refresh, then the preferred flag, then the largest area.
  Interlaced modes are only used when nothing else is advertised.
  """

  @type mode :: %{
          required(:width) => pos_integer(),
          required(:height) => pos_integer(),
          optional(atom()) => term()
        }

  @doc "The mode to use for `wanted` (`{width, height}` or `nil`), or `nil` without modes."
  @spec choose([mode()], {pos_integer(), pos_integer()} | nil) :: mode() | nil
  def choose([], _wanted), do: nil

  def choose(modes, wanted) do
    candidates =
      case Enum.reject(modes, &Map.get(&1, :interlaced, false)) do
        [] -> modes
        progressive -> progressive
      end

    target = wanted || preferred_size(candidates)
    Enum.min_by(candidates, &score(&1, target))
  end

  @doc "A mode's `{width, height}`: a mode map, or an Emerge mode id (`\"WxH:...\"`)."
  @spec size(mode() | String.t() | nil) :: {pos_integer(), pos_integer()} | nil
  def size(%{width: w, height: h}) when is_integer(w) and w > 0 and is_integer(h) and h > 0,
    do: {w, h}

  def size(id) when is_binary(id) do
    with [dims | _rest] <- String.split(id, ":", parts: 2),
         [w, h] <- String.split(dims, "x"),
         {w, ""} when w > 0 <- Integer.parse(w),
         {h, ""} when h > 0 <- Integer.parse(h) do
      {w, h}
    else
      _ -> nil
    end
  end

  def size(_mode), do: nil

  @doc """
  The mode an external KMS renderer (the MilkDrop renderer) should present
  in on an output the viewport reported as `size`: that size with no
  refresh, so the renderer keeps the mode the CRTC scans out when it
  starts (Emerge's, whatever its refresh: 50, 60 or 120 Hz) and there is
  no modeset to leave the HDMI audio clock stale.
  """
  @spec renderer_mode({pos_integer(), pos_integer()}) :: %{
          width: pos_integer(),
          height: pos_integer()
        }
  def renderer_mode({width, height})
      when is_integer(width) and width > 0 and is_integer(height) and height > 0,
      do: %{width: width, height: height}

  @doc """
  The DRM card node (`<dri_dir>/cardN`) that has `connector` (a kernel
  connector name, `"HDMI-A-1"`), from the card's sysfs connector entry
  `<sysfs_dir>/cardN-<connector>`; `nil` when no card with a node has it.
  Of several, the first in Emerge's scan order (sorted card paths).
  """
  @spec connector_card(String.t(), Path.t(), Path.t()) :: Path.t() | nil
  def connector_card(connector, sysfs_dir \\ "/sys/class/drm", dri_dir \\ "/dev/dri")

  def connector_card(connector, sysfs_dir, dri_dir) when is_binary(connector) do
    with true <- connector =~ ~r/\A[A-Za-z0-9-]{1,32}\z/,
         {:ok, entries} <- File.ls(sysfs_dir) do
      entries
      |> Enum.flat_map(fn entry ->
        case Regex.run(~r/\A(card\d+)-(.+)\z/, entry) do
          [_entry, card, ^connector] -> [Path.join(dri_dir, card)]
          _other -> []
        end
      end)
      |> Enum.filter(&File.exists?/1)
      |> Enum.sort()
      |> List.first()
    else
      _ -> nil
    end
  end

  def connector_card(_connector, _sysfs_dir, _dri_dir), do: nil

  defp preferred_size(modes) do
    case Enum.find(modes, &Map.get(&1, :preferred, false)) do
      nil -> nil
      mode -> {mode.width, mode.height}
    end
  end

  defp score(mode, target) do
    distance =
      case target do
        {w, h} -> (mode.width - w) ** 2 + (mode.height - h) ** 2
        nil -> 0
      end

    refresh = -round(Map.get(mode, :refresh_hz) || 0)
    preferred = if Map.get(mode, :preferred, false), do: 0, else: 1
    {distance, refresh, preferred, -(mode.width * mode.height)}
  end
end
