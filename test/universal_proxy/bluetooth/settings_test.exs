defmodule UniversalProxy.Bluetooth.SettingsTest do
  # async: false because DETS table names must be atoms; reusing a single
  # constant atom across tests prevents per-test atom-table growth. The
  # GenServer itself is unnamed (name: nil) so multiple tests can run
  # against the same atom table sequentially without clashing.
  use ExUnit.Case, async: false

  alias UniversalProxy.Bluetooth.Settings

  @table :bluetooth_settings_test

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "bluetooth_settings_test_#{System.unique_integer([:positive])}.dets"
      )

    on_exit(fn -> File.rm(path) end)

    pid = start_supervised!({Settings, name: nil, table: @table, dets_path: path})

    {:ok, server: pid, dets_path: path}
  end

  describe "defaults" do
    test "a fresh store reads back the defaults", %{server: server} do
      assert Settings.get(server) == %{
               enabled: true,
               active_connections: true,
               adapter: nil
             }
    end

    test "defaults/0 matches the fresh-store read", %{server: server} do
      assert Settings.defaults() == Settings.get(server)
    end
  end

  describe "setters" do
    test "set_enabled persists an explicit false", %{server: server} do
      :ok = Settings.set_enabled(server, false)
      assert %{enabled: false} = Settings.get(server)

      :ok = Settings.set_enabled(server, true)
      assert %{enabled: true} = Settings.get(server)
    end

    test "set_active_connections persists independently of enabled", %{server: server} do
      :ok = Settings.set_active_connections(server, false)

      assert %{enabled: true, active_connections: false} = Settings.get(server)
    end

    test "set_adapter stores a MAC and normalizes case", %{server: server} do
      :ok = Settings.set_adapter(server, "aa:bb:cc:dd:ee:ff")
      assert %{adapter: "AA:BB:CC:DD:EE:FF"} = Settings.get(server)
    end

    test "set_adapter nil returns to auto", %{server: server} do
      :ok = Settings.set_adapter(server, "AA:BB:CC:DD:EE:FF")
      :ok = Settings.set_adapter(server, nil)
      assert %{adapter: nil} = Settings.get(server)
    end

    test "set_adapter rejects malformed values", %{server: server} do
      for bad <- ["hci0", "AA:BB:CC:DD:EE", "AA-BB-CC-DD-EE-FF", "", 42, :auto] do
        assert Settings.set_adapter(server, bad) == {:error, :invalid_adapter},
               "expected rejection for #{inspect(bad)}"
      end

      assert %{adapter: nil} = Settings.get(server)
    end

    test "set_enabled rejects non-booleans by guard" do
      assert_raise FunctionClauseError, fn -> Settings.set_enabled(self(), "true") end
    end
  end

  describe "persistence" do
    test "settings survive a store restart", %{server: server, dets_path: path} do
      :ok = Settings.set_enabled(server, false)
      :ok = Settings.set_adapter(server, "AA:BB:CC:DD:EE:FF")

      stop_supervised!(Settings)

      pid = start_supervised!({Settings, name: nil, table: @table, dets_path: path})

      assert %{enabled: false, active_connections: true, adapter: "AA:BB:CC:DD:EE:FF"} =
               Settings.get(pid)
    end

    test "a stored record missing newer fields reads back with defaults", %{
      server: server,
      dets_path: path
    } do
      # Simulate an older firmware's record: only `enabled` was persisted.
      :ok = Settings.set_enabled(server, false)
      stop_supervised!(Settings)

      {:ok, table} = :dets.open_file(@table, file: to_charlist(path), type: :set)
      :ok = :dets.insert(table, {:settings, %{enabled: false}})
      :ok = :dets.sync(table)
      :ok = :dets.close(table)

      pid = start_supervised!({Settings, name: nil, table: @table, dets_path: path})

      assert %{enabled: false, active_connections: true, adapter: nil} = Settings.get(pid)
    end
  end
end
