defmodule UniversalProxy.ESPHome.ZWaveProxyTest do
  # Each test gets its own unnamed GenServer (pid only — no atom leakage)
  # and no UART hardware (port_path: nil).
  use ExUnit.Case, async: true

  alias UniversalProxy.ESPHome.ZWaveProxy
  alias UniversalProxy.ESPHome.ZWaveProxy.{Frame, Parser}

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

  setup do
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
    server = Module.concat(__MODULE__, "Server#{System.unique_integer([:positive])}")
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
        [name: nil, open_fun: fn _path -> {:ok, fake} end] ++
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
