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
      assert cfg.pairing_psk == nil
      assert cfg.pairings == []
      refute Map.has_key?(cfg, :psk)
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
          pairing_psk: <<7::256>>
        })

      :ok = Store.save_config(server, @key, %{friendly_name: "Renamed"})

      {:ok, cfg} = Store.get_config(server, @key)
      assert cfg.friendly_name == "Renamed"
      assert cfg.pairing_psk == <<7::256>>
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

  describe "ensure_pairing_psk/2 and pairing_token/2" do
    test "mints a 32-byte pairing PSK once and keeps it", %{server: server} do
      {:ok, psk} = Store.ensure_pairing_psk(server, @key)
      assert byte_size(psk) == 32
      assert {:ok, ^psk} = Store.ensure_pairing_psk(server, @key)
      assert {:ok, %{pairing_psk: ^psk}} = Store.get_config(server, @key)
    end

    test "is stable across a GenServer restart", %{dets_path: path} do
      pid = restart_store!(path, :first)
      {:ok, psk} = Store.ensure_pairing_psk(pid, @key)

      reopened = restart_store!(path, :second)
      assert {:ok, ^psk} = Store.ensure_pairing_psk(reopened, @key)
    end

    test "is distinct per input", %{server: server} do
      {:ok, a} = Store.ensure_pairing_psk(server, @key)
      {:ok, b} = Store.ensure_pairing_psk(server, @usb_key)
      assert a != b
    end

    test "the token is SP:0 + base32(client key || pairing PSK)", %{server: server} do
      {:ok, token} = Store.pairing_token(server, @key)
      {:ok, {pub, _priv}} = Store.ensure_client_keypair(server, @key)
      {:ok, pairing_psk} = Store.ensure_pairing_psk(server, @key)

      assert "SP:0" <> body = token

      assert {:ok, pub <> pairing_psk} ==
               body |> String.replace("9", "2") |> pad() |> Base.decode32()

      assert {:ok, ^token} = Store.pairing_token(server, @key)
    end

    test "survives clear_pairing (it is a credential, not pairing state)", %{server: server} do
      {:ok, psk} = Store.ensure_pairing_psk(server, @key)
      :ok = Store.clear_pairing(server, @key)
      assert {:ok, %{pairing_psk: ^psk}} = Store.get_config(server, @key)
    end

    test "the table file is owner-only", %{dets_path: path} do
      assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
      assert Bitwise.band(mode, 0o777) == 0o600
    end

    defp pad(body), do: body <> String.duplicate("=", rem(8 - rem(byte_size(body), 8), 8))
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

  describe "pairing records" do
    defp server_id(n), do: Base.url_encode64(<<n::256>>, padding: false)

    defp pair!(server, n, at \\ nil) do
      attrs = %{psk: <<n + 1000::256>>, server_id: server_id(n)}
      attrs = if at, do: Map.put(attrs, :paired_at, at), else: attrs
      :ok = Store.save_pairing(server, @key, attrs)
    end

    test "a pairing becomes a record with a derived psk_id and paired_at", %{server: server} do
      pair!(server, 1)
      {:ok, cfg} = Store.get_config(server, @key)

      assert [record] = cfg.pairings
      assert record.psk == <<1001::256>>
      assert record.psk_id == UniversalProxy.Sendspin.Pairing.psk_id_for(<<1001::256>>)
      assert record.server_id == server_id(1)
      assert %DateTime{} = record.paired_at
      assert record.last_used == record.paired_at
    end

    test "accepts an explicit paired_at", %{server: server} do
      pair!(server, 1, ~U[2026-01-01 00:00:00Z])
      {:ok, %{pairings: [record]}} = Store.get_config(server, @key)
      assert record.paired_at == ~U[2026-01-01 00:00:00Z]
    end

    test "re-pairing the same server replaces its record; another server adds one",
         %{server: server} do
      pair!(server, 1)
      pair!(server, 2)
      :ok = Store.save_pairing(server, @key, %{psk: <<9::256>>, server_id: server_id(1)})

      {:ok, cfg} = Store.get_config(server, @key)
      assert length(cfg.pairings) == 2
      assert Enum.find(cfg.pairings, &(&1.server_id == server_id(1))).psk == <<9::256>>
    end

    test "keeps at least five, then evicts the least recently used but never the protected one",
         %{server: server} do
      for n <- 1..8, do: pair!(server, n, DateTime.add(~U[2026-01-01 00:00:00Z], n, :day))

      {:ok, cfg} = Store.get_config(server, @key)
      assert length(cfg.pairings) == 8
      oldest = Enum.find(cfg.pairings, &(&1.server_id == server_id(1)))

      # A ninth server while the oldest record backs the open connection: the
      # next-oldest goes instead, and the pairing still succeeds.
      :ok =
        Store.save_pairing(server, @key, %{psk: <<99::256>>, server_id: server_id(9)},
          protect: oldest.psk_id
        )

      {:ok, cfg} = Store.get_config(server, @key)
      ids = Enum.map(cfg.pairings, & &1.server_id)
      assert length(ids) == 8
      assert server_id(9) in ids
      assert server_id(1) in ids
      refute server_id(2) in ids
    end

    test "touch_pairing/3 moves a record to the front of the LRU order", %{server: server} do
      pair!(server, 1, ~U[2026-01-01 00:00:00Z])
      pair!(server, 2, ~U[2026-01-02 00:00:00Z])
      {:ok, cfg} = Store.get_config(server, @key)
      assert [%{server_id: second} | _] = Store.pairings(cfg)
      assert second == server_id(2)

      first = Enum.find(cfg.pairings, &(&1.server_id == server_id(1)))
      :ok = Store.touch_pairing(server, @key, first.psk_id)
      {:ok, cfg} = Store.get_config(server, @key)
      assert [%{server_id: touched} | _] = Store.pairings(cfg)
      assert touched == server_id(1)
    end

    test "remove_pairing/3 by server_id or psk_id; clear_pairing/2 drops all, keeping identity",
         %{server: server} do
      :ok = Store.save_config(server, @key, %{friendly_name: "My Input"})
      {:ok, keypair} = Store.ensure_client_keypair(server, @key)
      {:ok, pairing_psk} = Store.ensure_pairing_psk(server, @key)
      pair!(server, 1)
      pair!(server, 2)
      pair!(server, 3)

      :ok = Store.remove_pairing(server, @key, server_id: server_id(1))
      {:ok, cfg} = Store.get_config(server, @key)
      record = Enum.find(cfg.pairings, &(&1.server_id == server_id(2)))
      :ok = Store.remove_pairing(server, @key, psk_id: record.psk_id)
      :ok = Store.remove_pairing(server, @key, psk_id: "not-there")
      {:ok, cfg} = Store.get_config(server, @key)
      assert Enum.map(cfg.pairings, & &1.server_id) == [server_id(3)]

      :ok = Store.clear_pairing(server, @key)
      {:ok, cleared} = Store.get_config(server, @key)
      assert cleared.pairings == []
      assert cleared.friendly_name == "My Input"
      assert cleared.client_keypair == keypair
      assert cleared.pairing_psk == pairing_psk
    end

    test "regenerate_pairing_psk/2 mints a new pairing PSK and keeps the records",
         %{server: server} do
      {:ok, old} = Store.ensure_pairing_psk(server, @key)
      {:ok, old_token} = Store.pairing_token(server, @key)
      pair!(server, 1)

      :ok = Store.regenerate_pairing_psk(server, @key)
      {:ok, cfg} = Store.get_config(server, @key)
      assert byte_size(cfg.pairing_psk) == 32
      refute cfg.pairing_psk == old
      assert length(cfg.pairings) == 1
      refute Store.pairing_token(server, @key) == {:ok, old_token}
    end
  end

  describe "pre-rc1 rows" do
    # The shape the pre-rc1 source wrote: one flat pairing record.
    defp legacy_row!(path, fields) do
      stop_supervised(UniversalProxy.Audio.Input.Store)
      {:ok, table} = :dets.open_file(:legacy_seed, file: to_charlist(path), type: :set)

      row =
        Map.merge(
          %{
            friendly_name: "Old Input",
            client_keypair: Noise.generate_static_keypair(),
            psk: nil,
            psk_id: nil,
            psk_category: nil,
            server_id: nil,
            paired_at: nil
          },
          fields
        )

      :ok = :dets.insert(table, {@key, row})
      :ok = :dets.close(table)
      start_supervised!({Store, name: nil, table: @table, dets_path: path}, id: :reopened)
    end

    test "a flat record becomes the first pairing, its psk_id recomputed", %{dets_path: path} do
      psk = <<42::256>>
      server_id = Base.url_encode64(<<5::256>>, padding: false)

      server =
        legacy_row!(path, %{
          psk: psk,
          psk_id: "a-stale-or-differently-derived-id",
          psk_category: :long_term,
          server_id: server_id,
          paired_at: ~U[2026-08-17 00:00:00Z]
        })

      {:ok, cfg} = Store.get_config(server, @key)
      assert cfg.friendly_name == "Old Input"

      assert [
               %{
                 psk: ^psk,
                 server_id: ^server_id,
                 paired_at: ~U[2026-08-17 00:00:00Z]
               } = record
             ] = cfg.pairings

      assert record.psk_id == UniversalProxy.Sendspin.Pairing.psk_id_for(psk)
      refute Map.has_key?(cfg, :psk) or Map.has_key?(cfg, :psk_category)

      # The next write persists the new shape and keeps the record.
      :ok = Store.save_config(server, @key, %{friendly_name: "Renamed"})
      {:ok, cfg} = Store.get_config(server, @key)
      assert [%{psk: ^psk}] = cfg.pairings
      assert [{@key, raw}] = :dets.lookup(@table, @key)
      refute Map.has_key?(raw, :psk)
    end

    test "a flat record without a usable server_id is dropped", %{dets_path: path} do
      server = legacy_row!(path, %{psk: <<42::256>>, psk_id: "x", server_id: nil})
      assert {:ok, %{pairings: [], friendly_name: "Old Input"}} = Store.get_config(server, @key)
    end

    test "an unpaired old row keeps its identity and gets no records", %{dets_path: path} do
      server = legacy_row!(path, %{})
      assert {:ok, %{pairings: [], client_keypair: {_, _}}} = Store.get_config(server, @key)
    end
  end

  describe "persistence across restart" do
    test "configs survive process restart", %{dets_path: path} do
      pid = restart_store!(path, :first)
      server_id = Base.url_encode64(<<3::256>>, padding: false)
      :ok = Store.save_pairing(pid, @key, %{psk: <<2::256>>, server_id: server_id})
      {:ok, %{pairings: [original]}} = Store.get_config(pid, @key)

      reopened = restart_store!(path, :second)
      assert {:ok, %{pairings: [^original]}} = Store.get_config(reopened, @key)
    end
  end
end
