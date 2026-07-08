defmodule UniversalProxy.SSHAccessTest do
  use ExUnit.Case, async: false

  alias UniversalProxy.SSHAccess

  setup do
    dir = Path.join(System.tmp_dir!(), "ssh_access_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "ssh_access.dets")
    table = :"ssh_access_test_#{System.unique_integer([:positive])}"
    name = :"ssh_access_srv_#{System.unique_integer([:positive])}"

    {:ok, pid} = SSHAccess.start_link(name: name, table: table, dets_path: path)

    on_exit(fn ->
      # The server is linked to the (already-dead) test process, so it may be
      # shutting down concurrently — alive?-then-stop is a TOCTOU race that
      # exits with :shutdown under CI load. Stop unconditionally and swallow
      # the already-dead exit.
      try do
        GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end

      File.rm_rf!(dir)
    end)

    {:ok, name: name, table: table, path: path}
  end

  test "exposes an ed25519 OpenSSH public key", %{name: name} do
    pub = SSHAccess.public_key(name)
    assert String.starts_with?(pub, "ssh-ed25519 ")

    # The line parses as a valid OpenSSH authorized_keys entry.
    assert [{{{:ECPoint, _point}, {:namedCurve, {1, 3, 101, 112}}}, _attrs}] =
             :ssh_file.decode(pub, :auth_keys)
  end

  test "exposes a SHA256 fingerprint matching the public key", %{name: name} do
    fp = SSHAccess.fingerprint(name)
    assert String.starts_with?(fp, "SHA256:")

    [{pub_rec, _}] = :ssh_file.decode(SSHAccess.public_key(name), :auth_keys)
    assert fp == to_string(:ssh.hostkey_fingerprint(:sha256, pub_rec))
  end

  test "exposes an unencrypted OpenSSH private key PEM", %{name: name} do
    priv = SSHAccess.private_key(name)
    assert String.starts_with?(priv, "-----BEGIN OPENSSH PRIVATE KEY-----\n")
    assert String.ends_with?(priv, "-----END OPENSSH PRIVATE KEY-----\n")
  end

  # Tagged so a stripped image without OpenSSH can exclude it
  # (`--exclude ssh_keygen`); when it runs, a missing ssh-keygen fails loudly
  # rather than passing with zero assertions.
  @tag :ssh_keygen
  test "the private key round-trips to the published public key", %{name: name} do
    keygen = System.find_executable("ssh-keygen")
    assert keygen, "ssh-keygen not found — exclude the :ssh_keygen tag on this host"

    tmp = Path.join(System.tmp_dir!(), "ssh_rt_#{System.unique_integer([:positive])}")
    File.write!(tmp, SSHAccess.private_key(name))
    File.chmod!(tmp, 0o600)
    on_exit(fn -> File.rm_rf!(tmp) end)

    {derived, 0} = System.cmd(keygen, ["-y", "-f", tmp])
    # Compare the "<type> <base64-blob>" prefix, ignoring the comment field.
    [type, blob | _] = String.split(SSHAccess.public_key(name), " ")
    assert String.starts_with?(String.trim(derived), "#{type} #{blob}")
  end

  test "persists the keypair across restarts", %{name: name, table: table, path: path} do
    first = %{
      public_key: SSHAccess.public_key(name),
      private_key: SSHAccess.private_key(name),
      fingerprint: SSHAccess.fingerprint(name)
    }

    :ok = GenServer.stop(name)

    name2 = :"ssh_access_srv_#{System.unique_integer([:positive])}"
    {:ok, _pid} = SSHAccess.start_link(name: name2, table: table, dets_path: path)

    assert SSHAccess.public_key(name2) == first.public_key
    assert SSHAccess.private_key(name2) == first.private_key
    assert SSHAccess.fingerprint(name2) == first.fingerprint
  end

  test "generate_keypair/0 produces distinct keys each call" do
    a = SSHAccess.generate_keypair()
    b = SSHAccess.generate_keypair()
    assert a.public_key != b.public_key
    assert a.fingerprint != b.fingerprint
  end
end
