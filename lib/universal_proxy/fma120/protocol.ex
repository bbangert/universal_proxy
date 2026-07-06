defmodule UniversalProxy.FMA120.Protocol do
  @moduledoc """
  Pure encode/decode for the FlooCast control protocol (no side effects).

  Framing is line-based ASCII, CSR/Qualcomm BlueCore style:

      BC:<HEADER>[=<payload>]\\r\\n   # outgoing (we prepend "BC:")
      <HEADER>[=<payload>]\\r\\n      # responses (BC: stripped)

  Payloads are **hex-ASCII** unless noted — `ER` is **decimal**, `BN`/`BE`
  are UTF-8/ASCII strings, `VR` is an ASCII version string, `FD` is CSV.
  Decode is per-header; never assume a single number base.

  This module performs no I/O. `feed/2` is a stateless line accumulator;
  `decode/1` turns one complete line into a structured term; `encode/1,2`
  builds an outgoing command frame.

  Header codes and enums are transcribed from the official FlooCast source
  (`FlooMsg*.py`) plus hardware-captured live samples. A few fields
  (`FD` field-3 state byte, `FT` bits beyond bit0, `AC` field widths) are
  best-effort and finalised against real transitions during HW validation.
  """

  import Bitwise

  @typedoc "A structured term produced by `decode/1`."
  @type decoded ::
          {:version, String.t()}
          | {:audio_mode, map()}
          | {:source_state, atom()}
          | {:le_audio_state, atom()}
          | {:le_preference, :a2dp | :lea}
          | {:broadcast_mode, map()}
          | {:broadcast_name, String.t()}
          | {:broadcast_encryption, :set | :unset}
          | {:broadcast_address, binary()}
          | {:paired_device, map()}
          | {:features, map()}
          | {:active_codec, map()}
          | {:found_device, map()}
          | :ok
          | {:error, non_neg_integer()}
          | {:unknown, String.t()}

  # ── Decode-only enum maps (never String.to_atom/1 on protocol input) ──

  # ST — source state (FlooMsgSt)
  @source_states %{
    0x00 => :init,
    0x01 => :idle,
    0x02 => :pairing,
    0x03 => :connecting,
    0x04 => :connected,
    0x05 => :audio_starting,
    0x06 => :audio_streaming,
    0x07 => :audio_stopping,
    0x08 => :disconnecting,
    0x09 => :voice_starting,
    0x0A => :voice_streaming,
    0x0B => :voice_stopping
  }

  # LA — LE-audio state (FlooMsgLa)
  @le_audio_states %{
    0x00 => :disconnected,
    0x01 => :connected,
    0x02 => :unicast_stream_starting,
    0x03 => :unicast_streaming,
    0x04 => :broadcast_stream_starting,
    0x05 => :broadcast_streaming,
    0x06 => :stream_stopping
  }

  # AC — active codec id map (verbatim from FlooMsgAc)
  @codecs %{
    0x01 => :voice_cvsd,
    0x02 => :voice_msbc,
    0x03 => :a2dp_sbc,
    0x04 => :a2dp_aptx,
    0x05 => :a2dp_aptx_hd,
    0x06 => :a2dp_aptx_adaptive,
    0x07 => :lea_lc3,
    0x08 => :lea_aptx_adaptive,
    0x09 => :lea_aptx_lite,
    0x0A => :a2dp_aptx_adaptive_lossless
  }

  @line_terminator "\r\n"

  # ── Encode ──────────────────────────────────────────────────────────

  @doc """
  Build an outgoing command frame: `"BC:<HEADER>[=<payload>]\\r\\n"`.

    * `payload == nil` → a bare query (`BC:VR`).
    * integer payload `0..255` → hex-byte encoded (`"%02X"`, e.g. `BC:AM=01`).
    * binary payload → passed through verbatim (UTF-8 strings: `BN`/`BE`).
  """
  @spec encode(String.t(), nil | 0..255 | binary()) :: binary()
  def encode(header, payload \\ nil)

  def encode(header, nil) when is_binary(header) do
    "BC:" <> header <> @line_terminator
  end

  def encode(header, payload)
      when is_binary(header) and is_integer(payload) and payload in 0..255 do
    "BC:" <> header <> "=" <> hex_byte(payload) <> @line_terminator
  end

  def encode(header, payload) when is_binary(header) and is_binary(payload) do
    "BC:" <> header <> "=" <> payload <> @line_terminator
  end

  @doc "Uppercase, zero-padded 2-char hex of a byte (`5 -> \"05\"`, `255 -> \"FF\"`)."
  @spec hex_byte(0..255) :: String.t()
  def hex_byte(value) when is_integer(value) and value in 0..255 do
    value |> Integer.to_string(16) |> String.upcase() |> String.pad_leading(2, "0")
  end

  # ── feed/2 — stateless line accumulator ─────────────────────────────

  @doc """
  Append `chunk` to `buffer`, split off every complete `\\r\\n`-terminated
  line, and decode each. Returns `{remaining_buffer, [decoded]}` where
  `remaining_buffer` is the trailing partial line (carried into the next
  call). Handles partial lines split across active-mode chunks and
  multiple lines in one chunk. Empty lines are dropped.
  """
  @spec feed(binary(), binary()) :: {binary(), [decoded()]}
  def feed(buffer, chunk) when is_binary(buffer) and is_binary(chunk) do
    parts = String.split(buffer <> chunk, @line_terminator)
    {complete, [remaining]} = Enum.split(parts, -1)

    decoded =
      complete
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&decode/1)

    {remaining, decoded}
  end

  # ── decode/1 ────────────────────────────────────────────────────────

  @doc """
  Decode one complete response line (no terminator) into a structured term.
  Unknown or malformed lines decode to `{:unknown, line}` — never a crash.
  """
  @spec decode(String.t()) :: decoded()
  def decode(line) when is_binary(line) do
    case String.split(line, "=", parts: 2) do
      [header] -> decode_header(header, nil, line)
      [header, payload] -> decode_header(header, payload, line)
    end
  end

  # VR — firmware version (ASCII string, NOT hex)
  defp decode_header("VR", payload, _line) when is_binary(payload), do: {:version, payload}

  # AM — audio mode (1 byte: bits0-1 quality, bit7 variant)
  defp decode_header("AM", payload, line) do
    with_byte(payload, line, fn b ->
      quality =
        case b &&& 0x03 do
          0 -> :high_quality
          1 -> :gaming
          2 -> :broadcast
          _ -> :unknown
        end

      variant = if (b &&& 0x80) == 0, do: :fma120, else: :fma121
      {:audio_mode, %{quality: quality, variant: variant}}
    end)
  end

  # ST — source state
  defp decode_header("ST", payload, line) do
    with_byte(payload, line, fn b ->
      {:source_state, Map.get(@source_states, b, :unknown)}
    end)
  end

  # LA — LE-audio state
  defp decode_header("LA", payload, line) do
    with_byte(payload, line, fn b ->
      {:le_audio_state, Map.get(@le_audio_states, b, :unknown)}
    end)
  end

  # LF — preferred LE-audio setting (00 prefer A2DP, 01 prefer LEA)
  defp decode_header("LF", payload, line) do
    with_byte(payload, line, fn
      0 -> {:le_preference, :a2dp}
      1 -> {:le_preference, :lea}
      _ -> {:unknown, line}
    end)
  end

  # BM — broadcast (Auracast) mode bitfield
  defp decode_header("BM", payload, line) do
    with_byte(payload, line, fn b ->
      {:broadcast_mode, decode_bm(b)}
    end)
  end

  # BN — Auracast name (UTF-8 string, NOT hex)
  defp decode_header("BN", payload, _line) when is_binary(payload), do: {:broadcast_name, payload}

  # BE — Auracast encryption (00 unset, 01 set)
  defp decode_header("BE", payload, line) do
    with_byte(payload, line, fn
      0 -> {:broadcast_encryption, :unset}
      1 -> {:broadcast_encryption, :set}
      _ -> {:unknown, line}
    end)
  end

  # AD — broadcast address (48-bit, hex)
  defp decode_header("AD", payload, line) do
    case hex_to_bytes(payload) do
      {:ok, bin} -> {:broadcast_address, bin}
      :error -> {:unknown, line}
    end
  end

  # FT — feature flags (bit0 LED confirmed; bits 1-3 best-effort)
  defp decode_header("FT", payload, line) do
    with_byte(payload, line, fn b ->
      {:features,
       %{
         led: bit?(b, 0),
         aptx_lossless: bit?(b, 1),
         gatt_client: bit?(b, 2),
         usb_audio_source: bit?(b, 3)
       }}
    end)
  end

  # FN — paired/recent device, length-discriminated (best-effort; the
  # dongle in practice volunteers FD rows. Confirmed at HW validation.)
  defp decode_header("FN", payload, line) when is_binary(payload) do
    case hex_to_bytes(payload) do
      {:ok, <<idx>>} ->
        {:paired_device, %{index: idx}}

      # Normalize the MAC to an uppercase hex string so it matches FD's format
      # (FD carries the MAC as hex text). Without this, the same device keyed by
      # MAC would land under two keys, and a raw-binary MAC could crash UTF-8
      # rendering in the drawer.
      {:ok, <<idx, mac::binary-size(6)>>} ->
        {:paired_device, %{index: idx, mac: Base.encode16(mac)}}

      {:ok, <<idx, mac::binary-size(6), name::binary>>} ->
        {:paired_device, %{index: idx, mac: Base.encode16(mac), name: name}}

      _ ->
        {:unknown, line}
    end
  end

  # AC — active codec (+ RSSI, sample rates, delays). Variable length;
  # missing trailing fields default to 0.
  defp decode_header("AC", payload, line) do
    case hex_to_bytes(payload) do
      {:ok, bytes} -> {:active_codec, decode_ac(bytes)}
      :error -> {:unknown, line}
    end
  end

  # FD — found/paired device row, CSV. Field-3 state byte is kept raw AND
  # mapped to a connection state via `fd_connection_state/1` (best-effort
  # empirical map; see that function).
  defp decode_header("FD", payload, line) when is_binary(payload) do
    case String.split(payload, ",", parts: 5) do
      [index, mac, state, cod | rest] ->
        state_byte = hex_or_nil(state)

        {:found_device,
         %{
           index: hex_or_nil(index),
           mac: mac,
           state_byte: state_byte,
           connection_state: fd_connection_state(state_byte),
           cod: cod,
           name: List.first(rest)
         }}

      _ ->
        {:unknown, line}
    end
  end

  # OK / ER
  defp decode_header("OK", _payload, _line), do: :ok

  defp decode_header("ER", payload, line) when is_binary(payload) do
    # ER is DECIMAL, not hex.
    case Integer.parse(payload, 10) do
      {code, ""} -> {:error, code}
      _ -> {:unknown, line}
    end
  end

  defp decode_header(_header, _payload, line), do: {:unknown, line}

  @doc """
  Map an `FD` field-3 state byte to a connection state.

  **Empirical / best-effort.** Observed live on rpi3 across real transitions:
  `C3`/`C5`/`C6` (paired-but-idle/disconnected) → `CC` (after a `TC` connect) →
  `CB` (after a `TC` disconnect). The high nibble is constant `0xC`; the low
  nibble encodes state/flags. The map is finalised against more transitions
  during HW validation — until then, unrecognised bytes decode to `:unknown`
  (the raw `state_byte` is always preserved alongside this for inspection).
  """
  @spec fd_connection_state(integer() | nil) :: :idle | :connected | :disconnected | :unknown
  def fd_connection_state(0xCC), do: :connected
  def fd_connection_state(0xCB), do: :disconnected
  def fd_connection_state(byte) when byte in [0xC3, 0xC5, 0xC6], do: :idle
  def fd_connection_state(_), do: :unknown

  # ── Private decode helpers ──────────────────────────────────────────

  defp decode_bm(b) do
    enc_profile = b &&& 0x03

    %{
      profile: if(enc_profile in [0, 1], do: :tmap, else: :pbp),
      encryption: if(enc_profile in [1, 3], do: :encrypted, else: :unencrypted),
      quality: if(bit?(b, 2), do: :high, else: :standard),
      usb_playback: if(bit?(b, 3), do: :stop_immediately, else: :maintain_3min),
      latency:
        case b >>> 4 &&& 0x03 do
          1 -> :lowest
          2 -> :lower
          3 -> :default
          _ -> :reserved
        end,
      quality_range: if(bit?(b, 6), do: :both, else: :single),
      usb_volume: if(bit?(b, 7), do: :follow, else: :fixed)
    }
  end

  # Field widths in bytes: codec 1, rssi 1, rate 2, speaker 2, mic 2,
  # sdu 2, transport-delay 2, presentation-delay 2. RSSI is signed.
  defp decode_ac(bytes) do
    {codec_id, r1} = take_uint(bytes, 1)
    {rssi, r2} = take_uint(r1, 1)
    {rate, r3} = take_uint(r2, 2)
    {speaker, r4} = take_uint(r3, 2)
    {mic, r5} = take_uint(r4, 2)
    {sdu, r6} = take_uint(r5, 2)
    {transport, r7} = take_uint(r6, 2)
    {presentation, _} = take_uint(r7, 2)

    %{
      codec: Map.get(@codecs, codec_id, :unknown),
      codec_id: codec_id,
      rssi: signed8(rssi),
      rate: rate,
      speaker_sample_rate: speaker * 10,
      mic_sample_rate: mic * 10,
      sdu_interval: sdu,
      transport_delay: transport,
      presentation_delay: presentation
    }
  end

  defp take_uint(bin, n) do
    case bin do
      <<chunk::binary-size(^n), rest::binary>> -> {:binary.decode_unsigned(chunk, :big), rest}
      _ -> {0, <<>>}
    end
  end

  defp signed8(v) when v >= 128, do: v - 256
  defp signed8(v), do: v

  defp bit?(byte, n), do: (byte >>> n &&& 1) == 1

  # Decode a hex-byte payload, invoking `fun` with the integer value.
  # Malformed payload → {:unknown, line}.
  # Single-byte hex payload only: a clean parse to a value in 0..255. A
  # malformed multi-byte payload (e.g. "FFFF") must not reach bitwise decoders.
  defp with_byte(payload, line, fun) when is_binary(payload) do
    case Integer.parse(payload, 16) do
      {byte, ""} when byte in 0..255 -> fun.(byte)
      _ -> {:unknown, line}
    end
  end

  defp with_byte(_payload, line, _fun), do: {:unknown, line}

  defp hex_or_nil(str) do
    case Integer.parse(str, 16) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp hex_to_bytes(str) when is_binary(str) do
    case Base.decode16(str, case: :mixed) do
      {:ok, bin} -> {:ok, bin}
      :error -> :error
    end
  end

  defp hex_to_bytes(_), do: :error
end
