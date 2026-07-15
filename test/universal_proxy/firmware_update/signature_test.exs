defmodule UniversalProxy.FirmwareUpdate.SignatureTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.FirmwareUpdate.Signature

  defp generate_keypair do
    :crypto.generate_key(:eddsa, :ed25519)
  end

  # Mirrors the KMS construction: sign the sha512 digest of the
  # manifest bytes, not the bytes themselves (docs/manifest-format.md).
  defp sign_manifest(manifest_bytes, priv) do
    digest = :crypto.hash(:sha512, manifest_bytes)
    :crypto.sign(:eddsa, :none, digest, [priv, :ed25519])
  end

  describe "happy path" do
    test "accepts a real signature produced by the matching private key" do
      {pub, priv} = generate_keypair()
      manifest = :crypto.strong_rand_bytes(4096)
      sig = sign_manifest(manifest, priv)

      assert :ok = Signature.verify_manifest(manifest, sig, pub)
    end
  end

  describe "tampered manifest" do
    test "returns :invalid_signature when manifest bytes change" do
      {pub, priv} = generate_keypair()
      manifest = :crypto.strong_rand_bytes(1024)
      sig = sign_manifest(manifest, priv)

      tampered = :crypto.strong_rand_bytes(1024)

      assert {:error, :invalid_signature} = Signature.verify_manifest(tampered, sig, pub)
    end

    test "returns :invalid_signature when signature is for a different key" do
      {pub, _priv} = generate_keypair()
      {_other_pub, other_priv} = generate_keypair()
      manifest = :crypto.strong_rand_bytes(1024)
      sig = sign_manifest(manifest, other_priv)

      assert {:error, :invalid_signature} = Signature.verify_manifest(manifest, sig, pub)
    end
  end

  describe "placeholder pubkey" do
    test "all-zero 32-byte pubkey is refused as :missing_public_key" do
      manifest = "anything"
      sig = <<0::size(64 * 8)>>

      assert {:error, :missing_public_key} =
               Signature.verify_manifest(manifest, sig, <<0::size(32 * 8)>>)
    end

    test "nil pubkey is refused as :missing_public_key" do
      assert {:error, :missing_public_key} =
               Signature.verify_manifest("anything", <<0::size(64 * 8)>>, nil)
    end
  end

  describe "input validation" do
    test "returns :invalid_signature_size when sig is not 64 bytes" do
      {pub, _priv} = generate_keypair()

      assert {:error, :invalid_signature_size} =
               Signature.verify_manifest("anything", <<0, 1, 2>>, pub)
    end

    test "non-32-byte pubkey is refused" do
      assert {:error, :missing_public_key} =
               Signature.verify_manifest("anything", <<0::size(64 * 8)>>, <<0, 1, 2>>)
    end
  end
end
