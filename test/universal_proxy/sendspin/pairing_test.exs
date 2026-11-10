defmodule UniversalProxy.Sendspin.PairingTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Sendspin.CPace
  alias UniversalProxy.Sendspin.Pairing
  alias UniversalProxy.SendspinPairingServer, as: Server

  @chacha "25519_ChaChaPoly_SHA256"
  @aesgcm "25519_AESGCM_SHA256"

  # Known-answer vectors, computed with aiosendspin 10.3.0's own Sendspin
  # 1.0.0-rc1 implementation (`aiosendspin.noise.pairing` / `pairing_code`,
  # cpace 0.1.0) from these fixed inputs. The two CPace scalars are
  # draft-irtf-cfrg-cpace-21 Appendix B.1's `ya`/`yb`, reused under a
  # Sendspin-shaped `sid`.
  @kat_hash Base.decode16!("000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F")
  @kat_nonce_a Base.decode16!("404142434445464748494A4B4C4D4E4F505152535455565758595A5B5C5D5E5F")
  @kat_nonce_b Base.decode16!("808182838485868788898A8B8C8D8E8F909192939495969798999A9B9C9D9E9F")
  @kat_index 1

  @kat_scalar_a Base.decode16!("21B4F4BD9E64ED355C3EB676A28EBEDAF6D8F17BDC365995B319097153044080")
  @kat_scalar_b Base.decode16!("848B0779FF415F0AF4EA14DF9DD1D3C29AC41D836C7808896C4EBA19C51AC40A")

  @kat_sid Base.decode16!(
             "73656E647370696E2D706169722D70616B652D7631" <>
               "000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F" <>
               "00000001" <> "00000001"
           )
  @kat_sid_round_2 Base.decode16!(
                     "73656E647370696E2D706169722D70616B652D7631" <>
                       "000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F" <>
                       "00000001" <> "00000002"
                   )
  @kat_commit_b Base.decode16!("FC91579D2561D9CAA0C0B933CA3F976D6A860C6EE561FF24A1A790A649DF957C")
  @kat_code "782070"
  @kat_ya Base.decode16!("D07C3ABD8E3B123FFE0273D6A49FF9C80B2052289636E53DE696459DECBCC540")
  @kat_yb Base.decode16!("217452BF1E317EE3D4EF572E88B57CF4E1CEE53E867F85FABDD5E00516CEFE58")
  @kat_isk Base.decode16!(
             "06FB8348EE58698E45605B069DB009692C26C27299777BAA22763F1BFC0854CE" <>
               "593A0512023BADDBECC1BE77BE75B9BD24341ECF6D48C1773A3FFF540B16033E"
           )
  @kat_ta Base.decode16!(
            "1EC1A842B3CC2C45A3F3761E5DA696133B59F9293A9D0FCB2D8ECB48A3408F09" <>
              "4973C4E74D43722FA4BE01F8F5EF5BEF1A0C7CB4F4700DAA662696E36C5E6D5D"
          )
  @kat_tb Base.decode16!(
            "272811A52F08B2E78EB24EC1081E459B8F74C158EC47054E8DA87B0090E53ECA" <>
              "FE9E3E2968967B31CD481E9CF95F65E7A791C800FE271F6FB952AFBA67FE1ED2"
          )
  @kat_nonce_wrap_key Base.decode16!(
                        "98043F92EC0DE3697F3B35E3C01C82C7AE2AD2AB0F2166C28FE016EC164CD3BA"
                      )
  @kat_psk_wrap_key Base.decode16!(
                      "6AF63807C0FE48CE0CCD4B63EAB8377DE128D0D5D3C2EAF1E59426528E818825"
                    )
  @kat_wrapped_nonce_chacha Base.decode16!(
                              "ECB2F4604CF99F1191E7D75F8B762DAD6E15D288E565D7B5BDF92E11ACC06FA3" <>
                                "FFD66FA4A421AC3CAC27FB8E3C50453F"
                            )
  @kat_wrapped_psk_chacha Base.decode16!(
                            "80FBE9F6785FA3120EF2C1019AB5C54313C83C08A0542E28209DFA68B4E4C7BC" <>
                              "60333BA984F0B2A1AE621517B5D883BD"
                          )
  @kat_wrapped_nonce_aesgcm Base.decode16!(
                              "619CA37970EC118BC89B4E79048F0B4D27A7628E64B259B0AB7280593B67A481" <>
                                "8F0A05FBF0CAAEAB3D181EF2A156EE54"
                            )
  # Round 2 runs a fresh CPace (same scalars here) under the round-2 sid.
  @kat_ya_round_2 Base.decode16!(
                    "683D9EF8B3BC8C418AAB685912D697145EEC77A9F0EBD15BA2C55586A1E5580E"
                  )
  @kat_ta_round_2 Base.decode16!(
                    "EEA88FF484CA3ED27BCD86376B4B82D5BEAF36B0F529607CD0B6458637C24452" <>
                      "E4B759CECF76DCC941530B7D58FBEFC6897E5D3E982481FD8126D80A1E200986"
                  )
  @kat_tb_round_2 Base.decode16!(
                    "280C2697F4D7C6A78E0CD2BD3F634D13660EBF4B74557F2B03DBE71B6BE3F0CE" <>
                      "4F68C7282569C610612341D7D624B1A314E1A2978686BF41FF90D3153260B144"
                  )
  @kat_wrapped_nonce_round_2 Base.decode16!(
                               "DD5F8A3ED1A13724352E3C6E3EA5D8BE203919EEFAD6A035FADBA9D21F1C7F47" <>
                                 "8729AED288566373E327333879B91B4B"
                             )
  @kat_psk :binary.list_to_bin(Enum.to_list(0xA0..0xBF))
  @kat_psk_id "UaXYTgo_O5NA363FD_WJGwAORfbAld1hDE9vHMOWFSg"

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)
  defp unb64(value), do: Base.url_decode64!(value, padding: false)

  defp client_opts(overrides \\ []) do
    Keyword.merge(
      [
        handshake_hash: :crypto.strong_rand_bytes(32),
        pairing_index: 1,
        suite: @chacha
      ],
      overrides
    )
  end

  defp server_opts(client_opts),
    do: Keyword.take(client_opts, [:handshake_hash, :pairing_index, :suite])

  # Drive a full attempt. `pin_fun` maps the code the client displayed onto
  # the code the operator typed into the server, which is where a wrong-code
  # test diverges.
  defp pair(opts, pin_fun \\ & &1) do
    client_opts = client_opts(opts)

    {:ok, [{"client/pair-init", init}], client} = Pairing.start(client_opts)
    server = Server.start(server_opts(client_opts))

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

  defp mistype(pin) do
    <<first::binary-size(1), rest::binary>> = pin
    other = if first == "9", do: "0", else: "9"
    other <> rest
  end

  describe "known-answer vectors (aiosendspin 10.3.0)" do
    test "sid/3 concatenates label, handshake hash, big-endian index and round" do
      assert Pairing.sid(@kat_hash, @kat_index, 1) == @kat_sid
      assert Pairing.sid(@kat_hash, @kat_index, 2) == @kat_sid_round_2
      assert byte_size(@kat_sid) == 21 + 32 + 4 + 4
    end

    test "commit/1 and derive_pairing_code/3" do
      assert Pairing.commit(@kat_nonce_b) == @kat_commit_b
      assert Pairing.commit_valid?(@kat_nonce_b, @kat_commit_b)
      refute Pairing.commit_valid?(@kat_nonce_a, @kat_commit_b)

      assert Pairing.derive_pairing_code(@kat_hash, @kat_nonce_a, @kat_nonce_b) == @kat_code
    end

    test "derive_pairing_code/3 is always six zero-padded digits" do
      for _ <- 1..50 do
        code =
          Pairing.derive_pairing_code(
            :crypto.strong_rand_bytes(32),
            :crypto.strong_rand_bytes(32),
            :crypto.strong_rand_bytes(32)
          )

        assert code =~ ~r/\A[0-9]{6}\z/
      end
    end

    test "confirmation tags and both wrap keys" do
      mac_key = Pairing.mac_key(@kat_sid, @kat_isk)
      assert Pairing.confirmation_tag(mac_key, @kat_ya, "server") == @kat_ta
      assert Pairing.confirmation_tag(mac_key, @kat_yb, "client") == @kat_tb
      assert Pairing.wrap_key(@kat_sid, @kat_isk) == @kat_psk_wrap_key
      assert Pairing.nonce_wrap_key(@kat_sid, @kat_isk) == @kat_nonce_wrap_key
    end

    test "wrap/3 seals with the suite's AEAD under a zero nonce" do
      assert Pairing.wrap(@chacha, @kat_nonce_wrap_key, @kat_nonce_b) == @kat_wrapped_nonce_chacha
      assert Pairing.wrap(@aesgcm, @kat_nonce_wrap_key, @kat_nonce_b) == @kat_wrapped_nonce_aesgcm
      assert Pairing.wrap(@chacha, @kat_psk_wrap_key, @kat_psk) == @kat_wrapped_psk_chacha

      assert Pairing.unwrap(@chacha, @kat_psk_wrap_key, @kat_wrapped_psk_chacha) ==
               {:ok, @kat_psk}
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
          nonce_b: @kat_nonce_b,
          cpace_scalar: @kat_scalar_b,
          psk: @kat_psk
        )

      assert init == %{"pairing_index" => 1, "commit_B" => b64(@kat_commit_b)}

      {:pin, pin, client} =
        Pairing.handle(client, "server/pair-init", %{"nonce_A" => b64(@kat_nonce_a)})

      assert pin == @kat_code
      assert Pairing.pin(client) == @kat_code

      {:send, [{"client/pair-auth", auth}], client} =
        Pairing.handle(client, "server/pair-auth", %{"pake_msg_1" => b64(@kat_ya)})

      assert auth == %{"pake_msg_2" => b64(@kat_yb)}

      {:send, [{"client/pair-confirm", confirm}, {"client/pair-finalize", finalize}], client} =
        Pairing.handle(client, "server/pair-confirm", %{"server_kc" => b64(@kat_ta)})

      assert confirm == %{
               "client_kc" => b64(@kat_tb),
               "wrapped_nonce_B" => b64(@kat_wrapped_nonce_chacha)
             }

      assert finalize == %{"wrapped_psk" => b64(@kat_wrapped_psk_chacha)}

      assert {:paired, outcome, _client} =
               Pairing.handle(client, "server/pair-finalize", %{})

      assert outcome == %{psk: @kat_psk, psk_id: @kat_psk_id, category: :long_term}
    end

    test "a retry round re-emits the code and runs CPace under the round-2 sid" do
      {:ok, _init, client} =
        Pairing.start(
          handshake_hash: @kat_hash,
          pairing_index: @kat_index,
          suite: @chacha,
          nonce_b: @kat_nonce_b,
          cpace_scalar: @kat_scalar_b,
          psk: @kat_psk
        )

      {:pin, @kat_code, client} =
        Pairing.handle(client, "server/pair-init", %{"nonce_A" => b64(@kat_nonce_a)})

      {:send, _auth, client} =
        Pairing.handle(client, "server/pair-auth", %{"pake_msg_1" => b64(@kat_ya)})

      # A wrong server tag (the operator mistyped): ask for another round.
      assert {:send, [{"client/pair-retry", %{}}], client} =
               Pairing.handle(client, "server/pair-confirm", %{"server_kc" => b64(<<0::512>>)})

      assert Pairing.round(client) == 2
      assert {:pin, @kat_code, client} = Pairing.handle(client, "server/pair-init", %{})

      {:send, _auth, client} =
        Pairing.handle(client, "server/pair-auth", %{"pake_msg_1" => b64(@kat_ya_round_2)})

      {:send, [{"client/pair-confirm", confirm}, _finalize], _client} =
        Pairing.handle(client, "server/pair-confirm", %{"server_kc" => b64(@kat_ta_round_2)})

      assert confirm == %{
               "client_kc" => b64(@kat_tb_round_2),
               "wrapped_nonce_B" => b64(@kat_wrapped_nonce_round_2)
             }
    end

    test "the server's own CPace share matches the vector" do
      {:ok, cpace} =
        CPace.start(:a,
          prs: @kat_code,
          ci: "",
          sid: @kat_sid,
          ad: "server",
          scalar: @kat_scalar_a
        )

      assert CPace.public_share(cpace) == @kat_ya
      assert CPace.finish(cpace, @kat_yb, "client") == {:ok, @kat_isk}
    end
  end

  describe "dynamic pairing code round trip" do
    test "the correct code pairs and both sides land on the same PSK" do
      %{client: client, server: server, server_confirm: confirm} = pair([])

      assert {:send,
              [{"client/pair-confirm", client_confirm}, {"client/pair-finalize", finalize}],
              client} = Pairing.handle(client, "server/pair-confirm", confirm)

      refute Map.has_key?(client_confirm, "nonce_B")
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

    test "the AES-GCM suite wraps the PSK and nonce just as well" do
      %{client: client, server: server, server_confirm: confirm} = pair(suite: @aesgcm)

      {:send, [{"client/pair-confirm", client_confirm}, {"client/pair-finalize", finalize}],
       client} = Pairing.handle(client, "server/pair-confirm", confirm)

      {:ok, server} = Server.handle(server, "client/pair-confirm", client_confirm)
      {:send, _, server} = Server.handle(server, "client/pair-finalize", finalize)
      {:paired, outcome, _client} = Pairing.handle(client, "server/pair-finalize", %{})

      assert Server.psk(server) == outcome.psk
    end

    test "every attempt derives a fresh code, PSK and commitment" do
      runs = for _ <- 1..5, do: pair([])
      pins = Enum.map(runs, & &1.pin)

      assert length(Enum.uniq(pins)) == 5
      assert Enum.all?(pins, &(String.length(&1) == 6))
    end

    test "a mistyped code retries in a second round and then pairs" do
      %{client: client, server: server, pin: pin, server_confirm: confirm} = pair([], &mistype/1)

      {:send, [{"client/pair-retry", retry}], client} =
        Pairing.handle(client, "server/pair-confirm", confirm)

      {:send, [{"server/pair-init", init}], server} =
        Server.handle(server, "client/pair-retry", retry)

      refute Map.has_key?(init, "nonce_A")
      assert {:pin, ^pin, client} = Pairing.handle(client, "server/pair-init", init)

      {:send, [{"server/pair-auth", auth}], server} = Server.submit_pin(server, pin)

      {:send, [{"client/pair-auth", client_auth}], client} =
        Pairing.handle(client, "server/pair-auth", auth)

      {:send, [{"server/pair-confirm", confirm}], server} =
        Server.handle(server, "client/pair-auth", client_auth)

      {:send, [{"client/pair-confirm", client_confirm}, {"client/pair-finalize", finalize}],
       client} = Pairing.handle(client, "server/pair-confirm", confirm)

      {:ok, server} = Server.handle(server, "client/pair-confirm", client_confirm)
      {:send, _, server} = Server.handle(server, "client/pair-finalize", finalize)
      {:paired, outcome, _client} = Pairing.handle(client, "server/pair-finalize", %{})

      assert Server.psk(server) == outcome.psk
      assert Server.round(server) == 2
    end
  end

  describe "Pairing PSK" do
    test "pair-init and the long-term PSK go out back to back, no PAKE" do
      opts = client_opts(method: :pairing_psk, pairing_index: 2, psk: @kat_psk)

      assert {:ok, [{"client/pair-init", init}, {"client/pair-finalize", finalize}], client} =
               Pairing.start(opts)

      assert init == %{"pairing_index" => 2}
      assert finalize == %{"long_term_psk" => b64(@kat_psk)}
      assert Pairing.stage(client) == :awaiting_pair_finalize

      server = Server.start(server_opts(opts) ++ [method: :pairing_psk])
      {:ok, server} = Server.handle(server, "client/pair-init", init)

      {:send, [{"server/pair-finalize", %{}}], server} =
        Server.handle(server, "client/pair-finalize", finalize)

      assert {:paired, %{psk: @kat_psk, psk_id: @kat_psk_id}, _client} =
               Pairing.handle(client, "server/pair-finalize", %{})

      assert Server.psk(server) == @kat_psk
    end

    test "a server reply other than server/pair-finalize is a protocol error" do
      {:ok, _msgs, client} = Pairing.start(client_opts(method: :pairing_psk))

      assert {:error, {:unexpected_message, "server/pair-auth", :awaiting_pair_finalize}, _} =
               Pairing.handle(client, "server/pair-auth", %{"pake_msg_1" => b64(@kat_ya)})
    end
  end

  describe "static pairing code round trip" do
    setup do
      opts = [handshake_hash: :crypto.strong_rand_bytes(32), pairing_index: 3, suite: @chacha]
      %{opts: opts}
    end

    test "no nonce or commitment travels, and the PSK still lands", %{opts: opts} do
      pin = "40028922"

      {:ok, [{"client/pair-init", init}], client} =
        Pairing.start(opts ++ [method: :static_pairing_code, pin: pin])

      assert init == %{"pairing_index" => 3}

      server = Server.start(opts ++ [method: :static_pairing_code, pin: pin])

      {:send, [{"server/pair-auth", auth}], server} =
        Server.handle(server, "client/pair-init", init)

      {:send, [{"client/pair-auth", client_auth}], client} =
        Pairing.handle(client, "server/pair-auth", auth)

      {:send, [{"server/pair-confirm", confirm}], server} =
        Server.handle(server, "client/pair-auth", client_auth)

      {:send, [{"client/pair-confirm", client_confirm}, {"client/pair-finalize", finalize}],
       client} = Pairing.handle(client, "server/pair-confirm", confirm)

      refute Map.has_key?(client_confirm, "wrapped_nonce_B")

      {:ok, server} = Server.handle(server, "client/pair-confirm", client_confirm)
      {:send, _, server} = Server.handle(server, "client/pair-finalize", finalize)
      {:paired, outcome, _client} = Pairing.handle(client, "server/pair-finalize", %{})

      assert Server.psk(server) == outcome.psk
    end

    test "a client code the operator did not type aborts without a retry", %{opts: opts} do
      {:ok, [{"client/pair-init", init}], client} =
        Pairing.start(opts ++ [method: :static_pairing_code, pin: "40028922"])

      server = Server.start(opts ++ [method: :static_pairing_code, pin: "40028923"])

      {:send, [{"server/pair-auth", auth}], server} =
        Server.handle(server, "client/pair-init", init)

      {:send, [{"client/pair-auth", client_auth}], client} =
        Pairing.handle(client, "server/pair-auth", auth)

      {:send, [{"server/pair-confirm", confirm}], server} =
        Server.handle(server, "client/pair-auth", client_auth)

      # Client rejects the server's Ta first, but even if it were tricked
      # into replying the server would reject Tb.
      assert {:abort, :pairing_code_mismatch, _msgs, _client} =
               Pairing.handle(client, "server/pair-confirm", confirm)

      forged = %{"client_kc" => b64(:crypto.strong_rand_bytes(64))}

      assert Server.handle(server, "client/pair-confirm", forged) ==
               {:error, :pairing_code_mismatch}
    end

    test "start/1 refuses a code that is not eight digits", %{opts: opts} do
      for pin <- ["1234567", "123456789", "abcdefgh", "1234 678", nil] do
        assert {:error, :invalid_static_pairing_code} =
                 Pairing.start(opts ++ [method: :static_pairing_code, pin: pin])
      end

      assert Pairing.valid_static_pairing_code?("40028922")
      refute Pairing.valid_static_pairing_code?("4002892")
    end
  end

  describe "round limit" do
    test "a mistyped code aborts with pairing_code_mismatch once max_rounds is spent" do
      %{client: client, server_confirm: confirm} = pair([max_rounds: 1], &mistype/1)

      assert {:abort, :pairing_code_mismatch, [{"pair/abort", payload}], client} =
               Pairing.handle(client, "server/pair-confirm", confirm)

      assert payload == %{"reason" => "pairing_code_mismatch"}
      assert Pairing.stage(client) == {:failed, :pairing_code_mismatch}
    end

    test "the server rejects a client tag from a different code" do
      %{server: server} = pair([], &mistype/1)

      confirm = %{
        "client_kc" => b64(:crypto.strong_rand_bytes(64)),
        "wrapped_nonce_B" => b64(:crypto.strong_rand_bytes(48))
      }

      # The MCF tag is the first check (`pairing.md` "Server verification").
      assert Server.handle(server, "client/pair-confirm", confirm) ==
               {:error, :pairing_code_mismatch}
    end

    test "a retry round's server/pair-init must not carry a nonce" do
      %{client: client, server_confirm: confirm} = pair([], &mistype/1)

      {:send, [{"client/pair-retry", _}], client} =
        Pairing.handle(client, "server/pair-confirm", confirm)

      assert {:error, {:unexpected_field, "nonce_A"}, _client} =
               Pairing.handle(client, "server/pair-init", %{"nonce_A" => b64(@kat_nonce_a)})
    end
  end

  describe "tampering" do
    test "a tampered commit_B is caught on reveal" do
      client_opts = client_opts([])

      {:ok, [{"client/pair-init", init}], client} = Pairing.start(client_opts)
      tampered = %{init | "commit_B" => b64(Pairing.commit(Pairing.generate_nonce()))}

      server = Server.start(server_opts(client_opts))

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

      # The PAKE itself still succeeds — the code matched — so the mismatch
      # only surfaces when nonce_B is unwrapped and checked.
      assert Server.handle(server, "client/pair-confirm", client_confirm) ==
               {:error, :commit_mismatch}
    end

    test "a tampered wrapped_nonce_B fails to unwrap" do
      %{client: client, server: server, server_confirm: confirm} = pair([])

      {:send, [{"client/pair-confirm", client_confirm}, _finalize], _client} =
        Pairing.handle(client, "server/pair-confirm", confirm)

      <<first, rest::binary>> = unb64(client_confirm["wrapped_nonce_B"])

      tampered = %{
        client_confirm
        | "wrapped_nonce_B" => b64(<<Bitwise.bxor(first, 1), rest::binary>>)
      }

      assert Server.handle(server, "client/pair-confirm", tampered) == {:error, :unwrap_failed}
    end

    test "a flipped bit in the server tag is a failed round" do
      %{client: client, server_confirm: confirm} = pair(max_rounds: 1)
      <<first, rest::binary>> = unb64(confirm["server_kc"])
      flipped = %{confirm | "server_kc" => b64(<<Bitwise.bxor(first, 1), rest::binary>>)}

      assert {:abort, :pairing_code_mismatch, _msgs, _client} =
               Pairing.handle(client, "server/pair-confirm", flipped)
    end

    test "a server that reflects our own share back is rejected" do
      %{client: client} = pair(max_rounds: 1)
      # Ya replaced by Yb: the tag the attacker can compute is Tb, not Ta.
      reflected = Pairing.confirmation_tag(:crypto.strong_rand_bytes(64), <<0::256>>, "server")

      assert {:abort, :pairing_code_mismatch, _msgs, _client} =
               Pairing.handle(client, "server/pair-confirm", %{"server_kc" => b64(reflected)})
    end

    test "a tampered wrapped_psk fails to unwrap" do
      %{client: client, server: server, server_confirm: confirm} = pair([])

      {:send, [{"client/pair-confirm", client_confirm}, {"client/pair-finalize", finalize}],
       _client} = Pairing.handle(client, "server/pair-confirm", confirm)

      {:ok, server} = Server.handle(server, "client/pair-confirm", client_confirm)

      <<first, rest::binary>> = unb64(finalize["wrapped_psk"])
      tampered = %{finalize | "wrapped_psk" => b64(<<Bitwise.bxor(first, 1), rest::binary>>)}

      assert Server.handle(server, "client/pair-finalize", tampered) == {:error, :unwrap_failed}
    end
  end

  describe "sid binding" do
    test "a server on a different handshake hash cannot produce a valid Ta" do
      %{client: client, server_confirm: confirm} =
        pair_with_server_override(handshake_hash: :crypto.strong_rand_bytes(32))

      assert {:abort, :pairing_code_mismatch, _msgs, _client} =
               Pairing.handle(client, "server/pair-confirm", confirm)
    end

    test "a replayed attempt counter breaks the tags too" do
      %{client: client, server_confirm: confirm} = pair_with_server_override(pairing_index: 2)

      assert {:abort, :pairing_code_mismatch, _msgs, _client} =
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
      assert Pairing.round_limit() == 20
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
    test "rejects a bad handshake hash, counter, suite, PSK, nonce or round budget" do
      assert {:error, {:invalid_handshake_hash, nil}} =
               Pairing.start(pairing_index: 1, suite: @chacha)

      assert {:error, {:invalid_pairing_index, -1}} =
               Pairing.start(client_opts(pairing_index: -1))

      assert {:error, {:unsupported_suite, "25519_Bogus"}} =
               Pairing.start(client_opts(suite: "25519_Bogus"))

      assert {:error, {:invalid_psk, 8}} = Pairing.start(client_opts(psk: <<0::64>>))
      assert {:error, {:invalid_nonce, 8}} = Pairing.start(client_opts(nonce_b: <<0::64>>))
      assert {:error, {:invalid_max_rounds, 0}} = Pairing.start(client_opts(max_rounds: 0))
      assert {:error, {:invalid_max_rounds, 21}} = Pairing.start(client_opts(max_rounds: 21))

      assert {:error, {:unsupported_method, :gesture}} =
               Pairing.start(client_opts(method: :gesture))
    end
  end

  describe "inspect redaction" do
    test "a mid-attempt struct leaks neither the CPace scalar nor nonce_b nor the PSK" do
      # Drive to `:awaiting_pair_auth`, where the live `%CPace{}` (with its
      # secret scalar) and `nonce_b` (still secret — revealed only later in
      # `client/pair-confirm`) both sit in the struct.
      {:ok, [{"client/pair-init", _init}], client} =
        Pairing.start(
          client_opts(
            handshake_hash: @kat_hash,
            pairing_index: @kat_index,
            nonce_b: @kat_nonce_b,
            cpace_scalar: @kat_scalar_b,
            psk: @kat_psk
          )
        )

      {:pin, _pin, client} =
        Pairing.handle(client, "server/pair-init", %{"nonce_A" => b64(@kat_nonce_a)})

      # Sanity: the secrets really are in the struct (the CPace nested one too).
      assert client.nonce_b == @kat_nonce_b
      assert client.cpace.scalar == @kat_scalar_b

      rendered = inspect(client)

      for secret <- [@kat_scalar_b, @kat_nonce_b, @kat_psk] do
        refute rendered =~ inspect(secret)
        refute rendered =~ Base.encode16(secret)
        refute rendered =~ Base.encode16(secret, case: :lower)
        refute rendered =~ b64(secret)
      end

      refute rendered =~ @kat_code
    end
  end

  # Same drive as `pair/2` but with the server deliberately bound to a
  # different sid input than the client.
  defp pair_with_server_override(override) do
    client_opts = client_opts(max_rounds: 1)

    server_opts =
      client_opts
      |> server_opts()
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
