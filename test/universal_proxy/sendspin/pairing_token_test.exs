defmodule UniversalProxy.Sendspin.PairingTokenTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Sendspin.PairingToken

  # `pairing.md` "Pairing PSK Flow": the version-0 reference vector for
  # client_key = 0x00..0x1f and pairing_psk = 0xe0..0xff.
  @spec_vector "SP:0AAAQEAYEAUDAOCAJBIFQYDIOB4IBCEQTCQKRMFYYDENBWHA5DYP6BYPC4PSOLZXH5DU6V97M5XXO74HR6LZ7J5PW674PT6X37T6757Y"

  test "encodes the spec's version-0 reference vector" do
    client_key = :binary.list_to_bin(Enum.to_list(0x00..0x1F))
    pairing_psk = :binary.list_to_bin(Enum.to_list(0xE0..0xFF))

    assert PairingToken.encode_psk_token(client_key, pairing_psk) == @spec_vector
  end

  test "stays inside the QR alphanumeric set, with no padding and no 2s" do
    token =
      PairingToken.encode_psk_token(:crypto.strong_rand_bytes(32), :crypto.strong_rand_bytes(32))

    assert token =~ ~r/\ASP:0[A-Z3-9]+\z/
    assert byte_size(token) == 4 + 103
  end
end
