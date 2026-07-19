defmodule UniversalProxy.UART.ServerTest do
  # async: false because the settings-clearing tests open a DETS-backed
  # SettingsStore on a fixed table atom — DETS table names must be atoms,
  # so serialization keeps the fixed atom safe to reuse (same rationale as
  # SettingsStoreTest/PskStoreTest/ConfigStoreTest).
  use ExUnit.Case, async: false

  alias UniversalProxy.UART.Server
  alias UniversalProxy.UART.SettingsStore

  describe "zwa2_device?/1" do
    test "matches ZWA-2 by VID/PID" do
      info = %{vendor_id: 0x303A, product_id: 0x4001, serial_number: "abc123"}
      assert Server.zwa2_device?(info)
    end

    test "rejects unknown VID/PID" do
      info = %{vendor_id: 0x1234, product_id: 0x5678, serial_number: "unknown"}
      refute Server.zwa2_device?(info)
    end

    test "rejects when vendor_id is missing" do
      info = %{product_id: 0x4001, serial_number: "abc123"}
      refute Server.zwa2_device?(info)
    end

    test "rejects when product_id is missing" do
      info = %{vendor_id: 0x303A, serial_number: "abc123"}
      refute Server.zwa2_device?(info)
    end

    test "rejects when both VID and PID are missing" do
      info = %{serial_number: "abc123", manufacturer: "Nabu Casa", description: "ZWA-2"}
      refute Server.zwa2_device?(info)
    end
  end

  describe "irdroid_device?/1" do
    test "matches IRDroid by integer VID/PID" do
      assert Server.irdroid_device?(%{vendor_id: 0x04D8, product_id: 0xFD08})
      assert Server.irdroid_device?(%{vendor_id: 0x04D8, product_id: 0xF58B})
    end

    test "matches IRDroid by hex-string VID/PID" do
      assert Server.irdroid_device?(%{vendor_id: "0x04D8", product_id: "0xFD08"})
      assert Server.irdroid_device?(%{vendor_id: "0x04d8", product_id: "0xf58b"})
    end

    test "matches IRDroid by bare hex-string VID/PID" do
      assert Server.irdroid_device?(%{vendor_id: "04D8", product_id: "FD08"})
    end

    test "matches IRDroid by decimal-string PID" do
      assert Server.irdroid_device?(%{vendor_id: "1240", product_id: "64776"})
    end

    test "rejects wrong vendor" do
      refute Server.irdroid_device?(%{vendor_id: 0x1234, product_id: 0xFD08})
    end

    test "rejects wrong product" do
      refute Server.irdroid_device?(%{vendor_id: 0x04D8, product_id: 0x0000})
    end

    test "rejects missing keys" do
      refute Server.irdroid_device?(%{serial_number: "abc123"})
    end
  end

  # Exercises the unplug-clear logic directly against a test-local
  # SettingsStore instead of via `handle_info(:check_hotplug, _)` — that
  # handler always fires a real `ESPHome.Supervisor.restart/0` on a
  # serial-set change, which must not run against the app-global
  # supervision tree from a test.
  describe "clear_removed_settings/3" do
    setup do
      path =
        Path.join(
          System.tmp_dir!(),
          "uart_server_settings_test_#{System.unique_integer([:positive])}.dets"
        )

      File.rm(path)

      store =
        start_supervised!(
          {SettingsStore, name: nil, table: :uart_server_test_settings, dets_path: path}
        )

      on_exit(fn -> File.rm(path) end)

      %{store: store}
    end

    @opts [speed: 9600, data_bits: 8, stop_bits: 1, parity: :none, flow_control: :none]

    test "deletes the persisted entry for a removed device's port id", %{store: store} do
      :ok = SettingsStore.put_opts(store, "p_1_1", @opts)

      assert Server.clear_removed_settings(
               MapSet.new(["SERIAL1"]),
               %{"SERIAL1" => "p_1_1"},
               store
             ) == :ok

      assert SettingsStore.get_opts(store, "p_1_1") == nil
    end

    test "a removed serial with no known port id is a no-op", %{store: store} do
      :ok = SettingsStore.put_opts(store, "p_1_1", @opts)

      Server.clear_removed_settings(MapSet.new(["UNKNOWN"]), %{}, store)

      assert SettingsStore.get_opts(store, "p_1_1") == @opts
    end

    test "leaves other ports' settings untouched", %{store: store} do
      :ok = SettingsStore.put_opts(store, "p_1_1", @opts)
      :ok = SettingsStore.put_opts(store, "p_1_2", @opts)

      Server.clear_removed_settings(MapSet.new(["SERIAL1"]), %{"SERIAL1" => "p_1_1"}, store)

      assert SettingsStore.get_opts(store, "p_1_1") == nil
      assert SettingsStore.get_opts(store, "p_1_2") == @opts
    end

    test "a dead/unavailable settings store does not crash the caller" do
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _reason}

      assert Server.clear_removed_settings(
               MapSet.new(["SERIAL1"]),
               %{"SERIAL1" => "p_1_1"},
               dead
             ) == :ok
    end
  end
end
