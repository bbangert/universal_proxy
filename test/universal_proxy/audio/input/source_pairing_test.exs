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

  # The `pairing` objects a server sends alongside the `pairing` activity.
  @pairing_params %{"method" => "dynamic_pairing_code", "format" => "digits"}
  @psk_pairing_params %{"method" => "pairing_psk"}

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

  # Connect and get as far as `client/hello`.
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

    Peer.await_pair_init!(peer)
  end

  defp await_pin! do
    assert_receive {:source_event, @key, {:pairing_pin, pin}}, 2_000
    assert pin =~ ~r/\A[0-9]{6}\z/
    pin
  end

  # After the in-band re-handshake the server's next message is server/activate
  # (no hellos are replayed); activate source@v1 and converge to :ready.
  defp activate_ready!(peer, source) do
    peer = Peer.activate!(peer)
    assert_receive {:source_event, @key, :activated}, 2_000
    {initial, peer} = Peer.await_client_state!(peer, false)
    assert initial == %{"available" => false, "source" => %{}}
    {available, peer} = Peer.await_client_state!(peer, true)
    assert available["available"] == true
    assert Source.status(source) == :ready
    peer
  end

  # The keypair record exists from the first `client/init`, so "not paired"
  # means the pairing fields are still blank rather than no record at all.
  defp refute_paired!(store) do
    assert {:ok, config} = Store.get_config(store, @key)
    assert config.pairings == []
  end

  defp records(store) do
    {:ok, config} = Store.get_config(store, @key)
    config.pairings
  end

  defp other_server_id, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

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
      # the operator — the server is told so with `client/pair-pending` — and the
      # `client/time` keepalive keeps the connection up.
      {pending, peer} = Peer.await_json!(peer, "client/pair-pending")
      assert pending["pairing_index"] == 1
      assert pending["message"] =~ "Allow pairing"
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
      {index, _peer} = Peer.await_pair_init!(peer)
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

    test "a consented code pairing adds a record beside another server's", ctx do
      {source, port} = start_source!(ctx)
      other = other_server_id()
      :ok = Store.save_pairing(ctx.store, @key, %{psk: Pairing.generate_psk(), server_id: other})

      {_hello, peer} = connect_hello!(port)
      :ok = Source.allow_pairing(source)
      {1, peer} = offer_pairing!(peer)
      pin = await_pin!()
      peer = peer |> Peer.submit_pin!(pin) |> Peer.serve_pair_auth!()
      {psk, _peer} = Peer.serve_pair_finalize!(peer)
      assert_receive {:source_event, @key, :paired}, 2_000

      ids = ctx.store |> records() |> Enum.map(& &1.server_id) |> Enum.sort()
      assert ids == Enum.sort([other, Peer.default_server_id()])
      assert Enum.any?(records(ctx.store), &(&1.psk == psk))
    end

    test "re-pairing the same server by code replaces its record", ctx do
      {source, port} = start_source!(ctx)
      old = Pairing.generate_psk()
      :ok = Store.save_pairing(ctx.store, @key, %{psk: old, server_id: Peer.default_server_id()})

      {_hello, peer} = connect_hello!(port)
      :ok = Source.allow_pairing(source)
      {1, peer} = offer_pairing!(peer)
      pin = await_pin!()
      peer = peer |> Peer.submit_pin!(pin) |> Peer.serve_pair_auth!()
      {psk, _peer} = Peer.serve_pair_finalize!(peer)
      assert_receive {:source_event, @key, :paired}, 2_000

      assert [%{psk: ^psk}] = records(ctx.store)
    end

    test "pairing attempts are capped at three per connection", ctx do
      {source, port} = start_source!(ctx)
      {_hello, peer} = connect_hello!(port)
      :ok = Source.allow_pairing(source)

      # Three failed attempts, indices 1..3. The window survives a failed
      # attempt, so one consent covers all three.
      peer =
        Enum.reduce(1..3, peer, fn expected_index, peer ->
          {index, peer} = offer_pairing!(peer)
          assert index == expected_index

          _pin = await_pin!()
          peer = Peer.abort_pairing!(peer, "user_cancelled")

          assert_receive {:source_event, @key, {:pairing_failed, {:peer_abort, :user_cancelled}}},
                         2_000

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

      {_hello, peer} = connect_hello!(port)
      assert :sys.get_state(source).trust == :none

      :ok = Source.allow_pairing(source)
      {index, peer} = offer_pairing!(peer)
      assert index == 1

      # We derive and display the code; the operator types it into MA.
      pin = await_pin!()

      peer = peer |> Peer.submit_pin!(pin) |> Peer.serve_pair_auth!()
      {psk, peer} = Peer.serve_pair_finalize!(peer)

      assert_receive {:source_event, @key, :paired}, 2_000

      # The server unwrapped exactly the PSK we minted, and it is persisted.
      assert [record] = records(ctx.store)
      assert record.psk == psk
      assert record.psk_id == Pairing.psk_id_for(psk)
      assert record.server_id == peer.server_id
      assert %DateTime{} = record.paired_at

      assert Source.status(source) == :awaiting_rehandshake

      # The server re-runs the handshake in band under the new PSK; its next
      # message is a fresh server/activate, now at trust user.
      peer = Peer.rehandshake!(peer, psk)
      assert %{trust: :user, psk_category: :long_term} = :sys.get_state(source)
      _peer = activate_ready!(peer, source)
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
      assert [%{psk: ^psk}] = records(ctx.store)
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

      # Nor between message 2 and the server/activate that follows it: the
      # client may send nothing but the handshake until that activation.
      peer = Peer.refute_frames!(peer, 100)

      # The connection is healthy afterward, at trust user.
      _peer = activate_ready!(peer, source)
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

    test "a mistyped code retries in a second round of the same attempt", ctx do
      {source, port} = start_source!(ctx)

      {_hello, peer} = connect_hello!(port)
      :ok = Source.allow_pairing(source)
      {1, peer} = offer_pairing!(peer)
      pin = await_pin!()

      # The server's CPace share is built from the wrong code, so its own MCF
      # tag fails our check: we ask for another round (strict — nothing else
      # interleaves) rather than revealing nonce_B or aborting.
      peer = peer |> Peer.submit_pin!(mistype(pin)) |> Peer.serve_pair_auth!()
      peer = Peer.serve_pair_retry!(peer)

      # Same attempt, same code, shown again for the second round.
      assert ^pin = await_pin!()
      refute_received {:source_event, @key, {:pairing_failed, _}}
      refute_paired!(ctx.store)

      peer = peer |> Peer.submit_pin!(pin) |> Peer.serve_pair_auth!()
      {psk, _peer} = Peer.serve_pair_finalize!(peer)

      assert_receive {:source_event, @key, :paired}, 2_000
      assert [%{psk: ^psk}] = records(ctx.store)
      assert Source.status(source) == :awaiting_rehandshake
      # A successful pairing consumes the consent window, round count and all.
      assert :sys.get_state(source).pairing_window == nil
    end

    test "an activation without pairing cancels a live attempt", ctx do
      {source, port} = start_source!(ctx)

      {_hello, peer} = connect_hello!(port)
      :ok = Source.allow_pairing(source)
      {1, peer} = offer_pairing!(peer)
      _pin = await_pin!()

      _peer = Peer.activate!(peer, roles: [], activities: [])

      assert_receive {:source_event, @key, {:pairing_failed, :cancelled}}, 2_000
      assert %{pairing: nil, fsm: :awaiting_activate} = :sys.get_state(source)
      refute_received {:source_event, @key, :disconnected}
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
      _peer = activate_ready!(peer, source)
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

    test "a paired reconnect uses the stored PSK, lands at trust user and never pairs", ctx do
      {source, port} = start_source!(ctx)
      psk = Pairing.generate_psk()

      :ok =
        Store.save_pairing(ctx.store, @key, %{
          psk: psk,
          psk_id: Pairing.psk_id_for(psk),
          psk_category: :long_term,
          server_id: Peer.default_server_id()
        })

      {_hello, peer} = connect_hello!(port, psk: psk)
      assert :sys.get_state(source).trust == :user

      _peer = Peer.activate!(peer)
      assert_receive {:source_event, @key, :activated}, 2_000

      refute_received {:source_event, @key, {:pairing_required, _params}}
      refute_received {:source_event, @key, :pairing_started}
    end
  end

  describe "Pairing PSK" do
    # The operator pasted the input's pairing token into MA: no consent
    # gesture, no code — the handshake under the pairing PSK authenticated both
    # sides already.
    defp pairing_psk!(ctx) do
      {:ok, psk} = Store.ensure_pairing_psk(ctx.store, @key)
      psk
    end

    defp serve_pairing_psk!(peer) do
      peer =
        Peer.activate!(peer, roles: [], activities: ["pairing"], pairing: @psk_pairing_params)

      assert_receive {:source_event, @key, :pairing_started}, 2_000
      {index, peer} = Peer.await_pair_init!(peer, method: :pairing_psk)
      {long_term, peer} = Peer.serve_pairing_psk_finalize!(peer)
      assert_receive {:source_event, @key, :paired}, 2_000
      {index, long_term, peer}
    end

    test "a pairing dial pairs without consent and re-handshakes to the new record", ctx do
      {source, port} = start_source!(ctx)
      pairing_psk = pairing_psk!(ctx)

      {_hello, peer} = connect_hello!(port, psk: pairing_psk, psk_category: :pairing)
      assert %{trust: :none, psk_category: :pairing} = :sys.get_state(source)

      {1, long_term, peer} = serve_pairing_psk!(peer)
      refute_received {:source_event, @key, {:pairing_required, _}}

      # A fresh long-term PSK — never the pairing PSK itself — is persisted,
      # bound to this server, and the pairing PSK survives (it is long-lived).
      assert long_term != pairing_psk
      assert {:ok, config} = Store.get_config(ctx.store, @key)
      assert [%{psk: ^long_term, server_id: server_id}] = config.pairings
      assert server_id == peer.server_id
      assert config.pairing_psk == pairing_psk

      peer = Peer.rehandshake!(peer, long_term)
      assert %{trust: :user, psk_category: :long_term} = :sys.get_state(source)
      _peer = activate_ready!(peer, source)
    end

    test "a connected unpaired session re-handshakes to the pairing PSK, then pairs", ctx do
      {source, port} = start_source!(ctx)
      pairing_psk = pairing_psk!(ctx)

      {_hello, peer} = connect_hello!(port)
      peer = Peer.activate!(peer, roles: [], activities: [])
      assert :sys.get_state(source).psk_category == :sentinel

      peer = Peer.rehandshake!(peer, pairing_psk, category: :pairing, tolerate_time: true)
      assert %{psk_category: :pairing, pairing_index: 0} = :sys.get_state(source)

      {1, long_term, peer} = serve_pairing_psk!(peer)
      peer = Peer.rehandshake!(peer, long_term)
      _peer = activate_ready!(peer, source)
    end

    test "a token pairing replaces the same server's record and keeps the others", ctx do
      {source, port} = start_source!(ctx)
      other = other_server_id()
      :ok = Store.save_pairing(ctx.store, @key, %{psk: Pairing.generate_psk(), server_id: other})

      :ok =
        Store.save_pairing(ctx.store, @key, %{
          psk: Pairing.generate_psk(),
          server_id: Peer.default_server_id()
        })

      {_hello, peer} = connect_hello!(port, psk: pairing_psk!(ctx), psk_category: :pairing)
      {1, long_term, _peer} = serve_pairing_psk!(peer)

      records = records(ctx.store)
      assert length(records) == 2
      assert Enum.find(records, &(&1.server_id == Peer.default_server_id())).psk == long_term
      assert Enum.any?(records, &(&1.server_id == other))
      assert Source.status(source) == :awaiting_rehandshake
    end

    test "pairing_psk on a Sentinel session is method_not_supported", ctx do
      {source, port} = start_source!(ctx)
      {_hello, peer} = connect_hello!(port)

      peer =
        Peer.activate!(peer, roles: [], activities: ["pairing"], pairing: @psk_pairing_params)

      {reason, _peer} = Peer.await_pair_abort!(peer)
      assert reason == "method_not_supported"

      assert_receive {:source_event, @key,
                      {:pairing_failed, {:unsupported_method, :pairing_psk}}},
                     2_000

      assert Source.status(source) == :pairing_required
      refute_paired!(ctx.store)
    end

    test "a code method on a pairing-PSK session is method_not_supported", ctx do
      {_source, port} = start_source!(ctx)
      {_hello, peer} = connect_hello!(port, psk: pairing_psk!(ctx), psk_category: :pairing)

      peer = Peer.activate!(peer, roles: [], activities: ["pairing"], pairing: @pairing_params)

      {reason, _peer} = Peer.await_pair_abort!(peer)
      assert reason == "method_not_supported"
      refute_paired!(ctx.store)
    end

    test "an unknown method or the qr_code format is method_not_supported", ctx do
      {_source, port} = start_source!(ctx)
      {_hello, peer} = connect_hello!(port)

      for params <- [
            %{"method" => "dynamic_pin", "pin_length" => 6},
            %{"method" => "dynamic_pairing_code", "format" => "qr_code"}
          ],
          reduce: peer do
        peer ->
          peer = Peer.activate!(peer, roles: [], activities: ["pairing"], pairing: params)
          {reason, peer} = Peer.await_pair_abort!(peer)
          assert reason == "method_not_supported"
          peer
      end
    end

    test "unpaired re-handshakes are capped per connection", ctx do
      {source, port} = start_source!(ctx)
      {_hello, peer} = connect_hello!(port)
      peer = Peer.activate!(peer, roles: [], activities: [])

      sentinel = UniversalProxy.Sendspin.Noise.sentinel_psk()
      pairing_psk = pairing_psk!(ctx)

      # Three token attempts that each switch to the pairing PSK and are
      # cancelled back, plus the post-pairing re-key, stay within the cap.
      peer =
        Enum.reduce(1..8, peer, fn i, peer ->
          {psk, category} =
            if rem(i, 2) == 1, do: {pairing_psk, :pairing}, else: {sentinel, :sentinel}

          peer = Peer.rehandshake!(peer, psk, category: category, tolerate_time: true)
          Peer.activate!(peer, roles: [], activities: [])
        end)

      refute_received {:source_event, @key, {:error, _}}

      _peer =
        Peer.send_message!(peer, "noise/handshake", %{
          "data" => Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)
        })

      assert_receive {:source_event, @key, {:error, {:unexpected_rehandshake, _, :none}}}, 2_000
      assert Source.status(source) == :listening
    end
  end
end
