defmodule UniversalProxy.Sendspin.Wire do
  @moduledoc """
  Pure Sendspin message codecs: no process, no I/O, no crypto.

  Covers every wire layer a `source@v1` client touches, per
  `research/aiosendspin-ground-truth.md` (fetched from `Sendspin/spec` and
  `Sendspin/aiosendspin` @ `main`, 2026-08-16):

    * The two cleartext JSON messages exchanged before Noise starts
      (`client/init`, `server/init`), plus the `prologue/2` helper that
      concatenates their exact wire bytes — the Noise handshake prologue must
      be the literal bytes sent/received, not a re-serialization (ground
      truth §2).
    * `noise/handshake`'s JSON envelope (base64url `data` field), reused
      unmodified for the in-band re-handshake (ground truth §4).
    * Post-handshake plaintext framing: `wrap_json/1` / `unwrap_json/1`
      prefix/strip the type-`0` byte that marks a JSON body inside one Noise
      transport plaintext (`messaging.md` "Binary Message ID Structure").
    * The source-role binary audio frame: type byte `12` (`0x0C`) + **big-endian
      signed** int64 microsecond timestamp + raw audio bytes. Only the
      timestamp prefix is big-endian; PCM sample payloads are little-endian
      (ground truth correction #1 and #3).
    * Fragmentation (types `2`/`3`) via the pure `Reassembler` struct — a
      single Noise transport message is capped at 65535 bytes minus the
      16-byte AEAD tag, so large messages arrive as an opening fragment-more
      frame (carrying `orig_type`), zero or more continuations, and a closing
      fragment-end frame (`messaging.md` "Fragmentation").
    * JSON payload builders/parsers for every message the source FSM needs:
      `client/hello` / `server/hello`, `server/activate`, `client/state`,
      `client/time` / `server/time`, `server/command`, `client_stream/start` /
      `client_stream/end`, and every pairing message that carries the CPace
      PAKE and PSK wrap (`client/pair-init`, `server/pair-init`,
      `server/pair-auth`, `client/pair-auth`, `server/pair-confirm`,
      `client/pair-confirm`, `client/pair-finalize`, `server/pair-finalize`,
      `pair/abort`). Pairing fields are typed passthrough only — base64url
      text on the wire becomes a raw binary here, nothing more; the
      CPace/PSK-wrap math lives in `UniversalProxy.Sendspin.{CPace,Pairing}`.

  **`UniversalProxy.Sendspin.Pairing` does not call the typed pairing
  functions below.** It works directly with `decode_envelope/1`'s raw,
  string-keyed payload maps (it does its own base64url decode via a private
  `decode_field/3`) and hands back `{type, payload}` tuples already
  wire-shaped, ready for `encode_message/2`. The typed `encode_*`/`decode_*`
  pairing functions here exist for symmetry with every other message type,
  tests, and any future caller that wants atom-keyed, already-decoded
  fields — field names are kept in lockstep with what `Pairing` actually
  produces/consumes (`pake_msg_1`, `pake_msg_2`, `server_kc`, `client_kc`,
  `wrapped_psk`, `nonce_A`/`nonce_B`, `commit_B`, `pairing_index`, `reason`).

  `client/pair-pending` and `client/goodbye` are intentionally out of scope
  for this module — neither appears in `Pairing`'s implemented flow (gesture-
  gated attempts and connection teardown are both out of scope there too);
  add them here the same way if a later task needs them.

  ## Decode contract

  Every `decode_*/1` function takes the raw JSON text of one message (for
  cleartext messages: the exact WS text frame; for post-handshake messages:
  the JSON body already stripped of its leading type-`0` byte, e.g. via
  `unwrap_json/1` or the `{:json, body}` result of `decode_frame/2`) and
  returns `{:ok, parsed}` or `{:error, reason}`. `decode_message/1` is the
  generic dispatcher used once inside Noise transport mode: it recognizes
  every message type listed above and returns `{:unknown, type, payload}` —
  not an error — for anything else, so a future message type doesn't break
  an already-deployed client (forward compatibility).

  Closed-enum wire strings (`trust_level`, `command`, `signal`, `codec`,
  `activities`, pairing `method`) decode to fixed, already-existing atoms via
  explicit `case`/function-head matching — never `String.to_atom/1` — so a
  malicious or buggy peer can't grow the atom table.
  """

  # Transport-mode binary message type byte (byte 0 of the Noise-decrypted
  # plaintext). `messaging.md` "Binary Message ID Structure".
  @json_body 0
  @fragment_more 2
  @fragment_end 3
  @source_audio_chunk 12

  # Bounds a single connection's reassembly buffer against a peer streaming
  # endless fragments (mirrors aiosendspin's `MAX_REASSEMBLED_MESSAGE_BYTES`).
  # The largest legitimate inbound message a source@v1 client ever receives
  # is a few kB of JSON (pairing/control messages) — 1 MB is already a
  # generous multiple of that, while still bounding per-connection memory on
  # a 1 GB Pi 3 shared across however many capture-card listeners it runs.
  @max_reassembled_bytes 1024 * 1024

  # A fragment-more frame can carry as little as 1 byte of payload, so the
  # byte cap alone still permits `@max_reassembled_bytes` reduce steps
  # (again, per connection) before it trips. Capping the fragment count
  # bounds that work independent of how small the attacker makes each one.
  @max_reassembled_fragments 4_096

  @type device_info :: %{
          optional(:product_name) => String.t(),
          optional(:manufacturer) => String.t(),
          optional(:software_version) => String.t(),
          optional(:mac_address) => String.t()
        }

  @type pair_method :: :dynamic_pin | :pairing_psk | :static_pin

  @type pair_method_descriptor :: %{
          optional(:out_channels) => [String.t()],
          optional(:min_pin_length) => pos_integer(),
          optional(:locations) => [String.t()],
          method: pair_method()
        }

  @type client_hello :: %{
          name: String.t(),
          device_info: device_info() | nil,
          trust_level: :user | :none,
          supported_roles: [String.t()],
          source_v1_support: %{features: %{line_sense: boolean() | nil} | nil} | nil,
          supported_pair_methods: [pair_method_descriptor()],
          unpaired_access: %{enabled: boolean()}
        }

  @type server_activate :: %{
          activities: [:playback | :pairing | :management],
          active_roles: [String.t()] | nil,
          pairing:
            %{
              method: pair_method(),
              pin_length: pos_integer() | nil,
              languages: [String.t()] | nil
            }
            | nil
        }

  @type client_stream_start :: %{
          codec: :pcm | :opus | :flac,
          channels: pos_integer(),
          sample_rate: pos_integer(),
          bit_depth: pos_integer(),
          codec_header: binary() | nil
        }

  @typedoc "One reassembled or single-frame transport plaintext, dispatched by leading type byte."
  @type frame ::
          {:json, binary()}
          | {:audio, integer(), binary()}
          | {:binary, byte(), binary()}

  defmodule Reassembler do
    @moduledoc """
    Pure fragment-reassembly state for the Sendspin fragment message types.

    No process, no I/O — the connection owns one of these per direction and
    threads it through `UniversalProxy.Sendspin.Wire.decode_frame/2` for every
    decrypted transport plaintext it receives.
    """

    # `size`/`fragment_count` are carried running totals, not recomputed —
    # see `UniversalProxy.Sendspin.Wire.grow_reassembly/2`'s moduledoc note
    # on why (an `IO.iodata_length/1` call per fragment would be O(N²) over
    # the life of one fragmented message).
    defstruct type: nil, buffer: [], size: 0, fragment_count: 0

    @type t :: %__MODULE__{
            type: byte() | nil,
            buffer: iodata(),
            size: non_neg_integer(),
            fragment_count: non_neg_integer()
          }

    @doc "An empty reassembler: no fragmented message currently in flight."
    @spec new() :: t()
    def new, do: %__MODULE__{}
  end

  # -- Cleartext init exchange --
  #
  # `client_id`/`server_id` are passed through as opaque strings: shape
  # validation (43 chars, decodes to exactly 32 bytes) and `version`/`suite`
  # value validation happen where those fields are actually consumed
  # (`UniversalProxy.Sendspin.Noise`), not duplicated here.

  @doc """
  Encode the cleartext `client/init` message, first sent by us after the
  websocket opens (ground truth §2 — we always send this first, even on an
  inbound connection). The returned bytes are the exact wire text; keep them
  for `prologue/2`.
  """
  @spec encode_client_init(String.t(), pos_integer(), String.t()) :: binary()
  def encode_client_init(client_id, version, suite)
      when is_binary(client_id) and is_integer(version) and is_binary(suite) do
    encode_message("client/init", %{
      "client_id" => client_id,
      "version" => version,
      "suite" => suite
    })
  end

  @doc "Decode a `client/init` message."
  @spec decode_client_init(binary()) ::
          {:ok, %{client_id: String.t(), version: integer(), suite: String.t()}}
          | {:error, term()}
  def decode_client_init(text), do: decode_as(text, "client/init", &parse_client_init_payload/1)

  @doc """
  Encode the cleartext `server/init` reply.
  """
  @spec encode_server_init(String.t(), pos_integer()) :: binary()
  def encode_server_init(server_id, version) when is_binary(server_id) and is_integer(version) do
    encode_message("server/init", %{"server_id" => server_id, "version" => version})
  end

  @doc """
  Decode a `server/init` message. The exact bytes passed in are what a
  responder must feed to `prologue/2` — decode does not, and cannot,
  reconstruct byte-identical text from the parsed fields alone.
  """
  @spec decode_server_init(binary()) ::
          {:ok, %{server_id: String.t(), version: integer()}} | {:error, term()}
  def decode_server_init(text), do: decode_as(text, "server/init", &parse_server_init_payload/1)

  @doc """
  Build the Noise handshake prologue: the exact wire bytes of `client/init`
  followed by the exact wire bytes of `server/init` (ground truth §2). Both
  arguments must be the literal bytes transmitted/received — not
  re-serialized JSON, which could differ in whitespace or key order and
  silently break the handshake.
  """
  @spec prologue(iodata(), iodata()) :: binary()
  def prologue(client_init_text, server_init_text) do
    IO.iodata_to_binary([client_init_text, server_init_text])
  end

  @doc """
  Encode a `noise/handshake` message carrying one raw Noise handshake message
  (`data`, base64url on the wire). Used both cleartext (handshake messages 1
  and 2) and, unmodified, as an ordinary type-`0` JSON body during the
  in-band re-handshake (ground truth §4) — wrap the result with `wrap_json/1`
  in that case.
  """
  @spec encode_noise_handshake(binary()) :: binary()
  def encode_noise_handshake(data) when is_binary(data) do
    encode_message("noise/handshake", %{"data" => b64url_encode(data)})
  end

  @doc "Decode a `noise/handshake` message, returning the raw handshake bytes."
  @spec decode_noise_handshake(binary()) :: {:ok, binary()} | {:error, term()}
  def decode_noise_handshake(text) do
    case decode_as(text, "noise/handshake", &parse_noise_handshake_payload/1) do
      {:ok, %{data: data}} -> {:ok, data}
      {:error, _} = error -> error
    end
  end

  # -- Generic envelope --

  @doc """
  Build the generic `{"type": type, "payload": payload}` envelope every
  Sendspin message uses. Every specific `encode_*` function is a thin
  wrapper over this.
  """
  @spec encode_message(String.t(), map()) :: binary()
  def encode_message(type, payload) when is_binary(type) and is_map(payload) do
    Jason.encode!(%{"type" => type, "payload" => payload})
  end

  @doc """
  Parse the generic envelope, returning the message type and its payload
  object (defaulting to `%{}` if `payload` is absent, as for messages with no
  fields such as `client_stream/end`).
  """
  @spec decode_envelope(binary()) :: {:ok, String.t(), map()} | {:error, term()}
  def decode_envelope(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{"type" => type} = message} when is_binary(type) ->
        case Map.get(message, "payload", %{}) do
          payload when is_map(payload) -> {:ok, type, payload}
          _other -> {:error, :invalid_payload}
        end

      {:ok, _other} ->
        {:error, :invalid_envelope}

      {:error, reason} ->
        {:error, {:invalid_json, reason}}
    end
  end

  @doc """
  Dispatch a post-handshake JSON message body by its `type` field. Returns
  `{:unknown, type, payload}` — never an error — for a type this module
  doesn't recognize, so a future protocol addition degrades gracefully
  instead of breaking an already-deployed client.
  """
  @spec decode_message(binary()) ::
          {:ok, {atom(), map()}} | {:unknown, String.t(), map()} | {:error, term()}
  def decode_message(text) when is_binary(text) do
    with {:ok, type, payload} <- decode_envelope(text) do
      case type_tag_and_parser(type) do
        nil -> {:unknown, type, payload}
        {tag, parser} -> tag_result(tag, parser.(payload))
      end
    end
  end

  # -- Post-handshake plaintext framing --

  @doc "Prefix a JSON message's wire text with the type-`0` (JSON body) byte."
  @spec wrap_json(binary()) :: binary()
  def wrap_json(json_text) when is_binary(json_text), do: <<@json_body, json_text::binary>>

  @doc "Strip and validate the type-`0` byte from a decrypted transport plaintext."
  @spec unwrap_json(binary()) :: {:ok, binary()} | {:error, term()}
  def unwrap_json(<<@json_body, json_text::binary>>), do: {:ok, json_text}
  def unwrap_json(<<type, _rest::binary>>), do: {:error, {:unexpected_type, @json_body, type}}
  def unwrap_json(<<>>), do: {:error, :empty_plaintext}

  # -- Binary source-audio frame (source role, slot 0, type 0x0C) --

  @doc """
  Encode a source-audio binary frame: type byte `12`, big-endian **signed**
  int64 microsecond timestamp, then the raw (little-endian PCM, for
  `codec: "pcm"`) audio bytes. This is the complete Noise transport
  plaintext — pass the result to `UniversalProxy.Sendspin.Noise.encrypt/2`
  directly.
  """
  @spec encode_audio_frame(integer(), binary()) :: binary()
  def encode_audio_frame(timestamp_us, payload)
      when is_integer(timestamp_us) and is_binary(payload) do
    <<@source_audio_chunk, timestamp_us::signed-big-64, payload::binary>>
  end

  @doc "Decode a source-audio binary frame plaintext."
  @spec decode_audio_frame(binary()) :: {:ok, integer(), binary()} | {:error, term()}
  def decode_audio_frame(<<@source_audio_chunk, timestamp_us::signed-big-64, payload::binary>>) do
    {:ok, timestamp_us, payload}
  end

  def decode_audio_frame(<<@source_audio_chunk, _rest::binary>>),
    do: {:error, :truncated_audio_frame}

  def decode_audio_frame(<<type, _rest::binary>>),
    do: {:error, {:unexpected_type, @source_audio_chunk, type}}

  def decode_audio_frame(<<>>), do: {:error, :empty_plaintext}

  # -- Fragmentation --

  @doc """
  Feed one decrypted transport plaintext through fragment reassembly and, once
  a full message is available, dispatch it by leading type byte.

  Returns `{:pending, reassembler}` while a fragmented message is still in
  flight, `{:complete, frame, reassembler}` (with a fresh, empty reassembler)
  once one is fully reassembled or arrived unfragmented, or `{:error, reason}`
  on any malformed sequence (`messaging.md` "Fragmentation" — these are
  protocol errors the caller should close the connection over).
  """
  @spec decode_frame(binary(), Reassembler.t()) ::
          {:pending, Reassembler.t()} | {:complete, frame(), Reassembler.t()} | {:error, term()}
  def decode_frame(<<>>, %Reassembler{}), do: {:error, :empty_plaintext}

  def decode_frame(
        <<@fragment_more, orig_type, data::binary>>,
        %Reassembler{type: nil} = reassembler
      )
      when orig_type != @fragment_more and orig_type != @fragment_end do
    grow_reassembly(%{reassembler | type: orig_type}, data)
  end

  # `orig_type` of 2 or 3 is an explicit protocol violation (a sender MUST NOT
  # fragment a fragment), caught before the generic 1-byte-input clause below.
  def decode_frame(<<@fragment_more, _orig_type, _data::binary>>, %Reassembler{type: nil}) do
    {:error, :invalid_orig_type}
  end

  def decode_frame(<<@fragment_more>>, %Reassembler{type: nil}) do
    {:error, :fragment_missing_orig_type}
  end

  def decode_frame(<<@fragment_more, data::binary>>, %Reassembler{type: type} = reassembler)
      when not is_nil(type) do
    grow_reassembly(reassembler, data)
  end

  def decode_frame(<<@fragment_end, _data::binary>>, %Reassembler{type: nil}) do
    {:error, :fragment_end_without_start}
  end

  def decode_frame(<<@fragment_end, data::binary>>, %Reassembler{type: type} = reassembler)
      when not is_nil(type) do
    case grow_reassembly(reassembler, data) do
      {:pending, %Reassembler{buffer: full_buffer}} ->
        reassembled_frame(IO.iodata_to_binary([<<type>>, full_buffer]))

      {:error, _} = error ->
        error
    end
  end

  # Any non-fragment frame while a fragmented message is in flight is a
  # protocol error — only fragment-more/fragment-end may interleave.
  def decode_frame(_plaintext, %Reassembler{type: type}) when not is_nil(type) do
    {:error, :fragment_interrupted}
  end

  def decode_frame(plaintext, %Reassembler{type: nil}), do: reassembled_frame(plaintext)

  # Carries `size`/`fragment_count` as running totals on the struct instead
  # of recomputing `IO.iodata_length(buffer)` on every call — the latter
  # re-walks the whole (ever-deeper-nested) buffer per fragment, so N
  # fragments would cost O(N²) total work over one fragmented message.
  defp grow_reassembly(
         %Reassembler{buffer: buffer, size: size, fragment_count: count} = reassembler,
         data
       ) do
    new_size = size + byte_size(data)
    new_count = count + 1

    cond do
      new_size > @max_reassembled_bytes ->
        {:error, :fragment_too_large}

      new_count > @max_reassembled_fragments ->
        {:error, :too_many_fragments}

      true ->
        {:pending,
         %{reassembler | buffer: [buffer, data], size: new_size, fragment_count: new_count}}
    end
  end

  defp reassembled_frame(plaintext) do
    case dispatch_frame(plaintext) do
      {:error, _} = error -> error
      frame -> {:complete, frame, Reassembler.new()}
    end
  end

  defp dispatch_frame(<<@json_body, body::binary>>), do: {:json, body}

  defp dispatch_frame(<<@source_audio_chunk, _rest::binary>> = plaintext) do
    case decode_audio_frame(plaintext) do
      {:ok, timestamp_us, payload} -> {:audio, timestamp_us, payload}
      {:error, _} = error -> error
    end
  end

  defp dispatch_frame(<<type, payload::binary>>), do: {:binary, type, payload}

  # -- server/hello --

  @doc "Encode `server/hello` (server → client, first post-handshake message)."
  @spec encode_server_hello(String.t()) :: binary()
  def encode_server_hello(name) when is_binary(name) do
    encode_message("server/hello", %{"name" => name})
  end

  @doc "Decode `server/hello`."
  @spec decode_server_hello(binary()) :: {:ok, %{name: String.t()}} | {:error, term()}
  def decode_server_hello(text),
    do: decode_as(text, "server/hello", &parse_server_hello_payload/1)

  # -- client/hello --

  @doc """
  Encode `client/hello`. `source_v1_support` is required (as `%{features:
  ...}` or `%{}`) whenever `"source@v1"` is in `supported_roles` — a server
  MUST NOT activate a role listed without its support object (`messaging.md`
  `client/hello`).
  """
  @spec encode_client_hello(client_hello()) :: binary()
  def encode_client_hello(fields) when is_map(fields) do
    payload =
      %{}
      |> Map.put("name", Map.fetch!(fields, :name))
      |> maybe_put("device_info", fields |> Map.get(:device_info) |> encode_device_info())
      |> Map.put("trust_level", encode_trust_level(Map.fetch!(fields, :trust_level)))
      |> Map.put("supported_roles", Map.fetch!(fields, :supported_roles))
      |> maybe_put(
        "source@v1_support",
        fields |> Map.get(:source_v1_support) |> encode_source_v1_support()
      )
      |> Map.put(
        "supported_pair_methods",
        fields
        |> Map.fetch!(:supported_pair_methods)
        |> Enum.map(&encode_pair_method_descriptor/1)
      )
      |> Map.put("unpaired_access", %{
        "enabled" => fields |> Map.fetch!(:unpaired_access) |> Map.fetch!(:enabled)
      })

    encode_message("client/hello", payload)
  end

  @doc "Decode `client/hello`."
  @spec decode_client_hello(binary()) :: {:ok, client_hello()} | {:error, term()}
  def decode_client_hello(text),
    do: decode_as(text, "client/hello", &parse_client_hello_payload/1)

  defp parse_client_hello_payload(payload) do
    with {:ok, name} <- fetch_string(payload, "name"),
         {:ok, device_info} <- parse_optional_device_info(payload),
         {:ok, trust_level_str} <- fetch_string(payload, "trust_level"),
         {:ok, trust_level} <- decode_trust_level(trust_level_str),
         {:ok, supported_roles} <- fetch_string_list(payload, "supported_roles"),
         {:ok, source_v1_support} <- parse_optional_source_v1_support(payload),
         {:ok, pair_methods_raw} <- fetch_list(payload, "supported_pair_methods"),
         {:ok, pair_methods} <- map_ok(pair_methods_raw, &parse_pair_method_descriptor/1),
         {:ok, unpaired_access_raw} <- fetch_map(payload, "unpaired_access"),
         {:ok, unpaired_enabled} <- fetch_boolean(unpaired_access_raw, "enabled") do
      {:ok,
       %{
         name: name,
         device_info: device_info,
         trust_level: trust_level,
         supported_roles: supported_roles,
         source_v1_support: source_v1_support,
         supported_pair_methods: pair_methods,
         unpaired_access: %{enabled: unpaired_enabled}
       }}
    end
  end

  defp encode_device_info(nil), do: nil

  defp encode_device_info(info) when is_map(info) do
    %{}
    |> maybe_put("product_name", Map.get(info, :product_name))
    |> maybe_put("manufacturer", Map.get(info, :manufacturer))
    |> maybe_put("software_version", Map.get(info, :software_version))
    |> maybe_put("mac_address", Map.get(info, :mac_address))
  end

  defp parse_optional_device_info(payload) do
    case Map.get(payload, "device_info") do
      nil ->
        {:ok, nil}

      info when is_map(info) ->
        {:ok,
         %{}
         |> maybe_put(:product_name, Map.get(info, "product_name"))
         |> maybe_put(:manufacturer, Map.get(info, "manufacturer"))
         |> maybe_put(:software_version, Map.get(info, "software_version"))
         |> maybe_put(:mac_address, Map.get(info, "mac_address"))}

      _other ->
        {:error, {:invalid_field, "device_info"}}
    end
  end

  defp encode_source_v1_support(nil), do: nil

  defp encode_source_v1_support(support) when is_map(support) do
    %{} |> maybe_put("features", support |> Map.get(:features) |> encode_source_features())
  end

  defp encode_source_features(nil), do: nil

  defp encode_source_features(features) when is_map(features) do
    %{} |> maybe_put("line_sense", Map.get(features, :line_sense))
  end

  defp parse_optional_source_v1_support(payload) do
    case Map.get(payload, "source@v1_support") do
      nil ->
        {:ok, nil}

      support when is_map(support) ->
        case parse_optional_source_features(support) do
          {:ok, features} -> {:ok, %{features: features}}
          {:error, _} = error -> error
        end

      _other ->
        {:error, {:invalid_field, "source@v1_support"}}
    end
  end

  defp parse_optional_source_features(support) do
    case Map.get(support, "features") do
      nil -> {:ok, nil}
      features when is_map(features) -> {:ok, %{line_sense: Map.get(features, "line_sense")}}
      _other -> {:error, {:invalid_field, "source@v1_support.features"}}
    end
  end

  defp encode_pair_method_descriptor(descriptor) do
    %{}
    |> Map.put("method", encode_pair_method(Map.fetch!(descriptor, :method)))
    |> maybe_put("out_channels", Map.get(descriptor, :out_channels))
    |> maybe_put("min_pin_length", Map.get(descriptor, :min_pin_length))
    |> maybe_put("locations", Map.get(descriptor, :locations))
  end

  defp parse_pair_method_descriptor(descriptor) when is_map(descriptor) do
    with {:ok, method_str} <- fetch_string(descriptor, "method"),
         {:ok, method} <- decode_pair_method(method_str) do
      {:ok,
       %{method: method}
       |> maybe_put(:out_channels, Map.get(descriptor, "out_channels"))
       |> maybe_put(:min_pin_length, Map.get(descriptor, "min_pin_length"))
       |> maybe_put(:locations, Map.get(descriptor, "locations"))}
    end
  end

  defp parse_pair_method_descriptor(_other),
    do: {:error, {:invalid_field, "supported_pair_methods"}}

  defp encode_trust_level(:user), do: "user"
  defp encode_trust_level(:none), do: "none"

  defp decode_trust_level("user"), do: {:ok, :user}
  defp decode_trust_level("none"), do: {:ok, :none}
  defp decode_trust_level(other), do: {:error, {:invalid_field, {"trust_level", other}}}

  defp encode_pair_method(:dynamic_pin), do: "dynamic_pin"
  defp encode_pair_method(:pairing_psk), do: "pairing_psk"
  defp encode_pair_method(:static_pin), do: "static_pin"

  defp decode_pair_method("dynamic_pin"), do: {:ok, :dynamic_pin}
  defp decode_pair_method("pairing_psk"), do: {:ok, :pairing_psk}
  defp decode_pair_method("static_pin"), do: {:ok, :static_pin}
  defp decode_pair_method(other), do: {:error, {:invalid_field, {"method", other}}}

  # -- server/activate --

  @doc "Encode `server/activate`."
  @spec encode_server_activate(server_activate()) :: binary()
  def encode_server_activate(fields) when is_map(fields) do
    payload =
      %{}
      |> Map.put("activities", fields |> Map.fetch!(:activities) |> Enum.map(&encode_activity/1))
      |> maybe_put("active_roles", Map.get(fields, :active_roles))
      |> maybe_put("pairing", fields |> Map.get(:pairing) |> encode_pairing_params())

    encode_message("server/activate", payload)
  end

  @doc "Decode `server/activate`, extracting `active_roles` and the pairing method (ground truth §2/§7)."
  @spec decode_server_activate(binary()) :: {:ok, server_activate()} | {:error, term()}
  def decode_server_activate(text),
    do: decode_as(text, "server/activate", &parse_server_activate_payload/1)

  defp parse_server_activate_payload(payload) do
    with {:ok, activities_raw} <- fetch_list(payload, "activities"),
         {:ok, activities} <- map_ok(activities_raw, &decode_activity/1),
         {:ok, active_roles} <- parse_optional_string_list(payload, "active_roles"),
         {:ok, pairing} <- parse_optional_pairing_params(payload) do
      {:ok, %{activities: activities, active_roles: active_roles, pairing: pairing}}
    end
  end

  defp encode_pairing_params(nil), do: nil

  defp encode_pairing_params(params) do
    %{}
    |> Map.put("method", encode_pair_method(Map.fetch!(params, :method)))
    |> maybe_put("pin_length", Map.get(params, :pin_length))
    |> maybe_put("languages", Map.get(params, :languages))
  end

  defp parse_optional_pairing_params(payload) do
    case Map.get(payload, "pairing") do
      nil ->
        {:ok, nil}

      params when is_map(params) ->
        with {:ok, method_str} <- fetch_string(params, "method"),
             {:ok, method} <- decode_pair_method(method_str) do
          {:ok,
           %{
             method: method,
             pin_length: Map.get(params, "pin_length"),
             languages: Map.get(params, "languages")
           }}
        end

      _other ->
        {:error, {:invalid_field, "pairing"}}
    end
  end

  defp encode_activity(:playback), do: "playback"
  defp encode_activity(:pairing), do: "pairing"
  defp encode_activity(:management), do: "management"

  defp decode_activity("playback"), do: {:ok, :playback}
  defp decode_activity("pairing"), do: {:ok, :pairing}
  defp decode_activity("management"), do: {:ok, :management}
  defp decode_activity(other), do: {:error, {:invalid_field, {"activities", other}}}

  # -- client/time / server/time --

  @doc "Encode `client/time`."
  @spec encode_client_time(integer()) :: binary()
  def encode_client_time(client_transmitted_us) when is_integer(client_transmitted_us) do
    encode_message("client/time", %{"client_transmitted" => client_transmitted_us})
  end

  @doc "Decode `client/time`."
  @spec decode_client_time(binary()) :: {:ok, %{client_transmitted: integer()}} | {:error, term()}
  def decode_client_time(text), do: decode_as(text, "client/time", &parse_client_time_payload/1)

  @doc """
  Encode `server/time`. Field names/units match ground truth §6 exactly:
  all three are server- or client-clock microseconds, not epoch time.
  """
  @spec encode_server_time(integer(), integer(), integer()) :: binary()
  def encode_server_time(client_transmitted_us, server_received_us, server_transmitted_us)
      when is_integer(client_transmitted_us) and is_integer(server_received_us) and
             is_integer(server_transmitted_us) do
    encode_message("server/time", %{
      "client_transmitted" => client_transmitted_us,
      "server_received" => server_received_us,
      "server_transmitted" => server_transmitted_us
    })
  end

  @doc """
  Decode `server/time`. The caller derives the `ClockFilter.update/5`
  measurement from these three fields plus its own local receive time (T4) —
  see ground truth §6.
  """
  @spec decode_server_time(binary()) ::
          {:ok,
           %{
             client_transmitted: integer(),
             server_received: integer(),
             server_transmitted: integer()
           }}
          | {:error, term()}
  def decode_server_time(text), do: decode_as(text, "server/time", &parse_server_time_payload/1)

  defp parse_client_time_payload(payload) do
    with {:ok, client_transmitted} <- fetch_integer(payload, "client_transmitted") do
      {:ok, %{client_transmitted: client_transmitted}}
    end
  end

  defp parse_server_time_payload(payload) do
    with {:ok, client_transmitted} <- fetch_integer(payload, "client_transmitted"),
         {:ok, server_received} <- fetch_integer(payload, "server_received"),
         {:ok, server_transmitted} <- fetch_integer(payload, "server_transmitted") do
      {:ok,
       %{
         client_transmitted: client_transmitted,
         server_received: server_received,
         server_transmitted: server_transmitted
       }}
    end
  end

  # -- client/state (source object) --

  @doc """
  Encode `client/state`. `source` is `nil` to omit the object entirely (no
  `source` role, or an update that doesn't touch it), or `%{signal: nil |
  :present | :absent}` — `signal: nil` sends `"source": {}` (line-sensing not
  currently reported), distinct from omitting `source` altogether.
  """
  @spec encode_client_state(boolean(), %{signal: :present | :absent | nil} | nil) :: binary()
  def encode_client_state(available, source \\ nil) when is_boolean(available) do
    payload =
      %{"available" => available} |> maybe_put("source", encode_client_state_source(source))

    encode_message("client/state", payload)
  end

  @doc "Decode `client/state`."
  @spec decode_client_state(binary()) ::
          {:ok, %{available: boolean(), source: %{signal: :present | :absent | nil} | nil}}
          | {:error, term()}
  def decode_client_state(text),
    do: decode_as(text, "client/state", &parse_client_state_payload/1)

  defp encode_client_state_source(nil), do: nil

  defp encode_client_state_source(%{signal: signal}) do
    %{} |> maybe_put("signal", signal && encode_signal(signal))
  end

  defp encode_signal(:present), do: "present"
  defp encode_signal(:absent), do: "absent"

  defp parse_client_state_payload(payload) do
    with {:ok, available} <- fetch_boolean(payload, "available"),
         {:ok, source} <- parse_optional_client_state_source(payload) do
      {:ok, %{available: available, source: source}}
    end
  end

  defp parse_optional_client_state_source(payload) do
    case Map.get(payload, "source") do
      nil ->
        {:ok, nil}

      source when is_map(source) ->
        case Map.get(source, "signal") do
          nil -> {:ok, %{signal: nil}}
          "present" -> {:ok, %{signal: :present}}
          "absent" -> {:ok, %{signal: :absent}}
          other -> {:error, {:invalid_field, {"source.signal", other}}}
        end

      _other ->
        {:error, {:invalid_field, "source"}}
    end
  end

  # -- server/command (source object) --

  @doc """
  Encode `server/command`. `source` is `nil` to omit the object (no command
  for the source role in this message). Per ground truth §7 the source
  command object is exactly `{"command": "start" | "stop"}` — there is no
  `mute` for a source (that's a player-role concept).
  """
  @spec encode_server_command(%{command: :start | :stop} | nil) :: binary()
  def encode_server_command(source \\ nil) do
    payload = %{} |> maybe_put("source", encode_server_command_source(source))
    encode_message("server/command", payload)
  end

  @doc "Decode `server/command`."
  @spec decode_server_command(binary()) ::
          {:ok, %{source: %{command: :start | :stop} | nil}} | {:error, term()}
  def decode_server_command(text),
    do: decode_as(text, "server/command", &parse_server_command_payload/1)

  defp encode_server_command_source(nil), do: nil

  defp encode_server_command_source(%{command: command}),
    do: %{"command" => encode_command(command)}

  defp encode_command(:start), do: "start"
  defp encode_command(:stop), do: "stop"

  defp parse_server_command_payload(payload) do
    with {:ok, source} <- parse_optional_server_command_source(payload) do
      {:ok, %{source: source}}
    end
  end

  defp parse_optional_server_command_source(payload) do
    case Map.get(payload, "source") do
      nil -> {:ok, nil}
      %{"command" => "start"} -> {:ok, %{command: :start}}
      %{"command" => "stop"} -> {:ok, %{command: :stop}}
      %{"command" => other} -> {:error, {:invalid_field, {"source.command", other}}}
      _other -> {:error, {:invalid_field, "source"}}
    end
  end

  # -- client_stream/start / client_stream/end --

  @doc """
  Encode `client_stream/start`. `codec_header` uses **standard** (padded)
  Base64 — a different alphabet/padding convention than every other binary
  field in this protocol, which is base64url without padding (ground truth
  §7). `nil` omits the field, correct for `pcm`/`opus`.
  """
  @spec encode_client_stream_start(client_stream_start()) :: binary()
  def encode_client_stream_start(fields) when is_map(fields) do
    source =
      %{}
      |> Map.put("codec", encode_codec(Map.fetch!(fields, :codec)))
      |> Map.put("channels", Map.fetch!(fields, :channels))
      |> Map.put("sample_rate", Map.fetch!(fields, :sample_rate))
      |> Map.put("bit_depth", Map.fetch!(fields, :bit_depth))
      |> maybe_put("codec_header", fields |> Map.get(:codec_header) |> encode_codec_header())

    encode_message("client_stream/start", %{"source" => source})
  end

  @doc "Decode `client_stream/start`."
  @spec decode_client_stream_start(binary()) :: {:ok, client_stream_start()} | {:error, term()}
  def decode_client_stream_start(text),
    do: decode_as(text, "client_stream/start", &parse_client_stream_start_payload/1)

  @doc "Encode `client_stream/end` (no payload fields)."
  @spec encode_client_stream_end() :: binary()
  def encode_client_stream_end, do: encode_message("client_stream/end", %{})

  @doc "Decode `client_stream/end`."
  @spec decode_client_stream_end(binary()) :: {:ok, %{}} | {:error, term()}
  def decode_client_stream_end(text),
    do: decode_as(text, "client_stream/end", &parse_empty_payload/1)

  defp encode_codec_header(nil), do: nil
  defp encode_codec_header(data) when is_binary(data), do: base64_std_encode(data)

  defp encode_codec(:pcm), do: "pcm"
  defp encode_codec(:opus), do: "opus"
  defp encode_codec(:flac), do: "flac"

  defp decode_codec("pcm"), do: {:ok, :pcm}
  defp decode_codec("opus"), do: {:ok, :opus}
  defp decode_codec("flac"), do: {:ok, :flac}
  defp decode_codec(other), do: {:error, {:invalid_field, {"codec", other}}}

  defp parse_client_stream_start_payload(payload) do
    with {:ok, source} <- fetch_map(payload, "source"),
         {:ok, codec_str} <- fetch_string(source, "codec"),
         {:ok, codec} <- decode_codec(codec_str),
         {:ok, channels} <- fetch_integer(source, "channels"),
         {:ok, sample_rate} <- fetch_integer(source, "sample_rate"),
         {:ok, bit_depth} <- fetch_integer(source, "bit_depth"),
         {:ok, codec_header} <- parse_optional_codec_header(source) do
      {:ok,
       %{
         codec: codec,
         channels: channels,
         sample_rate: sample_rate,
         bit_depth: bit_depth,
         codec_header: codec_header
       }}
    end
  end

  defp parse_optional_codec_header(source) do
    case Map.get(source, "codec_header") do
      nil -> {:ok, nil}
      b64 when is_binary(b64) -> base64_std_decode(b64)
      _other -> {:error, {:invalid_field, "codec_header"}}
    end
  end

  # -- Pairing messages --

  @doc """
  Encode `client/pair-init`, starting the PIN-pairing attempt. `commit_B` is
  our commitment to `nonce_B` (`SHA-256("sendspin-pair-commit-v1" ||
  nonce_B)`) and is present only for dynamic-PIN pairing — `nil` omits it for
  static-PIN pairing, which has no nonce/commit round trip.
  """
  @spec encode_client_pair_init(non_neg_integer(), binary() | nil) :: binary()
  def encode_client_pair_init(pairing_index, commit_b \\ nil) when is_integer(pairing_index) do
    payload =
      %{"pairing_index" => pairing_index}
      |> maybe_put("commit_B", commit_b && b64url_encode(commit_b))

    encode_message("client/pair-init", payload)
  end

  @doc "Decode `client/pair-init`."
  @spec decode_client_pair_init(binary()) ::
          {:ok, %{pairing_index: non_neg_integer(), commit_b: binary() | nil}} | {:error, term()}
  def decode_client_pair_init(text),
    do: decode_as(text, "client/pair-init", &parse_client_pair_init_payload/1)

  @doc "Encode `server/pair-init` (server's dynamic-PIN nonce contribution, `nonce_A`)."
  @spec encode_server_pair_init(binary()) :: binary()
  def encode_server_pair_init(nonce_a) when is_binary(nonce_a) do
    encode_message("server/pair-init", %{"nonce_A" => b64url_encode(nonce_a)})
  end

  @doc "Decode `server/pair-init`."
  @spec decode_server_pair_init(binary()) :: {:ok, %{nonce_a: binary()}} | {:error, term()}
  def decode_server_pair_init(text),
    do: decode_as(text, "server/pair-init", &parse_server_pair_init_payload/1)

  defp parse_client_pair_init_payload(payload) do
    with {:ok, pairing_index} <- fetch_integer(payload, "pairing_index"),
         {:ok, commit_b} <- parse_optional_b64url(payload, "commit_B") do
      {:ok, %{pairing_index: pairing_index, commit_b: commit_b}}
    end
  end

  defp parse_server_pair_init_payload(payload) do
    with {:ok, b64} <- fetch_string(payload, "nonce_A"),
         {:ok, bin} <- b64url_decode(b64) do
      {:ok, %{nonce_a: bin}}
    end
  end

  @doc "Encode `server/pair-auth` (server's CPace public share `Ya`)."
  @spec encode_server_pair_auth(binary()) :: binary()
  def encode_server_pair_auth(pake_msg_1) when is_binary(pake_msg_1) do
    encode_message("server/pair-auth", %{"pake_msg_1" => b64url_encode(pake_msg_1)})
  end

  @doc "Decode `server/pair-auth`."
  @spec decode_server_pair_auth(binary()) :: {:ok, %{pake_msg_1: binary()}} | {:error, term()}
  def decode_server_pair_auth(text),
    do: decode_as(text, "server/pair-auth", &parse_server_pair_auth_payload/1)

  @doc "Encode `client/pair-auth` (client's CPace public share `Yb`)."
  @spec encode_client_pair_auth(binary()) :: binary()
  def encode_client_pair_auth(pake_msg_2) when is_binary(pake_msg_2) do
    encode_message("client/pair-auth", %{"pake_msg_2" => b64url_encode(pake_msg_2)})
  end

  @doc "Decode `client/pair-auth`."
  @spec decode_client_pair_auth(binary()) :: {:ok, %{pake_msg_2: binary()}} | {:error, term()}
  def decode_client_pair_auth(text),
    do: decode_as(text, "client/pair-auth", &parse_client_pair_auth_payload/1)

  @doc "Encode `server/pair-confirm` (server's MCF tag `Ta`)."
  @spec encode_server_pair_confirm(binary()) :: binary()
  def encode_server_pair_confirm(server_kc) when is_binary(server_kc) do
    encode_message("server/pair-confirm", %{"server_kc" => b64url_encode(server_kc)})
  end

  @doc "Decode `server/pair-confirm`."
  @spec decode_server_pair_confirm(binary()) :: {:ok, %{server_kc: binary()}} | {:error, term()}
  def decode_server_pair_confirm(text),
    do: decode_as(text, "server/pair-confirm", &parse_server_pair_confirm_payload/1)

  @doc """
  Encode `client/pair-confirm` (client's MCF tag `Tb`, plus `nonce_B` — the
  dynamic-PIN commitment opening — when applicable; `nil` omits it for
  static-PIN pairing).
  """
  @spec encode_client_pair_confirm(binary(), binary() | nil) :: binary()
  def encode_client_pair_confirm(client_kc, nonce_b \\ nil) when is_binary(client_kc) do
    payload =
      %{"client_kc" => b64url_encode(client_kc)}
      |> maybe_put("nonce_B", nonce_b && b64url_encode(nonce_b))

    encode_message("client/pair-confirm", payload)
  end

  @doc "Decode `client/pair-confirm`."
  @spec decode_client_pair_confirm(binary()) ::
          {:ok, %{client_kc: binary(), nonce_b: binary() | nil}} | {:error, term()}
  def decode_client_pair_confirm(text),
    do: decode_as(text, "client/pair-confirm", &parse_client_pair_confirm_payload/1)

  @doc """
  Encode `client/pair-finalize`. Exactly one of `:long_term_psk` (Pairing PSK
  flow) or `:wrapped_psk` (PIN flows) must be present — this is the wire's
  documented XOR, so unlike every other `encode_*/1` in this module the
  result is a tagged tuple rather than a bare binary.
  """
  @spec encode_client_pair_finalize(%{long_term_psk: binary()} | %{wrapped_psk: binary()}) ::
          {:ok, binary()} | {:error, term()}
  def encode_client_pair_finalize(fields) when is_map(fields) do
    case {Map.fetch(fields, :long_term_psk), Map.fetch(fields, :wrapped_psk)} do
      {{:ok, psk}, :error} when is_binary(psk) ->
        {:ok, encode_message("client/pair-finalize", %{"long_term_psk" => b64url_encode(psk)})}

      {:error, {:ok, wrapped}} when is_binary(wrapped) ->
        {:ok, encode_message("client/pair-finalize", %{"wrapped_psk" => b64url_encode(wrapped)})}

      {:error, :error} ->
        {:error, :missing_psk_field}

      _both_or_invalid ->
        {:error, :exactly_one_psk_field_required}
    end
  end

  @doc "Decode `client/pair-finalize`."
  @spec decode_client_pair_finalize(binary()) ::
          {:ok, %{long_term_psk: binary()} | %{wrapped_psk: binary()}} | {:error, term()}
  def decode_client_pair_finalize(text),
    do: decode_as(text, "client/pair-finalize", &parse_client_pair_finalize_payload/1)

  @doc "Encode `server/pair-finalize` (no payload fields)."
  @spec encode_server_pair_finalize() :: binary()
  def encode_server_pair_finalize, do: encode_message("server/pair-finalize", %{})

  @doc "Decode `server/pair-finalize`."
  @spec decode_server_pair_finalize(binary()) :: {:ok, %{}} | {:error, term()}
  def decode_server_pair_finalize(text),
    do: decode_as(text, "server/pair-finalize", &parse_empty_payload/1)

  @typedoc "One of the six documented `pair/abort` reasons (`pairing.md` `pair/abort`)."
  @type pair_abort_reason ::
          :attempt_timeout
          | :concurrent_attempt
          | :method_not_supported
          | :pin_length_unacceptable
          | :pin_mismatch
          | :user_cancelled

  @doc "Encode `pair/abort`. Either side may send this — it aborts a pairing attempt, started or not."
  @spec encode_pair_abort(pair_abort_reason()) :: binary()
  def encode_pair_abort(reason) when is_atom(reason) do
    encode_message("pair/abort", %{"reason" => encode_pair_abort_reason(reason)})
  end

  @doc """
  Decode `pair/abort`. An unrecognized reason decodes to `{:unknown, string}`
  rather than an error — mirrors `UniversalProxy.Sendspin.Pairing`'s own
  `decode_abort_reason/1` (a future spec revision could add reasons, and
  both directions of this message already tolerate that there).
  """
  @spec decode_pair_abort(binary()) ::
          {:ok, %{reason: pair_abort_reason() | {:unknown, String.t()}}} | {:error, term()}
  def decode_pair_abort(text), do: decode_as(text, "pair/abort", &parse_pair_abort_payload/1)

  defp parse_pair_abort_payload(payload) do
    with {:ok, reason_str} <- fetch_string(payload, "reason") do
      {:ok, %{reason: decode_pair_abort_reason(reason_str)}}
    end
  end

  defp encode_pair_abort_reason(:attempt_timeout), do: "attempt_timeout"
  defp encode_pair_abort_reason(:concurrent_attempt), do: "concurrent_attempt"
  defp encode_pair_abort_reason(:method_not_supported), do: "method_not_supported"
  defp encode_pair_abort_reason(:pin_length_unacceptable), do: "pin_length_unacceptable"
  defp encode_pair_abort_reason(:pin_mismatch), do: "pin_mismatch"
  defp encode_pair_abort_reason(:user_cancelled), do: "user_cancelled"

  defp decode_pair_abort_reason("attempt_timeout"), do: :attempt_timeout
  defp decode_pair_abort_reason("concurrent_attempt"), do: :concurrent_attempt
  defp decode_pair_abort_reason("method_not_supported"), do: :method_not_supported
  defp decode_pair_abort_reason("pin_length_unacceptable"), do: :pin_length_unacceptable
  defp decode_pair_abort_reason("pin_mismatch"), do: :pin_mismatch
  defp decode_pair_abort_reason("user_cancelled"), do: :user_cancelled
  defp decode_pair_abort_reason(other), do: {:unknown, other}

  defp parse_server_pair_auth_payload(payload) do
    with {:ok, b64} <- fetch_string(payload, "pake_msg_1"),
         {:ok, bin} <- b64url_decode(b64) do
      {:ok, %{pake_msg_1: bin}}
    end
  end

  defp parse_client_pair_auth_payload(payload) do
    with {:ok, b64} <- fetch_string(payload, "pake_msg_2"),
         {:ok, bin} <- b64url_decode(b64) do
      {:ok, %{pake_msg_2: bin}}
    end
  end

  defp parse_server_pair_confirm_payload(payload) do
    with {:ok, b64} <- fetch_string(payload, "server_kc"),
         {:ok, bin} <- b64url_decode(b64) do
      {:ok, %{server_kc: bin}}
    end
  end

  defp parse_client_pair_confirm_payload(payload) do
    with {:ok, kc_b64} <- fetch_string(payload, "client_kc"),
         {:ok, client_kc} <- b64url_decode(kc_b64),
         {:ok, nonce_b} <- parse_optional_b64url(payload, "nonce_B") do
      {:ok, %{client_kc: client_kc, nonce_b: nonce_b}}
    end
  end

  defp parse_client_pair_finalize_payload(payload) do
    case {Map.fetch(payload, "long_term_psk"), Map.fetch(payload, "wrapped_psk")} do
      {{:ok, b64}, :error} ->
        with {:ok, bin} <- b64url_decode(b64), do: {:ok, %{long_term_psk: bin}}

      {:error, {:ok, b64}} ->
        with {:ok, bin} <- b64url_decode(b64), do: {:ok, %{wrapped_psk: bin}}

      {:error, :error} ->
        {:error, :missing_psk_field}

      {{:ok, _}, {:ok, _}} ->
        {:error, :exactly_one_psk_field_required}
    end
  end

  defp parse_optional_b64url(payload, key) do
    case Map.get(payload, key) do
      nil -> {:ok, nil}
      b64 when is_binary(b64) -> b64url_decode(b64)
      _other -> {:error, {:invalid_field, key}}
    end
  end

  defp parse_empty_payload(_payload), do: {:ok, %{}}

  defp parse_client_init_payload(payload) do
    with {:ok, client_id} <- fetch_string(payload, "client_id"),
         {:ok, version} <- fetch_integer(payload, "version"),
         {:ok, suite} <- fetch_string(payload, "suite") do
      {:ok, %{client_id: client_id, version: version, suite: suite}}
    end
  end

  defp parse_server_init_payload(payload) do
    with {:ok, server_id} <- fetch_string(payload, "server_id"),
         {:ok, version} <- fetch_integer(payload, "version") do
      {:ok, %{server_id: server_id, version: version}}
    end
  end

  defp parse_noise_handshake_payload(payload) do
    with {:ok, b64} <- fetch_string(payload, "data"),
         {:ok, data} <- b64url_decode(b64) do
      {:ok, %{data: data}}
    end
  end

  defp parse_server_hello_payload(payload) do
    with {:ok, name} <- fetch_string(payload, "name"), do: {:ok, %{name: name}}
  end

  # -- Generic dispatch table (used by decode_message/1) --

  defp type_tag_and_parser("client/init"), do: {:client_init, &parse_client_init_payload/1}
  defp type_tag_and_parser("server/init"), do: {:server_init, &parse_server_init_payload/1}

  defp type_tag_and_parser("noise/handshake"),
    do: {:noise_handshake, &parse_noise_handshake_payload/1}

  defp type_tag_and_parser("server/hello"), do: {:server_hello, &parse_server_hello_payload/1}
  defp type_tag_and_parser("client/hello"), do: {:client_hello, &parse_client_hello_payload/1}

  defp type_tag_and_parser("server/activate"),
    do: {:server_activate, &parse_server_activate_payload/1}

  defp type_tag_and_parser("client/time"), do: {:client_time, &parse_client_time_payload/1}
  defp type_tag_and_parser("server/time"), do: {:server_time, &parse_server_time_payload/1}
  defp type_tag_and_parser("client/state"), do: {:client_state, &parse_client_state_payload/1}

  defp type_tag_and_parser("server/command"),
    do: {:server_command, &parse_server_command_payload/1}

  defp type_tag_and_parser("client_stream/start"),
    do: {:client_stream_start, &parse_client_stream_start_payload/1}

  defp type_tag_and_parser("client_stream/end"), do: {:client_stream_end, &parse_empty_payload/1}

  defp type_tag_and_parser("client/pair-init"),
    do: {:client_pair_init, &parse_client_pair_init_payload/1}

  defp type_tag_and_parser("server/pair-init"),
    do: {:server_pair_init, &parse_server_pair_init_payload/1}

  defp type_tag_and_parser("server/pair-auth"),
    do: {:server_pair_auth, &parse_server_pair_auth_payload/1}

  defp type_tag_and_parser("client/pair-auth"),
    do: {:client_pair_auth, &parse_client_pair_auth_payload/1}

  defp type_tag_and_parser("server/pair-confirm"),
    do: {:server_pair_confirm, &parse_server_pair_confirm_payload/1}

  defp type_tag_and_parser("client/pair-confirm"),
    do: {:client_pair_confirm, &parse_client_pair_confirm_payload/1}

  defp type_tag_and_parser("client/pair-finalize"),
    do: {:client_pair_finalize, &parse_client_pair_finalize_payload/1}

  defp type_tag_and_parser("server/pair-finalize"),
    do: {:server_pair_finalize, &parse_empty_payload/1}

  defp type_tag_and_parser("pair/abort"), do: {:pair_abort, &parse_pair_abort_payload/1}
  defp type_tag_and_parser(_other), do: nil

  defp tag_result(tag, {:ok, parsed}), do: {:ok, {tag, parsed}}
  defp tag_result(_tag, {:error, _} = error), do: error

  # -- Shared decode plumbing --

  defp decode_as(text, expected_type, parser) do
    case decode_envelope(text) do
      {:ok, ^expected_type, payload} -> parser.(payload)
      {:ok, other, _payload} -> {:error, {:unexpected_type, expected_type, other}}
      {:error, _} = error -> error
    end
  end

  # -- Field-extraction helpers --

  defp fetch_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _other} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp fetch_integer(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      {:ok, _other} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp fetch_boolean(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, _other} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp fetch_map(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _other} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp fetch_list(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_list(value) -> {:ok, value}
      {:ok, _other} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp fetch_string_list(map, key) do
    with {:ok, list} <- fetch_list(map, key) do
      if Enum.all?(list, &is_binary/1) do
        {:ok, list}
      else
        {:error, {:invalid_field, key}}
      end
    end
  end

  defp parse_optional_string_list(map, key) do
    case Map.get(map, key) do
      nil ->
        {:ok, nil}

      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1) do
          {:ok, list}
        else
          {:error, {:invalid_field, key}}
        end

      _other ->
        {:error, {:invalid_field, key}}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp map_ok(list, fun) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  # -- Base64 helpers --
  #
  # Two distinct alphabets on purpose: everything except `codec_header` is
  # base64url without padding; `codec_header` alone is standard Base64 with
  # padding (ground truth §7) — don't reuse one helper for both.

  defp b64url_encode(data) when is_binary(data), do: Base.url_encode64(data, padding: false)

  defp b64url_decode(text) when is_binary(text) do
    case Base.url_decode64(text, padding: false) do
      {:ok, data} -> {:ok, data}
      :error -> {:error, :invalid_base64}
    end
  end

  defp base64_std_encode(data) when is_binary(data), do: Base.encode64(data)

  defp base64_std_decode(text) when is_binary(text) do
    case Base.decode64(text) do
      {:ok, data} -> {:ok, data}
      :error -> {:error, :invalid_base64}
    end
  end
end
