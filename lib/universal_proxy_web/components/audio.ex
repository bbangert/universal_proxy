defmodule UniversalProxyWeb.Components.Audio do
  @moduledoc """
  Shared helpers + function components for Sendspin audio rendering.

  The Audio tab (`AudioLive`) and the Overview audio summary
  (`OverviewLive`) share the same state machine and several visual
  primitives. Centralising them here keeps the two surfaces from
  drifting — the original split between "Idle" (Audio) and "Stopped"
  (Overview) was a footgun that this module exists to prevent
  recurring.
  """

  use Phoenix.Component

  @type status :: %{label: String.t(), variant: atom(), tint_var: String.t()}

  @doc """
  Compute the user-facing audio status from an output map.

  Returns a struct-shaped map with:

    * `:label` — copy to render in the badge ("Streaming" / "Connected"
      / "Searching" / "Disabled").
    * `:variant` — the badge variant (`:success`, `:accent`, `:warning`,
      `:neutral`). Maps directly to the existing badge component.
    * `:tint_var` — a CSS `var(--hs-…)` reference used to colour the
      row spine on Overview and the card spine on AudioLive.

  Both `:disconnected` and `:unknown` connection collapse to
  "Searching" — by the time a user is looking at a status indicator,
  the difference between "we used to be connected and lost it" and
  "we haven't heard yet" doesn't matter to them.
  """
  @spec audio_status(map()) :: status()
  def audio_status(out) do
    enabled? = out.enabled
    connection = Map.get(out, :connection, :unknown)
    stream = Map.get(out, :stream)

    cond do
      not enabled? ->
        %{label: "Disabled", variant: :neutral, tint_var: "var(--hs-fg-4)"}

      connection == :connected and not is_nil(stream) ->
        %{label: "Streaming", variant: :success, tint_var: "var(--hs-success)"}

      connection == :connected ->
        %{label: "Connected", variant: :accent, tint_var: "var(--hs-accent)"}

      true ->
        # Both `:disconnected` and `:unknown` (no event observed yet).
        %{label: "Searching", variant: :warning, tint_var: "var(--hs-warning)"}
    end
  end

  @doc "True when the player is enabled, connected, and has a current stream snapshot."
  @spec audio_streaming?(map()) :: boolean()
  def audio_streaming?(out) do
    out.enabled and Map.get(out, :connection) == :connected and not is_nil(Map.get(out, :stream))
  end

  @doc "True when the player is enabled and connected (whether or not a stream is active)."
  @spec audio_connected?(map()) :: boolean()
  def audio_connected?(out) do
    out.enabled and Map.get(out, :connection) == :connected
  end

  @doc """
  Map a 0–100 volume to the speaker glyph's "wave count" so the icon
  visually tracks loudness: silence → no waves, normal → one wave,
  loud → two waves.
  """
  @spec speaker_level(integer() | any()) :: 0..2
  def speaker_level(volume) when is_integer(volume) and volume > 60, do: 2
  def speaker_level(volume) when is_integer(volume) and volume > 0, do: 1
  def speaker_level(_), do: 0

  @doc """
  Build a human-readable stream label from a stream-info map (the
  shape `Audio.Player`/`Audio.Server` produce for `stream_start`
  events).

  Returns `"Streaming"` when no useful fields are present (or when
  the input is `nil`), so callers can use this in a position where
  some label is expected.
  """
  @spec stream_label(map() | nil | any()) :: String.t()
  def stream_label(nil), do: "Streaming"

  def stream_label(%{} = stream) do
    parts =
      [
        stream
        |> Map.get(:codec)
        |> as_label()
        |> case do
          nil -> nil
          codec -> String.upcase(codec)
        end,
        stream |> Map.get(:sample_rate) |> as_khz(),
        stream |> Map.get(:bit_depth) |> as_bit_depth()
      ]
      |> Enum.reject(&is_nil/1)

    case parts do
      [] -> "Streaming"
      _ -> Enum.join(parts, " · ")
    end
  end

  def stream_label(_), do: "Streaming"

  defp as_label(v) when is_binary(v), do: v
  defp as_label(_), do: nil

  defp as_khz(v) when is_integer(v) and v > 0, do: "#{div(v, 1000)} kHz"
  defp as_khz(_), do: nil

  defp as_bit_depth(v) when is_integer(v) and v > 0, do: "#{v}-bit"
  defp as_bit_depth(_), do: nil

  @doc """
  Five-bar animated EQ component.

  Active state animates each bar on a staggered CSS keyframe (see
  `assets/css/app.css` `audio-eq-{0..4}`). Inactive shows a static
  shallow waveform — useful as a visual cue that audio *would* play
  here when it's not currently flowing (e.g., the "Disabled" stream
  banner uses a static EQ as the icon).

  The colour inherits via `currentColor` from the surrounding text
  element, so the bars match the badge tint of whatever block they
  live in (audio-tint when streaming, fg-3 when inactive).
  """
  attr(:active, :boolean, required: true)

  def eq_bars(assigns) do
    ~H"""
    <span class={["audio-eq", @active && "audio-eq--active"]}>
      <span class="audio-eq__bar"></span>
      <span class="audio-eq__bar"></span>
      <span class="audio-eq__bar"></span>
      <span class="audio-eq__bar"></span>
      <span class="audio-eq__bar"></span>
    </span>
    """
  end
end
