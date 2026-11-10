defmodule UniversalProxy.Sendspin.PairingToken do
  @moduledoc """
  Sendspin pairing-token encoding (`pairing.md` "Pairing Token").

  A token is `"SP:"`, a one-character version, and the payload as RFC 4648
  base32 with the `=` padding stripped and every `2` transliterated to `9`,
  so it stays inside the QR alphanumeric set. Version `0` carries a client's
  identity and pairing PSK, `client_key (32 bytes) || pairing_psk (32
  bytes)`: an operator pastes it into a server to pair over the Pairing PSK
  method.

  The result is a long-lived pairing secret — callers must keep it out of
  logs, PubSub and anything else that is not an explicit operator reveal.
  """

  @prefix "SP:"
  @psk_token_version "0"

  @doc "Encode a version-0 (Pairing PSK) token from the raw client key and pairing PSK."
  @spec encode_psk_token(<<_::256>>, <<_::256>>) :: String.t()
  def encode_psk_token(<<_::256>> = client_key, <<_::256>> = pairing_psk) do
    body =
      (client_key <> pairing_psk)
      |> Base.encode32(padding: false)
      |> String.replace("2", "9")

    @prefix <> @psk_token_version <> body
  end
end
