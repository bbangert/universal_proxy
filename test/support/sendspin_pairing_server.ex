defmodule UniversalProxy.SendspinPairingServer do
  @moduledoc """
  A scripted Music-Assistant-side pairing peer — CPace party A (initiator).

  Written straight from the ground-truth spec
  (`.claude/plans/usb-audio-input/research/aiosendspin-ground-truth.md` §3)
  rather than by mirroring `UniversalProxy.Sendspin.Pairing`, so a
  round-trip test exercises both halves of the exchange. It shares the
  client's protocol primitives (`sid/2`, `derive_pin/4`, `mac_key/2`, …)
  because those are the one documented construction, not per-role logic.

  Like the client it is pure: `handle/3` takes a wire `type` plus a decoded
  payload map and returns what the server would send next.
  """

  alias UniversalProxy.Sendspin.CPace
  alias UniversalProxy.Sendspin.Pairing

  @enforce_keys [:method, :handshake_hash, :pairing_index, :sid, :suite, :nonce_a, :pin_length]
  defstruct [
    :method,
    :handshake_hash,
    :pairing_index,
    :sid,
    :suite,
    :nonce_a,
    :pin_length,
    :pin,
    :commit_b,
    :cpace,
    :peer_share,
    :isk,
    :mac_key,
    :psk
  ]

  @doc """
  Build a server-side attempt.

  Options mirror the client's: `:handshake_hash`, `:pairing_index`,
  `:suite`, `:method`, `:pin_length`, plus `:nonce_a` and `:pin` (the PIN an
  operator typed; required up front for `:static_pin`, supplied later via
  `submit_pin/2` for `:dynamic_pin`).
  """
  def start(opts) do
    hash = Keyword.fetch!(opts, :handshake_hash)
    index = Keyword.fetch!(opts, :pairing_index)

    %__MODULE__{
      method: Keyword.get(opts, :method, :dynamic_pin),
      handshake_hash: hash,
      pairing_index: index,
      sid: Pairing.sid(hash, index),
      suite: Keyword.fetch!(opts, :suite),
      nonce_a: Keyword.get_lazy(opts, :nonce_a, &Pairing.generate_nonce/0),
      pin_length: Keyword.get(opts, :pin_length, 6),
      pin: Keyword.get(opts, :pin)
    }
  end

  @doc "Feed the server one client message."
  def handle(server, type, payload)

  def handle(%__MODULE__{method: :dynamic_pin} = server, "client/pair-init", payload) do
    {:ok, commit_b} = decode(payload["commit_B"], 32)
    server = %{server | commit_b: commit_b}
    {:send, [{"server/pair-init", %{"nonce_A" => b64(server.nonce_a)}}], server}
  end

  def handle(%__MODULE__{method: :static_pin} = server, "client/pair-init", payload) do
    refute_key(payload, "commit_B")
    pair_auth(server, server.pin)
  end

  def handle(%__MODULE__{} = server, "client/pair-auth", payload) do
    {:ok, yb} = decode(payload["pake_msg_2"], 32)
    {:ok, isk} = CPace.finish(server.cpace, yb, Pairing.client_ad())
    mac_key = Pairing.mac_key(server.sid, isk)
    server = %{server | peer_share: yb, isk: isk, mac_key: mac_key}

    tag = Pairing.confirmation_tag(mac_key, CPace.public_share(server.cpace), Pairing.server_ad())
    {:send, [{"server/pair-confirm", %{"server_kc" => b64(tag)}}], server}
  end

  # Verification order per ground truth §3: commitment, then the MCF tag,
  # then that the PIN really was derived from both nonces. Only the last two
  # are reported as pin_mismatch.
  def handle(%__MODULE__{} = server, "client/pair-confirm", payload) do
    {:ok, tb} = decode(payload["client_kc"], 64)

    with :ok <- check_commit(server, payload),
         :ok <- check_tag(server, tb),
         :ok <- check_pin(server, payload) do
      {:ok, server}
    end
  end

  def handle(%__MODULE__{} = server, "client/pair-finalize", payload) do
    {:ok, wrapped} = decode(payload["wrapped_psk"], 48)
    wrap_key = Pairing.wrap_key(server.sid, server.isk)

    case Pairing.unwrap_psk(server.suite, wrap_key, wrapped) do
      {:ok, psk} ->
        {:send, [{"server/pair-finalize", %{}}], %{server | psk: psk}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Supply the PIN the operator typed, producing `server/pair-auth`.

  Dynamic-PIN only; the static flow takes its PIN in `start/1`.
  """
  def submit_pin(%__MODULE__{method: :dynamic_pin} = server, pin), do: pair_auth(server, pin)

  @doc "The PSK unwrapped from `client/pair-finalize`, once it has arrived."
  def psk(%__MODULE__{psk: psk}), do: psk

  @doc "This attempt's `nonce_A`."
  def nonce_a(%__MODULE__{nonce_a: nonce_a}), do: nonce_a

  defp pair_auth(server, pin) do
    {:ok, cpace} = CPace.start(:a, prs: pin, ci: "", sid: server.sid, ad: Pairing.server_ad())
    server = %{server | pin: pin, cpace: cpace}
    share = CPace.public_share(cpace)
    {:send, [{"server/pair-auth", %{"pake_msg_1" => b64(share)}}], server}
  end

  defp check_commit(%__MODULE__{method: :static_pin}, payload) do
    refute_key(payload, "nonce_B")
    :ok
  end

  defp check_commit(%__MODULE__{} = server, payload) do
    {:ok, nonce_b} = decode(payload["nonce_B"], 32)

    if Pairing.commit_valid?(nonce_b, server.commit_b),
      do: :ok,
      else: {:error, :commit_mismatch}
  end

  defp check_tag(%__MODULE__{} = server, tb) do
    expected = Pairing.confirmation_tag(server.mac_key, server.peer_share, Pairing.client_ad())
    if :crypto.hash_equals(tb, expected), do: :ok, else: {:error, :pin_mismatch}
  end

  defp check_pin(%__MODULE__{method: :static_pin}, _payload), do: :ok

  defp check_pin(%__MODULE__{} = server, payload) do
    {:ok, nonce_b} = decode(payload["nonce_B"], 32)

    derived =
      Pairing.derive_pin(server.handshake_hash, server.nonce_a, nonce_b, server.pin_length)

    if derived == server.pin, do: :ok, else: {:error, :pin_mismatch}
  end

  defp refute_key(payload, key) do
    false = Map.has_key?(payload, key)
    :ok
  end

  defp decode(value, size) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, <<raw::binary-size(^size)>>} -> {:ok, raw}
      _other -> {:error, :malformed_field}
    end
  end

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)
end
