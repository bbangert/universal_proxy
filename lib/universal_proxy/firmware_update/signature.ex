defmodule UniversalProxy.FirmwareUpdate.Signature do
  @moduledoc """
  Ed25519 signature verification for release manifests, using
  `:crypto.verify/5`.

  Library-shape: pure functions, no host dependencies, no file I/O.

  ## Why :crypto.verify, not :public_key.verify

  We verify with `:crypto.verify(:eddsa, :none, msg, sig, [pubkey,
  :ed25519])` rather than the higher-level `:public_key.verify/4` —
  on OTP 28, `:public_key.verify` with the `{:ed_pub, :ed25519, bin}`
  3-tuple raises `ArgumentError`, and the surrounding `:public_key`
  API expects ASN.1-encoded records that don't round-trip cleanly
  with the raw 32-byte key bytes we extract from KMS. `:crypto.verify`
  is what `:public_key` ultimately delegates to for EdDSA and accepts
  the raw key bytes directly. The wire format matches KMS's
  `ED25519_SHA_512` output byte-for-byte.

  ## Placeholder pubkey

  A 32-byte all-zero public key is the "no key provisioned yet"
  sentinel. `verify_manifest/3` refuses to validate against it,
  returning `{:error, :missing_public_key}` — fails closed instead of
  silently accepting any signature.

  ## Manifest signature scheme

  One KMS-signed `release-manifest.json` per GitHub release replaces
  the never-shipped per-asset `.fw.sig` scheme (see
  `docs/manifest-format.md`). The signed message is **not** the raw
  manifest bytes — it's `sha512(manifest_bytes)`, because AWS KMS caps
  RAW messages at 4,096 bytes and a manifest can exceed that. Signing
  the digest makes signature size independent of manifest size:

      # CI (signing):
      sha512sum release-manifest.json | cut -d' ' -f1 | xxd -r -p > digest.bin
      aws kms sign --key-id "$KMS_KEY_ID" \\
        --message fileb://digest.bin --message-type RAW \\
        --signing-algorithm ED25519_SHA_512 \\
        --output text --query Signature | base64 -d > release-manifest.sig

  The device must use the identical construction — KMS with
  `ED25519_SHA_512`/RAW performs pure Ed25519 over the message we
  provide (our digest); verifying over the raw manifest bytes instead
  would never match.
  """

  @pubkey_size 32
  @sig_size 64

  @doc """
  Verifies `sig` (raw 64 bytes) over `manifest_bytes` using
  `pubkey_bin` (32 raw bytes).

  The signed message is `sha512(manifest_bytes)` — see moduledoc.

  Returns `:ok`, `{:error, :invalid_signature}`, or one of the
  pre-flight errors:

    * `{:error, :missing_public_key}` — `pubkey_bin` is `nil`, not
      32 bytes, or the all-zero placeholder.
    * `{:error, :invalid_signature_size}` — `sig` is not 64 bytes.
  """
  @spec verify_manifest(binary(), binary(), binary() | nil) ::
          :ok | {:error, :missing_public_key | :invalid_signature | :invalid_signature_size}
  def verify_manifest(_manifest_bytes, _sig, nil), do: {:error, :missing_public_key}

  def verify_manifest(manifest_bytes, sig, pubkey_bin)
      when is_binary(pubkey_bin) and byte_size(pubkey_bin) == @pubkey_size do
    if pubkey_bin == placeholder_pubkey() do
      {:error, :missing_public_key}
    else
      with :ok <- validate_sig_size(sig) do
        digest = :crypto.hash(:sha512, manifest_bytes)

        if :crypto.verify(:eddsa, :none, digest, sig, [pubkey_bin, :ed25519]) do
          :ok
        else
          {:error, :invalid_signature}
        end
      end
    end
  end

  def verify_manifest(_manifest_bytes, _sig, _pubkey), do: {:error, :missing_public_key}

  defp validate_sig_size(<<_::binary-size(@sig_size)>>), do: :ok
  defp validate_sig_size(_), do: {:error, :invalid_signature_size}

  defp placeholder_pubkey, do: <<0::size(@pubkey_size * 8)>>
end
