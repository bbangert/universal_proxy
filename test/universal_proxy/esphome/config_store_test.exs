defmodule UniversalProxy.ESPHome.ConfigStoreTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.ESPHome.ConfigStore

  setup do
    table = :"config_store_test_#{System.unique_integer([:positive])}"
    path = Path.join(System.tmp_dir!(), "#{table}.dets")
    on_exit(fn -> File.rm(path) end)

    pid =
      start_supervised!({ConfigStore, name: table, table: table, dets_path: path})

    {:ok, server: pid, table: table}
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
end
