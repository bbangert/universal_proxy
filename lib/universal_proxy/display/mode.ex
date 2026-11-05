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
  | `:party_qr` | `"Party QR"` |
  | `:off` | `"Off"` |
  """

  @type t :: :now_playing | :visualizer | :party_qr | :off

  @modes [now_playing: "Now Playing", visualizer: "Visualizer", party_qr: "Party QR", off: "Off"]
  @options Keyword.values(@modes)
  # The modes Up/Down on the remote step through ("Off" only comes from HA).
  @cycle [:now_playing, :visualizer, :party_qr]

  @doc "The select's `object_id` (frozen)."
  @spec object_id() :: String.t()
  def object_id, do: "tv_display_mode"

  @doc "The select's name (frozen)."
  @spec name() :: String.t()
  def name, do: "TV display mode"

  @doc "The select's options, in display order (frozen)."
  @spec options() :: [String.t()]
  def options, do: @options

  @doc "Every mode."
  @spec modes() :: [t()]
  def modes, do: Keyword.keys(@modes)

  @doc "The mode used until the user picks one (D4)."
  @spec default() :: t()
  def default, do: :now_playing

  @doc "The option string for a mode."
  @spec to_option(t()) :: String.t()
  def to_option(mode) when is_atom(mode), do: Keyword.fetch!(@modes, mode)

  @doc "The mode for an option string or a mode atom; `:error` for anything else."
  @spec parse(term()) :: {:ok, t()} | :error
  def parse(mode) when is_atom(mode) do
    if Keyword.has_key?(@modes, mode), do: {:ok, mode}, else: :error
  end

  def parse(option) when is_binary(option) do
    case Enum.find(@modes, fn {_mode, label} -> label == option end) do
      {mode, _label} -> {:ok, mode}
      nil -> :error
    end
  end

  def parse(_other), do: :error

  @doc """
  The mode `step` places from `mode` in the remote's Up/Down cycle
  (Now Playing, Visualizer, Party QR), wrapping around. Off steps to
  Now Playing.
  """
  @spec cycle(t(), integer()) :: t()
  def cycle(mode, step) when is_integer(step) do
    case Enum.find_index(@cycle, &(&1 == mode)) do
      nil -> hd(@cycle)
      index -> Enum.at(@cycle, Integer.mod(index + step, length(@cycle)))
    end
  end
end
