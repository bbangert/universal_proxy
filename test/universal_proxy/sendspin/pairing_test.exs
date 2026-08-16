defmodule UniversalProxy.Sendspin.PairingTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Sendspin.CPace
  alias UniversalProxy.Sendspin.Pairing
  alias UniversalProxy.SendspinPairingServer, as: Server

  @chacha "25519_ChaChaPoly_SHA256"
  @aesgcm "25519_AESGCM_SHA256"

  # Known-answer vectors, computed by an independent pure-Python
  # reimplementation of the ground-truth algorithms (§3) whose CPace core is
  # itself pinned to the draft-irtf-cfrg-cpace-21 Appendix B.1 vectors and
  # whose SENTINEL_PSK reproduces the published constant. The two CPace
  # scalars are B.1's `ya`/`yb`, reused here under a Sendspin-shaped `sid`.
  @kat_hash Base.decode16!("000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F")
  @kat_nonce_a Base.decode16!("404142434445464748494A4B4C4D4E4F505152535455565758595A5B5C5D5E5F")
  @kat_nonce_b Base.decode16!("808182838485868788898A8B8C8D8E8F909192939495969798999A9B9C9D9E9F")
  @kat_index 1
  @kat_pin_length 6

  @kat_scalar_a Base.decode16!("21B4F4BD9E64ED355C3EB676A28EBEDAF6D8F17BDC365995B319097153044080")
  @kat_scalar_b Base.decode16!("848B0779FF415F0AF4EA14DF9DD1D3C29AC41D836C7808896C4EBA19C51AC40A")

  @kat_sid Base.decode16!(
             "73656E647370696E2D706169722D70616B652D7631" <>
               "000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F" <>
               "00000001"
           )
  @kat_commit_b Base.decode16!("FC91579D2561D9CAA0C0B933CA3F976D6A860C6EE561FF24A1A790A649DF957C")
  @kat_pin "789806"
  @kat_ya Base.decode16!("9092E32299CF5A1F27E882737269A15E4F6263C56A930AE79C85C4D77487E721")
  @kat_yb Base.decode16!("FE3226D416EBA5C959952B177B567918B92972D00C2339E0B18C594D91890115")
  @kat_isk Base.decode16!(
             "B7C963C7022F3DC11F5E42E0A628C560177AF191EFCB084F23AC52C64253F9E2" <>
               "82DE9C93268CD37976670E1F30593F2592259CD6C0760C620E9BBDD7389AFB8C"
           )
  @kat_mac_key Base.decode16!(
                 "6C99DF53D0FA4212E9EC82D7B0113281FDC61FEA52DFFFF1C98E62900811E8E5" <>
                   "84FADE42F24562A7070C1E3AC2B10228851C8FD31FEAB437C69637D0AA20E150"
               )
  @kat_ta Base.decode16!(
            "F9BDF3EDBB52BDFB096EEF689482CC33B7E9929049DA5436990721B681EDB16B" <>
              "1F8AC07823B46C9FEBECEFDBAA7EAE08F731F9442D19A3EC99600E9638756BF8"
          )
  @kat_tb Base.decode16!(
            "1EACBF68420DB4BF259F958E33C30871168F68A6553892EE1BC2E64B580B9F5F" <>
              "7BEDE56B021C08E3F97A79E246745B62290136318AB0ECE758F98A096D0C33F0"
          )
  @kat_wrap_key Base.decode16!("C244FD65FE33E5B5B4A7BDC9F6E483F384850EB2AAC94A0AF53CBCEEB13308B7")
  @kat_psk :binary.list_to_bin(Enum.to_list(0xA0..0xBF))
  @kat_psk_id "UaXYTgo_O5NA363FD_WJGwAORfbAld1hDE9vHMOWFSg"

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)
  defp unb64(value), do: Base.url_decode64!(value, padding: false)

  defp client_opts(overrides \\ []) do
    Keyword.merge(
      [
        handshake_hash: :crypto.strong_rand_bytes(32),
        pairing_index: 1,
        suite: @chacha,
        pin_length: 6
      ],
      overrides
    )
  end

  # Drive a full attempt. `pin_fun` maps the PIN the client displayed onto
  # the PIN the operator typed into the server, which is where a wrong-PIN
  # test diverges.
  defp pair(opts, pin_fun \\ & &1) do
    client_opts = client_opts(opts)

    server_opts =
      Keyword.take(client_opts, [:handshake_hash, :pairing_index, :suite, :pin_length])

    {:ok, [{"client/pair-init", init}], client} = Pairing.start(client_opts)
    server = Server.start(server_opts)

    {:send, [{"server/pair-init", %{"nonce_A" => _} = server_init}], server} =
      Server.handle(server, "client/pair-init", init)

    {:pin, pin, client} = Pairing.handle(client, "server/pair-init", server_init)

    {:send, [{"server/pair-auth", auth}], server} = Server.submit_pin(server, pin_fun.(pin))

    {:send, [{"client/pair-auth", client_auth}], client} =
      Pairing.handle(client, "server/pair-auth", auth)

    {:send, [{"server/pair-confirm", confirm}], server} =
      Server.handle(server, "client/pair-auth", client_auth)

    %{client: client, server: server, pin: pin, server_confirm: confirm}
  end

  describe "known-answer vectors (ground truth §3)" do
    test "sid/2 concatenates label, handshake hash and big-endian counter" do
      assert Pairing.sid(@kat_hash, @kat_index) == @kat_sid
      assert byte_size(@kat_sid) == 21 + 32 + 4
    end

    test "commit/1 and derive_pin/4" do
      assert Pairing.commit(@kat_nonce_b) == @kat_commit_b
      assert Pairing.commit_valid?(@kat_nonce_b, @kat_commit_b)
      refute Pairing.commit_valid?(@kat_nonce_a, @kat_commit_b)

      assert Pairing.derive_pin(@kat_hash, @kat_nonce_a, @kat_nonce_b, @kat_pin_length) ==
               @kat_pin
    end

    test "derive_pin/4 zero-pads to the requested width" do
      for length <- 4..12 do
        pin = Pairing.derive_pin(@kat_hash, @kat_nonce_a, @kat_nonce_b, length)
        assert String.length(pin) == length
        assert pin =~ ~r/\A[0-9]+\z/
      end
    end

    test "mac_key/2, confirmation_tag/3 and wrap_key/2" do
      assert Pairing.mac_key(@kat_sid, @kat_isk) == @kat_mac_key
      assert Pairing.confirmation_tag(@kat_mac_key, @kat_ya, "server") == @kat_ta
      assert Pairing.confirmation_tag(@kat_mac_key, @kat_yb, "client") == @kat_tb
      assert Pairing.wrap_key(@kat_sid, @kat_isk) == @kat_wrap_key
    end

    test "psk_id_for/1" do
      assert Pairing.psk_id_for(@kat_psk) == @kat_psk_id
    end

    test "a scripted dynamic attempt reproduces every wire field" do
      {:ok, [{"client/pair-init", init}], client} =
        Pairing.start(
          handshake_hash: @kat_hash,
          pairing_index: @kat_index,
          suite: @chacha,
          pin_length: @kat_pin_length,
          nonce_b: @kat_nonce_b,
          cpace_scalar: @kat_scalar_b,
          psk: @kat_psk
        )

      assert init == %{"pairing_index" => 1, "commit_B" => b64(@kat_commit_b)}

      {:pin, pin, client} =
        Pairing.handle(client, "server/pair-init", %{"nonce_A" => b64(@kat_nonce_a)})

      assert pin == @kat_pin
      assert Pairing.pin(client) == @kat_pin

      {:send, [{"client/pair-auth", auth}], client} =
        Pairing.handle(client, "server/pair-auth", %{"pake_msg_1" => b64(@kat_ya)})

      assert auth == %{"pake_msg_2" => b64(@kat_yb)}

      {:send, [{"client/pair-confirm", confirm}, {"client/pair-finalize", finalize}], client} =
        Pairing.handle(client, "server/pair-confirm", %{"server_kc" => b64(@kat_ta)})

      assert confirm == %{"client_kc" => b64(@kat_tb), "nonce_B" => b64(@kat_nonce_b)}

      wrapped = unb64(finalize["wrapped_psk"])
      assert byte_size(wrapped) == 48
      assert Pairing.unwrap_psk(@chacha, @kat_wrap_key, wrapped) == {:ok, @kat_psk}

      assert {:paired, outcome, _client} =
               Pairing.handle(client, "server/pair-finalize", %{})

      assert outcome == %{psk: @kat_psk, psk_id: @kat_psk_id, category: :long_term}
    end

    test "the server's own CPace share matches the vector" do
      {:ok, cpace} =
        CPace.start(:a, prs: @kat_pin, ci: "", sid: @kat_sid, ad: "server", scalar: @kat_scalar_a)

      assert CPace.public_share(cpace) == @kat_ya
      assert CPace.finish(cpace, @kat_yb, "client") == {:ok, @kat_isk}
    end
  end

  describe "dynamic-PIN round trip" do
    test "the correct PIN pairs and both sides land on the same PSK" do
      %{client: client, server: server, server_confirm: confirm} = pair([])

      assert {:send,
              [{"client/pair-confirm", client_confirm}, {"client/pair-finalize", finalize}],
              client} = Pairing.handle(client, "server/pair-confirm", confirm)

      assert {:ok, server} = Server.handle(server, "client/pair-confirm", client_confirm)

      assert {:send, [{"server/pair-finalize", %{}}], server} =
               Server.handle(server, "client/pair-finalize", finalize)

      assert {:paired, outcome, client} = Pairing.handle(client, "server/pair-finalize", %{})

      assert Pairing.stage(client) == :paired
      assert byte_size(outcome.psk) == 32
      assert outcome.category == :long_term
      assert outcome.psk_id == Pairing.psk_id_for(outcome.psk)
      assert Server.psk(server) == outcome.psk
    end

    test "the AES-GCM suite wraps the PSK just as well" do
      %{client: client, server: server, server_confirm: confirm} = pair(suite: @aesgcm)

      {:send, [{"client/pair-confirm", client_confirm}, {"client/pair-finalize", finalize}],
       client} = Pairing.handle(client, "server/pair-confirm", confirm)

      {:ok, server} = Server.handle(server, "client/pair-confirm", client_confirm)
      {:send, _, server} = Server.handle(server, "client/pair-finalize", finalize)
      {:paired, outcome, _client} = Pairing.handle(client, "server/pair-finalize", %{})

      assert Server.psk(server) == outcome.psk
    end

    test "every attempt derives a fresh PIN, PSK and commitment" do
      runs = for _ <- 1..5, do: pair([])
      pins = Enum.map(runs, & &1.pin)

      assert length(Enum.uniq(pins)) == 5
      assert Enum.all?(pins, &(String.length(&1) == 6))
    end

    test "a longer negotiated PIN still round-trips" do
      %{client: client, server: server, pin: pin, server_confirm: confirm} = pair(pin_length: 10)

      assert String.length(pin) == 10

      {:send, [{"client/pair-confirm", client_confirm}, _finalize], _client} =
        Pairing.handle(client, "server/pair-confirm", confirm)

      assert {:ok, _server} = Server.handle(server, "client/pair-confirm", client_confirm)
    end
  end

  describe "static-PIN round trip" do
    setup do
      opts = [handshake_hash: :crypto.strong_rand_bytes(32), pairing_index: 3, suite: @chacha]
      %{opts: opts}
    end

    test "no nonce or commitment travels, and the PSK still lands", %{opts: opts} do
      pin = "40028922"

      {:ok, [{"client/pair-init", init}], client} =
        Pairing.start(opts ++ [method: :static_pin, pin: pin])

      assert init == %{"pairing_index" => 3}

      server = Server.start(opts ++ [method: :static_pin, pin: pin])

      {:send, [{"server/pair-auth", auth}], server} =
        Server.handle(server, "client/pair-init", init)

      {:send, [{"client/pair-auth", client_auth}], client} =
        Pairing.handle(client, "server/pair-auth", auth)

      {:send, [{"server/pair-confirm", confirm}], server} =
        Server.handle(server, "client/pair-auth", client_auth)

      {:send, [{"client/pair-confirm", client_confirm}, {"client/pair-finalize", finalize}],
       client} = Pairing.handle(client, "server/pair-confirm", confirm)

      refute Map.has_key?(client_confirm, "nonce_B")

      {:ok, server} = Server.handle(server, "client/pair-confirm", client_confirm)
      {:send, _, server} = Server.handle(server, "client/pair-finalize", finalize)
      {:paired, outcome, _client} = Pairing.handle(client, "server/pair-finalize", %{})

      assert Server.psk(server) == outcome.psk
    end

    test "a client PIN the operator did not type fails the server's tag check", %{opts: opts} do
      {:ok, [{"client/pair-init", init}], client} =
        Pairing.start(opts ++ [method: :static_pin, pin: "40028922"])

      server = Server.start(opts ++ [method: :static_pin, pin: "40028923"])

      {:send, [{"server/pair-auth", auth}], server} =
        Server.handle(server, "client/pair-init", init)

      {:send, [{"client/pair-auth", client_auth}], client} =
        Pairing.handle(client, "server/pair-auth", auth)

      {:send, [{"server/pair-confirm", confirm}], server} =
        Server.handle(server, "client/pair-auth", client_auth)

      # Client rejects the server's Ta first, but even if it were tricked
      # into replying the server would reject Tb.
      assert {:abort, :pin_mismatch, _msgs, _client} =
               Pairing.handle(client, "server/pair-confirm", confirm)

      forged = %{"client_kc" => b64(:crypto.strong_rand_bytes(64))}
      assert Server.handle(server, "client/pair-confirm", forged) == {:error, :pin_mismatch}
    end

    test "start/1 refuses a PIN that is not eight digits", %{opts: opts} do
      for pin <- ["1234567", "123456789", "abcdefgh", "1234 678", nil] do
        assert {:error, {:invalid_static_pin, ^pin}} =
                 Pairing.start(opts ++ [method: :static_pin, pin: pin])
      end

      assert Pairing.valid_static_pin?("40028922")
      refute Pairing.valid_static_pin?("4002892")
    end
  end

  describe "wrong PIN" do
    test "a mistyped operator PIN fails the client's MCF check and aborts" do
      %{client: client, server_confirm: confirm} =
        pair([], fn pin -> String.replace(pin, ~r/\A./, "9") end)

      assert {:abort, :pin_mismatch, [{"pair/abort", payload}], client} =
               Pairing.handle(client, "server/pair-confirm", confirm)

      assert payload == %{"reason" => "pin_mismatch"}
      assert Pairing.stage(client) == {:failed, :pin_mismatch}
    end

    test "the server rejects a client tag from a different PIN" do
      %{server: server} = pair([], fn pin -> String.replace(pin, ~r/\A./, "9") end)

      confirm = %{
        "client_kc" => b64(:crypto.strong_rand_bytes(64)),
        "nonce_B" => b64(:crypto.strong_rand_bytes(32))
      }

      # Commit is checked before the tag, so a random nonce_B trips that
      # first — as the ground truth's verification order requires.
      assert Server.handle(server, "client/pair-confirm", confirm) == {:error, :commit_mismatch}
    end
  end

  describe "tampering" do
    test "a tampered commit_B is caught on reveal" do
      client_opts = client_opts([])

      server_opts =
        Keyword.take(client_opts, [:handshake_hash, :pairing_index, :suite, :pin_length])

      {:ok, [{"client/pair-init", init}], client} = Pairing.start(client_opts)
      tampered = %{init | "commit_B" => b64(Pairing.commit(Pairing.generate_nonce()))}

      server = Server.start(server_opts)

      {:send, [{"server/pair-init", server_init}], server} =
        Server.handle(server, "client/pair-init", tampered)

      {:pin, pin, client} = Pairing.handle(client, "server/pair-init", server_init)
      {:send, [{"server/pair-auth", auth}], server} = Server.submit_pin(server, pin)

      {:send, [{"client/pair-auth", client_auth}], client} =
        Pairing.handle(client, "server/pair-auth", auth)

      {:send, [{"server/pair-confirm", confirm}], server} =
        Server.handle(server, "client/pair-auth", client_auth)

      {:send, [{"client/pair-confirm", client_confirm}, _finalize], _client} =
        Pairing.handle(client, "server/pair-confirm", confirm)

      # The PAKE itself still succeeds — the PIN matched — so the mismatch
      # only surfaces when nonce_B is revealed.
      assert Server.handle(server, "client/pair-confirm", client_confirm) ==
               {:error, :commit_mismatch}
    end

    test "a flipped bit in the server tag is rejected" do
      %{client: client, server_confirm: confirm} = pair([])
      <<first, rest::binary>> = unb64(confirm["server_kc"])
      flipped = %{confirm | "server_kc" => b64(<<Bitwise.bxor(first, 1), rest::binary>>)}

      assert {:abort, :pin_mismatch, _msgs, _client} =
               Pairing.handle(client, "server/pair-confirm", flipped)
    end

    test "a server that reflects our own share back is rejected" do
      %{client: client} = pair([])
      # Ya replaced by Yb: the tag the attacker can compute is Tb, not Ta.
      reflected = Pairing.confirmation_tag(:crypto.strong_rand_bytes(64), <<0::256>>, "server")

      assert {:abort, :pin_mismatch, _msgs, _client} =
               Pairing.handle(client, "server/pair-confirm", %{"server_kc" => b64(reflected)})
    end

    test "a tampered wrapped_psk fails to unwrap" do
      %{client: client, server: server, server_confirm: confirm} = pair([])

      {:send, [_confirm, {"client/pair-finalize", finalize}], _client} =
        Pairing.handle(client, "server/pair-confirm", confirm)

      <<first, rest::binary>> = unb64(finalize["wrapped_psk"])
      tampered = %{finalize | "wrapped_psk" => b64(<<Bitwise.bxor(first, 1), rest::binary>>)}

      assert Server.handle(server, "client/pair-finalize", tampered) ==
               {:error, :psk_unwrap_failed}
    end
  end

  describe "sid binding" do
    test "a server on a different handshake hash cannot produce a valid Ta" do
      %{client: client, server_confirm: confirm} =
        pair_with_server_override(handshake_hash: :crypto.strong_rand_bytes(32))

      assert {:abort, :pin_mismatch, _msgs, _client} =
               Pairing.handle(client, "server/pair-confirm", confirm)
    end

    test "a replayed attempt counter breaks the tags too" do
      %{client: client, server_confirm: confirm} = pair_with_server_override(pairing_index: 2)

      assert {:abort, :pin_mismatch, _msgs, _client} =
               Pairing.handle(client, "server/pair-confirm", confirm)
    end
  end

  describe "abort and error handling" do
    test "a peer pair/abort ends the attempt with its reason" do
      {:ok, _msgs, client} = Pairing.start(client_opts())

      assert {:aborted, :user_cancelled, client} =
               Pairing.handle(client, "pair/abort", %{"reason" => "user_cancelled"})

      assert Pairing.stage(client) == {:failed, {:peer_abort, :user_cancelled}}
    end

    test "an unrecognised abort reason is still surfaced" do
      {:ok, _msgs, client} = Pairing.start(client_opts())

      assert {:aborted, {:unknown, "who_knows"}, _client} =
               Pairing.handle(client, "pair/abort", %{"reason" => "who_knows"})
    end

    test "abort/2 builds the wire message for caller-owned failures" do
      {:ok, _msgs, client} = Pairing.start(client_opts())

      assert {:abort, :attempt_timeout, [{"pair/abort", payload}], client} =
               Pairing.abort(client, :attempt_timeout)

      assert payload == %{"reason" => "attempt_timeout"}
      assert Pairing.stage(client) == {:failed, :attempt_timeout}
      assert Pairing.attempt_timeout_ms() == 120_000
    end

    test "an out-of-order message is a protocol error" do
      {:ok, _msgs, client} = Pairing.start(client_opts())

      assert {:error, {:unexpected_message, "server/pair-confirm", :awaiting_server_init}, client} =
               Pairing.handle(client, "server/pair-confirm", %{"server_kc" => b64(<<0::512>>)})

      assert {:failed, _reason} = Pairing.stage(client)
    end

    test "malformed fields are reported by wire key" do
      {:ok, _msgs, client} = Pairing.start(client_opts())

      for payload <- [%{}, %{"nonce_A" => "not base64!!"}, %{"nonce_A" => b64(<<0::64>>)}] do
        assert {:error, {:malformed_field, "nonce_A"}, _client} =
                 Pairing.handle(client, "server/pair-init", payload)
      end
    end

    test "base64 padding on the wire is tolerated" do
      {:ok, _msgs, client} = Pairing.start(client_opts())
      padded = Base.url_encode64(@kat_nonce_a, padding: true)

      assert {:pin, _pin, _client} =
               Pairing.handle(client, "server/pair-init", %{"nonce_A" => padded})
    end

    test "a low-order pake_msg_1 aborts the PAKE" do
      {:ok, _msgs, client} = Pairing.start(client_opts())

      {:pin, _pin, client} =
        Pairing.handle(client, "server/pair-init", %{"nonce_A" => b64(@kat_nonce_a)})

      assert {:error, {:invalid_share, "pake_msg_1"}, _client} =
               Pairing.handle(client, "server/pair-auth", %{"pake_msg_1" => b64(<<0::256>>)})
    end
  end

  describe "start/1 option validation" do
    test "rejects a bad handshake hash, counter, suite, PSK, nonce or PIN length" do
      assert {:error, {:invalid_handshake_hash, nil}} =
               Pairing.start(pairing_index: 1, suite: @chacha)

      assert {:error, {:invalid_pairing_index, -1}} =
               Pairing.start(client_opts(pairing_index: -1))

      assert {:error, {:unsupported_suite, "25519_Bogus"}} =
               Pairing.start(client_opts(suite: "25519_Bogus"))

      assert {:error, {:invalid_psk, 8}} = Pairing.start(client_opts(psk: <<0::64>>))
      assert {:error, {:invalid_nonce, 8}} = Pairing.start(client_opts(nonce_b: <<0::64>>))
      assert {:error, {:invalid_pin_length, 3}} = Pairing.start(client_opts(pin_length: 3))

      assert {:error, {:unsupported_method, :gesture}} =
               Pairing.start(client_opts(method: :gesture))
    end
  end

  # Same drive as `pair/2` but with the server deliberately bound to a
  # different sid input than the client.
  defp pair_with_server_override(override) do
    client_opts = client_opts()

    server_opts =
      client_opts
      |> Keyword.take([:handshake_hash, :pairing_index, :suite, :pin_length])
      |> Keyword.merge(override)

    {:ok, [{"client/pair-init", init}], client} = Pairing.start(client_opts)
    server = Server.start(server_opts)

    {:send, [{"server/pair-init", server_init}], server} =
      Server.handle(server, "client/pair-init", init)

    {:pin, pin, client} = Pairing.handle(client, "server/pair-init", server_init)
    {:send, [{"server/pair-auth", auth}], server} = Server.submit_pin(server, pin)

    {:send, [{"client/pair-auth", client_auth}], client} =
      Pairing.handle(client, "server/pair-auth", auth)

    {:send, [{"server/pair-confirm", confirm}], _server} =
      Server.handle(server, "client/pair-auth", client_auth)

    %{client: client, server_confirm: confirm}
  end
end
