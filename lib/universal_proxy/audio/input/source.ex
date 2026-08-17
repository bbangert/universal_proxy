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
                            loop runs from here for the rest of the connection
      :pairing_required     activate withheld source@v1 and granted the
                            pairing activity while we are unpaired; we are
                            holding the offer for operator consent, or a PIN
                            attempt is running or waiting to be re-offered
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

  ## Pairing

  `source@v1` can never activate at trust `none`, so a capture card must pair
  before it can stream. The server signals that by granting the `pairing`
  activity while withholding `source@v1`.

  Pairing is gated on an explicit **local operator gesture**
  (`allow_pairing/1`, a button on the Audio tab). A peer-sent pairing
  `server/activate` on its own does **not** open an attempt — but it is not
  instantly aborted either. We **hold** it in `:pairing_required` (surfacing the
  "Allow pairing" affordance) and wait, mirroring MA's `start_pin_pairing`,
  which sends the offer and then waits for `client/pair-init` rather than
  demanding an immediate reply. Only once the operator opens a time-boxed
  (120 s) window do we send `client/pair-init` and drive
  `UniversalProxy.Sendspin.Pairing` through the CPace exchange. If the operator
  never consents, a consent-wait timeout (also 120 s, matching MA's window)
  sends `pair/abort` and returns the connection to idle — an un-consented offer
  never pairs, so an attacker gains nothing. Attempts are
  capped at 3 per connection with a backoff between
  retries (bounding an online PIN brute force), and an attempt is refused
  outright while a long-term PSK already exists (an operator must unpair first)
  so a Sentinel-keyed attacker can't overwrite the stored PSK.

  **We derive and display the PIN** — the operator types it into Music
  Assistant, not the other way round. It surfaces as `{:pairing_pin, pin}`
  once `server/pair-init` reveals the server's nonce.

  A completed attempt persists the minted PSK via `Store.save_pairing/3` and
  the server then re-runs the Noise handshake **in band** (ground truth §4):
  two `noise/handshake` messages carried as ordinary encrypted JSON, prologued
  with the *previous* handshake's hash rather than the `client/init` +
  `server/init` bytes, our message 2 still encrypted under the old session.
  Afterwards the connection replays `server/hello` → `client/hello` (trust
  now `user`) → `server/activate`, which is why a re-handshake rewinds the FSM
  to `:awaiting_server_hello` and resets the pairing counter.

  An attempt that fails — the server's MCF tag not verifying (a mistyped
  PIN), a `pair/abort` from the server, or our own 120 s window expiring —
  leaves the connection up and the FSM back in `:pairing_required`, because
  the server retries by sending another pairing `server/activate` and each one
  increments `pairing_index`.

  ## Streaming lifecycle

  `source@v1` streaming is *server-commanded*: the default after a handshake
  is stopped, and a server MUST NOT be sent audio until it asks
  (`roles/source/v1.md` lines 44-50; aiosendspin's server role silently drops
  — and flags as noncompliant — a `client_stream/start` that arrives without a
  preceding `server/command.source.command = "start"`). So capture is spawned
  and `client_stream/start` sent only on that command, and `stop` tears both
  down again with a `client_stream/end`. Both directions are idempotent.

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
      :paired                     PSK minted and persisted; awaiting the
                                  post-pairing re-handshake
      :pairing_declined           a held offer expired without the operator's
                                  consent; we sent `pair/abort` and are back
                                  connected-and-idle
      {:pairing_failed, reason}   attempt abandoned; MA may offer another
      :streaming                  capture up, client_stream/start sent
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
      we only *decode* fragment types 2/3 (via `Wire.Reassembler`), never emit
      them.
    * **A re-handshake stops an open stream.** The spec is ambiguous about
      whether streaming survives one (`roles/source/v1.md` says a fresh
      handshake resets to "not streaming", but the server's role object —
      and therefore its `_start_requested` flag — outlives an in-band
      re-handshake). We stop, because the replayed `server/activate` is
      free to withhold the role entirely; a server that wanted the stream
      back re-sends `server/command.start`, which spec explicitly permits.
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

  # We advertise one method and can drive one method.
  @pair_method :dynamic_pin
  @min_pin_digits 4
  @max_pin_digits 12
  @default_min_pin_length 6

  # Pairing is gated on an explicit local operator gesture
  # (`allow_pairing/1`): a peer-sent pairing `server/activate` never opens an
  # attempt on its own. The window is time-boxed, at most three attempts run
  # per connection, and each retry backs off — bounding an online PIN brute
  # force to a handful of guesses.
  @max_pairing_attempts 3
  @pairing_backoff_ms 300
  @pairing_window_ms 120_000

  # A per-source accept rate limit, sized only to catch pathological churn (a
  # peer wedged in a tight connect/disconnect loop). It is a secondary backstop:
  # the real protection against a live session being flapped lives in the
  # eviction rules below (a trust-`user` incumbent is never evicted for an
  # un-authenticated challenger). Kept generous so MA's normal reconnect and
  # operator-initiated pairing-dial cadence is never refused.
  @max_accepts 30
  @accept_window_ms 60_000

  # How long the incumbent has to prove liveness before a parked challenger is
  # promoted. A live trust-`user` session answers a `client/time` inside this.
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
    :pairing_window_timer,
    :pairing_attempt_timer,
    :consent_wait_timer,
    :pairing_window_ms,
    fsm: :listening,
    trust: :none,
    reassembler: nil,
    filter: nil,
    outstanding: [],
    start_requested: false,
    pairing_index: 0,
    pairing_allowed: false,
    accepts: [],
    frames_dropped: 0
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
    * `:pairing_timeout_ms` — how long one PIN attempt may take before we
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
  # half-open connection and promote the parked challenger.
  def handle_info(:incumbent_liveness_timeout, %{parked_socket: pid} = state) when is_pid(pid) do
    Logger.info(
      "Audio.Input.Source #{inspect(state.key)} incumbent failed liveness probe; " <>
        "promoting the parked connection"
    )

    if state.parked_monitor, do: Process.demonitor(state.parked_monitor, [:flush])
    state = %{state | parked_socket: nil, parked_monitor: nil, liveness_timer: nil}

    state =
      state
      |> teardown_connection(:liveness_failed)
      |> tap(&notify(&1, :disconnected))

    {:noreply, adopt_socket(state, pid)}
  end

  def handle_info(:incumbent_liveness_timeout, state) do
    {:noreply, %{state | liveness_timer: nil}}
  end

  def handle_info(:pairing_window_timeout, state) do
    {:noreply, close_pairing_window(state)}
  end

  # The held pairing offer expired without an `allow_pairing/1` gesture. Only
  # act while still genuinely holding (no attempt opened, socket up); a stray
  # timeout that raced a consent or a teardown just clears its field.
  def handle_info(
        :consent_wait_timeout,
        %{fsm: :pairing_required, pairing: nil, socket: socket} = state
      )
      when not is_nil(socket) do
    {:noreply, decline_held_offer(state, :user_cancelled)}
  end

  def handle_info(:consent_wait_timeout, state) do
    {:noreply, cancel_consent_wait_timer(state)}
  end

  def handle_info({:open_pairing_attempt, params}, state) do
    if can_open_pairing?(state) do
      case open_pairing_now(%{state | pairing_attempt_timer: nil}, params) do
        {:ok, state} -> {:noreply, state}
        {:error, reason, state} -> {:noreply, fail(state, reason)}
      end
    else
      {:noreply, %{state | pairing_attempt_timer: nil}}
    end
  end

  def handle_info(:time_tick, state), do: {:noreply, send_time_request(state)}

  def handle_info(:pairing_timeout, %{pairing: %Pairing{}} = state) do
    state.pairing
    |> Pairing.abort(:attempt_timeout)
    |> apply_pairing_step(state)
    |> resolve_pairing_step()
  end

  def handle_info(:pairing_timeout, state), do: {:noreply, state}

  def handle_info({:capture_frame, ts_us, frame}, %{fsm: :streaming} = state) do
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

  # Frames that raced a `stop`, or arrived while degraded, are dropped: the
  # server MUST NOT receive chunks outside an open stream.
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

  defp probe_incumbent(state) do
    state |> send_time_request() |> arm_liveness_timer()
  end

  # Any inbound frame from the incumbent proves it alive: cancel the probe and
  # drop the challenger.
  defp incumbent_alive(%__MODULE__{liveness_timer: nil} = state), do: state

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

    %{
      state
      | liveness_timer:
          Process.send_after(self(), :incumbent_liveness_timeout, @incumbent_probe_ms)
    }
  end

  defp cancel_liveness_timer(%__MODULE__{liveness_timer: nil} = state), do: state

  defp cancel_liveness_timer(%__MODULE__{liveness_timer: timer} = state) do
    _ = Process.cancel_timer(timer)
    %{state | liveness_timer: nil}
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
    case Store.ensure_client_keypair(state.store, state.key) do
      {:ok, {pub, _priv} = keypair} ->
        client_id = Store.client_id(pub)
        text = Wire.encode_client_init(client_id, @protocol_version, state.suite)
        push(state, {:text, text})

        {:ok, %{state | keypair: keypair, client_id: client_id, client_init: text}}

      {:error, reason} ->
        {:error, {:keypair_unavailable, reason}}
    end
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
  # `psk_id` it chose, and psk2 means the PSK is not mixed until message 2 —
  # so message 1 authenticates under *any* PSK and we can read the id out of
  # it before committing. Decibel fixes the PSK at session creation, so a
  # mismatch means opening a second session and re-reading the same bytes.
  defp run_handshake(state, message_1) do
    prologue = Wire.prologue(state.client_init, state.server_init)

    case exchange_handshake(state, message_1, prologue) do
      {:ok, session, category} ->
        case Noise.write_handshake(session, @noise_msg2_payload) do
          {:ok, message_2} ->
            push(state, {:text, Wire.encode_noise_handshake(message_2)})

            {:ok,
             %{
               state
               | noise: session,
                 handshake_hash: Noise.handshake_hash(session),
                 psk_category: category,
                 trust: trust_level(category),
                 pairing_index: 0,
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
  defp exchange_handshake(state, message_1, prologue) do
    candidate = candidate_psk(state)

    with {:ok, session, payload} <- open_session(state, candidate, message_1, prologue) do
      finalize_session(state, session, candidate, payload, message_1, prologue)
    end
  end

  # Resolves the real PSK from message 1's plaintext and, if it differs from
  # the candidate we opened with, reopens under it. Closes the session it holds
  # on any error path so nothing leaks.
  defp finalize_session(state, session, candidate, payload, message_1, prologue) do
    with {:ok, psk_id} <- parse_psk_id(payload),
         {:ok, psk, category} <- resolve_psk(state, psk_id) do
      if psk == candidate do
        {:ok, session, category}
      else
        close_noise(session)

        case open_session(state, psk, message_1, prologue) do
          {:ok, new_session, _payload} -> {:ok, new_session, category}
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

  defp parse_psk_id(payload) do
    case Jason.decode(payload) do
      {:ok, %{"psk_id" => psk_id}} when is_binary(psk_id) -> {:ok, psk_id}
      {:ok, _other} -> {:error, :missing_psk_id}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  # Unpaired connections use the published Sentinel PSK; a paired one uses the
  # long-term PSK we minted during pairing. Anything else is a lookup miss and
  # the handshake cannot proceed (ground truth §1).
  defp resolve_psk(_state, @sentinel_psk_id), do: {:ok, Noise.sentinel_psk(), :sentinel}

  defp resolve_psk(state, psk_id) do
    case stored_pairing(state) do
      %{psk: <<_::256>> = psk, psk_id: stored_id} = pairing when is_binary(stored_id) ->
        # `psk_id` is a public hash, so timing is a negligible leak — but a
        # constant-time compare keeps the module uniformly constant-time.
        if secure_equal?(stored_id, psk_id) do
          pin_server_id(state, Map.get(pairing, :server_id))
          {:ok, psk, :long_term}
        else
          {:error, {:unknown_psk_id, psk_id}}
        end

      _other ->
        {:error, {:unknown_psk_id, psk_id}}
    end
  end

  # Detect a stolen-PSK replay from a different host: the PSK is the
  # authenticator (so we still proceed), but a long-term PSK presented under a
  # server static key other than the one we paired with is worth flagging.
  defp pin_server_id(%{server_id: current}, stored)
       when is_binary(current) and is_binary(stored) do
    unless secure_equal?(stored, current) do
      Logger.warning(
        "Audio.Input.Source long-term PSK presented from an unexpected server_id; " <>
          "possible stolen-PSK replay"
      )
    end
  end

  defp pin_server_id(_state, _stored), do: :ok

  defp secure_equal?(a, b) when byte_size(a) == byte_size(b), do: :crypto.hash_equals(a, b)
  defp secure_equal?(_a, _b), do: false

  defp candidate_psk(state) do
    case stored_pairing(state) do
      %{psk: <<_::256>> = psk} -> psk
      _other -> Noise.sentinel_psk()
    end
  end

  defp stored_pairing(state) do
    case Store.get_config(state.store, state.key) do
      {:ok, config} -> config
      :error -> %{}
    end
  catch
    :exit, _ -> %{}
  end

  # `trust_level` is exactly "did the matched PSK come from a long-term
  # pairing record" (aiosendspin `_compute_trust`).
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
    Logger.debug("Audio.Input.Source #{inspect(state.key)} ignoring message type #{type}")
    state
  end

  defp handle_message(%{fsm: :awaiting_server_hello} = state, :server_hello, _payload) do
    case send_client_hello(state) do
      :ok ->
        # Start the `client/time` clock-sync loop now, at connection setup —
        # NOT at role activation. Time sync is connection-level and
        # role-independent: aiosendspin's `_time_sync_loop` runs `while
        # self.connected` and its server replies to every `client/time`
        # regardless of any active role (ground truth §6), and a source@v1 MUST
        # converge its filter before it can report available. Running it from
        # here also keeps `server/time` replies flowing so a live-but-idle
        # (connected-yet-unpaired) session never trips Cowboy's idle timeout —
        # which is what lets MA hold the connection long enough to present its
        # pairing controls.
        {:ok, schedule_time_tick(%{state | fsm: :awaiting_activate}, 0)}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # A second (third, …) pairing `server/activate` is how the server retries
  # after a failed attempt, so `:pairing_required` accepts activate too. This
  # is the *initial* activation / pairing-retry path; a role change once
  # `source@v1` is already active is handled by the clause below.
  defp handle_message(%{fsm: fsm} = state, :server_activate, payload)
       when fsm in [:awaiting_activate, :pairing_required] do
    handle_activate(state, payload)
  end

  # `source@v1` is already active (`:syncing`/`:ready`/`:streaming`, or
  # `:degraded` where capture couldn't open) and the server re-sends
  # `server/activate`. Two cases, and neither may be silently ignored — doing so
  # would keep us capturing after the role was revoked:
  #
  #   * `source@v1` still present — a benign re-affirmation. We are already
  #     active, so this is a no-op: don't tear down a healthy stream or reset
  #     the converged clock filter (the source@v1 contract carries no "re-assert
  #     `client/state`" obligation, so nothing needs re-sending).
  #   * `source@v1` absent — MA revoked the role (another source took the
  #     target, an admin disabled it, …). Stop capture and, if streaming, send
  #     `client_stream/end`; rewind to `:awaiting_activate` holding the
  #     connection so a later `server/activate` re-activates without a
  #     reconnect. Disjoint from the pairing-retry path above (those states are
  #     not active), so the two never conflict.
  defp handle_message(%{fsm: fsm} = state, :server_activate, %{active_roles: roles})
       when fsm in [:syncing, :ready, :streaming, :degraded] do
    if is_list(roles) and @source_role in roles do
      {:ok, state}
    else
      {:ok, deactivate_source(state)}
    end
  end

  defp handle_message(state, :server_time, payload), do: handle_server_time(state, payload)

  defp handle_message(state, :server_command, %{source: source}) do
    handle_source_command(state, source)
  end

  # The in-band re-handshake (ground truth §4). The spec expects it right after
  # a successful pairing (`:awaiting_rehandshake`) or to rotate keys on an
  # already-authenticated (trust `user`) session. Accepting it from any state
  # let an unauthenticated peer drive unlimited X25519 handshakes on one
  # connection (CPU amplification), so it is now gated to those two windows.
  defp handle_message(%{fsm: :awaiting_rehandshake} = state, :noise_handshake, %{data: message_1}) do
    run_rehandshake(state, message_1)
  end

  defp handle_message(%{trust: :user} = state, :noise_handshake, %{data: message_1}) do
    run_rehandshake(state, message_1)
  end

  defp handle_message(state, :noise_handshake, %{data: _message_1}) do
    {:error, {:unexpected_rehandshake, state.fsm, state.trust}, state}
  end

  defp handle_message(state, tag, payload) when tag in @server_pairing_tags do
    handle_pairing_message(state, tag, payload)
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
        trust_level: state.trust,
        supported_roles: [@source_role],
        # Formats are NOT announced here — they go in `client_stream/start`.
        # `features` is required whenever the role is listed.
        source_v1_support: %{features: %{line_sense: false}},
        supported_pair_methods: state.pair_methods,
        # A source can never activate at trust `none`, so unpaired playback
        # access is meaningless for us and stays off.
        unpaired_access: %{enabled: false}
      })
    )
  end

  defp handle_activate(state, %{active_roles: roles, activities: activities, pairing: pairing}) do
    cond do
      is_list(roles) and @source_role in roles and state.trust == :user ->
        notify(state, :activated)
        state |> discard_pairing() |> activate()

      # `source@v1` MUST NOT activate at trust `none` (ground truth §7 / §964).
      # A spec-compliant server never does this; one that does is violating the
      # protocol, so we refuse and close rather than silently opening capture.
      is_list(roles) and @source_role in roles ->
        {:error, {:source_activated_untrusted, state.trust}, state}

      :pairing in activities and state.trust == :none ->
        notify(state, {:pairing_required, pairing})
        state = %{discard_pairing(state) | fsm: :pairing_required, last_pairing_params: pairing}
        maybe_start_pairing(state, pairing)

      # An idle `server/activate`: neither a `source@v1` role nor a pairing
      # activity. This is MA's steady state before the operator initiates
      # pairing (it dials every discovered source and holds it). Stay connected
      # and idle in `:awaiting_activate` so MA keeps a stable connection and can
      # later send a pairing or `source@v1` activate; closing here made the
      # source flap "unavailable" and never present a device to pair.
      true ->
        Logger.debug(
          "Audio.Input.Source #{inspect(state.key)} idle activate (roles=#{inspect(roles)}); staying idle"
        )

        {:ok, state}
    end
  end

  defp activate(state) do
    # The server ignores binary chunks until it has seen an initial
    # `client/state`, and `available` must stay false until the clock filter
    # converges (ground truth §6/§7). The `client/time` loop has been running
    # since `:awaiting_activate`, so the filter may already be converged: do NOT
    # reset it, drop in-flight measurements, or re-start the tick loop (that
    # would re-run convergence from zero). Just move to `:syncing` and re-check
    # availability, so an already-converged filter reports available promptly.
    case send_json(state, Wire.encode_client_state(false)) do
      :ok -> maybe_become_available(%{state | fsm: :syncing})
      {:error, reason} -> {:error, reason, state}
    end
  end

  # -- Pairing --

  # The consent gate. A pairing `server/activate` only opens an attempt when
  # (a) no long-term PSK already exists — refusing to let a Sentinel-keyed
  # attacker overwrite MA's stored PSK (`Store.save_pairing` clobbers) — and
  # (b) the operator has opened a local "allow pairing" window. Absent consent
  # we do NOT abort: we HOLD the offer in `:pairing_required` (surfacing the
  # "Allow pairing" affordance) and wait, mirroring how MA's `start_pin_pairing`
  # sends the offer and then waits for `client/pair-init` rather than demanding
  # an immediate reply. Pairing still requires the explicit operator gesture —
  # an un-consented offer just waits, then times out with no pairing.
  defp maybe_start_pairing(state, params) do
    cond do
      already_paired?(state) -> refuse_pairing(state)
      state.pairing_allowed -> start_pairing(state, params)
      true -> hold_for_consent(state)
    end
  end

  # No operator consent yet. Send neither `pair/abort` nor `client/pair-init`;
  # just hold in `:pairing_required` (already set by the caller, along with the
  # `{:pairing_required, params}` notification and `last_pairing_params`) and
  # arm a consent-wait timeout sized to MA's own pairing window. The `client/time`
  # keepalive holds the connection open in the meantime.
  defp hold_for_consent(state) do
    {:ok, arm_consent_wait(state)}
  end

  defp arm_consent_wait(state) do
    state = cancel_consent_wait_timer(state)
    timer = Process.send_after(self(), :consent_wait_timeout, state.pairing_window_ms)
    %{state | consent_wait_timer: timer}
  end

  defp cancel_consent_wait_timer(%__MODULE__{consent_wait_timer: nil} = state), do: state

  defp cancel_consent_wait_timer(%__MODULE__{consent_wait_timer: timer} = state) do
    _ = Process.cancel_timer(timer)
    %{state | consent_wait_timer: nil}
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

  defp already_paired?(state) do
    case stored_pairing(state) do
      %{psk: <<_::256>>} -> true
      _other -> false
    end
  end

  # A long-term PSK already exists: an operator must unpair first, so we refuse
  # outright rather than let a Sentinel-keyed peer overwrite the stored PSK. The
  # peer stays connected; only this offer is declined.
  defp refuse_pairing(state) do
    Logger.info(
      "Audio.Input.Source #{inspect(state.key)} declining pairing offer (already_paired)"
    )

    notify(state, {:pairing_failed, :already_paired})

    case send_json(state, Wire.encode_pair_abort(:user_cancelled)) do
      :ok -> {:ok, state}
      {:error, err} -> {:error, err, state}
    end
  end

  # `pairing_index` counts the attempts opened since the last Noise handshake,
  # first being 1 (ground truth §3). Capped at `@max_pairing_attempts` per
  # connection to bound an online PIN brute force; retries back off.
  defp start_pairing(state, params) do
    # Opening an attempt supersedes any held-offer wait.
    state = cancel_consent_wait_timer(state)
    index = state.pairing_index + 1

    cond do
      index > @max_pairing_attempts ->
        Logger.warning(
          "Audio.Input.Source #{inspect(state.key)} exceeded #{@max_pairing_attempts} " <>
            "pairing attempts; closing the connection"
        )

        {:error, :pairing_attempts_exhausted, state}

      index > 1 ->
        # Back off before a retry so a wrong-PIN loop can't be hammered.
        state = %{state | pairing_index: index}
        delay = @pairing_backoff_ms * (index - 1)
        timer = Process.send_after(self(), {:open_pairing_attempt, params}, delay)
        {:ok, %{state | pairing_attempt_timer: timer}}

      true ->
        open_pairing_now(%{state | pairing_index: index}, params)
    end
  end

  defp open_pairing_now(state, params) do
    case pair_method(params) do
      @pair_method -> open_attempt(state, params)
      other -> refuse_method(state, other)
    end
  end

  # Whether a deferred (backed-off) attempt is still valid to open: the
  # connection is up, still awaiting pairing, consent stands, no attempt is
  # already in flight, and no long-term PSK has appeared meanwhile.
  defp can_open_pairing?(state) do
    state.fsm == :pairing_required and not is_nil(state.socket) and is_nil(state.pairing) and
      state.pairing_allowed and not already_paired?(state)
  end

  # -- Pairing consent window --

  defp open_pairing_window(state) do
    state = arm_pairing_window(state)

    # Act on an offer that is already pending on the live connection.
    if state.fsm == :pairing_required and not is_nil(state.socket) and
         not is_nil(state.last_pairing_params) and is_nil(state.pairing) and
         not already_paired?(state) do
      case start_pairing(state, state.last_pairing_params) do
        {:ok, state} -> state
        {:error, reason, state} -> fail(state, reason)
      end
    else
      state
    end
  end

  defp arm_pairing_window(state) do
    state = cancel_pairing_window_timer(state)
    timer = Process.send_after(self(), :pairing_window_timeout, state.pairing_window_ms)
    expires_at = System.system_time(:second) + div(state.pairing_window_ms, 1_000)
    state = %{state | pairing_allowed: true, pairing_window_timer: timer}
    notify(state, {:pairing_window, expires_at})
    state
  end

  defp close_pairing_window(state) do
    state = %{cancel_pairing_window_timer(state) | pairing_allowed: false}
    notify(state, {:pairing_window, nil})
    state
  end

  defp cancel_pairing_window_timer(%__MODULE__{pairing_window_timer: nil} = state), do: state

  defp cancel_pairing_window_timer(%__MODULE__{pairing_window_timer: timer} = state) do
    _ = Process.cancel_timer(timer)
    %{state | pairing_window_timer: nil}
  end

  defp open_attempt(state, params) do
    opts = [
      handshake_hash: state.handshake_hash,
      pairing_index: state.pairing_index,
      suite: state.suite,
      method: @pair_method,
      pin_length: pin_length(state, params)
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

  # We advertise `dynamic_pin` alone, so anything else is a server bug; the
  # spec's own answer to it is `pair/abort` with `method_not_supported`.
  defp refuse_method(state, method) do
    case send_json(state, Wire.encode_pair_abort(:method_not_supported)) do
      :ok -> {:ok, pairing_failed(state, {:unsupported_method, method})}
      {:error, reason} -> {:error, reason, state}
    end
  end

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

  defp apply_pairing_step({:pin, pin, pairing}, state) do
    state = %{state | pairing: pairing}
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

  defp complete_pairing(state, %{psk: psk, psk_id: psk_id, category: category}) do
    attrs = %{
      psk: psk,
      psk_id: psk_id,
      psk_category: category,
      server_id: state.server_id,
      paired_at: DateTime.utc_now()
    }

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
        # the connection. The loop restarts at the replayed `server/hello`.
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
    Logger.info("Audio.Input.Source #{inspect(state.key)} pairing failed: #{inspect(reason)}")

    state = %{discard_pairing(state) | fsm: :pairing_required}
    notify(state, {:pairing_failed, reason})
    state
  end

  defp abandon_pairing(%__MODULE__{pairing: nil} = state, _reason), do: state
  defp abandon_pairing(state, reason), do: pairing_failed(state, reason)

  defp discard_pairing(state) do
    %{cancel_pairing_attempt_timer(cancel_pairing_timer(state)) | pairing: nil}
  end

  defp cancel_pairing_attempt_timer(%__MODULE__{pairing_attempt_timer: nil} = state), do: state

  defp cancel_pairing_attempt_timer(%__MODULE__{pairing_attempt_timer: timer} = state) do
    _ = Process.cancel_timer(timer)
    %{state | pairing_attempt_timer: nil}
  end

  defp arm_pairing_timer(state) do
    state = cancel_pairing_timer(state)
    timer = Process.send_after(self(), :pairing_timeout, state.pairing_timeout_ms)
    %{state | pairing_timer: timer}
  end

  defp cancel_pairing_timer(%__MODULE__{pairing_timer: nil} = state), do: state

  defp cancel_pairing_timer(%__MODULE__{pairing_timer: timer} = state) do
    _ = Process.cancel_timer(timer)
    %{state | pairing_timer: nil}
  end

  defp resolve_pairing_step({:ok, state}), do: {:noreply, state}
  defp resolve_pairing_step({:error, reason, state}), do: {:noreply, fail(state, reason)}

  defp pair_method(%{method: method}) when is_atom(method) and not is_nil(method), do: method
  defp pair_method(_params), do: @pair_method

  # `L = max(client_min, server_min)`, clamped to 4..12 (ground truth §3).
  defp pin_length(state, params) do
    client_min = client_min_pin_length(state)
    server_min = server_min_pin_length(params)

    client_min
    |> max(server_min)
    |> min(@max_pin_digits)
    |> max(@min_pin_digits)
  end

  defp client_min_pin_length(state) do
    Enum.find_value(state.pair_methods, @default_min_pin_length, fn descriptor ->
      case descriptor do
        %{method: @pair_method, min_pin_length: length} when is_integer(length) -> length
        _other -> nil
      end
    end)
  end

  defp server_min_pin_length(%{pin_length: length}) when is_integer(length), do: length
  defp server_min_pin_length(_params), do: 0

  defp save_pairing(state, attrs) do
    Store.save_pairing(state.store, state.key, attrs)
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

    case exchange_handshake(state, message_1, state.handshake_hash) do
      {:ok, session, category} ->
        # `send_json/2` still encrypts message 2 under the *old* session
        # (`state.noise` = `previous`); the new keys take effect only from the
        # next frame. If message 2 can't be produced or sent, close the freshly
        # opened session so it doesn't leak.
        with {:ok, message_2} <- Noise.write_handshake(session, @noise_msg2_payload),
             :ok <- send_json(state, Wire.encode_noise_handshake(message_2)) do
          close_noise(previous)
          {:ok, swap_session(state, session, category)}
        else
          {:error, reason} ->
            close_noise(session)
            {:error, reason, state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # Everything but `client_id`, `server_id` and the cipher suite resets: the
  # connection replays server/hello → client/hello → server/activate, and the
  # pairing counter restarts at 0 for the new handshake hash.
  defp swap_session(state, session, category) do
    if state.fsm == :streaming, do: notify(state, :stopped)

    state = state |> stop_capture() |> cancel_time_timer() |> discard_pairing()

    %{
      state
      | noise: session,
        handshake_hash: Noise.handshake_hash(session),
        psk_category: category,
        trust: trust_level(category),
        pairing_index: 0,
        fsm: :awaiting_server_hello,
        filter: ClockFilter.reset(state.filter),
        outstanding: [],
        start_requested: false
    }
  end

  # -- Time sync --

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
      case send_json(state, Wire.encode_client_state(true)) do
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

  defp schedule_time_tick(state, delay) do
    state = cancel_time_timer(state)
    %{state | time_timer: Process.send_after(self(), :time_tick, delay)}
  end

  defp cancel_time_timer(%__MODULE__{time_timer: nil} = state), do: state

  defp cancel_time_timer(%__MODULE__{time_timer: timer} = state) do
    _ = Process.cancel_timer(timer)
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
  # emits `client_stream/end` + `:stopped` only when a stream was actually open.
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
  defp end_stream(%{fsm: :streaming} = state) do
    state = stop_capture(state)
    _ = send_json(state, Wire.encode_client_stream_end())
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
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 2_000)
    end)

    %{state | capture: nil, stopping_capture: pid}
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

    # The operator's pairing consent window (`pairing_allowed` /
    # `pairing_window_timer`) deliberately survives a teardown: a transient
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

  # Dynamic PIN only: we derive and display the PIN, the operator types it
  # into MA (P1-T6 correction). `min_pin_length` is the spec's RECOMMENDED
  # initial value.
  defp default_pair_methods, do: [%{method: :dynamic_pin, min_pin_length: 6}]

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
