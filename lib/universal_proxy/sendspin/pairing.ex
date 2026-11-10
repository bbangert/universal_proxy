defmodule UniversalProxy.Sendspin.Pairing do
  @moduledoc """
  Sendspin pairing — the client half (CPace party B / responder), per
  Sendspin 1.0.0-rc1 `pairing.md`.

  Pairing runs *inside* an established Noise session: the server grants the
  `pairing` activity in `server/activate`, we open the attempt, and both
  sides end up holding a fresh 32-byte long-term PSK. Only a session keyed by
  a long-term PSK may activate roles on a client without unpaired access, so
  a capture-card source must pair before it can stream.

  This module is pure: it holds the attempt state in a struct and turns
  inbound decoded-JSON payloads into outbound ones. The connection FSM owns
  the websocket, the JSON codec, the Noise transport frames, the pairing
  counter and the 120 s attempt timeout (`attempt_timeout_ms/0`).

  ## Methods

  **Pairing PSK** (`:pairing_psk`) — the session's Noise handshake already
  authenticated both sides with the client's pairing PSK (the secret behind
  its pairing token), so there is no PAKE: `client/pair-init` and
  `client/pair-finalize {long_term_psk}` go out back to back, and
  `server/pair-finalize` completes it.

  **Dynamic pairing code** (`:dynamic_pairing_code`, `digits` format):

      client -> client/pair-init     {pairing_index, commit_B}   start/1
      client <- server/pair-init     {nonce_A}                   → {:pin, code, _}
      client <- server/pair-auth     {pake_msg_1 = Ya}
      client -> client/pair-auth     {pake_msg_2 = Yb}
      client <- server/pair-confirm  {server_kc = Ta}
      client -> client/pair-confirm  {client_kc = Tb, wrapped_nonce_B}
      client -> client/pair-finalize {wrapped_psk}
      client <- server/pair-finalize {}                          → {:paired, _, _}

  A `server_kc` that fails to verify (a mistyped code) answers
  `client/pair-retry` instead of `client/pair-confirm`, and the server starts
  another **round** with a `server/pair-init` carrying no nonce: the code is
  unchanged, but each round runs a fresh CPace under its own `sid` (the round
  number is part of it). At `:max_rounds` we abort with
  `pairing_code_mismatch` instead of retrying.

  **Static pairing code** (`:static_pairing_code`) is the same exchange
  minus `server/pair-init`, `commit_B`, `wrapped_nonce_B` and retries; the
  code is configured out of band and must be exactly 8 digits.

  ## Code direction

  In the dynamic flow **we derive and display the code** and the operator
  types it into the server. Both nonces and the Noise handshake hash
  determine it (`derive_pairing_code/3`), and our `commit_B` is sent before
  `nonce_A` exists so we cannot grind the digits. The server re-derives it
  from the `nonce_B` we reveal (sealed) in `client/pair-confirm`.

  ## PSK direction

  **We** mint the long-term PSK and send it in `client/pair-finalize` —
  wrapped under the CPace output in the code flows, in the clear (inside
  the Noise channel) in the Pairing PSK flow. Nothing is persisted until
  `server/pair-finalize` arrives.
  """

  alias UniversalProxy.Sendspin.CPace

  # Sendspin labels (`pairing.md`). Literal ASCII, no separator and no NUL
  # between a label and what follows it.
  @sid_label "sendspin-pair-pake-v1"
  @ad_server "server"
  @ad_client "client"
  @code_derive_label "sendspin-pairing-code-derive-v1"
  @commit_label "sendspin-pair-commit-v1"
  @psk_wrap_label "sendspin-pair-psk-wrap-v1"
  @nonce_wrap_label "sendspin-pair-nonce-wrap-v1"
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
  @wrapped_bytes @psk_bytes + @aead_tag_bytes

  # Every wrap key is per-field and used once, so a fixed all-zero nonce is
  # safe (`pairing.md` "Wrapping").
  @wrap_nonce :binary.copy(<<0>>, 12)

  @dynamic_code_digits 6
  @static_code_digits 8

  # `pairing.md` "Rounds": after 20 rounds since the last verified
  # `server_kc` the client MUST abort rather than retry.
  @round_limit 20

  @attempt_timeout_ms 120_000

  @abort_reasons %{
    attempt_timeout: "attempt_timeout",
    concurrent_attempt: "concurrent_attempt",
    method_not_supported: "method_not_supported",
    pairing_code_mismatch: "pairing_code_mismatch",
    user_cancelled: "user_cancelled"
  }

  @type method :: :dynamic_pairing_code | :static_pairing_code | :pairing_psk
  @type abort_reason ::
          :attempt_timeout
          | :concurrent_attempt
          | :method_not_supported
          | :pairing_code_mismatch
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
    * `{:pin, code, state}` — show `code` to the user (again, on a retry
      round); nothing to send yet.
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
          round: pos_integer(),
          max_rounds: pos_integer(),
          sid: binary(),
          suite: String.t(),
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
  # inspection: the minted long-term PSK, the derived code, the CPace
  # intermediate/MAC keys, the commit/reveal nonce (secret until revealed in
  # `client/pair-confirm`) and the (test-only) CPace scalar. The live CPace
  # scalar lives inside the `:cpace` field's `%CPace{}`, which self-redacts it
  # via its own `@derive {Inspect, except: [:scalar]}`.
  @derive {Inspect, except: [:psk, :pin, :isk, :mac_key, :nonce_b, :cpace_scalar]}
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
    round: 1,
    max_rounds: @round_limit
  ]

  # -- Attempt lifecycle --

  @doc """
  Open a pairing attempt, returning the message(s) to send.

  Options:

    * `:handshake_hash` (required) — the 32-byte Noise handshake hash of the
      session this attempt runs inside.
    * `:pairing_index` (required) — the count of pairing `server/activate`
      messages received since the last Noise handshake, first being 1. It
      resets to 0 on every handshake, re-handshakes included.
    * `:suite` (required) — the negotiated Noise cipher suite string; it
      selects the AEAD that wraps the PSK and `nonce_B`.
    * `:method` — `:dynamic_pairing_code` (default), `:static_pairing_code`
      or `:pairing_psk`.
    * `:max_rounds` — dynamic code rounds this attempt may run before it
      aborts instead of retrying, 1..#{@round_limit} (default #{@round_limit}).
    * `:pin` — required for `:static_pairing_code`; exactly 8 decimal digits.
    * `:psk` — the long-term PSK to hand the server. Freshly sampled unless
      given; supply it only in tests.
    * `:nonce_b` — our 32-byte commit/reveal nonce. Test-only, as above.
    * `:cpace_scalar` — test-only CPace scalar, see `CPace.start/2`.
  """
  @spec start(keyword()) :: {:ok, [message()], t()} | {:error, term()}
  def start(opts) do
    method = Keyword.get(opts, :method, :dynamic_pairing_code)

    with {:ok, hash} <- fetch_hash(opts),
         {:ok, index} <- fetch_index(opts),
         {:ok, max_rounds} <- fetch_max_rounds(opts),
         {:ok, _cipher} <- cipher_for(Keyword.get(opts, :suite)),
         {:ok, psk} <- fetch_psk(opts) do
      state = %__MODULE__{
        method: method,
        stage: :awaiting_server_init,
        handshake_hash: hash,
        pairing_index: index,
        max_rounds: max_rounds,
        sid: sid(hash, index, 1),
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

  # The first round carries the server's nonce and fixes the code.
  def handle(
        %__MODULE__{stage: :awaiting_server_init, method: :dynamic_pairing_code, round: 1} =
          state,
        "server/pair-init",
        payload
      ) do
    with {:ok, nonce_a} <- decode_field(payload, "nonce_A", @nonce_bytes),
         code = derive_pairing_code(state.handshake_hash, nonce_a, state.nonce_b),
         {:ok, cpace} <- start_cpace(state, code) do
      {:pin, code,
       %{state | nonce_a: nonce_a, pin: code, cpace: cpace, stage: :awaiting_pair_auth}}
    else
      {:error, reason} -> {:error, reason, fail(state, reason)}
    end
  end

  # A retry round: same code, no nonce, a fresh CPace under the round's sid.
  def handle(
        %__MODULE__{stage: :awaiting_server_init, method: :dynamic_pairing_code} = state,
        "server/pair-init",
        payload
      ) do
    if Map.has_key?(payload, "nonce_A") do
      reason = {:unexpected_field, "nonce_A"}
      {:error, reason, fail(state, reason)}
    else
      case start_cpace(state, state.pin) do
        {:ok, cpace} -> {:pin, state.pin, %{state | cpace: cpace, stage: :awaiting_pair_auth}}
        {:error, reason} -> {:error, reason, fail(state, reason)}
      end
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
        cond do
          server_tag_valid?(state, ta) ->
            # The server's checks and the PSK unwrap all happen on its side
            # of one round trip, so confirm and finalize go out together.
            {:send, [confirm_message(state), finalize_message(state)],
             %{state | stage: :awaiting_pair_finalize}}

          state.method == :dynamic_pairing_code and state.round < state.max_rounds ->
            retry(state)

          true ->
            abort(state, :pairing_code_mismatch)
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
  The code to display, or `nil` before `server/pair-init` in a dynamic
  attempt.
  """
  @spec pin(t()) :: String.t() | nil
  def pin(%__MODULE__{pin: pin}), do: pin

  @doc "The current dynamic-pairing-code round, 1 for the first."
  @spec round(t()) :: pos_integer()
  def round(%__MODULE__{round: round}), do: round

  @doc """
  How long the client may take over the whole exchange before it must send
  `pair/abort` with `attempt_timeout` (`pairing.md` recommends 2 minutes).
  """
  @spec attempt_timeout_ms() :: pos_integer()
  def attempt_timeout_ms, do: @attempt_timeout_ms

  @doc "The spec's round limit since the last verified `server_kc`."
  @spec round_limit() :: pos_integer()
  def round_limit, do: @round_limit

  # -- Protocol primitives --
  #
  # Public so the connection FSM, the credential store and the scripted
  # server in the tests all compute these the one documented way.

  @doc """
  The CPace session id: label, the Noise handshake hash, the pairing index
  and the round, both as big-endian `uint32` (`pairing.md` "PAKE").
  """
  @spec sid(binary(), non_neg_integer(), pos_integer()) :: binary()
  def sid(handshake_hash, pairing_index, round)
      when byte_size(handshake_hash) == 32 and pairing_index in 0..0xFFFFFFFF and
             round in 1..0xFFFFFFFF do
    @sid_label <> handshake_hash <> <<pairing_index::unsigned-big-32, round::unsigned-big-32>>
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
  The dynamic pairing code in the `digits` format:
  `SHA-256("sendspin-pairing-code-derive-v1" || h || nonce_A || nonce_B)`
  read as a big-endian integer, reduced mod `10^6` and zero-padded to 6 ASCII
  digits.
  """
  @spec derive_pairing_code(binary(), binary(), binary()) :: String.t()
  def derive_pairing_code(handshake_hash, nonce_a, nonce_b)
      when byte_size(handshake_hash) == 32 and byte_size(nonce_a) == @nonce_bytes and
             byte_size(nonce_b) == @nonce_bytes do
    <<digest::unsigned-big-256>> =
      :crypto.hash(:sha256, @code_derive_label <> handshake_hash <> nonce_a <> nonce_b)

    digest
    |> rem(Integer.pow(10, @dynamic_code_digits))
    |> Integer.to_string()
    |> String.pad_leading(@dynamic_code_digits, "0")
  end

  @doc "Whether `code` is a well-formed static pairing code — exactly 8 ASCII digits."
  @spec valid_static_pairing_code?(term()) :: boolean()
  def valid_static_pairing_code?(code) when is_binary(code) do
    byte_size(code) == @static_code_digits and code =~ ~r/\A[0-9]+\z/
  end

  def valid_static_pairing_code?(_code), do: false

  @doc """
  The CPace MCF key, `SHA-512("CPaceMac" || sid || ISK)` — a plain
  concatenation, unlike the length-prefixed inputs elsewhere in CPace.
  """
  @spec mac_key(binary(), binary()) :: binary()
  def mac_key(sid, isk), do: :crypto.hash(:sha512, @mac_label <> sid <> isk)

  @doc """
  An MCF tag, `HMAC-SHA-512(mac_key, lv_cat(share, ad))`.

  `Ta` covers the server's `(Ya, "server")` and `Tb` the client's
  `(Yb, "client")`, whichever side is computing them.
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
  `K_wrap = SHA-256("sendspin-pair-psk-wrap-v1" || sid || ISK)`, the
  single-use key the long-term PSK travels under.
  """
  @spec wrap_key(binary(), binary()) :: binary()
  def wrap_key(sid, isk), do: :crypto.hash(:sha256, @psk_wrap_label <> sid <> isk)

  @doc """
  `K_wrap = SHA-256("sendspin-pair-nonce-wrap-v1" || sid || ISK)`, the
  single-use key `nonce_B` is revealed under (as `wrapped_nonce_B`).
  """
  @spec nonce_wrap_key(binary(), binary()) :: binary()
  def nonce_wrap_key(sid, isk), do: :crypto.hash(:sha256, @nonce_wrap_label <> sid <> isk)

  @doc """
  Seal a 32-byte value under a wrap key with the connection's AEAD, an
  all-zero nonce and empty associated data. The result is 48 bytes.
  """
  @spec wrap(binary(), binary(), binary()) :: binary()
  def wrap(suite, wrap_key, value) when byte_size(value) == @psk_bytes do
    {:ok, cipher} = cipher_for(suite)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        cipher,
        wrap_key,
        @wrap_nonce,
        value,
        <<>>,
        @aead_tag_bytes,
        true
      )

    ciphertext <> tag
  end

  @doc """
  Open a wrapped value. An AEAD failure is a protocol error, not a wrong
  code — the MCF tags have already settled that question by this point.
  """
  @spec unwrap(binary(), binary(), binary()) :: {:ok, binary()} | {:error, term()}
  def unwrap(suite, wrap_key, wrapped) when byte_size(wrapped) == @wrapped_bytes do
    <<ciphertext::binary-size(@psk_bytes), tag::binary-size(@aead_tag_bytes)>> = wrapped

    with {:ok, cipher} <- cipher_for(suite) do
      case :crypto.crypto_one_time_aead(
             cipher,
             wrap_key,
             @wrap_nonce,
             ciphertext,
             <<>>,
             tag,
             false
           ) do
        :error -> {:error, :unwrap_failed}
        value -> {:ok, value}
      end
    end
  end

  def unwrap(_suite, _wrap_key, _wrapped), do: {:error, :malformed_wrapped_value}

  @doc """
  The wire identifier for a PSK: `base64url(SHA-256(label || psk))`, no
  padding. One namespace across long-term, pairing and sentinel PSKs; the
  `psk_category` beside it in Noise message 1 says which store to look in.
  """
  @spec psk_id_for(binary()) :: String.t()
  def psk_id_for(psk) when byte_size(psk) == @psk_bytes,
    do: b64(:crypto.hash(:sha256, @psk_id_label <> psk))

  @doc "A fresh 32-byte PSK (long-term or pairing), from the CSPRNG."
  @spec generate_psk() :: binary()
  def generate_psk, do: :crypto.strong_rand_bytes(@psk_bytes)

  @doc "A fresh 32-byte commit/reveal nonce."
  @spec generate_nonce() :: binary()
  def generate_nonce, do: :crypto.strong_rand_bytes(@nonce_bytes)

  # -- Attempt setup --

  defp start_method(:dynamic_pairing_code, state, opts) do
    with {:ok, nonce_b} <- fetch_nonce(opts) do
      state = %{state | nonce_b: nonce_b}

      payload = %{
        "pairing_index" => state.pairing_index,
        "commit_B" => b64(commit(nonce_b))
      }

      {:ok, [{"client/pair-init", payload}], state}
    end
  end

  defp start_method(:static_pairing_code, state, opts) do
    pin = Keyword.get(opts, :pin)

    if valid_static_pairing_code?(pin) do
      # No nonces and no commitment: the code is known to both sides up
      # front, so CPace can start before the server says anything.
      case start_cpace(state, pin) do
        {:ok, cpace} ->
          state = %{state | pin: pin, cpace: cpace, stage: :awaiting_pair_auth}
          {:ok, [{"client/pair-init", %{"pairing_index" => state.pairing_index}}], state}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :invalid_static_pairing_code}
    end
  end

  # The session itself was keyed by the pairing PSK, so both sides are
  # already authenticated: pair-init then the long-term PSK, back to back.
  defp start_method(:pairing_psk, state, _opts) do
    messages = [
      {"client/pair-init", %{"pairing_index" => state.pairing_index}},
      {"client/pair-finalize", %{"long_term_psk" => b64(state.psk)}}
    ]

    {:ok, messages, %{state | stage: :awaiting_pair_finalize}}
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

  # Ask for another round under the same code. The next round's CPace runs
  # under its own sid, so this round's keys are dropped.
  defp retry(state) do
    round = state.round + 1

    state = %{
      state
      | round: round,
        sid: sid(state.handshake_hash, state.pairing_index, round),
        cpace: nil,
        peer_share: nil,
        isk: nil,
        mac_key: nil,
        stage: :awaiting_server_init
    }

    {:send, [{"client/pair-retry", %{}}], state}
  end

  # -- Message construction --

  defp confirm_message(%__MODULE__{method: :dynamic_pairing_code} = state) do
    tag = confirmation_tag(state.mac_key, CPace.public_share(state.cpace), @ad_client)
    wrapped_nonce = wrap(state.suite, nonce_wrap_key(state.sid, state.isk), state.nonce_b)

    {"client/pair-confirm", %{"client_kc" => b64(tag), "wrapped_nonce_B" => b64(wrapped_nonce)}}
  end

  defp confirm_message(%__MODULE__{method: :static_pairing_code} = state) do
    tag = confirmation_tag(state.mac_key, CPace.public_share(state.cpace), @ad_client)
    {"client/pair-confirm", %{"client_kc" => b64(tag)}}
  end

  defp finalize_message(%__MODULE__{} = state) do
    wrapped = wrap(state.suite, wrap_key(state.sid, state.isk), state.psk)
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

  defp fetch_max_rounds(opts) do
    case Keyword.get(opts, :max_rounds, @round_limit) do
      rounds when is_integer(rounds) and rounds in 1..@round_limit -> {:ok, rounds}
      other -> {:error, {:invalid_max_rounds, other}}
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
