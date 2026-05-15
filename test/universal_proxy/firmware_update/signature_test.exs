defmodule UniversalProxy.FirmwareUpdate.SignatureTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.FirmwareUpdate.Signature

  setup do
    tmp = System.tmp_dir!()
    unique = System.unique_integer([:positive])
    fw_path = Path.join(tmp, "sig_test_#{unique}.fw")
    sig_path = Path.join(tmp, "sig_test_#{unique}.fw.sig")

    on_exit(fn ->
      File.rm(fw_path)
      File.rm(sig_path)
    end)

    {:ok, fw_path: fw_path, sig_path: sig_path}
  end

  defp generate_keypair do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    {pub, priv}
  end

  defp sign(blob, priv) do
    :crypto.sign(:eddsa, :none, blob, [priv, :ed25519])
  end

  describe "happy path" do
    test "accepts a real signature produced by the matching private key", %{
      fw_path: fw_path,
      sig_path: sig_path
    } do
      {pub, priv} = generate_keypair()
      blob = :crypto.strong_rand_bytes(4096)
      File.write!(fw_path, blob)
      File.write!(sig_path, sign(blob, priv))

      assert :ok = Signature.verify(fw_path, sig_path, pub)
    end
  end

  describe "tampered firmware" do
    test "returns :invalid_signature when firmware bytes change", %{
      fw_path: fw_path,
      sig_path: sig_path
    } do
      {pub, priv} = generate_keypair()
      blob = :crypto.strong_rand_bytes(1024)
      File.write!(fw_path, blob)
      File.write!(sig_path, sign(blob, priv))

      File.write!(fw_path, :crypto.strong_rand_bytes(1024))

      assert {:error, :invalid_signature} = Signature.verify(fw_path, sig_path, pub)
    end

    test "returns :invalid_signature when signature is for a different key", %{
      fw_path: fw_path,
      sig_path: sig_path
    } do
      {pub, _priv} = generate_keypair()
      {_other_pub, other_priv} = generate_keypair()
      blob = :crypto.strong_rand_bytes(1024)
      File.write!(fw_path, blob)
      File.write!(sig_path, sign(blob, other_priv))

      assert {:error, :invalid_signature} = Signature.verify(fw_path, sig_path, pub)
    end
  end

  describe "placeholder pubkey" do
    test "all-zero 32-byte pubkey is refused as :missing_public_key", %{
      fw_path: fw_path,
      sig_path: sig_path
    } do
      File.write!(fw_path, "anything")
      File.write!(sig_path, <<0::size(64 * 8)>>)

      assert {:error, :missing_public_key} =
               Signature.verify(fw_path, sig_path, <<0::size(32 * 8)>>)
    end

    test "nil pubkey is refused as :missing_public_key", %{
      fw_path: fw_path,
      sig_path: sig_path
    } do
      assert {:error, :missing_public_key} = Signature.verify(fw_path, sig_path, nil)
    end
  end

  describe "input validation" do
    test "returns :invalid_signature_size when .fw.sig is not 64 bytes", %{
      fw_path: fw_path,
      sig_path: sig_path
    } do
      {pub, _priv} = generate_keypair()
      File.write!(fw_path, "anything")
      File.write!(sig_path, <<0, 1, 2>>)

      assert {:error, :invalid_signature_size} = Signature.verify(fw_path, sig_path, pub)
    end

    test "returns :read_failed when firmware file is missing", %{sig_path: sig_path} do
      {pub, _priv} = generate_keypair()
      File.write!(sig_path, <<0::size(64 * 8)>>)

      assert {:error, {:read_failed, :enoent}} =
               Signature.verify("/nonexistent/firmware.fw", sig_path, pub)
    end

    test "returns :read_failed when signature file is missing", %{fw_path: fw_path} do
      {pub, _priv} = generate_keypair()
      File.write!(fw_path, "anything")

      assert {:error, {:read_failed, :enoent}} =
               Signature.verify(fw_path, "/nonexistent/firmware.fw.sig", pub)
    end

    test "non-32-byte pubkey is refused", %{fw_path: fw_path, sig_path: sig_path} do
      assert {:error, :missing_public_key} =
               Signature.verify(fw_path, sig_path, <<0, 1, 2>>)
    end
  end
end
