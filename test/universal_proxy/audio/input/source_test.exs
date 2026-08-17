defmodule UniversalProxy.Audio.Input.SourceTest do
  # async: false for the same reason as `Audio.Input.StoreTest` — the DETS
  # table name must be an atom, and reusing one constant atom across tests
  # keeps the atom table from growing. Listener ports are ephemeral (`port:
  # 0`), so nothing else here is globally shared.
  use ExUnit.Case, async: false

  alias UniversalProxy.Audio.Input.Source
  alias UniversalProxy.Audio.Input.Store
  alias UniversalProxy.Sendspin.Pairing
  alias UniversalProxy.SendspinSourcePeer, as: Peer

  @table :audio_input_source_test
  @key {"USB Capture Card", 0x1D6B, 0x0105}
  @frame_bytes 3_840

  # A server clock deliberately ~1000 s away from any client clock: an audio
  # timestamp that landed in this domain can only have come through the
  # clock filter, never from passing the capture timestamp straight out.
  @clock_offset_us 1_000_000_000

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "audio_input_source_test_#{System.unique_integer([:positive])}.dets"
      )

    on_exit(fn -> File.rm(path) end)

    store =
      start_supervised!(
        {UniversalProxy.Audio.Input.Store, name: nil, table: @table, dets_path: path}
      )

    {:ok, store: store}
  end

  # Emits `count` distinct 3,840-byte frames (20 ms of 48k/16/2 PCM) with a
  # short gap between writes, then idles so the capture stays open for a
  # stop/start round trip. Content is a per-frame running byte pattern so a
  # test could tell frames apart; the exit path is never reached in practice
  # because `Capture` kills the process on teardown.
  defp write_fake_arecord!(opts \\ []) do
    count = Keyword.get(opts, :count, 200)
    sleep_s = Keyword.get(opts, :sleep_s, 0.005)

    path =
      Path.join(
        System.tmp_dir!(),
        "source_fake_arecord_#{System.unique_integer([:positive])}.py"
      )

    script = """
    #!/usr/bin/env python3
    import sys, time

    FRAME = #{@frame_bytes}

    for i in range(#{count}):
        sys.stdout.buffer.write(bytes((i + j) % 256 for j in range(FRAME)))
        sys.stdout.buffer.flush()
        time.sleep(#{sleep_s})

    time.sleep(30)
    """

    File.write!(path, script)
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm(path) end)

    path
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
      # A 20 ms burst cadence reaches `ClockFilter.converged?/1` (two
      # measurements) fast enough for a test without changing any behaviour.
      |> Keyword.put_new(:time_burst_ms, 20)

    pid = start_supervised!({Source, opts})
    {pid, Source.port(pid)}
  end

  # Persist a long-term pairing so a handshake with this PSK lands at trust
  # `user` — the prerequisite for activating `source@v1` (B1). Streaming tests
  # connect with the returned PSK.
  defp pair!(ctx) do
    psk = Pairing.generate_psk()

    :ok =
      Store.save_pairing(ctx.store, @key, %{
        psk: psk,
        psk_id: Pairing.psk_id_for(psk),
        psk_category: :long_term,
        server_id: "test-server-id"
      })

    psk
  end

  # Connect, handshake, hello, activate — the point every streaming test starts
  # from. `source@v1` only activates at trust `user`, so callers pass the
  # long-term PSK from `pair!/1`.
  defp connect_activated!(port, opts) do
    peer = Peer.connect!(port, Keyword.put_new(opts, :clock_offset_us, @clock_offset_us))
    peer = Peer.handshake!(peer)
    peer = Peer.hello!(peer)
    {_hello, peer} = Peer.await_json!(peer, "client/hello")
    Peer.activate!(peer)
  end

  # Activate, converge the clock filter, and confirm we went available. The
  # `client/time` loop starts at connection setup (`:awaiting_activate`), so
  # `await_client_state!/2` answers whatever `client/time` are in flight until
  # the desired availability lands — regardless of when convergence happens.
  defp connect_available!(port, opts) do
    peer = connect_activated!(port, opts)
    {_initial, peer} = Peer.await_client_state!(peer, false)
    {_available, peer} = Peer.await_client_state!(peer, true)
    peer
  end

  describe "listener" do
    test "binds an ephemeral port and reports it before any connection", ctx do
      {source, port} = start_source!(ctx)

      assert_receive {:source_event, @key, {:listener_bound, ^port}}, 2_000
      assert port > 0
      assert Source.status(source) == :listening

      # The reported port is genuinely bound, not just allocated.
      assert {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [active: false], 1_000)
      :gen_tcp.close(socket)
    end

    test "serves only the sendspin path", ctx do
      {_source, port} = start_source!(ctx)
      assert_receive {:source_event, @key, {:listener_bound, ^port}}, 2_000

      {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, mode: :passive)
      {:ok, conn, ref} = Mint.HTTP.request(conn, "GET", "/nope", [], nil)
      {:ok, _conn, responses} = Mint.HTTP.recv(conn, 0, 2_000)

      assert Enum.any?(responses, &match?({:status, ^ref, 404}, &1))
    end

    test "stopping the source frees the port", ctx do
      {source, port} = start_source!(ctx)
      assert_receive {:source_event, @key, {:listener_bound, ^port}}, 2_000

      :ok = GenServer.stop(source)

      assert {:error, :econnrefused} =
               :gen_tcp.connect(~c"127.0.0.1", port, [active: false], 1_000)
    end
  end

  describe "happy path" do
    # Streaming tests drive the write_fake_arecord!/1 Python fixture standing
    # in for `arecord`; :python3 is excluded in test_helper.exs when python3
    # isn't on PATH (matches capture_test.exs).
    @describetag :python3

    test "handshakes, syncs, and streams 20 ms frames in the server clock domain", ctx do
      arecord = write_fake_arecord!()
      psk = pair!(ctx)
      {source, port} = start_source!(ctx, capture_opts: [arecord_path: arecord])
      assert_receive {:source_event, @key, {:listener_bound, ^port}}, 2_000

      peer = Peer.connect!(port, clock_offset_us: @clock_offset_us, psk: psk)
      assert_receive {:source_event, @key, :connected}, 2_000

      peer = Peer.handshake!(peer)
      peer = Peer.hello!(peer)

      {hello, peer} = Peer.await_json!(peer, "client/hello")
      assert hello["name"] == "USB Capture"
      assert hello["supported_roles"] == ["source@v1"]
      # Paired: the long-term PSK's category is `long_term` → trust `user`, the
      # prerequisite for a source to activate at all.
      assert hello["trust_level"] == "user"
      # Formats live in client_stream/start, never in hello.
      assert hello["source@v1_support"] == %{"features" => %{"line_sense" => false}}
      assert hello["unpaired_access"] == %{"enabled" => false}
      assert [%{"method" => "dynamic_pin"} | _] = hello["supported_pair_methods"]
      assert hello["device_info"]["manufacturer"] == "Universal Proxy"

      peer = Peer.activate!(peer)
      assert_receive {:source_event, @key, :activated}, 2_000

      {initial, peer} = Peer.await_client_state!(peer, false)
      assert initial["available"] == false

      {available, peer} = Peer.await_client_state!(peer, true)
      assert available["available"] == true
      assert Source.status(source) == :ready

      # Nothing streams until the server asks (source@v1 defaults to stopped).
      peer = Peer.command!(peer, "start")
      {stream, peer} = Peer.await_json!(peer, "client_stream/start")

      assert stream["source"] == %{
               "codec" => "pcm",
               "channels" => 2,
               "sample_rate" => 48_000,
               "bit_depth" => 16
             }

      assert_receive {:source_event, @key, :streaming}, 2_000

      {timestamp_us, payload, peer} = Peer.await_audio!(peer)
      assert byte_size(payload) == @frame_bytes
      assert_in_delta timestamp_us, Peer.server_now_us(peer), 2_000_000

      {next_timestamp_us, next_payload, _peer} = Peer.await_audio!(peer)
      assert byte_size(next_payload) == @frame_bytes
      assert next_timestamp_us >= timestamp_us
    end
  end

  describe "connection-level time sync" do
    # The interop fix (PR #170): the client/time loop starts at connection
    # setup, not at role activation, so an unpaired-and-idle MA connection stays
    # alive (Cowboy idle timeout) long enough to reach the pairing controls, and
    # the filter is already converged when the role finally activates.
    test "time-syncs in :awaiting_activate and activates already-converged", ctx do
      psk = pair!(ctx)
      # A slower burst than the default so serve_time!/3 answers each client/time
      # before the next tick fires: that keeps the exchange count exact for the
      # "no further exchange after activation" assertion below.
      {source, port} = start_source!(ctx, time_burst_ms: 200)
      assert_receive {:source_event, @key, {:listener_bound, ^port}}, 2_000

      peer = Peer.connect!(port, clock_offset_us: @clock_offset_us, psk: psk)
      peer = Peer.handshake!(peer)
      peer = Peer.hello!(peer)
      {_hello, peer} = Peer.await_json!(peer, "client/hello")

      # No role has activated, yet the source already sends client/time and
      # processes server/time: the periodic exchange keeps MA's connection alive
      # while it sits unpaired. Three exchanges converge the filter.
      assert Source.status(source) == :awaiting_activate
      peer = Peer.serve_time!(peer, 3)
      assert peer.time_exchanges >= 3
      refute_received {:source_event, @key, :activated}
      refute_received {:source_event, @key, :disconnected}
      assert Source.status(source) == :awaiting_activate

      # Activating now reports available with NO further time exchange: the
      # filter converged during :awaiting_activate and activation does not reset
      # it (before the fix the loop only started here, forcing a re-converge).
      before = peer.time_exchanges
      peer = Peer.activate!(peer)
      assert_receive {:source_event, @key, :activated}, 2_000

      {initial, peer} = Peer.await_client_state!(peer, false)
      assert initial["available"] == false
      {available, peer} = Peer.await_client_state!(peer, true)
      assert available["available"] == true
      assert peer.time_exchanges == before
      assert Source.status(source) == :ready
    end
  end

  describe "server/command" do
    # Only the streaming tests below shell to Python; the ":degraded" test uses
    # a missing binary path and never spawns it, so tag per-test rather than
    # the whole describe.
    @tag :python3
    test "stop ends the stream and start resumes it", ctx do
      arecord = write_fake_arecord!()
      psk = pair!(ctx)
      {source, port} = start_source!(ctx, capture_opts: [arecord_path: arecord])
      assert_receive {:source_event, @key, {:listener_bound, ^port}}, 2_000

      peer = connect_available!(port, psk: psk)
      peer = Peer.command!(peer, "start")
      {_stream, peer} = Peer.await_json!(peer, "client_stream/start")
      assert_receive {:source_event, @key, :streaming}, 2_000
      {_ts, _payload, peer} = Peer.await_audio!(peer)

      peer = Peer.command!(peer, "stop")
      {_end, peer} = Peer.await_json!(peer, "client_stream/end")
      assert_receive {:source_event, @key, :stopped}, 2_000
      assert Source.status(source) == :ready

      peer = Peer.command!(peer, "start")
      {_stream, peer} = Peer.await_json!(peer, "client_stream/start")
      assert_receive {:source_event, @key, :streaming}, 2_000

      {_ts, payload, _peer} = Peer.await_audio!(peer)
      assert byte_size(payload) == @frame_bytes
      assert Source.status(source) == :streaming
    end

    @tag :python3
    test "a stop immediately followed by start never opens a second arecord", ctx do
      arecord = write_fake_arecord!()
      psk = pair!(ctx)
      {source, port} = start_source!(ctx, capture_opts: [arecord_path: arecord])
      assert_receive {:source_event, @key, {:listener_bound, ^port}}, 2_000

      peer = connect_available!(port, psk: psk)
      peer = Peer.command!(peer, "start")
      {_stream, peer} = Peer.await_json!(peer, "client_stream/start")
      assert_receive {:source_event, @key, :streaming}, 2_000
      {_ts, _payload, peer} = Peer.await_audio!(peer)

      cap1 = :sys.get_state(source).capture
      assert is_pid(cap1)
      mon = Process.monitor(cap1)

      # Race a stop and an immediate start. The W-elixir-2 async stop must not
      # let the restart open a second arecord while the first still holds the
      # ALSA device — the new capture is deferred until the old one's EXIT.
      peer = Peer.command!(peer, "stop")
      {_end, peer} = Peer.await_json!(peer, "client_stream/end")
      peer = Peer.command!(peer, "start")
      {_stream, peer} = Peer.await_json!(peer, "client_stream/start")

      # The restart's client_stream/start is only sent after the old capture's
      # EXIT is processed, so by the time it reaches the peer the old arecord is
      # already gone — proving the two never overlap.
      assert_received {:DOWN, ^mon, :process, ^cap1, _}

      cap2 = :sys.get_state(source).capture
      assert is_pid(cap2) and cap2 != cap1
      refute Process.alive?(cap1)

      assert_receive {:source_event, @key, :streaming}, 2_000
      {_ts, payload, _peer} = Peer.await_audio!(peer)
      assert byte_size(payload) == @frame_bytes
      assert Source.status(source) == :streaming
    end

    test "a start with no arecord binary parks the FSM in :degraded", ctx do
      psk = pair!(ctx)

      {source, port} =
        start_source!(ctx, capture_opts: [arecord_path: "/tmp/definitely-not-arecord"])

      assert_receive {:source_event, @key, {:listener_bound, ^port}}, 2_000

      peer = connect_available!(port, psk: psk)
      _peer = Peer.command!(peer, "start")

      assert_receive {:source_event, @key, {:capture_missing, "/tmp/definitely-not-arecord"}},
                     2_000

      assert Source.status(source) == :degraded
    end
  end

  describe "role removal" do
    @tag :python3
    test "server/activate dropping source@v1 mid-stream stops capture and can re-activate", ctx do
      arecord = write_fake_arecord!()
      psk = pair!(ctx)
      {source, port} = start_source!(ctx, capture_opts: [arecord_path: arecord])
      assert_receive {:source_event, @key, {:listener_bound, ^port}}, 2_000

      peer = connect_available!(port, psk: psk)
      peer = Peer.command!(peer, "start")
      {_stream, peer} = Peer.await_json!(peer, "client_stream/start")
      assert_receive {:source_event, @key, :streaming}, 2_000
      {_ts, _payload, peer} = Peer.await_audio!(peer)

      capture = :sys.get_state(source).capture
      assert is_pid(capture)
      mon = Process.monitor(capture)

      # MA revokes source@v1 mid-stream (another source took the target, an
      # admin disabled it, …). We must stop capturing and sending audio, send
      # client_stream/end, and hold the connection so MA can re-activate later.
      peer = Peer.activate!(peer, roles: [])
      {_end, peer} = Peer.await_json!(peer, "client_stream/end")
      assert_receive {:source_event, @key, :stopped}, 2_000

      # Capture is torn down (async), the connection stays up, and the FSM has
      # left :streaming for a re-activatable state.
      assert_receive {:DOWN, ^mon, :process, ^capture, _}, 2_000
      refute Process.alive?(capture)
      refute_received {:source_event, @key, :disconnected}
      assert Source.status(source) == :awaiting_activate

      # A later server/activate WITH source@v1 re-activates without a reconnect.
      # The `client/time` loop kept running while the role was gone, so the
      # filter is still converged: the source reports available again without
      # re-running convergence, then a fresh start resumes streaming.
      peer = Peer.activate!(peer, roles: ["source@v1"])
      assert_receive {:source_event, @key, :activated}, 2_000

      {initial, peer} = Peer.await_client_state!(peer, false)
      assert initial["available"] == false
      {available, peer} = Peer.await_client_state!(peer, true)
      assert available["available"] == true

      peer = Peer.command!(peer, "start")
      {_stream, peer} = Peer.await_json!(peer, "client_stream/start")
      assert_receive {:source_event, @key, :streaming}, 2_000

      {_ts, payload, _peer} = Peer.await_audio!(peer)
      assert byte_size(payload) == @frame_bytes
      assert Source.status(source) == :streaming
    end
  end

  describe "pairing" do
    test "activate without source@v1 plus a pairing activity holds in :pairing_required", ctx do
      {source, port} = start_source!(ctx)
      assert_receive {:source_event, @key, {:listener_bound, ^port}}, 2_000

      peer = Peer.connect!(port)
      peer = Peer.handshake!(peer)
      peer = Peer.hello!(peer)
      {_hello, peer} = Peer.await_json!(peer, "client/hello")

      _peer =
        Peer.activate!(peer,
          roles: [],
          activities: ["pairing"],
          pairing: %{"method" => "dynamic_pin", "pin_length" => 6}
        )

      assert_receive {:source_event, @key, {:pairing_required, params}}, 2_000
      assert params.method == :dynamic_pin
      assert params.pin_length == 6

      refute_received {:source_event, @key, :activated}
      assert Source.status(source) == :pairing_required
    end
  end

  describe "connection lifecycle" do
    test "an idle activate (no role, no pairing) holds the connection open and idle", ctx do
      {source, port} = start_source!(ctx)
      assert_receive {:source_event, @key, {:listener_bound, ^port}}, 2_000

      peer = Peer.connect!(port)
      peer = Peer.handshake!(peer)
      peer = Peer.hello!(peer)
      {_hello, peer} = Peer.await_json!(peer, "client/hello")

      # MA's steady state before the operator initiates pairing: it dials every
      # discovered source and sends an activate with neither a source@v1 role
      # nor a pairing activity. We must stay connected and idle (not close), so
      # MA keeps a stable connection and can later escalate to pairing.
      peer = Peer.activate!(peer, roles: [], activities: ["playback"])

      refute_receive {:source_event, @key, {:error, _}}, 500
      refute_received {:source_event, @key, :disconnected}
      refute_received {:source_event, @key, :activated}
      assert Source.status(source) == :awaiting_activate

      # A later pairing activate on the SAME connection still works.
      _peer =
        Peer.activate!(peer,
          roles: [],
          activities: ["pairing"],
          pairing: %{"method" => "dynamic_pin", "pin_length" => 6}
        )

      assert_receive {:source_event, @key, {:pairing_required, _params}}, 2_000
      assert Source.status(source) == :pairing_required
    end

    test "a dropped connection is reported and the listener keeps accepting", ctx do
      psk = pair!(ctx)
      {source, port} = start_source!(ctx)
      assert_receive {:source_event, @key, {:listener_bound, ^port}}, 2_000

      peer = connect_activated!(port, psk: psk)
      assert_receive {:source_event, @key, :activated}, 2_000
      :ok = Peer.close!(peer)

      assert_receive {:source_event, @key, :disconnected}, 2_000
      assert Source.status(source) == :listening

      # MA redials the same listener; the client identity (and therefore the
      # Noise static key) is the persisted one, so a fresh handshake works.
      _peer = connect_activated!(port, psk: psk)
      assert_receive {:source_event, @key, :connected}, 2_000
      assert_receive {:source_event, @key, :activated}, 2_000
      assert Source.status(source) == :syncing
    end

    test "a second inbound connection replaces the first", ctx do
      psk = pair!(ctx)
      {_source, port} = start_source!(ctx)
      assert_receive {:source_event, @key, {:listener_bound, ^port}}, 2_000

      # The incumbent is only handshaked at trust `none` (Sentinel) — an
      # un-authenticated session, so it is replaced rather than protected.
      first = Peer.connect!(port)
      first = Peer.handshake!(first)
      assert_receive {:source_event, @key, :connected}, 2_000

      _second = connect_activated!(port, psk: psk)

      assert_receive {:source_event, @key, :disconnected}, 2_000
      assert_receive {:source_event, @key, :connected}, 2_000
      assert_receive {:source_event, @key, :activated}, 2_000

      # The replaced socket really was closed, not merely forgotten.
      assert Peer.closed?(first, 2_000)
    end

    @tag :python3
    test "a streaming trust-user session is not evicted by an un-handshaked peer", ctx do
      arecord = write_fake_arecord!()
      psk = pair!(ctx)
      {source, port} = start_source!(ctx, capture_opts: [arecord_path: arecord])
      assert_receive {:source_event, @key, {:listener_bound, ^port}}, 2_000

      peer = connect_available!(port, psk: psk)
      peer = Peer.command!(peer, "start")
      {_stream, peer} = Peer.await_json!(peer, "client_stream/start")
      assert_receive {:source_event, @key, :streaming}, 2_000

      # An attacker merely opens a socket (no handshake). The authenticated,
      # streaming session must NOT be torn down for it (W5).
      challenger = Peer.connect!(port)
      refute_receive {:source_event, @key, :disconnected}, 500
      assert Source.status(source) == :streaming

      # The incumbent answers the liveness probe, so the parked challenger is
      # dropped and the stream continues uninterrupted.
      peer = Peer.serve_time!(peer, 1)
      assert Peer.closed?(challenger, 2_000)
      assert Source.status(source) == :streaming
      {_ts, _payload, _peer} = Peer.await_audio!(peer)
    end
  end

  describe "hostile peer" do
    test "refuses to activate source@v1 at trust none and closes (B1)", ctx do
      {source, port} = start_source!(ctx)
      assert_receive {:source_event, @key, {:listener_bound, ^port}}, 2_000

      # Sentinel PSK ⇒ trust none. A spec-violating server that activates
      # source@v1 anyway must be refused and the connection dropped, never
      # opening capture.
      peer = Peer.connect!(port)
      peer = Peer.handshake!(peer)
      peer = Peer.hello!(peer)
      {_hello, peer} = Peer.await_json!(peer, "client/hello")
      _peer = Peer.activate!(peer)

      assert_receive {:source_event, @key, {:error, {:source_activated_untrusted, :none}}}, 2_000
      assert_receive {:source_event, @key, :disconnected}, 2_000
      refute_received {:source_event, @key, :activated}
      assert Source.status(source) == :listening
    end

    test "garbage ciphertext in transport mode drops the connection", ctx do
      {source, port} = start_source!(ctx)
      assert_receive {:source_event, @key, {:listener_bound, ^port}}, 2_000

      peer = Peer.connect!(port)
      peer = Peer.handshake!(peer)

      # A binary frame that isn't a valid Noise transport message.
      _peer = Peer.send_raw_binary!(peer, :crypto.strong_rand_bytes(64))

      assert_receive {:source_event, @key, {:error, _reason}}, 2_000
      assert_receive {:source_event, @key, :disconnected}, 2_000
      assert Source.status(source) == :listening
    end

    test "an oversized websocket frame is rejected at the listener before decrypt", ctx do
      {source, port} = start_source!(ctx)
      assert_receive {:source_event, @key, {:listener_bound, ^port}}, 2_000

      peer = Peer.connect!(port)
      peer = Peer.handshake!(peer)

      # One WS binary frame carries exactly one Noise transport message
      # (≤ 65_535 bytes), so a larger frame can never be legitimate. Cowboy
      # rejects it at the WS layer via `max_frame_size` BEFORE any reassembly
      # or decrypt work, so the connection drops with no protocol `{:error}`
      # reaching the FSM (an uncapped default would let it through to Noise).
      _peer = Peer.send_raw_binary!(peer, :crypto.strong_rand_bytes(70_000))

      assert_receive {:source_event, @key, :disconnected}, 2_000
      refute_received {:source_event, @key, {:error, _}}
      assert Source.status(source) == :listening
    end

    test "an out-of-order server/hello before the handshake is a protocol error", ctx do
      {source, port} = start_source!(ctx)
      assert_receive {:source_event, @key, {:listener_bound, ^port}}, 2_000

      # A text frame where the client is still waiting for server/init.
      peer = Peer.connect!(port)
      {_client_init, peer} = Peer.expect_client_init!(peer)
      _peer = Peer.send_text!(peer, ~s({"type":"server/hello","payload":{}}))

      assert_receive {:source_event, @key, {:error, _reason}}, 2_000
      assert_receive {:source_event, @key, :disconnected}, 2_000
      assert Source.status(source) == :listening
    end
  end

  describe "capture crash" do
    @describetag :python3

    test "a capture crash mid-stream ends the stream but keeps the connection", ctx do
      arecord = write_fake_arecord!()
      psk = pair!(ctx)
      {source, port} = start_source!(ctx, capture_opts: [arecord_path: arecord])
      assert_receive {:source_event, @key, {:listener_bound, ^port}}, 2_000

      peer = connect_available!(port, psk: psk)
      peer = Peer.command!(peer, "start")
      {_stream, peer} = Peer.await_json!(peer, "client_stream/start")
      assert_receive {:source_event, @key, :streaming}, 2_000
      {_ts, _payload, _peer} = Peer.await_audio!(peer)

      # Kill the capture process out from under the FSM.
      capture = :sys.get_state(source).capture
      assert is_pid(capture)
      Process.exit(capture, :kill)

      assert_receive {:source_event, @key, :stopped}, 2_000
      assert Source.status(source) == :ready
    end
  end
end
