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
               adapter: nil,
               roles: %{}
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

    test "corrupt field types are sanitized on read, not just on write", %{
      server: server,
      dets_path: path
    } do
      :ok = Settings.set_enabled(server, false)
      stop_supervised!(Settings)

      {:ok, table} = :dets.open_file(@table, file: to_charlist(path), type: :set)

      :ok =
        :dets.insert(
          table,
          {:settings, %{enabled: "yes", active_connections: 1, adapter: "not-a-mac", junk: :x}}
        )

      :ok = :dets.sync(table)
      :ok = :dets.close(table)

      pid = start_supervised!({Settings, name: nil, table: @table, dets_path: path})

      # Every bad field degrades to its default; unknown keys are dropped.
      assert Settings.get(pid) == %{
               enabled: true,
               active_connections: true,
               adapter: nil,
               roles: %{}
             }
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

  describe "roles: migration from legacy records" do
    # Write a raw record with NO :roles key (older firmware), restart, read.
    defp seed_legacy(path, record) do
      {:ok, table} = :dets.open_file(@table, file: to_charlist(path), type: :set)
      :ok = :dets.insert(table, {:settings, record})
      :ok = :dets.sync(table)
      :ok = :dets.close(table)
      start_supervised!({Settings, name: nil, table: @table, dets_path: path})
    end

    test "concrete adapter + enabled synthesizes a :proxy role", %{
      server: server,
      dets_path: path
    } do
      stop_supervised!(Settings)

      pid =
        seed_legacy(path, %{enabled: true, active_connections: true, adapter: "AA:BB:CC:DD:EE:FF"})

      _ = server

      settings = Settings.get(pid)
      assert settings.roles == %{"AA:BB:CC:DD:EE:FF" => :proxy}
      assert Settings.proxy_adapter(settings) == "AA:BB:CC:DD:EE:FF"
    end

    test "concrete adapter + disabled yields no role but proxy_adapter still falls back", %{
      dets_path: path
    } do
      stop_supervised!(Settings)

      pid =
        seed_legacy(path, %{
          enabled: false,
          active_connections: true,
          adapter: "AA:BB:CC:DD:EE:FF"
        })

      settings = Settings.get(pid)
      # :off == absence of a role entry.
      assert settings.roles == %{}
      assert Settings.role(settings, "AA:BB:CC:DD:EE:FF") == :off
      # Legacy behavior preserved: the selected radio is still the proxy target
      # (enabled gates espex wiring separately, not the radio selection).
      assert Settings.proxy_adapter(settings) == "AA:BB:CC:DD:EE:FF"
    end

    test "auto (nil) adapter yields empty roles and auto proxy_adapter", %{dets_path: path} do
      stop_supervised!(Settings)
      pid = seed_legacy(path, %{enabled: true, active_connections: true, adapter: nil})

      settings = Settings.get(pid)
      assert settings.roles == %{}
      assert Settings.proxy_adapter(settings) == nil
    end

    test "a record that already carries roles is not re-migrated", %{dets_path: path} do
      stop_supervised!(Settings)

      pid =
        seed_legacy(path, %{
          enabled: true,
          active_connections: true,
          adapter: "AA:BB:CC:DD:EE:FF",
          roles: %{"11:22:33:44:55:66" => :audio}
        })

      # Existing roles win; the adapter is NOT synthesized into :proxy on top.
      assert Settings.get(pid).roles == %{"11:22:33:44:55:66" => :audio}
    end

    test "a hand-edited record with two :proxy entries keeps only one", %{dets_path: path} do
      stop_supervised!(Settings)

      pid =
        seed_legacy(path, %{
          enabled: true,
          active_connections: true,
          adapter: nil,
          roles: %{"AA:BB:CC:DD:EE:FF" => :proxy, "11:22:33:44:55:66" => :proxy}
        })

      roles = Settings.get(pid).roles
      assert map_size(roles) == 1
      assert Enum.count(roles, fn {_m, r} -> r == :proxy end) == 1
    end
  end

  describe "set_role/3" do
    test "assigns :audio and surfaces it in audio_adapters/1", %{server: server} do
      :ok = Settings.set_role(server, "aa:bb:cc:dd:ee:ff", :audio)
      settings = Settings.get(server)
      assert Settings.role(settings, "AA:BB:CC:DD:EE:FF") == :audio
      assert Settings.audio_adapters(settings) == ["AA:BB:CC:DD:EE:FF"]
    end

    test "assigning :proxy demotes the previous :proxy (single-proxy invariant)", %{
      server: server
    } do
      :ok = Settings.set_role(server, "AA:BB:CC:DD:EE:FF", :proxy)
      :ok = Settings.set_role(server, "11:22:33:44:55:66", :proxy)

      settings = Settings.get(server)
      assert Settings.proxy_adapter(settings) == "11:22:33:44:55:66"
      assert Settings.role(settings, "AA:BB:CC:DD:EE:FF") == :off
      assert Enum.count(settings.roles, fn {_m, r} -> r == :proxy end) == 1
    end

    test ":off removes the entry", %{server: server} do
      :ok = Settings.set_role(server, "AA:BB:CC:DD:EE:FF", :audio)
      :ok = Settings.set_role(server, "AA:BB:CC:DD:EE:FF", :off)
      assert Settings.get(server).roles == %{}
    end

    test "rejects a malformed MAC and an unknown role", %{server: server} do
      assert {:error, :invalid_adapter} = Settings.set_role(server, "nope", :audio)
      assert {:error, :invalid_role} = Settings.set_role(server, "AA:BB:CC:DD:EE:FF", :bogus)
    end

    test "setting the legacy proxy adapter to :audio frees its proxy fallback", %{server: server} do
      # Reproduces the hardware bug: the pre-roles `adapter` selector still
      # named this radio, so giving it :audio left proxy_adapter falling back
      # to it — masking the :audio role and making the toggle snap to Proxy.
      :ok = Settings.set_adapter(server, "AA:BB:CC:DD:EE:FF")
      :ok = Settings.set_role(server, "AA:BB:CC:DD:EE:FF", :audio)

      settings = Settings.get(server)
      assert Settings.audio_adapters(settings) == ["AA:BB:CC:DD:EE:FF"]
      assert Settings.proxy_adapter(settings) == nil
    end
  end

  describe "proxy_adapter/1 legacy-fallback suppression" do
    test "falls back to the legacy adapter when it has no role" do
      assert Settings.proxy_adapter(%{roles: %{}, adapter: "AA:BB:CC:DD:EE:FF"}) ==
               "AA:BB:CC:DD:EE:FF"
    end

    test "suppresses the fallback when the legacy adapter was given :audio" do
      settings = %{roles: %{"AA:BB:CC:DD:EE:FF" => :audio}, adapter: "AA:BB:CC:DD:EE:FF"}
      assert Settings.proxy_adapter(settings) == nil
    end

    test "keeps a legacy proxy when a DIFFERENT radio is set to :audio" do
      settings = %{roles: %{"11:22:33:44:55:66" => :audio}, adapter: "AA:BB:CC:DD:EE:FF"}
      assert Settings.proxy_adapter(settings) == "AA:BB:CC:DD:EE:FF"
    end

    test "an explicit :proxy role always wins over the legacy adapter" do
      settings = %{roles: %{"11:22:33:44:55:66" => :proxy}, adapter: "AA:BB:CC:DD:EE:FF"}
      assert Settings.proxy_adapter(settings) == "11:22:33:44:55:66"
    end
  end
end
