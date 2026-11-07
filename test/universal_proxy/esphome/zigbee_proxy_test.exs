defmodule UniversalProxy.ESPHome.ZigbeeProxyTest do
  # Each test gets its own unnamed proxy holding a FakeUART instead of a
  # tty. async: false: several tests assert on the global
  # uart:port_opened/uart:port_closed PubSub topics.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias UniversalProxy.ESPHome.ZigbeeProxy
  alias UniversalProxy.ESPHome.ZigbeeProxy.{Ash, FakeUART}

  @pubsub UniversalProxy.PubSub

  hex = fn s -> s |> String.replace(" ", "") |> Base.decode16!() end

  # Wire bytes from the ESPHome ezsp_proxy_tap unit tests (ash_test.exs).
  @data_0 hex.("00 43 21 A8 50 9B 98 7E")
  @data_1 hex.("10 43 21 A8 50 9F C2 7E")
  @data_5 hex.("50 43 21 A8 50 8E AA 7E")

  # Every open starts a fresh FakeUART (a reopen after cleanup needs a
  # live one), linked to the proxy as Circuits.UART.start_link/0 is.
  defp start_proxy!(opts \\ []) do
    test_pid = self()
    name = "zb-#{System.unique_integer([:positive])}"
    port = %{kind: :zigbee, tty_name: "ttyZB", ha_name: name}

    resolver =
      Keyword.get(opts, :resolver, fn -> %{path: "ttyZB", display_name: name, port: port} end)

    open_fun = fn _path ->
      {:ok, fake} = FakeUART.start_link(test_pid)
      send(test_pid, {:fake_uart, fake})
      {:ok, fake}
    end

    server =
      start_supervised!(
        {ZigbeeProxy, name: nil, resolver: resolver, open_fun: open_fun},
        id: {:zb, System.unique_integer()}
      )

    assert_receive {:fake_uart, fake}
    %{server: server, fake: fake, name: name, port: port}
  end

  defp attach!(server, subscriber \\ self()) do
    {:ok, ref} = ZigbeeProxy.attach(server, [], subscriber)
    ref
  end

  defp subscribed!(server, mode \\ :raw) do
    ref = attach!(server)
    :ok = ZigbeeProxy.subscribe(server, ref)
    if mode == :protocol, do: :ok = ZigbeeProxy.set_mode(server, ref, :protocol)
    ref
  end

  # Poll for a condition the proxy reaches asynchronously (e.g. after a
  # monitored process dies); bounded so a regression fails, not hangs.
  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not reached")
      true -> Process.sleep(10) && wait_until(fun, attempts - 1)
    end
  end

  # Deliver NCP bytes and wait until the proxy has handled them.
  defp rx(server, data) do
    send(server, {:circuits_uart, "ttyZB", data})
    _ = :sys.get_state(server)
    :ok
  end

  defp ack(n), do: Ash.ack_frame(n)

  defp pushes(acc \\ []) do
    receive do
      {:pushed, attached?} -> pushes([attached? | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  defp wait_open(gate) do
    if Agent.get(gate, & &1) == :open, do: :ok, else: Process.sleep(5) && wait_open(gate)
  end

  # All UART writes received so far, concatenated.
  defp written(acc \\ <<>>) do
    receive do
      {:uart_write, data} -> written(acc <> data)
    after
      0 -> acc
    end
  end

  describe "without a ZBT-2" do
    test "idles, reports detached, and answers :not_attached" do
      server = start_supervised!({ZigbeeProxy, name: nil, resolver: fn -> nil end})

      assert ZigbeeProxy.status(server) == %{attached?: false, error?: false, port: nil}
      assert {:error, :not_attached} = ZigbeeProxy.attach(server, [], self())
      assert ZigbeeProxy.current_opts(server)[:speed] == 460_800
      assert :sys.get_state(server).reopen_timer != nil
    end

    test "the rescan attaches a port that appears later" do
      {:ok, fake} = FakeUART.start_link(self())
      {:ok, slot} = Agent.start_link(fn -> nil end)
      Phoenix.PubSub.subscribe(@pubsub, "uart:port_opened")

      server =
        start_supervised!(
          {ZigbeeProxy,
           name: nil,
           resolver: fn -> Agent.get(slot, & &1) end,
           open_fun: fn _path -> {:ok, fake} end}
        )

      refute ZigbeeProxy.status(server).attached?

      Agent.update(slot, fn _ -> %{path: "ttyLate", display_name: "late-zb"} end)
      send(server, :zigbee_reopen)

      assert_receive {:uart_port_opened, %{friendly_name: "late-zb", owner: :zigbee_proxy}}
      assert %{attached?: true, port: nil} = ZigbeeProxy.status(server)
    end

    test "a row resolved after an empty init is held but never advertised" do
      {:ok, fake} = FakeUART.start_link(self())
      {:ok, slot} = Agent.start_link(fn -> nil end)
      row = %{kind: :zigbee, tty_name: "ttyLate", ha_name: "late"}

      server =
        start_supervised!(
          {ZigbeeProxy,
           name: nil,
           resolver: fn -> Agent.get(slot, & &1) end,
           open_fun: fn _path -> {:ok, fake} end}
        )

      Agent.update(slot, fn _ -> %{path: "ttyLate", display_name: "late", port: row} end)
      send(server, :zigbee_reopen)
      _ = :sys.get_state(server)

      assert %{attached?: true, port: nil} = ZigbeeProxy.advertised(server)
      assert %{attached?: true, port: nil} = ZigbeeProxy.status(server)
    end

    test "after an unplug a resolver returning nil never reopens the old tty" do
      test_pid = self()
      {:ok, slot} = Agent.start_link(fn -> %{path: "ttyZB", display_name: "zb"} end)

      open_fun = fn path ->
        send(test_pid, {:open_attempt, path})
        {:ok, fake} = FakeUART.start_link(test_pid)
        {:ok, fake}
      end

      server =
        start_supervised!(
          {ZigbeeProxy, name: nil, resolver: fn -> Agent.get(slot, & &1) end, open_fun: open_fun}
        )

      assert_receive {:open_attempt, "ttyZB"}
      assert ZigbeeProxy.status(server).attached?

      Agent.update(slot, fn _ -> nil end)
      send(server, {:circuits_uart, "ttyZB", {:error, :eio}})
      assert %{attached?: false, port: nil} = ZigbeeProxy.status(server)

      send(server, :zigbee_reopen)
      assert :sys.get_state(server).display_name == nil
      refute_received {:open_attempt, _}
      refute ZigbeeProxy.status(server).attached?
    end

    test "cleanup completes and the proxy reopens when the UART close exits" do
      %{server: server, fake: fake} = start_proxy!()
      FakeUART.reply_with(fake, :close, :exit)
      ref = Process.monitor(fake)

      send(server, {:circuits_uart, "ttyZB", {:error, :eio}})
      assert_receive :uart_close
      assert_receive {:DOWN, ^ref, :process, ^fake, _}
      assert %{attached?: false, error?: true} = ZigbeeProxy.status(server)

      send(server, :zigbee_reopen)
      assert_receive {:fake_uart, _new}
      assert ZigbeeProxy.status(server).attached?
    end

    test "messages from another tty are ignored" do
      %{server: server} = start_proxy!()
      subscribed!(server)

      send(server, {:circuits_uart, "ttyOLD", "stale"})
      send(server, {:circuits_uart, "ttyOLD", {:error, :eio}})
      _ = :sys.get_state(server)

      assert ZigbeeProxy.status(server).attached?
      refute_received {:espex_serial_data, _, _}
    end

    test "a failed open reports error? and keeps the row" do
      port = %{kind: :zigbee, tty_name: "ttyBad", ha_name: "bad"}

      server =
        start_supervised!(
          {ZigbeeProxy,
           name: nil,
           resolver: fn -> %{path: "ttyBad", display_name: "bad", port: port} end,
           open_fun: fn _path -> {:error, :eacces} end}
        )

      assert ZigbeeProxy.status(server) == %{attached?: false, error?: true, port: port}
    end
  end

  describe "open and status" do
    test "broadcasts port_opened with owner: :zigbee_proxy and reports the row" do
      Phoenix.PubSub.subscribe(@pubsub, "uart:port_opened")
      %{server: server, name: name, port: port} = start_proxy!()

      assert_receive {:uart_port_opened, %{friendly_name: ^name, owner: :zigbee_proxy}}
      assert ZigbeeProxy.status(server) == %{attached?: true, error?: false, port: port}

      assert ZigbeeProxy.current_opts(server) ==
               [speed: 460_800, data_bits: 8, stop_bits: 1, parity: :none, flow_control: :none]
    end

    test "modem lines start asserted" do
      %{server: server} = start_proxy!()
      ref = attach!(server)
      assert {:ok, %{rts: true, dtr: true}} = ZigbeeProxy.get_modem_pins(server, ref)
    end

    test "claimed_port reports the held tty and whether a session is subscribed" do
      %{server: server, name: name} = start_proxy!()
      base = %{tty_name: "ttyZB", display_name: name, subscribed: false}

      assert ZigbeeProxy.claimed_port(server) == base
      ref = attach!(server)
      :ok = ZigbeeProxy.subscribe(server, ref)
      assert ZigbeeProxy.claimed_port(server) == %{base | subscribed: true}
      :ok = ZigbeeProxy.detach(server, ref)
      assert ZigbeeProxy.claimed_port(server) == base
    end

    test "advertised follows open, a UART error and an unplug, keeping the row" do
      slot = start_supervised!({Agent, fn -> nil end})
      %{server: server, port: port} = start_proxy!()
      _ = :sys.get_state(server)

      assert ZigbeeProxy.advertised(server) == %{attached?: true, error?: false, port: port}

      send(server, {:circuits_uart, "ttyZB", {:error, :eio}})
      _ = :sys.get_state(server)
      assert ZigbeeProxy.advertised(server) == %{attached?: false, error?: true, port: port}

      :sys.replace_state(server, fn state ->
        %{state | resolver: fn -> Agent.get(slot, & &1) end}
      end)

      send(server, :zigbee_reopen)
      _ = :sys.get_state(server)
      assert ZigbeeProxy.advertised(server) == %{attached?: false, error?: false, port: port}
      assert {:error, :not_attached} = ZigbeeProxy.attach(server, [], self())

      # The stick back on another tty: its row replaces the kept one.
      moved = %{port | tty_name: "ttyZB2"}
      Agent.update(slot, fn _ -> %{path: "ttyZB2", display_name: "zb2", port: moved} end)
      send(server, :zigbee_reopen)
      assert_receive {:fake_uart, _fake}
      _ = :sys.get_state(server)
      assert ZigbeeProxy.advertised(server) == %{attached?: true, error?: false, port: moved}
    end

    test "a re-resolved row with another HA name does not replace the advertised one" do
      %{server: server, port: port} = start_proxy!()
      _ = :sys.get_state(server)

      send(server, {:circuits_uart, "ttyZB", {:error, :eio}})
      _ = :sys.get_state(server)

      other = %{port | ha_name: "other"}

      :sys.replace_state(server, fn state ->
        %{state | resolver: fn -> %{path: "ttyZB", display_name: "o", port: other} end}
      end)

      send(server, :zigbee_reopen)
      assert_receive {:fake_uart, _fake}
      _ = :sys.get_state(server)
      assert %{attached?: true, port: ^port} = ZigbeeProxy.advertised(server)
    end

    test "advertised already holds the row while the first open is blocked" do
      test_pid = self()
      port = %{kind: :zigbee, tty_name: "ttyZB", ha_name: "zb"}

      open_fun = fn _path ->
        send(test_pid, {:open_blocked, self()})

        receive do
          :release -> {:error, :eacces}
        end
      end

      server =
        start_supervised!(
          {ZigbeeProxy,
           name: nil,
           resolver: fn -> %{path: "ttyZB", display_name: "zb", port: port} end,
           open_fun: open_fun}
        )

      assert_receive {:open_blocked, opener}
      assert ZigbeeProxy.advertised(server) == %{attached?: false, error?: false, port: port}
      send(opener, :release)
    end

    test "on_change runs when the attach state or row changes, and only then" do
      test_pid = self()
      port = %{kind: :zigbee, tty_name: "ttyZB", ha_name: "zb"}
      opens = :counters.new(1, [])

      # The first open succeeds, every reopen fails the same way.
      open_fun = fn _path ->
        :counters.add(opens, 1, 1)

        if :counters.get(opens, 1) == 1 do
          FakeUART.start_link(test_pid)
        else
          {:error, :eio}
        end
      end

      server =
        start_supervised!(
          {ZigbeeProxy,
           name: nil,
           resolver: fn -> %{path: "ttyZB", display_name: "zb", port: port} end,
           open_fun: open_fun,
           on_change: fn -> send(test_pid, {:zigbee_changed, self()}) end}
        )

      # Off the owner, in a task.
      assert_receive {:zigbee_changed, pid}
      assert pid != server

      rx(server, "data")
      refute_receive {:zigbee_changed, _}, 50

      send(server, {:circuits_uart, "ttyZB", {:error, :eio}})
      assert_receive {:zigbee_changed, _}

      send(server, :zigbee_reopen)
      _ = :sys.get_state(server)
      assert %{attached?: false, error?: true, port: ^port} = ZigbeeProxy.advertised(server)
      refute_receive {:zigbee_changed, _}, 50
    end

    test "pushes run one at a time, so the last one delivers the latest state" do
      test_pid = self()
      gate = start_supervised!({Agent, fn -> :closed end})
      calls = :counters.new(1, [])
      name = :"zb_order_#{System.unique_integer([:positive])}"

      # Reads the snapshot, then (first call only) waits for the test
      # before delivering, as a slow push to espex would.
      on_change = fn ->
        snapshot = ZigbeeProxy.advertised(name)
        :counters.add(calls, 1, 1)

        if :counters.get(calls, 1) == 1 do
          send(test_pid, :push_blocked)
          wait_open(gate)
        end

        send(test_pid, {:pushed, snapshot.attached?})
      end

      open_fun = fn _path ->
        {:ok, fake} = FakeUART.start_link(test_pid)
        send(test_pid, {:fake_uart, fake})
        {:ok, fake}
      end

      server =
        start_supervised!(
          {ZigbeeProxy,
           name: name,
           resolver: fn -> %{path: "ttyZB", display_name: "zb", port: %{ha_name: "zb"}} end,
           open_fun: open_fun,
           on_change: on_change}
        )

      assert_receive :push_blocked
      send(server, {:circuits_uart, "ttyZB", {:error, :eio}})
      _ = :sys.get_state(server)
      send(server, :zigbee_reopen)
      assert_receive {:fake_uart, _}
      send(server, {:circuits_uart, "ttyZB", {:error, :eio}})
      _ = :sys.get_state(server)

      Agent.update(gate, fn _ -> :open end)

      # The blocked push (the open) delivers first, then one coalesced
      # push of the final, detached state.
      assert pushes() == [true, false]
      assert :counters.get(calls, 1) == 2
    end

    test "the pusher stops with the owner" do
      server =
        start_supervised!(
          {ZigbeeProxy, name: nil, resolver: fn -> nil end, on_change: fn -> :ok end}
        )

      {pusher, _fun} = :sys.get_state(server).pusher
      ref = Process.monitor(pusher)

      GenServer.stop(server)
      assert_receive {:DOWN, ^ref, :process, ^pusher, _}
    end

    test "claimed_port is nil without a tty or a server" do
      server = start_supervised!({ZigbeeProxy, name: nil, resolver: fn -> nil end})
      assert ZigbeeProxy.claimed_port(server) == nil
      assert ZigbeeProxy.claimed_port(:no_such_zigbee_proxy) == nil
    end
  end

  describe "sessions" do
    test "multiple sessions; only one may subscribe" do
      %{server: server} = start_proxy!()
      a = attach!(server)
      b = attach!(server)

      assert :ok = ZigbeeProxy.subscribe(server, a)
      assert :ok = ZigbeeProxy.subscribe(server, a)
      assert {:error, :port_in_use} = ZigbeeProxy.subscribe(server, b)

      :ok = ZigbeeProxy.unsubscribe(server, a)
      assert :ok = ZigbeeProxy.subscribe(server, b)
    end

    test "an unknown session is refused" do
      %{server: server} = start_proxy!()
      assert {:error, :unknown_session} = ZigbeeProxy.subscribe(server, make_ref())
      assert {:error, :unknown_session} = ZigbeeProxy.configure(server, make_ref(), [])
      assert {:error, :unknown_session} = ZigbeeProxy.get_modem_pins(server, make_ref())
      assert :ok = ZigbeeProxy.detach(server, make_ref())
      assert :ok = ZigbeeProxy.unsubscribe(server, make_ref())
    end

    test "RX goes to the subscriber with the session's handle" do
      %{server: server} = start_proxy!()
      ref = subscribed!(server)

      rx(server, "hello")
      assert_receive {:espex_serial_data, {:zigbee, ^ref}, "hello"}
    end

    test "detach never closes the tty" do
      %{server: server} = start_proxy!()
      ref = subscribed!(server)

      assert :ok = ZigbeeProxy.detach(server, ref)
      refute_receive :uart_close, 50
      assert ZigbeeProxy.status(server).attached?
      assert {:ok, _} = ZigbeeProxy.attach(server, [], self())
    end

    test "subscriber death detaches the session and forces RAW" do
      %{server: server} = start_proxy!()
      sub = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, ref} = ZigbeeProxy.attach(server, [], sub)
      :ok = ZigbeeProxy.subscribe(server, ref)
      :ok = ZigbeeProxy.set_mode(server, ref, :protocol)

      sub_ref = Process.monitor(sub)
      Process.exit(sub, :kill)
      assert_receive {:DOWN, ^sub_ref, :process, ^sub, _}
      wait_until(fn -> :sys.get_state(server).sessions == %{} end)

      # A new subscriber can take the port, and starts in RAW: no ACK.
      ref2 = subscribed!(server)
      assert ref2 != ref
      rx(server, @data_0)
      assert_receive {:espex_serial_data, {:zigbee, ^ref2}, @data_0}
      refute_receive {:uart_write, _}, 50
    end

    test "a dead subscriber whose :DOWN is still queued is taken over" do
      %{server: server} = start_proxy!()
      old = make_ref()
      dead = spawn(fn -> :ok end)
      ref_down = Process.monitor(dead)
      assert_receive {:DOWN, ^ref_down, :process, ^dead, _}

      # A subscribed session whose :DOWN the proxy hasn't handled yet.
      :sys.replace_state(server, fn state ->
        %{
          state
          | sessions: Map.put(state.sessions, old, %{pid: dead, monitor: make_ref()}),
            subscribed: old
        }
      end)

      new = attach!(server)
      assert :ok = ZigbeeProxy.subscribe(server, new)
      refute Map.has_key?(:sys.get_state(server).sessions, old)
    end

    test "write: only the subscribed session; mirrored as :tx" do
      %{server: server, name: name} = start_proxy!()
      Phoenix.PubSub.subscribe(@pubsub, "uart:#{name}")
      other = attach!(server)
      ref = subscribed!(server)

      assert :ok = ZigbeeProxy.write(server, ref, ["ab", ?c])
      assert_receive {:uart_write, "abc"}
      assert_receive {:uart_data, %{name: ^name, dir: :tx, data: "abc"}}

      assert {:error, :port_in_use} = ZigbeeProxy.write(server, other, "x")
      refute_receive {:uart_write, "x"}, 50
    end
  end

  describe "ASH tap semantics (ash-test-vectors.md §6)" do
    test "T1: a subscribed session without set_mode is RAW: no ACK" do
      %{server: server} = start_proxy!()
      ref = subscribed!(server)

      rx(server, @data_0)
      assert_receive {:espex_serial_data, {:zigbee, ^ref}, @data_0}
      refute_receive {:uart_write, _}, 50
    end

    test "T2: PROTOCOL ACKs before forwarding and still delivers the original bytes" do
      %{server: server, name: name} = start_proxy!()
      Phoenix.PubSub.subscribe(@pubsub, "uart:#{name}")
      ref = subscribed!(server, :protocol)

      rx(server, @data_0)

      ack1 = ack(1)
      assert ack1 == <<0x7E, 0x81, 0x60, 0x59, 0x7E>>

      # The ACK reaches the wire first, then the subscriber.
      receive do
        {:uart_write, ^ack1} -> :ok
        {:espex_serial_data, {:zigbee, ^ref}, _} -> flunk("RX forwarded before the ACK write")
      after
        1_000 -> flunk("no ACK write")
      end

      assert_receive {:espex_serial_data, {:zigbee, ^ref}, @data_0}

      assert_receive {:uart_data, %{dir: :rx, data: @data_0}}
      assert_receive {:uart_data, %{dir: :tx, data: ^ack1, origin: :ash_ack}}
    end

    test "ACK writes use a short timeout; client writes keep the long one" do
      %{server: server} = start_proxy!()
      ref = subscribed!(server, :protocol)

      rx(server, @data_0)
      assert_receive {:uart_write_timeout, ack_timeout}
      assert ack_timeout <= 250

      :ok = ZigbeeProxy.write(server, ref, <<1, 2, 3>>)
      assert_receive {:uart_write_timeout, write_timeout}
      assert write_timeout >= 1_000
    end

    test "T3: RAW stops ACKs; re-enabling PROTOCOL resets the numbering" do
      %{server: server} = start_proxy!()
      ref = subscribed!(server, :protocol)

      rx(server, @data_0)
      assert written() == ack(1)

      :ok = ZigbeeProxy.set_mode(server, ref, :raw)
      rx(server, @data_1)
      assert written() == <<>>

      :ok = ZigbeeProxy.set_mode(server, ref, :protocol)
      rx(server, @data_5)
      assert written() == ack(6)
    end

    test "PROTOCOL → PROTOCOL does not reset" do
      %{server: server} = start_proxy!()
      ref = subscribed!(server, :protocol)

      rx(server, @data_0)
      assert written() == ack(1)
      :ok = ZigbeeProxy.set_mode(server, ref, :protocol)
      # Still in sequence after DATA_0, so DATA_5 is out of sequence: no ACK.
      rx(server, @data_5)
      assert written() == <<>>
      rx(server, @data_1)
      assert written() == ack(2)
    end

    test "T4: resubscribing forces RAW; set_mode then resets" do
      %{server: server} = start_proxy!()
      ref = subscribed!(server, :protocol)
      rx(server, @data_0)
      assert written() == ack(1)

      :ok = ZigbeeProxy.unsubscribe(server, ref)
      :ok = ZigbeeProxy.subscribe(server, ref)
      rx(server, @data_5)
      assert written() == <<>>

      :ok = ZigbeeProxy.set_mode(server, ref, :protocol)
      rx(server, @data_5)
      assert written() == ack(6)
    end

    test "T5: a disconnect resets the acker but keeps the subscriber and mode" do
      Phoenix.PubSub.subscribe(@pubsub, "uart:port_closed")
      %{server: server, name: name} = start_proxy!()
      ref = subscribed!(server, :protocol)
      rx(server, @data_0)
      assert written() == ack(1)

      send(server, {:circuits_uart, "ttyZB", {:error, :eio}})
      assert_receive {:uart_port_closed, %{friendly_name: ^name, owner: :zigbee_proxy}}

      assert %{attached?: false, error?: true} = ZigbeeProxy.status(server)
      assert {:error, :not_attached} = ZigbeeProxy.write(server, ref, "x")
      assert {:error, :not_attached} = ZigbeeProxy.configure(server, ref, speed: 115_200)
      assert {:error, :not_attached} = ZigbeeProxy.set_modem_pins(server, ref, false, false)
      assert {:error, :not_attached} = ZigbeeProxy.get_modem_pins(server, ref)

      send(server, :zigbee_reopen)
      assert ZigbeeProxy.status(server).attached?

      rx(server, @data_5)
      assert written() == ack(6)
      assert_receive {:espex_serial_data, {:zigbee, ^ref}, @data_5}
    end

    test "T6: with no subscriber nothing is ACKed" do
      %{server: server} = start_proxy!()
      _session = attach!(server)

      rx(server, @data_0)
      refute_receive {:uart_write, _}, 50
    end

    test "T7: a half frame seen before RAW cannot corrupt the next PROTOCOL frame" do
      %{server: server} = start_proxy!()
      ref = subscribed!(server, :protocol)

      <<head::binary-size(4), tail::binary>> = @data_0
      rx(server, head)
      :ok = ZigbeeProxy.set_mode(server, ref, :raw)
      rx(server, tail)
      :ok = ZigbeeProxy.set_mode(server, ref, :protocol)
      rx(server, @data_5)

      assert written() == ack(6)
    end

    test "T8: chunking does not change the ACK stream; one write per chunk" do
      %{server: server} = start_proxy!()
      subscribed!(server, :protocol)

      rx(server, @data_0 <> @data_1)
      assert_receive {:uart_write, both}
      assert both == ack(1) <> ack(2)

      %{server: server2} = start_proxy!()
      subscribed!(server2, :protocol)
      for <<byte <- @data_0 <> @data_1>>, do: rx(server2, <<byte>>)
      assert written() == ack(1) <> ack(2)
    end

    test "T9: set_mode by a non-subscriber is :port_in_use and changes nothing" do
      %{server: server} = start_proxy!()
      ref = subscribed!(server)
      other = attach!(server)

      assert {:error, :port_in_use} = ZigbeeProxy.set_mode(server, other, :protocol)
      rx(server, @data_0)
      assert_receive {:espex_serial_data, {:zigbee, ^ref}, @data_0}
      refute_receive {:uart_write, _}, 50
    end

    test "an unknown mode is :invalid_argument" do
      %{server: server} = start_proxy!()
      ref = subscribed!(server)
      assert {:error, :invalid_argument} = ZigbeeProxy.set_mode(server, ref, :bogus)
    end
  end

  describe "inter-session RX buffer" do
    test "bytes with no subscriber are delivered on the next subscribe" do
      %{server: server} = start_proxy!()
      ref = attach!(server)

      rx(server, "abc")
      rx(server, "def")
      refute_receive {:espex_serial_data, _, _}, 20

      :ok = ZigbeeProxy.subscribe(server, ref)
      assert_receive {:espex_serial_data, {:zigbee, ^ref}, "abcdef"}

      rx(server, "g")
      assert_receive {:espex_serial_data, {:zigbee, ^ref}, "g"}
    end

    test "overflow keeps the newest 256 bytes" do
      %{server: server} = start_proxy!()
      ref = attach!(server)

      data = :binary.copy(<<1>>, 200) <> :binary.copy(<<2>>, 100)
      rx(server, binary_part(data, 0, 150))
      rx(server, binary_part(data, 150, 150))

      :ok = ZigbeeProxy.subscribe(server, ref)
      assert_receive {:espex_serial_data, _, buffered}
      assert buffered == binary_part(data, 44, 256)
    end

    test "a disconnect empties it" do
      %{server: server} = start_proxy!()
      ref = attach!(server)
      rx(server, "stale")

      send(server, {:circuits_uart, "ttyZB", {:error, :eio}})
      send(server, :zigbee_reopen)
      :ok = ZigbeeProxy.subscribe(server, ref)
      refute_receive {:espex_serial_data, _, _}, 50
    end
  end

  describe "line settings" do
    test "settings equal to the live ones issue no ioctl" do
      %{server: server} = start_proxy!()
      ref = attach!(server)
      live = ZigbeeProxy.current_opts(server)

      assert {:ok, _} = ZigbeeProxy.attach(server, live, self())
      assert :ok = ZigbeeProxy.configure(server, ref, live)
      assert :ok = ZigbeeProxy.configure(server, ref, speed: 460_800)
      refute_receive {:uart_configure, _}, 50
    end

    test "a change is exactly one configure; repeating it is a no-op" do
      %{server: server} = start_proxy!()
      ref = attach!(server)

      assert :ok = ZigbeeProxy.configure(server, ref, speed: 115_200, flow_control: :hardware)
      assert_receive {:uart_configure, opts}
      assert opts[:speed] == 115_200 and opts[:flow_control] == :hardware

      assert :ok = ZigbeeProxy.configure(server, ref, speed: 115_200, flow_control: :hardware)
      refute_receive {:uart_configure, _}, 50

      assert ZigbeeProxy.current_opts(server) ==
               [
                 speed: 115_200,
                 data_bits: 8,
                 stop_bits: 1,
                 parity: :none,
                 flow_control: :hardware
               ]
    end

    test "attach applies its opts" do
      %{server: server} = start_proxy!()
      assert {:ok, _} = ZigbeeProxy.attach(server, [speed: 150], self())
      assert_receive {:uart_configure, opts}
      assert opts[:speed] == 150
    end

    test "B0 and bad values are refused without touching the line" do
      %{server: server} = start_proxy!()
      ref = attach!(server)

      assert {:error, :invalid_speed} = ZigbeeProxy.configure(server, ref, speed: 0)
      assert {:error, :invalid_speed} = ZigbeeProxy.attach(server, [speed: -1], self())
      assert {:error, :invalid_argument} = ZigbeeProxy.configure(server, ref, data_bits: 9)
      refute_receive {:uart_configure, _}, 50
      assert map_size(:sys.get_state(server).sessions) == 1
    end

    test "a UART error resets current_opts to the defaults the next open uses" do
      %{server: server} = start_proxy!()
      ref = attach!(server)
      assert :ok = ZigbeeProxy.configure(server, ref, speed: 115_200)
      assert ZigbeeProxy.current_opts(server)[:speed] == 115_200

      send(server, {:circuits_uart, "ttyZB", {:error, :eio}})
      refute ZigbeeProxy.status(server).attached?
      assert ZigbeeProxy.current_opts(server)[:speed] == 460_800
    end

    test "a failed configure keeps the old settings" do
      %{server: server, fake: fake} = start_proxy!()
      ref = attach!(server)
      before = ZigbeeProxy.current_opts(server)
      FakeUART.reply_with(fake, :configure, {:error, :einval})

      assert {:error, :einval} = ZigbeeProxy.configure(server, ref, speed: 57_600)
      assert ZigbeeProxy.current_opts(server) == before
    end
  end

  describe "modem pins" do
    test "unchanged lines are skipped; one changed line is one call" do
      %{server: server} = start_proxy!()
      ref = attach!(server)

      assert :ok = ZigbeeProxy.set_modem_pins(server, ref, true, true)
      refute_receive {:uart_set_dtr, _}, 20
      refute_receive {:uart_set_rts, _}, 20

      assert :ok = ZigbeeProxy.set_modem_pins(server, ref, true, false)
      assert_receive {:uart_set_dtr, false}
      refute_receive {:uart_set_rts, _}, 20
    end

    test "both lines changing sets DTR, then RTS" do
      %{server: server} = start_proxy!()
      ref = attach!(server)

      # The flasher's (dtr 0, rts 1) → (dtr 1, rts 0) step.
      :ok = ZigbeeProxy.set_modem_pins(server, ref, true, false)
      assert_receive {:uart_set_dtr, false}

      assert :ok = ZigbeeProxy.set_modem_pins(server, ref, false, true)
      assert_receive {line, _} = first when line in [:uart_set_dtr, :uart_set_rts]
      assert_receive {line, _} = second when line in [:uart_set_dtr, :uart_set_rts]
      assert [first, second] == [{:uart_set_dtr, true}, {:uart_set_rts, false}]

      assert {:ok, %{rts: false, dtr: true}} = ZigbeeProxy.get_modem_pins(server, ref)
    end

    test "the cache follows only the calls that succeeded" do
      %{server: server, fake: fake} = start_proxy!()
      ref = attach!(server)
      FakeUART.reply_with(fake, :set_rts, {:error, :eio})

      assert {:error, :eio} = ZigbeeProxy.set_modem_pins(server, ref, false, false)
      assert {:ok, %{rts: true, dtr: false}} = ZigbeeProxy.get_modem_pins(server, ref)
    end

    test "a reopen restores DTR=RTS=true" do
      %{server: server} = start_proxy!()
      ref = attach!(server)
      :ok = ZigbeeProxy.set_modem_pins(server, ref, false, false)

      send(server, {:circuits_uart, "ttyZB", {:error, :eio}})
      send(server, :zigbee_reopen)
      assert {:ok, %{rts: true, dtr: true}} = ZigbeeProxy.get_modem_pins(server, ref)
    end
  end

  describe "shutdown and failure" do
    test "terminate/2 closes the tty and broadcasts port_closed" do
      Phoenix.PubSub.subscribe(@pubsub, "uart:port_closed")
      {:ok, fake} = FakeUART.start_link(self())
      id = {:zb_stop, System.unique_integer()}

      start_supervised!(
        {ZigbeeProxy, name: nil, port_path: "/dev/ttyStop", open_fun: fn _ -> {:ok, fake} end},
        id: id
      )

      :ok = stop_supervised(id)
      assert_receive :uart_close
      assert_receive {:uart_port_closed, %{friendly_name: "ttyStop", owner: :zigbee_proxy}}
    end

    test "a crash of the linked UART stops the proxy" do
      test_pid = self()

      open_fun = fn _path ->
        {:ok, fake} = FakeUART.start_link(test_pid)
        send(test_pid, {:fake_uart, fake})
        {:ok, fake}
      end

      server =
        start_supervised!(
          Supervisor.child_spec(
            {ZigbeeProxy, name: nil, port_path: "/dev/ttyCrash", open_fun: open_fun},
            id: {:zb_crash, System.unique_integer()},
            restart: :temporary
          )
        )

      assert_receive {:fake_uart, fake}
      ref = Process.monitor(server)
      Process.exit(fake, :kill)
      assert_receive {:DOWN, ^ref, :process, ^server, :killed}, 1_000
    end

    test "a wedged server answers :timeout, not 'not attached'" do
      %{server: server} = start_proxy!()
      ref = attach!(server)
      :ok = :sys.suspend(server)

      try do
        assert {:error, :timeout} = ZigbeeProxy.attach(server, [], self())
        assert {:error, :timeout} = ZigbeeProxy.set_modem_pins(server, ref, true, true)
        assert %{error?: true, attached?: false} = ZigbeeProxy.status(server)
      after
        :sys.resume(server)
      end

      # The timed-out attach ran after resume; its cast detach follows it.
      assert %{sessions: sessions} = :sys.get_state(server)
      assert Map.keys(sessions) == [ref]
    end

    test "a dead server answers the defaults" do
      {:ok, pid} = ZigbeeProxy.start_link(name: nil)
      GenServer.stop(pid)
      ref = make_ref()

      assert {:error, :not_attached} = ZigbeeProxy.attach(pid, [], self())
      assert {:error, :not_attached} = ZigbeeProxy.subscribe(pid, ref)
      assert {:error, :not_attached} = ZigbeeProxy.write(pid, ref, "x")
      assert {:error, :not_attached} = ZigbeeProxy.set_mode(pid, ref, :raw)
      assert :ok = ZigbeeProxy.detach(pid, ref)
      assert :ok = ZigbeeProxy.unsubscribe(pid, ref)
      assert ZigbeeProxy.status(pid) == %{attached?: false, error?: false, port: nil}
      assert ZigbeeProxy.current_opts(pid)[:speed] == 460_800
    end
  end
end
