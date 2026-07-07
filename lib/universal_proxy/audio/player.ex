defmodule UniversalProxy.Audio.Player do
  @moduledoc """
  GenServer wrapping a single `sendspin_player` OS process.

  One `Audio.Player` per enabled ALSA output, supervised under the
  `UniversalProxy.Audio.PlayerSupervisor` `DynamicSupervisor`. The
  player owns:

    * A `Port` opened with `{:spawn_executable, binary_path}` and
      `{:line, 4096}` packet mode — stdout JSON events arrive as
      `{port, {:data, {:eol, line}}}` messages.
    * Stdin commands (`set_volume`, `set_muted`, `shutdown`) written
      via `Port.command/2` as line-delimited JSON.
    * The `MdnsLite` service advertisement for `_sendspin._tcp` so
      Sendspin servers can discover this player. Registered only once
      the binary reports `listening` (WebSocket listener bound), NOT
      at init: Music Assistant's discovery connect is one-shot
      (aiosendspin `retry_initial_connection=False`), so advertising
      into the spawn-to-bind gap makes MA burn its single attempt on
      a connection refused and orphan the player until the mDNS
      record next flaps.

  ## Why raw Port (no MuonTrap)

  `MuonTrap.Daemon` closes stdin and routes stdout through Logger —
  unusable for bidirectional JSON IPC. Wrapping muontrap with
  `--capture-output` requires implementing its byte-ack protocol and
  loses `{:line, N}` packet framing. See `scratchpad.md` ("Phase 3
  IPC decision") for the full trade-off. Net: on a BEAM crash a
  binary may be orphaned briefly, but Nerves reboots on crash and
  the kernel reaps orphans on reboot.

  ## JSON protocol

  Events (binary → BEAM, one per stdout line). Wire format is the
  canonical contract documented in `c_src/sendspin_player/README.md`
  ("Stdout events" section) — keep this list in sync with that
  README and with `main.cpp`'s `emit_json` call sites.

      {"event":"started","version":"0.1.0","port":8928,"name":"Out 1","product":"universal-proxy-07507f","alsa_device":"plughw:0,0","formats":[{"codec":"flac","channels":2,"rate":48000,"bit_depth":16}]}
      {"event":"listening","port":8928}
      {"event":"connected","server":"ws://music.local:8927/sendspin"}
      {"event":"disconnected"}
      {"event":"stream_start","sample_rate":48000,"channels":2,"bit_depth":16,"codec":"opus"}
      {"event":"stream_end"}
      {"event":"time_sync","error_us":42.3}
      {"event":"volume","value":80}
      {"event":"mute","value":false}
      {"event":"static_delay","value":200}
      {"event":"error","kind":"alsa_configure","msg":"..."}
      {"event":"shutdown"}

  Commands (BEAM → binary, written to stdin):

      {"cmd":"set_volume","value":75}
      {"cmd":"set_muted","value":true}
      {"cmd":"shutdown"}

  Each event is broadcast on PubSub topic `"sendspin:state"` as
  `{:sendspin_state, key, event_map}` so `LiveView` (Phase 4) and the
  `Audio.Server` cache can stay in sync without polling.
  """

  # `:temporary` — the parent `DynamicSupervisor` never restarts us
  # automatically. Restart policy lives in `Audio.Server`, which owns
  # the per-output state (port allocation, mDNS id, config) needed to
  # spawn a sensible replacement. A `DynamicSupervisor`-driven restart
  # would produce a fresh PID that `Audio.Server` doesn't know about,
  # so its `Player.set_volume/2` calls would hit a dead process.
  use GenServer, restart: :temporary

  require Logger

  alias UniversalProxy.Audio.Store

  @pubsub UniversalProxy.PubSub
  @topic_state "sendspin:state"
  @shutdown_grace_ms 500

  # RFC 6762 §8.3 announces. We call `MdnsLite.announce_all/0` (added
  # in our vendored fork) to emit proper multicast response packets
  # from port 5353 with TTL>0 — exactly the shape peers like Music
  # Assistant's `python-zeroconf` accept. Spaced over the first few
  # seconds to cover initial peer-discovery jitter.
  @reannounce_delays_ms [500, 1_500, 3_500]

  # Base retry cadence when mDNS registration fails on the `listening`
  # event (MdnsLite down or mid-restart at that one instant). Backs off
  # exponentially per consecutive failure, capped at @mdns_retry_max_ms —
  # on hosts where MdnsLite intentionally isn't running the retry loop
  # would otherwise tick (and log) every base interval forever.
  @mdns_retry_ms 5_000
  @mdns_retry_max_ms 60_000

  # One warning if the binary never reports `listening` — a player in
  # that state runs fine but is invisible to Sendspin servers, and
  # nothing else would say why.
  @mdns_watchdog_ms 15_000

  defstruct [
    :key,
    :config,
    :binary_path,
    :mdns_port,
    :server_url,
    :pubsub,
    :mdns_module,
    :device_name_fun,
    port: nil,
    mdns_id: nil,
    mdns_registered: false,
    reannounce_delays_ms: [],
    mdns_retry_ms: @mdns_retry_ms,
    mdns_failures: 0,
    last_event: %{},
    os_pid: nil
  ]

  @type t :: %__MODULE__{
          key: Store.output_key(),
          config: map(),
          binary_path: String.t(),
          mdns_port: pos_integer(),
          server_url: String.t() | nil,
          pubsub: module(),
          mdns_module: module(),
          # `init/1` passes this through untouched and `safe_device_name/1`
          # tolerates a non-function (returns nil), so the type is widened
          # past the expected 0-arity function to match the runtime.
          device_name_fun: (-> String.t() | nil) | term(),
          port: port() | nil,
          mdns_id: term(),
          mdns_registered: boolean(),
          reannounce_delays_ms: [non_neg_integer()],
          mdns_retry_ms: pos_integer(),
          mdns_failures: non_neg_integer(),
          last_event: map(),
          os_pid: pos_integer() | nil
        }

  # -- Client API --

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @doc """
  Push `{"cmd":"set_volume","value":n}` to the binary's stdin.
  Returns `:ok` even when the port is closed (the player is exiting);
  the next `start_link` will pick up the new volume from DETS via
  `--initial-volume`.
  """
  @spec set_volume(GenServer.server(), 0..100) :: :ok
  def set_volume(server, value) when is_integer(value) and value in 0..100 do
    GenServer.call(server, {:set_volume, value})
  end

  @doc """
  Push `{"cmd":"set_muted","value":true|false}` to the binary's
  stdin.
  """
  @spec set_muted(GenServer.server(), boolean()) :: :ok
  def set_muted(server, muted?) when is_boolean(muted?) do
    GenServer.call(server, {:set_muted, muted?})
  end

  @doc """
  Return the last parsed status event, or `%{}` if no event has been
  received yet. Tests and the LiveView read through this on mount
  before subscribing to PubSub.
  """
  @spec last_event(GenServer.server()) :: map()
  def last_event(server), do: GenServer.call(server, :last_event)

  @doc false
  # Test seam: send an arbitrary JSON command to the binary's stdin.
  # Used by `Audio.PlayerTest` to drive the fake binary's
  # `force_exit` command without exposing a "send raw bytes to a child
  # process" API to production callers.
  @spec __send_command__(GenServer.server(), map()) :: :ok
  def __send_command__(server, cmd) when is_map(cmd) do
    GenServer.cast(server, {:__send_command__, cmd})
  end

  # -- Server Callbacks --

  @impl true
  def init(opts) do
    # Trap exits so `DynamicSupervisor.terminate_child/2` triggers our
    # `terminate/2` — without this, the supervisor's `:shutdown` exit
    # signal kills us instantly and we'd leak the OS process and the
    # mDNS advertisement. `GenServer.stop` calls `terminate/2` either
    # way, so test parity is preserved.
    Process.flag(:trap_exit, true)

    key = Keyword.fetch!(opts, :key)
    config = Keyword.fetch!(opts, :config)
    mdns_port = Keyword.fetch!(opts, :mdns_port)
    binary_path = Keyword.get(opts, :binary_path) || default_binary_path()
    server_url = Keyword.get(opts, :server_url)
    pubsub = Keyword.get(opts, :pubsub, @pubsub)
    mdns_module = Keyword.get(opts, :mdns_module, MdnsLite)
    device_name_fun = Keyword.get(opts, :device_name_fun, &default_device_name/0)

    state = %__MODULE__{
      key: key,
      config: config,
      binary_path: binary_path,
      mdns_port: mdns_port,
      server_url: server_url,
      pubsub: pubsub,
      mdns_module: mdns_module,
      device_name_fun: device_name_fun
    }

    cond do
      not File.exists?(binary_path) ->
        Logger.error(
          "Audio.Player binary missing at #{binary_path}; refusing to start #{inspect(key)}"
        )

        {:stop, {:binary_missing, binary_path}}

      true ->
        port = open_port(state)
        # Port.info/2 returns `nil` if the port closed between open and
        # this call — happens when the binary exits immediately (bad arg,
        # missing libasound). `force_kill/1` already guards against
        # `os_pid: nil`, so we just pattern-match here instead of
        # crashing init with a misleading ArgumentError.
        os_pid =
          case Port.info(port, :os_pid) do
            {:os_pid, pid} -> pid
            nil -> nil
          end

        # mDNS registration is deferred until the binary's `listening`
        # event (WebSocket listener bound) — see the moduledoc. Only
        # `mdns_id` is set here so `terminate/2` can best-effort
        # remove/goodbye even if the binary never got that far.
        new_state = %{
          state
          | port: port,
            mdns_id: mdns_service_id(key),
            os_pid: os_pid,
            reannounce_delays_ms: Keyword.get(opts, :reannounce_delays_ms, @reannounce_delays_ms),
            mdns_retry_ms: Keyword.get(opts, :mdns_retry_ms, @mdns_retry_ms)
        }

        # One-shot diagnostic: if the binary never reports `listening`
        # (listener can't bind, wedged startup), the player would run
        # healthy but undiscoverable with no trace anywhere — surface it.
        Process.send_after(
          self(),
          :mdns_watchdog,
          Keyword.get(opts, :mdns_watchdog_ms, @mdns_watchdog_ms)
        )

        # `--initial-volume` is the only startup config the binary
        # accepts on its CLI; there's no `--initial-muted`. If DETS
        # says this output is muted, push a `set_muted` command over
        # stdin right after the port is open so the binary's default
        # (unmuted) doesn't briefly play before the BEAM tells it the
        # truth. Volume is already covered by `--initial-volume`.
        if Map.get(config, :muted, false) do
          send_command(new_state, {:set_muted, true})
        end

        {:ok, new_state}
    end
  end

  @impl true
  def handle_call({:set_volume, value}, _from, state) do
    send_command(state, {:set_volume, value})
    {:reply, :ok, state}
  end

  def handle_call({:set_muted, muted?}, _from, state) do
    send_command(state, {:set_muted, muted?})
    {:reply, :ok, state}
  end

  def handle_call(:last_event, _from, state) do
    {:reply, state.last_event, state}
  end

  @impl true
  def handle_cast({:__send_command__, cmd}, state) do
    send_command(state, cmd)
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    # `keys: :atoms` (NOT `:atoms!`) — interns unknown keys. The C++
    # binary's `emit_json` call sites are the only producers and their
    # key set is statically defined in `c_src/sendspin_player/src/main.cpp`,
    # so the keyspace is finite and code-controlled. Values can be
    # network-derived (codec strings, error messages from the Sendspin
    # server) but values aren't atomised by `:atoms`, only keys.
    case Jason.decode(line, keys: :atoms) do
      {:ok, %{event: _} = event} ->
        state = maybe_register_mdns(state, event)
        broadcast_state(state, event)
        {:noreply, %{state | last_event: event}}

      {:ok, _other} ->
        Logger.debug("Audio.Player #{inspect(state.key)} got non-event JSON: #{line}")
        {:noreply, state}

      {:error, reason} ->
        Logger.warning(
          "Audio.Player #{inspect(state.key)} could not decode line (#{inspect(reason)}): #{line}"
        )

        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning(
      "Audio.Player #{inspect(state.key)} binary exited with status #{status}; will be respawned by Audio.Server's next hotplug poll"
    )

    # `restart: :temporary` means the DynamicSupervisor does NOT
    # auto-restart. Audio.Server's `:DOWN` handler clears its
    # `state.players[key]` entry and the next poll's
    # `respawn_missing_players/1` convergence pass spawns a fresh
    # player instance.
    {:stop, {:binary_exited, status}, %{state | port: nil}}
  end

  def handle_info(:reannounce, state) do
    # Trigger our vendored `MdnsLite.announce_all/0` (RFC 6762 §8.3
    # unsolicited announce). The library multicasts a proper response
    # packet via the responder's own socket — source port 5353, every
    # registered service type. Peer cache update + `Added` callback on
    # python-zeroconf et al. should fire from this. Failure is
    # non-fatal: peers fall back to discovery on their next poll.
    _ = state.mdns_module.announce_all()
    {:noreply, state}
  end

  def handle_info(:retry_mdns_register, %{mdns_registered: false} = state) do
    {:noreply, attempt_mdns_registration(state)}
  end

  # Registration succeeded before the retry fired — nothing to do.
  def handle_info(:retry_mdns_register, state), do: {:noreply, state}

  def handle_info(:mdns_watchdog, %{mdns_registered: false} = state) do
    Logger.warning(
      "Audio.Player #{inspect(state.key)} never reported `listening` — " <>
        "WebSocket listener not bound (port conflict? wedged startup?); " <>
        "output is running but NOT advertised via mDNS"
    )

    {:noreply, state}
  end

  def handle_info(:mdns_watchdog, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    # Best-effort graceful shutdown:
    #   1. ask the binary to exit via JSON
    #   2. wait briefly for {:exit_status, _}
    #   3. fall through to Port.close (and a SIGKILL backstop if we
    #      still have an os_pid) so we never leave a stray process.
    Logger.info("Audio.Player #{inspect(state.key)} terminating (#{inspect(reason)})")

    if state.port do
      send_command(state, :shutdown)

      receive do
        {port, {:exit_status, _}} when port == state.port -> :ok
      after
        @shutdown_grace_ms ->
          Logger.warning(
            "Audio.Player #{inspect(state.key)} didn't exit within #{@shutdown_grace_ms}ms; forcing"
          )

          force_kill(state)
      end

      safe_port_close(state.port)
    end

    if state.mdns_id do
      # Send a TTL=0 PTR goodbye BEFORE removing the service from the
      # responder's table. Without this, peer caches like
      # python-zeroconf hold our records for their full TTL — and a
      # subsequent unsolicited announce on re-enable is treated as a
      # cache refresh, never producing an `Added` callback. Music
      # Assistant therefore never re-discovers the player until its
      # cache TTL expires (default 120 s). With the goodbye, peers
      # evict the records immediately and the next announce produces
      # the `Added` event MA listens for.
      #
      # `goodbye_service/1` (vendored extension to mdns_lite) routes
      # the response through the responder's port-5353 socket, which
      # is the source port RFC 6762 §6 requires for response packets.
      _ =
        try do
          state.mdns_module.goodbye_service(state.mdns_id)
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end

      # Best-effort. `remove_mdns_service/1` is a GenServer.call into
      # MdnsLite — if MdnsLite is stopped or restarting during our
      # shutdown, the call exits (`:noproc` / `:timeout`) rather than
      # raises. We need to catch both shapes so an mDNS hiccup never
      # aborts terminate/2 mid-cleanup (port already closed by here,
      # but the log noise + non-:ok return matters).
      try do
        state.mdns_module.remove_mdns_service(state.mdns_id)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  # -- Private --

  # The binary's WebSocket listener is confirmed bound on `listening` —
  # only then is it safe to advertise. Registering earlier (init) races
  # MA's one-shot discovery connect against the spawn-to-bind gap.
  # Guarded on `mdns_registered` for idempotency; the binary emits
  # `listening` once per lifetime.
  defp maybe_register_mdns(%__MODULE__{mdns_registered: false} = state, %{event: "listening"}) do
    attempt_mdns_registration(state)
  end

  defp maybe_register_mdns(state, _event), do: state

  # On success, anchor the §8.3 reannounce burst here so its
  # cache-priming fires after the record actually exists. On failure
  # (MdnsLite down or mid-restart) schedule a retry: `listening` is a
  # one-shot signal, so without the retry a transient outage at that
  # instant would leave the player unadvertised for the binary's whole
  # lifetime. Retries are deliberately unbounded (a cap would reintroduce
  # exactly that permanent state), but the delay backs off exponentially
  # and only the FIRST failure logs at warning — later attempts log at
  # debug, so a host where MdnsLite intentionally isn't running doesn't
  # emit a warning per player per interval forever.
  defp attempt_mdns_registration(state) do
    log_level = if state.mdns_failures == 0, do: :warning, else: :debug

    case register_mdns(state, log_level) do
      :ok ->
        schedule_reannounces(state.reannounce_delays_ms)
        %{state | mdns_registered: true, mdns_failures: 0}

      :error ->
        delay =
          min(state.mdns_retry_ms * Integer.pow(2, state.mdns_failures), @mdns_retry_max_ms)

        Process.send_after(self(), :retry_mdns_register, delay)
        %{state | mdns_failures: state.mdns_failures + 1}
    end
  end

  # RFC 6762 §8.3 calls for at least two unsolicited announcements ~1 s
  # apart when a service comes up. mdns_lite 0.9.1 sends zero, so we
  # synthesize them via `Audio.MdnsAnnouncer.announce/1`. Scheduled
  # from the `listening` event (not init) so the burst fires after the
  # service is actually registered. Tests can override
  # `reannounce_delays_ms:` to skip the schedule.
  defp schedule_reannounces(delays) when is_list(delays) do
    Enum.each(delays, fn ms when is_integer(ms) and ms >= 0 ->
      Process.send_after(self(), :reannounce, ms)
    end)
  end

  defp open_port(%__MODULE__{} = state) do
    args = build_cli_args(state)

    Port.open(
      {:spawn_executable, String.to_charlist(state.binary_path)},
      [:binary, :exit_status, {:line, 4096}, {:args, args}]
    )
  end

  defp build_cli_args(%__MODULE__{config: cfg} = state) do
    base = [
      "--alsa-device",
      Map.fetch!(cfg, :alsa_device),
      "--name",
      Map.fetch!(cfg, :friendly_name),
      "--client-id",
      Map.fetch!(cfg, :client_id),
      "--mdns-port",
      Integer.to_string(state.mdns_port),
      "--initial-volume",
      Integer.to_string(Map.get(cfg, :volume, 50)),
      "--initial-static-delay-ms",
      Integer.to_string(Map.get(cfg, :static_delay_ms, 0)),
      "--log-level",
      "info"
    ]

    # Sendspin servers display device_info as "Vendor / Product" (Music
    # Assistant's player list). Pass the node name (which carries the
    # per-device MAC suffix) as the product so entries read
    # "Universal Proxy / universal-proxy-07507f" — mirroring the HA Voice
    # PE scheme ("ESPHome / home-assistant-voice-09010e"). No node name
    # (host dev) falls back to the binary's default product.
    base =
      case safe_device_name(state.device_name_fun) do
        product when is_binary(product) and product != "" -> base ++ ["--product", product]
        _ -> base
      end

    case state.server_url do
      nil -> base
      url when is_binary(url) -> base ++ ["--server", url]
    end
  end

  # The C++ binary's stdin parser is a strict left-to-right scanner that
  # requires the literal field order `{"cmd":...[,"value":...]}` (see
  # `c_src/sendspin_player/src/main.cpp` `parse_command`). `Jason.encode!/1`
  # on a map iterates in hash order, which for our 2-key maps is
  # unstable — sometimes it emits `cmd` first, sometimes `value`. When
  # `value` came first the binary silently dropped the command. We
  # build the wire bytes manually so order is locked.
  #
  # The map-shaped clause stays for `__send_command__/2` (test seam);
  # the fake binary uses `json.loads` which is order-insensitive, so
  # `Jason.encode!` is safe there.
  defp send_command(%__MODULE__{port: nil}, _cmd), do: :ok

  defp send_command(state, {:set_volume, value}) when is_integer(value) do
    send_raw(state, [~s({"cmd":"set_volume","value":), Integer.to_string(value), ~s(})])
  end

  defp send_command(state, {:set_muted, muted?}) when is_boolean(muted?) do
    send_raw(state, [~s({"cmd":"set_muted","value":), to_string(muted?), ~s(})])
  end

  defp send_command(state, :shutdown) do
    send_raw(state, ~s({"cmd":"shutdown"}))
  end

  defp send_command(state, cmd) when is_map(cmd) do
    send_raw(state, Jason.encode!(cmd))
  end

  defp send_raw(%__MODULE__{port: port}, iodata) when is_port(port) do
    Port.command(port, [iodata, "\n"])
  rescue
    ArgumentError ->
      # Port was closed between our nil-check and the command — fine,
      # the binary is on its way out.
      :ok
  end

  # `log_level` throttles the failure logging across the retry loop:
  # :warning for the first attempt, :debug for retries.
  defp register_mdns(
         %__MODULE__{
           key: key,
           config: cfg,
           mdns_port: port,
           mdns_module: mod,
           device_name_fun: device_name_fun
         },
         log_level
       ) do
    friendly_name = Map.fetch!(cfg, :friendly_name)
    client_id = Map.fetch!(cfg, :client_id)

    # Set the mDNS *instance name* to the user-facing output name, suffixed
    # with the device node name (e.g. `bcm2835 Headphones
    # (universal-proxy-45099b)`). Two reasons the name carries identity:
    #   1. Music Assistant's python-zeroconf can't distinguish two
    #      ALSA outputs on the same Pi if they share an instance name —
    #      and identically-named outputs on *different* Pis (the common
    #      `bcm2835 Headphones`) are indistinguishable without the device
    #      suffix. The node name disambiguates both.
    #   2. Renaming an output changes the instance name, giving MA a clean
    #      Removed/Added cycle so the new name lands in its UI.
    #
    # `sendspin_instance_name/2` composes the two, preserving the device
    # suffix within the 63-byte mDNS label budget (the output portion is
    # truncated first). mDNS allows arbitrary UTF-8 in instance names, so
    # spaces, accents, etc. are fine and don't need escaping.
    display_name = sendspin_instance_name(friendly_name, safe_device_name(device_name_fun))

    service = %{
      id: mdns_service_id(key),
      instance_name: display_name,
      protocol: "sendspin",
      transport: "tcp",
      port: port,
      txt_payload: [
        "path=/sendspin",
        "name=#{display_name}",
        "client_id=#{client_id}"
      ]
    }

    case mod.add_mdns_service(service) do
      :ok ->
        :ok

      other ->
        Logger.log(
          log_level,
          "#{inspect(mod)}.add_mdns_service returned #{inspect(other)} for #{inspect(key)}"
        )

        :error
    end
  rescue
    e ->
      # mdns_lite may not be running in dev / on host with no
      # network — log, report failure so the caller can retry.
      # Player still functions either way; just not LAN-discoverable
      # until a retry succeeds.
      Logger.log(
        log_level,
        "#{inspect(mod)} advertise failed for #{inspect(key)}: #{Exception.message(e)}"
      )

      :error
  catch
    # MdnsLite.add_mdns_service/1 is a GenServer.call. If the
    # MdnsLite TableServer is stopped or mid-restart it exits with
    # `:noproc`/`:timeout` — not an exception. `rescue` alone misses
    # these; we want best-effort registration regardless of the
    # signal shape.
    :exit, reason ->
      Logger.log(
        log_level,
        "#{inspect(mod)} advertise exited for #{inspect(key)}: #{inspect(reason)}"
      )

      :error
  end

  defp mdns_service_id({slot_sub, vid, pid}) do
    {:sendspin_player, slot_sub, vid, pid}
  end

  # mDNS allows arbitrary UTF-8 in the *instance* portion of a service
  # name (the FQDN's leftmost label). The wire-format DNS label still
  # has to be ≤ 63 BYTES (RFC 1035 §2.3.4), not codepoints — multi-byte
  # UTF-8 sequences (accents, CJK, emoji) easily push past the limit
  # if we count graphemes. We trim to the byte budget at codepoint
  # boundaries so the resulting string is always valid UTF-8 and never
  # produces a malformed mDNS RR. Control chars get stripped first,
  # and an empty post-clean string falls back to a stable placeholder.
  defp sanitize_instance_name(raw) when is_binary(raw) do
    cleaned =
      raw
      |> String.replace(~r/[[:cntrl:]]/u, "")
      |> String.trim()
      |> truncate_to_byte_limit(63)

    if cleaned == "", do: "sendspin", else: cleaned
  end

  defp sanitize_instance_name(_), do: "sendspin"

  @doc false
  # Compose the sendspin mDNS instance name as "<output> (<node>)",
  # preserving the device suffix within the 63-byte mDNS label budget:
  # the output portion is truncated first so the identifier always
  # survives. With no node name it degrades to the bare output name.
  @spec sendspin_instance_name(String.t(), String.t() | nil) :: String.t()
  def sendspin_instance_name(friendly_name, node) when is_binary(node) and node != "" do
    # The node name (ConfigStore accepts any binary for `:name`) is
    # interpolated into the label and the TXT `name=` value, so strip
    # control chars/trim first. If nothing survives, degrade to the bare
    # output name rather than emit a `" ()"`-style suffix.
    do_sendspin_instance_name(friendly_name, clean_instance_string(node))
  end

  def sendspin_instance_name(friendly_name, _), do: sanitize_instance_name(friendly_name)

  defp do_sendspin_instance_name(friendly_name, ""), do: sanitize_instance_name(friendly_name)

  defp do_sendspin_instance_name(friendly_name, node) do
    suffix = " (#{node})"

    case 63 - byte_size(suffix) do
      budget when budget > 0 ->
        # A blank output name falls back to the plain placeholder so we
        # never emit a leading-space " (node)" label.
        base =
          friendly_name
          |> clean_instance_string()
          |> truncate_to_byte_limit(budget)
          |> String.trim_trailing()

        if base == "", do: "sendspin" <> suffix, else: base <> suffix

      # Pathologically long node name — can't fit a suffix, keep the
      # output name so the player is at least still discoverable.
      _ ->
        sanitize_instance_name(friendly_name)
    end
  end

  # Strip control chars and trim — shared by the plain and suffixed
  # instance-name paths.
  defp clean_instance_string(raw) when is_binary(raw) do
    raw
    |> String.replace(~r/[[:cntrl:]]/u, "")
    |> String.trim()
  end

  defp clean_instance_string(_), do: ""

  # The device node name (ESPHome identity), read defensively: ConfigStore
  # starts before Audio, but a lookup failure degrades to an unsuffixed
  # name rather than blocking mDNS registration.
  defp default_device_name do
    UniversalProxy.ESPHome.ConfigStore.current().name
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp safe_device_name(fun) when is_function(fun, 0) do
    fun.()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp safe_device_name(_), do: nil

  defp truncate_to_byte_limit(s, max) when byte_size(s) <= max, do: s

  defp truncate_to_byte_limit(s, max) do
    s
    |> String.codepoints()
    |> Enum.reduce_while({"", 0}, fn cp, {acc, sz} ->
      new_sz = sz + byte_size(cp)
      if new_sz > max, do: {:halt, {acc, sz}}, else: {:cont, {acc <> cp, new_sz}}
    end)
    |> elem(0)
  end

  defp broadcast_state(%__MODULE__{key: key, pubsub: pubsub}, event) do
    Phoenix.PubSub.broadcast(pubsub, @topic_state, {:sendspin_state, key, event})
  end

  defp force_kill(%__MODULE__{os_pid: nil}), do: :ok

  defp force_kill(%__MODULE__{os_pid: pid}) do
    # SIGKILL via :os.cmd is portable and doesn't require muontrap.
    # The kernel will reap; we don't care about the result.
    _ = :os.cmd(~c"kill -9 #{pid} 2>/dev/null")
    :ok
  end

  defp safe_port_close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  # `Mix.target/0` is evaluated at compile time and baked into the
  # release. Reading it from `Application.get_env` at runtime
  # (with a "host" default) was wrong — on the device nothing sets
  # that env, so we'd look in `priv/sendspin_player/host/` which is
  # excluded from the rpi3 firmware. The C++ compile task already
  # places the binary at `priv/sendspin_player/<MIX_TARGET>/sendspin_player`.
  @target_dir to_string(Mix.target())

  defp default_binary_path do
    Path.join([
      :code.priv_dir(:universal_proxy) |> List.to_string(),
      "sendspin_player",
      @target_dir,
      "sendspin_player"
    ])
  end
end
