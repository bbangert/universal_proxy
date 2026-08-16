defmodule UniversalProxy.Sendspin.Pairing do
  @moduledoc """
  Sendspin PIN pairing — the client half (CPace party B / responder).

  Pairing runs *inside* an established Noise session: the server grants the
  `pairing` activity in `server/activate`, we open the attempt, and both
  sides end up holding a fresh 32-byte long-term PSK that promotes the next
  handshake from trust `none` to trust `user`. `source@v1` can never
  activate below trust `user`, so a capture-card client must pair before it
  can stream.

  This module is pure: it holds the attempt state in a struct and turns
  inbound decoded-JSON payloads into outbound ones. The connection FSM owns
  the websocket, the JSON codec, the Noise transport frames, the pairing
  counter and the 120 s attempt timeout (`attempt_timeout_ms/0`).

  ## Message flow (dynamic PIN)

      client -> client/pair-init     {pairing_index, commit_B}   start/1
      client <- server/pair-init     {nonce_A}                   → {:pin, pin, _}
      client <- server/pair-auth     {pake_msg_1 = Ya}
      client -> client/pair-auth     {pake_msg_2 = Yb}
      client <- server/pair-confirm  {server_kc = Ta}
      client -> client/pair-confirm  {client_kc = Tb, nonce_B}
      client -> client/pair-finalize {wrapped_psk}
      client <- server/pair-finalize {}                          → {:paired, _, _}

  Static PIN is the same flow minus `server/pair-init`, `commit_B` and
  `nonce_B`; the PIN is configured out of band and must be exactly 8 digits.

  ## PIN direction

  In the dynamic flow **we derive and display the PIN** and the operator
  types it into Music Assistant — not the other way round. Both nonces and
  the Noise handshake hash determine it (`derive_pin/4`), and our `commit_B`
  is sent before `nonce_A` exists so we cannot grind the digits. The server
  re-derives it from the `nonce_B` we reveal in `client/pair-confirm` and
  compares against what the operator typed (ground truth §3, "Server-side
  verification order"; `aiosendspin/noise/pairing.py` `run_dynamic_pin_client`
  calls `pin_emitter(pin)`).

  ## PSK direction

  **We** mint the long-term PSK, wrap it under `K_wrap` and send it in
  `client/pair-finalize`; the server unwraps and stores it (ground truth §3,
  "PSK wrapping"). Nothing is persisted until `server/pair-finalize` arrives.
  """

  alias UniversalProxy.Sendspin.CPace

  # Sendspin labels — ground truth §3 "Constants". Literal ASCII, no
  # separator and no NUL between a label and what follows it.
  @sid_label "sendspin-pair-pake-v1"
  @ad_server "server"
  @ad_client "client"
  @pin_derive_label "sendspin-pin-derive-v1"
  @commit_label "sendspin-pair-commit-v1"
  @psk_wrap_label "sendspin-pair-psk-wrap-v1"
  @psk_id_label "sendspin-psk-id-v1"

  # CPace's own MCF label (draft-irtf-cfrg-cpace-21 Section 7.4); the generic
  # CPace module deliberately stops short of message confirmation.
  @mac_label "CPaceMac"

  @nonce_bytes 32
  @commit_bytes 32
  @share_bytes 32
  @tag_bytes 64
  @psk_bytes 32
  @aead_tag_bytes 16
  @wrapped_psk_bytes @psk_bytes + @aead_tag_bytes

  # K_wrap is freshly derived per attempt and used once, so a fixed all-zero
  # nonce is safe (ground truth §3, "PSK wrapping").
  @psk_wrap_nonce :binary.copy(<<0>>, 12)

  @min_pin_digits 4
  @max_pin_digits 12
  @default_pin_digits 6
  @static_pin_digits 8

  @attempt_timeout_ms 120_000

  @abort_reasons %{
    attempt_timeout: "attempt_timeout",
    concurrent_attempt: "concurrent_attempt",
    method_not_supported: "method_not_supported",
    pin_length_unacceptable: "pin_length_unacceptable",
    pin_mismatch: "pin_mismatch",
    user_cancelled: "user_cancelled"
  }

  @type method :: :dynamic_pin | :static_pin
  @type abort_reason ::
          :attempt_timeout
          | :concurrent_attempt
          | :method_not_supported
          | :pin_length_unacceptable
          | :pin_mismatch
          | :user_cancelled

  @type stage ::
          :awaiting_server_init
          | :awaiting_pair_auth
          | :awaiting_pair_confirm
          | :awaiting_pair_finalize
          | :paired
          | {:failed, term()}

  @typedoc "An outbound message as `{type, payload}`; the FSM adds the envelope."
  @type message :: {String.t(), map()}

  @type outcome :: %{psk: binary(), psk_id: String.t(), category: :long_term}

  @typedoc """
  What the caller must do next.

    * `{:send, msgs, state}` — send each message, in order, and keep reading.
    * `{:pin, pin, state}` — show `pin` to the user; nothing to send yet.
    * `{:paired, outcome, state}` — persist the PSK; pairing is complete and
      the server will re-run the Noise handshake in band.
    * `{:abort, reason, msgs, state}` — send the `pair/abort` and stop.
    * `{:aborted, reason, state}` — the peer aborted; stop.
    * `{:error, reason, state}` — protocol error; close the connection and
      persist nothing.
  """
  @type step ::
          {:send, [message()], t()}
          | {:pin, String.t(), t()}
          | {:paired, outcome(), t()}
          | {:abort, abort_reason(), [message()], t()}
          | {:aborted, term(), t()}
          | {:error, term(), t()}

  @type t :: %__MODULE__{
          method: method(),
          stage: stage(),
          handshake_hash: binary(),
          pairing_index: non_neg_integer(),
          sid: binary(),
          suite: String.t(),
          pin_length: pos_integer(),
          pin: String.t() | nil,
          nonce_a: binary() | nil,
          nonce_b: binary() | nil,
          cpace: CPace.t() | nil,
          peer_share: binary() | nil,
          isk: binary() | nil,
          mac_key: binary() | nil,
          psk: binary(),
          cpace_scalar: binary() | nil
        }

  # Redact the secret fields from any crash report / RingLogger dump / observer
  # inspection: the minted long-term PSK, the derived PIN, the CPace
  # intermediate/MAC keys and the (test-only) CPace scalar.
  @derive {Inspect, except: [:psk, :pin, :isk, :mac_key, :cpace_scalar]}
  @enforce_keys [:method, :stage, :handshake_hash, :pairing_index, :sid, :suite, :psk]
  defstruct [
    :method,
    :stage,
    :handshake_hash,
    :pairing_index,
    :sid,
    :suite,
    :pin,
    :nonce_a,
    :nonce_b,
    :cpace,
    :peer_share,
    :isk,
    :mac_key,
    :psk,
    :cpace_scalar,
    pin_length: @default_pin_digits
  ]

  # -- Attempt lifecycle --

  @doc """
  Open a pairing attempt, returning the `client/pair-init` to send.

  Options:

    * `:handshake_hash` (required) — the 32-byte Noise handshake hash of the
      session this attempt runs inside.
    * `:pairing_index` (required) — the count of pairing `server/activate`
      messages since the last Noise handshake, first attempt being 1. It
      resets to 0 on every handshake, re-handshakes included.
    * `:suite` (required) — the negotiated Noise cipher suite string; it
      selects the AEAD that wraps the PSK.
    * `:method` — `:dynamic_pin` (default) or `:static_pin`.
    * `:pin_length` — dynamic PIN digits, 4..12, default 6.
    * `:pin` — required for `:static_pin`; exactly 8 decimal digits.
    * `:psk` — the long-term PSK to hand the server. Freshly sampled unless
      given; supply it only in tests.
    * `:nonce_b` — our 32-byte commit/reveal nonce. Test-only, as above.
    * `:cpace_scalar` — test-only CPace scalar, see `CPace.start/2`.
  """
  @spec start(keyword()) :: {:ok, [message()], t()} | {:error, term()}
  def start(opts) do
    method = Keyword.get(opts, :method, :dynamic_pin)

    with {:ok, hash} <- fetch_hash(opts),
         {:ok, index} <- fetch_index(opts),
         {:ok, _cipher} <- cipher_for(Keyword.get(opts, :suite)),
         {:ok, psk} <- fetch_psk(opts) do
      state = %__MODULE__{
        method: method,
        stage: :awaiting_server_init,
        handshake_hash: hash,
        pairing_index: index,
        sid: sid(hash, index),
        suite: Keyword.fetch!(opts, :suite),
        psk: psk,
        cpace_scalar: Keyword.get(opts, :cpace_scalar)
      }

      start_method(method, state, opts)
    end
  end

  @doc """
  Feed one decoded pairing message in, by wire `type` and payload map.

  Payload keys are the wire strings (`"nonce_A"`, `"pake_msg_1"`, …) and
  every binary field is base64url without padding.
  """
  @spec handle(t(), String.t(), map()) :: step()
  def handle(state, type, payload)

  def handle(%__MODULE__{} = state, "pair/abort", payload) do
    reason = decode_abort_reason(payload)
    {:aborted, reason, fail(state, {:peer_abort, reason})}
  end

  def handle(
        %__MODULE__{stage: :awaiting_server_init, method: :dynamic_pin} = state,
        "server/pair-init",
        payload
      ) do
    with {:ok, nonce_a} <- decode_field(payload, "nonce_A", @nonce_bytes),
         pin = derive_pin(state.handshake_hash, nonce_a, state.nonce_b, state.pin_length),
         {:ok, cpace} <- start_cpace(state, pin) do
      state = %{
        state
        | nonce_a: nonce_a,
          pin: pin,
          cpace: cpace,
          stage: :awaiting_pair_auth
      }

      {:pin, pin, state}
    else
      {:error, reason} -> {:error, reason, fail(state, reason)}
    end
  end

  def handle(%__MODULE__{stage: :awaiting_pair_auth} = state, "server/pair-auth", payload) do
    with {:ok, ya} <- decode_field(payload, "pake_msg_1", @share_bytes),
         {:ok, isk} <- finish_cpace(state.cpace, ya) do
      state = %{
        state
        | peer_share: ya,
          isk: isk,
          mac_key: mac_key(state.sid, isk),
          stage: :awaiting_pair_confirm
      }

      share = CPace.public_share(state.cpace)
      {:send, [{"client/pair-auth", %{"pake_msg_2" => b64(share)}}], state}
    else
      {:error, reason} -> {:error, reason, fail(state, reason)}
    end
  end

  def handle(%__MODULE__{stage: :awaiting_pair_confirm} = state, "server/pair-confirm", payload) do
    case decode_field(payload, "server_kc", @tag_bytes) do
      {:ok, ta} ->
        if server_tag_valid?(state, ta) do
          # The server's Tb check and the PSK unwrap both happen on its side
          # of one round trip, so confirm and finalize go out together.
          {:send, [confirm_message(state), finalize_message(state)],
           %{state | stage: :awaiting_pair_finalize}}
        else
          abort(state, :pin_mismatch)
        end

      {:error, reason} ->
        {:error, reason, fail(state, reason)}
    end
  end

  def handle(%__MODULE__{stage: :awaiting_pair_finalize} = state, "server/pair-finalize", _p) do
    outcome = %{psk: state.psk, psk_id: psk_id_for(state.psk), category: :long_term}
    {:paired, outcome, %{state | stage: :paired}}
  end

  def handle(%__MODULE__{} = state, type, _payload) do
    reason = {:unexpected_message, type, state.stage}
    {:error, reason, fail(state, reason)}
  end

  @doc """
  Abort the attempt ourselves, returning the `pair/abort` to send.

  Use it for the conditions the FSM owns — the 120 s attempt timeout, a
  user cancelling, an unsupported method offer.
  """
  @spec abort(t(), abort_reason()) :: {:abort, abort_reason(), [message()], t()}
  def abort(%__MODULE__{} = state, reason) when is_map_key(@abort_reasons, reason) do
    message = {"pair/abort", %{"reason" => Map.fetch!(@abort_reasons, reason)}}
    {:abort, reason, [message], fail(state, reason)}
  end

  @doc "Where the attempt currently stands."
  @spec stage(t()) :: stage()
  def stage(%__MODULE__{stage: stage}), do: stage

  @doc """
  The PIN to display, or `nil` before `server/pair-init` in a dynamic-PIN
  attempt.
  """
  @spec pin(t()) :: String.t() | nil
  def pin(%__MODULE__{pin: pin}), do: pin

  @doc """
  How long the client may take over the whole exchange before it must send
  `pair/abort` with `attempt_timeout` (`aiosendspin/noise/pairing.py`).
  """
  @spec attempt_timeout_ms() :: pos_integer()
  def attempt_timeout_ms, do: @attempt_timeout_ms

  # -- Protocol primitives --
  #
  # Public so the connection FSM, the credential store and the scripted
  # server in the tests all compute these the one documented way.

  @doc """
  The CPace session id: label, the Noise handshake hash, and the pairing
  counter as a big-endian `uint32` (ground truth §3, "`sid` construction").
  """
  @spec sid(binary(), non_neg_integer()) :: binary()
  def sid(handshake_hash, pairing_index)
      when byte_size(handshake_hash) == 32 and pairing_index in 0..0xFFFFFFFF do
    @sid_label <> handshake_hash <> <<pairing_index::unsigned-big-32>>
  end

  @doc "`commit_B` — our commitment to `nonce_B`, sent before `nonce_A` exists."
  @spec commit(binary()) :: binary()
  def commit(nonce) when byte_size(nonce) == @nonce_bytes,
    do: :crypto.hash(:sha256, @commit_label <> nonce)

  @doc "Constant-time check of a revealed nonce against its commitment."
  @spec commit_valid?(binary(), binary()) :: boolean()
  def commit_valid?(nonce, commitment)
      when byte_size(nonce) == @nonce_bytes and byte_size(commitment) == @commit_bytes,
      do: :crypto.hash_equals(commit(nonce), commitment)

  def commit_valid?(_nonce, _commitment), do: false

  @doc """
  The dynamic PIN: `SHA-256(label || h || nonce_A || nonce_B)` read as a
  big-endian integer, reduced mod `10^length` and zero-padded to `length`
  ASCII digits (ground truth §3, "PIN derivation").
  """
  @spec derive_pin(binary(), binary(), binary(), pos_integer()) :: String.t()
  def derive_pin(handshake_hash, nonce_a, nonce_b, length)
      when byte_size(nonce_a) == @nonce_bytes and byte_size(nonce_b) == @nonce_bytes and
             length in @min_pin_digits..@max_pin_digits do
    <<digest::unsigned-big-256>> =
      :crypto.hash(:sha256, @pin_derive_label <> handshake_hash <> nonce_a <> nonce_b)

    digest
    |> rem(Integer.pow(10, length))
    |> Integer.to_string()
    |> String.pad_leading(length, "0")
  end

  @doc "Whether `pin` is a well-formed static PIN — exactly 8 ASCII digits."
  @spec valid_static_pin?(term()) :: boolean()
  def valid_static_pin?(pin) when is_binary(pin) do
    byte_size(pin) == @static_pin_digits and pin =~ ~r/\A[0-9]+\z/
  end

  def valid_static_pin?(_pin), do: false

  @doc """
  The CPace MCF key, `SHA-512("CPaceMac" || sid || ISK)` — a plain
  concatenation, unlike the length-prefixed inputs elsewhere in CPace.
  """
  @spec mac_key(binary(), binary()) :: binary()
  def mac_key(sid, isk), do: :crypto.hash(:sha512, @mac_label <> sid <> isk)

  @doc """
  An MCF tag, `HMAC-SHA-512(mac_key, lv_cat(share, ad))`.

  `Ta` covers the server's `(Ya, "server")` and `Tb` the client's
  `(Yb, "client")`, whichever side is computing them (ground truth §3, "MCF
  tag construction").
  """
  @spec confirmation_tag(binary(), binary(), binary()) :: binary()
  def confirmation_tag(mac_key, share, ad),
    do: :crypto.mac(:hmac, :sha512, mac_key, CPace.lv_cat([share, ad]))

  @doc "The server's associated data — CPace `ADa`."
  @spec server_ad() :: String.t()
  def server_ad, do: @ad_server

  @doc "The client's associated data — CPace `ADb`."
  @spec client_ad() :: String.t()
  def client_ad, do: @ad_client

  @doc """
  `K_wrap = SHA-256(label || sid || ISK)`, the single-use key the PSK
  travels under.
  """
  @spec wrap_key(binary(), binary()) :: binary()
  def wrap_key(sid, isk), do: :crypto.hash(:sha256, @psk_wrap_label <> sid <> isk)

  @doc """
  Seal a 32-byte PSK under `K_wrap` with the connection's AEAD, an all-zero
  nonce and empty associated data. The result is 48 bytes.
  """
  @spec wrap_psk(binary(), binary(), binary()) :: binary()
  def wrap_psk(suite, wrap_key, psk) when byte_size(psk) == @psk_bytes do
    {:ok, cipher} = cipher_for(suite)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        cipher,
        wrap_key,
        @psk_wrap_nonce,
        psk,
        <<>>,
        @aead_tag_bytes,
        true
      )

    ciphertext <> tag
  end

  @doc """
  Open a wrapped PSK. An AEAD failure is a protocol error, not a wrong PIN —
  the MCF tags have already settled that question by this point.
  """
  @spec unwrap_psk(binary(), binary(), binary()) :: {:ok, binary()} | {:error, term()}
  def unwrap_psk(suite, wrap_key, wrapped) when byte_size(wrapped) == @wrapped_psk_bytes do
    <<ciphertext::binary-size(@psk_bytes), tag::binary-size(@aead_tag_bytes)>> = wrapped

    with {:ok, cipher} <- cipher_for(suite) do
      case :crypto.crypto_one_time_aead(
             cipher,
             wrap_key,
             @psk_wrap_nonce,
             ciphertext,
             <<>>,
             tag,
             false
           ) do
        :error -> {:error, :psk_unwrap_failed}
        psk -> {:ok, psk}
      end
    end
  end

  def unwrap_psk(_suite, _wrap_key, _wrapped), do: {:error, {:malformed_field, "wrapped_psk"}}

  @doc """
  The wire identifier for a PSK: `base64url(SHA-256(label || psk))`, no
  padding. One namespace across long-term, pairing and sentinel PSKs, so a
  lookup by `psk_id` must be unique across all three.
  """
  @spec psk_id_for(binary()) :: String.t()
  def psk_id_for(psk) when byte_size(psk) == @psk_bytes,
    do: b64(:crypto.hash(:sha256, @psk_id_label <> psk))

  @doc "A fresh long-term PSK."
  @spec generate_psk() :: binary()
  def generate_psk, do: :crypto.strong_rand_bytes(@psk_bytes)

  @doc "A fresh 32-byte commit/reveal nonce."
  @spec generate_nonce() :: binary()
  def generate_nonce, do: :crypto.strong_rand_bytes(@nonce_bytes)

  # -- Attempt setup --

  defp start_method(:dynamic_pin, state, opts) do
    with {:ok, length} <- fetch_pin_length(opts),
         {:ok, nonce_b} <- fetch_nonce(opts) do
      state = %{state | pin_length: length, nonce_b: nonce_b}

      payload = %{
        "pairing_index" => state.pairing_index,
        "commit_B" => b64(commit(nonce_b))
      }

      {:ok, [{"client/pair-init", payload}], state}
    end
  end

  defp start_method(:static_pin, state, opts) do
    pin = Keyword.get(opts, :pin)

    if valid_static_pin?(pin) do
      # No nonces and no commitment: the PIN is known to both sides up
      # front, so CPace can start before the server says anything.
      case start_cpace(state, pin) do
        {:ok, cpace} ->
          state = %{state | pin: pin, cpace: cpace, stage: :awaiting_pair_auth}
          {:ok, [{"client/pair-init", %{"pairing_index" => state.pairing_index}}], state}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, {:invalid_static_pin, pin}}
    end
  end

  defp start_method(other, _state, _opts), do: {:error, {:unsupported_method, other}}

  defp start_cpace(state, pin) do
    cpace_opts = [prs: pin, ci: "", sid: state.sid, ad: @ad_client]

    cpace_opts =
      if state.cpace_scalar,
        do: Keyword.put(cpace_opts, :scalar, state.cpace_scalar),
        else: cpace_opts

    case CPace.start(:b, cpace_opts) do
      {:ok, cpace} -> {:ok, cpace}
      :error -> {:error, :cpace_start_failed}
    end
  end

  # aiosendspin puts pake_msg_2 on the wire before deriving; deriving first
  # only means a low-order Ya costs the server nothing.
  defp finish_cpace(cpace, peer_share) do
    case CPace.finish(cpace, peer_share, @ad_server) do
      {:ok, isk} -> {:ok, isk}
      :error -> {:error, {:invalid_share, "pake_msg_1"}}
    end
  end

  # -- Message construction --

  defp confirm_message(%__MODULE__{method: :dynamic_pin} = state) do
    tag = confirmation_tag(state.mac_key, CPace.public_share(state.cpace), @ad_client)

    {"client/pair-confirm", %{"client_kc" => b64(tag), "nonce_B" => b64(state.nonce_b)}}
  end

  defp confirm_message(%__MODULE__{method: :static_pin} = state) do
    tag = confirmation_tag(state.mac_key, CPace.public_share(state.cpace), @ad_client)
    {"client/pair-confirm", %{"client_kc" => b64(tag)}}
  end

  defp finalize_message(%__MODULE__{} = state) do
    wrapped = wrap_psk(state.suite, wrap_key(state.sid, state.isk), state.psk)
    {"client/pair-finalize", %{"wrapped_psk" => b64(wrapped)}}
  end

  # -- Verification --

  defp server_tag_valid?(%__MODULE__{} = state, tag) do
    own = {CPace.public_share(state.cpace), @ad_client}
    peer = {state.peer_share, @ad_server}

    # cpace-py's reflection guard. Sendspin's two ADs differ, so a peer that
    # echoes our share still fails on the HMAC below; the check is kept so
    # the two implementations reject the same inputs for the same reason.
    if peer == own do
      false
    else
      :crypto.hash_equals(tag, confirmation_tag(state.mac_key, state.peer_share, @ad_server))
    end
  end

  # -- Option validation --

  defp fetch_hash(opts) do
    case Keyword.get(opts, :handshake_hash) do
      <<hash::binary-size(32)>> -> {:ok, hash}
      other -> {:error, {:invalid_handshake_hash, other}}
    end
  end

  defp fetch_index(opts) do
    case Keyword.get(opts, :pairing_index) do
      index when is_integer(index) and index in 0..0xFFFFFFFF -> {:ok, index}
      other -> {:error, {:invalid_pairing_index, other}}
    end
  end

  defp fetch_psk(opts) do
    case Keyword.get(opts, :psk, generate_psk()) do
      <<psk::binary-size(@psk_bytes)>> -> {:ok, psk}
      other -> {:error, {:invalid_psk, byte_size_of(other)}}
    end
  end

  defp fetch_nonce(opts) do
    case Keyword.get(opts, :nonce_b, generate_nonce()) do
      <<nonce::binary-size(@nonce_bytes)>> -> {:ok, nonce}
      other -> {:error, {:invalid_nonce, byte_size_of(other)}}
    end
  end

  defp fetch_pin_length(opts) do
    case Keyword.get(opts, :pin_length, @default_pin_digits) do
      length when length in @min_pin_digits..@max_pin_digits -> {:ok, length}
      other -> {:error, {:invalid_pin_length, other}}
    end
  end

  defp cipher_for("25519_AESGCM_SHA256"), do: {:ok, :aes_256_gcm}
  defp cipher_for("25519_ChaChaPoly_SHA256"), do: {:ok, :chacha20_poly1305}
  defp cipher_for(other), do: {:error, {:unsupported_suite, other}}

  defp byte_size_of(value) when is_binary(value), do: byte_size(value)
  defp byte_size_of(value), do: value

  # -- Wire helpers --

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)

  defp decode_field(payload, key, size) do
    with {:ok, value} when is_binary(value) <- Map.fetch(payload, key),
         {:ok, raw} <- Base.url_decode64(String.trim_trailing(value, "="), padding: false),
         ^size <- byte_size(raw) do
      {:ok, raw}
    else
      _other -> {:error, {:malformed_field, key}}
    end
  end

  defp decode_abort_reason(payload) do
    wire = Map.get(payload, "reason")

    Enum.find_value(@abort_reasons, {:unknown, wire}, fn {atom, string} ->
      if string == wire, do: atom
    end)
  end

  defp fail(%__MODULE__{} = state, reason), do: %{state | stage: {:failed, reason}}
end
