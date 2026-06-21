defmodule UniversalProxy.ESPHome.ConfigStoreTest do
  # async: false because DETS table names must be atoms; reusing a single
  # constant atom across tests prevents per-test atom-table growth. The
  # GenServer itself is unnamed (name: nil), so the only atom in play is
  # @table below.
  use ExUnit.Case, async: false

  alias UniversalProxy.ESPHome.ConfigStore

  @table :config_store_test

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "config_store_test_#{System.unique_integer([:positive])}.dets"
      )

    on_exit(fn -> File.rm(path) end)

    pid =
      start_supervised!({ConfigStore, name: nil, table: @table, dets_path: path})

    {:ok, server: pid}
  end

  describe "current/1" do
    test "returns defaults when nothing has been persisted", %{server: server} do
      config = ConfigStore.current(server)

      assert config.name == "universal-proxy"
      assert config.friendly_name == "Universal Proxy"
      assert config.port == 6053
      assert config.project_name == "bbangert.universal_proxy"
    end
  end

  describe "put/2 + current/1 roundtrip" do
    test "persists known string fields", %{server: server} do
      :ok = ConfigStore.put(server, name: "kitchen", friendly_name: "Kitchen Proxy")

      config = ConfigStore.current(server)
      assert config.name == "kitchen"
      assert config.friendly_name == "Kitchen Proxy"
      # Untouched defaults remain
      assert config.port == 6053
    end

    test "later put merges, never replaces wholesale", %{server: server} do
      :ok = ConfigStore.put(server, name: "first")
      :ok = ConfigStore.put(server, friendly_name: "Second")

      config = ConfigStore.current(server)
      assert config.name == "first"
      assert config.friendly_name == "Second"
    end
  end

  describe "port coercion" do
    test "binary numeric port is coerced to integer", %{server: server} do
      :ok = ConfigStore.put(server, port: "6054")
      assert ConfigStore.current(server).port == 6054
    end

    test "non-numeric port falls back to default 6053", %{server: server} do
      :ok = ConfigStore.put(server, port: "not-a-number")
      assert ConfigStore.current(server).port == 6053
    end

    test "integer port passes through unchanged", %{server: server} do
      :ok = ConfigStore.put(server, port: 7000)
      assert ConfigStore.current(server).port == 7000
    end

    test "out-of-range integer port is dropped (existing value preserved)", %{server: server} do
      :ok = ConfigStore.put(server, port: 7000)
      :ok = ConfigStore.put(server, port: 70_000)
      assert ConfigStore.current(server).port == 7000
    end

    test "negative integer port is dropped", %{server: server} do
      :ok = ConfigStore.put(server, port: -1)
      assert ConfigStore.current(server).port == 6053
    end

    test "out-of-range numeric string port falls back to default", %{server: server} do
      :ok = ConfigStore.put(server, port: "70000")
      assert ConfigStore.current(server).port == 6053
    end

    test "nil port is dropped (existing value preserved)", %{server: server} do
      :ok = ConfigStore.put(server, port: 7000)
      :ok = ConfigStore.put(server, port: nil)
      assert ConfigStore.current(server).port == 7000
    end
  end

  describe "non-binary value handling" do
    test "nil values are silently dropped (default preserved)", %{server: server} do
      :ok = ConfigStore.put(server, name: nil)
      assert ConfigStore.current(server).name == "universal-proxy"
    end

    test "atom values are coerced to strings", %{server: server} do
      :ok = ConfigStore.put(server, name: :kitchen)
      assert ConfigStore.current(server).name == "kitchen"
    end

    test "unsupported types (tuple/map/list) are dropped, not crashed on", %{server: server} do
      :ok = ConfigStore.put(server, name: {:bad, :tuple})
      :ok = ConfigStore.put(server, friendly_name: %{nope: 1})
      :ok = ConfigStore.put(server, model: [1, 2, 3])

      config = ConfigStore.current(server)
      assert config.name == "universal-proxy"
      assert config.friendly_name == "Universal Proxy"
      assert config.model == "Universal Proxy"
    end
  end

  describe "unknown keys" do
    test "are silently dropped", %{server: server} do
      :ok = ConfigStore.put(server, name: "foo", bogus: "ignored", port: 6053)

      config = ConfigStore.current(server)
      assert config.name == "foo"
      refute Map.has_key?(config, :bogus)
    end
  end

  describe "project_name validation (ESPHome author.project rule)" do
    test "value with a dot is preserved verbatim", %{server: server} do
      :ok = ConfigStore.put(server, project_name: "acme.thermostat")
      assert ConfigStore.current(server).project_name == "acme.thermostat"
    end

    test "empty string is preserved (\"no project\" sentinel)", %{server: server} do
      :ok = ConfigStore.put(server, project_name: "")
      assert ConfigStore.current(server).project_name == ""
    end

    test "value without a dot is stripped to empty (HA discovery would crash)",
         %{server: server} do
      :ok = ConfigStore.put(server, project_name: "bare-name")
      assert ConfigStore.current(server).project_name == ""
    end

    test "leading/trailing whitespace is trimmed", %{server: server} do
      :ok = ConfigStore.put(server, project_name: "  acme.thermostat  ")
      assert ConfigStore.current(server).project_name == "acme.thermostat"
    end
  end

  describe "device_config_opts/1" do
    test "returns the merged map as a keyword list", %{server: server} do
      :ok = ConfigStore.put(server, name: "kw-test")
      opts = ConfigStore.device_config_opts(server)

      assert is_list(opts)
      assert Keyword.fetch!(opts, :name) == "kw-test"
      assert Keyword.fetch!(opts, :port) == 6053
    end
  end

  describe "project_version tracks the firmware version" do
    test "default project_version equals System.firmware_info().version", %{server: server} do
      # So HA's device-card firmware matches the `firmware_version`
      # diagnostic sensor instead of a stale hardcoded value.
      fw = UniversalProxy.System.firmware_info().version
      assert ConfigStore.current(server).project_version == fw
      assert Keyword.fetch!(ConfigStore.device_config_opts(server), :project_version) == fw
    end

    test "an explicit override still wins over the firmware default", %{server: server} do
      :ok = ConfigStore.put(server, project_version: "9.9.9")
      assert ConfigStore.current(server).project_version == "9.9.9"
    end
  end

  describe "webserver_port is a fixed default, not persistable" do
    test "put/2 ignores webserver_port; the default still reaches the opts", %{server: server} do
      :ok = ConfigStore.put(server, webserver_port: "not-a-port")
      assert ConfigStore.current(server).webserver_port == 80
      assert Keyword.fetch!(ConfigStore.device_config_opts(server), :webserver_port) == 80
    end
  end
end
