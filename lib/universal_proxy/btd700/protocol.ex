defmodule UniversalProxy.BTD700.Protocol do
  @moduledoc """
  Pure encode/decode for the Sennheiser BTD 700 USB HID control protocol
  (no side effects).

  Every frame, both directions, is a fixed **64-byte** HID report,
  always fully zero-padded:

      byte:    0        1         2         3         4 .. 63
              RptID    Marker    Cmd/Evt   Len       payload (<= 60 bytes, zero-padded)
              0x34

  Markers: `0xFC` = event (dongle -> host, unsolicited), `0xFE` = command
  (host -> dongle), `0xFF` = response (dongle -> host). `0xFD` is defined
  by the reference driver but never used by anyone, anywhere — it is
  deliberately not implemented here.

  This module performs no I/O. `encode/2` builds an outgoing 64-byte
  command frame; `decode/1` turns one received report into a structured
  term. The same hidraw node also carries an unrelated consumer-keys HID
  collection sharing the fd — those reports do not start with `0x34` and
  must be silently ignored, not treated as protocol garbage (see the
  `:ignore` return below).
  """

  import Bitwise

  @typedoc "A structured term produced by `decode/1`."
  @type decoded ::
          {:response, atom(), term()}
          | {:event, atom(), term()}
          | {:unknown, binary()}
          | :ignore

  @report_id 0x34
  @marker_command 0xFE
  @marker_response 0xFF
  @marker_event 0xFC

  @max_payload_bytes 60

  # ── Command table (encode: atom -> cmd id) ──────────────────────────
  #
  # Only commands with a legitimate host->dongle path are listed. Notably
  # absent: 0x17 (gaming status) — it is a receive-only event id with no
  # corresponding GET command, so there is no atom that maps to it here.
  # Calling `encode/2` with an atom not in this table raises (by design —
  # encode/2's contract is known command atoms only; it is decode/1 that
  # must never crash on untrusted input).
  @command_ids %{
    get_audio_mode: 0x01,
    set_audio_mode: 0x02,
    get_supported_codecs: 0x03,
    set_codec_mask: 0x04,
    get_codec_in_use: 0x05,
    get_dongle_state: 0x06,
    get_le_audio_state: 0x07,
    get_audio_quality: 0x08,
    get_broadcast_info: 0x09,
    set_broadcast_info: 0x0A,
    get_broadcast_key: 0x0B,
    set_broadcast_key: 0x0C,
    get_broadcast_name: 0x0D,
    set_broadcast_name: 0x0E,
    get_firmware_version: 0x12,
    factory_reset: 0x13,
    bt_connect: 0x14,
    get_sink_transport: 0x15
  }

  # ── Decode-only enum maps (never build atoms dynamically from wire bytes) ──

  @audio_modes %{0 => :high_quality, 1 => :gaming, 2 => :broadcast}

  @transport_modes %{0 => :disconnected, 1 => :classic, 2 => :le_audio, 3 => :multipoint}

  # 1-based — there is no 0 value for either frequency or resolution.
  @audio_frequencies %{1 => :freq_44100, 2 => :freq_48000, 3 => :freq_96000}
  @audio_resolutions %{1 => :res_16bit, 2 => :res_24bit}

  @dongle_states %{
    0 => :none,
    1 => :disconnected,
    2 => :connected,
    3 => :streaming_audio,
    4 => :streaming_voice
  }

  @le_audio_states %{
    0 => :none,
    1 => :disconnected,
    2 => :connected,
    3 => :streaming_unicast,
    4 => :streaming_broadcast
  }

  @sink_transports %{0 => :not_available, 1 => :classic, 2 => :le_audio, 3 => :dual}

  @broadcast_states %{0 => :off_private, 1 => :on_public}
  @broadcast_encryptions %{0 => :off, 1 => :on}
  @broadcast_qualities %{0 => :standard_16k, 1 => :standard_24k, 2 => :high}

  # Codec bitmask -> atom, in ascending bit order (bit 0 first). Used for
  # both `:supported_codecs` and `:codec_in_use`, which share the same u16
  # LE mask wire shape.
  @codec_bits [
    {0, :sbc},
    {1, :aptx},
    {2, :aptx_adaptive},
    {3, :aptx_lossless},
    {4, :aptx_lite},
    {5, :lc3}
  ]

  # ── Response id table (decode: cmd id -> atom) ───────────────────────
  #
  # GET-response atoms use the bare concept name (no get_/set_ prefix).
  # Setter-echo atoms (0x02, 0x04, 0x0A, 0x0C, 0x0E, 0x13, 0x14) keep the
  # encode-side name so later phases can match `{:response, cmd, _}` to
  # complete an in-flight setter call.
  @response_ids %{
    0x01 => :audio_mode,
    0x02 => :set_audio_mode,
    0x03 => :supported_codecs,
    0x04 => :set_codec_mask,
    0x05 => :codec_in_use,
    0x06 => :dongle_state,
    0x07 => :le_audio_state,
    0x08 => :audio_quality,
    0x09 => :broadcast_info,
    0x0A => :set_broadcast_info,
    0x0B => :broadcast_key,
    0x0C => :set_broadcast_key,
    0x0D => :broadcast_name,
    0x0E => :set_broadcast_name,
    0x12 => :firmware_version,
    0x13 => :factory_reset,
    0x14 => :bt_connect,
    0x15 => :sink_transport
  }

  # ── Event id table (decode: evt id -> atom) ──────────────────────────
  @event_ids %{
    0x02 => :audio_mode,
    0x03 => :supported_codecs,
    0x04 => :codec_in_use,
    0x0F => :dongle_state,
    0x10 => :le_audio_state,
    0x11 => :audio_quality,
    0x16 => :sink_transport,
    0x17 => :gaming
  }

  @setter_echo_atoms [
    :set_audio_mode,
    :set_codec_mask,
    :set_broadcast_info,
    :set_broadcast_key,
    :set_broadcast_name,
    :factory_reset,
    :bt_connect
  ]

  # ── Encode ────────────────────────────────────────────────────────────

  @doc """
  Build an outgoing 64-byte command frame:
  `<<0x34, 0xFE, cmd_id, len, args::binary, 0-pad>>`.

    * `args` defaults to `<<>>` for bare GET commands.
    * `args` is hard-clamped to #{@max_payload_bytes} bytes. `len` (byte
      index 3) always reflects the CLAMPED length, never the caller's
      original size — this fixes an upstream reference-driver bug where
      the length byte and the actual on-wire payload length could
      disagree (upstream let `args_len` exceed 60 while only clamping the
      copy). This port always keeps them consistent.
    * `:set_broadcast_name` is special-cased: the name is truncated to 59
      bytes *before* the NUL terminator is appended, so the NUL always
      survives — the generic clamp above then only ever sees a binary
      already `<= 60` bytes (name+NUL), making it a no-op safety net here
      rather than the primary truncation point.
  """
  @spec encode(atom(), binary()) :: binary()
  def encode(cmd, args \\ <<>>)

  def encode(:set_broadcast_name, name) when is_binary(name) do
    truncated_name = binary_part(name, 0, min(byte_size(name), @max_payload_bytes - 1))
    build_frame(Map.fetch!(@command_ids, :set_broadcast_name), truncated_name <> <<0>>)
  end

  def encode(cmd, args) when is_atom(cmd) and is_binary(args) do
    build_frame(Map.fetch!(@command_ids, cmd), args)
  end

  defp build_frame(cmd_id, args) do
    clamped = binary_part(args, 0, min(byte_size(args), @max_payload_bytes))
    len = byte_size(clamped)
    padding = @max_payload_bytes - len

    <<@report_id, @marker_command, cmd_id, len>> <> clamped <> :binary.copy(<<0>>, padding)
  end

  # ── decode/1 ──────────────────────────────────────────────────────────

  @doc """
  Decode one received HID report into a structured term. `report` is a
  binary (64 bytes typically, but treated defensively — never crashes on
  short, malformed, or unrelated input):

    * `:ignore` — byte 0 isn't `0x34` at all (the shared consumer-keys
      HID collection on the same fd).
    * `{:unknown, bin}` — `0x34`-prefixed but an unrecognized marker, an
      unrecognized cmd/evt id, or too short to carry a marker/cmd/len.
    * `{:response, cmd_atom, decoded}` — marker `0xFF`. Byte 3 (`len`) is
      UNVERIFIED by firmware and never gates parsing; only the actual
      received byte count does, via pattern-match guards.
    * `{:event, evt_atom, decoded}` — marker `0xFC`. Only
      `min(byte_size(payload), declared_len)` bytes are considered
      payload (defensively sliced) before per-event decoding.
  """
  @spec decode(binary()) :: decoded()
  def decode(<<@report_id, @marker_response, cmd, _len, payload::binary>> = bin) do
    case Map.get(@response_ids, cmd) do
      nil -> {:unknown, bin}
      atom -> {:response, atom, decode_response(atom, payload)}
    end
  end

  def decode(<<@report_id, @marker_event, evt, declared_len, payload::binary>> = bin) do
    case Map.get(@event_ids, evt) do
      nil ->
        {:unknown, bin}

      atom ->
        data_len = min(byte_size(payload), declared_len)
        <<data::binary-size(^data_len), _rest::binary>> = payload
        {:event, atom, decode_event(atom, data)}
    end
  end

  # Empty report — not a 0x34 frame either, so treat it the same as any
  # other non-protocol report sharing the fd.
  def decode(<<>>), do: :ignore

  def decode(<<first, _rest::binary>>) when first != @report_id, do: :ignore

  def decode(bin) when is_binary(bin), do: {:unknown, bin}

  # ── Response decoders — offsets below are into `payload`, i.e. the
  # full-frame offset minus 4 (payload starts at full-frame byte index 4).
  # Each has an undersized-payload fallback (`%{raw: payload}`) rather
  # than crashing or forcing the whole frame to `{:unknown, _}` — the cmd
  # id was still recognized, it just arrived with fewer bytes than usual.

  # Firmware version: [0]=major, [1]=minor, [2..3]=build u16 LE.
  defp decode_response(:firmware_version, <<major, minor, build::16-little, _rest::binary>>) do
    %{major: major, minor: minor, build: build, version: "#{major}.#{minor}.#{build}"}
  end

  defp decode_response(:firmware_version, payload), do: %{raw: payload}

  # Audio mode: [0]=mode, [1]=transport.
  defp decode_response(:audio_mode, <<mode, transport, _rest::binary>>) do
    decode_audio_mode(mode, transport)
  end

  defp decode_response(:audio_mode, payload), do: %{raw: payload}

  # Supported codecs / codec in use: [0..1]=u16 LE bitmask -> atom list.
  defp decode_response(:supported_codecs, <<mask::16-little, _rest::binary>>) do
    decode_codec_mask(mask)
  end

  defp decode_response(:supported_codecs, payload), do: %{raw: payload}

  defp decode_response(:codec_in_use, <<mask::16-little, _rest::binary>>) do
    decode_codec_mask(mask)
  end

  defp decode_response(:codec_in_use, payload), do: %{raw: payload}

  # Dongle state: [0]=state.
  defp decode_response(:dongle_state, <<state, _rest::binary>>) do
    Map.get(@dongle_states, state, :unknown)
  end

  defp decode_response(:dongle_state, payload), do: %{raw: payload}

  # LE-audio state: [0]=state.
  defp decode_response(:le_audio_state, <<state, _rest::binary>>) do
    Map.get(@le_audio_states, state, :unknown)
  end

  defp decode_response(:le_audio_state, payload), do: %{raw: payload}

  # Audio quality: [0]=resolution, [1]=frequency — this WIRE order is
  # REVERSED vs the naming in the C reference struct (which lists
  # frequency before resolution). [2] must be present (per spec) but its
  # meaning is unconfirmed/reserved, so it's required by the pattern and
  # otherwise ignored.
  defp decode_response(:audio_quality, <<resolution, frequency, _reserved, _rest::binary>>) do
    %{
      resolution: Map.get(@audio_resolutions, resolution, :unknown),
      frequency: Map.get(@audio_frequencies, frequency, :unknown)
    }
  end

  defp decode_response(:audio_quality, payload), do: %{raw: payload}

  # Broadcast info: [0]=state, [1]=encryption, [2]=quality.
  defp decode_response(:broadcast_info, <<state, encryption, quality, _rest::binary>>) do
    %{
      state: Map.get(@broadcast_states, state, :unknown),
      encryption: Map.get(@broadcast_encryptions, encryption, :unknown),
      quality: Map.get(@broadcast_qualities, quality, :unknown)
    }
  end

  defp decode_response(:broadcast_info, payload), do: %{raw: payload}

  # Broadcast key: raw bytes from offset 4 to the end of the actually
  # received frame — no length prefix inside the payload, so whatever is
  # left of `payload` (which may include zero padding) is handed back
  # verbatim. An empty payload (received frame <= 4 bytes) yields `<<>>`.
  defp decode_response(:broadcast_key, payload), do: payload

  # Broadcast name: bytes up to the first NUL, or all of `payload` if no
  # NUL is present. Returned as a raw binary slice — never forced through
  # UTF-8 validation, so invalid UTF-8 can never crash this path.
  defp decode_response(:broadcast_name, payload) do
    case :binary.split(payload, <<0>>) do
      [name, _rest] -> name
      [name] -> name
    end
  end

  # Sink transport: [0]=transport.
  defp decode_response(:sink_transport, <<transport, _rest::binary>>) do
    Map.get(@sink_transports, transport, :unknown)
  end

  defp decode_response(:sink_transport, payload), do: %{raw: payload}

  # Setter-echo acks: no confirmed body, so decode to an empty map. This
  # lets a real setter ack round-trip as a recognized response (later
  # phases match `{:response, cmd, _}` to complete an in-flight call)
  # instead of falling through to `{:unknown, _}`.
  defp decode_response(atom, _payload) when atom in @setter_echo_atoms, do: %{}

  # ── Event decoders — `data` is already sliced to
  # `min(byte_size(payload), declared_len)` by `decode/1`. Each has a
  # length-guarded fallback: if `data` is shorter than the decoder needs,
  # return `%{raw: data}` (tagged with the right evt atom by the caller)
  # rather than crashing or discarding the event as unknown.

  defp decode_event(:audio_mode, <<mode, transport, _rest::binary>>) do
    decode_audio_mode(mode, transport)
  end

  defp decode_event(:audio_mode, data), do: %{raw: data}

  defp decode_event(:supported_codecs, <<mask::16-little, _rest::binary>>) do
    decode_codec_mask(mask)
  end

  defp decode_event(:supported_codecs, data), do: %{raw: data}

  defp decode_event(:codec_in_use, <<mask::16-little, _rest::binary>>) do
    decode_codec_mask(mask)
  end

  defp decode_event(:codec_in_use, data), do: %{raw: data}

  defp decode_event(:dongle_state, <<state, _rest::binary>>) do
    Map.get(@dongle_states, state, :unknown)
  end

  defp decode_event(:dongle_state, data), do: %{raw: data}

  defp decode_event(:le_audio_state, <<state, _rest::binary>>) do
    Map.get(@le_audio_states, state, :unknown)
  end

  defp decode_event(:le_audio_state, data), do: %{raw: data}

  # Same wire order as the response: [0]=resolution, [1]=frequency.
  defp decode_event(:audio_quality, <<resolution, frequency, _rest::binary>>) do
    %{
      resolution: Map.get(@audio_resolutions, resolution, :unknown),
      frequency: Map.get(@audio_frequencies, frequency, :unknown)
    }
  end

  defp decode_event(:audio_quality, data), do: %{raw: data}

  defp decode_event(:sink_transport, <<transport, _rest::binary>>) do
    Map.get(@sink_transports, transport, :unknown)
  end

  defp decode_event(:sink_transport, data), do: %{raw: data}

  # Gaming status: receive-only, no confirmed enum — decode defensively
  # as a boolean (any non-zero byte is "on").
  defp decode_event(:gaming, <<byte, _rest::binary>>), do: byte != 0
  defp decode_event(:gaming, data), do: %{raw: data}

  # ── Private shared decode helpers ────────────────────────────────────

  defp decode_audio_mode(mode, transport) do
    %{
      mode: Map.get(@audio_modes, mode, :unknown),
      transport: Map.get(@transport_modes, transport, :unknown)
    }
  end

  defp decode_codec_mask(mask) do
    for {bit, atom} <- @codec_bits, (mask >>> bit &&& 1) == 1, do: atom
  end
end
