defmodule UniversalProxy.ESPHome.ZWaveProxyTest do
  # Each test gets its own unnamed GenServer (pid only — no atom leakage)
  # and no UART hardware (port_path: nil).
  #
  # async: false — the broadcast tests share a fixed-name espex registry
  # (torn down per test by start_supervised) and several tests assert on
  # the global uart:port_opened/uart:port_closed PubSub topics; running
  # serially avoids both dynamic-atom growth and cross-test delivery.
  use ExUnit.Case, async: false

  alias UniversalProxy.ESPHome.ZWaveProxy
  alias UniversalProxy.ESPHome.ZWaveProxy.{Advertiser, Frame, Parser}

  # Stands in for the Circuits.UART GenServer: replies :ok to every call
  # and forwards writes to the test process, so tests can assert exactly
  # what reaches the "wire".
  defmodule FakeUART do
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_call({:write, data, _timeout}, _from, test_pid) do
      send(test_pid, {:uart_write, data})
      {:reply, :ok, test_pid}
    end

    def handle_call(_msg, _from, test_pid), do: {:reply, :ok, test_pid}
  end

  # Records every MdnsLite call as `{:mdns, call, arg}` to the test process
  # (async: false makes the Application env a safe channel). `:add_result`
  # lets a test make add_mdns_service fail.
  defmodule FakeMdns do
    def add_mdns_service(service),
      do: record(:add, service, Application.get_env(:fake_mdns, :add_result, :ok))

    def remove_mdns_service(id), do: record(:remove, id, :ok)
    def goodbye_service(id), do: record(:goodbye, id, :ok)
    def announce_all, do: record(:announce_all, nil, :ok)

    defp record(call, arg, result) do
      case Application.get_env(:fake_mdns, :delay_ms) do
        nil -> :ok
        ms -> Process.sleep(ms)
      end

      send(Application.fetch_env!(:fake_mdns, :test_pid), {:mdns, call, arg})
      result
    end
  end

  setup do
    Application.put_env(:fake_mdns, :test_pid, self())
    Application.delete_env(:fake_mdns, :add_result)

    on_exit(fn ->
      Application.delete_env(:fake_mdns, :test_pid)
      Application.delete_env(:fake_mdns, :add_result)
      Application.delete_env(:fake_mdns, :table_pid)
      Application.delete_env(:fake_mdns, :delay_ms)
    end)

    pid = start_supervised!({ZWaveProxy, name: nil, port_path: nil})
    {:ok, server: pid}
  end

  # GET_NETWORK_IDS response with home ID DE:AD:BE:EF (LENGTH = 9).
  defp network_ids_response do
    body = <<0x01, 0x09, 0x01, 0x20, 0xDE, 0xAD, 0xBE, 0xEF, 0x05, 0x00>>
    body <> <<Frame.calculate_checksum(body <> <<0x00>>)>>
  end

  # Wire a FakeUART into the server's state (there is no real tty in CI).
  defp attach_fake_uart(server, overrides \\ %{}) do
    {:ok, fake} = FakeUART.start_link(self())

    :sys.replace_state(server, fn state ->
      struct!(state, Map.merge(%{uart_pid: fake, port_path: "/dev/ttyFake"}, overrides))
    end)

    fake
  end

  # Stand up an espex-convention connection registry with self() registered
  # as a subscriber, so `Espex.push_zwave_home_id/2` broadcasts land here.
  # Returns the server name to feed the adapter as `:espex_server`. Using
  # `Espex.Supervisor.registry_name/1` guarantees the name matches what the
  # broadcast dispatches to.
  defp start_espex_registry! do
    server = __MODULE__.EspexServer
    registry = Espex.Supervisor.registry_name(server)
    start_supervised!({Registry, keys: :duplicate, name: registry})
    {:ok, _} = Registry.register(registry, :subscribers, nil)
    server
  end

  describe "without hardware" do
    test "available? returns false", %{server: server} do
      refute ZWaveProxy.available?(server)
    end

    test "home_id returns 0 when no controller", %{server: server} do
      assert ZWaveProxy.home_id(server) == 0
    end

    test "subscribe is rejected with :unavailable", %{server: server} do
      assert {:error, :unavailable} = ZWaveProxy.subscribe(server, self())
    end

    test "send_frame returns {:error, :unavailable}", %{server: server} do
      assert {:error, :unavailable} = ZWaveProxy.send_frame(server, <<1, 2, 3>>)
    end

    test "unsubscribe is idempotent for an unknown pid", %{server: server} do
      assert :ok = ZWaveProxy.unsubscribe(server, self())
    end

    test "claimed_port is nil without an open port", %{server: server} do
      assert ZWaveProxy.claimed_port(server) == nil
    end

    test "an unopenable port path leaves the proxy unavailable, not crashed" do
      server =
        start_supervised!(
          {ZWaveProxy, name: nil, port_path: "/dev/nonexistent-zwave-test"},
          id: :zwave_bad_port
        )

      refute ZWaveProxy.available?(server)
      assert Process.alive?(server)
    end
  end

  describe "frame pipeline (fake UART)" do
    test "UART bytes are ACKed locally, forwarded, and update the home ID", %{server: server} do
      espex = start_espex_registry!()
      attach_fake_uart(server, %{espex_server: espex})
      assert {:ok, <<0, 0, 0, 0>>} = ZWaveProxy.subscribe(server, self())

      frame = network_ids_response()
      send(server, {:circuits_uart, "ttyFake", frame})

      # Local ACK reaches the wire before the frame reaches the client.
      assert_receive {:uart_write, <<0x06>>}
      # Home-ID change is broadcast to every espex connection (we are one).
      assert_receive {:espex_zwave_home_id_changed, <<0xDE, 0xAD, 0xBE, 0xEF>>}
      # The frame itself still goes only to the subscriber.
      assert_receive {:espex_zwave_frame, ^frame}

      assert ZWaveProxy.home_id(server) == 0xDEADBEEF
      assert ZWaveProxy.available?(server)
    end

    test "duplicate single-byte client responses are suppressed (ESPHome parity)",
         %{server: server} do
      attach_fake_uart(server, %{parser: %{Parser.new() | last_response: 0x06}})

      # The proxy already ACKed locally — the client's copy is dropped.
      assert :ok = ZWaveProxy.send_frame(server, <<0x06>>)
      refute_receive {:uart_write, <<0x06>>}, 50

      # A different single-byte response passes through.
      assert :ok = ZWaveProxy.send_frame(server, <<0x15>>)
      assert_receive {:uart_write, <<0x15>>}

      # Multi-byte frames are never suppressed.
      frame = network_ids_response()
      assert :ok = ZWaveProxy.send_frame(server, frame)
      assert_receive {:uart_write, ^frame}
    end

    test "empty frames are rejected", %{server: server} do
      attach_fake_uart(server)
      assert {:error, :empty_frame} = ZWaveProxy.send_frame(server, <<>>)
    end

    test "claimed_port reports the open tty and subscription state", %{server: server} do
      attach_fake_uart(server)

      base = %{tty_name: "ttyFake", display_name: "ttyFake", subscribed: false}
      assert ZWaveProxy.claimed_port(server) == base

      {:ok, _} = ZWaveProxy.subscribe(server, self())
      assert ZWaveProxy.claimed_port(server) == %{base | subscribed: true}

      :ok = ZWaveProxy.unsubscribe(server, self())
      assert ZWaveProxy.claimed_port(server) == base
    end

    test "claimed_port prefers the resolver-supplied display name", %{server: server} do
      attach_fake_uart(server, %{display_name: "ZWA-2 (1-1.1)"})

      assert ZWaveProxy.claimed_port(server) == %{
               tty_name: "ttyFake",
               display_name: "ZWA-2 (1-1.1)",
               subscribed: false
             }
    end
  end

  describe "History pipeline broadcasts (fake UART)" do
    test "rx chunks, local ACKs, and client writes broadcast as :uart_data", %{server: server} do
      display = "zw-hist-#{System.unique_integer([:positive])}"
      attach_fake_uart(server, %{display_name: display})
      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "uart:#{display}")

      frame = network_ids_response()
      send(server, {:circuits_uart, "ttyFake", frame})

      assert_receive {:uart_data, %{name: ^display, dir: :rx, data: ^frame}}
      # The locally written ACK is mirrored as TX.
      assert_receive {:uart_data, %{name: ^display, dir: :tx, data: <<0x06>>}}

      # A client-originated frame write is mirrored too (0x15 is not the
      # last local response, so it is not dedup-suppressed).
      assert :ok = ZWaveProxy.send_frame(server, <<0x15>>)
      assert_receive {:uart_data, %{name: ^display, dir: :tx, data: <<0x15>>}}
    end

    test "dedup-suppressed client frames are not broadcast", %{server: server} do
      display = "zw-hist-#{System.unique_integer([:positive])}"

      attach_fake_uart(server, %{
        display_name: display,
        parser: %{Parser.new() | last_response: 0x06}
      })

      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "uart:#{display}")

      assert :ok = ZWaveProxy.send_frame(server, <<0x06>>)
      refute_receive {:uart_data, _}, 50
    end

    test "UART error broadcasts :uart_port_closed", %{server: server} do
      display = "zw-hist-#{System.unique_integer([:positive])}"
      attach_fake_uart(server, %{display_name: display})
      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "uart:port_closed")

      send(server, {:circuits_uart, "ttyFake", {:error, :eio}})

      # `owner:` is the contract History's external-port tracking keys
      # off — assert it explicitly.
      assert_receive {:uart_port_closed, %{friendly_name: ^display, owner: :zwave_proxy}}
      refute ZWaveProxy.available?(server)
    end
  end

  describe "home-ID lifecycle (fake UART)" do
    test "UART error clears the home ID and broadcasts the zeroed ID", %{server: server} do
      espex = start_espex_registry!()

      attach_fake_uart(server, %{
        home_id: <<0xDE, 0xAD, 0xBE, 0xEF>>,
        home_id_ready: true,
        espex_server: espex
      })

      assert {:ok, <<0xDE, 0xAD, 0xBE, 0xEF>>} = ZWaveProxy.subscribe(server, self())

      send(server, {:circuits_uart, "ttyFake", {:error, :eio}})

      assert_receive {:espex_zwave_home_id_changed, <<0, 0, 0, 0>>}
      refute ZWaveProxy.available?(server)
      assert ZWaveProxy.home_id(server) == 0
    end

    test "home-ID broadcast is dropped (not crashed) when espex registry is down",
         %{server: server} do
      # Default espex_server (Espex.Server) has no registry in the test
      # env; the boot-ordering rescue must swallow it and keep the server
      # alive with the home ID stored.
      attach_fake_uart(server)
      frame = network_ids_response()
      send(server, {:circuits_uart, "ttyFake", frame})

      assert ZWaveProxy.home_id(server) == 0xDEADBEEF
      assert Process.alive?(server)
    end

    test "retry tick re-sends GET_NETWORK_IDS while the home ID is unknown", %{server: server} do
      attach_fake_uart(server, %{home_id_ready: false, query_retries: 0})

      send(server, :zwave_home_id_retry)
      assert_receive {:uart_write, cmd}
      assert cmd == Frame.get_network_ids_command()
    end

    test "retry tick gives up after the retry budget", %{server: server} do
      attach_fake_uart(server, %{home_id_ready: false, query_retries: 5})

      send(server, :zwave_home_id_retry)
      refute_receive {:uart_write, _}, 50
    end

    test "retry tick is a no-op once the home ID is known", %{server: server} do
      attach_fake_uart(server, %{home_id_ready: true, query_retries: 1})

      send(server, :zwave_home_id_retry)
      refute_receive {:uart_write, _}, 50
    end
  end

  describe "frame reception timeout (fake UART)" do
    test "a stalled partial frame is abandoned and the parser recovers", %{server: server} do
      attach_fake_uart(server)

      # Partial frame (SOF + LENGTH), then silence — parser is mid-frame.
      send(server, {:circuits_uart, "ttyFake", <<0x01, 0x09>>})
      ref = :sys.get_state(server).frame_timer_ref
      assert Parser.mid_frame?(:sys.get_state(server).parser)

      # Fire the armed timeout directly (the 1.5 s wall-clock timer isn't
      # test-friendly); the stale bytes must be dropped.
      send(server, {:zwave_frame_timeout, ref})
      refute Parser.mid_frame?(:sys.get_state(server).parser)

      # A fresh full frame now parses cleanly — no corruption from the
      # abandoned partial.
      send(server, {:circuits_uart, "ttyFake", network_ids_response()})
      assert_receive {:uart_write, <<0x06>>}
    end

    test "the timer is timed from the start byte, not reset per chunk", %{server: server} do
      attach_fake_uart(server)

      # First chunk starts the frame → a timer is armed.
      send(server, {:circuits_uart, "ttyFake", <<0x01, 0x09>>})
      timer1 = :sys.get_state(server).frame_timer
      assert timer1 != nil

      # More bytes of the SAME frame must NOT rearm the timer — it keeps
      # measuring from the SOF, so a slow trickle still times out.
      send(server, {:circuits_uart, "ttyFake", <<0x01, 0x20>>})
      assert :sys.get_state(server).frame_timer == timer1

      # Completing the frame cancels the timer.
      send(server, {:circuits_uart, "ttyFake", <<0xDE, 0xAD, 0xBE, 0xEF, 0x05, 0x00, 0xF0>>})
      assert :sys.get_state(server).frame_timer == nil
    end

    test "timeout is a no-op when the parser is idle", %{server: server} do
      attach_fake_uart(server)
      refute Parser.mid_frame?(:sys.get_state(server).parser)

      send(server, {:zwave_frame_timeout, make_ref()})
      assert Process.alive?(server)
      refute Parser.mid_frame?(:sys.get_state(server).parser)
    end

    test "a stale timeout ref does not reset a newer frame", %{server: server} do
      attach_fake_uart(server)

      # Frame A starts and arms a timer (capture its ref), then completes —
      # this is the "timer fired just before cancel" shape.
      send(server, {:circuits_uart, "ttyFake", <<0x01, 0x09>>})
      stale_ref = :sys.get_state(server).frame_timer_ref

      send(
        server,
        {:circuits_uart, "ttyFake", <<0x01, 0x20, 0xDE, 0xAD, 0xBE, 0xEF, 0x05, 0x00, 0xF0>>}
      )

      refute Parser.mid_frame?(:sys.get_state(server).parser)

      # Frame B is now mid-flight when frame A's late timeout is delivered.
      send(server, {:circuits_uart, "ttyFake", <<0x01, 0x09>>})
      assert Parser.mid_frame?(:sys.get_state(server).parser)

      send(server, {:zwave_frame_timeout, stale_ref})
      # Frame B must survive — the stale ref is ignored.
      assert Parser.mid_frame?(:sys.get_state(server).parser)
    end
  end

  describe "feature_flags/0" do
    test "always advertises the Z-Wave capability, even with no hardware" do
      # Cold-hotplug discovery depends on this: HA arms its HOME_ID_CHANGE
      # listener only if the flag is set at connect.
      assert ZWaveProxy.feature_flags() == 0x01
    end
  end

  describe "open path (injected opener)" do
    # Exercises attempt_open/resolve_port/:uart_port_opened without a real
    # tty by injecting an opener that hands back a FakeUART. Subscribe to
    # the lifecycle topic BEFORE the server starts so the open broadcast
    # (fired from handle_continue) isn't missed.
    defp start_opening_proxy!(resolver_or_opts) do
      {:ok, fake} = FakeUART.start_link(self())
      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "uart:port_opened")

      opts =
        [name: nil, open_fun: fn _path -> {:ok, fake} end, advertiser: nil] ++
          List.wrap(resolver_or_opts)

      server = start_supervised!({ZWaveProxy, opts}, id: {:zw_open, System.unique_integer()})
      {server, fake}
    end

    test "resolver map: broadcasts port_opened with the display name and queries home ID" do
      {server, _fake} =
        start_opening_proxy!(
          resolver: fn -> %{path: "/dev/ttyZW", display_name: "ZWA-2 (1-1.1)"} end
        )

      assert_receive {:uart_port_opened, %{friendly_name: "ZWA-2 (1-1.1)", owner: :zwave_proxy}}
      assert_receive {:uart_write, cmd}
      assert cmd == Frame.get_network_ids_command()

      assert ZWaveProxy.claimed_port(server) ==
               %{tty_name: "ttyZW", display_name: "ZWA-2 (1-1.1)", subscribed: false}
    end

    test "resolver bare string: display name falls back to the tty basename" do
      {_server, _fake} = start_opening_proxy!(resolver: fn -> "/dev/ttyBare" end)

      assert_receive {:uart_port_opened, %{friendly_name: "ttyBare", owner: :zwave_proxy}}
    end

    test "no resolver: opens the static port_path, basename as display name" do
      {_server, _fake} = start_opening_proxy!(port_path: "/dev/ttyStatic")

      assert_receive {:uart_port_opened, %{friendly_name: "ttyStatic", owner: :zwave_proxy}}
    end
  end

  describe "shutdown and the linked UART" do
    test "a supervisor shutdown broadcasts :uart_port_closed" do
      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "uart:port_opened")
      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "uart:port_closed")
      {:ok, fake} = FakeUART.start_link(self())
      id = {:zw_shutdown, System.unique_integer()}

      start_supervised!(
        {ZWaveProxy,
         name: nil,
         port_path: "/dev/ttyShutdown",
         open_fun: fn _path -> {:ok, fake} end,
         advertiser: nil},
        id: id
      )

      assert_receive {:uart_port_opened, %{friendly_name: "ttyShutdown"}}

      # The supervisor stops the child with a :shutdown exit signal; only a
      # server that traps exits runs terminate/2 for it.
      :ok = stop_supervised(id)

      assert_receive {:uart_port_closed, %{friendly_name: "ttyShutdown", owner: :zwave_proxy}}
    end

    test "a crash of the linked UART process still stops the proxy" do
      test_pid = self()
      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "uart:port_opened")

      # Started from inside the proxy, so the fake is linked to it the way
      # Circuits.UART.start_link/0 is.
      open_fun = fn _path ->
        {:ok, fake} = FakeUART.start_link(test_pid)
        send(test_pid, {:fake_uart, fake})
        {:ok, fake}
      end

      server =
        start_supervised!(
          Supervisor.child_spec(
            {ZWaveProxy, name: nil, port_path: "/dev/ttyCrash", open_fun: open_fun},
            id: {:zw_crash, System.unique_integer()},
            restart: :temporary
          )
        )

      assert_receive {:fake_uart, fake}
      assert_receive {:uart_port_opened, %{friendly_name: "ttyCrash"}}
      ref = Process.monitor(server)

      Process.exit(fake, :kill)

      # Usually the :killed link exit; a home-ID retry write racing the
      # kill can crash it first with :noproc. Either way it doesn't survive.
      assert_receive {:DOWN, ^ref, :process, ^server, reason}, 1_000
      assert reason != :normal
    end
  end

  describe "_zwave._tcp mDNS" do
    @config %{name: "universal-proxy-abc123", port: 7053}
    @service %{
      id: :zwave_proxy,
      instance_name: "universal-proxy-abc123",
      protocol: "zwave",
      transport: "tcp",
      port: 7053,
      txt_payload: ["protocol=esphome"]
    }
    @register [{:remove, :zwave_proxy}, {:add, @service}, {:announce_all, nil}]
    @withdraw [{:goodbye, :zwave_proxy}, {:remove, :zwave_proxy}]

    defp start_advertiser!(opts \\ []) do
      opts =
        Keyword.merge(
          [
            name: nil,
            mdns_module: FakeMdns,
            config_fun: fn -> @config end,
            table_fun: fn -> Application.get_env(:fake_mdns, :table_pid) end
          ],
          opts
        )

      start_supervised!({Advertiser, opts}, id: {:zw_adv, System.unique_integer()})
    end

    defp start_mdns_proxy!(advertiser, opts \\ []) do
      {child, opts} = Keyword.pop(opts, :child, [])
      {:ok, fake} = FakeUART.start_link(self())
      id = {:zw_mdns, System.unique_integer()}

      opts =
        Keyword.merge(
          [
            name: nil,
            port_path: "/dev/ttyMdns",
            open_fun: fn _path -> {:ok, fake} end,
            advertiser: advertiser
          ],
          opts
        )

      spec = Supervisor.child_spec({ZWaveProxy, opts}, [id: id] ++ child)
      pid = start_supervised!(spec)
      {pid, fake, id}
    end

    # The next `n` recorded MdnsLite calls, in the order they were made.
    defp calls(n) do
      for _ <- 1..n do
        receive do
          {:mdns, call, arg} -> {call, arg}
        after
          1_000 -> flunk("expected #{n} mDNS calls, mailbox ran dry")
        end
      end
    end

    # A stand-in MdnsLite table owner, killed when the test exits even if an
    # assertion fails first.
    defp spawn_table do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(pid, :kill) end)
      pid
    end

    # Round-trips the advertiser so every earlier cast has been handled.
    defp sync(advertiser), do: :sys.get_state(advertiser)

    test "registers on claim with the node name and configured API port, then announces" do
      adv = start_advertiser!()
      start_mdns_proxy!(adv)

      assert calls(3) == @register
    end

    test "registers nothing when there is no stick" do
      adv = start_advertiser!()
      start_supervised!({ZWaveProxy, name: nil, advertiser: adv}, id: :zw_mdns_idle)
      # A resolver that finds nothing: the reopen loop never claims a port.
      start_supervised!(
        {ZWaveProxy, name: nil, resolver: fn -> nil end, advertiser: adv},
        id: :zw_mdns_no_stick
      )

      sync(adv)
      refute_receive {:mdns, _, _}, 100
    end

    test "a proxy with the advertiser disabled makes no mDNS calls" do
      adv = start_advertiser!()
      start_mdns_proxy!(nil)

      sync(adv)
      refute_receive {:mdns, _, _}, 100
    end

    test "unplug withdraws the service: goodbye before remove" do
      adv = start_advertiser!()
      {pid, _fake, _id} = start_mdns_proxy!(adv)
      assert calls(3) == @register

      send(pid, {:circuits_uart, "ttyMdns", {:error, :eio}})

      assert calls(2) == @withdraw
      sync(adv)
      refute_receive {:mdns, _, _}, 50
    end

    test "proxy shutdown withdraws: goodbye then remove" do
      adv = start_advertiser!()
      {_pid, _fake, id} = start_mdns_proxy!(adv)
      assert calls(3) == @register

      :ok = stop_supervised(id)

      assert calls(2) == @withdraw
    end

    test "a proxy killed before terminate/2 still gets its service withdrawn" do
      adv = start_advertiser!()
      # Temporary: a restarted replacement would re-advertise and race the
      # old owner's :DOWN, hiding whether the cleanup works.
      {pid, _fake, _id} = start_mdns_proxy!(adv, child: [restart: :temporary])

      assert calls(3) == @register

      Process.exit(pid, :kill)

      assert calls(2) == @withdraw
    end

    test "advertiser shutdown while advertised withdraws" do
      adv = start_advertiser!()
      start_mdns_proxy!(adv)
      assert calls(3) == @register

      GenServer.stop(adv)

      assert calls(2) == @withdraw
    end

    test "terminate with no claim touches nothing" do
      adv = start_advertiser!()
      id = :zw_mdns_unclaimed
      start_supervised!({ZWaveProxy, name: nil, advertiser: adv}, id: id)
      :ok = stop_supervised(id)

      sync(adv)
      refute_receive {:mdns, _, _}, 100
    end

    test "re-registration (restart) removes any stale entry first and never errors" do
      adv = start_advertiser!()
      {_pid, _fake, id} = start_mdns_proxy!(adv)
      assert calls(3) == @register
      :ok = stop_supervised(id)
      assert calls(2) == @withdraw

      start_mdns_proxy!(adv)

      assert calls(3) == @register
    end

    test "a failed add is retried and the service lands once MdnsLite recovers" do
      Application.put_env(:fake_mdns, :add_result, {:error, :mdns_unavailable})
      adv = start_advertiser!()
      start_mdns_proxy!(adv)
      assert calls(2) == [{:remove, :zwave_proxy}, {:add, @service}]
      refute_receive {:mdns, :announce_all, _}, 50

      Application.put_env(:fake_mdns, :add_result, :ok)
      # Fire the retry now rather than waiting out the backoff.
      send(adv, :retry)

      assert calls(3) == @register
    end

    test "unplug while a retry is pending withdraws (the add may have landed) and cancels the retry" do
      Application.put_env(:fake_mdns, :add_result, {:error, :mdns_unavailable})
      adv = start_advertiser!()
      {pid, _fake, _id} = start_mdns_proxy!(adv)
      assert calls(2) == [{:remove, :zwave_proxy}, {:add, @service}]

      send(pid, {:circuits_uart, "ttyMdns", {:error, :eio}})

      assert calls(2) == @withdraw
      assert :sys.get_state(adv).retry_timer == nil
    end

    test "an unreadable config is retried rather than registering a bogus port" do
      adv = start_advertiser!(config_fun: fn -> raise "config down" end)
      start_mdns_proxy!(adv)

      assert calls(1) == [{:remove, :zwave_proxy}]
      refute_receive {:mdns, :add, _}, 100
      assert :sys.get_state(adv).failures == 1
    end

    test "re-registers against a live replacement after the MdnsLite table owner restarts" do
      old = spawn_table()
      replacement = spawn_table()
      Application.put_env(:fake_mdns, :table_pid, old)

      adv = start_advertiser!()
      start_mdns_proxy!(adv)
      assert calls(3) == @register
      sync(adv)

      # The replacement is already registered when the old owner dies.
      Application.put_env(:fake_mdns, :table_pid, replacement)
      Process.exit(old, :kill)

      assert calls(3) == @register
      state = sync(adv)
      assert is_reference(state.table_ref)
      assert adv in elem(Process.info(replacement, :monitored_by), 1)
      refute_receive {:mdns, _, _}, 100
    end

    test "a table lookup that still names the dead owner backs off instead of spinning" do
      old = spawn_table()
      Application.put_env(:fake_mdns, :table_pid, old)

      adv = start_advertiser!()
      start_mdns_proxy!(adv)
      assert calls(3) == @register
      sync(adv)

      # The lookup keeps returning the dead pid.
      Process.exit(old, :kill)

      refute_receive {:mdns, _, _}, 150
      state = sync(adv)
      assert state.retry_timer != nil
      assert state.table_ref == nil
      refute state.registered
    end

    test "a missing table owner after :DOWN waits for the retry timer" do
      old = spawn_table()
      Application.put_env(:fake_mdns, :table_pid, old)

      adv = start_advertiser!()
      start_mdns_proxy!(adv)
      assert calls(3) == @register
      sync(adv)

      Application.delete_env(:fake_mdns, :table_pid)
      Process.exit(old, :kill)

      refute_receive {:mdns, _, _}, 150
      assert sync(adv).retry_timer != nil

      send(adv, :retry)
      assert calls(3) == @register
    end

    test "supervisor shutdown mid-registration still withdraws, within a finite budget" do
      adv_spec = Supervisor.child_spec({Advertiser, name: nil}, [])
      assert adv_spec.shutdown > 5_000
      assert is_integer(adv_spec.shutdown)

      Application.put_env(:fake_mdns, :delay_ms, 50)
      id = {:zw_adv_slow, System.unique_integer()}

      adv =
        start_supervised!(
          {Advertiser,
           name: nil,
           mdns_module: FakeMdns,
           config_fun: fn -> @config end,
           table_fun: fn -> nil end},
          id: id
        )

      Advertiser.advertise(adv)
      # The shutdown signal queues behind the cast; registration (3 slow
      # calls) completes, then terminate/2 withdraws (2 more).
      :ok = stop_supervised(id)

      assert calls(5) == @register ++ @withdraw
    end

    test "a table owner going down after a withdraw is ignored" do
      table = spawn_table()
      Application.put_env(:fake_mdns, :table_pid, table)
      on_exit(fn -> Application.delete_env(:fake_mdns, :table_pid) end)

      adv = start_advertiser!()
      {pid, _fake, _id} = start_mdns_proxy!(adv)
      assert calls(3) == @register
      send(pid, {:circuits_uart, "ttyMdns", {:error, :eio}})
      assert calls(2) == @withdraw

      Process.exit(table, :kill)

      sync(adv)
      refute_receive {:mdns, _, _}, 50
    end
  end

  describe "callbacks tolerate a dead/missing server" do
    setup do
      {:ok, pid} = ZWaveProxy.start_link(name: nil, port_path: nil)
      ref = Process.monitor(pid)
      GenServer.stop(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
      {:ok, dead: pid}
    end

    test "available? returns false", %{dead: pid} do
      refute ZWaveProxy.available?(pid)
    end

    test "home_id returns 0", %{dead: pid} do
      assert ZWaveProxy.home_id(pid) == 0
    end

    test "subscribe returns {:error, :unavailable}", %{dead: pid} do
      assert {:error, :unavailable} = ZWaveProxy.subscribe(pid, self())
    end

    test "unsubscribe returns :ok (idempotent)", %{dead: pid} do
      assert :ok = ZWaveProxy.unsubscribe(pid, self())
    end

    test "send_frame returns {:error, :unavailable}", %{dead: pid} do
      assert {:error, :unavailable} = ZWaveProxy.send_frame(pid, <<1>>)
    end
  end
end
