defmodule UniversalProxy.Display.Mode do
  @moduledoc """
  The TV UI's user-selectable modes and the Home Assistant select that
  exposes them.

  The select's `object_id`, name and option strings are frozen: Home
  Assistant keys the entity on the object_id and stores the option the
  user picked, so changing any of them after adoption orphans or breaks
  the entity. The same option strings are what `UniversalProxy.Audio.Store`
  persists as the HDMI output's `display_mode`.

  | Mode | Option |
  |---|---|
  | `:now_playing` | `"Now Playing"` (the default) |
  | `:visualizer` | `"Visualizer"` |
  | `:milkdrop` | `"MilkDrop"` (only while MilkDrop is enabled) |
  | `:party_qr` | `"Party QR"` |
  | `:off` | `"Off"` |

  `:milkdrop` exists only where `UniversalProxy.MilkDrop.enabled?/0` (a
  supported target with the feature flag on): elsewhere `options/1`,
  `modes/1`, `parse/2` and `cycle/3` behave as if it didn't exist, so Home
  Assistant never sees an option that can't work. Every function that
  depends on it takes that flag as its last argument (default: the live
  `UniversalProxy.MilkDrop.enabled?/0`).
  """

  alias UniversalProxy.MilkDrop

  @type t :: :now_playing | :visualizer | :milkdrop | :party_qr | :off

  @modes [
    now_playing: "Now Playing",
    visualizer: "Visualizer",
    milkdrop: "MilkDrop",
    party_qr: "Party QR",
    off: "Off"
  ]
  # The modes Up/Down on the remote step through ("Off" only comes from HA).
  @cycle [:now_playing, :visualizer, :milkdrop, :party_qr]
  # Modes that exist only behind a feature flag.
  @gated [:milkdrop]

  @doc "The select's `object_id` (frozen)."
  @spec object_id() :: String.t()
  def object_id, do: "tv_display_mode"

  @doc "The select's name (frozen)."
  @spec name() :: String.t()
  def name, do: "TV display mode"

  @doc "The select's options, in display order (frozen)."
  @spec options(boolean()) :: [String.t()]
  def options(milkdrop? \\ MilkDrop.enabled?()),
    do: Enum.map(modes(milkdrop?), &Keyword.fetch!(@modes, &1))

  @doc "Every mode that exists (MilkDrop only with `milkdrop?`)."
  @spec modes(boolean()) :: [t()]
  def modes(milkdrop? \\ MilkDrop.enabled?()),
    do: @modes |> Keyword.keys() |> Enum.filter(&available?(&1, milkdrop?))

  @doc "The mode used until the user picks one (D4)."
  @spec default() :: t()
  def default, do: :now_playing

  @doc "The option string for a mode."
  @spec to_option(t()) :: String.t()
  def to_option(mode) when is_atom(mode), do: Keyword.fetch!(@modes, mode)

  @doc """
  The mode for an option string or a mode atom; `:error` for anything
  else, MilkDrop included unless `milkdrop?`.
  """
  @spec parse(term(), boolean()) :: {:ok, t()} | :error
  def parse(mode_or_option, milkdrop? \\ MilkDrop.enabled?())

  def parse(mode, milkdrop?) when is_atom(mode) do
    if Keyword.has_key?(@modes, mode) and available?(mode, milkdrop?),
      do: {:ok, mode},
      else: :error
  end

  def parse(option, milkdrop?) when is_binary(option) do
    case Enum.find(@modes, fn {_mode, label} -> label == option end) do
      {mode, _label} -> parse(mode, milkdrop?)
      nil -> :error
    end
  end

  def parse(_other, _milkdrop?), do: :error

  @doc """
  The mode `step` places from `mode` in the remote's Up/Down cycle
  (Now Playing, Visualizer, MilkDrop when `milkdrop?`, Party QR), wrapping
  around. Off (or a mode not in the cycle) steps to Now Playing.
  """
  @spec cycle(t(), integer(), boolean()) :: t()
  def cycle(mode, step, milkdrop? \\ MilkDrop.enabled?()) when is_integer(step) do
    cycle = Enum.filter(@cycle, &available?(&1, milkdrop?))

    case Enum.find_index(cycle, &(&1 == mode)) do
      nil -> hd(cycle)
      index -> Enum.at(cycle, Integer.mod(index + step, length(cycle)))
    end
  end

  defp available?(mode, milkdrop?), do: mode not in @gated or milkdrop? == true
end
