defmodule UniversalProxy.Audio.Input.StoreTest do
  # async: false because DETS table names must be atoms; reusing a single
  # constant atom across tests prevents per-test atom-table growth. The
  # GenServer itself is unnamed (name: nil) so multiple tests can run
  # against the same atom table sequentially without clashing.
  use ExUnit.Case, async: false

  alias UniversalProxy.Audio.Input.Store
  alias UniversalProxy.Sendspin.Noise

  @table :audio_input_store_test
  @key {"USB Capture Card", nil, nil}
  @usb_key {"Audio Gadget In", 0x1D6B, 0x0105}

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "audio_input_store_test_#{System.unique_integer([:positive])}.dets"
      )

    on_exit(fn -> File.rm(path) end)

    pid = start_supervised!({Store, name: nil, table: @table, dets_path: path})

    {:ok, server: pid, dets_path: path}
  end

  # Both restart-across-process tests need the same two-step dance: stop
  # whichever Store currently holds the `@table` DETS atom (reusing its
  # handle instead would only prove in-memory state, since
  # `:dets.open_file/2` on an already-open atom is a no-op) and start a
  # fresh instance against the same `dets_path`. Call with `id: :first`
  # to replace the setup-owned Store, then `id: :second` to replace
  # `:first` and prove the earlier write actually reached disk.
  defp restart_store!(path, id) do
    case id do
      :first -> stop_supervised(UniversalProxy.Audio.Input.Store)
      :second -> stop_supervised(:first)
    end

    start_supervised!({Store, name: nil, table: @table, dets_path: path}, id: id)
  end

  describe "save_config/3 defaults" do
    test "applies defaults on first save with an empty params map", %{server: server} do
      :ok = Store.save_config(server, @key, %{})
      {:ok, cfg} = Store.get_config(server, @key)

      assert cfg.friendly_name == "USB Capture Card"
      assert cfg.client_keypair == nil
      assert cfg.psk == nil
      assert cfg.psk_id == nil
      assert cfg.psk_category == nil
      assert cfg.server_id == nil
      assert cfg.paired_at == nil
    end

    test "preserves a caller-supplied friendly_name", %{server: server} do
      :ok = Store.save_config(server, @key, %{friendly_name: "Living Room Line-In"})
      {:ok, cfg} = Store.get_config(server, @key)
      assert cfg.friendly_name == "Living Room Line-In"
    end

    test "accepts string-keyed params (LiveView form data shape)", %{server: server} do
      :ok = Store.save_config(server, @key, %{"friendly_name" => "Bedroom In"})
      {:ok, cfg} = Store.get_config(server, @key)
      assert cfg.friendly_name == "Bedroom In"
    end
  end

  describe "merge semantics" do
    test "a partial update doesn't clobber an unrelated field", %{server: server} do
      :ok =
        Store.save_config(server, @key, %{
          friendly_name: "Kept Name",
          psk_category: :long_term
        })

      :ok = Store.save_config(server, @key, %{friendly_name: "Renamed"})

      {:ok, cfg} = Store.get_config(server, @key)
      assert cfg.friendly_name == "Renamed"
      assert cfg.psk_category == :long_term
    end

    test "explicit nil/false values are persisted rather than falling back to defaults",
         %{server: server} do
      :ok = Store.save_config(server, @key, %{friendly_name: "Named"})
      :ok = Store.save_config(server, @key, %{friendly_name: nil})

      {:ok, cfg} = Store.get_config(server, @key)
      assert cfg.friendly_name == nil
    end
  end

  describe "tuple-key handling" do
    test "stores keys with non-nil VID/PID distinctly", %{server: server} do
      :ok = Store.save_config(server, @key, %{friendly_name: "Built-in In"})
      :ok = Store.save_config(server, @usb_key, %{friendly_name: "USB In"})

      assert {:ok, %{friendly_name: "Built-in In"}} = Store.get_config(server, @key)
      assert {:ok, %{friendly_name: "USB In"}} = Store.get_config(server, @usb_key)
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

  describe "all_configs/1" do
    test "returns every saved row as a %{key => config} map", %{server: server} do
      :ok = Store.save_config(server, @key, %{friendly_name: "A"})
      :ok = Store.save_config(server, @usb_key, %{friendly_name: "B"})

      all = Store.all_configs(server)
      assert map_size(all) == 2
      assert all[@key].friendly_name == "A"
      assert all[@usb_key].friendly_name == "B"
    end
  end

  describe "ensure_client_keypair/2" do
    test "generates a keypair on first use and persists it", %{server: server} do
      {:ok, {pub, priv}} = Store.ensure_client_keypair(server, @key)

      assert is_binary(pub) and byte_size(pub) == 32
      assert is_binary(priv)

      {:ok, cfg} = Store.get_config(server, @key)
      assert cfg.client_keypair == {pub, priv}
    end

    test "is stable across repeated calls", %{server: server} do
      {:ok, keypair1} = Store.ensure_client_keypair(server, @key)
      {:ok, keypair2} = Store.ensure_client_keypair(server, @key)

      assert keypair1 == keypair2
    end

    test "is stable across a GenServer restart (persisted, not regenerated)",
         %{dets_path: path} do
      pid = restart_store!(path, :first)
      {:ok, original_keypair} = Store.ensure_client_keypair(pid, @key)

      reopened = restart_store!(path, :second)
      {:ok, keypair_after_restart} = Store.ensure_client_keypair(reopened, @key)

      assert keypair_after_restart == original_keypair
    end

    test "does not disturb other saved fields", %{server: server} do
      :ok = Store.save_config(server, @key, %{friendly_name: "Keep Me"})
      {:ok, _keypair} = Store.ensure_client_keypair(server, @key)

      {:ok, cfg} = Store.get_config(server, @key)
      assert cfg.friendly_name == "Keep Me"
    end

    test "a persisted keypair with a wrong-length priv is discarded and regenerated",
         %{server: server} do
      {pub, _valid_priv} = Noise.generate_static_keypair()
      bad_keypair = {pub, <<1, 2, 3>>}

      :ok = Store.save_config(server, @key, %{client_keypair: bad_keypair})
      {:ok, %{client_keypair: ^bad_keypair}} = Store.get_config(server, @key)

      {:ok, {new_pub, new_priv}} = Store.ensure_client_keypair(server, @key)

      assert byte_size(new_pub) == 32
      assert byte_size(new_priv) == 32
      assert {new_pub, new_priv} != bad_keypair

      {:ok, cfg} = Store.get_config(server, @key)
      assert cfg.client_keypair == {new_pub, new_priv}
    end
  end

  describe "client_id/1" do
    test "is the url-safe, no-padding base64 encoding of the 32-byte pubkey" do
      pub = :crypto.strong_rand_bytes(32)

      assert Store.client_id(pub) == Base.url_encode64(pub, padding: false)
      refute String.contains?(Store.client_id(pub), "=")
      assert String.length(Store.client_id(pub)) == 43
    end

    test "matches the pub half of a stored keypair", %{server: server} do
      {:ok, {pub, _priv}} = Store.ensure_client_keypair(server, @key)
      assert Store.client_id(pub) == Base.url_encode64(pub, padding: false)
    end
  end

  describe "save_pairing/3 and clear_pairing/2" do
    test "round-trips pairing state and defaults paired_at", %{server: server} do
      :ok =
        Store.save_pairing(server, @key, %{
          psk: :crypto.strong_rand_bytes(32),
          psk_id: "some-psk-id",
          psk_category: :long_term,
          server_id: "some-server-id"
        })

      {:ok, cfg} = Store.get_config(server, @key)
      assert byte_size(cfg.psk) == 32
      assert cfg.psk_id == "some-psk-id"
      assert cfg.psk_category == :long_term
      assert cfg.server_id == "some-server-id"
      assert %DateTime{} = cfg.paired_at
    end

    test "accepts an explicit paired_at instead of defaulting", %{server: server} do
      paired_at = ~U[2026-01-01 00:00:00Z]

      :ok =
        Store.save_pairing(server, @key, %{
          psk: <<0::256>>,
          psk_id: "id",
          psk_category: :long_term,
          server_id: "server",
          paired_at: paired_at
        })

      {:ok, cfg} = Store.get_config(server, @key)
      assert cfg.paired_at == paired_at
    end

    test "preserves friendly_name and client_keypair, round-trips through clear_pairing",
         %{server: server} do
      :ok = Store.save_config(server, @key, %{friendly_name: "My Input"})
      {:ok, keypair} = Store.ensure_client_keypair(server, @key)

      :ok =
        Store.save_pairing(server, @key, %{
          psk: <<1::256>>,
          psk_id: "id",
          psk_category: :long_term,
          server_id: "server"
        })

      {:ok, paired_cfg} = Store.get_config(server, @key)
      assert paired_cfg.friendly_name == "My Input"
      assert paired_cfg.client_keypair == keypair
      assert paired_cfg.psk == <<1::256>>

      :ok = Store.clear_pairing(server, @key)

      {:ok, cleared_cfg} = Store.get_config(server, @key)
      assert cleared_cfg.friendly_name == "My Input"
      assert cleared_cfg.client_keypair == keypair
      assert cleared_cfg.psk == nil
      assert cleared_cfg.psk_id == nil
      assert cleared_cfg.psk_category == nil
      assert cleared_cfg.server_id == nil
      assert cleared_cfg.paired_at == nil
    end
  end

  describe "persistence across restart" do
    test "configs survive process restart", %{dets_path: path} do
      pid = restart_store!(path, :first)

      :ok =
        Store.save_pairing(pid, @key, %{
          psk: <<2::256>>,
          psk_id: "restart-id",
          psk_category: :long_term,
          server_id: "restart-server"
        })

      {:ok, %{paired_at: original_paired_at}} = Store.get_config(pid, @key)

      reopened = restart_store!(path, :second)

      {:ok, cfg} = Store.get_config(reopened, @key)

      assert cfg.psk == <<2::256>>
      assert cfg.psk_id == "restart-id"
      assert cfg.server_id == "restart-server"
      assert cfg.paired_at == original_paired_at
    end
  end
end
