defmodule UniversalProxy.StorageTest do
  # async: false — terminates the application-tree `Storage.Supervisor`
  # and `Storage.Settings` children to exercise façade degradation, and
  # reads the live global `Storage.Server`/`Storage.Settings` for the "up"
  # path. Concurrent tests would race those global names.
  use ExUnit.Case, async: false

  alias UniversalProxy.Storage
  alias UniversalProxy.Storage.Settings

  describe "with the subsystem up (real app supervision)" do
    test "state/0 returns the live default shape (host, nothing attached)" do
      assert Storage.state() == %{
               drives: [],
               mount: nil,
               share: :off,
               share_folder: "/",
               capacity: nil
             }
    end

    test "list_drives/0 mirrors state/0's drives" do
      assert Storage.list_drives() == []
    end

    test "supported?/0 is a plain boolean, never raises" do
      assert is_boolean(Storage.supported?())
    end

    test "topic/0 delegates to Storage.Server.topic/0" do
      assert Storage.topic() == "storage:state"
    end

    test "the folder API reports \"nothing mounted\" rather than guessing (host)" do
      assert Storage.list_folders("/") == {:error, :not_mounted}
      assert Storage.create_folder("/", "backups") == {:error, :not_mounted}

      assert Storage.set_share_folder({"1-1.3", "0bda", "0316"}, "backups") ==
               {:error, :not_mounted}
    end

    test "an escaping path is refused before the mount state is even consulted" do
      assert Storage.list_folders("../..") == {:error, :invalid_path}
      assert Storage.create_folder("..", "x") == {:error, :invalid_path}
    end

    test "an invalid folder name is refused by the name rule" do
      assert Storage.create_folder("/", "a/b") == {:error, :invalid_name}
    end

    test "share_credentials/0 returns the real lazily-generated record" do
      # This calls the app's actual `Storage.Settings` (global name), which
      # generates and persists a password into the host's `_build/`
      # DETS file on first read. Acceptable on host; assert shape only,
      # never log/print the password itself.
      assert %{username: "backup", password: password, provisioned_hash: _, rotated_at: _} =
               Storage.share_credentials()

      assert is_binary(password)
      assert String.length(password) == 24
      # Stable across repeated reads without a rotation.
      assert Storage.share_credentials().password == password
    end

    test "rotate_password/0 replaces the password and pokes convergence" do
      before = Storage.share_credentials()
      rotated = Storage.rotate_password()

      assert %{username: "backup", password: new_password} = rotated
      assert is_binary(new_password)
      assert String.length(new_password) == 24
      assert new_password != before.password
      # provisioned_hash is cleared so Storage.Smbd reprovisions on the
      # next convergence against the live daemon.
      assert rotated.provisioned_hash == nil
      assert Storage.share_credentials().password == new_password
    end
  end

  describe "façade degradation: Storage.Supervisor down" do
    setup do
      :ok =
        Supervisor.terminate_child(UniversalProxy.Supervisor, UniversalProxy.Storage.Supervisor)

      on_exit(fn ->
        Supervisor.restart_child(UniversalProxy.Supervisor, UniversalProxy.Storage.Supervisor)
      end)

      refute Process.whereis(UniversalProxy.Storage.Server)
      :ok
    end

    test "state/0 answers the safe default instead of raising" do
      assert Storage.state() == %{
               drives: [],
               mount: nil,
               share: :off,
               share_folder: "/",
               capacity: nil
             }
    end

    test "list_drives/0 degrades to an empty list" do
      assert Storage.list_drives() == []
    end

    test "set_share_enabled/2 degrades to {:error, :unavailable}" do
      assert Storage.set_share_enabled({"1-1.3", "0bda", "0316"}, true) == {:error, :unavailable}
    end

    test "set_share_folder/2 degrades to {:error, :unavailable}" do
      assert Storage.set_share_folder({"1-1.3", "0bda", "0316"}, "/") ==
               {:error, :unavailable}
    end

    test "list_folders/1 degrades to {:error, :unavailable}" do
      assert Storage.list_folders("/") == {:error, :unavailable}
    end

    test "create_folder/2 degrades to {:error, :unavailable}" do
      assert Storage.create_folder("/", "backups") == {:error, :unavailable}
    end

    test "eject/0 degrades to {:error, :unavailable}" do
      assert Storage.eject() == {:error, :unavailable}
    end

    test "format_drive/2 degrades to {:error, :unavailable} (server not running, not wedged)" do
      assert Storage.format_drive("/dev/sda1", "BACKUP") == {:error, :unavailable}
    end

    test "format_drive/1 defaults the label to USB_BACKUP and still degrades safely" do
      assert Storage.format_drive("/dev/sda1") == {:error, :unavailable}
    end
  end

  describe "façade degradation: Storage.Settings down" do
    setup do
      :ok = Supervisor.terminate_child(UniversalProxy.Supervisor, UniversalProxy.Storage.Settings)

      on_exit(fn ->
        Supervisor.restart_child(UniversalProxy.Supervisor, UniversalProxy.Storage.Settings)
      end)

      refute Process.whereis(UniversalProxy.Storage.Settings)
      :ok
    end

    test "share_credentials/0 returns nil, not the lazily-generated map" do
      assert Storage.share_credentials() == nil
    end

    test "rotate_password/0 degrades to {:error, :unavailable}" do
      assert Storage.rotate_password() == {:error, :unavailable}
    end
  end

  describe "call_server/1 timeout vs. unavailable split (format_drive/2's seam)" do
    test "a wedged call returns {:error, :timeout}, not an exit" do
      # A process that never replies — the shape of a Storage.Server stuck
      # mid-format. Killed in on_exit: a linked process survives the test
      # process's :normal exit and would otherwise leak for the run.
      wedged = spawn_link(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(wedged, :kill) end)

      assert Storage.call_server(fn -> GenServer.call(wedged, :anything, 100) end) ==
               {:error, :timeout}
    end

    test "a server that stops mid-call returns {:error, :unavailable}, not an exit" do
      dying = spawn(fn -> receive(do: (_ -> exit(:some_reason))) end)

      assert Storage.call_server(fn -> GenServer.call(dying, :anything, 1_000) end) ==
               {:error, :unavailable}
    end
  end

  describe "Settings module shape sanity (documents share_credentials/0's contract)" do
    test "the live global Storage.Settings returns the credentials shape directly" do
      assert %{username: "backup", password: password} = Settings.credentials()
      assert String.length(password) == 24
    end
  end
end
