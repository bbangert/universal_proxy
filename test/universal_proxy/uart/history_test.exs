defmodule UniversalProxy.UART.HistoryTest do
  @moduledoc """
  Exercises the bounded ring buffer + atomic subscribe/snapshot
  semantics of `UniversalProxy.UART.History`. Each test starts a fresh
  named instance so we don't fight the application-tree singleton for
  state.

  Frames are injected via `Phoenix.PubSub.broadcast/3` on the per-port
  topic, matching the real `UART.Server` broadcast shape.
  """
  # `async: false` because the packet-rate test subscribes to a
  # process-wide PubSub topic (`History.packet_rate_topic/0`) that
  # *every* live History instance broadcasts on every second. Pinning
  # the module to serial keeps test-spawned Histories from poisoning
  # each other's mailboxes. The per-instance `auto_tick: false` below
  # silences the wall-clock timer so only injected ticks fire.
  use ExUnit.Case, async: false

  alias UniversalProxy.UART.History

  @pubsub UniversalProxy.PubSub

  setup do
    name = :"history_#{System.unique_integer([:positive])}"
    {:ok, pid} = History.start_link(name: name, auto_tick: false)
    %{server: name, pid: pid}
  end

  # GenServer.call drains the mailbox up to that point synchronously,
  # so this is enough to flush a broadcast into history's state.
  defp drain(server), do: :sys.get_state(server)

  defp publish(friendly_name, data, dir) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      "uart:#{friendly_name}",
      {:uart_data, %{name: friendly_name, data: data, timestamp: DateTime.utc_now(), dir: dir}}
    )
  end

  defp publish_open(friendly_name) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      "uart:port_opened",
      {:uart_port_opened, %{path: "/dev/null", friendly_name: friendly_name}}
    )
  end

  test "snapshot is empty before any frames", %{server: server} do
    assert [] == History.subscribe_and_snapshot(server)
  end

  test "frames published after port_opened land in the buffer and snapshot", %{server: server} do
    name = "port-#{System.unique_integer([:positive])}"

    publish_open(name)
    drain(server)

    publish(name, "hello", :rx)
    publish(name, "world", :tx)
    drain(server)

    snapshot = History.subscribe_and_snapshot(server)
    assert [%{data: "hello", dir: :rx}, %{data: "world", dir: :tx}] = snapshot
    # Frame ids are monotonic, oldest-first.
    [a, b] = snapshot
    assert a.id < b.id
  end

  test "subscribe_and_snapshot delivers exactly-once: snapshot OR live, never both",
       %{server: server} do
    name = "port-#{System.unique_integer([:positive])}"
    publish_open(name)
    drain(server)

    publish(name, "before-subscribe", :rx)
    drain(server)

    snapshot = History.subscribe_and_snapshot(server)
    assert [%{data: "before-subscribe"}] = snapshot

    # Nothing in our mailbox yet — the pre-subscribe frame was only in
    # the snapshot, never forwarded.
    refute_receive {:uart_history_frame, _}, 50

    publish(name, "after-subscribe", :rx)

    assert_receive {:uart_history_frame, %{data: "after-subscribe", dir: :rx}}, 200
    # The "before-subscribe" frame did not arrive again as a live forward.
    refute_receive {:uart_history_frame, %{data: "before-subscribe"}}, 50
  end

  test "buffer caps at 100 frames per port", %{server: server} do
    name = "port-#{System.unique_integer([:positive])}"
    publish_open(name)
    drain(server)

    for i <- 1..120, do: publish(name, "f#{i}", :rx)
    drain(server)

    snapshot = History.subscribe_and_snapshot(server)
    assert length(snapshot) == 100

    # Oldest retained should be f21 (1..20 evicted); newest f120.
    [first | _] = snapshot
    [last] = Enum.take(snapshot, -1)
    assert first.data == "f21"
    assert last.data == "f120"
  end

  test "caps apply per port, not globally", %{server: server} do
    a = "port-a-#{System.unique_integer([:positive])}"
    b = "port-b-#{System.unique_integer([:positive])}"

    publish_open(a)
    publish_open(b)
    drain(server)

    for i <- 1..110, do: publish(a, "a#{i}", :rx)
    for i <- 1..110, do: publish(b, "b#{i}", :tx)
    drain(server)

    snapshot = History.subscribe_and_snapshot(server)
    # 100 per port × 2 ports
    assert length(snapshot) == 200

    by_name = Enum.group_by(snapshot, & &1.name)
    assert length(by_name[a]) == 100
    assert length(by_name[b]) == 100
  end

  test "buffer survives port_closed (history retained after disconnect)", %{server: server} do
    name = "port-#{System.unique_integer([:positive])}"
    publish_open(name)
    drain(server)

    publish(name, "before-close", :rx)
    drain(server)

    Phoenix.PubSub.broadcast(
      @pubsub,
      "uart:port_closed",
      {:uart_port_closed, %{path: "/dev/null", friendly_name: name}}
    )

    drain(server)

    assert [%{data: "before-close"}] = History.subscribe_and_snapshot(server)
  end

  test "eviction spares a port claimed by the Z-Wave proxy" do
    name = :"history_#{System.unique_integer([:positive])}"
    claimed = "ZWA-2 (1-1.1) #{System.unique_integer([:positive])}"

    {:ok, _pid} =
      History.start_link(
        name: name,
        auto_tick: false,
        zwave_claim: fn -> %{tty_name: "ttyACM0", display_name: claimed, subscribed: true} end
      )

    publish_open(claimed)
    drain(name)
    publish(claimed, "zw-frame", :rx)
    drain(name)

    # Fire the delayed eviction directly (the 5-minute grace timer is
    # not test-friendly). The claim must veto it: the Z-Wave port never
    # appears in UART.named_ports/0, so without the claim check this
    # would evict — and unsubscribe — a live port.
    send(name, {:evict_port, claimed})
    drain(name)

    assert [%{data: "zw-frame"}] = History.subscribe_and_snapshot(name)

    # Frames published after the attempted eviction still arrive (the
    # PubSub subscription survived).
    publish(claimed, "still-alive", :rx)
    drain(name)
    assert [_a, %{data: "still-alive"}] = History.subscribe_and_snapshot(name)
  end

  test "eviction proceeds when the Z-Wave proxy holds no (or another) port" do
    name = :"history_#{System.unique_integer([:positive])}"
    port = "gone-port #{System.unique_integer([:positive])}"

    {:ok, _pid} = History.start_link(name: name, auto_tick: false, zwave_claim: fn -> nil end)

    publish_open(port)
    drain(name)
    publish(port, "old-frame", :rx)
    drain(name)

    send(name, {:evict_port, port})
    drain(name)

    assert [] == History.subscribe_and_snapshot(name)
  end

  test "subscriber is dropped when its process dies", %{server: server, pid: history_pid} do
    name = "port-#{System.unique_integer([:positive])}"
    publish_open(name)
    drain(server)

    parent = self()

    sub =
      spawn(fn ->
        _ = History.subscribe_and_snapshot(server)
        send(parent, :subscribed)
        receive do: (:die -> :ok)
      end)

    ref = Process.monitor(sub)
    assert_receive :subscribed, 200

    # Sanity: history sees the subscriber.
    assert %{subscribers: subs} = :sys.get_state(history_pid)
    assert Map.has_key?(subs, sub)

    send(sub, :die)
    assert_receive {:DOWN, ^ref, :process, ^sub, _}, 200

    # Give history a turn to process the :DOWN before checking.
    drain(server)
    assert %{subscribers: %{}} = :sys.get_state(history_pid)
  end

  test "unsubscribe stops live forwarding", %{server: server} do
    name = "port-#{System.unique_integer([:positive])}"
    publish_open(name)
    drain(server)

    _ = History.subscribe_and_snapshot(server)

    publish(name, "first", :rx)
    assert_receive {:uart_history_frame, %{data: "first"}}, 200

    :ok = History.unsubscribe(server)
    drain(server)

    publish(name, "after-unsub", :rx)
    drain(server)
    refute_receive {:uart_history_frame, _}, 50
  end

  test "frames from ports that never had port_opened are dropped", %{server: server} do
    # History only subscribes to ports it sees via `:uart_port_opened`
    # (or open at init). A broadcast on an unsubscribed topic must not
    # land in the buffer.
    name = "never-opened-#{System.unique_integer([:positive])}"

    publish(name, "ghost", :rx)
    drain(server)

    assert [] == History.subscribe_and_snapshot(server)
  end

  # The throughput tick is driven by `:timer.send_interval/3` inside
  # the GenServer; we deliberately bypass the wall clock and inject
  # ticks directly so tests stay deterministic.
  defp tick(server), do: send(GenServer.whereis(server) || server, :throughput_tick)

  test "throughput snapshot starts as a zero-filled 24-sample window", %{server: server} do
    name = "port-#{System.unique_integer([:positive])}"
    samples = History.throughput_subscribe_and_snapshot(server, name)

    assert length(samples) == 24
    assert Enum.all?(samples, &(&1 == {0, 0}))
  end

  test "double subscribe from same pid does not duplicate frame delivery",
       %{server: server} do
    # ensure_subscriber/2 must be idempotent — a second subscribe call
    # from the same pid should NOT create a second monitor or cause the
    # frame to land in our mailbox twice.
    name = "port-#{System.unique_integer([:positive])}"
    publish_open(name)
    drain(server)

    _ = History.subscribe_and_snapshot(server)
    _ = History.subscribe_and_snapshot(server)

    publish(name, "once", :rx)

    assert_receive {:uart_history_frame, %{data: "once"}}, 200
    refute_receive {:uart_history_frame, %{data: "once"}}, 50
  end

  test "double throughput subscribe from same pid does not duplicate tick delivery",
       %{server: server} do
    name = "port-#{System.unique_integer([:positive])}"
    publish_open(name)
    drain(server)

    _ = History.throughput_subscribe_and_snapshot(server, name)
    _ = History.throughput_subscribe_and_snapshot(server, name)

    publish(name, "x", :rx)
    drain(server)
    tick(server)

    assert_receive {:uart_throughput, %{name: ^name}}, 200
    refute_receive {:uart_throughput, %{name: ^name}}, 50
  end

  test "frames arriving before any subscribe still accumulate into the next tick",
       %{server: server} do
    # accumulate_throughput/2 lazily creates a throughput entry on
    # first :uart_data even if no LV has subscribed yet. The tick that
    # follows must commit those bytes into the rolling window so a
    # late subscriber's snapshot reflects real activity.
    name = "port-#{System.unique_integer([:positive])}"
    publish_open(name)
    drain(server)

    for _ <- 1..3, do: publish(name, "abcd", :rx)
    drain(server)
    tick(server)
    drain(server)

    samples = History.throughput_subscribe_and_snapshot(server, name)
    assert [{12, 0} | _] = samples
  end

  test "accumulated bytes roll into the newest sample on tick", %{server: server} do
    name = "port-#{System.unique_integer([:positive])}"
    publish_open(name)
    drain(server)

    _ = History.throughput_subscribe_and_snapshot(server, name)

    publish(name, "hello", :rx)
    publish(name, "hi", :tx)
    drain(server)

    tick(server)

    assert_receive {:uart_throughput, %{name: ^name, samples: [{5, 2} | _]}}, 200
  end

  test "tick rolls the window forward and resets pending counts", %{server: server} do
    name = "port-#{System.unique_integer([:positive])}"
    publish_open(name)
    drain(server)

    _ = History.throughput_subscribe_and_snapshot(server, name)

    publish(name, "abc", :rx)
    drain(server)
    tick(server)

    assert_receive {:uart_throughput, %{samples: [{3, 0} | _]}}, 200

    # No new bytes between ticks → next sample is {0, 0}, prior sample
    # slides one position toward the tail.
    tick(server)

    assert_receive {:uart_throughput, %{samples: [{0, 0}, {3, 0} | _]}}, 200
  end

  test "throughput_unsubscribe stops live delivery", %{server: server} do
    name = "port-#{System.unique_integer([:positive])}"
    publish_open(name)
    drain(server)

    _ = History.throughput_subscribe_and_snapshot(server, name)
    publish(name, "x", :rx)
    drain(server)
    tick(server)
    assert_receive {:uart_throughput, %{name: ^name}}, 200

    :ok = History.throughput_unsubscribe(server, name)
    drain(server)

    publish(name, "y", :rx)
    drain(server)
    tick(server)
    refute_receive {:uart_throughput, _}, 50
  end

  test "snapshot returned by subscribe reflects ticks already rolled in", %{server: server} do
    # A late subscriber (e.g. an LV that just mounted) sees the rolling
    # window as-of subscribe time — no replay of pre-subscribe ticks
    # via PubSub, no double-counting via snapshot.
    name = "port-#{System.unique_integer([:positive])}"
    publish_open(name)
    drain(server)

    # Seed a single sample without any live subscribers.
    publish(name, "abcd", :rx)
    drain(server)
    tick(server)
    drain(server)

    samples = History.throughput_subscribe_and_snapshot(server, name)

    # The {4, 0} sample is now at the head; the rest are still zero.
    assert [{4, 0} | rest] = samples
    assert Enum.all?(rest, &(&1 == {0, 0}))

    # And no live message landed in our mailbox — we only got the snapshot.
    refute_receive {:uart_throughput, _}, 50
  end

  test "packets_per_minute counts RX-only frames across ports", %{server: server} do
    # `packets_per_minute` reflects "frames received". TX frames are
    # broadcast through the same `:uart_data` topic for the Traffic
    # log + per-direction throughput, but they must NOT bump the
    # global counter — otherwise every full-duplex link's rate
    # roughly doubles versus what the device-summary card claims.
    a = "port-a-#{System.unique_integer([:positive])}"
    b = "port-b-#{System.unique_integer([:positive])}"
    publish_open(a)
    publish_open(b)
    drain(server)

    for _ <- 1..3, do: publish(a, "x", :rx)
    for _ <- 1..5, do: publish(b, "y", :tx)
    drain(server)

    assert History.packets_per_minute(server) == 3
  end

  test "single tick broadcasts the current packets/min count", %{server: server} do
    Phoenix.PubSub.subscribe(@pubsub, History.packet_rate_topic())

    name = "port-#{System.unique_integer([:positive])}"
    publish_open(name)
    drain(server)

    for _ <- 1..4, do: publish(name, "x", :rx)
    drain(server)
    tick(server)

    assert_receive {:uart_packet_rate, 4}, 500
  end

  test "packets older than the 60-tick window roll off", %{server: server} do
    # The broadcast is fanned out via `Task.Supervisor` so ordering of
    # arrival messages isn't guaranteed across 60 ticks. State, by
    # contrast, is mutated synchronously inside the tick handler — so
    # we read it back via `packets_per_minute/1` (a `GenServer.call`,
    # which serialises behind any in-flight tick).
    name = "port-#{System.unique_integer([:positive])}"
    publish_open(name)
    drain(server)

    for _ <- 1..4, do: publish(name, "x", :rx)
    drain(server)
    tick(server)
    assert History.packets_per_minute(server) == 4

    for _ <- 1..60, do: tick(server)

    assert History.packets_per_minute(server) == 0
  end

  test "throughput subscriber is dropped when its process dies", %{
    server: server,
    pid: history_pid
  } do
    name = "port-#{System.unique_integer([:positive])}"
    publish_open(name)
    drain(server)

    parent = self()

    sub =
      spawn(fn ->
        _ = History.throughput_subscribe_and_snapshot(server, name)
        send(parent, :subscribed)
        receive do: (:die -> :ok)
      end)

    ref = Process.monitor(sub)
    assert_receive :subscribed, 200

    assert %{throughput_subscribers: subs} = :sys.get_state(history_pid)
    assert Map.has_key?(Map.get(subs, name, %{}), sub)

    send(sub, :die)
    assert_receive {:DOWN, ^ref, :process, ^sub, _}, 200

    drain(server)
    assert %{throughput_subscribers: subs} = :sys.get_state(history_pid)
    refute Map.has_key?(Map.get(subs, name, %{}), sub)
  end
end
