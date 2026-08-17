defmodule UniversalProxy.Sendspin.Noise do
  @moduledoc """
  Noise transport session for the Sendspin protocol, backed by `Decibel`.

  Sendspin encrypts every connection with `Noise_KKpsk2_<suite>`, where the
  suite is one of `"25519_ChaChaPoly_SHA256"` (software) or
  `"25519_AESGCM_SHA256"` (hardware-accelerated) and is agreed in the
  cleartext `client/init` / `server/init` exchange.

  **We are always the Noise responder** and the Sendspin server (Music
  Assistant) is always the initiator, regardless of which side opened the
  websocket — with a capture-card source we host the listener and the server
  dials in, yet the role assignment is unchanged. The message flow is:

      server -> msg1   read_handshake/2
      server <- msg2   write_handshake/1   (PSK mixed in here, per psk2)
      ... transport mode: encrypt/2 and decrypt/2

  Both static keys are pre-known (`KK`): ours is the `client_id`, the peer's
  is the `server_id` from `server/init`. The prologue is the exact wire bytes
  of `client/init` followed by `server/init`, so a mismatch on either side
  fails msg1 authentication.

  Transport messages are raw Noise ciphertexts carried in websocket binary
  frames — the websocket supplies the framing, so nothing here adds a length
  prefix.

  ## Single-process ownership

  Decibel keeps session state in the **process dictionary**, keyed by the ref
  returned from `Decibel.new/4`. A session therefore only works in the process
  that called `start/1`; the struct records that owner and every function
  raises `ArgumentError` when called from anywhere else. Drive one session
  from one connection process (and hand it no further once that process dies —
  the state dies with it).

  Distinct sessions in the same process are independent (each has its own
  ref), so a process may hold several at once, e.g. across a re-handshake.
  """

  @enforce_keys [:ref, :owner, :protocol]
  defstruct [:ref, :owner, :protocol]

  @opaque t :: %__MODULE__{ref: reference(), owner: pid(), protocol: String.t()}

  @type suite :: String.t()
  @type key :: <<_::256>>

  @suites %{
    "25519_ChaChaPoly_SHA256" => "Noise_KKpsk2_25519_ChaChaPoly_SHA256",
    "25519_AESGCM_SHA256" => "Noise_KKpsk2_25519_AESGCM_SHA256"
  }

  # KKpsk2 always mixes a PSK — there is no zero-PSK path. Before any pairing
  # record exists both sides use this published constant, so an unpaired
  # connection is authenticated only by possession of the peer's claimed
  # static key (`connection.md` lines 107-119, `aiosendspin/noise/constants.py`
  # line 11).
  @sentinel_psk :crypto.hash(:sha256, "sendspin-sentinel-psk-v1")

  @doc """
  The published Sentinel PSK, `SHA-256("sendspin-sentinel-psk-v1")`.

  Used for every connection that has no long-term pairing record yet. Its
  `psk_id` (`UniversalProxy.Sendspin.Pairing.psk_id_for/1`) is what a server
  sends in Noise message 1 when it has no record for us either.
  """
  @spec sentinel_psk() :: key()
  def sentinel_psk, do: @sentinel_psk

  @doc """
  The cipher suites we accept in the `client/init` / `server/init` exchange.
  """
  @spec supported_suites() :: [suite()]
  def supported_suites, do: @suites |> Map.keys() |> Enum.sort()

  @doc """
  Map a Sendspin cipher-suite string to its full Noise protocol name.
  """
  @spec protocol_name(suite()) :: {:ok, String.t()} | {:error, {:unsupported_suite, term()}}
  def protocol_name(suite) do
    case Map.fetch(@suites, suite) do
      {:ok, name} -> {:ok, name}
      :error -> {:error, {:unsupported_suite, suite}}
    end
  end

  @doc """
  Generate an X25519 static keypair as `{public, private}`.

  The public half is the device's Sendspin `client_id` (base64url-encoded, no
  padding, by the caller); the pair is persisted and reused across sessions.
  """
  @spec generate_static_keypair() :: {key(), binary()}
  def generate_static_keypair, do: :crypto.generate_key(:ecdh, :x25519)

  @doc """
  Start a responder session, owned by the calling process.

  Options:

    * `:static_keypair` — our `{public, private}` X25519 static pair
    * `:remote_static_key` — the server's 32-byte static public key (`server_id`)
    * `:psk` — the 32-byte pre-shared key
    * `:prologue` — iodata; exact `client/init` then `server/init` wire bytes
    * `:suite` — a `supported_suites/0` value
  """
  @spec start(keyword()) :: {:ok, t()} | {:error, term()}
  def start(opts) do
    with {:ok, protocol} <- protocol_name(Keyword.get(opts, :suite)),
         {:ok, {pub, priv}} <- validate_keypair(Keyword.get(opts, :static_keypair)),
         {:ok, rs} <- validate_key(Keyword.get(opts, :remote_static_key), :remote_static_key),
         {:ok, psk} <- validate_key(Keyword.get(opts, :psk), :psk) do
      keys = %{
        s: {pub, priv},
        rs: rs,
        psks: [psk],
        prologue: Keyword.get(opts, :prologue, [])
      }

      ref = Decibel.new(protocol, :rsp, keys)
      {:ok, %__MODULE__{ref: ref, owner: self(), protocol: protocol}}
    end
  end

  @doc """
  Consume the server's handshake message 1, returning any handshake payload.

  Returns `{:error, :decrypt_failed}` when the message does not authenticate —
  a wrong server static key or a prologue that differs from the server's both
  land here.
  """
  @spec read_handshake(t(), iodata()) :: {:ok, binary()} | {:error, term()}
  def read_handshake(%__MODULE__{} = session, message) do
    ref = ref!(session)

    if Decibel.is_handshake_complete?(ref) do
      {:error, :handshake_complete}
    else
      try do
        {:ok, IO.iodata_to_binary(Decibel.handshake_decrypt(ref, message))}
      rescue
        Decibel.DecryptionError -> {:error, :decrypt_failed}
        # A truncated message runs the token reader off the end of the buffer.
        MatchError -> {:error, :malformed_handshake}
      end
    end
  end

  @doc """
  Produce handshake message 2, carrying `payload` as its inner plaintext. The
  PSK is mixed in here (psk2), after which the session is in transport mode.

  Sendspin requires the payload to be the literal two bytes `{}` — an empty
  Noise payload is rejected by the server's `_validate_msg2_payload` — so
  callers must pass it explicitly; the default empty payload exists only for
  tests exercising the raw Noise layer.
  """
  @spec write_handshake(t(), iodata()) :: {:ok, binary()} | {:error, term()}
  def write_handshake(session, payload \\ [])

  def write_handshake(%__MODULE__{} = session, payload) do
    ref = ref!(session)

    if Decibel.is_handshake_complete?(ref) do
      {:error, :handshake_complete}
    else
      {:ok, IO.iodata_to_binary(Decibel.handshake_encrypt(ref, payload))}
    end
  end

  @doc """
  `true` once the handshake has completed and transport mode is active.
  """
  @spec finished?(t()) :: boolean()
  def finished?(%__MODULE__{} = session), do: Decibel.is_handshake_complete?(ref!(session))

  @doc """
  The 32-byte handshake hash of the completed handshake, or `nil` before that.

  The pairing layer binds its CPace session id and PIN derivation to this
  value, so it must be read from the session that ran the handshake.
  """
  @spec handshake_hash(t()) :: key() | nil
  def handshake_hash(%__MODULE__{} = session), do: Decibel.get_handshake_hash(ref!(session))

  @doc """
  Encrypt an outbound transport message. The result is the websocket binary
  frame payload verbatim.
  """
  @spec encrypt(t(), iodata()) :: {:ok, binary()} | {:error, term()}
  def encrypt(%__MODULE__{} = session, plaintext) do
    ref = ref!(session)

    if Decibel.is_handshake_complete?(ref) do
      {:ok, IO.iodata_to_binary(Decibel.encrypt(ref, plaintext))}
    else
      {:error, :handshake_incomplete}
    end
  end

  @doc """
  Decrypt an inbound transport message.

  Returns `{:error, :decrypt_failed}` on a tampered, truncated or out-of-order
  ciphertext. The inbound nonce is only advanced on success, so a failure does
  not desynchronise a subsequent good message.
  """
  @spec decrypt(t(), iodata()) :: {:ok, binary()} | {:error, term()}
  def decrypt(%__MODULE__{} = session, ciphertext) do
    ref = ref!(session)

    if Decibel.is_handshake_complete?(ref) do
      try do
        {:ok, IO.iodata_to_binary(Decibel.decrypt(ref, ciphertext))}
      rescue
        Decibel.DecryptionError -> {:error, :decrypt_failed}
        # Anything shorter than the AEAD tag never reaches the cipher.
        ArgumentError -> {:error, :decrypt_failed}
      end
    else
      {:error, :handshake_incomplete}
    end
  end

  @doc """
  Discard the session's keys. Implicit when the owning process exits.
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{} = session), do: Decibel.close(ref!(session))

  # -- Private --

  defp ref!(%__MODULE__{ref: ref, owner: owner}) when owner == self(), do: ref

  defp ref!(%__MODULE__{owner: owner}) do
    raise ArgumentError,
          "Sendspin Noise session is owned by #{inspect(owner)} but was used from " <>
            "#{inspect(self())}; decibel keeps session state in the process dictionary"
  end

  # X25519 keys are exactly 32 bytes both halves; a malformed priv must
  # fail here with the tagged error rather than deferring to a raw
  # Decibel/:crypto failure further into the handshake.
  defp validate_keypair({<<_::256>> = pub, <<_::256>> = priv}), do: {:ok, {pub, priv}}
  defp validate_keypair(_other), do: {:error, {:invalid_key, :static_keypair}}

  defp validate_key(<<_::256>> = key, _name), do: {:ok, key}
  defp validate_key(_other, name), do: {:error, {:invalid_key, name}}
end
