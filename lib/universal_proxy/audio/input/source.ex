defmodule UniversalProxy.Audio.Input.Source do
  @moduledoc """
  One capture card's Sendspin `source@v1` client: a websocket listener plus
  the connection FSM that speaks the protocol over whatever Music Assistant
  dials into it.

  ## Direction

  We are the Sendspin **client** but we **host** the socket: MA discovers our
  `_sendspin._tcp` mDNS advertisement and connects in
  (`aiosendspin`'s `SendspinConnection.attach_websocket`, ground truth §2).
  The protocol roles are unaffected by that — we still send `client/init`
  first, and MA is still the Noise **initiator** while we are the responder.

  ## Listener

  `init/1` starts a per-source `Plug.Cowboy` listener under ranch (via
  `Plug.Cowboy.http/3` with a unique `:ref`), serving only
  `#{inspect(__MODULE__)}.default_path/0` through
  `UniversalProxy.Audio.Input.Source.Listener`. The listener is *not* linked
  to us — ranch supervises it — so `terminate/2` shuts it down explicitly
  with `Plug.Cowboy.shutdown/1`.

  Passing `port: 0` (the default) lets the OS allocate; the actually-bound
  port is read back from `:ranch.get_port/1` and reported to the owner as
  `{:listener_bound, port}` **before** any connection can arrive. That
  notification is the mDNS-deferral contract: the owner (P4-T2) must not
  advertise the service until it fires, mirroring how `Audio.Player` defers
  registration until the C++ binary's `listening` event (registering into
  the spawn-to-bind gap makes MA burn its one-shot discovery connect).

  ## Connection FSM

      :listening            no MA connection; the listener is up
      :awaiting_server_init sent client/init, waiting for server/init
      :awaiting_handshake   waiting for Noise message 1
      :awaiting_server_hello sent Noise message 2, transport mode is up
      :awaiting_activate    sent client/hello; the `client/time` clock-sync
                            loop runs from the first server/activate on, for
                            the rest of the connection
      :pairing_required     an unpaired session was offered the pairing
                            activity; we are holding a code offer for operator
                            consent, or an attempt is running or waiting to be
                            re-offered
      :awaiting_rehandshake pairing completed; waiting for the server to
                            re-run the Noise handshake in band
      :syncing              source@v1 active; reports available once the
                            (already-running) clock filter converges
      :ready                converged and available; not streaming
      :streaming            capture running, audio frames going out
      :degraded             connected and active, but capture cannot start
                            (no arecord binary / spawn failure)

  Exactly one MA connection at a time. A second inbound connection
  **replaces** the first (see "Protocol decisions" below).

  ## Keys and activation

  Noise message 1 names the PSK the server keys the session with (`psk_id`)
  and the category it uses it as (`psk_category`): our **long-term** PSK from
  a completed pairing, our **pairing PSK** (the secret behind the input's
  pairing token, `Store.pairing_token/2`), or the public **Sentinel**. A
  `psk_id` we do not hold under that category falls back to the Sentinel in
  the initial handshake (`connection.md` "Sentinel Fallback") and fails a
  re-handshake. We advertise `unpaired_access: false`, so only a long-term
  session may activate `source@v1` (internally: trust `user`); an unpaired one
  that asks for playback or roles is closed with `client/goodbye`
  `pairing_required`, and a long-term one offered pairing with
  `unauthorized`.

  ## Pairing

  We offer two methods (`client/hello` `supported_pair_methods`):

    * **Pairing PSK** — the operator pastes the input's pairing token into
      Music Assistant, which (re-)handshakes to the pairing PSK and offers
      `pairing_psk`. Holding the token is the authorization, so the attempt
      opens at once: `client/pair-init` + `client/pair-finalize
      {long_term_psk}`.
    * **Dynamic pairing code** (`digits`, shown on the Audio tab). This is
      gated on an explicit **local operator gesture** (`allow_pairing/1`, a
      button on the Audio tab). A peer-sent offer on its own does **not** open
      an attempt: we **hold** it in `:pairing_required` and tell the server so
      with `client/pair-pending`, surfacing the "Allow pairing" affordance. Only
      once the operator opens a time-boxed (120 s) window do we send
      `client/pair-init` and drive `UniversalProxy.Sendspin.Pairing` through
      the CPace exchange. If the operator never consents, a consent-wait
      timeout (also 120 s) sends `pair/abort` and returns the connection to
      idle — an un-consented offer never pairs. Attempts are capped at 3 per
      connection with a backoff between them, and mistyped codes retry in
      further rounds up to the spec's 20-round limit per consent window.

  Either method stores a **pairing record** for the server (up to 8 per
  input, `Store.save_pairing/4`): it replaces that server's earlier record or
  is added beside the others, so pairing a second server never evicts the
  first unless storage is full. A paired server may drop its record with
  `server/unpair` (we remove ours, say `client/goodbye` `unpaired` and close);
  the operator can do the same per server from the Audio tab, or regenerate the
  pairing token (`pairings_changed/1` closes a session whose record or pairing
  PSK is gone).

  **We derive and display the code** — the operator types it into Music
  Assistant, not the other way round. It surfaces as `{:pairing_pin, pin}`
  once `server/pair-init` reveals the server's nonce.

  A completed attempt persists the minted PSK via `Store.save_pairing/4` and
  the server then re-runs the Noise handshake **in band**: two
  `noise/handshake` messages carried as ordinary encrypted JSON, prologued
  with the *previous* handshake's hash, our message 2 still encrypted under the
  old session. The server's next message is a fresh `server/activate` (no
  hellos are replayed), and until it arrives we send nothing else. Connection
  state — the FSM, an open stream, the clock filter — persists across it; only
  the keys, the matched PSK and the pairing counter change.

  An attempt that fails — a `pair/abort` from the server, our round limit, or
  our own 120 s window expiring — leaves the connection up and the FSM back in
  `:pairing_required`, because the server retries by sending another pairing
  `server/activate` and each one increments `pairing_index`.

  ## Streaming lifecycle

  `source@v1` streaming is *server-commanded*: the default after a handshake
  is stopped, and a server MUST NOT be sent audio until it asks
  (`roles/source/v1.md` "Default streaming behavior"; a `client-stream/start`
  without a preceding `server/command.source.command = "start"` is a protocol
  error). So capture is spawned and `client-stream/start` sent only on that
  command, and `stop` tears both down again with a `client-stream/end`. Both
  directions are idempotent. Every `client/state` an active source sends
  carries the (full) `source` object.

  Audio frames are stamped in the **server's** clock domain:
  `ClockFilter.server_time/2` maps our local capture time forward. Both the
  `client/time` exchange and `Capture`'s frame stamps use
  `System.monotonic_time/1`, so the filter sees one consistent local basis
  with no clock conversion — monotonic never jumps or slews on an NTP sync,
  which a `System.os_time/1` capture stamp could.

  ## Owner notifications

  Every event is `{:source_event, key, event}` sent to the `:owner` pid:

      {:listener_bound, port}     listener is bound; safe to advertise mDNS
      :connected                  MA opened a websocket, client/init sent
      :activated                  server/activate granted source@v1
      {:pairing_required, params} activate withheld source@v1 and offered
                                  pairing; `params` is the activate message's
                                  `pairing` object (or `nil`). Awaiting the
                                  operator's `allow_pairing/1` gesture.
      {:pairing_window, expires}  the consent window opened (`expires` = Unix
                                  second) or closed (`nil`)
      :pairing_started            client/pair-init sent, attempt running
      {:pairing_pin, pin}         show this PIN; the user types it into MA
      :unpaired                   the server unpaired us (`server/unpair`);
                                  its record is removed
      :paired                     PSK minted and persisted; awaiting the
                                  post-pairing re-handshake
      :pairing_declined           a held offer expired without the operator's
                                  consent; we sent `pair/abort` and are back
                                  connected-and-idle
      {:pairing_failed, reason}   attempt abandoned; MA may offer another
      :streaming                  capture up, client-stream/start sent
      :stopped                    streaming ended (server stop or capture exit)
      :disconnected               connection gone; the listener stays up
      {:capture_missing, path}    no arecord binary — FSM is :degraded
      {:error, reason}            protocol/crypto/capture failure

  PubSub is the owner's job (P4-T2); this module only messages a pid.

  ## Protocol decisions where the ground truth is silent

    * **Second inbound connection: replace only an un-authenticated incumbent.**
      Neither the spec nor aiosendspin says what a client listener does with a
      second server connection. Rejecting outright risks a permanent lockout: a
      half-open TCP connection (Pi sleeps, MA container restarts) would keep the
      old socket "alive" from our side forever while MA redials into a refusal.
      So an incumbent that has *not* authenticated (trust `none`, still
      handshaking) is replaced — self-healing. But a trust-`user` incumbent
      (paired, possibly streaming) is **not** evicted for a peer that has proven
      nothing: the challenger is parked, the incumbent is probed for liveness
      (a `client/time` round trip), and the challenger is promoted only if the
      incumbent fails that probe. Accepts are also rate-limited per source.
    * **No outbound fragmentation.** Every message we send is far below the
      65535-byte Noise transport limit (a 20 ms PCM frame is 3,849 bytes), so
      we only *decode* fragments (type 1, via `Wire.Reassembler`), never emit
      them.
    * **Capture frames are dropped across a re-handshake.** Between Noise
      message 1 and the next `server/activate` the client may send nothing but
      the handshake, so frames captured in that window are discarded rather
      than queued; the stream itself stays open and resumes, or is ended with
      `client-stream/end`, depending on what that activation keeps.
  """

  # `:temporary` — the owner (`Audio.Input.Server`, P4-T2) holds the per-card
  # state needed to spawn a replacement (port, key, alsa device) and drives
  # respawn from its convergence pass, exactly as `Audio.Server` does for
  # `Audio.Player`.
  use GenServer, restart: :temporary

  require Logger

  alias UniversalProxy.Audio.Input.Capture
  alias UniversalProxy.Audio.Input.DeviceInfo
  alias UniversalProxy.Audio.Input.Source.Listener
  alias UniversalProxy.Audio.Input.Store
  alias UniversalProxy.Sendspin.ClockFilter
  alias UniversalProxy.Sendspin.Noise
  alias UniversalProxy.Sendspin.Pairing
  alias UniversalProxy.Sendspin.Wire

  # `API_PATH` in aiosendspin, "Fixed by protocol". The mDNS TXT `path` key
  # must match it (and must start with "/" or MA ignores the service).
  @ws_path "/sendspin"
  @protocol_version 1
  @default_suite "25519_ChaChaPoly_SHA256"
  @source_role "source@v1"

  # Our capture format. MA resamples everything to 48k/16/2 internally, so
  # matching it just avoids a resample (ground truth §7.5).
  @codec :pcm
  @sample_rate 48_000
  @channels 2
  @bit_depth 16

  # aiosendspin's `_compute_time_sync_interval`: burst until synchronised,
  # then back off on the filter's own error estimate (ground truth §6).
  @time_burst_ms 200
  @time_intervals [{1_000, 3_000}, {2_000, 1_000}, {5_000, 500}]

  # Cowboy's websocket idle timeout (fires if we *receive* nothing for this
  # long). Our `client/time` loop runs for the whole life of the connection —
  # from `:awaiting_activate` on, not just while streaming — so the server's
  # `server/time` replies keep inbound traffic flowing and this never trips on a
  # live-but-idle (e.g. connected-yet-unpaired) session. Its cadence tops out at
  # 3 s, so an actual timeout here means a peer that has genuinely gone silent.
  @ws_timeout_ms 60_000

  # Cap the accepted inbound websocket frame size. Each inbound binary frame
  # carries exactly one Noise transport message (its AEAD ciphertext), which
  # the Noise spec bounds at 65535 bytes — larger Sendspin app messages
  # fragment at the Sendspin layer (types 2/3) into separate ≤64 KiB Noise
  # messages, each its own WS frame. So no legitimate frame exceeds this, and
  # WebSockAdapter's 10 MB default would otherwise let a sentinel-PSK LAN peer
  # force repeated multi-MB allocations + crypto (the reassembler's 1 MB cap
  # only kicks in *after* a full frame is received and decrypted).
  @max_ws_frame_bytes 65_535

  # Noise message 2's inner plaintext is the literal two bytes `{}` — an empty
  # payload is rejected by aiosendspin's `_validate_msg2_payload`.
  @noise_msg2_payload "{}"

  @sentinel_psk_id Pairing.psk_id_for(Noise.sentinel_psk())

  # Server-sent pairing messages, in flow order. `pair/abort` is deliberately
  # not one of them: `Wire` has already turned its reason into an atom, so it
  # is handled here instead of round-tripping through `Pairing`.
  @server_pairing_tags [
    :server_pair_init,
    :server_pair_auth,
    :server_pair_confirm,
    :server_pair_finalize
  ]

  # The `source@v1` states, in which the role is active on this connection.
  @active_states [:syncing, :ready, :streaming, :degraded]

  # Shown by the server while we hold a code offer for the operator's gesture
  # (`client/pair-pending`, at most 200 characters).
  @pair_pending_message "Open the Audio tab on the device and click Allow pairing."

  # In-band re-handshakes an unpaired session may drive per connection. Each of
  # the `@max_pairing_attempts` (3) attempts a server may run costs at most two:
  # into the pairing PSK and, if it is cancelled, back to its record (or the
  # post-pairing re-key to the new record on success). Two more cover a key
  # rotation and a retry after a dropped re-key. The cap bounds a
  # Sentinel-keyed peer looping handshakes for the X25519 work.
  @max_unpaired_rehandshakes 8

  # Code pairing is gated on an explicit local operator gesture
  # (`allow_pairing/1`): a peer-sent pairing `server/activate` never opens a
  # code attempt on its own. The window is time-boxed, at most three attempts
  # run per connection, each retry backs off, and the code rounds within one
  # window are capped at the spec's round limit — bounding an online code
  # brute force.
  @max_pairing_attempts 3
  @pairing_backoff_ms 300
  @pairing_window_ms 120_000

  # How many un-consented pairing offers a source may HOLD within `@hold_window_ms`
  # before we stop re-arming the "Allow pairing" prompt and decline outright. The
  # budget is tracked in `hold_times` (monotonic-ms stamps) which SURVIVES a
  # teardown, so it bounds a peer that lets each hold lapse and immediately
  # re-offers — including across reconnects — rather than per-connection (a
  # per-connection counter zeroed at teardown was defeatable by replacing the
  # held connection every `pairing_window_ms`). The window spans several
  # 120 s hold cycles so a handful of genuine offers still get through.
  #
  # Residual: the `/audio` UI that shows the prompt is itself unauthenticated, so
  # bounding the hold is the mitigation; gating that UI is separate, larger work.
  @max_holds 3
  @hold_window_ms 600_000

  # A per-source accept rate limit, sized only to catch pathological churn (a
  # peer wedged in a tight connect/disconnect loop). It is a secondary backstop:
  # the real protection against a live session being flapped lives in the
  # eviction rules below (a trust-`user` incumbent is never evicted for an
  # un-authenticated challenger). Kept generous so MA's normal reconnect and
  # operator-initiated pairing-dial cadence is never refused.
  @max_accepts 30
  @accept_window_ms 60_000

  # How long the incumbent has to prove liveness before a parked challenger is
  # promoted. A live trust-`user` or actively-pairing session answers a
  # `client/time` (or sends a pairing frame) inside this. Overridable per source
  # (`:incumbent_probe_ms`) as a test seam.
  @incumbent_probe_ms 5_000

  # The outbound audio path is bounded: if the socket process falls this far
  # behind (a stalled MA peer), frames are dropped rather than queued, so a
  # slow consumer can't grow the connection's mailbox without limit. Dropping
  # audio is the correct failure for a real-time capture path.
  @max_outbound_backlog 32

  # Ranch per-listener connection cap. One MA connection at a time plus a
  # little slack for a parked challenger and reconnect races.
  @max_connections 8

  # Attacker-controlled text (server_id, peer-chosen abort reasons) is bounded
  # before it reaches the log so a peer can't flood RingLogger.
  @log_reason_max 200

  # Per-connection bookkeeping (see the `conn` field).
  @conn_defaults %{
    rekeying: false,
    unpaired_rehandshakes: 0,
    pairing_attempts: 0,
    record_id: nil,
    stream_end_pending: false
  }

  @derive {Inspect, except: [:keypair]}
  defstruct [
    :key,
    :alsa_device,
    :name,
    :store,
    :owner,
    :path,
    :requested_port,
    :listener_ref,
    :bound_port,
    :suite,
    :capture_opts,
    :device_info,
    :pair_methods,
    :time_burst_ms,
    :socket,
    :socket_monitor,
    :client_init,
    :server_init,
    :server_id,
    :remote_static,
    :client_id,
    :keypair,
    :noise,
    :handshake_hash,
    :psk_category,
    :capture,
    :stopping_capture,
    :time_timer,
    :pairing,
    :pairing_timer,
    :pairing_timeout_ms,
    :listen_ip,
    :parked_socket,
    :parked_monitor,
    :liveness_timer,
    :last_pairing_params,
    :pairing_attempt_timer,
    :consent_wait_timer,
    :consent_wait_gen,
    :pairing_timer_gen,
    :liveness_gen,
    :pairing_window_ms,
    :incumbent_probe_ms,
    fsm: :listening,
    trust: :none,
    # Per-connection bookkeeping, reset at teardown: `rekeying` holds between
    # Noise message 1 of an in-band re-handshake and the next
    # `server/activate` (nothing but the handshake may be sent), with a
    # `client-stream/end` due at that activation in `stream_end_pending`; the
    # two counters bound unpaired re-handshakes and pairing attempts; and
    # `record_id` is the `psk_id` of the pairing record (or pairing PSK) keying
    # the session, `nil` under the Sentinel.
    conn: @conn_defaults,
    # The operator's open "allow pairing" consent window, `nil` when closed:
    # its timer and the code rounds emitted under it (`pairing.md` "Rounds" —
    # opening a window is the operator action that resets the count).
    pairing_window: nil,
    reassembler: nil,
    filter: nil,
    outstanding: [],
    start_requested: false,
    pairing_index: 0,
    accepts: [],
    frames_dropped: 0,
    # A monotonic counter stamped into every cross-connection-risky timer
    # message (`:consent_wait_timeout`, `:pairing_timeout`,
    # `:incumbent_liveness_timeout`). `Process.cancel_timer/1` cannot retract an
    # already-queued message, so a teardown+reconnect can leave a stale timeout
    # from an old connection in the mailbox; the handlers drop any whose gen no
    # longer matches the armed timer's `*_gen`. Never reset (monotonic across
    # connections keeps every gen unique).
    timer_gen: 0,
    # Monotonic-ms timestamps of the un-consented pairing offers this source has
    # HELD, within a sliding `@hold_window_ms`. Deliberately NOT reset on
    # teardown (like `accepts`): a per-connection counter would let an unpaired
    # peer zero the budget by replacing its held connection every `pairing_window_ms`,
    # keeping the "Allow pairing" prompt showable forever. Bounding across
    # reconnects is the point.
    hold_times: []
  ]

  @type key :: Store.input_key()

  @type event ::
          {:listener_bound, :inet.port_number()}
          | :connected
          | :activated
          | {:pairing_required, map() | nil}
          | :pairing_started
          | {:pairing_pin, String.t()}
          | :paired
          | :unpaired
          | {:pairing_failed, term()}
          | :pairing_declined
          | :streaming
          | :stopped
          | :disconnected
          | {:capture_missing, String.t()}
          | {:error, term()}

  # -- Client API --

  @doc """
  The websocket path we serve, and therefore the value the mDNS TXT `path`
  key must carry.
  """
  @spec default_path() :: String.t()
  def default_path, do: @ws_path

  @doc """
  Start a source for one capture card.

  Options:

    * `:key` (required) — `{slot_sub, vid, pid}`, as `Audio.Input.Enumerate`
      produces.
    * `:alsa_device` (required) — e.g. `"plughw:1,0"`.
    * `:name` — the `client/hello.name` MA renders in its source list;
      defaults to the key's `slot_sub`.
    * `:owner` — pid receiving `{:source_event, key, event}`; defaults to the
      caller.
    * `:store` — `Audio.Input.Store` server reference.
    * `:port` — listener port; `0` (default) lets the OS allocate.
    * `:path` — websocket path; defaults to `#{@ws_path}`.
    * `:suite` — Noise cipher suite; defaults to `#{@default_suite}`.
    * `:capture_opts` — extra options merged into `Capture.start_link/1`
      (test seam for `:arecord_path` / `:args` / `:frame_bytes`).
    * `:device_info` — `client/hello.device_info` map; defaults to the same
      product/manufacturer/version/mac `Audio.Player` reports.
    * `:time_burst_ms` — pre-convergence `client/time` cadence (default
      #{@time_burst_ms}).
    * `:pairing_timeout_ms` — how long one pairing attempt may take before we
      send `pair/abort` with `attempt_timeout` (default
      `Sendspin.Pairing.attempt_timeout_ms/0`, 120 s).
    * `:pairing_window_ms` — the consent window: both how long a held pairing
      offer waits for the operator's `allow_pairing/1` gesture and how long an
      opened window stays open (default #{@pairing_window_ms}, 120 s).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name_registration))
  end

  @doc "The port the listener actually bound."
  @spec port(GenServer.server()) :: :inet.port_number()
  def port(server), do: GenServer.call(server, :port)

  @doc "The current FSM state — see the moduledoc for the full list."
  @spec status(GenServer.server()) :: atom()
  def status(server), do: GenServer.call(server, :status)

  @doc """
  Open a time-boxed local "allow pairing" window (the operator consent
  gesture). Until this is called, a peer-sent pairing `server/activate` is
  **held** (not aborted) until the consent-wait timeout. If an offer is already
  pending on the live connection, opening the window proceeds straight to
  `client/pair-init`; otherwise it pre-authorizes the next offer.
  """
  @spec allow_pairing(GenServer.server()) :: :ok
  def allow_pairing(server), do: GenServer.cast(server, :allow_pairing)

  @doc """
  The input's pairing records or pairing PSK changed outside this process (an
  operator unpaired a server or regenerated the token). A live session keyed
  by a record or pairing PSK that is gone is closed; the server can re-pair.
  """
  @spec pairings_changed(GenServer.server()) :: :ok
  def pairings_changed(server), do: GenServer.cast(server, :pairings_changed)

  # -- Server callbacks --

  @impl GenServer
  def init(opts) do
    # Trap exits so `terminate/2` runs on a supervisor shutdown (the ranch
    # listener is not linked to us and would otherwise leak its port), and so
    # a linked `Capture` exiting never takes the FSM down with it.
    Process.flag(:trap_exit, true)

    {slot_sub, _vid, _pid} = key = Keyword.fetch!(opts, :key)

    state = %__MODULE__{
      key: key,
      alsa_device: Keyword.fetch!(opts, :alsa_device),
      name: Keyword.get(opts, :name, slot_sub),
      store: Keyword.get(opts, :store, Store),
      owner: Keyword.get(opts, :owner, self()),
      path: Keyword.get(opts, :path, @ws_path),
      requested_port: Keyword.get(opts, :port, 0),
      suite: Keyword.get(opts, :suite, @default_suite),
      capture_opts: Keyword.get(opts, :capture_opts, []),
      device_info: Keyword.get_lazy(opts, :device_info, &default_device_info/0),
      pair_methods: Keyword.get(opts, :supported_pair_methods, default_pair_methods()),
      time_burst_ms: Keyword.get(opts, :time_burst_ms, @time_burst_ms),
      pairing_timeout_ms: Keyword.get(opts, :pairing_timeout_ms, Pairing.attempt_timeout_ms()),
      pairing_window_ms: Keyword.get(opts, :pairing_window_ms, @pairing_window_ms),
      incumbent_probe_ms: Keyword.get(opts, :incumbent_probe_ms, @incumbent_probe_ms),
      listen_ip: Keyword.get(opts, :listen_ip, :any),
      reassembler: Wire.Reassembler.new(),
      filter: ClockFilter.new()
    }

    case start_listener(state) do
      {:ok, state} ->
        notify(state, {:listener_bound, state.bound_port})
        {:ok, state}

      {:error, reason} ->
        Logger.error(
          "Audio.Input.Source #{inspect(key)} could not bind a websocket listener: " <>
            inspect(reason)
        )

        {:stop, {:listener_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call(:port, _from, state), do: {:reply, state.bound_port, state}
  def handle_call(:status, _from, state), do: {:reply, state.fsm, state}

  @impl GenServer
  def handle_cast(:allow_pairing, state) do
    {:noreply, open_pairing_window(state)}
  end

  def handle_cast(:pairings_changed, state) do
    if session_key_revoked?(state) do
      Logger.info(
        "Audio.Input.Source #{inspect(state.key)} closing a session whose pairing was revoked"
      )

      # No `client/goodbye`: the server's next dial lands in the Sentinel
      # Fallback, which tells it our record is gone and offers re-pairing.
      state = teardown_connection(state, :pairing_revoked)
      notify(state, :disconnected)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:sendspin_ws_open, pid}, state) do
    cond do
      not accept_allowed?(state) ->
        Logger.warning(
          "Audio.Input.Source #{inspect(state.key)} accept rate limit exceeded; " <>
            "refusing new connection"
        )

        send(pid, {:sendspin_ws_close, :rate_limited})
        {:noreply, state}

      is_nil(state.socket) ->
        {:noreply, adopt_socket(record_accept(state), pid)}

      # A trust-`user` (paired) session is authenticated; do not evict it for a
      # peer that has proven nothing. Park the challenger and probe the
      # incumbent — it only yields if it fails a liveness check (half-open TCP).
      state.trust == :user ->
        {:noreply, park_socket(record_accept(state), pid)}

      # A CONSENTED pairing exchange is mid-flight on the incumbent (a live CPace
      # attempt or the post-pairing re-handshake). It is still trust `none`, but
      # tearing it down for a concurrent MA connection — MA opens several during
      # interactive PIN pairing — would discard the in-progress exchange the
      # operator is actively completing. A merely HELD, pre-consent offer is NOT
      # covered (see `pairing_in_progress?/1`): it carries no consented state and
      # falls through to the un-authenticated self-heal replace below. Park the
      # challenger, but WITHOUT the promote-on-silence liveness probe: the
      # exchange is legitimately silent while the operator reads and types the PIN
      # (routinely longer than the probe window), so probing would mistake a slow
      # human for a dead incumbent and tear the live pairing down. The exchange
      # bounds itself (pairing timeout / socket close); once it resolves,
      # `maybe_probe_parked/1` re-probes any still-parked challenger.
      pairing_in_progress?(state) ->
        {:noreply, park_socket(record_accept(state), pid)}

      true ->
        # The incumbent is still un-authenticated (mid-handshake): most likely
        # a half-open TCP left by a peer that vanished during setup. Replacing
        # it is self-healing and can't cost an authenticated session.
        Logger.info(
          "Audio.Input.Source #{inspect(state.key)} replacing an un-authenticated connection"
        )

        state =
          state
          |> teardown_connection(:replaced)
          |> tap(&notify(&1, :disconnected))

        {:noreply, adopt_socket(record_accept(state), pid)}
    end
  end

  def handle_info({:sendspin_ws_in, pid, opcode, data}, %{socket: pid} = state) do
    # Any inbound frame from the incumbent proves it is alive, so a parked
    # challenger loses the liveness race and is dropped.
    state = incumbent_alive(state)

    case handle_frame(state, opcode, data) do
      {:ok, state} -> {:noreply, state}
      {:error, reason, state} -> {:noreply, fail(state, reason)}
    end
  end

  # A frame from a socket we already replaced, parked, or tore down.
  def handle_info({:sendspin_ws_in, _stale, _opcode, _data}, state), do: {:noreply, state}

  # The parked challenger died before it could be promoted — just forget it.
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{parked_monitor: monitor} = state) do
    {:noreply, %{cancel_liveness_timer(state) | parked_socket: nil, parked_monitor: nil}}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{socket_monitor: monitor} = state) do
    state = teardown_connection(state, :peer_closed)
    notify(state, :disconnected)
    {:noreply, state}
  end

  # The incumbent never answered the liveness probe: treat it as a dead
  # half-open connection and promote the parked challenger. Guarded on the timer
  # gen so a stale probe timeout from an old connection can't promote an
  # unrelated later challenger before its own probe elapses.
  def handle_info(
        {:incumbent_liveness_timeout, gen},
        %{liveness_gen: gen, parked_socket: pid} = state
      )
      when not is_nil(gen) and is_pid(pid) do
    Logger.info(
      "Audio.Input.Source #{inspect(state.key)} incumbent failed liveness probe; " <>
        "promoting the parked connection"
    )

    if state.parked_monitor, do: Process.demonitor(state.parked_monitor, [:flush])

    state = %{
      state
      | parked_socket: nil,
        parked_monitor: nil,
        liveness_timer: nil,
        liveness_gen: nil
    }

    state =
      state
      |> teardown_connection(:liveness_failed)
      |> tap(&notify(&1, :disconnected))

    {:noreply, adopt_socket(state, pid)}
  end

  # Stale or superseded probe timeout, or one with no challenger still parked:
  # drop it without touching the current timer.
  def handle_info({:incumbent_liveness_timeout, _gen}, state) do
    {:noreply, state}
  end

  def handle_info(:pairing_window_timeout, state) do
    {:noreply, close_pairing_window(state)}
  end

  # The held pairing offer expired without an `allow_pairing/1` gesture. Only act
  # when the gen still matches the armed timer (else this is a stale timeout from
  # an old connection or a superseded arm — see `timer_gen`) and we are still
  # genuinely holding (no attempt opened, socket up).
  def handle_info(
        {:consent_wait_timeout, gen},
        %{consent_wait_gen: gen, fsm: :pairing_required, pairing: nil, socket: socket} = state
      )
      when not is_nil(gen) and not is_nil(socket) do
    {:noreply, decline_held_offer(state, :user_cancelled)}
  end

  # A stale or superseded consent-wait timeout: drop it without touching the
  # current timer (which, if set, belongs to a live hold we must not cancel).
  def handle_info({:consent_wait_timeout, _gen}, state) do
    {:noreply, state}
  end

  def handle_info({:open_pairing_attempt, params}, state) do
    if can_open_pairing?(state, params) do
      case open_pairing_now(%{state | pairing_attempt_timer: nil}, params) do
        {:ok, state} -> {:noreply, state}
        {:error, reason, state} -> {:noreply, fail(state, reason)}
      end
    else
      {:noreply, %{state | pairing_attempt_timer: nil}}
    end
  end

  # While a pairing attempt is actively exchanging (`pairing != nil`, i.e. from
  # `client/pair-init` until the attempt resolves), MA drives a strict sequential
  # `_receive_pairing`: any interleaved non-pairing frame — a `client/time`
  # keepalive included — is treated as a malformed message and aborts pairing.
  # So keep the loop armed (preserving the ClockFilter, which must not re-converge
  # afterwards) but skip the send until the exchange ends. The consent HOLD
  # (`pairing == nil` in `:pairing_required`) is unaffected, so a held offer still
  # keeps the connection alive.
  def handle_info(:time_tick, %{pairing: %Pairing{}} = state) do
    {:noreply, schedule_time_tick(state, time_interval(state))}
  end

  def handle_info(:time_tick, state), do: {:noreply, send_time_request(state)}

  def handle_info({:pairing_timeout, gen}, %{pairing_timer_gen: gen, pairing: %Pairing{}} = state)
      when not is_nil(gen) do
    state.pairing
    |> Pairing.abort(:attempt_timeout)
    |> apply_pairing_step(state)
    |> resolve_pairing_step()
  end

  # Stale (old-connection or superseded) or fired-after-resolve pairing timeout.
  def handle_info({:pairing_timeout, _gen}, state), do: {:noreply, state}

  def handle_info(
        {:capture_frame, ts_us, frame},
        %{fsm: :streaming, conn: %{rekeying: false}} = state
      ) do
    if outbound_congested?(state) do
      {:noreply, drop_frame(state)}
    else
      server_us = ClockFilter.server_time(state.filter, ts_us)

      case Noise.encrypt(state.noise, Wire.encode_audio_frame(server_us, frame)) do
        {:ok, ciphertext} ->
          push(state, {:binary, ciphertext})
          {:noreply, state}

        {:error, reason} ->
          {:noreply, fail(state, reason)}
      end
    end
  end

  # Frames that raced a `stop`, arrived while degraded, or were captured during
  # a re-handshake are dropped: the server MUST NOT receive chunks outside an
  # open stream, and nothing but the handshake may go out while re-keying.
  def handle_info({:capture_frame, _ts_us, _frame}, state), do: {:noreply, state}

  def handle_info({:capture_exit, status}, state) do
    Logger.warning(
      "Audio.Input.Source #{inspect(state.key)} capture exited with status #{status}"
    )

    notify(state, {:error, {:capture_exit, status}})
    {:noreply, end_stream(%{state | capture: nil})}
  end

  # `Capture` is linked (it stops itself after reporting `:capture_exit`), so
  # its exit signal is expected noise once we trap exits.
  def handle_info({:EXIT, pid, _reason}, %{capture: pid} = state) do
    {:noreply, end_stream(%{state | capture: nil})}
  end

  # The capture we asked to stop (asynchronously, see `stop_capture/1`) has
  # finally terminated, so the ALSA device is only now released. Any deferred
  # `start` is safe to open here — `start_requested` is the pending-start
  # intent (a `stop`/teardown clears it, cancelling the deferral).
  def handle_info({:EXIT, pid, _reason}, %{stopping_capture: pid} = state) do
    case maybe_start_streaming(%{state | stopping_capture: nil}) do
      {:ok, state} -> {:noreply, state}
      {:error, reason, state} -> {:noreply, fail(state, reason)}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(message, state) do
    Logger.debug("Audio.Input.Source #{inspect(state.key)} ignoring #{inspect(message)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(reason, state) do
    Logger.info("Audio.Input.Source #{inspect(state.key)} terminating (#{inspect(reason)})")

    _ = teardown_connection(state, :shutdown)
    stop_listener(state)
    :ok
  end

  defp session_key_revoked?(%__MODULE__{socket: nil}), do: false

  defp session_key_revoked?(%__MODULE__{psk_category: :long_term} = state) do
    not Enum.any?(Store.pairings(stored_pairing(state)), &(&1.psk_id == state.conn.record_id))
  end

  defp session_key_revoked?(%__MODULE__{psk_category: :pairing} = state) do
    case stored_pairing(state) do
      %{pairing_psk: <<_::256>> = psk} -> Pairing.psk_id_for(psk) != state.conn.record_id
      _other -> true
    end
  end

  defp session_key_revoked?(_state), do: false

  # -- Listener --

  defp start_listener(state) do
    # Ranch refs must be unique process-wide; the unique integer keeps a
    # restarted source from colliding with a listener that is still winding
    # down under the same key.
    ref = {__MODULE__, state.key, System.unique_integer([:positive])}

    plug_opts = [
      path: state.path,
      source: self(),
      websock_opts: [timeout: @ws_timeout_ms, max_frame_size: @max_ws_frame_bytes]
    ]

    # `:listen_ip` defaults to `:any` (the listener has to be reachable on
    # whatever interface mDNS advertised the card on); a deployment that wants
    # to keep the capture listener off AP-mode/cellular interfaces can pin it
    # to a specific LAN address. `max_connections` bounds concurrent sockets.
    cowboy_opts = [
      ref: ref,
      port: state.requested_port,
      ip: state.listen_ip,
      transport_options: [num_acceptors: 2, max_connections: @max_connections]
    ]

    case Plug.Cowboy.http(Listener, plug_opts, cowboy_opts) do
      {:ok, _pid} -> {:ok, %{state | listener_ref: ref, bound_port: :ranch.get_port(ref)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stop_listener(%__MODULE__{listener_ref: nil}), do: :ok

  defp stop_listener(%__MODULE__{listener_ref: ref}) do
    Plug.Cowboy.shutdown(ref)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # -- Connection acceptance & eviction --

  # Adopt a socket as the active connection and open the protocol (client/init
  # first, per ground truth §2, even though MA dialed us).
  defp adopt_socket(state, pid) do
    state = %{
      state
      | socket: pid,
        socket_monitor: Process.monitor(pid),
        fsm: :awaiting_server_init
    }

    notify(state, :connected)

    case send_client_init(state) do
      {:ok, state} -> state
      {:error, reason} -> fail(state, reason)
    end
  end

  # Park a challenger behind a live trust-`user` incumbent and probe the
  # incumbent's liveness. Only one challenger parks at a time.
  defp park_socket(%__MODULE__{parked_socket: parked} = state, pid) when is_pid(parked) do
    send(pid, {:sendspin_ws_close, :busy})
    state
  end

  defp park_socket(state, pid) do
    Logger.info(
      "Audio.Input.Source #{inspect(state.key)} parking a challenger behind the live " <>
        "trust-user session; probing incumbent liveness"
    )

    state = %{state | parked_socket: pid, parked_monitor: Process.monitor(pid)}
    probe_incumbent(state)
  end

  # Probe the incumbent's liveness so a genuinely dead (half-open) connection
  # yields the slot to the parked challenger. A `client/time` goes out and the
  # short liveness timer is armed; an inbound frame before it fires proves the
  # incumbent alive and drops the challenger, silence promotes it.
  #
  # BUT a consented pairing exchange must NOT be probed: it is legitimately
  # silent while the operator reads and types the PIN (often longer than the
  # probe window) and its `client/time` keepalive is itself suppressed for the
  # exchange, so the incumbent cannot answer the probe even though it is alive.
  # Promoting on that silence would tear down a live pairing. Park the challenger
  # and let the exchange bound itself (pairing timeout / socket close);
  # `maybe_probe_parked/1` re-probes once the exchange resolves.
  defp probe_incumbent(state) do
    if pairing_in_progress?(state) do
      state
    else
      state |> send_time_request() |> arm_liveness_timer()
    end
  end

  # After a pairing attempt resolves with a challenger still parked, decide the
  # incumbent's fate the normal way — probe it. A live incumbent (its keepalive
  # resumed now the exchange is over) answers and the challenger is dropped; a
  # genuinely dead one (the attempt timed out on a half-open socket, so no
  # inbound frame ever arrived to drop the challenger) fails the probe and the
  # challenger is promoted. On a live incumbent the resolving frame already ran
  # `incumbent_alive/1` and dropped the challenger, so this is a no-op there.
  defp maybe_probe_parked(%__MODULE__{parked_socket: nil} = state), do: state

  defp maybe_probe_parked(%__MODULE__{liveness_timer: timer} = state) when not is_nil(timer),
    do: state

  defp maybe_probe_parked(state), do: probe_incumbent(state)

  # A pairing exchange the operator has actually consented to is mid-flight and
  # must not be evicted by a concurrent connection even though it is still trust
  # `none`: an open `Sendspin.Pairing` attempt (`pairing != nil`, from
  # `client/pair-init` until it resolves) or the post-pairing re-handshake window
  # (`:awaiting_rehandshake`). The un-authenticated self-heal replace would
  # otherwise discard the in-progress CPace / re-handshake state the operator is
  # completing.
  #
  # A merely HELD, pre-consent offer (`:pairing_required` with `pairing == nil`,
  # consent-wait timer armed) is deliberately NOT protected: it carries no
  # operator-consented state worth keeping, and protecting it would let an
  # unauthenticated Sentinel-PSK peer squat the single connection slot and block
  # legit MA from ever pairing. A challenger arriving while we only hold an
  # un-consented offer falls through to the normal un-authenticated self-heal
  # replace, so the held offer is replaceable.
  defp pairing_in_progress?(state) do
    not is_nil(state.pairing) or state.fsm == :awaiting_rehandshake
  end

  # Any inbound frame from the incumbent proves it alive: cancel the probe and
  # drop the challenger. This drops a parked challenger even when no liveness
  # timer is armed — the case during a consented pairing exchange, where the
  # incumbent's own pairing frames are what prove it alive (the promote-on-silence
  # probe is deliberately withheld for the exchange, see `probe_incumbent/1`).
  defp incumbent_alive(%__MODULE__{parked_socket: nil, liveness_timer: nil} = state), do: state

  defp incumbent_alive(state) do
    state |> cancel_liveness_timer() |> drop_parked()
  end

  defp drop_parked(%__MODULE__{parked_socket: nil} = state), do: state

  defp drop_parked(%__MODULE__{parked_socket: pid, parked_monitor: monitor} = state) do
    if monitor, do: Process.demonitor(monitor, [:flush])
    send(pid, {:sendspin_ws_close, :discarded})
    %{state | parked_socket: nil, parked_monitor: nil}
  end

  defp arm_liveness_timer(state) do
    state = cancel_liveness_timer(state)
    {gen, state} = next_timer_gen(state)

    %{
      state
      | liveness_timer:
          Process.send_after(self(), {:incumbent_liveness_timeout, gen}, state.incumbent_probe_ms),
        liveness_gen: gen
    }
  end

  defp cancel_liveness_timer(%__MODULE__{liveness_timer: nil} = state),
    do: %{state | liveness_gen: nil}

  defp cancel_liveness_timer(%__MODULE__{liveness_timer: timer} = state) do
    _ = Process.cancel_timer(timer)
    %{state | liveness_timer: nil, liveness_gen: nil}
  end

  # A simple sliding-window accept rate limit, spanning connections.
  defp accept_allowed?(state) do
    now = System.monotonic_time(:millisecond)
    Enum.count(state.accepts, &(now - &1 < @accept_window_ms)) < @max_accepts
  end

  defp record_accept(state) do
    now = System.monotonic_time(:millisecond)
    %{state | accepts: Enum.filter([now | state.accepts], &(now - &1 < @accept_window_ms))}
  end

  # Outbound backpressure: when the socket process is this far behind, drop the
  # frame rather than growing its mailbox. Dropping audio is the correct
  # failure for a real-time path (see capture-path research).
  defp outbound_congested?(%__MODULE__{socket: pid}) when is_pid(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, len} -> len > @max_outbound_backlog
      _other -> false
    end
  end

  defp outbound_congested?(_state), do: false

  defp drop_frame(state) do
    dropped = state.frames_dropped + 1

    if rem(dropped, 100) == 1 do
      Logger.warning(
        "Audio.Input.Source #{inspect(state.key)} dropping outbound audio; the MA peer is " <>
          "behind (#{dropped} frames dropped)"
      )
    end

    %{state | frames_dropped: dropped}
  end

  # -- Cleartext handshake --

  defp send_client_init(state) do
    # The pairing PSK must already exist when Noise message 1 arrives: a
    # server holding our token keys the very first handshake with it.
    with {:ok, {pub, _priv} = keypair} <- Store.ensure_client_keypair(state.store, state.key),
         {:ok, _pairing_psk} <- Store.ensure_pairing_psk(state.store, state.key) do
      client_id = Store.client_id(pub)
      text = Wire.encode_client_init(client_id, @protocol_version, state.suite)
      push(state, {:text, text})

      {:ok, %{state | keypair: keypair, client_id: client_id, client_init: text}}
    else
      {:error, reason} -> {:error, {:keypair_unavailable, reason}}
    end
  catch
    :exit, reason -> {:error, {:keypair_unavailable, {:store_unavailable, reason}}}
  end

  defp handle_frame(%{fsm: :awaiting_server_init} = state, :text, text) do
    with {:ok, %{server_id: server_id, version: @protocol_version}} <-
           Wire.decode_server_init(text),
         {:ok, remote_static} <- decode_public_key(server_id) do
      {:ok,
       %{
         state
         | server_init: text,
           server_id: server_id,
           remote_static: remote_static,
           fsm: :awaiting_handshake
       }}
    else
      {:ok, %{version: version}} -> {:error, {:unsupported_version, version}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp handle_frame(%{fsm: :awaiting_handshake} = state, :text, text) do
    case Wire.decode_noise_handshake(text) do
      {:ok, message_1} -> run_handshake(state, message_1)
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp handle_frame(%{noise: noise} = state, :binary, data) when not is_nil(noise) do
    case Noise.decrypt(noise, data) do
      {:ok, plaintext} -> reassemble(state, plaintext)
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp handle_frame(state, opcode, _data) do
    {:error, {:unexpected_frame, opcode, state.fsm}, state}
  end

  defp reassemble(state, plaintext) do
    case Wire.decode_frame(plaintext, state.reassembler) do
      {:pending, reassembler} ->
        {:ok, %{state | reassembler: reassembler}}

      {:complete, frame, reassembler} ->
        handle_transport_frame(%{state | reassembler: reassembler}, frame)

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # The server is the Noise initiator. Message 1's payload carries the
  # `psk_id` it chose and its `psk_category`, and psk2 means the PSK is not
  # mixed until message 2 — so message 1 authenticates under *any* PSK and we
  # can read them out of it before committing. Decibel fixes the PSK at
  # session creation, so a mismatch means opening a second session and
  # re-reading the same bytes.
  defp run_handshake(state, message_1) do
    prologue = Wire.prologue(state.client_init, state.server_init)

    case exchange_handshake(state, message_1, prologue, :sentinel_fallback) do
      {:ok, session, category, record_id} ->
        case Noise.write_handshake(session, @noise_msg2_payload) do
          {:ok, message_2} ->
            push(state, {:text, Wire.encode_noise_handshake(message_2)})
            touch_record(state, category, record_id)

            {:ok,
             %{
               state
               | noise: session,
                 handshake_hash: Noise.handshake_hash(session),
                 psk_category: category,
                 trust: trust_level(category),
                 pairing_index: 0,
                 conn: %{state.conn | record_id: record_id},
                 fsm: :awaiting_server_hello
             }}

          {:error, reason} ->
            # The session authenticated but we could not produce message 2:
            # close it so its keys don't leak into the process dictionary.
            close_noise(session)
            {:error, reason, state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # Reads message 1 and leaves a session that has produced neither its own
  # message 2 nor any transport frame — the caller decides how message 2
  # travels, which is the one thing an in-band re-handshake does differently.
  #
  # Decibel keeps session state in the (long-lived `Source`) process
  # dictionary, so every error branch here MUST close whatever candidate
  # session it is holding; otherwise a peer that loops `connect → garbage
  # msg1 → disconnect` permanently accretes key material.
  defp exchange_handshake(state, message_1, prologue, on_miss) do
    # One Store read per handshake; every lookup below works on this config.
    config = stored_pairing(state)
    candidate = candidate_psk(config)

    with {:ok, session, payload} <- open_session(state, candidate, message_1, prologue) do
      finalize_session(
        %{state: state, config: config, on_miss: on_miss},
        {session, candidate},
        payload,
        {message_1, prologue}
      )
    end
  end

  # Resolves the real PSK from message 1's plaintext and, if it differs from
  # the candidate we opened with, reopens under it. Closes the session it holds
  # on any error path so nothing leaks.
  defp finalize_session(ctx, {session, candidate}, payload, {message_1, prologue}) do
    with {:ok, reference} <- Wire.decode_noise_msg1_payload(payload),
         {:ok, psk, category, record_id} <- resolve_psk(ctx, reference) do
      if secure_equal?(psk, candidate) do
        {:ok, session, category, record_id}
      else
        close_noise(session)

        case open_session(ctx.state, psk, message_1, prologue) do
          {:ok, new_session, _payload} -> {:ok, new_session, category, record_id}
          {:error, reason} -> {:error, reason}
        end
      end
    else
      {:error, reason} ->
        close_noise(session)
        {:error, reason}
    end
  end

  defp open_session(state, psk, message_1, prologue) do
    case Noise.start(
           suite: state.suite,
           static_keypair: state.keypair,
           remote_static_key: state.remote_static,
           psk: psk,
           prologue: prologue
         ) do
      {:ok, session} ->
        # `Noise.start` created the session (process-dictionary state); if
        # reading message 1 fails, close it here so it can't leak.
        case Noise.read_handshake(session, message_1) do
          {:ok, payload} -> {:ok, session, payload}
          {:error, reason} -> {:error, close_and_return(session, reason)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp close_and_return(session, reason) do
    close_noise(session)
    reason
  end

  # Look the `psk_id` up among our PSKs of the declared category only. A miss
  # in the initial handshake completes under the Sentinel (`connection.md`
  # "Sentinel Fallback": the server learns we could not use the PSK it
  # referenced); a miss during a re-handshake fails it. On a match the result
  # carries the id of the record (or pairing PSK) now backing the session.
  defp resolve_psk(ctx, %{psk_id: psk_id, psk_category: category}) do
    case lookup_psk(ctx.config, category, psk_id) do
      {:ok, psk, record} ->
        verify_record_server(ctx.state, category, psk, record)

      :miss when ctx.on_miss == :sentinel_fallback ->
        Logger.info(
          "Audio.Input.Source #{inspect(ctx.state.key)} does not hold the PSK the server " <>
            "referenced (#{category}); completing the handshake under the Sentinel PSK"
        )

        {:ok, Noise.sentinel_psk(), :sentinel, nil}

      :miss ->
        {:error, {:unknown_psk_id, category}}
    end
  end

  # `psk_id` is a public hash, so timing is a negligible leak — but a
  # constant-time compare keeps the module uniformly constant-time.
  defp lookup_psk(_config, :sentinel, psk_id) do
    if secure_equal?(@sentinel_psk_id, psk_id), do: {:ok, Noise.sentinel_psk(), nil}, else: :miss
  end

  defp lookup_psk(config, :long_term, psk_id) do
    case Enum.find(Store.pairings(config), &secure_equal?(&1.psk_id, psk_id)) do
      %{psk: psk} = record -> {:ok, psk, record}
      nil -> :miss
    end
  end

  defp lookup_psk(%{pairing_psk: <<_::256>> = psk}, :pairing, psk_id) do
    if secure_equal?(Pairing.psk_id_for(psk), psk_id), do: {:ok, psk, nil}, else: :miss
  end

  defp lookup_psk(_config, _category, _psk_id), do: :miss

  # A long-term PSK is bound to the server it was paired with: after a match,
  # the record's `server_id` must equal the one in `server/init`, or the
  # handshake fails (a misbinding, not a miss — no Sentinel Fallback).
  defp verify_record_server(state, :long_term, psk, %{server_id: stored, psk_id: id}) do
    if is_binary(state.server_id) and secure_equal?(stored, state.server_id),
      do: {:ok, psk, :long_term, id},
      else: {:error, :pairing_record_server_mismatch}
  end

  defp verify_record_server(_state, :pairing, psk, _record),
    do: {:ok, psk, :pairing, Pairing.psk_id_for(psk)}

  defp verify_record_server(_state, category, psk, _record), do: {:ok, psk, category, nil}

  defp secure_equal?(a, b) when byte_size(a) == byte_size(b), do: :crypto.hash_equals(a, b)
  defp secure_equal?(_a, _b), do: false

  # Open the first session under the most recently used record (the likeliest
  # server to be dialing), else the Sentinel.
  defp candidate_psk(config) do
    case Store.pairings(config) do
      [%{psk: psk} | _rest] -> psk
      [] -> Noise.sentinel_psk()
    end
  end

  defp touch_record(state, :long_term, psk_id) when is_binary(psk_id) do
    Store.touch_pairing(state.store, state.key, psk_id)
  catch
    :exit, _ -> :ok
  end

  defp touch_record(_state, _category, _record_id), do: :ok

  defp stored_pairing(state) do
    case Store.get_config(state.store, state.key) do
      {:ok, config} -> config
      :error -> %{}
    end
  catch
    :exit, _ -> %{}
  end

  # Trust `user` is exactly "the matched PSK is our long-term pairing record":
  # only such a session may activate roles (we advertise no unpaired access).
  defp trust_level(:long_term), do: :user
  defp trust_level(_category), do: :none

  # -- Transport-mode dispatch --

  defp handle_transport_frame(state, {:json, body}) do
    case Wire.decode_message(body) do
      {:ok, {tag, payload}} -> handle_message(state, tag, payload)
      {:unknown, type, _payload} -> {:ok, log_unknown(state, type)}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # A server never sends the source-audio binary type, and 13-15 are reserved.
  defp handle_transport_frame(state, _frame), do: {:ok, state}

  defp log_unknown(state, type) do
    Logger.debug(
      "Audio.Input.Source #{inspect(state.key)} ignoring message type #{truncate_text(type)}"
    )

    state
  end

  defp handle_message(%{fsm: :awaiting_server_hello} = state, :server_hello, _payload) do
    case send_client_hello(state) do
      :ok -> {:ok, %{state | fsm: :awaiting_activate}}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # The first `server/activate` after an in-band re-handshake. Whatever the
  # FSM state, the session's PSK (and so its trust) may have changed: a role
  # we hold active under a session that is no longer long-term is dropped
  # first, then the activation is applied like any other.
  defp handle_message(%{conn: %{rekeying: true} = conn} = state, :server_activate, payload) do
    state = ensure_time_loop(%{state | conn: %{conn | rekeying: false}})

    # A stream that ended while re-keying is closed now, ahead of the
    # activation's own effects.
    state =
      if state.conn.stream_end_pending do
        _ = send_json(state, Wire.encode_client_stream_end())
        put_in(state.conn.stream_end_pending, false)
      else
        state
      end

    cond do
      state.fsm in @active_states and state.trust != :user ->
        handle_activate(deactivate_source(state), payload)

      state.fsm in @active_states ->
        reaffirm_activate(state, payload)

      true ->
        handle_activate(state, payload)
    end
  end

  # A second (third, …) pairing `server/activate` is how the server retries
  # after a failed attempt, so `:pairing_required` accepts activate too. This
  # is the *initial* activation / pairing-retry path; a role change once
  # `source@v1` is already active is handled by the clause below.
  #
  # The `client/time` clock-sync loop starts at the first activation — the
  # client may send nothing before it (`messaging.md` "Communication") — and
  # runs for the rest of the connection: time sync is connection-level and
  # role-independent, a `source@v1` must converge before it reports available,
  # and the `server/time` replies keep a live-but-idle (connected-yet-unpaired)
  # session from tripping Cowboy's idle timeout.
  defp handle_message(%{fsm: fsm} = state, :server_activate, payload)
       when fsm in [:awaiting_activate, :pairing_required] do
    handle_activate(ensure_time_loop(state), payload)
  end

  defp handle_message(%{fsm: fsm} = state, :server_activate, payload)
       when fsm in @active_states do
    reaffirm_activate(state, payload)
  end

  defp handle_message(state, :server_time, payload), do: handle_server_time(state, payload)

  defp handle_message(state, :server_command, %{source: source}) do
    handle_source_command(state, source)
  end

  # The in-band re-handshake. Expected to rotate keys on an authenticated
  # (trust `user`) session, which is uncapped; and on an unpaired one right
  # after a successful pairing, when the server switches it to our pairing PSK,
  # or back to its record after a cancelled attempt. Those are capped per
  # connection (`@max_unpaired_rehandshakes`) so an unauthenticated peer can't
  # drive unlimited X25519 handshakes on one connection (CPU amplification).
  defp handle_message(%{trust: :user} = state, :noise_handshake, %{data: message_1}) do
    run_rehandshake(state, message_1)
  end

  defp handle_message(
         %{conn: %{unpaired_rehandshakes: count} = conn} = state,
         :noise_handshake,
         %{data: m1}
       )
       when count < @max_unpaired_rehandshakes do
    run_rehandshake(%{state | conn: %{conn | unpaired_rehandshakes: count + 1}}, m1)
  end

  defp handle_message(state, :noise_handshake, %{data: _message_1}) do
    {:error, {:unexpected_rehandshake, state.fsm, state.trust}, state}
  end

  defp handle_message(state, tag, payload) when tag in @server_pairing_tags do
    handle_pairing_message(state, tag, payload)
  end

  # `messaging.md` `server/unpair`: a paired server drops its own record. In a
  # session keyed by that record we drop ours too, say so and close; in an
  # unpaired session it is ignored.
  defp handle_message(%{trust: :user} = state, :server_unpair, _payload) do
    Logger.info("Audio.Input.Source #{inspect(state.key)} unpaired by the server")

    case Store.remove_pairing(state.store, state.key, psk_id: state.conn.record_id) do
      :ok -> notify(state, :unpaired)
      {:error, reason} -> Logger.error("Audio.Input.Source unpair failed: #{inspect(reason)}")
    end

    goodbye(state, :unpaired)
  catch
    :exit, _ -> goodbye(state, :unpaired)
  end

  defp handle_message(state, :pair_abort, %{reason: reason}) do
    {:ok, abandon_pairing(state, {:peer_abort, reason})}
  end

  defp handle_message(state, tag, _payload) do
    Logger.debug("Audio.Input.Source #{inspect(state.key)} ignoring #{tag} in state #{state.fsm}")

    {:ok, state}
  end

  defp send_client_hello(state) do
    send_json(
      state,
      Wire.encode_client_hello(%{
        name: state.name,
        device_info: state.device_info,
        supported_roles: [@source_role],
        # Formats are NOT announced here — they go in `client-stream/start`.
        source_v1_support: %{features: %{line_sense: false}},
        supported_pair_methods: state.pair_methods,
        # A capture card exposes a live input to whoever streams it, so it
        # only ever streams to a server it has paired with.
        unpaired_access: %{enabled: false}
      })
    )
  end

  # Apply an activation to a connection that has no active `source@v1`
  # (`messaging.md` `server/activate`: allowed activity sets per matched PSK,
  # and the rejection order when one is not admissible). An activation without
  # `pairing` also cancels any attempt or held offer in progress.
  defp handle_activate(state, %{active_roles: roles, activities: activities} = payload) do
    roles = roles || []
    pairing? = :pairing in activities
    state = if pairing?, do: state, else: leave_pairing(state)

    cond do
      # Not an allowed activity set for any key we hold: one we don't know, or
      # pairing on a long-term session.
      not allowed_activities?(state, activities) ->
        goodbye(state, :unauthorized)

      state.psk_category == :long_term and @source_role in roles ->
        notify(state, :activated)
        state |> discard_pairing() |> activate()

      # Unpaired, and we admit no unpaired access: playback or roles would only
      # be admissible with it enabled.
      unpaired_playback?(state, activities, roles) ->
        goodbye(state, :pairing_required)

      pairing? ->
        pairing_offer(state, payload.pairing)

      # An idle `server/activate`: no role, no pairing. This is MA's steady
      # state before the operator acts (it dials every discovered source and
      # holds it). Stay connected and idle in `:awaiting_activate` so MA keeps a
      # stable connection and can later send a pairing or `source@v1` activate;
      # closing here made the source flap "unavailable" and never present a
      # device to pair.
      true ->
        Logger.debug(
          "Audio.Input.Source #{inspect(state.key)} idle activate (roles=#{inspect(roles)}); staying idle"
        )

        {:ok, %{state | fsm: :awaiting_activate}}
    end
  end

  # `source@v1` is already active and the server re-sends `server/activate`.
  # Neither case may be silently ignored — doing so would keep us capturing
  # after the role was revoked:
  #
  #   * `source@v1` still present (or `active_roles` omitted, which keeps the
  #     previous roles) — a benign re-affirmation: don't tear down a healthy
  #     stream or reset the converged clock filter.
  #   * `source@v1` absent — the role was revoked. Stop capture and, if
  #     streaming, send `client-stream/end`; rewind to `:awaiting_activate`
  #     holding the connection, then apply the rest of the activation (which
  #     may, for instance, offer pairing).
  defp reaffirm_activate(state, %{active_roles: roles} = payload) do
    cond do
      :pairing in payload.activities or unknown_activity?(payload.activities) ->
        goodbye(state, :unauthorized)

      is_nil(roles) or @source_role in roles ->
        {:ok, state}

      true ->
        handle_activate(deactivate_source(state), payload)
    end
  end

  defp activate(state) do
    # The server holds the role until it has the `source` object this
    # activation requires, and `available` must stay false until the clock
    # filter converges. The `client/time` loop has been running since the first
    # activation, so the filter may already be converged: do NOT reset it, drop
    # in-flight measurements, or re-start the tick loop (that would re-run
    # convergence from zero). Just move to `:syncing` and re-check availability,
    # so an already-converged filter reports available promptly.
    case send_json(state, client_state(false)) do
      :ok -> maybe_become_available(%{state | fsm: :syncing})
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp unknown_activity?(activities), do: Enum.any?(activities, &match?({:unknown, _}, &1))

  defp allowed_activities?(state, activities) do
    not unknown_activity?(activities) and
      not (state.psk_category == :long_term and :pairing in activities)
  end

  defp unpaired_playback?(state, activities, roles) do
    state.psk_category != :long_term and (:playback in activities or roles != [])
  end

  # Full state only: every `client/state` an active source sends carries the
  # complete `source` object (no line sensing, so it is empty).
  defp client_state(available), do: Wire.encode_client_state(available, %{signal: nil})

  # Say why, then close (`messaging.md` `client/goodbye`).
  defp goodbye(state, reason) do
    Logger.info("Audio.Input.Source #{inspect(state.key)} closing the connection: #{reason}")
    _ = send_json(state, Wire.encode_client_goodbye(reason))
    {:error, {:goodbye, reason}, state}
  end

  # -- Pairing --

  # A pairing `server/activate` on an unpaired session. Each one admits one
  # attempt and advances `pairing_index` (the count of them since the last
  # handshake), whether or not we open the attempt. The method must be one we
  # offer, and `pairing_psk` exactly when the session is keyed by our pairing
  # PSK; anything else is answered with `pair/abort` `method_not_supported`.
  defp pairing_offer(state, params) do
    state = %{
      discard_pairing(state)
      | fsm: :pairing_required,
        last_pairing_params: params,
        pairing_index: state.pairing_index + 1
    }

    case offered_method(state, params) do
      :pairing_psk ->
        # Holding the token is the operator's authorization: no consent hold.
        start_pairing(state, params)

      :dynamic_pairing_code ->
        notify(state, {:pairing_required, params})
        maybe_start_pairing(state, params)

      :unsupported ->
        refuse_method(state, params)
    end
  end

  defp offered_method(%{psk_category: :pairing}, %{method: :pairing_psk}), do: :pairing_psk

  defp offered_method(%{psk_category: :sentinel}, %{
         method: :dynamic_pairing_code,
         format: :digits
       }),
       do: :dynamic_pairing_code

  defp offered_method(_state, _params), do: :unsupported

  # The consent gate for the dynamic pairing code. An offer only opens an
  # attempt when the operator has opened a local "allow pairing" window that
  # still has code rounds left; the record it produces is added beside any the
  # input already holds. Absent consent we do NOT abort: we HOLD
  # the offer in `:pairing_required` (surfacing the "Allow pairing" affordance)
  # and tell the server with `client/pair-pending`, which keeps its own wait
  # open for the operator's gesture. An un-consented offer just waits, then
  # times out with no pairing.
  defp maybe_start_pairing(state, params) do
    if rounds_left(state) > 0, do: start_pairing(state, params), else: hold_for_consent(state)
  end

  # Code rounds the open consent window still admits; none while it is closed.
  defp rounds_left(%__MODULE__{pairing_window: %{rounds: rounds}}),
    do: Pairing.round_limit() - rounds

  defp rounds_left(_state), do: 0

  # No operator consent yet. Don't open the attempt: answer
  # `client/pair-pending` and hold in `:pairing_required` (already set by the
  # caller, along with the `{:pairing_required, params}` notification and
  # `last_pairing_params`), arming a consent-wait timeout. The `client/time`
  # keepalive holds the connection open in the meantime.
  #
  # Once a source has burned `@max_holds` un-consented offers within
  # `@hold_window_ms`, stop re-arming the prompt and decline outright, so a peer
  # can't keep the UI nagging by re-offering as soon as each hold lapses. The
  # budget lives in `hold_times`, which survives teardown, so it bounds the churn
  # across reconnects rather than per-connection.
  defp hold_for_consent(state) do
    if holds_exhausted?(state) do
      Logger.info(
        "Audio.Input.Source #{inspect(state.key)} exceeded #{@max_holds} un-consented pairing " <>
          "offers within the hold window; declining instead of re-holding"
      )

      {:ok, decline_held_offer(state, :user_cancelled)}
    else
      pending = Wire.encode_client_pair_pending(state.pairing_index, @pair_pending_message)

      case send_json(state, pending) do
        :ok -> {:ok, arm_consent_wait(record_hold(state))}
        {:error, reason} -> {:error, reason, state}
      end
    end
  end

  defp holds_exhausted?(state) do
    now = System.monotonic_time(:millisecond)
    Enum.count(state.hold_times, &(now - &1 < @hold_window_ms)) >= @max_holds
  end

  defp record_hold(state) do
    now = System.monotonic_time(:millisecond)
    %{state | hold_times: Enum.filter([now | state.hold_times], &(now - &1 < @hold_window_ms))}
  end

  # A fresh monotonic generation token for a cross-connection-risky timer. Each
  # arm gets a unique gen, so any older queued timeout (from an earlier arm or an
  # old connection) fails its handler's gen match and is dropped.
  defp next_timer_gen(state) do
    gen = state.timer_gen + 1
    {gen, %{state | timer_gen: gen}}
  end

  defp arm_consent_wait(state) do
    state = cancel_consent_wait_timer(state)
    {gen, state} = next_timer_gen(state)
    timer = Process.send_after(self(), {:consent_wait_timeout, gen}, state.pairing_window_ms)
    %{state | consent_wait_timer: timer, consent_wait_gen: gen}
  end

  defp cancel_consent_wait_timer(%__MODULE__{consent_wait_timer: nil} = state),
    do: %{state | consent_wait_gen: nil}

  defp cancel_consent_wait_timer(%__MODULE__{consent_wait_timer: timer} = state) do
    _ = Process.cancel_timer(timer)
    %{state | consent_wait_timer: nil, consent_wait_gen: nil}
  end

  # The consent-wait timeout fired with no `allow_pairing/1` gesture: MA's own
  # pairing window has (about) elapsed too. Decline the held offer with
  # `pair/abort` and return to connected-idle, holding the connection for a
  # later offer. No pairing happened, so an un-consented attacker gains nothing.
  defp decline_held_offer(state, reason) do
    Logger.info("Audio.Input.Source #{inspect(state.key)} pairing offer expired without consent")

    state = cancel_consent_wait_timer(state)
    _ = send_json(state, Wire.encode_pair_abort(reason))
    state = %{state | fsm: :awaiting_activate, last_pairing_params: nil}
    notify(state, :pairing_declined)
    state
  end

  # Attempts are capped at `@max_pairing_attempts` per connection to bound an
  # online code brute force; retries back off. The attempt runs under the
  # current `pairing_index` (set when its offer arrived).
  defp start_pairing(state, params) do
    # Opening an attempt supersedes any held-offer wait.
    state = cancel_consent_wait_timer(state)
    attempt = state.conn.pairing_attempts + 1

    cond do
      attempt > @max_pairing_attempts ->
        Logger.warning(
          "Audio.Input.Source #{inspect(state.key)} exceeded #{@max_pairing_attempts} " <>
            "pairing attempts; closing the connection"
        )

        {:error, :pairing_attempts_exhausted, state}

      attempt > 1 ->
        # Back off before a retry so a wrong-code loop can't be hammered.
        state = put_in(state.conn.pairing_attempts, attempt)
        delay = @pairing_backoff_ms * (attempt - 1)
        timer = Process.send_after(self(), {:open_pairing_attempt, params}, delay)
        {:ok, %{state | pairing_attempt_timer: timer}}

      true ->
        open_pairing_now(put_in(state.conn.pairing_attempts, attempt), params)
    end
  end

  defp open_pairing_now(state, params) do
    # Transitioning into an active attempt: cancel any queued backoff retry so a
    # stray `{:open_pairing_attempt, _}` can't open a second concurrent attempt.
    state |> cancel_pairing_attempt_timer() |> open_attempt(params)
  end

  # Whether a deferred (backed-off) attempt is still valid to open: the
  # connection is up, still awaiting pairing, no attempt is already in flight,
  # and — for a code attempt — consent stands and no long-term PSK has
  # appeared meanwhile.
  defp can_open_pairing?(state, params) do
    state.fsm == :pairing_required and not is_nil(state.socket) and is_nil(state.pairing) and
      (offered_method(state, params) == :pairing_psk or not is_nil(state.pairing_window))
  end

  # -- Pairing consent window --

  # Opening the window is the operator action that also resets the code-round
  # count (`pairing.md` "Rounds").
  defp open_pairing_window(state) do
    state = arm_pairing_window(state)

    # Act on an offer that is already pending on the live connection. A second
    # `allow_pairing` (LiveView double-click, or one arriving during a queued
    # backoff retry) must be a no-op: `pairing != nil` means an attempt is already
    # exchanging, and `pairing_attempt_timer != nil` means one is already queued
    # to open — either way, driving `start_pairing` again would double-increment
    # `pairing_index` and race two writers of `state.pairing`.
    if state.fsm == :pairing_required and not is_nil(state.socket) and
         not is_nil(state.last_pairing_params) and is_nil(state.pairing) and
         is_nil(state.pairing_attempt_timer) and
         offered_method(state, state.last_pairing_params) == :dynamic_pairing_code do
      case start_pairing(state, state.last_pairing_params) do
        {:ok, state} -> state
        {:error, reason, state} -> fail(state, reason)
      end
    else
      state
    end
  end

  defp arm_pairing_window(state) do
    state = cancel_pairing_window(state)
    timer = Process.send_after(self(), :pairing_window_timeout, state.pairing_window_ms)
    expires_at = System.system_time(:second) + div(state.pairing_window_ms, 1_000)
    state = %{state | pairing_window: %{timer: timer, rounds: 0}}
    notify(state, {:pairing_window, expires_at})
    state
  end

  defp close_pairing_window(state) do
    state = cancel_pairing_window(state)
    notify(state, {:pairing_window, nil})
    state
  end

  defp cancel_pairing_window(%__MODULE__{pairing_window: nil} = state), do: state

  defp cancel_pairing_window(%__MODULE__{pairing_window: %{timer: timer}} = state) do
    _ = Process.cancel_timer(timer)
    %{state | pairing_window: nil}
  end

  defp open_attempt(state, params) do
    opts = [
      handshake_hash: state.handshake_hash,
      pairing_index: state.pairing_index,
      suite: state.suite,
      method: params.method,
      max_rounds: max(rounds_left(state), 1)
    ]

    case Pairing.start(opts) do
      {:ok, messages, pairing} ->
        state = arm_pairing_timer(%{state | pairing: pairing})
        notify(state, :pairing_started)
        send_pairing_messages(state, messages)

      {:error, reason} ->
        {:ok, pairing_failed(state, reason)}
    end
  end

  # A method we don't offer, a format we don't offer, or a method the matched
  # PSK disallows: the spec's answer is `pair/abort` with
  # `method_not_supported`, leaving the connection open.
  defp refuse_method(state, params) do
    case send_json(state, Wire.encode_pair_abort(:method_not_supported)) do
      :ok -> {:ok, pairing_failed(state, {:unsupported_method, pairing_method(params)})}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp pairing_method(%{method: method}), do: method
  defp pairing_method(_params), do: nil

  defp handle_pairing_message(%{pairing: nil} = state, tag, _payload) do
    Logger.debug(
      "Audio.Input.Source #{inspect(state.key)} ignoring #{tag} with no pairing attempt open"
    )

    {:ok, state}
  end

  defp handle_pairing_message(state, tag, payload) do
    {type, wire_payload} = pairing_wire_message(tag, payload)

    state.pairing
    |> Pairing.handle(type, wire_payload)
    |> apply_pairing_step(state)
  end

  # `Pairing` speaks the wire's own shapes — string keys, base64url values —
  # so that the same module can be driven from a scripted peer and from here.
  # `Wire` has already decoded these fields, and re-encoding four small
  # strings per attempt is cheaper than parsing every frame twice.
  defp pairing_wire_message(:server_pair_init, %{nonce_a: nil}),
    do: {"server/pair-init", %{}}

  defp pairing_wire_message(:server_pair_init, %{nonce_a: nonce_a}),
    do: {"server/pair-init", %{"nonce_A" => b64(nonce_a)}}

  defp pairing_wire_message(:server_pair_auth, %{pake_msg_1: share}),
    do: {"server/pair-auth", %{"pake_msg_1" => b64(share)}}

  defp pairing_wire_message(:server_pair_confirm, %{server_kc: tag}),
    do: {"server/pair-confirm", %{"server_kc" => b64(tag)}}

  defp pairing_wire_message(:server_pair_finalize, _payload),
    do: {"server/pair-finalize", %{}}

  defp apply_pairing_step({:send, messages, pairing}, state) do
    send_pairing_messages(%{state | pairing: pairing}, messages)
  end

  # Each round emits the code (again) and counts against the window's limit.
  defp apply_pairing_step({:pin, pin, pairing}, state) do
    state = %{state | pairing: pairing} |> count_round()
    notify(state, {:pairing_pin, pin})
    {:ok, state}
  end

  defp apply_pairing_step({:paired, outcome, _pairing}, state) do
    complete_pairing(state, outcome)
  end

  defp apply_pairing_step({:abort, reason, messages, _pairing}, state) do
    case send_pairing_messages(state, messages) do
      {:ok, state} -> {:ok, pairing_failed(state, reason)}
      {:error, reason, state} -> {:error, reason, state}
    end
  end

  defp apply_pairing_step({:aborted, reason, _pairing}, state) do
    {:ok, pairing_failed(state, {:peer_abort, reason})}
  end

  # A malformed pairing field is a protocol error, not a failed attempt: the
  # connection goes down and nothing is persisted (ground truth §3).
  defp apply_pairing_step({:error, reason, _pairing}, state) do
    {:error, {:pairing_error, reason}, discard_pairing(state)}
  end

  # The new record replaces this server's, or is added beside the others
  # (`Store.save_pairing/4`), whichever method produced it.
  defp complete_pairing(state, %{psk: psk}) do
    attrs = %{psk: psk, server_id: state.server_id, paired_at: DateTime.utc_now()}

    case save_pairing(state, attrs) do
      :ok ->
        # The server now re-runs the Noise handshake in band; until it does,
        # this session is still keyed by the Sentinel PSK at trust `none`.
        # Consent is consumed by a successful pairing.
        #
        # Pause the `client/time` loop for the re-handshake window: the swap to
        # the new session keys takes effect "from the next frame onwards" (ground
        # truth §4), so a `client/time` sent under the old session whose
        # `server/time` reply lands after we swap would fail to decrypt and drop
        # the connection. The loop restarts at the activation that follows.
        state =
          %{
            cancel_time_timer(discard_pairing(close_pairing_window(state)))
            | fsm: :awaiting_rehandshake,
              outstanding: []
          }

        notify(state, :paired)
        {:ok, state}

      {:error, reason} ->
        # The peer already stored the PSK when it sent `server/pair-finalize`;
        # if our own persist fails we would be out of sync (its next handshake
        # arrives with a `psk_id` we don't know → wedged card). Abort and drop
        # the connection so a fresh handshake starts clean and, since nothing
        # was persisted here, we come back unpaired-and-pairable rather than
        # wedged.
        Logger.error(
          "Audio.Input.Source #{inspect(state.key)} pairing persist failed " <>
            "(#{inspect(reason)}); aborting to force a fresh handshake"
        )

        _ = send_json(state, Wire.encode_pair_abort(:user_cancelled))
        {:error, {:persist_failed, reason}, discard_pairing(state)}
    end
  end

  defp send_pairing_messages(state, messages) do
    Enum.reduce_while(messages, {:ok, state}, fn {type, payload}, {:ok, state} ->
      case send_json(state, Wire.encode_message(type, payload)) do
        :ok -> {:cont, {:ok, state}}
        {:error, reason} -> {:halt, {:error, reason, state}}
      end
    end)
  end

  # A failed attempt leaves the connection up in `:pairing_required`: the
  # server retries by sending another pairing `server/activate`, which is also
  # what advances `pairing_index`.
  defp pairing_failed(state, reason) do
    Logger.info(
      "Audio.Input.Source #{inspect(state.key)} pairing failed: #{truncate_reason(reason)}"
    )

    state = %{discard_pairing(state) | fsm: :pairing_required}
    notify(state, {:pairing_failed, reason})
    # The attempt just resolved: if a challenger parked (without a liveness probe)
    # during the exchange is still waiting, probe the now-unprotected incumbent so
    # a dead pairing connection yields the slot rather than deadlocking behind it.
    maybe_probe_parked(state)
  end

  # An active attempt was aborted (by the peer): fail it, staying connected in
  # `:pairing_required` for a retry.
  defp abandon_pairing(%__MODULE__{pairing: %Pairing{}} = state, reason),
    do: pairing_failed(state, reason)

  # The peer aborted while we were only HOLDING a pre-consent offer (no attempt
  # open). Tear the hold down, otherwise a later `allow_pairing/1` would drive
  # `client/pair-init` for an offer MA has already withdrawn: cancel the
  # consent-wait timer, forget the offer params, and return to connected-idle so
  # the UI drops its "Allow pairing" affordance. No `pair/abort` is echoed back —
  # the peer is the one that aborted.
  defp abandon_pairing(%__MODULE__{fsm: :pairing_required, pairing: nil} = state, reason) do
    state = %{
      cancel_consent_wait_timer(state)
      | fsm: :awaiting_activate,
        last_pairing_params: nil
    }

    notify(state, {:pairing_failed, reason})
    state
  end

  # Nothing pending at all (truly idle, no consent-wait): a stray abort is a
  # harmless no-op.
  defp abandon_pairing(state, _reason), do: state

  defp count_round(%__MODULE__{pairing_window: %{rounds: rounds} = window} = state),
    do: %{state | pairing_window: %{window | rounds: rounds + 1}}

  defp count_round(state), do: state

  defp discard_pairing(state) do
    %{cancel_pairing_attempt_timer(cancel_pairing_timer(state)) | pairing: nil}
  end

  # An activation without `pairing` ends any attempt or held offer: the client
  # abandons it, discarding all pairing state (`pairing.md` "Entering and
  # leaving pairing").
  defp leave_pairing(%__MODULE__{pairing: nil, last_pairing_params: nil} = state), do: state

  defp leave_pairing(state) do
    if state.pairing, do: notify(state, {:pairing_failed, :cancelled})

    %{
      cancel_consent_wait_timer(discard_pairing(state))
      | last_pairing_params: nil,
        fsm: if(state.fsm == :pairing_required, do: :awaiting_activate, else: state.fsm)
    }
  end

  defp cancel_pairing_attempt_timer(%__MODULE__{pairing_attempt_timer: nil} = state), do: state

  defp cancel_pairing_attempt_timer(%__MODULE__{pairing_attempt_timer: timer} = state) do
    _ = Process.cancel_timer(timer)
    %{state | pairing_attempt_timer: nil}
  end

  defp arm_pairing_timer(state) do
    state = cancel_pairing_timer(state)
    {gen, state} = next_timer_gen(state)
    timer = Process.send_after(self(), {:pairing_timeout, gen}, state.pairing_timeout_ms)
    %{state | pairing_timer: timer, pairing_timer_gen: gen}
  end

  defp cancel_pairing_timer(%__MODULE__{pairing_timer: nil} = state),
    do: %{state | pairing_timer_gen: nil}

  defp cancel_pairing_timer(%__MODULE__{pairing_timer: timer} = state) do
    _ = Process.cancel_timer(timer)
    %{state | pairing_timer: nil, pairing_timer_gen: nil}
  end

  defp resolve_pairing_step({:ok, state}), do: {:noreply, state}
  defp resolve_pairing_step({:error, reason, state}), do: {:noreply, fail(state, reason)}

  # The record keying this session (if any) is the one eviction must spare.
  defp save_pairing(state, attrs) do
    Store.save_pairing(state.store, state.key, attrs, protect: state.conn.record_id)
  catch
    :exit, reason -> {:error, {:store_unavailable, reason}}
  end

  # -- Re-handshake --

  # Ground truth §4: the server re-runs the handshake without a new websocket
  # and without repeating client/init or server/init. The prologue is the
  # *previous* handshake's hash, our message 2 travels as an ordinary
  # encrypted JSON message under the **old** session, and the new keys take
  # effect only from the next frame onwards.
  defp run_rehandshake(%__MODULE__{handshake_hash: nil} = state, _message_1) do
    {:error, :rehandshake_before_handshake, state}
  end

  defp run_rehandshake(state, message_1) do
    previous = state.noise

    case exchange_handshake(state, message_1, state.handshake_hash, :fail) do
      {:ok, session, category, record_id} ->
        # `send_json/2` still encrypts message 2 under the *old* session
        # (`state.noise` = `previous`); the new keys take effect only from the
        # next frame. If message 2 can't be produced or sent, close the freshly
        # opened session so it doesn't leak.
        with {:ok, message_2} <- Noise.write_handshake(session, @noise_msg2_payload),
             :ok <- send_json(state, Wire.encode_noise_handshake(message_2)) do
          close_noise(previous)
          touch_record(state, category, record_id)
          {:ok, swap_session(state, session, category, record_id)}
        else
          {:error, reason} ->
            close_noise(session)
            {:error, reason, state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # Only the keys, the matched PSK (and so trust), the handshake hash and the
  # pairing counter change; connection state — the FSM, an open stream, the
  # clock filter — persists. No hellos are replayed: the server's next message
  # is `server/activate`, and until it arrives we send nothing (`rekeying`), so
  # the clock-sync loop pauses and capture frames are dropped.
  #
  # Any pairing attempt or held offer ends (its consent-wait timer must not
  # fire into the re-keyed session). A session that drops below trust `user`
  # stops capturing at once; its `client-stream/end` waits for the activation
  # (`end_stream/1`).
  defp swap_session(state, session, category, record_id) do
    downgrade? = state.trust == :user and trust_level(category) != :user
    state = state |> cancel_time_timer() |> leave_pairing()

    state = %{
      state
      | noise: session,
        handshake_hash: Noise.handshake_hash(session),
        psk_category: category,
        trust: trust_level(category),
        pairing_index: 0,
        conn: %{state.conn | rekeying: true, record_id: record_id},
        outstanding: []
    }

    if downgrade?, do: end_stream(state), else: state
  end

  # -- Time sync --

  # No `client/time` may leave while a pairing exchange is live: MA's strict
  # `_receive_pairing` aborts on any interleaved non-pairing frame. The
  # `:time_tick` loop re-arms without sending, so keepalive resumes automatically
  # once `pairing` clears. The incumbent-liveness probe is separately withheld
  # while an exchange is active (see `probe_incumbent/1`) — a parked challenger is
  # instead dropped by the pairing frames the exchange carries inbound — so this
  # suppression no longer doubles as liveness silencing.
  defp send_time_request(%__MODULE__{pairing: %Pairing{}} = state), do: state

  # Same suppression for the post-pairing in-band re-handshake window: the swap to
  # the new session keys takes effect from the next frame, so a `client/time`
  # emitted here (e.g. from a `:time_tick` already queued when `complete_pairing`
  # cancelled the loop) would draw a `server/time` reply the source can no longer
  # decrypt, dropping the connection. `complete_pairing` cancels the timer; this
  # guard closes the queued-tick race the cancel can't.
  defp send_time_request(%__MODULE__{fsm: :awaiting_rehandshake} = state), do: state

  # Nor between a re-handshake's Noise message 1 and the activation after it.
  defp send_time_request(%__MODULE__{conn: %{rekeying: true}} = state), do: state

  defp send_time_request(%__MODULE__{noise: nil} = state), do: state

  defp send_time_request(state) do
    transmitted = now_us()

    case send_json(state, Wire.encode_client_time(transmitted)) do
      :ok ->
        state = %{state | outstanding: Enum.take([transmitted | state.outstanding], 8)}
        schedule_time_tick(state, time_interval(state))

      {:error, reason} ->
        fail(state, reason)
    end
  end

  defp handle_server_time(state, payload) do
    %{
      client_transmitted: transmitted,
      server_received: received,
      server_transmitted: replied
    } = payload

    if transmitted in state.outstanding do
      filter = ClockFilter.update(state.filter, transmitted, received, replied, now_us())

      %{state | filter: filter, outstanding: List.delete(state.outstanding, transmitted)}
      |> maybe_become_available()
    else
      {:ok, state}
    end
  end

  defp maybe_become_available(%{fsm: :syncing} = state) do
    if ClockFilter.converged?(state.filter) do
      case send_json(state, client_state(true)) do
        :ok -> maybe_start_streaming(%{state | fsm: :ready})
        {:error, reason} -> {:error, reason, state}
      end
    else
      {:ok, state}
    end
  end

  defp maybe_become_available(state), do: {:ok, state}

  defp time_interval(state) do
    if ClockFilter.converged?(state.filter) do
      error = ClockFilter.error(state.filter)

      Enum.find_value(@time_intervals, state.time_burst_ms, fn {threshold, interval} ->
        error != :infinity and error < threshold and interval
      end)
    else
      state.time_burst_ms
    end
  end

  # Start the clock-sync loop if it is not already running.
  defp ensure_time_loop(%__MODULE__{time_timer: nil} = state), do: schedule_time_tick(state, 0)
  defp ensure_time_loop(state), do: state

  defp schedule_time_tick(state, delay) do
    state = cancel_time_timer(state)
    %{state | time_timer: Process.send_after(self(), :time_tick, delay)}
  end

  defp cancel_time_timer(%__MODULE__{time_timer: nil} = state), do: state

  defp cancel_time_timer(%__MODULE__{time_timer: timer} = state) do
    _ = Process.cancel_timer(timer)

    # A tick that fired before the cancel is already queued; drop it so it
    # isn't handled as the next one (an early or post-stop time request).
    receive do
      :time_tick -> :ok
    after
      0 -> :ok
    end

    %{state | time_timer: nil}
  end

  defp now_us, do: System.monotonic_time(:microsecond)

  # -- Streaming --

  defp handle_source_command(state, %{command: :start}) do
    maybe_start_streaming(%{state | start_requested: true})
  end

  defp handle_source_command(state, %{command: :stop}) do
    {:ok, end_stream(%{state | start_requested: false})}
  end

  defp handle_source_command(state, nil), do: {:ok, state}

  # A previous capture is still shutting down (async stop). Opening `arecord`
  # now would race it on the same ALSA device (EBUSY). Defer: the
  # `{:EXIT, stopping_capture}` handler re-runs this once the old process is
  # gone, and `start_requested` carries the pending intent across the wait.
  defp maybe_start_streaming(%{stopping_capture: pid} = state) when is_pid(pid) do
    {:ok, state}
  end

  # `start` is idempotent and may legitimately arrive before we are available
  # — remember it and open the stream as soon as the filter converges.
  defp maybe_start_streaming(%{fsm: :ready, start_requested: true} = state) do
    case start_capture(state) do
      {:ok, state} -> open_stream(state)
      {:degraded, state} -> {:ok, state}
    end
  end

  defp maybe_start_streaming(state), do: {:ok, state}

  defp open_stream(state) do
    case send_json(state, stream_start_message()) do
      :ok ->
        notify(state, :streaming)
        {:ok, %{state | fsm: :streaming}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp stream_start_message do
    Wire.encode_client_stream_start(%{
      codec: @codec,
      channels: @channels,
      sample_rate: @sample_rate,
      bit_depth: @bit_depth,
      codec_header: nil
    })
  end

  # Defense in depth: capture opens the card's live audio, so it must never run
  # below trust `user`. Activation is already trust-gated (B1), so this should
  # be unreachable — but no FSM edge may reach `arecord` from an untrusted
  # session.
  defp start_capture(%__MODULE__{trust: trust} = state) when trust != :user do
    Logger.error(
      "Audio.Input.Source #{inspect(state.key)} refusing to capture at trust #{inspect(trust)}"
    )

    notify(state, {:error, {:capture_requires_trust, trust}})
    {:degraded, %{state | fsm: :degraded}}
  end

  defp start_capture(state) do
    opts =
      state.capture_opts
      |> Keyword.put(:alsa_device, state.alsa_device)
      |> Keyword.put(:subscriber, self())

    case Capture.start_link(opts) do
      {:ok, pid} ->
        # `Capture` stamps frames on the same monotonic basis the clock filter
        # uses (`System.monotonic_time/1`), so frames feed `server_time/2`
        # directly — no realtime→monotonic conversion.
        {:ok, %{state | capture: pid}}

      {:error, {:binary_missing, path}} ->
        notify(state, {:capture_missing, path})
        {:degraded, %{state | fsm: :degraded}}

      {:error, reason} ->
        Logger.error(
          "Audio.Input.Source #{inspect(state.key)} could not start capture: #{inspect(reason)}"
        )

        notify(state, {:error, {:capture_failed, reason}})
        {:degraded, %{state | fsm: :degraded}}
    end
  end

  # `source@v1` was removed from `active_roles` mid-session. End any open stream
  # (reusing the async `stop_capture` path — never a synchronous stop from a
  # handler) and rewind to `:awaiting_activate` while holding the connection, so
  # a later `server/activate` re-activates without a reconnect. `end_stream/1`
  # emits `client-stream/end` + `:stopped` only when a stream was actually open.
  # Trust and the Noise session are kept — and so are the `client/time` loop and
  # the (converged) filter: time sync is connection-level, so it must keep
  # running here both to hold the connection and to leave the filter ready for a
  # prompt re-activation (the loop and filter reset only on a re-handshake or
  # teardown).
  defp deactivate_source(state) do
    Logger.info(
      "Audio.Input.Source #{inspect(state.key)} source@v1 role removed mid-session; deactivating"
    )

    %{end_stream(state) | fsm: :awaiting_activate, start_requested: false}
  end

  # Closes an open stream if there is one; a no-op otherwise, so both a
  # redundant `stop` command and a capture crash land here safely.
  # While re-keying nothing but the handshake may go out, so the
  # `client-stream/end` is held until the activation that follows.
  defp end_stream(%{fsm: :streaming} = state) do
    state = stop_capture(state)

    state =
      if state.conn.rekeying do
        put_in(state.conn.stream_end_pending, true)
      else
        _ = send_json(state, Wire.encode_client_stream_end())
        state
      end

    notify(state, :stopped)
    %{state | fsm: :ready}
  end

  defp end_stream(state), do: stop_capture(state)

  defp stop_capture(%__MODULE__{capture: nil} = state), do: state

  # Stop asynchronously: a synchronous `GenServer.stop(pid, :normal, 2_000)`
  # here would block the FSM inside a `handle_info` for up to the shutdown
  # timeout, stalling a racing new handshake or `stop`/`start`. `Capture` is
  # linked and we trap exits, so its eventual normal exit arrives as an
  # `{:EXIT, pid, _}` message.
  #
  # We remember it as `stopping_capture` so a following `start` does NOT open a
  # second `arecord` on the still-held device (real ALSA rejects that as
  # EBUSY, and late frames from the old capture would bleed into the new
  # stream). A deferred start waits for this pid's `{:EXIT, _}` — see the
  # `maybe_start_streaming/1` guard and the matching `handle_info`. The
  # invariant `capture` is nil while `stopping_capture` is set keeps a new
  # capture from ever starting before the old one is gone, so there is exactly
  # one to track.
  defp stop_capture(%__MODULE__{capture: pid} = state) do
    Task.Supervisor.start_child(UniversalProxy.TaskSupervisor, fn ->
      stop_capture_process(pid, 2_000)
    end)

    %{state | capture: nil, stopping_capture: pid}
  end

  # Runs in the async stop task. The capture may exit on its own between the
  # alive? check and the stop (it is linked to this Source) — that is the
  # outcome we want, so the already-gone exits are fine. A stop that times
  # out leaves the capture alive and `stopping_capture` set, blocking every
  # later start: log it and kill the capture, so its `{:EXIT, _}` still
  # reaches the Source and the deferred start proceeds. Any other exit
  # propagates and crashes the task (logged by the Task.Supervisor).
  @doc false
  @spec stop_capture_process(pid(), timeout()) :: :ok
  def stop_capture_process(pid, timeout) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, timeout)
    :ok
  catch
    :exit, reason when reason in [:noproc, :normal, :shutdown] ->
      :ok

    :exit, {reason, _} when reason in [:noproc, :normal, :shutdown] ->
      :ok

    :exit, {{:shutdown, _}, _} ->
      :ok

    :exit, reason when reason == :timeout or (is_tuple(reason) and elem(reason, 0) == :timeout) ->
      Logger.warning(
        "Audio.Input.Source capture #{inspect(pid)} did not stop within #{timeout}ms; killing it"
      )

      Process.exit(pid, :kill)
      :ok
  end

  # -- Connection teardown --

  defp fail(state, reason) do
    Logger.warning(
      "Audio.Input.Source #{inspect(state.key)} connection failed: #{truncate_reason(reason)}"
    )

    notify(state, {:error, reason})
    state = teardown_connection(state, :protocol_error)
    notify(state, :disconnected)
    state
  end

  defp teardown_connection(state, reason) do
    state =
      state
      |> stop_capture()
      |> cancel_time_timer()
      |> discard_pairing()
      |> cancel_consent_wait_timer()
      |> cancel_liveness_timer()
      |> drop_parked()

    if state.socket_monitor, do: Process.demonitor(state.socket_monitor, [:flush])
    if state.socket, do: send(state.socket, {:sendspin_ws_close, reason})
    close_noise(state.noise)

    # The operator's pairing consent window (`pairing_window`) deliberately
    # survives a teardown: a transient
    # reconnect inside the 120 s window shouldn't force the operator to click
    # "allow pairing" again.
    %{
      state
      | socket: nil,
        socket_monitor: nil,
        noise: nil,
        psk_category: nil,
        trust: :none,
        client_init: nil,
        server_init: nil,
        server_id: nil,
        remote_static: nil,
        handshake_hash: nil,
        pairing_index: 0,
        conn: @conn_defaults,
        last_pairing_params: nil,
        frames_dropped: 0,
        fsm: :listening,
        reassembler: Wire.Reassembler.new(),
        # A fresh connection means a fresh server clock and a fresh local
        # basis; the filter must not carry an offset across it.
        filter: ClockFilter.reset(state.filter),
        outstanding: [],
        start_requested: false
    }
  end

  defp close_noise(nil), do: :ok

  # The rescue is required: decibel 1.0 raises `Decibel.SessionError` on an
  # already-closed session, and several teardown paths here can reach the same
  # session twice (a re-handshake retiring `previous`, then terminate/2).
  defp close_noise(session) do
    Noise.close(session)
  rescue
    _ -> :ok
  end

  # -- Websocket plumbing --

  defp send_json(state, json_text) do
    case Noise.encrypt(state.noise, Wire.wrap_json(json_text)) do
      {:ok, ciphertext} ->
        push(state, {:binary, ciphertext})
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp push(%__MODULE__{socket: nil}, _frame), do: :ok

  defp push(%__MODULE__{socket: pid}, frame) do
    send(pid, {:sendspin_ws_push, [frame]})
    :ok
  end

  defp notify(%__MODULE__{owner: owner, key: key}, event) do
    send(owner, {:source_event, key, event})
    :ok
  end

  # -- Helpers --

  # `client_id`/`server_id` must be exactly 43 base64url characters decoding
  # to exactly 32 raw bytes — both checks, per aiosendspin's `_peer_pub_bytes`.
  defp decode_public_key(text) when byte_size(text) == 43 do
    case Base.url_decode64(text, padding: false) do
      {:ok, <<key::binary-size(32)>>} -> {:ok, key}
      _other -> {:error, {:invalid_public_key, text}}
    end
  end

  defp decode_public_key(text) when is_binary(text),
    do: {:error, {:invalid_public_key, truncate_text(text)}}

  # `server_id` and peer-chosen reasons are unbounded attacker input; bound
  # them before they reach the log so a peer can't flood RingLogger.
  defp truncate_reason(reason), do: reason |> inspect() |> truncate_text()

  # Slices by codepoints (values here come from JSON, i.e. valid UTF-8) so the
  # truncated string stays a valid binary for the logger.
  defp truncate_text(text) when is_binary(text) and byte_size(text) > @log_reason_max,
    do: String.slice(text, 0, @log_reason_max) <> "…"

  defp truncate_text(text), do: text

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)

  # Every client offers the Pairing PSK method; beside it, the dynamic pairing
  # code in `digits` form, which we show on the Audio tab (the operator types it
  # into MA).
  defp default_pair_methods do
    %{pairing_psk: %{}, dynamic_pairing_code: %{out_channels: ["display"], formats: ["digits"]}}
  end

  # Same four fields the C++ player reports, sourced the same way, so both
  # roles of one device present identically in MA.
  defp default_device_info do
    %{
      product_name: DeviceInfo.node_name() || "universal_proxy",
      manufacturer: "Universal Proxy",
      software_version: to_string(Application.spec(:universal_proxy, :vsn))
    }
    |> put_mac_address(DeviceInfo.mac_address())
  end

  defp put_mac_address(info, mac) when is_binary(mac), do: Map.put(info, :mac_address, mac)
  defp put_mac_address(info, _mac), do: info
end
