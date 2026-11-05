defmodule UniversalProxy.Display.OutputMode do
  @moduledoc """
  Picks the display mode the renderer pins, from the connector's advertised
  modes (`EmergeSkia.drm_outputs/1` maps: `:width`, `:height`,
  `:refresh_hz`, `:preferred`, `:interlaced`), and reads a mode's size.

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
