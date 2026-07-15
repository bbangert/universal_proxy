defmodule UniversalProxy.FirmwareUpdate.UpdaterTest do
  # async: false — subscribes to a global PubSub topic and uses persistent_term
  # keyed by the test pid to bridge the GenServer process to the test pid.
  use ExUnit.Case, async: false

  alias UniversalProxy.FirmwareUpdate.Updater

  @topic "firmware_update:test"
  @manifest_asset "release-manifest.json"
  @manifest_sig_asset "release-manifest.sig"

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

      key = Path.basename(dest_path)

      case :persistent_term.get({__MODULE__, {:asset, key}}, :unset) do
        :unset ->
          File.mkdir_p!(Path.dirname(dest_path))
          File.write!(dest_path, "stub bytes: #{key}")
          :ok

        {content, result} ->
          File.mkdir_p!(Path.dirname(dest_path))
          File.write!(dest_path, content)
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

  setup do
    test_pid = self()

    :persistent_term.put({StubClient, :test_pid}, test_pid)
    :persistent_term.put({StubFwup, :test_pid}, test_pid)

    download_dir =
      Path.join(System.tmp_dir!(), "updater_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(download_dir)

    Phoenix.PubSub.subscribe(UniversalProxy.PubSub, @topic)

    on_exit(fn ->
      Phoenix.PubSub.unsubscribe(UniversalProxy.PubSub, @topic)
      File.rm_rf(download_dir)

      for key <- [:test_pid, :latest, :result] do
        :persistent_term.erase({StubClient, key})
        :persistent_term.erase({StubFwup, key})
      end

      for key <- [@manifest_asset, @manifest_sig_asset, "firmware_pending.fw"] do
        :persistent_term.erase({StubClient, {:asset, key}})
      end
    end)

    {:ok, download_dir: download_dir}
  end

  defp set_latest(response), do: :persistent_term.put({StubClient, :latest}, response)

  defp set_asset(basename, content, result \\ :ok) do
    :persistent_term.put({StubClient, {:asset, basename}}, {content, result})
  end

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
      public_key: <<1::size(32 * 8)>>
    ]

    merged = Keyword.merge(base, opts)

    # Explicit unique :id — tests that start more than one updater (e.g.
    # the expiry test's two-pid comparison) would otherwise collide on
    # the default id (the Updater module) under the same test's
    # supervision tree.
    spec = %{id: make_ref(), start: {Updater, :start_link, [merged]}}
    start_supervised!(spec)
  end

  defp simple_matcher(_tag, assets) do
    case Enum.find(assets, fn a -> String.ends_with?(a.name, ".fw") end) do
      nil -> {:error, :no_fw_asset}
      fw -> {:ok, fw}
    end
  end

  defp build_release(opts \\ []) do
    %{
      tag_name: Keyword.get(opts, :tag, "v1.2.3"),
      name: "release",
      body: "notes",
      published_at: "2026-05-15T12:00:00Z",
      assets:
        Keyword.get(opts, :assets, [
          %{name: "universal_proxy_rpi3.fw", url: "https://example/fw", size: 100}
        ]),
      etag: "etag-1"
    }
  end

  # -- Manifest fixtures --
  #
  # Real Ed25519 keypair + real Signature.verify_manifest/3 (no stub) —
  # a round-trip test against real signer output is the point (see
  # docs/manifest-format.md).

  defp generate_keypair, do: :crypto.generate_key(:eddsa, :ed25519)

  defp sign_manifest(manifest_bytes, priv) do
    digest = :crypto.hash(:sha512, manifest_bytes)
    :crypto.sign(:eddsa, :none, digest, [priv, :ed25519])
  end

  defp sha256_hex(bytes),
    do: bytes |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp build_manifest_json(opts \\ []) do
    target = Keyword.get(opts, :target, "rpi3")
    asset_name = Keyword.get(opts, :asset_name, "universal_proxy_#{target}.fw")
    fw_content = Keyword.get(opts, :fw_content, "manifest-path firmware bytes")
    sha256 = Keyword.get(opts, :sha256) || sha256_hex(fw_content)
    size = Keyword.get(opts, :size) || byte_size(fw_content)
    counter = Keyword.get(opts, :counter, 100)
    expires_at = Keyword.get(opts, :expires_at, nil)

    %{
      "version" => 1,
      "counter" => counter,
      "signed_at" => "2026-07-15T12:00:00Z",
      "expires_at" => expires_at,
      "targets" => %{
        target => %{"asset" => asset_name, "sha256" => sha256, "size" => size}
      },
      "deltas" => %{}
    }
    |> JSON.encode!()
  end

  defp build_manifest_release(opts \\ []) do
    fw_name = Keyword.get(opts, :fw_asset_name, "universal_proxy_rpi3.fw")

    fw_asset = %{
      name: fw_name,
      url: "https://example/#{fw_name}",
      browser_download_url: "https://example/#{fw_name}",
      size: 100
    }

    manifest_assets = [
      %{
        name: @manifest_asset,
        url: "https://example/#{@manifest_asset}",
        browser_download_url: "https://example/#{@manifest_asset}",
        size: 10
      },
      %{
        name: @manifest_sig_asset,
        url: "https://example/#{@manifest_sig_asset}",
        browser_download_url: "https://example/#{@manifest_sig_asset}",
        size: 64
      }
    ]

    %{
      tag_name: Keyword.get(opts, :tag, "v1.2.3"),
      name: "release",
      body: "notes",
      published_at: "2026-05-15T12:00:00Z",
      assets: Keyword.get(opts, :assets, manifest_assets ++ [fw_asset]),
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

    test "channel opt is forwarded to client.latest_release" do
      set_latest({:ok, build_release()})
      pid = start_updater(channel: :prerelease)

      :ok = Updater.check(pid)

      assert_receive {:client_latest, "owner/repo", opts}, 500
      assert Keyword.get(opts, :channel) == :prerelease
    end
  end

  describe "install_latest/1 without verification (legacy path)" do
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
  end

  describe "install_latest/1 with manifest verification" do
    test "happy path: :verifying → :downloading → :flashing → :idle, counter persisted, reboot fired" do
      {pub, priv} = generate_keypair()
      fw_content = "real firmware bytes for rpi3"
      manifest_bytes = build_manifest_json(fw_content: fw_content, counter: 500)
      sig_bytes = sign_manifest(manifest_bytes, priv)

      set_asset(@manifest_asset, manifest_bytes)
      set_asset(@manifest_sig_asset, sig_bytes)
      set_asset("firmware_pending.fw", fw_content)

      set_latest({:ok, build_manifest_release()})

      test_pid = self()
      kv_put = fn key, value -> send(test_pid, {:kv_put, key, value}) end
      reboot_fn = fn -> send(test_pid, :rebooted) end

      pid =
        start_updater(
          verification_required: true,
          public_key: pub,
          target_fn: fn -> "rpi3" end,
          kv_put: kv_put,
          reboot_fn: reboot_fn
        )

      :ok = Updater.check(pid)
      assert_receive {:fw_update_progress, %{phase: :idle}}, 500

      :ok = Updater.install_latest(pid)

      assert_receive {:fw_update_progress, %{phase: :verifying}}, 500
      assert_receive {:fw_update_progress, %{phase: :downloading}}, 500
      assert_receive {:fw_update_progress, %{phase: :flashing}}, 500
      assert_receive {:kv_put, "fw_manifest_counter", "500"}, 500
      assert_receive {:fw_update_progress, %{phase: :idle}}, 500
      assert_receive {:fwup_apply, _fw_path, _fwup_opts}, 500
      assert_receive :rebooted, 500
    end

    test "bad signature (signed by the wrong key): error broadcast, no fwup call, no kv_put" do
      {pub, _priv} = generate_keypair()
      {_other_pub, other_priv} = generate_keypair()

      manifest_bytes = build_manifest_json()
      sig_bytes = sign_manifest(manifest_bytes, other_priv)

      set_asset(@manifest_asset, manifest_bytes)
      set_asset(@manifest_sig_asset, sig_bytes)
      set_asset("firmware_pending.fw", "irrelevant")

      set_latest({:ok, build_manifest_release()})

      test_pid = self()
      kv_put = fn key, value -> send(test_pid, {:kv_put, key, value}) end

      pid =
        start_updater(
          verification_required: true,
          public_key: pub,
          target_fn: fn -> "rpi3" end,
          kv_put: kv_put
        )

      :ok = Updater.check(pid)
      assert_receive {:fw_update_progress, %{phase: :idle}}, 500

      :ok = Updater.install_latest(pid)

      assert_receive {:fw_update_progress, %{phase: :verifying}}, 500
      assert_receive {:fw_update_progress, %{phase: :error, message: msg}}, 500
      assert msg =~ "invalid_signature"

      refute_receive {:fwup_apply, _, _}, 100
      refute_receive {:kv_put, _, _}, 100
    end

    test "expired manifest: enforce_expiry false proceeds, true fails with manifest_expired" do
      {pub, priv} = generate_keypair()
      fw_content = "fw bytes"
      past = "2020-01-01T00:00:00Z"

      manifest_bytes = build_manifest_json(fw_content: fw_content, expires_at: past, counter: 10)
      sig_bytes = sign_manifest(manifest_bytes, priv)

      set_asset(@manifest_asset, manifest_bytes)
      set_asset(@manifest_sig_asset, sig_bytes)
      set_asset("firmware_pending.fw", fw_content)
      set_latest({:ok, build_manifest_release()})

      pid_proceeds =
        start_updater(
          verification_required: true,
          public_key: pub,
          target_fn: fn -> "rpi3" end,
          enforce_expiry: false
        )

      :ok = Updater.check(pid_proceeds)
      assert_receive {:fw_update_progress, %{phase: :idle}}, 500
      :ok = Updater.install_latest(pid_proceeds)
      assert_receive {:fw_update_progress, %{phase: :flashing}}, 500
      assert_receive {:fw_update_progress, %{phase: :idle}}, 500

      pid_fails =
        start_updater(
          verification_required: true,
          public_key: pub,
          target_fn: fn -> "rpi3" end,
          enforce_expiry: true
        )

      :ok = Updater.check(pid_fails)
      assert_receive {:fw_update_progress, %{phase: :idle}}, 500
      :ok = Updater.install_latest(pid_fails)
      assert_receive {:fw_update_progress, %{phase: :verifying}}, 500
      assert_receive {:fw_update_progress, %{phase: :error, message: msg}}, 500
      assert msg =~ "manifest_expired"
    end

    test "counter rollback: stored counter higher than manifest's ⇒ fails, fw never downloaded",
         %{download_dir: _unused} do
      {pub, priv} = generate_keypair()
      manifest_bytes = build_manifest_json(counter: 5)
      sig_bytes = sign_manifest(manifest_bytes, priv)

      set_asset(@manifest_asset, manifest_bytes)
      set_asset(@manifest_sig_asset, sig_bytes)
      set_latest({:ok, build_manifest_release()})

      dir =
        Path.join(
          System.tmp_dir!(),
          "updater_test_rollback_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      fw_path = Path.join(dir, "firmware_pending.fw")

      pid =
        start_updater(
          download_dir: dir,
          verification_required: true,
          public_key: pub,
          target_fn: fn -> "rpi3" end,
          kv_get: fn "fw_manifest_counter" -> "10" end
        )

      :ok = Updater.check(pid)
      assert_receive {:fw_update_progress, %{phase: :idle}}, 500
      :ok = Updater.install_latest(pid)

      assert_receive {:fw_update_progress, %{phase: :verifying}}, 500
      assert_receive {:fw_update_progress, %{phase: :error, message: msg}}, 500
      assert msg =~ "manifest_rollback"

      refute_receive {:client_download, _, ^fw_path, _}, 100
    end

    test "sha256 mismatch on the firmware download: error broadcast, no flash, no kv_put" do
      {pub, priv} = generate_keypair()
      manifest_bytes = build_manifest_json(counter: 20)
      sig_bytes = sign_manifest(manifest_bytes, priv)

      set_asset(@manifest_asset, manifest_bytes)
      set_asset(@manifest_sig_asset, sig_bytes)

      set_asset(
        "firmware_pending.fw",
        "irrelevant",
        {:error, {:sha256_mismatch, expected: "aa", actual: "bb"}}
      )

      set_latest({:ok, build_manifest_release()})

      test_pid = self()
      kv_put = fn key, value -> send(test_pid, {:kv_put, key, value}) end

      pid =
        start_updater(
          verification_required: true,
          public_key: pub,
          target_fn: fn -> "rpi3" end,
          kv_put: kv_put
        )

      :ok = Updater.check(pid)
      assert_receive {:fw_update_progress, %{phase: :idle}}, 500
      :ok = Updater.install_latest(pid)

      assert_receive {:fw_update_progress, %{phase: :downloading}}, 500
      assert_receive {:fw_update_progress, %{phase: :error, message: msg}}, 500
      assert msg =~ "sha256_mismatch"

      refute_receive {:fwup_apply, _, _}, 100
      refute_receive {:kv_put, _, _}, 100
    end

    test "missing manifest asset ⇒ :missing_manifest error" do
      release = build_release()
      set_latest({:ok, release})

      pid = start_updater(verification_required: true, target_fn: fn -> "rpi3" end)

      :ok = Updater.check(pid)
      assert_receive {:fw_update_progress, %{phase: :idle}}, 500
      :ok = Updater.install_latest(pid)

      assert_receive {:fw_update_progress, %{phase: :verifying}}, 500
      assert_receive {:fw_update_progress, %{phase: :error, message: msg}}, 500
      assert msg =~ "missing_manifest"
    end
  end

  describe "downgrade gate" do
    test "refuses a downgrade by default (legacy path)" do
      set_latest({:ok, build_release(tag: "v1.0.0")})
      pid = start_updater(verification_required: false, current_version_fn: fn -> "2.0.0" end)

      :ok = Updater.check(pid)
      assert_receive {:fw_update_progress, %{phase: :idle}}, 500
      :ok = Updater.install_latest(pid)

      assert_receive {:fw_update_progress, %{phase: :error, message: msg}}, 500
      assert msg =~ "downgrade_refused"
      refute_receive {:fwup_apply, _, _}, 100
    end

    test "allow_downgrade: true proceeds anyway" do
      set_latest({:ok, build_release(tag: "v1.0.0")})

      pid =
        start_updater(
          verification_required: false,
          current_version_fn: fn -> "2.0.0" end,
          allow_downgrade: true
        )

      :ok = Updater.check(pid)
      assert_receive {:fw_update_progress, %{phase: :idle}}, 500

      ExUnit.CaptureLog.capture_log(fn ->
        :ok = Updater.install_latest(pid)
        assert_receive {:fw_update_progress, %{phase: :flashing}}, 500
        assert_receive {:fw_update_progress, %{phase: :idle}}, 500
      end)
    end
  end

  describe "install_latest/1 error guards" do
    test "returns {:error, :no_release_cached} before check has run" do
      pid = start_updater()
      assert {:error, :no_release_cached} = Updater.install_latest(pid)
    end
  end

  describe "init/1 cleanup" do
    test "scrubs partial and manifest/sig files from a prior crashed install", %{
      download_dir: download_dir
    } do
      File.write!(Path.join(download_dir, "firmware_pending.fw"), "leftover")
      File.write!(Path.join(download_dir, "firmware_pending.fw.sig"), "leftover")
      File.write!(Path.join(download_dir, "firmware_pending.fw.part"), "leftover")
      File.write!(Path.join(download_dir, @manifest_asset), "leftover")
      File.write!(Path.join(download_dir, @manifest_sig_asset), "leftover")

      _pid = start_updater(download_dir: download_dir)

      refute File.exists?(Path.join(download_dir, "firmware_pending.fw"))
      refute File.exists?(Path.join(download_dir, "firmware_pending.fw.sig"))
      refute File.exists?(Path.join(download_dir, "firmware_pending.fw.part"))
      refute File.exists?(Path.join(download_dir, @manifest_asset))
      refute File.exists?(Path.join(download_dir, @manifest_sig_asset))
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
