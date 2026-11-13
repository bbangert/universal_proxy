defmodule UniversalProxy.Audio.PlayerTest do
  # async: false — the suite shares a named `MdnsStub` Agent across
  # tests, and each test subscribes to the global `sendspin:state`
  # PubSub topic to observe Player's broadcasts. Two tests running
  # concurrently would tangle each other's mDNS calls and crossed
  # PubSub messages.
  use ExUnit.Case, async: false

  alias UniversalProxy.Audio.Player
  alias UniversalProxy.Display.Progress

  @pubsub UniversalProxy.PubSub
  @fake_binary Path.expand("../../support/fake_sendspin_player.py", __DIR__)
  @key {"bcm2835 Headphones", nil, nil}
  # The id `fake_sendspin_player.py` reports on `listening`, standing in
  # for the one the real binary derives from its keypair.
  @fake_client_id "ZmFrZS1zZW5kc3Bpbi1wbGF5ZXItaWQtMzJieXRlcyE"

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
          device_name_fun: fn -> nil end,
          # Same determinism story for the device_info MAC.
          mac_address_fun: fn -> nil end
        ],
        overrides
      )

    start_supervised!({Player, opts})
  end

  # Minimal state for `Player.__cli_args__/1` arg-level assertions —
  # flags like --mac never appear in stdout events, so they can't be
  # asserted through the fake's echo.
  defp cli_state(overrides) do
    struct!(
      %Player{
        key: @key,
        config: config(),
        binary_path: @fake_binary,
        mdns_port: 18_928,
        device_name_fun: fn -> nil end,
        mac_address_fun: fn -> nil end,
        state_dir: "/tmp/sendspin-player-test/deadbeef"
      },
      overrides
    )
  end

  defp mac_pair(args) do
    case Enum.drop_while(args, &(&1 != "--mac")) do
      ["--mac", mac | _] -> ["--mac", mac]
      [] -> nil
    end
  end

  describe "startup" do
    # `started` event shape is documented in
    # `c_src/sendspin_player/README.md` ("Stdout events"). The fake
    # binary mirrors that shape exactly so this test would catch a
    # drift in either direction. The Sendspin `client_id` is reported by
    # the binary on `listening` (derived from its `--state-dir` keypair)
    # and advertised in mDNS TXT, NOT echoed on `started`;
    # `initial_volume` is reported via a separate `volume` event right
    # after `started`.
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

    test "passes the node name as --product for the Vendor / Product identity" do
      # Sendspin servers (Music Assistant) show device_info as
      # "Vendor / Product"; the vendor is fixed to "Universal Proxy" in
      # the binary and the product carries the per-device node name.
      _pid = start_player!(device_name_fun: fn -> "universal-proxy-45099b" end, mdns_port: 18_903)

      assert_receive {:sendspin_state, @key,
                      %{event: "started", product: "universal-proxy-45099b"}},
                     2_000
    end

    test "omits --product without a node name so the binary default applies" do
      _pid = start_player!()

      assert_receive {:sendspin_state, @key, %{event: "started", product: "sendspin_player"}},
                     2_000
    end

    test "passes --mac downcased and starts normally with a MAC configured" do
      # Process-level: the real binary accepts --mac (fake mirrors the
      # arg surface), and args carry the normalized persisted MAC.
      _pid = start_player!(mac_address_fun: fn -> "B8:27:EB:07:50:7F" end, mdns_port: 18_904)
      assert_receive {:sendspin_state, @key, %{event: "started"}}, 2_000

      args = Player.__cli_args__(cli_state(mac_address_fun: fn -> "B8:27:EB:07:50:7F" end))
      assert ["--mac", "b8:27:eb:07:50:7f"] = mac_pair(args)

      # Hand-entered Settings overrides persist verbatim — stray
      # whitespace must normalize away, not silently disable the flag.
      args = Player.__cli_args__(cli_state(mac_address_fun: fn -> " B8:27:EB:07:50:7F\n" end))
      assert ["--mac", "b8:27:eb:07:50:7f"] = mac_pair(args)
    end

    test "omits --mac on zeros sentinel, malformed value, or a crashing fun" do
      # Degraded path (decision: quiet omit, binary auto-detects — never
      # block audio on cosmetic metadata). Zeros = espex "no interface";
      # malformed = user-edited Settings value; raise/exit = ConfigStore
      # down (the catch :exit optional-subsystem idiom).
      for fun <- [
            fn -> "00:00:00:00:00:00" end,
            fn -> "not-a-mac" end,
            fn -> "b8:27:eb:07:50" end,
            fn -> nil end,
            fn -> raise "boom" end,
            fn -> exit(:noproc) end
          ] do
        args = Player.__cli_args__(cli_state(mac_address_fun: fun))
        assert mac_pair(args) == nil
      end
    end

    test "passes a per-output --state-dir named by the Store's client_id" do
      pid = start_player!()
      assert_receive {:sendspin_state, @key, %{event: "started"}}, 2_000

      state = :sys.get_state(pid)
      assert Path.basename(state.state_dir) == "deadbeef"
      assert Path.basename(Path.dirname(state.state_dir)) == "sendspin_players"

      assert ["--state-dir", dir | _] =
               Enum.drop_while(Player.__cli_args__(state), &(&1 != "--state-dir"))

      assert dir == state.state_dir
      refute "--client-id" in Player.__cli_args__(state)
    end

    @tag :tmp_dir
    test "the pairing token lands in the state dir, never on PubSub", %{tmp_dir: tmp_dir} do
      _pid = start_player!(state_dir: tmp_dir)
      assert_receive {:sendspin_state, @key, %{event: "listening"}}, 2_000

      assert {:ok, "SP:0" <> _ = token} = UniversalProxy.Audio.PairingToken.read(tmp_dir)

      {:messages, messages} = Process.info(self(), :messages)
      refute inspect(messages, limit: :infinity, printable_limit: :infinity) =~ token
    end

    test "hashes a Store client_id that is not a safe directory name" do
      # Only `generate_client_id/0` writes the field today; this guards a
      # corrupted DETS row from turning into a path outside the base dir.
      pid = start_player!(config: Map.put(config(), :client_id, "../../etc"))
      assert_receive {:sendspin_state, @key, %{event: "started"}}, 2_000

      state_dir = :sys.get_state(pid).state_dir
      assert Path.basename(state_dir) =~ ~r/\A[0-9a-f]{64}\z/
      assert Path.basename(Path.dirname(state_dir)) == "sendspin_players"
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
      # The id the binary reported, never the Store's state-dir token.
      assert "client_id=#{@fake_client_id}" in service.txt_payload
      refute "client_id=deadbeef" in service.txt_payload
      # instance_name = friendly_name (sanitized) so each output gets
      # its own mDNS instance instead of colliding on the host's
      # default. Renames produce a clean Removed/Added cycle on peer
      # caches like avahi.
      assert service.instance_name == "Headphones"
    end

    test "omits the TXT client_id when `listening` carries none" do
      # The entry is a non-spec extra; advertising a guessed id would
      # disagree with the one the player presents in client/hello.
      System.put_env("FAKE_OMIT_CLIENT_ID", "1")
      on_exit(fn -> System.delete_env("FAKE_OMIT_CLIENT_ID") end)

      _pid = start_player!()
      assert_receive {:sendspin_state, @key, %{event: "listening"}}, 2_000

      [{:add, service}] = MdnsStub.calls()
      assert "path=/sendspin" in service.txt_payload
      refute Enum.any?(service.txt_payload, &String.starts_with?(&1, "client_id="))
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

    test "refuses mDNS registration when the bound port differs from the requested one" do
      # The `listening` event reports the port the binary ACTUALLY
      # bound. If it ever diverges from the one we were going to
      # advertise, registering would hand MA's one-shot discovery
      # connect a dead port — refuse loudly instead. The fake reports
      # a foreign port via env.
      System.put_env("FAKE_LISTENING_PORT", "8928")
      on_exit(fn -> System.delete_env("FAKE_LISTENING_PORT") end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          # Short watchdog so we can also assert it stays SILENT after a
          # refusal — `listening` did arrive, so its "never reported"
          # warning would be false.
          _pid = start_player!(mdns_watchdog_ms: 50)

          # `maybe_register_mdns` runs in the same handle_info before
          # the event is broadcast, so receiving `listening` proves the
          # refusal path already executed.
          assert_receive {:sendspin_state, @key, %{event: "listening", port: 8928}}, 2_000
          Process.sleep(120)
        end)

      assert log =~ "refusing mDNS registration"
      refute log =~ "never reported `listening`"
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

      # The retry runs from a timer, long after the `listening` event;
      # it must still advertise the id that event carried.
      {:add, service} = Enum.at(calls, add_idx)
      assert "client_id=#{@fake_client_id}" in service.txt_payload
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

    test "blank output name with a node too long for the placeholder drops the node" do
      # suffix = " (" <> 54 bytes <> ")" = 57 bytes, which would push the
      # 8-byte "sendspin" placeholder to 65 bytes — must fall back to the
      # bare placeholder instead of exceeding the 63-byte mDNS label limit.
      node = String.duplicate("n", 54)

      name = Player.sendspin_instance_name("  \t ", node)

      assert byte_size(name) <= 63
      assert name == "sendspin"
    end

    test "blank output name with a node right at the placeholder boundary keeps the node" do
      # suffix = " (" <> 52 bytes <> ")" = 55 bytes; "sendspin" <> suffix
      # is exactly 63 bytes — the placeholder path still fits here.
      node = String.duplicate("n", 52)

      name = Player.sendspin_instance_name("  \t ", node)

      assert byte_size(name) == 63
      assert name == "sendspin (#{node})"
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

  describe "sendspin_instance_name/3 with :source role" do
    test "appends the ' In' marker ahead of the node suffix" do
      assert Player.sendspin_instance_name("BTD 700 (1-1.3.1)", "universal-proxy-07507f", :source) ==
               "BTD 700 (1-1.3.1) In (universal-proxy-07507f)"
    end

    test "differs from the :player result for identical inputs" do
      friendly = "BTD 700 (1-1.3.1)"
      node = "universal-proxy-07507f"

      refute Player.sendspin_instance_name(friendly, node, :source) ==
               Player.sendspin_instance_name(friendly, node, :player)
    end

    test "the ' In' marker survives truncation of a long friendly name" do
      node = "universal-proxy-45099b"
      # 80+ bytes, includes multi-byte UTF-8 so byte-vs-codepoint truncation
      # bugs would show up here.
      long = String.duplicate("漢", 40)

      name = Player.sendspin_instance_name(long, node, :source)

      assert byte_size(name) <= 63
      assert String.valid?(name)
      # The role marker is the whole point — it must never be truncated away.
      assert String.ends_with?(name, " In (#{node})")
    end

    test "no node name → bare output name with the ' In' marker" do
      assert Player.sendspin_instance_name("bcm2835 Headphones", nil, :source) ==
               "bcm2835 Headphones In"

      assert Player.sendspin_instance_name("bcm2835 Headphones", "", :source) ==
               "bcm2835 Headphones In"
    end

    test "blank friendly name with a node still yields a valid marked label" do
      assert Player.sendspin_instance_name("  \t ", "node-x", :source) == "sendspin In (node-x)"
    end

    test "pathologically long node name drops the node but keeps the marker" do
      node = String.duplicate("n", 100)

      name = Player.sendspin_instance_name("BTD 700 (1-1.3.1)", node, :source)

      assert byte_size(name) <= 63
      assert String.valid?(name)
      assert String.ends_with?(name, " In")
      assert String.starts_with?(name, "BTD 700 (1-1.3.1)")
    end

    test "blank friendly name with a node too long for the placeholder drops the node, keeps the marker" do
      # suffix = " In (" <> 50 bytes <> ")" = 56 bytes, which would push
      # the 8-byte "sendspin" placeholder to 64 bytes — must fall back to
      # sanitize_instance_name/2 (placeholder + role marker only) instead.
      node = String.duplicate("n", 50)

      name = Player.sendspin_instance_name("   ", node, :source)

      assert byte_size(name) <= 63
      assert name == "sendspin In"
    end

    test "boundary collision: no node, friendly name truncates with ' In' at the cut" do
      # 60 "a"s + " In" is exactly 63 bytes, so :player's untruncated
      # composition and :source's truncate-then-append-" In" composition
      # land on the identical 63-byte string unless the collision dodge
      # kicks in.
      friendly = String.duplicate("a", 60) <> " In"

      player = Player.sendspin_instance_name(friendly, nil, :player)
      source = Player.sendspin_instance_name(friendly, nil, :source)

      refute source == player
      assert byte_size(player) <= 63
      assert byte_size(source) <= 63
      assert String.valid?(source)
      assert String.ends_with?(source, " In")
    end

    test "boundary collision: with node, friendly name truncates with ' In' at the cut" do
      node = "universal-proxy-07507f"
      friendly = String.duplicate("a", 35) <> " In" <> String.duplicate("b", 20)

      player = Player.sendspin_instance_name(friendly, node, :player)
      source = Player.sendspin_instance_name(friendly, node, :source)

      refute source == player
      assert byte_size(source) <= 63
      assert String.ends_with?(source, " In (#{node})")
    end

    test "boundary collision is deterministic across repeated calls" do
      node = "universal-proxy-07507f"
      friendly = String.duplicate("a", 35) <> " In" <> String.duplicate("b", 20)

      assert Player.sendspin_instance_name(friendly, node, :source) ==
               Player.sendspin_instance_name(friendly, node, :source)
    end

    test "boundary collision with multi-byte codepoints stays valid UTF-8 and distinct" do
      # 20 "漢" (3 bytes each) + " In" is exactly 63 bytes — same boundary
      # shape as the ASCII case above, but exercises codepoint-respecting
      # truncation on the shrink path.
      friendly = String.duplicate("漢", 20) <> " In"

      player = Player.sendspin_instance_name(friendly, nil, :player)
      source = Player.sendspin_instance_name(friendly, nil, :source)

      refute source == player
      assert byte_size(source) <= 63
      assert String.valid?(source)
      assert String.ends_with?(source, " In")
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
      :ok = Player.set_volume_external(pid, true)

      # GenServer.stop sends shutdown JSON then closes the port,
      # which flushes our recorder's `cat` to disk.
      :ok = GenServer.stop(pid, :normal, 2_000)

      lines = tmp |> File.read!() |> String.split("\n", trim: true)

      assert ~s({"cmd":"set_volume","value":80}) in lines
      assert ~s({"cmd":"set_muted","value":true}) in lines
      assert ~s({"cmd":"set_volume_external","value":true}) in lines
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
      assert_receive {:sendspin_state, @key, %{event: "mute", value: true, startup: true}},
                     2_000
    end

    test "tags the startup snapshot (initial volume, startup mute echo), and nothing after" do
      pid = start_player!(config: Map.put(config(), :muted, true))

      assert_receive {:sendspin_state, @key, %{event: "volume", value: 60, startup: true}},
                     2_000

      assert_receive {:sendspin_state, @key, %{event: "mute", value: true, startup: true}},
                     1_000

      :ok = Player.set_volume(pid, 60)
      assert_receive {:sendspin_state, @key, %{event: "volume", value: 60} = volume}, 1_000
      refute Map.has_key?(volume, :startup)
      # Every volume/mute event names the player process it came from.
      assert volume.player == pid

      :ok = Player.set_muted(pid, true)
      assert_receive {:sendspin_state, @key, %{event: "mute", value: true} = mute}, 1_000
      refute Map.has_key?(mute, :startup)
    end

    test "without a startup mute, the first mute event is not a snapshot" do
      pid = start_player!()
      assert_receive {:sendspin_state, @key, %{event: "volume", startup: true}}, 2_000

      :ok = Player.set_muted(pid, true)
      assert_receive {:sendspin_state, @key, %{event: "mute", value: true} = mute}, 1_000
      refute Map.has_key?(mute, :startup)
    end
  end

  describe "set_volume_external/2" do
    test "writes JSON to stdin and the binary's ack is broadcast" do
      pid = start_player!()
      assert_receive {:sendspin_state, @key, %{event: "started"}}, 2_000

      :ok = Player.set_volume_external(pid, true)
      assert_receive {:sendspin_state, @key, %{event: "volume_external", value: true}}, 1_000
      assert :sys.get_state(pid).volume_external

      :ok = Player.set_volume_external(pid, false)
      assert_receive {:sendspin_state, @key, %{event: "volume_external", value: false}}, 1_000
      refute :sys.get_state(pid).volume_external
    end

    test "state follows the binary's ack even when the setter was not called" do
      pid = start_player!()
      assert_receive {:sendspin_state, @key, %{event: "started"}}, 2_000
      refute :sys.get_state(pid).volume_external

      # Bypasses set_volume_external/2, so only the ack can update the state.
      :ok = Player.__send_command__(pid, %{cmd: "set_volume_external", value: true})
      assert_receive {:sendspin_state, @key, %{event: "volume_external", value: true}}, 1_000
      assert :sys.get_state(pid).volume_external

      :ok = Player.__send_command__(pid, %{cmd: "set_volume_external", value: false})
      assert_receive {:sendspin_state, @key, %{event: "volume_external", value: false}}, 1_000
      refute :sys.get_state(pid).volume_external
    end

    test "volume and mute are still reported while external" do
      pid = start_player!()
      assert_receive {:sendspin_state, @key, %{event: "started"}}, 2_000

      :ok = Player.set_volume_external(pid, true)
      assert_receive {:sendspin_state, @key, %{event: "volume_external", value: true}}, 1_000

      :ok = Player.set_volume(pid, 35)
      :ok = Player.set_muted(pid, true)
      assert_receive {:sendspin_state, @key, %{event: "volume", value: 35}}, 1_000
      assert_receive {:sendspin_state, @key, %{event: "mute", value: true}}, 1_000
    end

    test "the tap goes off when its owner is killed" do
      pid = start_player!(pcm_tap_path: "/run/up-pcm-test")
      assert_receive {:sendspin_state, @key, %{event: "started"}}, 2_000
      owner = spawn(fn -> Process.sleep(:infinity) end)

      :ok = Player.pcm_tap(pid, true, owner)
      assert_receive {:sendspin_state, @key, %{event: "pcm_tap", value: true}}, 1_000

      Process.exit(owner, :kill)
      assert_receive {:sendspin_state, @key, %{event: "pcm_tap", value: false}}, 1_000
      assert %{enabled: false} = Player.pcm_tap_status(pid)
      assert :sys.get_state(pid).pcm_tap_lease == nil
    end

    test "an enable from a new owner replaces the lease" do
      pid = start_player!(pcm_tap_path: "/run/up-pcm-test")
      assert_receive {:sendspin_state, @key, %{event: "started"}}, 2_000
      old = spawn(fn -> Process.sleep(:infinity) end)
      new = spawn(fn -> Process.sleep(:infinity) end)

      :ok = Player.pcm_tap(pid, true, old)
      assert_receive {:sendspin_state, @key, %{event: "pcm_tap", value: true}}, 1_000
      :ok = Player.pcm_tap(pid, true, new)
      assert_receive {:sendspin_state, @key, %{event: "pcm_tap", value: true}}, 1_000
      assert {^new, _ref} = :sys.get_state(pid).pcm_tap_lease

      # The old owner neither turns it off nor takes it down with it.
      :ok = Player.pcm_tap(pid, false, old)
      Process.exit(old, :kill)
      refute_receive {:sendspin_state, @key, %{event: "pcm_tap", value: false}}, 200
      assert %{enabled: true} = Player.pcm_tap_status(pid)

      Process.exit(new, :kill)
      assert_receive {:sendspin_state, @key, %{event: "pcm_tap", value: false}}, 1_000
      assert :sys.get_state(pid).pcm_tap_lease == nil
    end

    test "an off from the holder ends the lease" do
      pid = start_player!(pcm_tap_path: "/run/up-pcm-test")
      assert_receive {:sendspin_state, @key, %{event: "started"}}, 2_000
      owner = spawn(fn -> Process.sleep(:infinity) end)

      :ok = Player.pcm_tap(pid, true, owner)
      :ok = Player.pcm_tap(pid, false, owner)
      assert :sys.get_state(pid).pcm_tap_lease == nil
      assert_receive {:sendspin_state, @key, %{event: "pcm_tap", value: true}}, 1_000
      assert_receive {:sendspin_state, @key, %{event: "pcm_tap", value: false}}, 1_000

      # Its later death sends no second off.
      Process.exit(owner, :kill)
      refute_receive {:sendspin_state, @key, %{event: "pcm_tap"}}, 200
    end

    test "rejects a non-boolean" do
      pid = start_player!()

      assert_raise FunctionClauseError, fn -> apply(Player, :set_volume_external, [pid, 1]) end
    end

    test "a player started with :volume_external starts the binary in that mode" do
      # Players never reopen their port; a respawn is a fresh player, so
      # the mode survives a restart only through this option.
      pid = start_player!(volume_external: true)

      assert_receive {:sendspin_state, @key, %{event: "volume_external", value: true}}, 2_000
      assert "--external-volume" in Player.__cli_args__(:sys.get_state(pid))
    end

    test "--external-volume is omitted by default" do
      refute "--external-volume" in Player.__cli_args__(cli_state([]))
      assert "--external-volume" in Player.__cli_args__(cli_state(volume_external: true))
    end
  end

  describe "pcm_tap/3" do
    test "the binary gets --pcm-tap-path, under the tmp dir on the host" do
      pid = start_player!()
      assert_receive {:sendspin_state, @key, %{event: "started"}}, 2_000

      path = Player.pcm_tap_path(config())
      assert path == Path.join(System.tmp_dir!(), "up-pcm-deadbeef")
      assert %{path: ^path, enabled: false} = Player.pcm_tap_status(pid)

      assert ["--pcm-tap-path", ^path | _] =
               Enum.drop_while(
                 Player.__cli_args__(:sys.get_state(pid)),
                 &(&1 != "--pcm-tap-path")
               )
    end

    test "a player started without a path passes no flag" do
      refute "--pcm-tap-path" in Player.__cli_args__(cli_state(pcm_tap_path: nil))
    end

    test "the ack is broadcast and tracked in pcm_tap_status/1" do
      pid = start_player!(pcm_tap_path: "/run/up-pcm-test")
      assert_receive {:sendspin_state, @key, %{event: "started"}}, 2_000

      :ok = Player.pcm_tap(pid, true, self())
      assert_receive {:sendspin_state, @key, %{event: "pcm_tap", value: true}}, 1_000
      assert %{path: "/run/up-pcm-test", enabled: true} = Player.pcm_tap_status(pid)

      :ok = Player.pcm_tap(pid, false, self())
      assert_receive {:sendspin_state, @key, %{event: "pcm_tap", value: false}}, 1_000
      assert %{enabled: false} = Player.pcm_tap_status(pid)
    end

    test "a failed enable leaves the tap off and logs why" do
      pid = start_player!(pcm_tap_path: nil)
      assert_receive {:sendspin_state, @key, %{event: "started"}}, 2_000

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          :ok = Player.pcm_tap(pid, true, self())

          assert_receive {:sendspin_state, @key, %{event: "pcm_tap", value: false, ok: false}},
                         1_000

          assert %{path: nil, enabled: false} = Player.pcm_tap_status(pid)
        end)

      assert log =~ "could not enable the PCM tap"
      assert log =~ "no --pcm-tap-path"
    end

    test "rejects a non-boolean" do
      pid = start_player!()
      assert_raise FunctionClauseError, fn -> apply(Player, :pcm_tap, [pid, 1, self()]) end
    end

    @tag :tmp_dir
    test "writes the command with the fixed field order", %{tmp_dir: tmp_dir} do
      log = Path.join(tmp_dir, "stdin.log")
      recorder = Path.join(tmp_dir, "recorder.sh")

      File.write!(recorder, """
      #!/bin/sh
      echo '{"event":"started","version":"0.0.0-fake","port":19003,"name":"x","alsa_device":"x"}'
      cat > "#{log}"
      """)

      File.chmod!(recorder, 0o755)

      pid = start_player!(binary_path: recorder, mdns_port: 19_003)
      assert_receive {:sendspin_state, @key, %{event: "started"}}, 2_000

      :ok = Player.pcm_tap(pid, true, self())
      :ok = Player.pcm_tap(pid, false, self())
      :ok = GenServer.stop(pid, :normal, 2_000)

      lines = log |> File.read!() |> String.split("\n", trim: true)
      assert ~s({"cmd":"pcm_tap","value":true}) in lines
      assert ~s({"cmd":"pcm_tap","value":false}) in lines
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

  describe "display roles" do
    @display_kinds ~w(metadata metadata_clear controller_state controller_clear
                      controller_result group color color_clear artwork artwork_clear
                      viz_enable viz viz_clear)

    setup do
      :ok = Phoenix.PubSub.subscribe(@pubsub, "sendspin:display")
      :ok = Phoenix.PubSub.subscribe(@pubsub, Player.viz_topic(config().client_id))
      :ok
    end

    defp display_opts(dir, overrides \\ %{}) do
      Map.merge(
        %{
          artwork_dir: dir,
          artwork_size: {320, 240},
          artwork_keep: 8,
          viz_bins: 4,
          viz_rate: 20,
          viz_offset_ms: 100
        },
        overrides
      )
    end

    defp start_display_player!(dir, overrides \\ %{}) do
      pid = start_player!(display_roles: display_opts(dir, overrides))
      assert_receive {:sendspin_state, @key, %{event: "started", display_roles: true}}, 2_000
      assert_receive {:sendspin_state, @key, %{event: "listening"}}, 2_000
      pid
    end

    defp display_event(kind) do
      assert_receive {:sendspin_display, @key, seq, %{event: ^kind} = event}, 1_000
      {seq, event}
    end

    defp refute_display_kinds_on_state do
      for kind <- @display_kinds do
        refute_received {:sendspin_state, _, %{event: ^kind}}
      end
    end

    test "passes the display flags only with the :display_roles option" do
      refute "--display-roles" in Player.__cli_args__(cli_state([]))

      args = Player.__cli_args__(cli_state(display_roles: display_opts("/tmp/up_art/x")))

      assert Enum.drop_while(args, &(&1 != "--display-roles")) |> Enum.take(13) == [
               "--display-roles",
               "--artwork-dir",
               "/tmp/up_art/x",
               "--artwork-size",
               "320x240",
               "--artwork-keep",
               "8",
               "--viz-bins",
               "4",
               "--viz-rate",
               "20",
               "--viz-offset-ms",
               "100"
             ]
    end

    @tag :tmp_dir
    test "display events go to sendspin:display with rising seq, never sendspin:state or last_event",
         %{tmp_dir: tmp_dir} do
      pid = start_display_player!(tmp_dir)
      before = Player.last_event(pid)
      assert %{event: "listening"} = before

      :ok = Player.__send_command__(pid, %{cmd: "emit_display"})

      {s1, metadata} = display_event("metadata")
      {s2, _} = display_event("controller_state")
      {s3, _} = display_event("group")
      {s4, _} = display_event("color")
      {s5, artwork} = display_event("artwork")

      assert [s1, s2, s3, s4, s5] == Enum.to_list(s1..(s1 + 4))
      assert metadata.title == "Fake Song"

      assert %{track_progress: 1000, playback_speed: 1000, progress_age_ms: 250} =
               metadata.progress

      # Every display event carries the BEAM monotonic time it was read at,
      # the reference for extrapolating the track position.
      now = System.monotonic_time(:millisecond)
      assert is_integer(metadata.received_at) and metadata.received_at <= now
      assert artwork.received_at >= metadata.received_at
      assert Path.dirname(artwork.path) == tmp_dir
      assert File.exists?(artwork.path)
      assert %{width: 320, height: 240, slot: 0} = artwork

      refute_display_kinds_on_state()
      assert Player.last_event(pid) == before

      assert {^s5, snapshot} = Player.display_snapshot(pid)

      assert Map.keys(snapshot) |> Enum.sort() == [
               :artwork,
               :color,
               :controller_state,
               :group,
               :metadata
             ]

      assert snapshot.metadata == metadata
    end

    @tag :tmp_dir
    test "clear events empty their snapshot slot; disconnected forgets the group",
         %{tmp_dir: tmp_dir} do
      pid = start_display_player!(tmp_dir)
      :ok = Player.__send_command__(pid, %{cmd: "emit_display"})
      display_event("artwork")

      :ok = Player.__send_command__(pid, %{cmd: "emit_event", event: %{event: "metadata_clear"}})

      :ok =
        Player.__send_command__(pid, %{
          cmd: "emit_event",
          event: %{event: "artwork_clear", slot: 0}
        })

      {seq, _} = display_event("artwork_clear")
      assert {^seq, snapshot} = Player.display_snapshot(pid)
      assert Map.keys(snapshot) |> Enum.sort() == [:color, :controller_state, :group]

      # An already-subscribed consumer hears about the group going away as a
      # sequenced display event, and the snapshot agrees.
      :ok = Player.__send_command__(pid, %{cmd: "emit_event", event: %{event: "disconnected"}})
      assert_receive {:sendspin_state, @key, %{event: "disconnected"}}, 1_000
      {clear_seq, _} = display_event("group_clear")
      assert clear_seq == seq + 1
      assert {^clear_seq, snapshot} = Player.display_snapshot(pid)
      refute Map.has_key?(snapshot, :group)

      # Nothing to clear the second time.
      :ok = Player.__send_command__(pid, %{cmd: "emit_event", event: %{event: "disconnected"}})
      assert_receive {:sendspin_state, @key, %{event: "disconnected"}}, 1_000
      refute_receive {:sendspin_display, @key, _, %{event: "group_clear"}}, 100
    end

    @tag :tmp_dir
    test "a group pause/resume re-times the cached metadata for late subscribers",
         %{tmp_dir: tmp_dir} do
      pid = start_display_player!(tmp_dir)

      emit = fn event ->
        :ok = Player.__send_command__(pid, %{cmd: "emit_event", event: event})
      end

      emit.(%{
        event: "metadata",
        title: "Song",
        progress: %{
          track_progress: 10_000,
          track_duration: 200_000,
          playback_speed: 1000,
          progress_age_ms: 0
        }
      })

      display_event("metadata")
      emit.(%{event: "group", playback_state: "playing"})
      display_event("group")
      Process.sleep(300)

      # Pause: the position reached so far, frozen, published before the group.
      emit.(%{event: "group", playback_state: "paused"})
      {mseq, paused} = display_event("metadata")
      {gseq, _} = display_event("group")
      assert gseq == mseq + 1
      assert %{playback_speed: 0, progress_age_ms: 0, track_progress: at} = paused.progress
      assert at >= 10_300 and at < 12_000
      assert paused.title == "Song"

      # A late subscriber (a restarted TV UI) still sees the frozen position.
      Process.sleep(200)

      assert {^gseq, %{metadata: snap, group: %{playback_state: "paused"}}} =
               Player.display_snapshot(pid)

      assert snap.progress.track_progress == at
      assert snap.progress.playback_speed == 0

      # Resume: the same position, the speed back, the paused time not counted.
      emit.(%{event: "group", playback_state: "playing"})
      {_, resumed} = display_event("metadata")
      display_event("group")
      assert %{playback_speed: 1000, track_progress: ^at} = resumed.progress

      # Same state again, or a group with no metadata change: nothing re-timed.
      emit.(%{event: "group", playback_state: "playing"})
      display_event("group")
      refute_received {:sendspin_display, @key, _, %{event: "metadata"}}
    end

    @tag :tmp_dir
    test "server metadata that arrives while stopped keeps its timing when playback starts",
         %{tmp_dir: tmp_dir} do
      pid = start_display_player!(tmp_dir)

      emit = fn event ->
        :ok = Player.__send_command__(pid, %{cmd: "emit_event", event: event})
      end

      emit.(%{event: "group", playback_state: "stopped"})
      display_event("group")

      emit.(%{
        event: "metadata",
        progress: %{
          track_progress: 10_000,
          track_duration: 200_000,
          playback_speed: 1000,
          progress_age_ms: 500
        }
      })

      {_, metadata} = display_event("metadata")
      emit.(%{event: "group", playback_state: "playing"})
      {seq, _} = display_event("group")
      refute_received {:sendspin_display, @key, _, %{event: "metadata"}}

      assert {^seq, %{metadata: snap}} = Player.display_snapshot(pid)
      assert snap == metadata
      assert Progress.at(snap, snap.received_at, true).elapsed_ms == 10_500

      # A pause then re-bases it; new server metadata while paused drops
      # that frozen anchor again.
      emit.(%{event: "group", playback_state: "paused"})
      {_, %{progress: %{playback_speed: 0}}} = display_event("metadata")
      display_event("group")
      emit.(%{event: "metadata", progress: %{metadata.progress | playback_speed: 1000}})
      display_event("metadata")
      emit.(%{event: "group", playback_state: "playing"})
      display_event("group")
      refute_received {:sendspin_display, @key, _, %{event: "metadata"}}
    end

    @tag :tmp_dir
    test "viz frames go to the per-output viz topic, only while enabled", %{tmp_dir: tmp_dir} do
      pid = start_display_player!(tmp_dir)
      before = Player.last_event(pid)

      # Disabled at start: the binary emits nothing.
      :ok = Player.__send_command__(pid, %{cmd: "emit_viz"})
      :ok = Player.viz_enable(pid, true)
      {seq, %{value: true}} = display_event("viz_enable")
      refute_received {:sendspin_viz, _, _}

      :ok = Player.__send_command__(pid, %{cmd: "emit_viz"})

      assert_receive {:sendspin_viz, @key, %{event: "viz", lead_ms: 100, bins: bins}}, 1_000
      assert length(bins) == 4

      :ok = Player.__send_command__(pid, %{cmd: "emit_event", event: %{event: "viz_clear"}})
      assert_receive {:sendspin_viz, @key, %{event: "viz_clear"}}, 1_000

      refute_display_kinds_on_state()
      refute_received {:sendspin_display, _, _, %{event: "viz"}}
      assert Player.last_event(pid) == before
      # Viz traffic neither advances the display seq nor enters the snapshot.
      assert {^seq, %{}} = Player.display_snapshot(pid)
    end

    @tag :tmp_dir
    test "controller/2 round-trips through the binary", %{tmp_dir: tmp_dir} do
      pid = start_display_player!(tmp_dir)

      for command <- [:play, :pause, :stop, :next, :previous] do
        :ok = Player.controller(pid, command)
        name = Atom.to_string(command)
        assert {_, %{command: ^name, ok: true}} = display_event("controller_result")
      end

      assert {_, snapshot} = Player.display_snapshot(pid)
      refute Map.has_key?(snapshot, :controller_result)
      refute_display_kinds_on_state()
    end

    test "controller/2 and viz_enable/2 refuse a player without display roles" do
      pid = start_player!()
      assert_receive {:sendspin_state, @key, %{event: "started"} = started}, 2_000
      refute Map.has_key?(started, :display_roles)

      assert {:error, :display_roles_disabled} = Player.controller(pid, :next)
      assert {:error, :display_roles_disabled} = Player.viz_enable(pid, true)
      assert {0, %{}} = Player.display_snapshot(pid)
      assert_raise FunctionClauseError, fn -> apply(Player, :controller, [pid, :volume]) end
    end

    @tag :tmp_dir
    test "controller and viz_enable commands use the fixed field order", %{tmp_dir: tmp_dir} do
      uniq = System.unique_integer([:positive])
      log = Path.join(tmp_dir, "stdin_#{uniq}.log")
      recorder = Path.join(tmp_dir, "recorder_#{uniq}.sh")

      File.write!(recorder, """
      #!/bin/sh
      echo '{"event":"started","version":"0.0.0-fake","port":19002,"name":"x","alsa_device":"x"}'
      cat > "#{log}"
      """)

      File.chmod!(recorder, 0o755)

      pid =
        start_player!(
          binary_path: recorder,
          mdns_port: 19_002,
          display_roles: display_opts(Path.join(tmp_dir, "art"))
        )

      assert_receive {:sendspin_state, @key, %{event: "started"}}, 2_000

      :ok = Player.controller(pid, :next)
      :ok = Player.controller(pid, :play)
      :ok = Player.viz_enable(pid, true)
      :ok = GenServer.stop(pid, :normal, 2_000)

      lines = log |> File.read!() |> String.split("\n", trim: true)

      assert ~s({"cmd":"controller","value":3}) in lines
      assert ~s({"cmd":"controller","value":0}) in lines
      assert ~s({"cmd":"viz_enable","value":true}) in lines
    end

    test "an oversize stdout line is dropped whole and parsing resumes" do
      pid = start_player!()
      assert_receive {:sendspin_state, @key, %{event: "listening"}}, 2_000

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          big = %{event: "volume", value: 1, pad: String.duplicate("x", 6_000)}
          :ok = Player.__send_command__(pid, %{cmd: "emit_event", event: big})
          :ok = Player.set_volume(pid, 44)
          assert_receive {:sendspin_state, @key, %{event: "volume", value: 44}}, 1_000
        end)

      assert log =~ "dropped an oversize stdout line"
      refute log =~ "could not decode line"
      refute_received {:sendspin_state, @key, %{event: "volume", value: 1}}
      assert %{event: "volume", value: 44} = Player.last_event(pid)
    end

    test "the binary's stderr lines are logged, not parsed or broadcast" do
      pid = start_player!()
      assert_receive {:sendspin_state, @key, %{event: "listening"}}, 2_000
      before = Player.last_event(pid)

      # The suite logs from :warning up; the :info lines need more.
      level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: level) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          for line <- [
                "AlsaPipeSink: underrun, recovering",
                "W SyncTask: Lost sync (48211us off)",
                "E SyncTask: Failed to decode audio chunk",
                "I SyncTask: Regained sync",
                "AlsaPipeSink: plughw:0,0 — 44100 Hz 2 ch 16 bit"
              ] do
            :ok = Player.__send_command__(pid, %{cmd: "emit_stderr", line: line})
          end

          :ok = Player.set_volume(pid, 45)
          assert_receive {:sendspin_state, @key, %{event: "volume", value: 45}}, 1_000
        end)

      assert log =~ ~r/\[warning\].*sendspin_player: AlsaPipeSink: underrun, recovering/
      assert log =~ ~r/\[warning\].*sendspin_player: W SyncTask: Lost sync/
      assert log =~ ~r/\[error\].*sendspin_player: E SyncTask: Failed to decode/
      assert log =~ ~r/\[info\].*sendspin_player: I SyncTask: Regained sync/
      assert log =~ ~r/\[info\].*sendspin_player: AlsaPipeSink: plughw:0,0/
      refute log =~ "could not decode line"
      refute before == Player.last_event(pid)
      assert %{event: "volume", value: 45} = Player.last_event(pid)
    end

    @tag :tmp_dir
    test "the artwork dir is emptied of artwork files before the binary starts",
         %{tmp_dir: tmp_dir} do
      sha_name = fn tag -> Base.encode16(:crypto.hash(:sha256, tag), case: :lower) <> ".jpg" end
      stale = Path.join(tmp_dir, sha_name.("previous-instance"))
      stale_tmp = Path.join(tmp_dir, "." <> sha_name.("half-written") <> ".tmp")
      unrelated = Path.join(tmp_dir, "not-artwork.txt")
      for path <- [stale, stale_tmp, unrelated], do: File.write!(path, "x")

      pid = start_display_player!(tmp_dir)
      refute File.exists?(stale)
      refute File.exists?(stale_tmp)
      assert File.exists?(unrelated)

      # Retention is the binary's (--artwork-keep); the player deletes
      # nothing the binary reports.
      paths =
        for _ <- 1..10 do
          :ok = Player.__send_command__(pid, %{cmd: "emit_display"})
          {_, %{path: path}} = display_event("artwork")
          path
        end

      assert Enum.all?(paths, &File.exists?/1)
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
