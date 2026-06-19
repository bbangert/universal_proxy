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
      Sendspin servers can discover this player.

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

      {"event":"started","version":"0.1.0","port":8928,"name":"Out 1","alsa_device":"plughw:0,0","formats":[{"codec":"flac","channels":2,"rate":48000,"bit_depth":16}]}
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

  defstruct [
    :key,
    :config,
    :binary_path,
    :mdns_port,
    :server_url,
    :pubsub,
    :mdns_module,
    port: nil,
    mdns_id: nil,
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
          port: port() | nil,
          mdns_id: term(),
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

    state = %__MODULE__{
      key: key,
      config: config,
      binary_path: binary_path,
      mdns_port: mdns_port,
      server_url: server_url,
      pubsub: pubsub,
      mdns_module: mdns_module
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

        register_mdns(state)
        new_state = %{state | port: port, mdns_id: mdns_service_id(key), os_pid: os_pid}

        # `--initial-volume` is the only startup config the binary
        # accepts on its CLI; there's no `--initial-muted`. If DETS
        # says this output is muted, push a `set_muted` command over
        # stdin right after the port is open so the binary's default
        # (unmuted) doesn't briefly play before the BEAM tells it the
        # truth. Volume is already covered by `--initial-volume`.
        if Map.get(config, :muted, false) do
          send_command(new_state, {:set_muted, true})
        end

        schedule_reannounces(opts)

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

  # RFC 6762 §8.3 calls for at least two unsolicited announcements ~1 s
  # apart when a service comes up. mdns_lite 0.9.1 sends zero, so we
  # synthesize them via `Audio.MdnsAnnouncer.announce/1`. Tests can
  # override `reannounce_delays_ms:` to skip the schedule.
  defp schedule_reannounces(opts) do
    delays = Keyword.get(opts, :reannounce_delays_ms, @reannounce_delays_ms)

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

  defp register_mdns(%__MODULE__{key: key, config: cfg, mdns_port: port, mdns_module: mod}) do
    friendly_name = Map.fetch!(cfg, :friendly_name)
    client_id = Map.fetch!(cfg, :client_id)

    # Set the mDNS *instance name* to the user-facing friendly name.
    # Without this, all our `_sendspin._tcp` services share the host's
    # default instance name (e.g. `nerves-507f._sendspin._tcp.local`),
    # which means:
    #   1. Music Assistant's python-zeroconf can't distinguish two
    #      ALSA outputs on the same Pi — they collide on the instance
    #      name.
    #   2. Renaming an output doesn't change the instance name, so
    #      MA's `_handle_service_added` sees no service-instance
    #      change and its UI keeps showing the old name forever.
    # By setting instance_name = friendly_name we get a clean
    # Removed/Added cycle on rename, and the new name lands in MA's
    # display the next time it processes the Added event.
    #
    # `sanitize_instance_name/1` strips control chars and trims; the
    # mDNS wire format allows arbitrary UTF-8 in instance names, so
    # spaces, accents, etc. are fine and don't need escaping.
    service = %{
      id: mdns_service_id(key),
      instance_name: sanitize_instance_name(friendly_name),
      protocol: "sendspin",
      transport: "tcp",
      port: port,
      txt_payload: [
        "path=/sendspin",
        "name=#{friendly_name}",
        "client_id=#{client_id}"
      ]
    }

    case mod.add_mdns_service(service) do
      :ok ->
        :ok

      other ->
        Logger.warning("MdnsLite.add_mdns_service returned #{inspect(other)} for #{inspect(key)}")

        :ok
    end
  rescue
    e ->
      # mdns_lite may not be running in dev / on host with no
      # network — log and continue. Player still functions; just
      # not LAN-discoverable.
      Logger.warning("MdnsLite advertise failed for #{inspect(key)}: #{Exception.message(e)}")

      :ok
  catch
    # MdnsLite.add_mdns_service/1 is a GenServer.call. If the
    # MdnsLite TableServer is stopped or mid-restart it exits with
    # `:noproc`/`:timeout` — not an exception. `rescue` alone misses
    # these; we want best-effort registration regardless of the
    # signal shape.
    :exit, reason ->
      Logger.warning("MdnsLite advertise exited for #{inspect(key)}: #{inspect(reason)}")
      :ok
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
