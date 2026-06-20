defmodule UniversalProxy.ESPHome.PskStoreTest do
  # async: false — these tests subscribe to the global "esphome:psk" PubSub
  # topic and touch the app-started store, so they must not run concurrently
  # with other global-state tests. Serialized, a fixed table atom is safe
  # (no per-test dynamic atoms to leak); isolation comes from the unique file.
  use ExUnit.Case, async: false

  alias UniversalProxy.ESPHome.PskStore

  # Each test gets its own unnamed store backed by a unique temp DETS file.
  # The behaviour callback store_psk/1 (hardwired to the named __MODULE__
  # server) is exercised against the global store in security_live_test's
  # auto-upgrade flip test; here we drive the underlying {:store, psk} server
  # path directly.
  setup context do
    table = :esphome_psk_unit_test
    path = Path.join(System.tmp_dir!(), "esphome_psk_test_#{:erlang.phash2(context.test)}.dets")
    File.rm(path)

    store = start_supervised!({PskStore, name: nil, table: table, dets_path: path})
    on_exit(fn -> File.rm(path) end)

    %{store: store, path: path}
  end

  test "load_psk/1 is nil on a fresh store", %{store: store} do
    assert PskStore.load_psk(store) == nil
  end

  test "persists a 32-byte key, returns :ok, and load_psk/1 reads the raw bytes", %{store: store} do
    key = :crypto.strong_rand_bytes(32)
    assert GenServer.call(store, {:store, key}) == :ok
    assert PskStore.load_psk(store) == key
  end

  test "clear/1 returns the store to nil", %{store: store} do
    key = :crypto.strong_rand_bytes(32)
    :ok = GenServer.call(store, {:store, key})
    assert PskStore.load_psk(store) == key

    assert PskStore.clear(store) == :ok
    assert PskStore.load_psk(store) == nil
  end

  test "subscribers get {:esphome_psk, key} on store and {:esphome_psk, nil} on clear",
       %{store: store} do
    Phoenix.PubSub.subscribe(UniversalProxy.PubSub, PskStore.topic())

    key = :crypto.strong_rand_bytes(32)
    :ok = GenServer.call(store, {:store, key})
    assert_receive {:esphome_psk, ^key}

    :ok = PskStore.clear(store)
    assert_receive {:esphome_psk, nil}
  end

  test "persistence survives a stop/restart against the same path" do
    path =
      Path.join(
        System.tmp_dir!(),
        "esphome_psk_persist_#{System.unique_integer([:positive])}.dets"
      )

    File.rm(path)
    tbl = :esphome_psk_persist_test

    {:ok, store1} = PskStore.start_link(name: nil, table: tbl, dets_path: path)
    key = :crypto.strong_rand_bytes(32)
    :ok = GenServer.call(store1, {:store, key})
    :ok = GenServer.stop(store1)

    {:ok, store2} = PskStore.start_link(name: nil, table: tbl, dets_path: path)
    assert PskStore.load_psk(store2) == key
    :ok = GenServer.stop(store2)
    File.rm(path)
  end
end
