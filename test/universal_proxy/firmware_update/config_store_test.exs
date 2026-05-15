defmodule UniversalProxy.FirmwareUpdate.ConfigStoreTest do
  # async: false — DETS table names are atoms; reusing a single constant
  # atom across tests prevents per-test atom-table growth.
  use ExUnit.Case, async: false

  alias UniversalProxy.FirmwareUpdate.ConfigStore

  @table :firmware_update_config_test

  setup do
    unique = System.unique_integer([:positive])

    dets_path = Path.join(System.tmp_dir!(), "firmware_update_config_#{unique}.dets")
    pubkey_path = Path.join(System.tmp_dir!(), "firmware_signing_#{unique}.pub")

    on_exit(fn ->
      File.rm(dets_path)
      File.rm(pubkey_path)
    end)

    pid =
      start_supervised!(
        {ConfigStore, name: nil, table: @table, dets_path: dets_path, pubkey_path: pubkey_path}
      )

    {:ok, server: pid, pubkey_path: pubkey_path}
  end

  describe "defaults" do
    test "returns documented v1 defaults when nothing has been persisted", %{server: server} do
      assert ConfigStore.get_repo(server) == "bbangert/universal_proxy"
      assert ConfigStore.get_token(server) == nil
      refute ConfigStore.verification_required?(server)
    end
  end

  describe "put/2 persistence" do
    test "repo override is round-tripped", %{server: server} do
      assert :ok = ConfigStore.put(server, repo: "myfork/proxy")
      assert ConfigStore.get_repo(server) == "myfork/proxy"
    end

    test "github_token override is round-tripped", %{server: server} do
      assert :ok = ConfigStore.put(server, github_token: "ghp_secret")
      assert ConfigStore.get_token(server) == "ghp_secret"
    end

    test "verification_required toggle is round-tripped", %{server: server} do
      assert :ok = ConfigStore.put(server, verification_required: true)
      assert ConfigStore.verification_required?(server)

      assert :ok = ConfigStore.put(server, verification_required: false)
      refute ConfigStore.verification_required?(server)
    end

    test "later put merges, never replaces wholesale", %{server: server} do
      :ok = ConfigStore.put(server, repo: "first/repo")
      :ok = ConfigStore.put(server, github_token: "tok")

      assert ConfigStore.get_repo(server) == "first/repo"
      assert ConfigStore.get_token(server) == "tok"
    end

    test "unknown keys are silently dropped", %{server: server} do
      assert :ok = ConfigStore.put(server, repo: "ok/repo", bogus: "ignored")
      assert ConfigStore.get_repo(server) == "ok/repo"
    end

    test "empty string repo is dropped (default preserved)", %{server: server} do
      :ok = ConfigStore.put(server, repo: "")
      assert ConfigStore.get_repo(server) == "bbangert/universal_proxy"
    end

    test "non-boolean verification_required is dropped", %{server: server} do
      :ok = ConfigStore.put(server, verification_required: "true")
      refute ConfigStore.verification_required?(server)
    end
  end

  describe "get_public_key/1" do
    test "returns nil when override unset and pubkey file is absent", %{server: server} do
      assert ConfigStore.get_public_key(server) == nil
    end

    test "reads 32 bytes from pubkey_path when override is unset", %{
      server: server,
      pubkey_path: pubkey_path
    } do
      key = :crypto.strong_rand_bytes(32)
      File.write!(pubkey_path, key)

      assert ConfigStore.get_public_key(server) == key
    end

    test "returns nil when pubkey file is wrong size", %{
      server: server,
      pubkey_path: pubkey_path
    } do
      File.write!(pubkey_path, :crypto.strong_rand_bytes(31))
      assert ConfigStore.get_public_key(server) == nil
    end

    test "override takes precedence over on-disk file", %{
      server: server,
      pubkey_path: pubkey_path
    } do
      file_key = :crypto.strong_rand_bytes(32)
      override_key = :crypto.strong_rand_bytes(32)
      File.write!(pubkey_path, file_key)

      :ok = ConfigStore.put(server, public_key: override_key)

      assert ConfigStore.get_public_key(server) == override_key
    end

    test "wrong-sized override is rejected by put/2 (skipped)", %{server: server} do
      assert :ok = ConfigStore.put(server, public_key: <<0::8>>)
      assert ConfigStore.get_public_key(server) == nil
    end
  end

  describe "snapshot/1" do
    test "merges defaults + overrides + on-disk pubkey fallback", %{
      server: server,
      pubkey_path: pubkey_path
    } do
      key = :crypto.strong_rand_bytes(32)
      File.write!(pubkey_path, key)
      :ok = ConfigStore.put(server, repo: "snap/repo", verification_required: true)

      snap = ConfigStore.snapshot(server)

      assert snap.repo == "snap/repo"
      assert snap.github_token == nil
      assert snap.public_key == key
      assert snap.verification_required == true
    end
  end
end
