defmodule UniversalProxy.Storage.SettingsTest do
  # async: false because DETS table names must be atoms; a unique atom per
  # test avoids clashing with concurrently-run test suites, following
  # UniversalProxy.Audio.StoreTest's convention.
  use ExUnit.Case, async: false

  import Bitwise
  import ExUnit.CaptureLog

  alias UniversalProxy.Storage.Settings

  @moduletag :tmp_dir

  @key {"Backup Drive", "1d6b", "0104"}

  setup %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "storage_settings_#{System.unique_integer([:positive])}.dets")
    table = :"storage_settings_test_#{System.unique_integer([:positive])}"

    pid = start_supervised!({Settings, name: nil, table: table, dets_path: path})

    {:ok, server: pid, table: table, path: path}
  end

  describe "get_drive/2" do
    test "unknown key returns defaults", %{server: server} do
      assert Settings.get_drive(server, @key) == %{
               share_enabled?: false,
               share_folder: "/",
               friendly_name: nil,
               last_seen_at: nil
             }
    end

    test "a record stored before share_folder existed reads back the default", %{
      server: server,
      table: table
    } do
      # The pre-share_folder shape, written straight into DETS: this is what
      # an upgraded device has on disk.
      :ok = :dets.insert(table, {@key, %{share_enabled?: true, friendly_name: "Old"}})

      assert Settings.get_drive(server, @key) == %{
               share_enabled?: true,
               share_folder: "/",
               friendly_name: "Old",
               last_seen_at: nil
             }
    end
  end

  describe "put_drive/3" do
    test "merges a partial update onto defaults", %{server: server} do
      :ok = Settings.put_drive(server, @key, %{share_enabled?: true})

      assert Settings.get_drive(server, @key) == %{
               share_enabled?: true,
               share_folder: "/",
               friendly_name: nil,
               last_seen_at: nil
             }
    end

    test "share_folder round-trips and leaves the other fields alone", %{server: server} do
      :ok = Settings.put_drive(server, @key, %{share_enabled?: true})
      :ok = Settings.put_drive(server, @key, %{share_folder: "backups/ha"})

      assert Settings.get_drive(server, @key) == %{
               share_enabled?: true,
               share_folder: "backups/ha",
               friendly_name: nil,
               last_seen_at: nil
             }
    end

    test "merges a second partial update onto the first, preserving untouched fields", %{
      server: server
    } do
      :ok = Settings.put_drive(server, @key, %{share_enabled?: true, friendly_name: "Backup"})
      :ok = Settings.put_drive(server, @key, %{last_seen_at: 1_000})

      assert Settings.get_drive(server, @key) == %{
               share_enabled?: true,
               share_folder: "/",
               friendly_name: "Backup",
               last_seen_at: 1_000
             }
    end

    test "an explicit false does not get overwritten by defaults", %{server: server} do
      :ok = Settings.put_drive(server, @key, %{share_enabled?: true})
      :ok = Settings.put_drive(server, @key, %{share_enabled?: false})

      assert Settings.share_enabled?(server, @key) == false
    end
  end

  describe "share_enabled?/2" do
    test "reflects the stored value", %{server: server} do
      refute Settings.share_enabled?(server, @key)
      :ok = Settings.put_drive(server, @key, %{share_enabled?: true})
      assert Settings.share_enabled?(server, @key)
    end
  end

  describe "credentials/1 — lazy password generation" do
    test "generates a password on first read", %{server: server} do
      creds = Settings.credentials(server)

      assert creds.username == "backup"
      assert is_binary(creds.password)
      assert String.length(creds.password) == 24
      assert creds.provisioned_hash == nil
      assert creds.rotated_at == nil
    end

    test "the same password is returned on subsequent reads", %{server: server} do
      first = Settings.credentials(server)
      second = Settings.credentials(server)
      third = Settings.credentials(server)

      assert first.password == second.password
      assert second.password == third.password
    end

    test "the password survives a process restart", %{server: server, table: table, path: path} do
      first = Settings.credentials(server)

      # DETS treats opening an already-open atom as a no-op returning the
      # existing handle, so the setup-owned process must be stopped first —
      # otherwise this would only exercise in-memory shared state instead of
      # disk persistence (see Audio.StoreTest's restart test for the same
      # caveat).
      :ok = stop_supervised(Settings)

      reopened =
        start_supervised!({Settings, name: nil, table: table, dets_path: path}, id: :second)

      second = Settings.credentials(reopened)

      assert first.password == second.password
      assert first.username == second.username
    end
  end

  describe "rotate_password/1" do
    test "replaces the password, clears provisioned_hash, and stamps rotated_at", %{
      server: server
    } do
      original = Settings.credentials(server)
      :ok = Settings.put_provisioned_hash(server, "deadbeef")

      rotated = Settings.rotate_password(server)

      assert rotated.password != original.password
      assert rotated.provisioned_hash == nil
      assert is_integer(rotated.rotated_at)
      assert rotated.rotated_at > 0

      # The rotation is persisted — a later read sees the same rotated value.
      assert Settings.credentials(server).password == rotated.password
    end
  end

  describe "put_provisioned_hash/2" do
    test "round-trips via credentials/1", %{server: server} do
      _ = Settings.credentials(server)
      :ok = Settings.put_provisioned_hash(server, "abc123")

      assert Settings.credentials(server).provisioned_hash == "abc123"
    end
  end

  describe "file permissions" do
    test "the DETS file is created with mode 0600", %{path: path} do
      # setup already opened the store, which creates the file.
      assert File.exists?(path)
      stat = File.stat!(path)
      assert (stat.mode &&& 0o777) == 0o600
    end
  end

  describe "secret hygiene" do
    test "credentials/1 does not log the generated password", %{server: server} do
      log = capture_log(fn -> Settings.credentials(server) end)
      creds = Settings.credentials(server)

      refute log =~ creds.password
    end

    test "rotate_password/1 does not log the new password", %{server: server} do
      _ = Settings.credentials(server)

      log = capture_log(fn -> Settings.rotate_password(server) end)
      rotated = Settings.credentials(server)

      refute log =~ rotated.password
    end
  end
end
