defmodule UniversalProxy.Audio.Input.SourcePairingTest do
  # async: false for the same reason as `Audio.Input.SourceTest` — the DETS
  # table name must be an atom, so one constant atom is reused rather than
  # growing the atom table per test.
  use ExUnit.Case, async: false

  alias UniversalProxy.Audio.Input.Source
  alias UniversalProxy.Audio.Input.Store
  alias UniversalProxy.Sendspin.Pairing
  alias UniversalProxy.SendspinSourcePeer, as: Peer

  @table :audio_input_source_pairing_test
  @key {"USB Capture Card", 0x1D6B, 0x0105}
  @pin_length 6

  # The `pairing` object a server sends alongside the `pairing` activity.
  @pairing_params %{"method" => "dynamic_pin", "pin_length" => @pin_length}

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "audio_input_source_pairing_test_#{System.unique_integer([:positive])}.dets"
      )

    on_exit(fn -> File.rm(path) end)

    store =
      start_supervised!(
        {UniversalProxy.Audio.Input.Store, name: nil, table: @table, dets_path: path}
      )

    {:ok, store: store}
  end

  defp start_source!(ctx, opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:key, @key)
      |> Keyword.put_new(:alsa_device, "plughw:9,0")
      |> Keyword.put_new(:name, "USB Capture")
      |> Keyword.put_new(:store, ctx.store)
      |> Keyword.put_new(:owner, self())
      |> Keyword.put_new(:port, 0)
      |> Keyword.put_new(:time_burst_ms, 20)

    pid = start_supervised!({Source, opts})
    port = Source.port(pid)
    assert_receive {:source_event, @key, {:listener_bound, ^port}}, 2_000

    {pid, port}
  end

  # Connect and get as far as `client/hello`, asserting the trust level the
  # handshake's PSK category implies.
  defp connect_hello!(port, opts \\ []) do
    peer = port |> Peer.connect!(opts) |> Peer.handshake!() |> Peer.hello!()
    {hello, peer} = Peer.await_json!(peer, "client/hello")
    {hello, peer}
  end

  # Activate with `source@v1` withheld and the pairing activity granted, then
  # answer the `client/pair-init` that follows. Assumes the operator consent
  # window is already open (`Source.allow_pairing/1`).
  defp offer_pairing!(peer) do
    peer =
      Peer.activate!(peer, roles: [], activities: ["pairing"], pairing: @pairing_params)

    assert_receive {:source_event, @key, {:pairing_required, _params}}, 2_000
    assert_receive {:source_event, @key, :pairing_started}, 2_000

    Peer.await_pair_init!(peer, pin_length: @pin_length)
  end

  defp await_pin! do
    assert_receive {:source_event, @key, {:pairing_pin, pin}}, 2_000
    assert String.length(pin) == @pin_length
    assert pin =~ ~r/\A[0-9]+\z/
    pin
  end

  # The keypair record exists from the first `client/init`, so "not paired"
  # means the pairing fields are still blank rather than no record at all.
  defp refute_paired!(store) do
    assert {:ok, config} = Store.get_config(store, @key)
    assert config.psk == nil
    assert config.psk_id == nil
    assert config.paired_at == nil
  end

  # A different PIN of the same length — what a mistyped digit produces.
  defp mistype(pin) do
    <<first::binary-size(1), rest::binary>> = pin
    wrong = first |> String.to_integer() |> Kernel.+(1) |> rem(10) |> Integer.to_string()
    wrong <> rest
  end

  describe "pairing consent gate" do
    test "a pairing offer without consent HOLDS the offer instead of aborting", ctx do
      {source, port} = start_source!(ctx)
      {_hello, peer} = connect_hello!(port)

      peer =
        Peer.activate!(peer, roles: [], activities: ["pairing"], pairing: @pairing_params)

      assert_receive {:source_event, @key, {:pairing_required, _params}}, 2_000
      refute_receive {:source_event, @key, :pairing_started}, 300

      # We neither open an attempt nor send `pair/abort`: the offer is held for
      # the operator, and the `client/time` keepalive keeps the connection up.
      # Serving a couple of exchanges pumps everything the source has sent — no
      # `pair/abort` is among it.
      peer = Peer.serve_time!(peer, 2)
      refute Enum.any?(peer.messages, &match?({:json, "pair/abort", _}, &1))

      assert Source.status(source) == :pairing_required
      refute_paired!(ctx.store)
    end

    test "opening the consent window drives the held offer straight to pairing", ctx do
      {source, port} = start_source!(ctx)
      {_hello, peer} = connect_hello!(port)

      peer =
        Peer.activate!(peer, roles: [], activities: ["pairing"], pairing: @pairing_params)

      assert_receive {:source_event, @key, {:pairing_required, _params}}, 2_000

      # No abort was sent while holding; operator consent now acts on the offer
      # the source is already holding.
      peer = Peer.serve_time!(peer, 1)
      refute Enum.any?(peer.messages, &match?({:json, "pair/abort", _}, &1))

      :ok = Source.allow_pairing(source)
      assert_receive {:source_event, @key, :pairing_started}, 2_000
      {index, _peer} = Peer.await_pair_init!(peer, pin_length: @pin_length)
      assert index == 1
    end

    test "a held offer that never gets consent aborts on the consent-wait timeout", ctx do
      # Tiny consent window so the wait elapses in the test.
      {source, port} = start_source!(ctx, pairing_window_ms: 40)
      {_hello, peer} = connect_hello!(port)

      peer =
        Peer.activate!(peer, roles: [], activities: ["pairing"], pairing: @pairing_params)

      assert_receive {:source_event, @key, {:pairing_required, _params}}, 2_000

      # The operator never consents: the consent-wait timeout fires, we abort the
      # held offer and fall back to connected-idle.
      {reason, _peer} = Peer.await_pair_abort!(peer)
      assert reason == "user_cancelled"
      assert_receive {:source_event, @key, :pairing_declined}, 2_000
      assert Source.status(source) == :awaiting_activate
      refute_paired!(ctx.store)
    end

    test "a peer abort during a HELD offer tears the hold down; later consent can't resurrect it",
         ctx do
      {source, port} = start_source!(ctx)
      {_hello, peer} = connect_hello!(port)

      # Offer held without consent: :pairing_required, no attempt open.
      peer =
        Peer.activate!(peer, roles: [], activities: ["pairing"], pairing: @pairing_params)

      assert_receive {:source_event, @key, {:pairing_required, _params}}, 2_000

      # MA withdraws the offer while we are still holding it for the operator.
      peer = Peer.abort_pairing!(peer, "user_cancelled")

      # The hold is torn down (not left live): back to connected-idle with the
      # offer params forgotten, and the UI drops its "Allow pairing" affordance.
      assert_receive {:source_event, @key, {:pairing_failed, {:peer_abort, :user_cancelled}}},
                     2_000

      assert Source.status(source) == :awaiting_activate

      # A LATER operator "Allow pairing" must NOT drive `client/pair-init` for the
      # offer MA already withdrew: nothing pairs and no pair-init is emitted.
      :ok = Source.allow_pairing(source)
      refute_receive {:source_event, @key, :pairing_started}, 300
      peer = Peer.serve_time!(peer, 1)
      refute Enum.any?(peer.messages, &match?({:json, "client/pair-init", _}, &1))
      refute_paired!(ctx.store)
    end

    test "held pairing offers are bounded across reconnects (budget survives teardown)", ctx do
      # A large consent window so a genuinely-held offer never self-declines
      # quickly: only exhausting the hold budget produces an immediate decline.
      {source, port} = start_source!(ctx, pairing_window_ms: 5_000)

      # Burn the whole hold budget, each hold on a FRESH connection. A
      # per-connection counter zeroed at teardown would never trip here.
      Enum.each(1..3, fn _i ->
        {_hello, peer} = connect_hello!(port)

        peer =
          Peer.activate!(peer, roles: [], activities: ["pairing"], pairing: @pairing_params)

        assert_receive {:source_event, @key, {:pairing_required, _params}}, 2_000
        # HELD, not declined: the prompt stays up (no immediate decline).
        refute_receive {:source_event, @key, :pairing_declined}, 200

        :ok = Peer.close!(peer)
        assert_receive {:source_event, @key, :disconnected}, 2_000
      end)

      # The next held offer, again on a fresh connection, exceeds the budget and
      # is declined outright instead of re-arming the prompt — proving the budget
      # was NOT zeroed by the intervening teardowns.
      {_hello, peer} = connect_hello!(port)
      _peer = Peer.activate!(peer, roles: [], activities: ["pairing"], pairing: @pairing_params)

      assert_receive {:source_event, @key, {:pairing_required, _params}}, 2_000
      assert_receive {:source_event, @key, :pairing_declined}, 1_000
      assert Source.status(source) == :awaiting_activate
      refute_paired!(ctx.store)
    end

    test "refuses to open an attempt while a long-term PSK already exists", ctx do
      {source, port} = start_source!(ctx)

      psk = Pairing.generate_psk()

      :ok =
        Store.save_pairing(ctx.store, @key, %{
          psk: psk,
          psk_id: Pairing.psk_id_for(psk),
          psk_category: :long_term,
          server_id: "stored-server-id"
        })

      # An attacker connects with the published Sentinel PSK anyway (trust
      # none) and, even with operator consent, must not be allowed to overwrite
      # the stored PSK.
      {hello, peer} = connect_hello!(port)
      assert hello["trust_level"] == "none"
      :ok = Source.allow_pairing(source)

      peer =
        Peer.activate!(peer, roles: [], activities: ["pairing"], pairing: @pairing_params)

      assert_receive {:source_event, @key, {:pairing_required, _params}}, 2_000
      assert_receive {:source_event, @key, {:pairing_failed, :already_paired}}, 2_000
      {reason, _peer} = Peer.await_pair_abort!(peer)
      assert reason == "user_cancelled"
      refute_received {:source_event, @key, :pairing_started}

      # The stored PSK is untouched.
      assert {:ok, %{psk: ^psk}} = Store.get_config(ctx.store, @key)
    end

    test "pairing attempts are capped at three per connection", ctx do
      {source, port} = start_source!(ctx)
      {_hello, peer} = connect_hello!(port)
      :ok = Source.allow_pairing(source)

      # Three wrong-PIN attempts, indices 1..3. The window survives a failed
      # attempt, so one consent covers all three.
      peer =
        Enum.reduce(1..3, peer, fn expected_index, peer ->
          {index, peer} = offer_pairing!(peer)
          assert index == expected_index

          pin = await_pin!()
          peer = peer |> Peer.submit_pin!(mistype(pin)) |> Peer.serve_pair_auth!()
          {"pin_mismatch", peer} = Peer.await_pair_abort!(peer)
          assert_receive {:source_event, @key, {:pairing_failed, :pin_mismatch}}, 2_000
          peer
        end)

      # The fourth offer exceeds the cap: the client closes the connection.
      _peer =
        Peer.activate!(peer, roles: [], activities: ["pairing"], pairing: @pairing_params)

      assert_receive {:source_event, @key, {:error, :pairing_attempts_exhausted}}, 2_000
      assert_receive {:source_event, @key, :disconnected}, 2_000
      assert Source.status(source) == :listening
    end
  end

  describe "PIN pairing" do
    test "pairs, persists the PSK, re-handshakes at trust user and reaches :ready", ctx do
      {source, port} = start_source!(ctx)

      {hello, peer} = connect_hello!(port)
      assert hello["trust_level"] == "none"

      :ok = Source.allow_pairing(source)
      {index, peer} = offer_pairing!(peer)
      assert index == 1

      # We derive and display the PIN; the operator types it into MA.
      pin = await_pin!()

      peer = peer |> Peer.submit_pin!(pin) |> Peer.serve_pair_auth!()
      {psk, peer} = Peer.serve_pair_finalize!(peer)

      assert_receive {:source_event, @key, :paired}, 2_000

      # The server unwrapped exactly the PSK we minted, and it is persisted.
      assert {:ok, config} = Store.get_config(ctx.store, @key)
      assert config.psk == psk
      assert config.psk_id == Pairing.psk_id_for(psk)
      assert config.psk_category == :long_term
      assert config.server_id == peer.server_id
      assert %DateTime{} = config.paired_at

      assert Source.status(source) == :awaiting_rehandshake

      # Ground truth §4: the server re-runs the handshake in band under the
      # new PSK, then the connection replays hello/activate.
      peer = Peer.rehandshake!(peer, psk)
      peer = Peer.hello!(peer)

      {hello, peer} = Peer.await_json!(peer, "client/hello")
      assert hello["trust_level"] == "user"

      peer = Peer.activate!(peer)
      assert_receive {:source_event, @key, :activated}, 2_000

      {initial, peer} = Peer.await_client_state!(peer, false)
      assert initial["available"] == false

      {available, _peer} = Peer.await_client_state!(peer, true)
      assert available["available"] == true
      assert Source.status(source) == :ready
    end

    test "no client/time is emitted during the active pairing exchange", ctx do
      # A fast keepalive cadence, so a tick would certainly fire mid-exchange if
      # it were not suppressed. `serve_pair_auth!`/`serve_pair_finalize!` are
      # strict: they flunk on any frame interleaved with the exchange, so a
      # completed pairing is proof that only pairing frames flowed.
      {source, port} = start_source!(ctx, time_burst_ms: 10)

      {_hello, peer} = connect_hello!(port)
      :ok = Source.allow_pairing(source)
      {1, peer} = offer_pairing!(peer)
      pin = await_pin!()

      # Snapshot the answered-`client/time` count: `submit_pin!` onward is strict,
      # so this must not move. A second signal to the strict-helper flunk, closing
      # a small CI-load window where a stray tick could slip in unnoticed.
      time_exchanges_before = peer.time_exchanges

      # Let several keepalive intervals elapse while the attempt is live. Without
      # the fix a `client/time` would land between `client/pair-init` and
      # `client/pair-auth` — the exact interleave that made real MA raise
      # "malformed message awaiting ClientPairAuthMessage".
      Process.sleep(60)

      peer = peer |> Peer.submit_pin!(pin) |> Peer.serve_pair_auth!()
      {psk, peer} = Peer.serve_pair_finalize!(peer)

      assert_receive {:source_event, @key, :paired}, 2_000
      assert {:ok, %{psk: ^psk}} = Store.get_config(ctx.store, @key)
      assert Source.status(source) == :awaiting_rehandshake
      assert peer.time_exchanges == time_exchanges_before
    end

    test "no client/time is emitted during the re-handshake window", ctx do
      # A fast keepalive cadence so a tick would certainly fire inside the
      # :awaiting_rehandshake window if it were not suppressed. `rehandshake!` is
      # strict — it flunks on any frame interleaved with the in-band re-handshake
      # — so a completed re-handshake is proof only handshake frames flowed.
      {source, port} = start_source!(ctx, time_burst_ms: 10)

      {_hello, peer} = connect_hello!(port)
      :ok = Source.allow_pairing(source)
      {1, peer} = offer_pairing!(peer)
      pin = await_pin!()

      peer = peer |> Peer.submit_pin!(pin) |> Peer.serve_pair_auth!()
      {psk, peer} = Peer.serve_pair_finalize!(peer)
      assert_receive {:source_event, @key, :paired}, 2_000
      assert Source.status(source) == :awaiting_rehandshake

      # Let several keepalive intervals elapse inside the window before driving
      # the re-handshake, so a stray tick queued when the loop was cancelled would
      # have emitted `client/time` by now if the window weren't suppressed.
      Process.sleep(60)

      time_exchanges_before = peer.time_exchanges
      peer = Peer.rehandshake!(peer, psk)
      assert peer.time_exchanges == time_exchanges_before

      # The connection is healthy afterward: it replays hello/activate at trust
      # user.
      peer = Peer.hello!(peer)
      {hello, _peer} = Peer.await_json!(peer, "client/hello")
      assert hello["trust_level"] == "user"
    end

    test "client/time keepalive resumes after an aborted pairing attempt", ctx do
      {source, port} = start_source!(ctx, time_burst_ms: 20)

      {_hello, peer} = connect_hello!(port)
      :ok = Source.allow_pairing(source)
      {1, peer} = offer_pairing!(peer)

      # Abort the live attempt from the server side: the source returns to
      # :pairing_required with no attempt open, so the `client/time` loop that was
      # suppressed during the exchange must start sending again.
      peer = Peer.abort_pairing!(peer, "user_cancelled")

      assert_receive {:source_event, @key, {:pairing_failed, {:peer_abort, :user_cancelled}}},
                     2_000

      assert Source.status(source) == :pairing_required

      # If keepalive had not resumed, `serve_time!` would block and flunk; two
      # answered exchanges prove the loop is sending once more.
      time_exchanges_before = peer.time_exchanges
      peer = Peer.serve_time!(peer, 2)
      assert peer.time_exchanges >= time_exchanges_before + 2
    end

    test "a mistyped PIN aborts the attempt and the retry pairs at index 2", ctx do
      {source, port} = start_source!(ctx)

      {_hello, peer} = connect_hello!(port)
      :ok = Source.allow_pairing(source)
      {1, peer} = offer_pairing!(peer)
      pin = await_pin!()

      # The server's CPace share is built from the wrong PIN, so its own MCF
      # tag fails our check and we abort before revealing nonce_B.
      peer = peer |> Peer.submit_pin!(mistype(pin)) |> Peer.serve_pair_auth!()

      {reason, peer} = Peer.await_pair_abort!(peer)
      assert reason == "pin_mismatch"

      assert_receive {:source_event, @key, {:pairing_failed, :pin_mismatch}}, 2_000
      assert Source.status(source) == :pairing_required
      refute_paired!(ctx.store)

      # The server retries by granting the pairing activity again; the consent
      # window survives the failure so the retry proceeds at index 2.
      {index, peer} = offer_pairing!(peer)
      assert index == 2

      retry_pin = await_pin!()
      assert retry_pin != pin

      peer = peer |> Peer.submit_pin!(retry_pin) |> Peer.serve_pair_auth!()
      {psk, _peer} = Peer.serve_pair_finalize!(peer)

      assert_receive {:source_event, @key, :paired}, 2_000
      assert {:ok, %{psk: ^psk}} = Store.get_config(ctx.store, @key)
      assert Source.status(source) == :awaiting_rehandshake
    end

    test "a pair/abort from the server ends the attempt without dropping the connection",
         ctx do
      {source, port} = start_source!(ctx)

      {_hello, peer} = connect_hello!(port)
      :ok = Source.allow_pairing(source)
      {1, peer} = offer_pairing!(peer)

      peer = Peer.abort_pairing!(peer, "user_cancelled")

      assert_receive {:source_event, @key, {:pairing_failed, {:peer_abort, :user_cancelled}}},
                     2_000

      refute_received {:source_event, @key, :disconnected}
      assert Source.status(source) == :pairing_required
      refute_paired!(ctx.store)

      # The connection is still usable: another offer starts a fresh attempt.
      {2, _peer} = offer_pairing!(peer)
      assert await_pin!()
    end

    test "an attempt that outlives its window aborts with attempt_timeout", ctx do
      {source, port} = start_source!(ctx, pairing_timeout_ms: 50)

      {_hello, peer} = connect_hello!(port)
      :ok = Source.allow_pairing(source)

      peer =
        Peer.activate!(peer, roles: [], activities: ["pairing"], pairing: @pairing_params)

      assert_receive {:source_event, @key, :pairing_started}, 2_000
      {_payload, peer} = Peer.await_json!(peer, "client/pair-init")

      # The server never answers; the client's own 120 s window (50 ms here)
      # is what ends the attempt.
      {reason, _peer} = Peer.await_pair_abort!(peer)
      assert reason == "attempt_timeout"

      assert_receive {:source_event, @key, {:pairing_failed, :attempt_timeout}}, 2_000
      assert Source.status(source) == :pairing_required
    end

    test "a disconnect mid-attempt returns cleanly to :listening", ctx do
      {source, port} = start_source!(ctx)

      {_hello, peer} = connect_hello!(port)
      :ok = Source.allow_pairing(source)
      {1, peer} = offer_pairing!(peer)

      :ok = Peer.close!(peer)

      assert_receive {:source_event, @key, :disconnected}, 2_000
      assert Source.status(source) == :listening
      refute_paired!(ctx.store)

      # No orphaned attempt: the pairing window timer must not fire a
      # pairing_failed event at a connection that no longer exists.
      refute_receive {:source_event, @key, {:pairing_failed, _reason}}, 200

      # And the listener still accepts a fresh connection.
      {_hello, _peer} = connect_hello!(port)
      assert_receive {:source_event, @key, :connected}, 2_000
    end

    test "a challenger parked mid-pairing does not promote past a slow human PIN entry",
         ctx do
      # A short liveness-probe window so the "slow human" gap below decisively
      # exceeds it: if the probe ran during pairing it would fire and promote.
      {source, port} = start_source!(ctx, incumbent_probe_ms: 100)

      {_hello, peer} = connect_hello!(port)
      :ok = Source.allow_pairing(source)
      {1, peer} = offer_pairing!(peer)
      pin = await_pin!()

      # Real MA opens several concurrent connections during interactive PIN
      # pairing. This one arrives mid-exchange: the pairing incumbent (still
      # trust `none`) must NOT be torn down for it — the challenger is parked.
      challenger = Peer.connect!(port)
      assert Source.status(source) == :pairing_required

      # The operator takes their time reading and typing the PIN — the exchange
      # is legitimately silent for far longer than the probe window. Without the
      # fix (an armed liveness probe) this silence would fire the 100 ms timeout,
      # promote the challenger, and tear the live pairing down. It must not.
      refute_receive {:source_event, @key, :disconnected}, 400
      assert Source.status(source) == :pairing_required

      # The operator finally submits: the exchange resumes and completes. The
      # incumbent's first pairing frame proves it alive, dropping the challenger.
      peer = peer |> Peer.submit_pin!(pin) |> Peer.serve_pair_auth!()
      {psk, peer} = Peer.serve_pair_finalize!(peer)
      assert_receive {:source_event, @key, :paired}, 2_000
      assert Peer.closed?(challenger, 2_000)
      assert Source.status(source) == :awaiting_rehandshake

      # The re-handshake completes at trust user and the source reaches :ready.
      peer = Peer.rehandshake!(peer, psk)
      peer = Peer.hello!(peer)
      {hello, peer} = Peer.await_json!(peer, "client/hello")
      assert hello["trust_level"] == "user"

      peer = Peer.activate!(peer)
      assert_receive {:source_event, @key, :activated}, 2_000
      {_initial, peer} = Peer.await_client_state!(peer, false)
      {available, _peer} = Peer.await_client_state!(peer, true)
      assert available["available"] == true
      assert Source.status(source) == :ready
    end

    test "a challenger during the consent-hold replaces the un-consented held offer", ctx do
      {source, port} = start_source!(ctx)
      {_hello, peer} = connect_hello!(port)

      # A pairing offer with no consent window open: held in :pairing_required,
      # still trust `none`. The operator has consented to nothing, so this hold
      # carries no state worth protecting.
      peer =
        Peer.activate!(peer, roles: [], activities: ["pairing"], pairing: @pairing_params)

      assert_receive {:source_event, @key, {:pairing_required, _params}}, 2_000

      # A concurrent MA connection arrives while the offer is merely held. Unlike a
      # consented, live pairing exchange, the un-consented hold is REPLACED by the
      # challenger (un-authenticated self-heal) rather than parked — an unpaired
      # peer must not be able to squat the single connection slot and block legit
      # MA from pairing.
      challenger = Peer.connect!(port)

      assert_receive {:source_event, @key, :disconnected}, 2_000
      assert_receive {:source_event, @key, :connected}, 2_000
      assert Peer.closed?(peer, 2_000)

      # The promoted challenger is a live connection: client/init flows and it can
      # complete a fresh handshake and be offered pairing itself.
      challenger = Peer.handshake!(challenger)
      challenger = Peer.hello!(challenger)
      {_hello, _challenger} = Peer.await_json!(challenger, "client/hello")
      assert Source.status(source) == :awaiting_activate
    end

    test "a dead pairing incumbent yields to a challenger once the attempt times out", ctx do
      # Short pairing + probe windows so the test doesn't wait the production
      # defaults. The dead exchange is bounded by the pairing timeout, NOT the
      # liveness probe (which is withheld while an exchange is active so a slow
      # human PIN entry can't be mistaken for a dead incumbent).
      {source, port} = start_source!(ctx, pairing_timeout_ms: 100, incumbent_probe_ms: 100)
      {_hello, peer} = connect_hello!(port)
      :ok = Source.allow_pairing(source)
      {1, _peer} = offer_pairing!(peer)
      _pin = await_pin!()

      # The pairing incumbent goes silent mid-exchange (half-open TCP: the MA
      # container restarted). A concurrent connection is parked WITHOUT arming the
      # promote-on-silence probe, so it does not tear the (possibly live) exchange
      # down. Only once the attempt itself times out — leaving an unprotected held
      # offer — does the still-parked challenger probe the now-silent incumbent
      # and get promoted, rather than deadlocking behind a dead pairing socket.
      challenger = Peer.connect!(port)

      assert_receive {:source_event, @key, {:pairing_failed, :attempt_timeout}}, 2_000
      assert_receive {:source_event, @key, :disconnected}, 2_000
      assert_receive {:source_event, @key, :connected}, 2_000

      # The promoted challenger is a live connection: it gets client/init and can
      # complete a fresh handshake.
      challenger = Peer.handshake!(challenger)
      challenger = Peer.hello!(challenger)
      {_hello, _challenger} = Peer.await_json!(challenger, "client/hello")
      assert Source.status(source) == :awaiting_activate
    end

    test "a paired reconnect uses the stored PSK, asserts trust user and never pairs", ctx do
      {_source, port} = start_source!(ctx)
      psk = Pairing.generate_psk()

      :ok =
        Store.save_pairing(ctx.store, @key, %{
          psk: psk,
          psk_id: Pairing.psk_id_for(psk),
          psk_category: :long_term,
          server_id: "stored-server-id"
        })

      {hello, peer} = connect_hello!(port, psk: psk)
      assert hello["trust_level"] == "user"

      _peer = Peer.activate!(peer)
      assert_receive {:source_event, @key, :activated}, 2_000

      refute_received {:source_event, @key, {:pairing_required, _params}}
      refute_received {:source_event, @key, :pairing_started}
    end
  end
end
