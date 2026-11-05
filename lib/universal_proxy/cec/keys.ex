defmodule UniversalProxy.Cec.Keys do
  @moduledoc """
  Remote-control keys from the TV, for the process that claimed them with
  `UniversalProxy.Cec.claim_keys/2`.

  `<User Control Pressed>`, `<Play>` and `<Deck Control>` become one key
  atom each:

  | Key | From |
  |---|---|
  | `:select` | Select (0x00), Enter (0x2B) |
  | `:up`, `:down`, `:left`, `:right` | the arrows (0x01-0x04) |
  | `:exit` | Exit/Back (0x0D) |
  | `:menu` | Root Menu (0x09) |
  | `:play` | Play (0x44), Play Function (0x60), `<Play>` forward |
  | `:pause` | Pause (0x46), `<Play>` still |
  | `:play_pause` | Pause-Play Function (0x61) |
  | `:stop` | Stop (0x45), Stop Function (0x64), `<Deck Control>` stop |
  | `:forward`, `:backward` | Forward/Backward (0x4B/0x4C, next/previous), `<Deck Control>` skip forward/reverse |
  | `:fast_forward`, `:rewind` | Fast Forward/Rewind (0x49/0x48), `<Play>` fast forward/reverse |
  | `:red`, `:green`, `:yellow`, `:blue` | F2-F4, F1 (0x72, 0x73, 0x74, 0x71) |

  Play Function (0x60) may carry a Play Mode operand; it then maps like
  `<Play>` with that mode (still → `:pause`, fast forward → `:fast_forward`,
  ...), still as a press. Without one it is `:play`.

  Anything else (numbers, channel keys, reverse or slow play, ...) is
  dropped.

  Keys fire on the press. A held key makes the TV repeat `<User Control
  Pressed>` every 200-450 ms, usually without a release in between, so a
  press of the key already held, less than 550 ms after the last one
  (the spec's follower repeat timeout), is a repeat and is dropped; a
  `<User Control Released>` ends the hold. `<Play>` and `<Deck Control>`
  are one-shot commands and always fire.
  """

  alias Circuits.CEC.Message

  @type key ::
          :select
          | :up
          | :down
          | :left
          | :right
          | :exit
          | :menu
          | :play
          | :pause
          | :play_pause
          | :stop
          | :forward
          | :backward
          | :fast_forward
          | :rewind
          | :red
          | :green
          | :yellow
          | :blue

  @typedoc "The key being held and when it was last pressed (ms), or `nil`."
  @type held :: {key(), integer()} | nil

  @repeat_ms 550

  @ui_keys %{
    select: :select,
    enter: :select,
    up: :up,
    down: :down,
    left: :left,
    right: :right,
    back: :exit,
    device_root_menu: :menu,
    play: :play,
    play_function: :play,
    pause: :pause,
    pause_play_function: :play_pause,
    stop: :stop,
    stop_function: :stop,
    skip_forward: :forward,
    skip_backward: :backward,
    fast_forward: :fast_forward,
    rewind: :rewind,
    f1_blue: :blue,
    f2_red: :red,
    f3_green: :green,
    f4_yellow: :yellow
  }

  @play_modes %{
    play_forward: :play,
    play_still: :pause,
    fast_forward_min: :fast_forward,
    fast_forward_medium: :fast_forward,
    fast_forward_max: :fast_forward,
    fast_reverse_min: :rewind,
    fast_reverse_medium: :rewind,
    fast_reverse_max: :rewind
  }

  @deck_modes %{skip_forward: :forward, skip_reverse: :backward, stop: :stop}

  @doc """
  Classifies a received message body: `{:press, key}` (repeatable),
  `{:command, key}` (one-shot), `:release`, or `:ignore`.
  """
  @spec classify(term()) :: {:press, key()} | {:command, key()} | :release | :ignore
  def classify({:user_control_pressed, cmd}), do: lookup(@ui_keys, cmd, :press)

  def classify({:user_control_pressed, :play_function, <<mode, _::binary>>}),
    do: lookup(@play_modes, play_mode(mode), :press)

  def classify({:user_control_pressed, cmd, _extra}), do: lookup(@ui_keys, cmd, :press)
  def classify(:user_control_released), do: :release
  def classify({:play, mode}), do: lookup(@play_modes, mode, :command)
  def classify({:deck_control, mode}), do: lookup(@deck_modes, mode, :command)
  def classify(_body), do: :ignore

  # The Play Mode operand as `<Play>` names it, from the library's table.
  defp play_mode(byte) do
    case Message.decode(<<0x04, Message.opcode(:play), byte>>) do
      {:ok, %Message{body: {:play, mode}}} -> mode
      _other -> nil
    end
  end

  defp lookup(table, name, kind) do
    case Map.fetch(table, name) do
      {:ok, key} -> {kind, key}
      :error -> :ignore
    end
  end

  @doc """
  Applies a classified message to the held key at monotonic time `now`
  (ms): the key to deliver (or `nil`) and the new held key.
  """
  @spec step(held(), {:press, key()} | {:command, key()} | :release | :ignore, integer()) ::
          {key() | nil, held()}
  def step({key, at}, {:press, key}, now) when now - at < @repeat_ms, do: {nil, {key, now}}
  def step(_held, {:press, key}, now), do: {key, {key, now}}
  def step(held, {:command, key}, _now), do: {key, held}
  def step(_held, :release, _now), do: {nil, nil}
  def step(held, :ignore, _now), do: {nil, held}
end
