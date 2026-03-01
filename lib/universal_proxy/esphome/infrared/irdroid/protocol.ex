defmodule UniversalProxy.ESPHome.Infrared.Irdroid.Protocol do
  @moduledoc """
  Pure functional state machine for IRDroid / IR Toy v2.5+ dedicated-mode
  protocol framing.

  Firmware v2.5 separates transmit and receive into dedicated modes:

  | Command | Mode   | Description                                       |
  | ------- | ------ | ------------------------------------------------- |
  | `'m'`   | `IR_R` | Dedicated receive -- streams 16-bit BE timing     |
  | `'n'`   | `IR_T` | Dedicated transmit -- accepts `0x03` TX command   |
  | `0x00`  | reset  | Exit any mode, return to main                     |
  | `'v'`   | --     | Report version (4 bytes)                          |

  All functions are pure -- no processes, no side effects. The `feed/2`
  function is a state machine that parses incoming bytes into structured
  actions, following the same pattern as `ZWave.Parser`.

  ## Timing conversion

  The device uses 16-bit timer counts at ~21.3333 us per count
  (48 MHz / 256 prescaler). Conversion:

  - Device -> ESPHome: `round(raw_count * 21.3333)` us, alternating sign
  - ESPHome -> Device: `round(abs(us) / 21.3333)` as big-endian uint16

  Reference: https://github.com/Irdroid/USB_Infrared_Transceiver
  """

  import Bitwise

  @us_per_count 48_000_000 / 256 / 1_000_000
  @count_to_us 1 / @us_per_count

  @type mode :: :idle | :version | :mode_ack | :receive | :transmit

  @type action ::
          {:version, non_neg_integer(), non_neg_integer()}
          | {:mode_entered, String.t()}
          | {:rx_timings, [integer()]}
          | :tx_complete
          | {:tx_error, :buffer_underrun}
          | :rx_overflow

  @type t :: %__MODULE__{
          mode: mode(),
          buffer: binary(),
          pulse: boolean(),
          rx_timings: [integer()]
        }

  defstruct mode: :idle,
            buffer: <<>>,
            pulse: true,
            rx_timings: []

  @doc "Returns a new protocol state."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  # -- Command builders (pure, return binaries) --

  @doc "Reset command -- exit current mode, return to main."
  @spec reset() :: binary()
  def reset, do: <<0x00>>

  @doc "Enter dedicated receive mode."
  @spec enter_receive_mode() :: binary()
  def enter_receive_mode, do: "m"

  @doc "Enter dedicated transmit mode."
  @spec enter_transmit_mode() :: binary()
  def enter_transmit_mode, do: "n"

  @doc "Request firmware version."
  @spec get_version() :: binary()
  def get_version, do: "v"

  @doc """
  Encode a carrier frequency setup command.

  PR2 = round(48_000_000 / (16 * freq_hz)) - 1, clamped to 0..255.
  The second byte after 0x06 is the duty cycle (0 = 50% default).
  """
  @spec encode_carrier(pos_integer()) :: binary()
  def encode_carrier(freq_hz) when is_integer(freq_hz) and freq_hz > 0 do
    pr2 = round(48_000_000 / (16 * freq_hz)) - 1
    pr2 = pr2 |> max(0) |> min(255)
    <<0x06, pr2::8, 0x00>>
  end

  @doc """
  Encode a transmit payload for dedicated TX mode.

  Prepends `0x25` (notify-on-complete) and `0x03` (start transmit),
  then the timing data as big-endian uint16 pairs, terminated with `0xFFFF`.

  ## Options

    * `:repeat_count` -- number of times to repeat (default 1)

  """
  @spec encode_transmit([integer()], keyword()) :: binary()
  def encode_transmit(timings, opts \\ []) do
    repeat = Keyword.get(opts, :repeat_count, 1) |> max(1)

    timing_bytes =
      timings
      |> Enum.map(fn us ->
        count = round(abs(us) * @us_per_count)
        count = count |> max(1) |> min(0xFFFE)
        <<count::big-unsigned-16>>
      end)
      |> IO.iodata_to_binary()

    payload = timing_bytes <> <<0xFF, 0xFF>>

    repeated =
      if repeat > 1 do
        List.duplicate(payload, repeat) |> IO.iodata_to_binary()
      else
        payload
      end

    <<0x25, 0x03>> <> repeated
  end

  # -- Parser (feed incoming bytes, return {new_state, [action]}) --

  @doc """
  Feed incoming serial bytes into the protocol state machine.

  Returns `{new_state, actions}` where actions is a list of tuples
  describing parsed events.
  """
  @spec feed(t(), binary()) :: {t(), [action()]}
  def feed(%__MODULE__{} = state, <<>>) do
    {state, []}
  end

  def feed(%__MODULE__{} = state, data) when is_binary(data) do
    combined = state.buffer <> data
    parse(state, combined, [])
  end

  # -- Version response: "V" <hw_digit> <fw_h> <fw_l> --

  defp parse(%{mode: :version} = state, <<_v, hw, fw_h, fw_l, rest::binary>>, actions) do
    hw_version = hw - ?0
    fw_version = (fw_h - ?0) * 10 + (fw_l - ?0)
    state = %{state | mode: :idle, buffer: <<>>}
    parse(state, rest, actions ++ [{:version, hw_version, fw_version}])
  end

  defp parse(%{mode: :version} = state, partial, actions) do
    {%{state | buffer: partial}, actions}
  end

  # -- Mode acknowledgement: "S01" (3 bytes) --

  defp parse(%{mode: :mode_ack} = state, <<s, d1, d2, rest::binary>>, actions) do
    version_str = <<s, d1, d2>>
    state = %{state | mode: :idle, buffer: <<>>}
    parse(state, rest, actions ++ [{:mode_entered, version_str}])
  end

  defp parse(%{mode: :mode_ack} = state, partial, actions) do
    {%{state | buffer: partial}, actions}
  end

  # -- Receive mode: 16-bit BE timing pairs, 0xFFFF = terminator --
  # Six consecutive 0xFF bytes indicate device overflow

  defp parse(%{mode: :receive} = state, <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, rest::binary>>, actions) do
    state = %{state | rx_timings: [], pulse: true, buffer: <<>>}
    parse(state, rest, actions ++ [:rx_overflow])
  end

  defp parse(%{mode: :receive} = state, <<hi, lo, rest::binary>>, actions) do
    raw = (hi <<< 8) ||| lo

    if raw == 0xFFFF do
      timings = Enum.reverse(state.rx_timings)
      state = %{state | rx_timings: [], pulse: true, buffer: <<>>}

      if timings == [] do
        parse(state, rest, actions)
      else
        parse(state, rest, actions ++ [{:rx_timings, timings}])
      end
    else
      us = round(raw * @count_to_us)
      timing = if state.pulse, do: us, else: -us
      state = %{state | rx_timings: [timing | state.rx_timings], pulse: not state.pulse}
      parse(state, rest, actions)
    end
  end

  defp parse(%{mode: :receive} = state, partial, actions) when byte_size(partial) < 2 do
    {%{state | buffer: partial}, actions}
  end

  # -- Transmit mode completion signals --

  defp parse(%{mode: :transmit} = state, <<"C", rest::binary>>, actions) do
    state = %{state | mode: :idle, buffer: <<>>}
    parse(state, rest, actions ++ [:tx_complete])
  end

  defp parse(%{mode: :transmit} = state, <<"F", rest::binary>>, actions) do
    state = %{state | mode: :idle, buffer: <<>>}
    parse(state, rest, actions ++ [{:tx_error, :buffer_underrun}])
  end

  defp parse(%{mode: :transmit} = state, <<_byte, rest::binary>>, actions) do
    parse(state, rest, actions)
  end

  defp parse(%{mode: :transmit} = state, <<>>, actions) do
    {%{state | buffer: <<>>}, actions}
  end

  # -- Idle mode: detect response headers --

  defp parse(%{mode: :idle} = state, <<"V", rest::binary>>, actions) do
    parse(%{state | mode: :version, buffer: <<>>}, <<"V", rest::binary>>, actions)
  end

  defp parse(%{mode: :idle} = state, <<"S", rest::binary>>, actions) do
    parse(%{state | mode: :mode_ack, buffer: <<>>}, <<"S", rest::binary>>, actions)
  end

  defp parse(%{mode: :idle} = state, <<_byte, rest::binary>>, actions) do
    parse(state, rest, actions)
  end

  defp parse(%{mode: :idle} = state, <<>>, actions) do
    {%{state | buffer: <<>>}, actions}
  end

  # -- Mode transition helpers (called by DeviceWorker) --

  @doc "Transition the parser state to receive mode."
  @spec set_receive_mode(t()) :: t()
  def set_receive_mode(%__MODULE__{} = state) do
    %{state | mode: :receive, buffer: <<>>, rx_timings: [], pulse: true}
  end

  @doc "Transition the parser state to transmit mode."
  @spec set_transmit_mode(t()) :: t()
  def set_transmit_mode(%__MODULE__{} = state) do
    %{state | mode: :transmit, buffer: <<>>}
  end

  @doc "Transition the parser state to idle mode."
  @spec set_idle(t()) :: t()
  def set_idle(%__MODULE__{} = state) do
    %{state | mode: :idle, buffer: <<>>, rx_timings: [], pulse: true}
  end
end
