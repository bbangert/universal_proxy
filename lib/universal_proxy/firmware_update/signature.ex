defmodule UniversalProxy.FirmwareUpdate.Signature do
  @moduledoc """
  Detached Ed25519 signature verification using OTP's `:public_key`.

  Library-shape: pure functions, no host dependencies.

  ## Why detached signatures (Variant 3)

  Rather than `fwup --public-key` (which bakes signature material into
  the `.fw` itself), we keep the firmware bytes untouched and ship a
  separate `<name>.fw.sig` produced by AWS KMS in CI. This lets the
  device's verification module use OTP's `:public_key.verify/4`
  directly — no KMS-format-specific decoding needed.

  ## Placeholder pubkey

  A 32-byte all-zero public key is the "no key provisioned yet"
  sentinel. `verify/3` refuses to validate against it, returning
  `{:error, :missing_public_key}` — fails closed instead of silently
  accepting any signature.
  """

  @pubkey_size 32
  @sig_size 64

  @doc """
  Verifies the Ed25519 signature in `sig_path` for the firmware at
  `fw_path` using `pubkey_bin` (32 raw bytes).

  Returns `:ok`, `{:error, :invalid_signature}`, or one of the
  pre-flight errors:

    * `{:error, :missing_public_key}` — `pubkey_bin` is `nil` or the
      32-byte all-zero placeholder.
    * `{:error, {:read_failed, term()}}` — could not read `fw_path` or
      `sig_path` from disk.
    * `{:error, :invalid_signature_size}` — `sig_path` is not 64 bytes.
  """
  @spec verify(Path.t(), Path.t(), binary() | nil) ::
          :ok
          | {:error,
             :missing_public_key
             | :invalid_signature
             | :invalid_signature_size
             | {:read_failed, term()}}
  def verify(_fw_path, _sig_path, nil), do: {:error, :missing_public_key}

  def verify(fw_path, sig_path, pubkey_bin)
      when is_binary(pubkey_bin) and byte_size(pubkey_bin) == @pubkey_size do
    if pubkey_bin == placeholder_pubkey() do
      {:error, :missing_public_key}
    else
      with {:ok, sig} <- read(sig_path),
           :ok <- validate_sig_size(sig),
           {:ok, fw} <- read(fw_path) do
        if :crypto.verify(:eddsa, :none, fw, sig, [pubkey_bin, :ed25519]) do
          :ok
        else
          {:error, :invalid_signature}
        end
      end
    end
  end

  def verify(_fw_path, _sig_path, _pubkey), do: {:error, :missing_public_key}

  defp read(path) do
    case File.read(path) do
      {:ok, bin} -> {:ok, bin}
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  defp validate_sig_size(<<_::binary-size(@sig_size)>>), do: :ok
  defp validate_sig_size(_), do: {:error, :invalid_signature_size}

  defp placeholder_pubkey, do: <<0::size(@pubkey_size * 8)>>
end
