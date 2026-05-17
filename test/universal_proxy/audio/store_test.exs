defmodule UniversalProxy.Audio.StoreTest do
  # async: false because DETS table names must be atoms; reusing a single
  # constant atom across tests prevents per-test atom-table growth. The
  # GenServer itself is unnamed (name: nil) so multiple tests can run
  # against the same atom table sequentially without clashing.
  use ExUnit.Case, async: false

  alias UniversalProxy.Audio.Store

  @table :audio_store_test
  @key {"bcm2835 Headphones", nil, nil}
  @usb_key {"Audio Gadget", 0x1D6B, 0x0104}

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "audio_store_test_#{System.unique_integer([:positive])}.dets"
      )

    on_exit(fn -> File.rm(path) end)

    pid = start_supervised!({Store, name: nil, table: @table, dets_path: path})

    {:ok, server: pid, dets_path: path}
  end

  describe "save_config/3 defaults" do
    test "applies defaults on first save with an empty params map", %{server: server} do
      :ok = Store.save_config(server, @key, %{})
      {:ok, cfg} = Store.get_config(server, @key)

      assert cfg.friendly_name == "bcm2835 Headphones"
      assert cfg.enabled == true
      assert cfg.volume == 50
      assert cfg.muted == false
      # client_id is a hex-encoded 16-byte random — 32 lowercase hex chars
      assert is_binary(cfg.client_id)
      assert String.match?(cfg.client_id, ~r/^[0-9a-f]{32}$/)
    end

    test "preserves a caller-supplied friendly_name + volume + muted", %{server: server} do
      :ok =
        Store.save_config(server, @key, %{
          friendly_name: "Kitchen Speakers",
          volume: 80,
          muted: true
        })

      {:ok, cfg} = Store.get_config(server, @key)
      assert cfg.friendly_name == "Kitchen Speakers"
      assert cfg.volume == 80
      assert cfg.muted == true
      assert cfg.enabled == true
    end

    test "keeps client_id stable across re-saves", %{server: server} do
      :ok = Store.save_config(server, @key, %{})
      {:ok, %{client_id: original_id}} = Store.get_config(server, @key)

      :ok = Store.save_config(server, @key, %{volume: 60})
      {:ok, %{client_id: id_after, volume: vol}} = Store.get_config(server, @key)

      assert id_after == original_id
      assert vol == 60
    end

    test "clamps out-of-range volume to 0..100", %{server: server} do
      :ok = Store.save_config(server, @key, %{volume: 999})
      assert {:ok, %{volume: 100}} = Store.get_config(server, @key)

      :ok = Store.save_config(server, @key, %{volume: -1})
      assert {:ok, %{volume: 0}} = Store.get_config(server, @key)
    end

    test "accepts string-keyed params (LiveView form data shape)", %{server: server} do
      :ok = Store.save_config(server, @key, %{"friendly_name" => "Bedroom", "volume" => 33})
      {:ok, cfg} = Store.get_config(server, @key)
      assert cfg.friendly_name == "Bedroom"
      assert cfg.volume == 33
    end
  end

  describe "tuple-key handling" do
    test "stores keys with non-nil VID/PID distinctly", %{server: server} do
      :ok = Store.save_config(server, @key, %{friendly_name: "Built-in"})
      :ok = Store.save_config(server, @usb_key, %{friendly_name: "USB DAC"})

      assert {:ok, %{friendly_name: "Built-in"}} = Store.get_config(server, @key)
      assert {:ok, %{friendly_name: "USB DAC"}} = Store.get_config(server, @usb_key)
    end

    test "get/delete return :error / :ok for missing keys", %{server: server} do
      assert :error = Store.get_config(server, @key)
      assert :ok = Store.delete_config(server, @key)
    end
  end

  describe "delete_config/2" do
    test "removes a saved row", %{server: server} do
      :ok = Store.save_config(server, @key, %{})
      assert {:ok, _} = Store.get_config(server, @key)

      :ok = Store.delete_config(server, @key)
      assert :error = Store.get_config(server, @key)
    end
  end

  describe "get_all/1" do
    test "returns every saved row as a %{key => config} map", %{server: server} do
      :ok = Store.save_config(server, @key, %{friendly_name: "A"})
      :ok = Store.save_config(server, @usb_key, %{friendly_name: "B"})

      all = Store.get_all(server)
      assert map_size(all) == 2
      assert all[@key].friendly_name == "A"
      assert all[@usb_key].friendly_name == "B"
    end
  end

  describe "persistence across restart" do
    # The setup-started Store holds an open handle to the
    # `:audio_store_test` DETS atom. `:dets.open_file/2` on an already-
    # open atom is a no-op — it returns the existing handle — so we
    # must stop the setup-owned Store before opening a fresh one,
    # otherwise the "restart" would only exercise in-memory shared
    # state instead of disk persistence.
    test "configs survive process restart", %{dets_path: path} do
      :ok = stop_supervised(UniversalProxy.Audio.Store)

      pid = start_supervised!({Store, name: nil, table: @table, dets_path: path}, id: :first)
      :ok = Store.save_config(pid, @key, %{friendly_name: "Persisted", volume: 75})
      {:ok, %{client_id: original_id}} = Store.get_config(pid, @key)

      :ok = stop_supervised(:first)

      reopened =
        start_supervised!({Store, name: nil, table: @table, dets_path: path}, id: :second)

      {:ok, cfg} = Store.get_config(reopened, @key)

      assert cfg.friendly_name == "Persisted"
      assert cfg.volume == 75
      assert cfg.client_id == original_id
    end
  end
end
