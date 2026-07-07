defmodule UniversalProxy.Audio.PlayerTest do
  # async: false — the suite shares a named `MdnsStub` Agent across
  # tests, and each test subscribes to the global `sendspin:state`
  # PubSub topic to observe Player's broadcasts. Two tests running
  # concurrently would tangle each other's mDNS calls and crossed
  # PubSub messages.
  use ExUnit.Case, async: false

  alias UniversalProxy.Audio.Player

  @pubsub UniversalProxy.PubSub
  @fake_binary Path.expand("../../support/fake_sendspin_player.py", __DIR__)
  @key {"bcm2835 Headphones", nil, nil}

  defmodule MdnsStub do
    @moduledoc """
    Stands in for `MdnsLite` in tests. Records calls so assertions
    can verify Player wired add/remove/announce_all correctly. The
    `announce_all/0` shape mirrors our vendored `MdnsLite.announce_all/0`.
    """
    use Agent

    def start_link(_initial \\ []) do
      Agent.start_link(fn -> %{calls: [], fail_adds: 0} end, name: __MODULE__)
    end

    @doc """
    Make the next `n` add_mdns_service calls fail with `{:error, :noproc}`,
    mimicking MdnsLite's TableServer being down/mid-restart. Recorded as
    `{:add_failed, service}` so tests can assert the failed attempt.
    """
    def fail_next_adds(n) do
      Agent.update(__MODULE__, fn s -> %{s | fail_adds: n} end)
    end

    def add_mdns_service(service) do
      Agent.get_and_update(__MODULE__, fn
        %{fail_adds: n} = s when n > 0 ->
          {{:error, :noproc}, %{s | fail_adds: n - 1, calls: [{:add_failed, service} | s.calls]}}

        s ->
          {:ok, %{s | calls: [{:add, service} | s.calls]}}
      end)
    end

    def remove_mdns_service(id) do
      Agent.update(__MODULE__, fn s -> %{s | calls: [{:remove, id} | s.calls]} end)
      :ok
    end

    def announce_all do
      Agent.update(__MODULE__, fn s -> %{s | calls: [:announce_all | s.calls]} end)
      :ok
    end

    def goodbye_service(id) do
      Agent.update(__MODULE__, fn s -> %{s | calls: [{:goodbye, id} | s.calls]} end)
      :ok
    end

    def calls, do: Agent.get(__MODULE__, & &1.calls) |> Enum.reverse()
  end

  setup do
    start_supervised!(MdnsStub)
    :ok = Phoenix.PubSub.subscribe(@pubsub, "sendspin:state")
    :ok
  end

  defp config do
    %{
      friendly_name: "Headphones",
      enabled: true,
      client_id: "deadbeef",
      volume: 60,
      muted: false,
      alsa_device: "plughw:0,0",
      card_index: 0,
      card_name: "bcm2835 Headphones"
    }
  end

  defp start_player!(overrides \\ []) do
    opts =
      Keyword.merge(
        [
          key: @key,
          config: config(),
          mdns_port: 18_928,
          binary_path: @fake_binary,
          mdns_module: MdnsStub,
          # Default to no re-announces in existing tests; the dedicated
          # describe block opts back in. Otherwise every test would
          # schedule timers that fire after the test process exits.
          reannounce_delays_ms: [],
          # Default to no device suffix so instance-name assertions are
          # deterministic regardless of whether ConfigStore is running;
          # the dedicated test opts a real node name back in.
          device_name_fun: fn -> nil end
        ],
        overrides
      )

    start_supervised!({Player, opts})
  end

  describe "startup" do
    # `started` event shape is documented in
    # `c_src/sendspin_player/README.md` ("Stdout events"). The fake
    # binary mirrors that shape exactly so this test would catch a
    # drift in either direction. `client_id` is passed to the binary
    # as a CLI arg + advertised in mDNS TXT but is NOT echoed back on
    # `started`; `initial_volume` is reported via a separate `volume`
    # event right after `started`.
    test "spawns the binary and forwards CLI args via the `started` event" do
      pid = start_player!()

      assert_receive {:sendspin_state, @key, event}, 2_000
      assert event.event == "started"
      assert event.name == "Headphones"
      assert event.port == 18_928
      assert event.alsa_device == "plughw:0,0"
      assert is_binary(event.version)

      # Real binary emits `volume` immediately after `started` to
      # publish the initial volume; the fake mirrors that.
      assert_receive {:sendspin_state, @key, %{event: "volume", value: 60}}, 1_000

      assert Process.alive?(pid)
    end

    test "forwards the persisted static delay via --initial-static-delay-ms" do
      _pid = start_player!(config: Map.put(config(), :static_delay_ms, 250))
      assert_receive {:sendspin_state, @key, _started}, 2_000
      # The binary echoes the static delay it was launched with — proving the
      # CLI arg flowed through and round-trips back for persistence.
      assert_receive {:sendspin_state, @key, %{event: "static_delay", value: 250}}, 1_000
    end

    test "registers an mDNS service once the binary reports `listening`" do
      _pid = start_player!()

      # Registration is gated on the binary's `listening` event (the
      # WebSocket listener is bound) — advertising earlier would race
      # Music Assistant's one-shot discovery connect against the
      # spawn-to-bind gap. `register_mdns/1` runs in the same
      # handle_info before the event is broadcast, so once we receive
      # `listening` the Agent has recorded the add. No sleep needed.
      assert_receive {:sendspin_state, @key, %{event: "listening"}}, 2_000

      [{kind, service}] = MdnsStub.calls()
      assert kind == :add
      assert service.id == {:sendspin_player, "bcm2835 Headphones", nil, nil}
      assert service.protocol == "sendspin"
      assert service.transport == "tcp"
      assert service.port == 18_928
      assert "name=Headphones" in service.txt_payload
      assert "client_id=deadbeef" in service.txt_payload
      # instance_name = friendly_name (sanitized) so each output gets
      # its own mDNS instance instead of colliding on the host's
      # default. Renames produce a clean Removed/Added cycle on peer
      # caches like avahi.
      assert service.instance_name == "Headphones"
    end

    test "does NOT register mDNS while `listening` has not arrived" do
      # Simulates a binary whose WebSocket listener never comes up
      # (bind failure, wedged startup). Advertising such a player
      # would hand Music Assistant a guaranteed connection-refused —
      # and MA's discovery connect is one-shot, so that orphans the
      # player. The fake suppresses `listening` via env.
      System.put_env("FAKE_SKIP_LISTENING", "1")
      on_exit(fn -> System.delete_env("FAKE_SKIP_LISTENING") end)

      _pid = start_player!()

      # All startup events through static_delay arrive...
      assert_receive {:sendspin_state, @key, %{event: "started"}}, 2_000
      assert_receive {:sendspin_state, @key, %{event: "static_delay"}}, 1_000

      # ...but with no `listening`, no advertisement may happen.
      Process.sleep(50)
      refute Enum.any?(MdnsStub.calls(), &match?({:add, _}, &1))
    end

    test "retries mDNS registration when MdnsLite is unavailable at `listening`" do
      # `listening` is a one-shot signal from the binary; if MdnsLite's
      # TableServer happens to be down at that instant, registration
      # must be retried or the player stays unadvertised for the
      # binary's whole lifetime.
      MdnsStub.fail_next_adds(1)
      _pid = start_player!(mdns_retry_ms: 25, reannounce_delays_ms: [1])

      assert_receive {:sendspin_state, @key, %{event: "listening"}}, 2_000

      # First attempt fails, the scheduled retry succeeds, and the
      # reannounce burst fires only after the successful registration.
      eventually(
        fn ->
          calls = MdnsStub.calls()

          Enum.any?(calls, &match?({:add_failed, _}, &1)) and
            Enum.any?(calls, &match?({:add, _}, &1)) and
            :announce_all in calls
        end,
        1_000
      )

      calls = MdnsStub.calls()
      add_idx = Enum.find_index(calls, &match?({:add, _}, &1))
      announce_idx = Enum.find_index(calls, &(&1 == :announce_all))
      assert add_idx < announce_idx, "reannounce burst must follow successful registration"
    end

    test "warns when the binary never reports `listening`" do
      # A player in this state runs fine but is invisible to Sendspin
      # servers; the watchdog is the only breadcrumb saying why.
      System.put_env("FAKE_SKIP_LISTENING", "1")
      on_exit(fn -> System.delete_env("FAKE_SKIP_LISTENING") end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          _pid = start_player!(mdns_watchdog_ms: 50)
          assert_receive {:sendspin_state, @key, %{event: "static_delay"}}, 2_000
          Process.sleep(120)
        end)

      assert log =~ "never reported `listening`"
    end

    test "mDNS instance_name truncates by BYTES, not graphemes" do
      # DNS labels are limited to 63 bytes on the wire (RFC 1035
      # §2.3.4). A friendly name full of multi-byte UTF-8 codepoints
      # (e.g. CJK characters at 3 bytes each, emoji at 4) can exceed
      # the byte budget even when its grapheme/codepoint count is
      # well below 63. We truncate at codepoint boundaries so the
      # resulting string is valid UTF-8 AND ≤ 63 bytes.
      #
      # 30 × 3-byte chars = 90 bytes. After byte-truncation we expect
      # at most 21 chars (21 × 3 = 63) and byte_size ≤ 63.
      long_name = String.duplicate("漢", 30)
      assert byte_size(long_name) == 90

      _pid =
        start_player!(
          config: Map.put(config(), :friendly_name, long_name),
          mdns_port: 18_900
        )

      assert_receive {:sendspin_state, @key, %{event: "listening"}}, 2_000

      [{:add, service}] = MdnsStub.calls()
      assert byte_size(service.instance_name) <= 63
      assert String.valid?(service.instance_name)
      # The first 21 chars of the original are what fits — verify we
      # kept the prefix rather than mangling the boundary.
      assert String.starts_with?(long_name, service.instance_name)
    end

    test "mDNS instance_name falls back to a placeholder when blank" do
      # All-whitespace / all-control-chars / empty name after clean-up
      # would produce a zero-byte DNS label, which mdns_lite rejects.
      # We substitute "sendspin" instead.
      _pid =
        start_player!(
          config: Map.put(config(), :friendly_name, "   \t\r\n  "),
          mdns_port: 18_901
        )

      assert_receive {:sendspin_state, @key, %{event: "listening"}}, 2_000

      [{:add, service}] = MdnsStub.calls()
      assert service.instance_name == "sendspin"
    end

    test "mDNS instance_name carries the device node name so devices are distinguishable" do
      _pid = start_player!(device_name_fun: fn -> "universal-proxy-45099b" end, mdns_port: 18_902)

      assert_receive {:sendspin_state, @key, %{event: "listening"}}, 2_000

      [{:add, service}] = MdnsStub.calls()
      assert service.instance_name == "Headphones (universal-proxy-45099b)"
      # TXT `name` matches the instance so MA shows the same identifier.
      assert "name=Headphones (universal-proxy-45099b)" in service.txt_payload
    end
  end

  describe "sendspin_instance_name/2" do
    test "appends the node name as a suffix" do
      assert Player.sendspin_instance_name("bcm2835 Headphones", "universal-proxy-45099b") ==
               "bcm2835 Headphones (universal-proxy-45099b)"
    end

    test "no node name → bare sanitized output name" do
      assert Player.sendspin_instance_name("bcm2835 Headphones", nil) == "bcm2835 Headphones"
      assert Player.sendspin_instance_name("bcm2835 Headphones", "") == "bcm2835 Headphones"
    end

    test "preserves the device suffix within the 63-byte budget by truncating the output" do
      node = "universal-proxy-45099b"
      long = String.duplicate("漢", 40)

      name = Player.sendspin_instance_name(long, node)

      assert byte_size(name) <= 63
      assert String.valid?(name)
      # The identifying suffix always survives — that's the whole point.
      assert String.ends_with?(name, " (#{node})")
    end

    test "blank output name with a node still yields a valid label" do
      assert Player.sendspin_instance_name("  \t ", "node-x") == "sendspin (node-x)"
    end

    test "refuses to start when the binary is missing" do
      # `trap_exit` so `start_link/1` reports `{:error, _}` to the
      # caller (this test process) instead of propagating an `:EXIT`
      # signal that would kill us. ExUnit runs each test in its own
      # process and the flag dies with that process; no cleanup
      # needed.
      Process.flag(:trap_exit, true)

      assert {:error, {:binary_missing, "/tmp/nope"}} =
               Player.start_link(
                 key: @key,
                 config: config(),
                 mdns_port: 18_999,
                 binary_path: "/tmp/nope",
                 mdns_module: MdnsStub
               )
    end
  end

  describe "set_volume/2" do
    test "writes JSON to stdin and the fake echoes back via PubSub" do
      pid = start_player!()
      assert_receive {:sendspin_state, @key, %{event: "started"}}, 2_000

      :ok = Player.set_volume(pid, 80)
      assert_receive {:sendspin_state, @key, %{event: "volume", value: 80}}, 1_000

      :ok = Player.set_volume(pid, 5)
      assert_receive {:sendspin_state, @key, %{event: "volume", value: 5}}, 1_000
    end

    # The C++ binary's stdin parser is a strict left-to-right scanner —
    # `Jason.encode!/1` on a map iterates in unstable hash order, so
    # naively encoding `%{cmd: ..., value: ...}` emits `value` first
    # roughly half the time, and the binary silently drops the command.
    # Lock the literal wire bytes so a regression here is caught
    # without needing a real-binary integration test.
    test "produces deterministic field order `{\"cmd\":...,\"value\":...}`" do
      # Spawn a recording fake whose only job is to capture the raw
      # bytes received on stdin, then assert the exact sequence.
      tmp_dir = System.tmp_dir!()
      uniq = System.unique_integer([:positive])
      tmp = Path.join(tmp_dir, "player_test_stdin_#{uniq}.log")
      recorder = Path.join(tmp_dir, "player_test_stdin_recorder_#{uniq}.sh")

      on_exit(fn ->
        File.rm(tmp)
        File.rm(recorder)
      end)

      File.write!(recorder, """
      #!/bin/sh
      echo '{"event":"started","version":"0.0.0-fake","port":19001,"name":"x","alsa_device":"x"}'
      cat > "#{tmp}"
      """)

      File.chmod!(recorder, 0o755)

      pid = start_player!(binary_path: recorder, mdns_port: 19_001)
      assert_receive {:sendspin_state, @key, %{event: "started"}}, 2_000

      :ok = Player.set_volume(pid, 80)
      :ok = Player.set_muted(pid, true)

      # GenServer.stop sends shutdown JSON then closes the port,
      # which flushes our recorder's `cat` to disk.
      :ok = GenServer.stop(pid, :normal, 2_000)

      lines = tmp |> File.read!() |> String.split("\n", trim: true)

      assert ~s({"cmd":"set_volume","value":80}) in lines
      assert ~s({"cmd":"set_muted","value":true}) in lines
      assert ~s({"cmd":"shutdown"}) in lines
    end
  end

  describe "set_muted/2" do
    test "writes JSON to stdin and the fake echoes back via PubSub" do
      pid = start_player!()
      assert_receive {:sendspin_state, @key, %{event: "started"}}, 2_000

      :ok = Player.set_muted(pid, true)
      assert_receive {:sendspin_state, @key, %{event: "mute", value: true}}, 1_000

      :ok = Player.set_muted(pid, false)
      assert_receive {:sendspin_state, @key, %{event: "mute", value: false}}, 1_000
    end

    test "applies persisted :muted state on player start via stdin" do
      # `build_cli_args/1` only passes `--initial-volume`; there's no
      # `--initial-muted`. If DETS says the output is muted, Player
      # must send a `set_muted true` over stdin right after the port
      # is open so the binary's default (unmuted) doesn't briefly
      # play before BEAM corrects it. Without this fix a muted output
      # comes back unmuted after reboot/respawn.
      muted_config = Map.put(config(), :muted, true)
      _pid = start_player!(config: muted_config)

      # `started` event + initial-volume event + our follow-up mute
      # event. assert_receive selectively matches the mute event in
      # the mailbox.
      assert_receive {:sendspin_state, @key, %{event: "mute", value: true}}, 2_000
    end
  end

  describe "termination" do
    test "sends shutdown command and removes the mDNS service" do
      pid = start_player!()
      # Sync on `listening` (not just `started`) so the teardown under
      # test is deterministically the registered-record path — port
      # messages and the stop request come from different senders, so
      # BEAM gives no cross-sender ordering guarantee.
      assert_receive {:sendspin_state, @key, %{event: "listening"}}, 2_000

      :ok = GenServer.stop(pid, :normal, 2_000)
      refute Process.alive?(pid)

      calls = MdnsStub.calls()
      assert {:remove, {:sendspin_player, "bcm2835 Headphones", nil, nil}} in calls
    end

    test "sends a TTL=0 goodbye BEFORE removing the mDNS service" do
      # Without this ordering, peer caches (python-zeroconf, avahi) hold
      # our records for their full mDNS TTL even after we yank the
      # service from the responder table — and a later announce of the
      # same instance is treated as a cache refresh, not a re-discovery.
      # Caught when Music Assistant refused to reconnect on re-enable
      # because its python-zeroconf hadn't seen a Removed event.
      pid = start_player!()
      # Sync on `listening` (not just `started`) so the teardown under
      # test is deterministically the registered-record path — port
      # messages and the stop request come from different senders, so
      # BEAM gives no cross-sender ordering guarantee.
      assert_receive {:sendspin_state, @key, %{event: "listening"}}, 2_000

      :ok = GenServer.stop(pid, :normal, 2_000)

      id = {:sendspin_player, "bcm2835 Headphones", nil, nil}
      calls = MdnsStub.calls()

      goodbye_idx = Enum.find_index(calls, &match?({:goodbye, ^id}, &1))
      remove_idx = Enum.find_index(calls, &match?({:remove, ^id}, &1))

      assert goodbye_idx != nil, "expected MdnsStub.goodbye_service/1 to be called"
      assert remove_idx != nil, "expected MdnsStub.remove_mdns_service/1 to be called"
      assert goodbye_idx < remove_idx, "goodbye must come before remove, got #{inspect(calls)}"
    end
  end

  describe "binary unexpected exit" do
    test "Player stops with {:binary_exited, status} when the binary exits abnormally" do
      # `trap_exit` so the test process can observe `:DOWN` instead of
      # being killed by the player's EXIT signal. ExUnit gives each
      # test its own process, so the flag dies with this test — no
      # cleanup needed.
      Process.flag(:trap_exit, true)

      pid = start_player!()
      assert_receive {:sendspin_state, @key, %{event: "started"}}, 2_000

      ref = Process.monitor(pid)
      :ok = Player.__send_command__(pid, %{cmd: "force_exit"})

      # The fake exits with status 7 → Player's handle_info({:exit_status, 7})
      # returns {:stop, {:binary_exited, 7}, state} → DOWN delivers.
      assert_receive {:DOWN, ^ref, :process, ^pid, {:binary_exited, 7}}, 2_000

      # MdnsLite remove must still run from terminate/2 — supervised
      # cleanup must not skip on abnormal exit.
      assert {:remove, {:sendspin_player, "bcm2835 Headphones", nil, nil}} in MdnsStub.calls()
    end
  end

  describe "JSON atom contract" do
    test "stream_start events round-trip through Jason.decode" do
      # The binary emits `stream_start` with `sample_rate`/`channels`/
      # `bit_depth`/`codec` — keys that may not exist as atoms at the
      # time decode runs. We use `keys: :atoms` (NOT `:atoms!`) so
      # Jason interns them on the fly. The binary's emit_json call
      # sites in main.cpp define a closed key set, so unbounded atom
      # growth is not a concern. Caught when an earlier attempt with
      # `:atoms!` + a module-attribute "interning" trick failed at
      # runtime because dead-code elimination dropped the literal.
      tmp_dir = System.tmp_dir!()

      stream_fake =
        Path.join(tmp_dir, "player_stream_start_fake_#{System.unique_integer([:positive])}.sh")

      on_exit(fn -> File.rm(stream_fake) end)

      File.write!(stream_fake, """
      #!/bin/sh
      echo '{"event":"started","version":"0.0.0-fake","port":19100,"name":"x","alsa_device":"x"}'
      echo '{"event":"stream_start","sample_rate":44100,"channels":2,"bit_depth":16,"codec":"flac"}'
      # Keep the process alive so terminate/2 runs the shutdown handshake.
      exec cat
      """)

      File.chmod!(stream_fake, 0o755)

      pid = start_player!(binary_path: stream_fake, mdns_port: 19_100)

      # Drain the `started` event, then wait for `stream_start`.
      assert_receive {:sendspin_state, @key, %{event: "started"}}, 2_000

      assert_receive {:sendspin_state, @key,
                      %{
                        event: "stream_start",
                        sample_rate: 44_100,
                        channels: 2,
                        bit_depth: 16,
                        codec: "flac"
                      }},
                     1_000

      # And the cache must hold the latest parsed event.
      assert %{event: "stream_start", codec: "flac"} = Player.last_event(pid)
    end
  end

  describe "last_event/1" do
    test "caches the most recent event for late subscribers" do
      pid = start_player!()
      assert_receive {:sendspin_state, @key, _started}, 1_000

      :ok = Player.set_volume(pid, 33)
      assert_receive {:sendspin_state, @key, %{event: "volume", value: 33}}, 1_000

      assert %{event: "volume", value: 33} = Player.last_event(pid)
    end
  end

  describe "RFC 6762 §8.3 re-announce schedule" do
    # User-visible regression: re-enabling an output didn't notify
    # Music Assistant until MA's next polling cycle (30-60+ s). Player
    # schedules `MdnsLite.announce_all/0` (vendored fork only — upstream
    # 0.9.1 doesn't have it) a few times right after the responder
    # registers our service so peer caches update immediately.
    test "fires the configured re-announce schedule via mdns_module.announce_all" do
      _pid = start_player!(reannounce_delays_ms: [10, 25, 50])

      assert_receive {:sendspin_state, @key, _started}, 2_000

      # Three announce_all calls should land within ~250 ms of the
      # schedule (50 ms last delay + generous slack for slow CI).
      eventually(
        fn -> Enum.count(MdnsStub.calls(), &(&1 == :announce_all)) == 3 end,
        1_000
      )
    end

    test "an empty schedule fires no announces" do
      _pid = start_player!()
      assert_receive {:sendspin_state, @key, _started}, 2_000

      # Default `reannounce_delays_ms: []` in `start_player!/1` means
      # MdnsStub.announce_all should never be called.
      Process.sleep(50)
      refute Enum.any?(MdnsStub.calls(), &(&1 == :announce_all))
    end
  end

  # Poll a predicate every 10 ms until it returns true or the timeout
  # elapses. Used in lieu of a fixed `Process.sleep` so the test
  # finishes as soon as the scheduled timers have fired, not after a
  # worst-case sleep.
  defp eventually(check, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    loop = fn loop ->
      cond do
        check.() ->
          :ok

        System.monotonic_time(:millisecond) >= deadline ->
          flunk("eventually/2 timed out after #{timeout_ms} ms")

        true ->
          Process.sleep(10)
          loop.(loop)
      end
    end

    loop.(loop)
  end
end
