defmodule UniversalProxy.FirmwareUpdate.UpdaterTest do
  # async: false — subscribes to a global PubSub topic and uses persistent_term
  # keyed by the test pid to bridge the GenServer process to the test pid.
  use ExUnit.Case, async: false

  alias UniversalProxy.FirmwareUpdate.Updater

  @topic "firmware_update:test"

  defmodule StubClient do
    @moduledoc false

    def latest_release(repo, opts) do
      test_pid = :persistent_term.get({__MODULE__, :test_pid})
      send(test_pid, {:client_latest, repo, opts})

      case :persistent_term.get({__MODULE__, :latest}, :unset) do
        :unset -> {:error, :not_set}
        response -> response
      end
    end

    def download_asset(url, dest_path, opts) do
      test_pid = :persistent_term.get({__MODULE__, :test_pid})
      send(test_pid, {:client_download, url, dest_path, opts})

      case :persistent_term.get({__MODULE__, :download}, :unset) do
        :unset ->
          File.mkdir_p!(Path.dirname(dest_path))
          File.write!(dest_path, "stub firmware bytes")
          :ok

        {:write, content, result} ->
          File.mkdir_p!(Path.dirname(dest_path))
          File.write!(dest_path, content)
          result

        result ->
          result
      end
    end
  end

  defmodule StubFwup do
    @moduledoc false

    def apply(fw_path, opts) do
      test_pid = :persistent_term.get({__MODULE__, :test_pid})
      send(test_pid, {:fwup_apply, fw_path, opts})

      case :persistent_term.get({__MODULE__, :result}, :unset) do
        :unset -> :ok
        result -> result
      end
    end
  end

  defmodule StubSignature do
    @moduledoc false

    def verify(_fw_path, _sig_path, _pubkey) do
      test_pid = :persistent_term.get({__MODULE__, :test_pid})
      send(test_pid, :signature_verify_called)

      case :persistent_term.get({__MODULE__, :result}, :unset) do
        :unset -> :ok
        result -> result
      end
    end
  end

  setup do
    test_pid = self()

    :persistent_term.put({StubClient, :test_pid}, test_pid)
    :persistent_term.put({StubFwup, :test_pid}, test_pid)
    :persistent_term.put({StubSignature, :test_pid}, test_pid)

    download_dir =
      Path.join(System.tmp_dir!(), "updater_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(download_dir)

    Phoenix.PubSub.subscribe(UniversalProxy.PubSub, @topic)

    on_exit(fn ->
      Phoenix.PubSub.unsubscribe(UniversalProxy.PubSub, @topic)
      File.rm_rf(download_dir)

      for key <- [:test_pid, :latest, :download, :result] do
        :persistent_term.erase({StubClient, key})
        :persistent_term.erase({StubFwup, key})
        :persistent_term.erase({StubSignature, key})
      end
    end)

    {:ok, download_dir: download_dir}
  end

  defp set_latest(response), do: :persistent_term.put({StubClient, :latest}, response)
  defp set_signature_result(r), do: :persistent_term.put({StubSignature, :result}, r)

  defp start_updater(opts \\ []) do
    # Each updater gets its own dir under System.tmp_dir!() and registers
    # its own cleanup — the previous pattern of `./tmp_updater_*` in cwd
    # was orphaned because the setup's on_exit only cleaned setup's dir.
    dir = Path.join(System.tmp_dir!(), "updater_test_dir_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(dir) end)

    base = [
      name: nil,
      owner_repo: "owner/repo",
      asset_matcher: &simple_matcher/2,
      download_dir: dir,
      pubsub: UniversalProxy.PubSub,
      pubsub_topic: @topic,
      client: StubClient,
      fwup: StubFwup,
      signature: StubSignature,
      public_key: <<1::size(32 * 8)>>
    ]

    start_supervised!({Updater, Keyword.merge(base, opts)})
  end

  defp simple_matcher(_tag, assets) do
    fw = Enum.find(assets, fn a -> String.ends_with?(a.name, ".fw") end)
    sig = Enum.find(assets, fn a -> String.ends_with?(a.name, ".fw.sig") end)
    if fw, do: {:ok, fw, sig}, else: {:error, :no_fw_asset}
  end

  defp build_release(opts \\ []) do
    %{
      tag_name: Keyword.get(opts, :tag, "v1.2.3"),
      name: "release",
      body: "notes",
      published_at: "2026-05-15T12:00:00Z",
      assets:
        Keyword.get(opts, :assets, [
          %{name: "universal_proxy_rpi3.fw", url: "https://example/fw", size: 100},
          %{name: "universal_proxy_rpi3.fw.sig", url: "https://example/sig", size: 64}
        ]),
      etag: "etag-1"
    }
  end

  describe "check/1 happy path" do
    test "idle → checking → idle when a release is returned" do
      set_latest({:ok, build_release()})
      pid = start_updater()

      :ok = Updater.check(pid)

      assert_receive {:fw_update_progress, %{phase: :checking}}, 500
      assert_receive {:fw_update_progress, %{phase: :idle}}, 500

      snap = Updater.state(pid)
      assert snap.phase == :idle
      assert snap.last_release.tag_name == "v1.2.3"
    end

    test "304 not_modified leaves last_release untouched" do
      set_latest({:ok, :not_modified})
      pid = start_updater()

      :ok = Updater.check(pid)

      assert_receive {:fw_update_progress, %{phase: :idle}}, 500
      snap = Updater.state(pid)
      assert snap.last_release == nil
    end

    test "404 transitions to :error" do
      set_latest({:error, :not_found})
      pid = start_updater()

      :ok = Updater.check(pid)

      assert_receive {:fw_update_progress, %{phase: :error, message: msg}}, 500
      assert msg =~ "not_found"
    end
  end

  describe "install_latest/1 without verification" do
    test "downloads → flashes, no :verifying phase, warning fires" do
      set_latest({:ok, build_release()})
      pid = start_updater(verification_required: false)

      :ok = Updater.check(pid)
      assert_receive {:fw_update_progress, %{phase: :idle}}, 500

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          :ok = Updater.install_latest(pid)

          assert_receive {:fw_update_progress, %{phase: :downloading}}, 500
          assert_receive {:fw_update_progress, %{phase: :flashing}}, 500
          assert_receive {:fw_update_progress, %{phase: :idle}}, 500
        end)

      assert log =~ "without signature verification"
      refute_receive {:fw_update_progress, %{phase: :verifying}}, 50
    end

    test "forwards req_options as a list (never nil) to the client" do
      # Regression: opts had no :req_options key, so Map.get/2 returned nil and
      # download_asset received `req_options: nil`, crashing Keyword.merge/2.
      set_latest({:ok, build_release()})
      pid = start_updater(verification_required: false)

      :ok = Updater.check(pid)
      assert_receive {:fw_update_progress, %{phase: :idle}}, 500

      :ok = Updater.install_latest(pid)

      assert_receive {:client_download, _url, _dest, opts}, 500
      assert is_list(Keyword.get(opts, :req_options))
    end

    test "no signature asset still flashes when verification is disabled" do
      release =
        build_release(
          assets: [%{name: "universal_proxy_rpi3.fw", url: "https://example/fw", size: 100}]
        )

      set_latest({:ok, release})
      pid = start_updater(verification_required: false)

      :ok = Updater.check(pid)
      assert_receive {:fw_update_progress, %{phase: :idle}}, 500

      :ok = Updater.install_latest(pid)
      assert_receive {:fw_update_progress, %{phase: :flashing}}, 500
      assert_receive {:fw_update_progress, %{phase: :idle}}, 500
    end
  end

  describe "install_latest/1 with verification" do
    test "downloads → verifies → flashes on happy path" do
      set_latest({:ok, build_release()})
      set_signature_result(:ok)
      pid = start_updater(verification_required: true)

      :ok = Updater.check(pid)
      assert_receive {:fw_update_progress, %{phase: :idle}}, 500

      :ok = Updater.install_latest(pid)

      assert_receive {:fw_update_progress, %{phase: :downloading}}, 500
      assert_receive {:fw_update_progress, %{phase: :verifying}}, 500
      assert_receive {:fw_update_progress, %{phase: :flashing}}, 500
      assert_receive {:fw_update_progress, %{phase: :idle}}, 500
      assert_receive :signature_verify_called, 100
    end

    test "bad signature transitions to :error and never flashes" do
      set_latest({:ok, build_release()})
      set_signature_result({:error, :invalid_signature})
      pid = start_updater(verification_required: true)

      :ok = Updater.check(pid)
      assert_receive {:fw_update_progress, %{phase: :idle}}, 500

      :ok = Updater.install_latest(pid)

      assert_receive {:fw_update_progress, %{phase: :downloading}}, 500
      assert_receive {:fw_update_progress, %{phase: :verifying}}, 500
      assert_receive {:fw_update_progress, %{phase: :error, message: msg}}, 500
      assert msg =~ "invalid_signature"
      refute_receive {:fw_update_progress, %{phase: :flashing}}, 50
    end

    test "missing .fw.sig asset transitions to :error" do
      release =
        build_release(
          assets: [%{name: "universal_proxy_rpi3.fw", url: "https://example/fw", size: 100}]
        )

      set_latest({:ok, release})
      pid = start_updater(verification_required: true)

      :ok = Updater.check(pid)
      assert_receive {:fw_update_progress, %{phase: :idle}}, 500

      :ok = Updater.install_latest(pid)

      assert_receive {:fw_update_progress, %{phase: :error, message: msg}}, 500
      assert msg =~ "missing_signature_asset"
    end
  end

  describe "install_latest/1 error guards" do
    test "returns {:error, :no_release_cached} before check has run" do
      pid = start_updater()
      assert {:error, :no_release_cached} = Updater.install_latest(pid)
    end
  end

  describe "init/1 cleanup" do
    test "scrubs partial files from a prior crashed install", %{download_dir: download_dir} do
      File.write!(Path.join(download_dir, "firmware_pending.fw"), "leftover")
      File.write!(Path.join(download_dir, "firmware_pending.fw.sig"), "leftover")
      File.write!(Path.join(download_dir, "firmware_pending.fw.part"), "leftover")

      _pid = start_updater(download_dir: download_dir)

      refute File.exists?(Path.join(download_dir, "firmware_pending.fw"))
      refute File.exists?(Path.join(download_dir, "firmware_pending.fw.sig"))
      refute File.exists?(Path.join(download_dir, "firmware_pending.fw.part"))
    end
  end

  describe "update_config/2" do
    test "mutating :owner_repo is picked up on next check/1" do
      set_latest({:ok, build_release()})
      pid = start_updater(owner_repo: "first/repo")

      :ok = Updater.check(pid)
      assert_receive {:client_latest, "first/repo", _}, 500
      assert_receive {:fw_update_progress, %{phase: :idle}}, 500

      :ok = Updater.update_config(pid, owner_repo: "second/repo")
      :ok = Updater.check(pid)
      assert_receive {:client_latest, "second/repo", _}, 500
    end

    test "mutating an immutable key returns {:error, :immutable}" do
      pid = start_updater()
      assert {:error, :immutable} = Updater.update_config(pid, pubsub: SomeOther.PubSub)
    end

    test "mutating an unknown key returns {:error, :unknown}" do
      pid = start_updater()
      assert {:error, :unknown} = Updater.update_config(pid, totally_made_up: :nope)
    end
  end
end
