defmodule UniversalProxy.Sendspin.NoiseTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Sendspin.Noise

  @client_init ~s({"client_id":"Zm9v","version":1,"cipher_suite":"25519_ChaChaPoly_SHA256"})
  @server_init ~s({"server_id":"YmFy","version":1,"cipher_suite":"25519_ChaChaPoly_SHA256"})
  @prologue @client_init <> @server_init

  setup do
    {client_pub, client_priv} = Noise.generate_static_keypair()
    {server_pub, server_priv} = Noise.generate_static_keypair()

    %{
      client: {client_pub, client_priv},
      server: {server_pub, server_priv},
      psk: :crypto.strong_rand_bytes(32)
    }
  end

  # The Music Assistant side, driven through decibel directly so the test
  # exercises our wrapper against an independent Noise implementation path.
  # Decibel keys its process-dictionary state by ref, so the initiator and the
  # responder coexist in this one test process without interfering.
  defp start_server(ctx, opts) do
    suite = Keyword.get(opts, :suite, "25519_ChaChaPoly_SHA256")
    {:ok, protocol} = Noise.protocol_name(suite)
    {client_pub, _} = ctx.client

    keys = %{
      s: ctx.server,
      rs: client_pub,
      psks: [Keyword.get(opts, :psk, ctx.psk)],
      prologue: Keyword.get(opts, :prologue, @prologue)
    }

    Decibel.new(protocol, :ini, keys)
  end

  defp start_client(ctx, opts) do
    {server_pub, _} = ctx.server

    Noise.start(
      suite: Keyword.get(opts, :suite, "25519_ChaChaPoly_SHA256"),
      static_keypair: ctx.client,
      remote_static_key: server_pub,
      psk: Keyword.get(opts, :psk, ctx.psk),
      prologue: Keyword.get(opts, :prologue, @prologue)
    )
  end

  defp complete_handshake(ctx, opts \\ []) do
    ini = start_server(ctx, opts)
    {:ok, session} = start_client(ctx, opts)

    msg1 = IO.iodata_to_binary(Decibel.handshake_encrypt(ini))
    {:ok, ""} = Noise.read_handshake(session, msg1)
    {:ok, msg2} = Noise.write_handshake(session)
    Decibel.handshake_decrypt(ini, msg2)

    {ini, session}
  end

  describe "suite negotiation" do
    test "maps both Sendspin suites to KKpsk2 protocol names" do
      assert {:ok, "Noise_KKpsk2_25519_ChaChaPoly_SHA256"} =
               Noise.protocol_name("25519_ChaChaPoly_SHA256")

      assert {:ok, "Noise_KKpsk2_25519_AESGCM_SHA256"} =
               Noise.protocol_name("25519_AESGCM_SHA256")

      assert Noise.supported_suites() == [
               "25519_AESGCM_SHA256",
               "25519_ChaChaPoly_SHA256"
             ]
    end

    test "rejects an unknown suite", ctx do
      assert {:error, {:unsupported_suite, "25519_AESGCM_SHA512"}} =
               Noise.protocol_name("25519_AESGCM_SHA512")

      assert {:error, {:unsupported_suite, nil}} = start_client(ctx, suite: nil)
    end
  end

  describe "sentinel PSK" do
    test "matches the published constant byte for byte" do
      # The literal from the spec (`connection.md`) — pinned here rather than
      # recomputed, so a change to the label string can't silently redefine
      # what "unpaired" means on the wire.
      assert Base.encode16(Noise.sentinel_psk(), case: :lower) ==
               "1b5e24dbc1aed95fc2a5a338a90c05df44bd10f5ec1f4cd66cbf86272767b9d3"

      assert UniversalProxy.Sendspin.Pairing.psk_id_for(Noise.sentinel_psk()) ==
               "GFsV9tLaSQm9HcFWpKsgYQOr7wFTvNUtkmFwuVz3zoo"
    end
  end

  describe "option validation" do
    test "rejects malformed keys", ctx do
      {server_pub, _} = ctx.server

      base = [
        suite: "25519_ChaChaPoly_SHA256",
        static_keypair: ctx.client,
        remote_static_key: server_pub,
        psk: ctx.psk,
        prologue: @prologue
      ]

      assert {:error, {:invalid_key, :static_keypair}} =
               Noise.start(Keyword.put(base, :static_keypair, <<0::256>>))

      assert {:error, {:invalid_key, :remote_static_key}} =
               Noise.start(Keyword.put(base, :remote_static_key, <<0::128>>))

      assert {:error, {:invalid_key, :psk}} = Noise.start(Keyword.put(base, :psk, nil))
    end

    test "rejects a keypair with a valid 32-byte pub but a wrong-length priv", ctx do
      {server_pub, _} = ctx.server
      {client_pub, _valid_priv} = ctx.client

      base = [
        suite: "25519_ChaChaPoly_SHA256",
        static_keypair: {client_pub, <<1, 2, 3>>},
        remote_static_key: server_pub,
        psk: ctx.psk,
        prologue: @prologue
      ]

      assert {:error, {:invalid_key, :static_keypair}} = Noise.start(base)
    end
  end

  for suite <- ["25519_ChaChaPoly_SHA256", "25519_AESGCM_SHA256"] do
    describe "handshake and transport (#{suite})" do
      test "completes against a decibel initiator", ctx do
        suite = unquote(suite)
        ini = start_server(ctx, suite: suite)
        {:ok, session} = start_client(ctx, suite: suite)

        refute Noise.finished?(session)
        assert Noise.handshake_hash(session) == nil
        assert {:error, :handshake_incomplete} = Noise.encrypt(session, "too early")

        msg1 = IO.iodata_to_binary(Decibel.handshake_encrypt(ini))
        assert {:ok, ""} = Noise.read_handshake(session, msg1)
        refute Noise.finished?(session)

        assert {:ok, msg2} = Noise.write_handshake(session)
        assert Decibel.handshake_decrypt(ini, msg2) == ""

        assert Noise.finished?(session)
        assert {:error, :handshake_complete} = Noise.write_handshake(session)
      end

      test "both sides derive the same handshake hash", ctx do
        {ini, session} = complete_handshake(ctx, suite: unquote(suite))

        hash = Noise.handshake_hash(session)
        assert byte_size(hash) == 32
        assert hash == Decibel.get_handshake_hash(ini)
      end

      test "transport messages round-trip in both directions", ctx do
        {ini, session} = complete_handshake(ctx, suite: unquote(suite))

        # Multiple messages per direction: each cipher advances its own nonce,
        # so identical plaintexts must produce distinct ciphertexts.
        outbound = for n <- 1..4, do: <<0x0C, n::64>>

        ciphertexts =
          for frame <- outbound do
            assert {:ok, ct} = Noise.encrypt(session, frame)
            assert IO.iodata_to_binary(Decibel.decrypt(ini, ct)) == frame
            ct
          end

        assert length(Enum.uniq(ciphertexts)) == 4

        for n <- 1..4 do
          frame = <<0x00, "server/hello ", n>>
          ct = IO.iodata_to_binary(Decibel.encrypt(ini, frame))
          assert {:ok, ^frame} = Noise.decrypt(session, ct)
        end

        repeated = IO.iodata_to_binary(Decibel.encrypt(ini, "same"))
        assert {:ok, "same"} = Noise.decrypt(session, repeated)
      end
    end
  end

  describe "failure modes" do
    test "a wrong PSK breaks message 2 for the initiator", ctx do
      ini = start_server(ctx, [])
      {:ok, session} = start_client(ctx, psk: :crypto.strong_rand_bytes(32))

      msg1 = IO.iodata_to_binary(Decibel.handshake_encrypt(ini))

      # Message 1 predates the psk2 mix, so it still authenticates for us.
      assert {:ok, ""} = Noise.read_handshake(session, msg1)
      assert {:ok, msg2} = Noise.write_handshake(session)

      assert_raise Decibel.DecryptionError, fn -> Decibel.handshake_decrypt(ini, msg2) end
    end

    test "a prologue mismatch fails message 1 for us", ctx do
      ini = start_server(ctx, [])
      {:ok, session} = start_client(ctx, prologue: @client_init <> "{}")

      msg1 = IO.iodata_to_binary(Decibel.handshake_encrypt(ini))
      assert {:error, :decrypt_failed} = Noise.read_handshake(session, msg1)
    end

    test "an unexpected server static key fails message 1", ctx do
      {other_pub, _} = Noise.generate_static_keypair()
      ini = start_server(ctx, [])

      {:ok, session} =
        Noise.start(
          suite: "25519_ChaChaPoly_SHA256",
          static_keypair: ctx.client,
          remote_static_key: other_pub,
          psk: ctx.psk,
          prologue: @prologue
        )

      msg1 = IO.iodata_to_binary(Decibel.handshake_encrypt(ini))
      assert {:error, :decrypt_failed} = Noise.read_handshake(session, msg1)
    end

    test "a truncated handshake message is reported, not raised", ctx do
      ini = start_server(ctx, [])
      {:ok, session} = start_client(ctx, [])

      <<short::binary-size(8), _::binary>> = IO.iodata_to_binary(Decibel.handshake_encrypt(ini))
      assert {:error, :malformed_handshake} = Noise.read_handshake(session, short)
    end

    test "a tampered transport ciphertext fails to decrypt", ctx do
      {ini, session} = complete_handshake(ctx)

      <<head, rest::binary>> = IO.iodata_to_binary(Decibel.encrypt(ini, "server/hello"))
      tampered = <<Bitwise.bxor(head, 0xFF), rest::binary>>

      assert {:error, :decrypt_failed} = Noise.decrypt(session, tampered)

      # A too-short frame never reaches the AEAD tag check.
      assert {:error, :decrypt_failed} = Noise.decrypt(session, <<1, 2, 3>>)
    end
  end

  describe "process ownership" do
    test "raises when used outside the owning process", ctx do
      {_ini, session} = complete_handshake(ctx)

      task =
        Task.async(fn ->
          assert_raise ArgumentError, ~r/process dictionary/, fn ->
            Noise.encrypt(session, "nope")
          end
        end)

      Task.await(task)
    end

    test "two sessions coexist in one process", ctx do
      {_ini_a, session_a} = complete_handshake(ctx)
      {_ini_b, session_b} = complete_handshake(ctx, suite: "25519_AESGCM_SHA256")

      assert Noise.handshake_hash(session_a) != Noise.handshake_hash(session_b)
      assert {:ok, _} = Noise.encrypt(session_a, "a")
      assert {:ok, _} = Noise.encrypt(session_b, "b")
    end

    test "close/1 discards the session", ctx do
      {_ini, session} = complete_handshake(ctx)
      assert :ok = Noise.close(session)
    end
  end
end
