defmodule UniversalProxy.FMA120.StoreTest do
  # async: false — DETS table names must be atoms; reuse one constant atom
  # across tests (the GenServer itself is unnamed) to avoid atom-table growth.
  use ExUnit.Case, async: false

  alias UniversalProxy.FMA120.Store

  @table :fma120_store_test
  @key {"1-1.3", 0x0A12, 0x4007}

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "fma120_store_test_#{System.unique_integer([:positive])}.dets"
      )

    on_exit(fn -> File.rm(path) end)

    pid = start_supervised!({Store, name: nil, table: @table, dets_path: path})
    {:ok, server: pid}
  end

  describe "get_config/2" do
    test "returns :error when nothing is saved", %{server: server} do
      assert Store.get_config(server, @key) == :error
    end

    test "round-trips a saved config with defaults filled in", %{server: server} do
      :ok = Store.update_config(server, @key, %{})
      {:ok, cfg} = Store.get_config(server, @key)

      assert cfg == Store.defaults()
      assert cfg.broadcast_encryption_set == false
      assert cfg.le_preference == nil
    end
  end

  describe "update_config/3 merge" do
    test "merges partial params over saved values", %{server: server} do
      :ok = Store.update_config(server, @key, %{le_preference: :lea})
      :ok = Store.update_config(server, @key, %{broadcast_name: "Office"})

      {:ok, cfg} = Store.get_config(server, @key)
      assert cfg.le_preference == :lea
      assert cfg.broadcast_name == "Office"
    end

    test "persists an explicit false (not overridden by default)", %{server: server} do
      :ok = Store.update_config(server, @key, %{broadcast_encryption_set: true})
      :ok = Store.update_config(server, @key, %{broadcast_encryption_set: false})

      {:ok, cfg} = Store.get_config(server, @key)
      assert cfg.broadcast_encryption_set == false
    end
  end

  describe "sanitize guards" do
    test "rejects out-of-range / wrong-typed values", %{server: server} do
      :ok =
        Store.update_config(server, @key, %{
          le_preference: :nonsense,
          feature_flags: 999,
          broadcast_mode: -1,
          codec_preference: :not_a_codec,
          broadcast_name: ""
        })

      {:ok, cfg} = Store.get_config(server, @key)
      assert cfg.le_preference == nil
      assert cfg.feature_flags == nil
      assert cfg.broadcast_mode == nil
      assert cfg.codec_preference == nil
      assert cfg.broadcast_name == nil
    end

    test "accepts valid values", %{server: server} do
      :ok =
        Store.update_config(server, @key, %{
          le_preference: :lea,
          feature_flags: 0x0F,
          broadcast_mode: 0xF4,
          codec_preference: :lea_lc3,
          friendly_name_override: "Den dongle"
        })

      {:ok, cfg} = Store.get_config(server, @key)
      assert cfg.le_preference == :lea
      assert cfg.feature_flags == 0x0F
      assert cfg.broadcast_mode == 0xF4
      assert cfg.codec_preference == :lea_lc3
      assert cfg.friendly_name_override == "Den dongle"
    end

    test "drops unknown keys", %{server: server} do
      :ok = Store.update_config(server, @key, %{bogus: 1, le_preference: :a2dp})
      {:ok, cfg} = Store.get_config(server, @key)
      refute Map.has_key?(cfg, :bogus)
      assert cfg.le_preference == :a2dp
    end
  end

  describe "all_configs/1" do
    test "returns every saved config keyed by tuple", %{server: server} do
      other = {"1-1.2", 0x0A12, 0x4007}
      :ok = Store.update_config(server, @key, %{le_preference: :lea})
      :ok = Store.update_config(server, other, %{le_preference: :a2dp})

      all = Store.all_configs(server)
      assert map_size(all) == 2
      assert all[@key].le_preference == :lea
      assert all[other].le_preference == :a2dp
    end
  end
end
