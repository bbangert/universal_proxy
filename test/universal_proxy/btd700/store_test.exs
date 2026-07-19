defmodule UniversalProxy.BTD700.StoreTest do
  # async: false — DETS table names must be atoms; reuse one constant atom
  # across tests (the GenServer itself is unnamed) to avoid atom-table growth.
  use ExUnit.Case, async: false

  alias UniversalProxy.BTD700.Store

  @table :btd700_store_test
  @key {"1-1.2", 0x3542, 0x3001}

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "btd700_store_test_#{System.unique_integer([:positive])}.dets"
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
      assert cfg.broadcast_encryption == false
      assert cfg.audio_mode == nil
    end
  end

  describe "update_config/3 merge" do
    test "merges partial params over saved values", %{server: server} do
      :ok = Store.update_config(server, @key, %{audio_mode: :broadcast})
      :ok = Store.update_config(server, @key, %{broadcast_name: "Living Room"})

      {:ok, cfg} = Store.get_config(server, @key)
      assert cfg.audio_mode == :broadcast
      assert cfg.broadcast_name == "Living Room"
    end

    test "persists an explicit false (not overridden by default)", %{server: server} do
      :ok = Store.update_config(server, @key, %{broadcast_encryption: true})
      :ok = Store.update_config(server, @key, %{broadcast_encryption: false})

      {:ok, cfg} = Store.get_config(server, @key)
      assert cfg.broadcast_encryption == false
    end

    test "persists an explicit nil (not overridden by the previous value)", %{server: server} do
      :ok = Store.update_config(server, @key, %{audio_mode: :gaming})
      :ok = Store.update_config(server, @key, %{audio_mode: nil})

      {:ok, cfg} = Store.get_config(server, @key)
      assert cfg.audio_mode == nil
    end
  end

  describe "sanitize guards" do
    test "rejects out-of-range / wrong-typed enum values", %{server: server} do
      :ok =
        Store.update_config(server, @key, %{
          audio_mode: :nonsense,
          broadcast_state: :not_a_state,
          broadcast_quality: :ultra_hd,
          broadcast_name: ""
        })

      {:ok, cfg} = Store.get_config(server, @key)
      assert cfg.audio_mode == nil
      assert cfg.broadcast_state == nil
      assert cfg.broadcast_quality == nil
      assert cfg.broadcast_name == nil
    end

    test "rejects a codec_mask containing an unknown atom", %{server: server} do
      :ok = Store.update_config(server, @key, %{codec_mask: [:sbc, :not_a_codec]})
      {:ok, cfg} = Store.get_config(server, @key)
      assert cfg.codec_mask == nil
    end

    test "rejects a codec_mask that isn't a list", %{server: server} do
      :ok = Store.update_config(server, @key, %{codec_mask: :sbc})
      {:ok, cfg} = Store.get_config(server, @key)
      assert cfg.codec_mask == nil
    end

    test "rejects an oversize broadcast name (> 59 bytes UTF-8)", %{server: server} do
      too_long = String.duplicate("a", 60)
      :ok = Store.update_config(server, @key, %{broadcast_name: too_long})
      {:ok, cfg} = Store.get_config(server, @key)
      assert cfg.broadcast_name == nil
    end

    test "accepts a broadcast name at exactly the 59-byte boundary", %{server: server} do
      at_limit = String.duplicate("a", 59)
      :ok = Store.update_config(server, @key, %{broadcast_name: at_limit})
      {:ok, cfg} = Store.get_config(server, @key)
      assert cfg.broadcast_name == at_limit
    end

    test "accepts valid values", %{server: server} do
      :ok =
        Store.update_config(server, @key, %{
          audio_mode: :high_quality,
          codec_mask: [:sbc, :aptx_adaptive, :lc3],
          broadcast_state: :on_public,
          broadcast_quality: :standard_24k,
          broadcast_encryption: true,
          broadcast_name: "Office"
        })

      {:ok, cfg} = Store.get_config(server, @key)
      assert cfg.audio_mode == :high_quality
      assert cfg.codec_mask == [:sbc, :aptx_adaptive, :lc3]
      assert cfg.broadcast_state == :on_public
      assert cfg.broadcast_quality == :standard_24k
      assert cfg.broadcast_encryption == true
      assert cfg.broadcast_name == "Office"
    end

    test "drops unknown keys, including an attempted broadcast key", %{server: server} do
      :ok =
        Store.update_config(server, @key, %{
          bogus: 1,
          broadcast_key: <<1, 2, 3, 4>>,
          audio_mode: :gaming
        })

      {:ok, cfg} = Store.get_config(server, @key)
      refute Map.has_key?(cfg, :bogus)
      refute Map.has_key?(cfg, :broadcast_key)
      assert cfg.audio_mode == :gaming
    end
  end

  describe "key-bytes never storable" do
    test "a raw dets dump of the stored record never contains a broadcast_key field", %{
      server: server
    } do
      :ok =
        Store.update_config(server, @key, %{
          broadcast_key: <<0xDE, 0xAD, 0xBE, 0xEF>>,
          broadcast_encryption: true
        })

      all = Store.all_configs(server)
      stored = all[@key]

      assert stored.broadcast_encryption == true
      refute Map.has_key?(stored, :broadcast_key)
      refute Enum.any?(Map.values(stored), &(&1 == <<0xDE, 0xAD, 0xBE, 0xEF>>))
    end
  end

  describe "all_configs/1" do
    test "returns every saved config keyed by tuple", %{server: server} do
      other = {"1-1.3", 0x3542, 0x3001}
      :ok = Store.update_config(server, @key, %{audio_mode: :broadcast})
      :ok = Store.update_config(server, other, %{audio_mode: :gaming})

      all = Store.all_configs(server)
      assert map_size(all) == 2
      assert all[@key].audio_mode == :broadcast
      assert all[other].audio_mode == :gaming
    end
  end
end
