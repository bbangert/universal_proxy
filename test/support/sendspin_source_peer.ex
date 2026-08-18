defmodule UniversalProxy.SendspinSourcePeer do
  @moduledoc """
  A scripted Music-Assistant-side peer for `UniversalProxy.Audio.Input.Source`.

  Dials the source's own websocket listener (MA connects *in* — see the
  ground-truth doc §2/§5), then drives the server half of the protocol:
  `server/init` + Noise message 1 as the **initiator**, `server/hello`,
  `server/activate`, `server/time` replies and `server/command`.

  Two independence properties are deliberate, mirroring
  `UniversalProxy.SendspinPairingServer`:

    * the Noise initiator is `Decibel` driven directly, not our
      `Sendspin.Noise` responder wrapper, so a round trip exercises both
      halves rather than one implementation talking to itself;
    * the websocket client is `mint_web_socket` in **passive** mode, so the
      test process's mailbox stays free for the `{:source_event, ...}`
      notifications the source sends it.

  The peer keeps a server clock that is deliberately far away from the
  client's (`:clock_offset_us`), so a test can prove that audio-frame
  timestamps really were mapped through the clock filter rather than passed
  through unchanged.

  ## Pumping

  `client/time` messages arrive continuously once the source is active, and
  audio frames arrive continuously once it is streaming. Every `await_*`
  helper therefore *pumps*: it answers `client/time` (counting it in
  `:time_exchanges`), stashes audio frames in `:audio` and other messages in
  `:messages`, and returns only when the message it was waiting for arrives.
  `serve_time!/3` is the exception — it waits for `client/time` itself so a
  test can drive the filter to convergence deliberately.
  """

  import ExUnit.Assertions

  alias UniversalProxy.Sendspin.Noise
  alias UniversalProxy.Sendspin.Pairing
  alias UniversalProxy.Sendspin.Wire
  alias UniversalProxy.SendspinPairingServer, as: PairingServer

  @default_timeout 5_000

  defstruct [
    :conn,
    :ref,
    :websocket,
    :noise,
    :handshake_hash,
    :server_keypair,
    :server_id,
    :client_id,
    :psk,
    :psk_id,
    :suite,
    :pairing,
    clock_offset_us: 0,
    frames: [],
    audio: [],
    messages: [],
    time_exchanges: 0
  ]

  @doc """
  Open a websocket to `port` and perform the HTTP upgrade only.

  Options:

    * `:path` — defaults to `UniversalProxy.Audio.Input.Source.default_path/0`.
    * `:server_keypair` — X25519 `{pub, priv}`; generated when absent.
    * `:psk` — the PSK to hand the Noise session; defaults to the Sentinel PSK.
    * `:psk_id` — the id advertised in Noise message 1; defaults to the id of
      `:psk`.
    * `:clock_offset_us` — server clock minus client clock, in µs.
  """
  def connect!(port, opts \\ []) do
    path = Keyword.get(opts, :path, UniversalProxy.Audio.Input.Source.default_path())
    psk = Keyword.get(opts, :psk, Noise.sentinel_psk())
    server_keypair = Keyword.get_lazy(opts, :server_keypair, &Noise.generate_static_keypair/0)
    {server_pub, _priv} = server_keypair

    {:ok, conn} =
      Mint.HTTP.connect(:http, "127.0.0.1", port, mode: :passive, protocols: [:http1])

    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, path, [])
    {conn, status, headers} = await_upgrade(conn, ref, %{})
    {:ok, conn, websocket} = Mint.WebSocket.new(conn, ref, status, headers, mode: :passive)

    %__MODULE__{
      conn: conn,
      ref: ref,
      websocket: websocket,
      server_keypair: server_keypair,
      server_id: Base.url_encode64(server_pub, padding: false),
      psk: psk,
      psk_id: Keyword.get_lazy(opts, :psk_id, fn -> Pairing.psk_id_for(psk) end),
      clock_offset_us: Keyword.get(opts, :clock_offset_us, 0)
    }
  end

  @doc """
  Run the cleartext exchange and the Noise handshake, leaving the peer in
  transport mode.

  Asserts the client half along the way: `client/init` first (even though the
  client accepted rather than opened the socket), protocol version 1, and a
  Noise message 2 whose inner payload is the literal `{}`.
  """
  def handshake!(peer, timeout \\ @default_timeout) do
    {client_init, peer} = expect_text!(peer, timeout)

    assert {:ok, %{client_id: client_id, version: 1, suite: suite}} =
             Wire.decode_client_init(client_init)

    assert byte_size(client_id) == 43
    {:ok, client_pub} = Base.url_decode64(client_id, padding: false)

    server_init = Wire.encode_server_init(peer.server_id, 1)
    peer = send_ws!(peer, {:text, server_init})

    {:ok, protocol} = Noise.protocol_name(suite)

    noise =
      Decibel.new(protocol, :ini, %{
        s: peer.server_keypair,
        rs: client_pub,
        psks: [peer.psk],
        prologue: client_init <> server_init
      })

    message_1 =
      noise
      |> Decibel.handshake_encrypt(Jason.encode!(%{"psk_id" => peer.psk_id}))
      |> IO.iodata_to_binary()

    peer = send_ws!(peer, {:text, Wire.encode_noise_handshake(message_1)})

    {text, peer} = expect_text!(peer, timeout)
    assert {:ok, message_2} = Wire.decode_noise_handshake(text)
    assert IO.iodata_to_binary(Decibel.handshake_decrypt(noise, message_2)) == "{}"

    %{
      peer
      | noise: noise,
        handshake_hash: Decibel.get_handshake_hash(noise),
        suite: suite,
        client_id: client_id
    }
  end

  @doc """
  Re-run the Noise handshake **in band**, as a server does after a successful
  pairing (ground truth §4).

  The two `noise/handshake` messages travel as ordinary encrypted JSON under
  the *old* session, the prologue is the previous handshake's hash, and `psk`
  (the freshly paired long-term PSK) keys the new session. On return the peer
  talks under the new session.
  """
  def rehandshake!(peer, psk, timeout \\ @default_timeout) do
    {:ok, protocol} = Noise.protocol_name(peer.suite)
    {:ok, client_pub} = Base.url_decode64(peer.client_id, padding: false)
    psk_id = Pairing.psk_id_for(psk)

    noise =
      Decibel.new(protocol, :ini, %{
        s: peer.server_keypair,
        rs: client_pub,
        psks: [psk],
        prologue: peer.handshake_hash
      })

    message_1 =
      noise
      |> Decibel.handshake_encrypt(Jason.encode!(%{"psk_id" => psk_id}))
      |> IO.iodata_to_binary()

    peer = send_message!(peer, "noise/handshake", %{"data" => b64(message_1)})

    # STRICT, mirroring the pairing exchange: the in-band re-handshake is the same
    # strict-sequential exchange, and the source suppresses `client/time` for its
    # whole `:awaiting_rehandshake` window (a `server/time` reply sent under the
    # old session would reach the source after it swaps to the new keys and fail
    # to decrypt). So the ONLY frame here is the source's `noise/handshake`
    # message 2 — flunk on anything interleaved rather than tolerating it, which
    # is what makes a future regression that emits `client/time` one boundary
    # later (during re-handshake instead of pairing) fail loudly.
    {payload, peer} =
      case next!(peer, timeout) do
        {{:json, "noise/handshake", payload}, peer} ->
          {payload, peer}

        {other, _peer} ->
          flunk(
            "expected noise/handshake message 2 but received #{inspect(other)} mid-rehandshake; " <>
              "a real server never interleaves frames with the in-band re-handshake"
          )
      end

    {:ok, message_2} = Base.url_decode64(payload["data"], padding: false)
    assert IO.iodata_to_binary(Decibel.handshake_decrypt(noise, message_2)) == "{}"

    Decibel.close(peer.noise)

    %{
      peer
      | noise: noise,
        handshake_hash: Decibel.get_handshake_hash(noise),
        psk: psk,
        psk_id: psk_id
    }
  end

  @doc "Read the first (client/init) text frame without proceeding further."
  def expect_client_init!(peer, timeout \\ @default_timeout), do: expect_text!(peer, timeout)

  @doc "Send a raw text frame (test seam for malformed / out-of-order input)."
  def send_text!(peer, text) when is_binary(text), do: send_ws!(peer, {:text, text})

  @doc "Send a raw binary frame — not necessarily a valid Noise transport frame."
  def send_raw_binary!(peer, data) when is_binary(data), do: send_ws!(peer, {:binary, data})

  @doc "Send an encrypted JSON message."
  def send_message!(peer, type, payload \\ %{}) do
    ciphertext =
      peer.noise
      |> Decibel.encrypt(Wire.wrap_json(Wire.encode_message(type, payload)))
      |> IO.iodata_to_binary()

    send_ws!(peer, {:binary, ciphertext})
  end

  @doc "Send `server/hello`."
  def hello!(peer, name \\ "Music Assistant") do
    send_message!(peer, "server/hello", %{"name" => name})
  end

  @doc """
  Send `server/activate`. `opts[:roles]` defaults to activating `source@v1`;
  pass `roles: []` plus `activities: ["pairing"]` to exercise the
  pairing-required path.
  """
  def activate!(peer, opts \\ []) do
    payload =
      %{
        "activities" => Keyword.get(opts, :activities, ["playback"]),
        "active_roles" => Keyword.get(opts, :roles, ["source@v1"])
      }
      |> maybe_put("pairing", Keyword.get(opts, :pairing))

    send_message!(peer, "server/activate", payload)
  end

  @doc "Send `server/command` with a source `start`/`stop`."
  def command!(peer, command) when command in ["start", "stop"] do
    send_message!(peer, "server/command", %{"source" => %{"command" => command}})
  end

  @doc """
  Wait for `client/pair-init` and answer it with `server/pair-init`.

  This is the exchange boundary and stays *tolerant*: the source's `client/time`
  keepalive runs across `:awaiting_activate` and the consent hold, so pre-exchange
  `client/time` frames legitimately precede `client/pair-init` on the wire and are
  answered here. Suppression begins only once the source has sent `client/pair-init`
  (it sets `pairing != nil`), so every helper *after* this one is strict.

  Opens a fresh `UniversalProxy.SendspinPairingServer` attempt bound to this
  connection's handshake hash and to the `pairing_index` the client chose, so
  a retry after a failed attempt really is a second attempt. Returns
  `{pairing_index, peer}`.
  """
  def await_pair_init!(peer, opts \\ [], timeout \\ @default_timeout) do
    {payload, peer} = await_json!(peer, "client/pair-init", timeout)
    index = Map.fetch!(payload, "pairing_index")

    pairing =
      PairingServer.start(
        handshake_hash: peer.handshake_hash,
        pairing_index: index,
        suite: peer.suite,
        pin_length: Keyword.get(opts, :pin_length, 6)
      )

    {:send, messages, pairing} = PairingServer.handle(pairing, "client/pair-init", payload)
    {index, send_pairing!(%{peer | pairing: pairing}, messages)}
  end

  @doc """
  Type a PIN into "Music Assistant", producing `server/pair-auth`.

  Pass the PIN the source displayed to pair successfully, or anything else to
  make the CPace confirmation fail exactly as a mistyped PIN does.
  """
  def submit_pin!(peer, pin) do
    {:send, messages, pairing} = PairingServer.submit_pin(peer.pairing, pin)
    send_pairing!(%{peer | pairing: pairing}, messages)
  end

  @doc """
  Wait for `client/pair-auth` and answer it with `server/pair-confirm`.

  Strict: once the exchange is live (from `client/pair-init` onwards) aiosendspin's
  `_receive_pairing` does blocking sequential receives and rejects any interleaved
  non-pairing frame as malformed, so this flunks on a stray `client/time` rather
  than tolerating it (`await_pairing_json!/3`).
  """
  def serve_pair_auth!(peer, timeout \\ @default_timeout) do
    {payload, peer} = await_pairing_json!(peer, "client/pair-auth", timeout)
    {:send, messages, pairing} = PairingServer.handle(peer.pairing, "client/pair-auth", payload)
    send_pairing!(%{peer | pairing: pairing}, messages)
  end

  @doc """
  Verify `client/pair-confirm`, unwrap the PSK from `client/pair-finalize` and
  answer `server/pair-finalize`. Returns `{psk, peer}`.

  Strict like `serve_pair_auth!/2`: both receives flunk on any interleaved
  non-pairing frame.
  """
  def serve_pair_finalize!(peer, timeout \\ @default_timeout) do
    {confirm, peer} = await_pairing_json!(peer, "client/pair-confirm", timeout)
    {:ok, pairing} = PairingServer.handle(peer.pairing, "client/pair-confirm", confirm)

    {finalize, peer} = await_pairing_json!(peer, "client/pair-finalize", timeout)
    {:send, messages, pairing} = PairingServer.handle(pairing, "client/pair-finalize", finalize)

    peer = send_pairing!(%{peer | pairing: pairing}, messages)
    {PairingServer.psk(pairing), peer}
  end

  @doc "Wait for a `pair/abort` from the client, returning `{reason, peer}`."
  def await_pair_abort!(peer, timeout \\ @default_timeout) do
    {payload, peer} = await_json!(peer, "pair/abort", timeout)
    {Map.get(payload, "reason"), peer}
  end

  @doc "Abort the attempt from the server side."
  def abort_pairing!(peer, reason) when is_binary(reason) do
    send_message!(peer, "pair/abort", %{"reason" => reason})
  end

  defp send_pairing!(peer, messages) do
    Enum.reduce(messages, peer, fn {type, payload}, peer ->
      send_message!(peer, type, payload)
    end)
  end

  @doc "This peer's current server-domain clock reading, in µs."
  def server_now_us(%__MODULE__{clock_offset_us: offset}) do
    System.monotonic_time(:microsecond) + offset
  end

  @doc """
  Wait for one JSON message of `type`, pumping everything else. Returns
  `{payload, peer}` with the payload string-keyed, exactly as it arrived.
  """
  def await_json!(peer, type, timeout \\ @default_timeout) do
    {{:json, ^type, payload}, peer} =
      pump!(peer, fn event -> match?({:json, ^type, _}, event) end, timeout)

    {payload, peer}
  end

  @doc """
  Wait for one pairing message of `type`, refusing to pump anything else.

  Mirrors aiosendspin's `_receive_pairing`, which does a blocking sequential
  receive of the next expected pairing message and treats ANY other frame — a
  `client/time` keepalive, an audio chunk — as malformed, aborting the pairing.
  So this flunks on a non-pairing frame instead of answering it, which is what
  makes the tests catch keepalive interleaved with a live exchange (the bug that
  broke real MA with "malformed message awaiting ClientPairAuthMessage"). Returns
  `{payload, peer}`.
  """
  def await_pairing_json!(peer, type, timeout \\ @default_timeout) do
    case next!(peer, timeout) do
      {{:json, ^type, payload}, peer} ->
        {payload, peer}

      {other, _peer} ->
        flunk(
          "expected pairing message #{type} but received #{inspect(other)} mid-exchange; " <>
            "a real MA aborts pairing on any frame interleaved with the pairing exchange"
        )
    end
  end

  @doc """
  Pump until a `client/state` whose `available` flag equals `available?`,
  answering `client/time` (and so advancing the clock filter) along the way.

  Robust to the source having started time-syncing before activation: whether
  the filter converges before or after the role activates, this keeps answering
  `client/time` until the desired `client/state` arrives. Returns
  `{payload, peer}`.
  """
  def await_client_state!(peer, available?, timeout \\ @default_timeout) do
    {{:json, "client/state", payload}, peer} =
      pump!(
        peer,
        fn
          {:json, "client/state", payload} -> Map.get(payload, "available") == available?
          _event -> false
        end,
        timeout
      )

    {payload, peer}
  end

  @doc "Wait for one binary audio frame, pumping everything else."
  def await_audio!(peer, timeout \\ @default_timeout) do
    {{:audio, timestamp_us, payload}, peer} =
      pump!(peer, fn event -> match?({:audio, _, _}, event) end, timeout)

    {timestamp_us, payload, peer}
  end

  @doc """
  Answer exactly `count` `client/time` messages, stashing anything else.

  Two answered exchanges are all `ClockFilter.converged?/1` needs.
  """
  def serve_time!(peer, count, timeout \\ @default_timeout) do
    Enum.reduce(1..count, peer, fn _index, peer ->
      {{:json, "client/time", payload}, peer} =
        pump!(peer, fn event -> match?({:json, "client/time", _}, event) end, timeout)

      reply_time!(peer, payload)
    end)
  end

  @doc "Close the underlying TCP connection without a websocket close frame."
  def close!(peer) do
    Mint.HTTP.close(peer.conn)
    :ok
  end

  @doc """
  Whether the source closed this connection — either a websocket close frame
  or a bare TCP close, both of which a replaced connection may produce.
  """
  def closed?(peer, timeout \\ @default_timeout) do
    case Mint.WebSocket.recv(peer.conn, 0, timeout) do
      {:ok, conn, [{:data, _ref, data}]} ->
        {:ok, websocket, frames} = Mint.WebSocket.decode(peer.websocket, data)

        Enum.any?(frames, &match?({:close, _code, _reason}, &1)) or
          closed?(%{peer | conn: conn, websocket: websocket}, timeout)

      {:error, _conn, _error, _responses} ->
        true
    end
  end

  # -- Pumping --

  defp pump!(peer, match_fun, timeout), do: pump!(peer, match_fun, timeout, true)

  defp pump!(peer, match_fun, timeout, answer_time?) do
    {event, peer} = next!(peer, timeout)

    cond do
      match_fun.(event) ->
        {event, peer}

      answer_time? and match?({:json, "client/time", _}, event) ->
        {:json, _type, payload} = event
        peer |> reply_time!(payload) |> pump!(match_fun, timeout, answer_time?)

      match?({:audio, _, _}, event) ->
        {:audio, timestamp_us, payload} = event

        pump!(
          %{peer | audio: [{timestamp_us, payload} | peer.audio]},
          match_fun,
          timeout,
          answer_time?
        )

      true ->
        pump!(%{peer | messages: [event | peer.messages]}, match_fun, timeout, answer_time?)
    end
  end

  defp reply_time!(peer, %{"client_transmitted" => transmitted}) do
    received = server_now_us(peer)

    peer =
      send_message!(peer, "server/time", %{
        "client_transmitted" => transmitted,
        "server_received" => received,
        "server_transmitted" => server_now_us(peer)
      })

    %{peer | time_exchanges: peer.time_exchanges + 1}
  end

  defp next!(peer, timeout) do
    case next_ws!(peer, timeout) do
      {{:binary, data}, peer} -> {decode_transport!(peer, data), peer}
      {frame, peer} -> {frame, peer}
    end
  end

  defp decode_transport!(peer, data) do
    plaintext = IO.iodata_to_binary(Decibel.decrypt(peer.noise, data))

    case Wire.decode_frame(plaintext, Wire.Reassembler.new()) do
      {:complete, {:json, body}, _reassembler} ->
        {:ok, type, payload} = Wire.decode_envelope(body)
        {:json, type, payload}

      {:complete, {:audio, timestamp_us, payload}, _reassembler} ->
        {:audio, timestamp_us, payload}

      other ->
        flunk("unexpected transport frame: #{inspect(other)}")
    end
  end

  defp expect_text!(peer, timeout) do
    {{:text, text}, peer} = next_ws!(peer, timeout)
    {text, peer}
  end

  # -- Websocket plumbing --

  defp send_ws!(peer, frame) do
    {:ok, websocket, data} = Mint.WebSocket.encode(peer.websocket, frame)
    {:ok, conn} = Mint.WebSocket.stream_request_body(peer.conn, peer.ref, data)
    %{peer | websocket: websocket, conn: conn}
  end

  defp next_ws!(%__MODULE__{frames: [frame | rest]} = peer, _timeout) do
    {frame, %{peer | frames: rest}}
  end

  defp next_ws!(peer, timeout) do
    case Mint.WebSocket.recv(peer.conn, 0, timeout) do
      {:ok, conn, [{:data, _ref, data}]} ->
        {:ok, websocket, frames} = Mint.WebSocket.decode(peer.websocket, data)
        next_ws!(%{peer | conn: conn, websocket: websocket, frames: frames}, timeout)

      {:error, _conn, error, _responses} ->
        flunk("websocket receive failed: #{inspect(error)}")
    end
  end

  defp await_upgrade(conn, ref, acc) do
    {:ok, conn, responses} = Mint.HTTP.recv(conn, 0, @default_timeout)

    acc =
      Enum.reduce(responses, acc, fn
        {:status, ^ref, status}, acc -> Map.put(acc, :status, status)
        {:headers, ^ref, headers}, acc -> Map.put(acc, :headers, headers)
        _other, acc -> acc
      end)

    case acc do
      %{status: status, headers: headers} -> {conn, status, headers}
      _incomplete -> await_upgrade(conn, ref, acc)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)
end
