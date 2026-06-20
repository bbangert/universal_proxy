defmodule UniversalProxy.ESPHome.PskStoreTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.ESPHome.PskStore

  # Each test gets its own unnamed store backed by a unique temp DETS file and
  # a unique table atom, so they don't collide with each other or the
  # app-started global PskStore. The behaviour callback store_psk/1 (which is
  # hardwired to the named __MODULE__ server) is exercised against the global
  # store in security_live_test's auto-upgrade flip test; here we drive the
  # underlying {:store, psk} server path directly.
  setup context do
    table = :erlang.binary_to_atom("esphome_psk_test_#{:erlang.phash2(context.test)}", :utf8)
    path = Path.join(System.tmp_dir!(), "#{table}.dets")
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
    tbl = :erlang.binary_to_atom("persist_#{System.unique_integer([:positive])}", :utf8)

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
