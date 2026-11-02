defmodule UniversalProxy.TuyaMesh.PresenceTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.TuyaMesh.{FakeLights, FakeRadio, Presence}

  @a "AA0000000001"
  @b "AA0000000002"
  @c "AA0000000003"

  @min 60_000

  setup do
    clock = start_supervised!({Agent, fn -> 0 end})
    now = fn -> Agent.get(clock, & &1) end
    {:ok, clock: clock, now: now}
  end

  # Ticks only when the test polls; no jitter, no start delay. Started a
  # gap before 0, so the first attempt may go at 0. Every accepted ping
  # airs on the FakeRadio unless `on_ping` (`(mac, radio) -> any`) says
  # otherwise.
  defp start(ctx, opts \\ []) do
    {macs, opts} = Keyword.pop(opts, :macs, [@a, @b, @c])
    {replying, opts} = Keyword.pop(opts, :replying, [])
    {on_ping, opts} = Keyword.pop(opts, :on_ping, fn _mac, radio -> FakeRadio.air(radio) end)
    Agent.update(ctx.clock, fn _ -> -Keyword.get(opts, :min_gap_ms, 30_000) end)

    radio = start_supervised!({FakeRadio, clock: ctx.now}, id: :radio)

    lights =
      start_supervised!(
        {FakeLights,
         macs: macs, replying: replying, clock: ctx.now, on_ping: &on_ping.(&1, radio)},
        id: :lights
      )

    defaults = [
      name: nil,
      lights: lights,
      radio: radio,
      notify: self(),
      clock: ctx.now,
      jitter: fn _ms -> 0 end,
      tick_ms: 3_600_000,
      start_delay_ms: 0
    ]

    presence = start_supervised!({Presence, Keyword.merge(defaults, opts)}, id: :presence)

    Map.merge(ctx, %{
      lights: lights,
      radio: radio,
      presence: presence,
      opts: Keyword.merge(defaults, opts)
    })
  end

  defp at(ctx, ms) do
    Agent.update(ctx.clock, fn _ -> ms end)
    :ok = Presence.poll(ctx.presence)
    ctx
  end

  defp pings(ctx), do: FakeLights.pings(ctx.lights)

  defp bulb(ctx, mac) do
    {:ok, snapshot} = Presence.snapshot(ctx.presence)
    Map.fetch!(snapshot, mac)
  end

  describe "the schedule" do
    test "pings one bulb at a time, the gap apart", ctx do
      ctx = start(ctx)

      at(ctx, 0)
      assert pings(ctx) == [@a]
      assert bulb(ctx, @a).pinging

      # Outstanding: nothing else goes out, even past the reply timeout,
      # until the gap has passed too.
      at(ctx, 5_000)
      at(ctx, 15_000)
      assert pings(ctx) == [@a]
      refute bulb(ctx, @a).pinging
      assert bulb(ctx, @a).misses == 1

      at(ctx, 30_000)
      assert pings(ctx) == [@a, @b]
      at(ctx, 60_000)
      assert pings(ctx) == [@a, @b, @c]
    end

    test "never pings while the radio is busy or not ready", ctx do
      ctx = start(ctx)

      for status <- [%{queued: 1}, %{tx: %{class: :normal, instance: 1}}, %{ready: false}] do
        :ok = FakeRadio.put(ctx.radio, Map.merge(%{ready: true, queued: 0, tx: nil}, status))
        at(ctx, 0)
        assert pings(ctx) == []
      end

      :ok = FakeRadio.put(ctx.radio, %{ready: true, queued: 0, tx: nil})
      at(ctx, 0)
      assert pings(ctx) == [@a]
    end

    test "nothing is pinged while Lights is down", ctx do
      ctx = start(ctx)
      :ok = stop_supervised(:lights)
      at(ctx, 0)
      assert {:ok, %{}} = Presence.snapshot(ctx.presence)
      assert Process.alive?(ctx.presence)
    end

    test "only bulbs silent for over a minute are pinged", ctx do
      ctx = start(ctx, macs: [@a], base_interval_ms: 10_000)
      :ok = FakeLights.report(ctx.lights, @a, 0)

      at(ctx, 30_000)
      at(ctx, @min)
      assert pings(ctx) == []

      at(ctx, @min + 1)
      assert pings(ctx) == [@a]
    end

    test "a silent bulb backs off 2 → 15 min; any report resets it", ctx do
      ctx = start(ctx, macs: [@a], min_gap_ms: 0)

      # Each round: ping at `t`, the miss noticed 10 s later.
      for {t, misses, interval} <- [
            {0, 1, 2 * @min},
            {2 * @min, 2, 4 * @min},
            {6 * @min, 3, 8 * @min},
            {14 * @min, 4, 15 * @min},
            {29 * @min, 5, 15 * @min}
          ] do
        if t > 0 do
          at(ctx, t - 1)
          assert length(pings(ctx)) == misses - 1
        end

        at(ctx, t)
        assert length(pings(ctx)) == misses
        at(ctx, t + 10_000)
        assert %{misses: ^misses, interval_ms: ^interval, missed_at: ^t} = bulb(ctx, @a)
      end

      # A report (here a DP report from an acked command) resets it.
      :ok = FakeLights.report(ctx.lights, @a, 40 * @min)
      at(ctx, 40 * @min)
      assert %{misses: 0, interval_ms: interval, missed_at: nil, last_ms: last} = bulb(ctx, @a)
      assert interval == 2 * @min and last == 40 * @min

      # Back on the 2 min cadence, answering this time.
      :ok = FakeLights.put(ctx.lights, :replying, [@a])
      at(ctx, 42 * @min)
      assert length(pings(ctx)) == 6
      at(ctx, 42 * @min + 5_000)
      assert %{misses: 0, last_ms: last, pinging: false} = bulb(ctx, @a)
      assert last == 42 * @min
    end

    test "busy, queue full and not ready are not silence", ctx do
      ctx = start(ctx, macs: [@a])

      for {reason, t} <- [busy: 0, queue_full: 30_000, not_ready: 60_000] do
        :ok = FakeLights.put(ctx.lights, :ping_reply, {:error, reason})
        at(ctx, t)
        at(ctx, t + 15_000)
        assert %{misses: 0, pinging: false} = bulb(ctx, @a)
      end

      # Tried again on every gap: the bulb stayed due.
      assert pings(ctx) == [@a, @a, @a]
      :ok = FakeLights.put(ctx.lights, :ping_reply, :ok)
      at(ctx, 90_000)
      assert bulb(ctx, @a).pinging
    end

    test "the start is delayed, and a bulb heard already waits its interval", ctx do
      ctx = start(ctx, macs: [@a, @b], start_delay_ms: 15_000, min_gap_ms: 0)
      :ok = FakeLights.report(ctx.lights, @b, 0)

      at(ctx, 14_999)
      assert pings(ctx) == []
      at(ctx, 15_000)
      assert pings(ctx) == [@a]
      at(ctx, 30_000)
      at(ctx, 2 * @min - 1)
      assert pings(ctx) == [@a]
      at(ctx, 2 * @min)
      assert pings(ctx) == [@a, @b]
    end

    test "jitter offsets every check", ctx do
      ctx = start(ctx, macs: [@a], min_gap_ms: 0, jitter: fn ms -> div(ms, 10) end)

      at(ctx, 0)
      assert pings(ctx) == [@a]
      at(ctx, 10_000)
      at(ctx, 2 * @min + 12_000 - 1)
      assert length(pings(ctx)) == 1
      at(ctx, 2 * @min + 12_000)
      assert length(pings(ctx)) == 2
    end
  end

  describe "the budget" do
    test "ten answering bulbs over an hour: at most one ping per gap", ctx do
      macs = for n <- 1..10, do: "BB00000000" <> String.pad_leading("#{n}", 2, "0")
      ctx = start(ctx, macs: macs, replying: macs)

      for t <- 0..3_600_000//5_000, do: at(ctx, t)

      sent = pings(ctx)
      assert length(sent) <= 3_600_000 / 30_000 + 1
      # Every bulb still gets checked, each about every 5 min.
      assert Enum.frequencies(sent) |> Map.values() |> Enum.min() >= 10
    end

    test "dead bulbs back off to a few pings an hour each", ctx do
      ctx = start(ctx, macs: [@a, @b])
      for t <- 0..3_600_000//5_000, do: at(ctx, t)

      # 0, 2, 6, 14, 29, 44, 59 min (the gap shifts @b by 30 s).
      assert Enum.frequencies(pings(ctx)) == %{@a => 7, @b => 7}
    end
  end

  describe "the snapshot" do
    test "is pushed to :notify when it changes, with the expected interval", ctx do
      ctx = start(ctx, macs: [@a, @b], replying: [@a])

      at(ctx, 0)

      assert_receive {:tuya_mesh_presence, _session,
                      %{@a => %{last_ms: nil, pinging: true}, @b => b}}

      # Two bulbs, a 30 s gap: the base 2 min is the longer.
      assert b == %{
               last_ms: nil,
               misses: 0,
               missed_at: nil,
               interval_ms: 2 * @min,
               pinging: false
             }

      # The reply is read on the next tick.
      at(ctx, 0)
      assert_receive {:tuya_mesh_presence, _session, %{@a => %{last_ms: 0, pinging: false}}}

      at(ctx, 0)
      refute_receive {:tuya_mesh_presence, _, _}, 50

      at(ctx, 30_000)
      assert_receive {:tuya_mesh_presence, _session, %{@b => %{pinging: true}}}
    end

    test "the interval covers a full round when the gap paces the bulbs", ctx do
      macs = for n <- 1..10, do: "CC00000000" <> String.pad_leading("#{n}", 2, "0")
      ctx = start(ctx, macs: macs)
      at(ctx, 0)
      assert bulb(ctx, hd(macs)).interval_ms == 10 * 30_000
    end

    test "bulbs that leave the inventory are dropped", ctx do
      ctx = start(ctx)
      at(ctx, 0)
      assert pings(ctx) == [@a]

      :ok = FakeLights.put(ctx.lights, :macs, [@b])
      at(ctx, 1_000)
      assert {:ok, snapshot} = Presence.snapshot(ctx.presence)
      assert Map.keys(snapshot) == [@b]

      # The outstanding ping went with it: the next one is free to go.
      at(ctx, 30_000)
      assert pings(ctx) == [@a, @b]
    end
  end

  describe "verdicts" do
    test "a command slipping in before the ping gives no verdict", ctx do
      on_ping = fn _mac, radio ->
        FakeRadio.air(radio)
        FakeRadio.put(radio, %{queued: 1})
      end

      ctx = start(ctx, macs: [@a], on_ping: on_ping)
      at(ctx, 0)
      assert pings(ctx) == [@a]
      refute bulb(ctx, @a).pinging

      :ok = FakeRadio.put(ctx.radio, %{queued: 0})
      at(ctx, 15_000)
      assert bulb(ctx, @a).misses == 0

      # Still due: tried again after the gap.
      at(ctx, 30_000)
      assert pings(ctx) == [@a, @a]
    end

    test "a ping not on air, or not the next SN, gives no verdict", ctx do
      skipped = fn _mac, radio ->
        FakeRadio.air(radio)
        FakeRadio.air(radio)
      end

      for on_ping <- [fn _mac, _radio -> :ok end, skipped] do
        ctx = start(ctx, macs: [@a], on_ping: on_ping)
        at(ctx, 0)
        refute bulb(ctx, @a).pinging
        at(ctx, 15_000)
        assert bulb(ctx, @a).misses == 0
        Enum.each([:presence, :lights, :radio], &stop_supervised!/1)
      end
    end

    test "a Radio that never sent a frame can't confirm: no verdict, the next ping can", ctx do
      ctx = start(ctx, macs: [@a])
      :ok = FakeRadio.put(ctx.radio, %{last_tx_sn: nil})

      at(ctx, 0)
      refute bulb(ctx, @a).pinging
      at(ctx, 30_000)
      assert bulb(ctx, @a).pinging
      at(ctx, 40_000)
      assert bulb(ctx, @a).misses == 1
    end

    test "a receiver lost during the reply window drops the attempt", ctx do
      for loss <- [%{ready: false}, %{listening: false}, %{discovering: false}] do
        ctx = start(ctx, macs: [@a])
        at(ctx, 0)
        assert bulb(ctx, @a).pinging

        :ok = FakeRadio.put(ctx.radio, loss)
        at(ctx, 5_000)
        :ok = FakeRadio.put(ctx.radio, %{ready: true, listening: true, discovering: true})
        at(ctx, 15_000)
        assert %{misses: 0, pinging: false} = bulb(ctx, @a)
        Enum.each([:presence, :lights, :radio], &stop_supervised!/1)
      end
    end

    test "a failed Lights read defers the verdict to the next one", ctx do
      ctx = start(ctx, macs: [@a, @b])
      at(ctx, 0)
      at(ctx, 30_000)
      assert pings(ctx) == [@a, @b]

      # @b's window closes while Lights can't be read.
      :ok = FakeLights.put(ctx.lights, :all_reply, {:error, :timeout})
      at(ctx, 45_000)
      assert %{misses: 0, pinging: true} = bulb(ctx, @b)

      # The next read shows a reply that came in meanwhile: no miss.
      :ok = FakeLights.put(ctx.lights, :all_reply, nil)
      :ok = FakeLights.report(ctx.lights, @b, 41_000)
      at(ctx, 50_000)
      assert %{misses: 0, pinging: false, last_ms: 41_000} = bulb(ctx, @b)

      # @a's window closed with a working read and no reply: a miss.
      assert bulb(ctx, @a).misses == 1
    end

    test "the window starts once the ping is confirmed; a reply during the call counts", ctx do
      # The ping call takes 4 s.
      slow = fn _mac, radio ->
        Agent.update(ctx.clock, &(&1 + 4_000))
        FakeRadio.air(radio)
      end

      ctx = start(ctx, macs: [@a], on_ping: slow)
      at(ctx, 0)
      Agent.update(ctx.clock, fn _ -> 13_999 end)
      :ok = Presence.poll(ctx.presence)
      assert bulb(ctx, @a).pinging
      at(ctx, 14_000)
      assert %{misses: 1, missed_at: 0} = bulb(ctx, @a)

      :ok = stop_supervised!(:presence)
      :ok = stop_supervised!(:lights)
      :ok = stop_supervised!(:radio)

      # Heard while the call ran (the clock read before it): the reply.
      ctx = start(ctx, macs: [@a], replying: [@a], on_ping: slow)
      at(ctx, 0)
      at(ctx, 4_000)
      assert %{misses: 0, last_ms: 4_000, pinging: false} = bulb(ctx, @a)
    end
  end

  describe "a replacement" do
    test "waits a full gap after its start before its first attempt", ctx do
      ctx = start(ctx, macs: [@a, @b])
      at(ctx, 0)
      assert pings(ctx) == [@a]

      # Restarted (a crash, Lights restarting, an upload) right after.
      :ok = stop_supervised!(:presence)
      Agent.update(ctx.clock, fn _ -> 1_000 end)
      presence = start_supervised!({Presence, ctx.opts}, id: :presence)
      ctx = %{ctx | presence: presence}

      at(ctx, 1_000)
      at(ctx, 30_999)
      assert pings(ctx) == [@a]
      at(ctx, 31_000)
      assert pings(ctx) == [@a, @a]
    end

    test "pushes under a session of its own", ctx do
      ctx = start(ctx, macs: [@a])
      at(ctx, 0)
      assert_receive {:tuya_mesh_presence, first, _snapshot}

      :ok = stop_supervised!(:presence)
      presence = start_supervised!({Presence, ctx.opts}, id: :presence)
      at(%{ctx | presence: presence}, 1_000)
      assert_receive {:tuya_mesh_presence, second, _snapshot}
      assert is_reference(first) and is_reference(second) and first != second
    end
  end

  test "the client API survives a missing server" do
    assert Presence.snapshot(:"no_presence_#{System.unique_integer([:positive])}") ==
             {:error, :not_running}
  end
end
