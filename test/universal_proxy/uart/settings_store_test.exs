defmodule UniversalProxy.UART.SettingsStoreTest do
  # Each test gets its own unnamed store backed by a unique temp DETS file
  # (mirrors PskStoreTest's isolation pattern), so this module is safe to
  # run async.
  use ExUnit.Case, async: true

  alias UniversalProxy.UART.SettingsStore

  setup do
    table = :"uart_settings_unit_test_#{System.unique_integer([:positive])}"

    path =
      Path.join(
        System.tmp_dir!(),
        "uart_settings_test_#{System.unique_integer([:positive])}.dets"
      )

    File.rm(path)

    store = start_supervised!({SettingsStore, name: nil, table: table, dets_path: path})
    on_exit(fn -> File.rm(path) end)

    %{store: store, path: path, table: table}
  end

  test "get_opts/2 is nil for an unknown port id", %{store: store} do
    assert SettingsStore.get_opts(store, "p_unknown") == nil
  end

  test "put_opts/3 then get_opts/2 round-trips the line settings", %{store: store} do
    opts = [speed: 115_200, data_bits: 8, stop_bits: 1, parity: :none, flow_control: :none]

    assert SettingsStore.put_opts(store, "p_1_1", opts) == :ok
    assert SettingsStore.get_opts(store, "p_1_1") == opts
  end

  test "only the line-setting keys are stored — friendly_name is stripped", %{store: store} do
    opts = [
      speed: 9600,
      data_bits: 8,
      stop_bits: 1,
      parity: :none,
      flow_control: :none,
      friendly_name: "FTDI FT232RL (1-1.1.2)"
    ]

    :ok = SettingsStore.put_opts(store, "p_1_2", opts)

    assert SettingsStore.get_opts(store, "p_1_2") ==
             [speed: 9600, data_bits: 8, stop_bits: 1, parity: :none, flow_control: :none]
  end

  test "persistence survives a stop/restart against the same path" do
    path =
      Path.join(
        System.tmp_dir!(),
        "uart_settings_persist_#{System.unique_integer([:positive])}.dets"
      )

    File.rm(path)
    tbl = :"uart_settings_persist_test_#{System.unique_integer([:positive])}"
    opts = [speed: 57_600, data_bits: 8, stop_bits: 1, parity: :even, flow_control: :hardware]

    {:ok, store1} = SettingsStore.start_link(name: nil, table: tbl, dets_path: path)
    :ok = SettingsStore.put_opts(store1, "p_2_1", opts)
    :ok = GenServer.stop(store1)

    {:ok, store2} = SettingsStore.start_link(name: nil, table: tbl, dets_path: path)
    assert SettingsStore.get_opts(store2, "p_2_1") == opts
    :ok = GenServer.stop(store2)
    File.rm(path)
  end

  describe "all_opts/1" do
    test "returns an empty map when the store has no records", %{store: store} do
      assert SettingsStore.all_opts(store) == %{}
    end

    test "returns every persisted port's settings keyed by port id", %{store: store} do
      opts_1 = [speed: 115_200, data_bits: 8, stop_bits: 1, parity: :none, flow_control: :none]
      opts_2 = [speed: 9600, data_bits: 7, stop_bits: 2, parity: :even, flow_control: :hardware]

      :ok = SettingsStore.put_opts(store, "p_1_1", opts_1)
      :ok = SettingsStore.put_opts(store, "p_1_2", opts_2)

      assert SettingsStore.all_opts(store) == %{"p_1_1" => opts_1, "p_1_2" => opts_2}
    end
  end
end
