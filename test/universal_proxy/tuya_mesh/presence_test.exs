defmodule UniversalProxy.TuyaMesh.PresenceTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.TuyaMesh.{FakeLights, FakeRadio, Presence}

  @a "AA0000000001"
  @b "AA0000000002"
  @c "AA0000000003"

  @s 1_000
  @min 60_000

  setup do
    clock = start_supervised!({Agent, fn -> 0 end})
    now = fn -> Agent.get(clock, & &1) end
    {:ok, clock: clock, now: now}
  end

  defp macs(n), do: for(i <- 1..n, do: "BB00000000" <> String.pad_leading("#{i}", 2, "0"))

  # The production timing, no jitter, ticks only when the test polls.
  # Started a minute before 0 and settled there (Lights read, Radio idle),
  # so the start-up minute's cap is spent by 0 and the first broadcast goes
  # at 0. Every accepted frame airs on the FakeRadio unless `on_ping`
  # (`(mac | :all, radio) -> any`) says otherwise.
  defp start(ctx, opts \\ []) do
    {macs, opts} = Keyword.pop(opts, :macs, [@a, @b, @c])
    {replying, opts} = Keyword.pop(opts, :replying, [])
    {deaf, opts} = Keyword.pop(opts, :deaf, [])
    {held, opts} = Keyword.pop(opts, :held, [])
    {on_ping, opts} = Keyword.pop(opts, :on_ping, fn _target, radio -> FakeRadio.air(radio) end)
    Agent.update(ctx.clock, fn _ -> -@min end)

    radio = start_supervised!({FakeRadio, clock: ctx.now}, id: :radio)

    lights =
      start_supervised!(
        {FakeLights,
         macs: macs,
         replying: replying,
         deaf: deaf,
         held: held,
         clock: ctx.now,
         on_ping: &on_ping.(&1, radio)},
        id: :lights
      )

    defaults = [
      name: nil,
      lights: lights,
      radio: radio,
      notify: self(),
      clock: ctx.now,
      jitter: fn _ms -> 0 end,
      tick_ms: 3_600_000
    ]

    opts = Keyword.merge(defaults, opts)
    presence = start_supervised!({Presence, opts}, id: :presence)
    :ok = Presence.poll(presence)
    flush_pushes()

    Map.merge(ctx, %{lights: lights, radio: radio, presence: presence, opts: opts})
  end

  defp stop_all, do: Enum.each([:presence, :lights, :radio], &stop_supervised!/1)

  defp flush_pushes do
    receive do
      {:tuya_mesh_presence, _generation, _snapshot} -> flush_pushes()
    after
      0 -> :ok
    end
  end

  defp at(ctx, ms) do
    Agent.update(ctx.clock, fn _ -> ms end)
    :ok = Presence.poll(ctx.presence)
    ctx
  end

  # Polls once a second, as a busy pinger ticks.
  defp run(ctx, from, to), do: for(t <- from..to//@s, do: at(ctx, t))

  defp pings(ctx), do: FakeLights.pings(ctx.lights)
  defp log(ctx), do: FakeLights.log(ctx.lights)

  defp bulb(ctx, mac) do
    {:ok, snapshot} = Presence.snapshot(ctx.presence)
    Map.fetch!(snapshot, mac)
  end

  defp max_in_a_minute(log) do
    times = Enum.map(log, &elem(&1, 1))

    times
    |> Enum.map(fn t -> Enum.count(times, &(&1 >= t and &1 < t + @min)) end)
    |> Enum.max(fn -> 0 end)
  end

  defp max_in_an_hour(log) do
    times = Enum.map(log, &elem(&1, 1))

    times
    |> Enum.map(fn t -> Enum.count(times, &(&1 >= t and &1 < t + 60 * @min)) end)
    |> Enum.max(fn -> 0 end)
  end

  defp restart(ctx, at_ms) do
    :ok = stop_supervised!(:presence)
    Agent.update(ctx.clock, fn _ -> at_ms end)
    %{ctx | presence: start_supervised!({Presence, ctx.opts}, id: :presence)}
  end

  describe "a cycle" do
    test "one broadcast; only the bulbs that didn't answer get a direct ping", ctx do
      ctx = start(ctx, replying: [@a, @b, @c], deaf: [@c])

      at(ctx, 0)
      assert pings(ctx) == [:all]

      # The window closes 5 s after the broadcast aired: @c is unconfirmed.
      at(ctx, 4 * @s)
      assert pings(ctx) == [:all]
      at(ctx, 5 * @s)
      assert pings(ctx) == [:all, @c]

      # It answers the direct ping: no miss.
      run(ctx, 6 * @s, 59 * @s)
      assert pings(ctx) == [:all, @c]
      assert %{misses: 0, last_ms: 5_000} = bulb(ctx, @c)
      assert %{misses: 0, last_ms: 0} = bulb(ctx, @a)

      # The next cycle a minute later.
      at(ctx, @min)
      assert pings(ctx) == [:all, @c, :all]
    end

    test "missing the broadcast and the direct ping is one miss; two cycles, two", ctx do
      ctx = start(ctx, macs: [@a, @b], replying: [@a])

      run(ctx, 0, 11 * @s)
      assert pings(ctx) == [:all, @b]
      assert %{misses: 1, missed_at: 5_000} = bulb(ctx, @b)
      assert bulb(ctx, @a).misses == 0

      run(ctx, 12 * @s, 71 * @s)
      assert pings(ctx) == [:all, @b, :all, @b]
      assert %{misses: 2, missed_at: 65_000} = bulb(ctx, @b)
    end

    test "a dead bulb's direct pings back off; it still hears every broadcast", ctx do
      ctx = start(ctx, macs: [@a])
      run(ctx, 0, 30 * @min)

      directs = for {@a, at} <- log(ctx), do: div(at, 1_000)
      # 5 s, 65 s, then 2, 4 and 8 min after each later miss (at the cycle
      # that follows).
      assert directs == [5, 65, 185, 425, 905]
      assert Enum.count(pings(ctx), &(&1 == :all)) == 31
    end

    test "any frame from a bulb, its power-on announce included, clears its misses", ctx do
      ctx = start(ctx, macs: [@a])
      run(ctx, 0, 71 * @s)
      assert bulb(ctx, @a).misses == 2

      :ok = FakeLights.report(ctx.lights, @a, 80_000)
      at(ctx, 81 * @s)
      assert %{misses: 0, missed_at: nil, last_ms: 80_000} = bulb(ctx, @a)

      # No backoff left: followed up as usual when it misses a broadcast.
      :ok = FakeLights.put(ctx.lights, :replying, [@a])
      :ok = FakeLights.put(ctx.lights, :deaf, [@a])
      run(ctx, 82 * @s, 126 * @s)
      assert List.last(pings(ctx)) == @a
    end

    test "a bulb heard just before the broadcast needs no follow-up", ctx do
      ctx = start(ctx, macs: [@a])
      :ok = FakeLights.report(ctx.lights, @a, -10_000)
      run(ctx, 0, 30 * @s)
      assert pings(ctx) == [:all]
    end

    test "never sent while a command is queued or on air, or the radio isn't ready", ctx do
      ctx = start(ctx)

      for status <- [%{queued: 1}, %{tx: %{class: :normal, instance: 1}}, %{ready: false}] do
        :ok = FakeRadio.put(ctx.radio, Map.merge(%{ready: true, queued: 0, tx: nil}, status))
        at(ctx, 0)
        assert pings(ctx) == []
      end

      :ok = FakeRadio.put(ctx.radio, %{ready: true, queued: 0, tx: nil})
      at(ctx, 0)
      assert pings(ctx) == [:all]
    end

    test "nothing is sent while Lights is down", ctx do
      ctx = start(ctx)
      :ok = stop_supervised(:lights)
      at(ctx, 0)
      assert Process.alive?(ctx.presence)
    end

    test "bulbs that leave the inventory are dropped", ctx do
      ctx = start(ctx)
      at(ctx, 0)
      :ok = FakeLights.put(ctx.lights, :macs, [@b])
      run(ctx, 1 * @s, 10 * @s)
      assert {:ok, snapshot} = Presence.snapshot(ctx.presence)
      assert Map.keys(snapshot) == [@b]
      assert pings(ctx) == [:all, @b]
    end
  end

  # Polls once a second from `from` until all `bulbs` are missed twice (at
  # most 5 minutes); the time each was, from `from`.
  defp until_all_missed(ctx, bulbs, from) do
    Enum.reduce_while(from..(from + 5 * @min)//@s, %{}, fn t, decided ->
      at(ctx, t)

      decided =
        Enum.reduce(bulbs, decided, fn mac, acc ->
          if bulb(ctx, mac).misses >= 2, do: Map.put_new(acc, mac, t - from), else: acc
        end)

      if map_size(decided) == length(bulbs), do: {:halt, decided}, else: {:cont, decided}
    end)
  end

  describe "a whole-mesh outage" do
    test "after an hour of rotating broadcast misses: all Not reachable within 4 min", ctx do
      bulbs = macs(10)
      ctx = start(ctx, macs: bulbs, replying: bulbs)

      # Each cycle two different bulbs miss the broadcast (collisions).
      for t <- 0..(60 * @min - 1)//@s do
        if rem(t, @min) == 0 do
          cycle = div(t, @min)
          deaf = [Enum.at(bulbs, rem(2 * cycle, 10)), Enum.at(bulbs, rem(2 * cycle + 1, 10))]
          :ok = FakeLights.put(ctx.lights, :deaf, deaf)
        end

        at(ctx, t)
      end

      assert Enum.all?(bulbs, &(bulb(ctx, &1).misses == 0))
      assert Enum.count(pings(ctx), &(&1 != :all)) >= 100

      # The power goes just after the next broadcast was answered.
      run(ctx, 60 * @min, 60 * @min + 5 * @s)
      :ok = FakeLights.put(ctx.lights, :replying, [])
      decided = until_all_missed(ctx, bulbs, 60 * @min + 6 * @s)

      assert map_size(decided) == 10
      assert Enum.max(Map.values(decided)) <= 4 * @min
      assert max_in_a_minute(log(ctx)) <= 10
      assert max_in_an_hour(log(ctx)) <= 240
    end

    test "after the four-straggler warm-up: all Not reachable within 4 min", ctx do
      bulbs = macs(10)
      ctx = start(ctx, macs: bulbs, replying: bulbs, deaf: Enum.take(bulbs, 4))
      run(ctx, 0, 10 * @min + 5 * @s)
      assert Enum.all?(bulbs, &(bulb(ctx, &1).misses == 0))

      :ok = FakeLights.put(ctx.lights, :replying, [])
      decided = until_all_missed(ctx, bulbs, 10 * @min + 6 * @s)

      assert map_size(decided) == 10
      assert Enum.max(Map.values(decided)) <= 4 * @min
      assert max_in_a_minute(log(ctx)) <= 10
    end

    test "every bulb is Not reachable (two misses) within 4 minutes, inside the caps", ctx do
      bulbs = macs(10)
      ctx = start(ctx, macs: bulbs, replying: bulbs)
      run(ctx, 0, 125 * @s)
      assert Enum.all?(bulbs, &(bulb(ctx, &1).misses == 0))

      # The power goes just after a broadcast was answered (the worst case).
      lost = 125 * @s
      :ok = FakeLights.put(ctx.lights, :replying, [])

      decided =
        Enum.reduce(lost..(lost + 5 * @min)//@s, %{}, fn t, decided ->
          at(ctx, t)

          Enum.reduce(bulbs, decided, fn mac, acc ->
            if bulb(ctx, mac).misses >= 2, do: Map.put_new(acc, mac, t), else: acc
          end)
        end)

      assert map_size(decided) == 10
      assert Enum.max(Map.values(decided)) - lost <= 4 * @min
      assert max_in_a_minute(log(ctx)) <= 10
    end
  end

  describe "the budget" do
    test "an hour of a healthy mesh with two stragglers: within both caps", ctx do
      bulbs = macs(10)
      stragglers = Enum.take(bulbs, 2)
      ctx = start(ctx, macs: bulbs, replying: bulbs, deaf: stragglers)
      run(ctx, 0, 60 * @min - 1)

      sent = log(ctx)
      assert Enum.count(sent, &(elem(&1, 0) == :all)) == 60
      # Each straggler directly twice, then every other cycle: 2 + 29.
      for mac <- stragglers, do: assert(Enum.count(sent, &(elem(&1, 0) == mac)) == 31)
      assert length(sent) == 60 + 2 * 31
      assert max_in_a_minute(sent) <= 10
      assert Enum.all?(bulbs, &(bulb(ctx, &1).misses == 0))
      assert %{interval_ms: 120_000} = bulb(ctx, hd(stragglers))
      assert %{interval_ms: @min} = bulb(ctx, List.last(bulbs))
    end

    test "ten stragglers for two hours: never unreachable, honest intervals, caps hold",
         ctx do
      bulbs = macs(10)
      ctx = start(ctx, macs: bulbs, replying: bulbs, deaf: bulbs)

      for t <- 0..(120 * @min - 1)//@s do
        at(ctx, t)

        # Once each was heard (the first round takes a couple of minutes).
        if t >= 3 * @min and rem(t, 10 * @s) == 0 do
          {:ok, snapshot} = Presence.snapshot(ctx.presence)

          for {_mac, b} <- snapshot do
            assert b.misses == 0
            # The Resolver's window for it (2.5 x its interval) still holds.
            assert t - b.last_ms <= div(b.interval_ms * 5, 2)
          end
        end
      end

      sent = log(ctx)
      assert max_in_an_hour(sent) <= 240
      assert max_in_a_minute(sent) <= 10

      # The advertised interval covers the real gaps between checks.
      {:ok, snapshot} = Presence.snapshot(ctx.presence)

      for mac <- bulbs do
        times = for {^mac, at} <- sent, at >= 30 * @min, do: at
        gaps = times |> Enum.zip(tl(times)) |> Enum.map(fn {a, b} -> b - a end)
        assert Enum.max(gaps) <= snapshot[mac].interval_ms
      end
    end

    test "four permanent stragglers for two hours: broadcasts never stop, all stay heard",
         ctx do
      bulbs = macs(10)
      {stragglers, healthy} = Enum.split(bulbs, 4)
      ctx = start(ctx, macs: bulbs, replying: bulbs, deaf: stragglers)

      for t <- 0..(120 * @min - 1)//@s do
        at(ctx, t)

        if t >= 3 * @min and rem(t, 10 * @s) == 0 do
          {:ok, snapshot} = Presence.snapshot(ctx.presence)

          for mac <- healthy do
            assert t - snapshot[mac].last_ms <= 150_000
          end

          # Within the Resolver's window for them (2.5 x their interval).
          for mac <- stragglers do
            assert t - snapshot[mac].last_ms <= div(snapshot[mac].interval_ms * 5, 2)
          end

          assert Enum.all?(snapshot, fn {_mac, b} -> b.misses == 0 end)
        end
      end

      sent = log(ctx)
      broadcasts = for {:all, at} <- sent, do: at
      assert length(broadcasts) == 120
      assert broadcasts |> Enum.zip(tl(broadcasts)) |> Enum.all?(fn {a, b} -> b - a <= @min end)
      assert max_in_an_hour(sent) <= 240
      assert max_in_a_minute(sent) <= 10
    end

    test "an hour of a dead mesh: within both caps, dead bulbs backed off", ctx do
      ctx = start(ctx, macs: macs(10))
      run(ctx, 0, 60 * @min - 1)

      sent = log(ctx)
      assert length(sent) <= 240
      assert max_in_a_minute(sent) <= 10
      # The second half hour: broadcasts plus a couple of direct pings each.
      late = Enum.filter(sent, &(elem(&1, 1) >= 30 * @min))
      assert length(late) <= 60
    end

    test "the hour cap holds when the minute cap alone would allow more", ctx do
      # 67 reserved for broadcasts, 33 for follow-ups.
      ctx = start(ctx, macs: macs(10), max_per_hour: 100)
      run(ctx, 0, 60 * @min - 1)
      sent = log(ctx)
      assert length(sent) <= 100
      assert Enum.count(sent, &(elem(&1, 0) != :all)) <= 33
      assert Enum.count(sent, &(elem(&1, 0) == :all)) == 60
    end

    test "the frame log survives the pinger and the mesh: <= 240 in any rolling hour",
         ctx do
      # Every bulb a straggler and no spacing: routine follow-ups run into
      # their hour cap within the first hour.
      bulbs = macs(10)
      table = :ets.new(:frames, [:set, :public])

      ctx =
        start(ctx,
          macs: bulbs,
          replying: bulbs,
          deaf: bulbs,
          frames: table,
          routine_spacing_ms: 0
        )

      run(ctx, 0, 40 * @min)

      # A pinger restart, then (a new mesh generation) a mesh restart.
      ctx = restart(ctx, 40 * @min + @s)
      run(ctx, 40 * @min + @s, 80 * @min)
      ctx = %{ctx | opts: Keyword.put(ctx.opts, :mesh_generation, 1)}
      ctx = restart(ctx, 80 * @min + @s)
      run(ctx, 80 * @min + @s, 150 * @min)

      sent = log(ctx)
      assert max_in_an_hour(sent) <= 240
      assert Enum.count(sent, &(elem(&1, 0) != :all)) > 0
    end

    test "a log that doesn't know the last hour allows only broadcasts for an hour", ctx do
      table = :ets.new(:frames, [:set, :public])
      Presence.unknown_history(table, -@min)
      ctx = start(ctx, macs: macs(3), frames: table)
      run(ctx, 0, 30 * @min)
      assert Enum.all?(pings(ctx), &(&1 == :all))

      run(ctx, 30 * @min + @s, 62 * @min)
      assert Enum.any?(pings(ctx), &(&1 != :all))
    end
  end

  describe "verdicts" do
    test "a broadcast whose airing can't be confirmed gives no verdicts", ctx do
      # A command slipped in: the broadcast went on air behind it.
      on_ping = fn
        :all, radio ->
          FakeRadio.air(radio)
          FakeRadio.put(radio, %{queued: 1})

        _mac, radio ->
          FakeRadio.air(radio)
      end

      ctx = start(ctx, macs: [@a], on_ping: on_ping)
      at(ctx, 0)
      :ok = FakeRadio.put(ctx.radio, %{queued: 0})
      run(ctx, 1 * @s, 30 * @s)
      assert pings(ctx) == [:all]
      assert bulb(ctx, @a).misses == 0
    end

    test "a direct ping not on air, or not the next SN, gives no verdict", ctx do
      skipped = fn _mac, radio ->
        FakeRadio.air(radio)
        FakeRadio.air(radio)
      end

      for direct <- [fn _mac, _radio -> :ok end, skipped] do
        on_ping = fn
          :all, radio -> FakeRadio.air(radio)
          mac, radio -> direct.(mac, radio)
        end

        ctx = start(ctx, macs: [@a], on_ping: on_ping)
        run(ctx, 0, 59 * @s)
        assert bulb(ctx, @a).misses == 0
        assert Enum.count(pings(ctx), &(&1 == @a)) >= 2
        stop_all()
      end
    end

    test "a Radio that never sent a frame can't confirm: no verdict, the next can", ctx do
      ctx = start(ctx, macs: [@a])
      :ok = FakeRadio.put(ctx.radio, %{last_tx_sn: nil})

      run(ctx, 0, 59 * @s)
      assert pings(ctx) == [:all]
      run(ctx, 60 * @s, 71 * @s)
      assert bulb(ctx, @a).misses == 1
    end

    test "a receiver lost during the reply window drops the attempt", ctx do
      for loss <- [%{ready: false}, %{listening: false}, %{discovering: false}] do
        ctx = start(ctx, macs: [@a])
        run(ctx, 0, 5 * @s)
        assert bulb(ctx, @a).pinging

        :ok = FakeRadio.put(ctx.radio, loss)
        at(ctx, 6 * @s)
        :ok = FakeRadio.put(ctx.radio, %{ready: true, listening: true, discovering: true})
        at(ctx, 9 * @s)
        assert %{misses: 0, pinging: false} = bulb(ctx, @a)

        # Still unconfirmed: asked again once routine spacing allows.
        run(ctx, 10 * @s, 33 * @s)
        assert pings(ctx) == [:all, @a, @a]
        stop_all()
      end
    end

    test "a failed Lights read defers the verdict to the next one", ctx do
      ctx = start(ctx, macs: [@a, @b], replying: [@a])
      at(ctx, 0)

      # The broadcast's window closes while Lights can't be read.
      :ok = FakeLights.put(ctx.lights, :all_reply, {:error, :timeout})
      at(ctx, 5 * @s)
      assert pings(ctx) == [:all]

      # The next read shows @b answered meanwhile: no follow-up needed.
      :ok = FakeLights.put(ctx.lights, :all_reply, nil)
      :ok = FakeLights.report(ctx.lights, @b, 3_000)
      run(ctx, 6 * @s, 20 * @s)
      assert pings(ctx) == [:all]
      assert bulb(ctx, @b).last_ms == 3_000
    end

    test "the window starts once the frame is confirmed; a reply during the call counts",
         ctx do
      # Each call takes 4 s.
      slow = fn _target, radio ->
        Agent.update(ctx.clock, &(&1 + 4_000))
        FakeRadio.air(radio)
      end

      ctx = start(ctx, macs: [@a], on_ping: slow)
      # Broadcast asked at 0, confirmed at 4 s: its window closes at 9 s.
      at(ctx, 0)
      at(ctx, 8_999)
      assert pings(ctx) == [:all]
      at(ctx, 9 * @s)
      assert pings(ctx) == [:all, @a]
      # The direct ping, asked at 9 s, confirmed at 13 s: closes at 18 s.
      at(ctx, 17_999)
      assert bulb(ctx, @a).pinging
      at(ctx, 18 * @s)
      assert %{misses: 1, missed_at: 9_000} = bulb(ctx, @a)

      stop_all()

      # Heard while the broadcast call ran (the clock read before it).
      ctx = start(ctx, macs: [@a], replying: [@a], on_ping: slow)
      run(ctx, 0, 20 * @s)
      assert pings(ctx) == [:all]
      assert bulb(ctx, @a).last_ms == 4_000
    end

    test "busy, queue full and not ready are not silence, and queue nothing", ctx do
      ctx = start(ctx, macs: [@a])

      for {reason, t} <- [busy: 0, queue_full: 5 * @s, not_ready: 10 * @s] do
        :ok = FakeLights.put(ctx.lights, :ping_reply, {:error, reason})
        at(ctx, t)
      end

      # Each refused broadcast stayed due and was tried again after the gap.
      assert pings(ctx) == [:all, :all, :all]
      :ok = FakeLights.put(ctx.lights, :ping_reply, :ok)
      run(ctx, 15 * @s, 25 * @s)
      assert pings(ctx) == [:all, :all, :all, :all, @a]
      assert bulb(ctx, @a).misses == 1
    end

    test "a frame that timed out and aired late is not followed within a gap", ctx do
      ctx = start(ctx, macs: [@a])
      run(ctx, 0, 4 * @s)

      # The direct ping times out, held behind a command backlog until 40 s.
      :ok = FakeLights.put(ctx.lights, :ping_reply, {:error, :timeout})
      at(ctx, 5 * @s)
      assert pings(ctx) == [:all, @a]
      :ok = FakeLights.put(ctx.lights, :ping_reply, :ok)
      :ok = FakeRadio.put(ctx.radio, %{queued: 1})
      run(ctx, 6 * @s, 39 * @s)

      Agent.update(ctx.clock, fn _ -> 40_000 end)
      :ok = FakeRadio.put(ctx.radio, %{queued: 0})
      :ok = FakeRadio.air(ctx.radio)
      run(ctx, 40 * @s, 47 * @s)
      assert pings(ctx) == [:all, @a]

      # Idle at 43 s: the still-unconfirmed bulb is asked a gap later.
      at(ctx, 48 * @s)
      assert pings(ctx) == [:all, @a, @a]
    end
  end

  describe "a reset bulb counter" do
    test "a bulb answering with frames Lights holds is never missed", ctx do
      ctx = start(ctx, macs: [@a], held: [@a], deaf: [@a])
      run(ctx, 0, 30 * @min)
      # Twice, then every other cycle (a straggler).
      assert Enum.count(pings(ctx), &(&1 == @a)) == 16
      assert %{misses: 0} = bulb(ctx, @a)
    end
  end

  describe "a replacement" do
    test "settles and counts a minute spent: no frame within a minute of its start", ctx do
      ctx = start(ctx, macs: [@a, @b])
      at(ctx, 0)
      assert pings(ctx) == [:all]

      # Restarted (a crash, Lights restarting, an upload) right after.
      ctx = restart(ctx, 1 * @s)
      run(ctx, 1 * @s, 60 * @s)
      assert pings(ctx) == [:all]
      at(ctx, 61 * @s)
      assert pings(ctx) == [:all, :all]
    end

    test "a predecessor's frame held behind a backlog delays the first attempt", ctx do
      # Accepted, but queued behind a command.
      held = fn _target, radio -> FakeRadio.put(radio, %{queued: 1}) end
      ctx = start(ctx, macs: [@a, @b], on_ping: held)
      at(ctx, 0)
      assert pings(ctx) == [:all]

      # Replaced while it is still queued (Lights lives on).
      ctx = restart(ctx, 1 * @s)
      run(ctx, 1 * @s, 69 * @s)

      # It airs at 70 s, after the replacement's start-up minute.
      Agent.update(ctx.clock, fn _ -> 70_000 end)
      :ok = FakeRadio.put(ctx.radio, %{queued: 0})
      :ok = FakeRadio.air(ctx.radio)
      run(ctx, 70 * @s, 77 * @s)
      assert pings(ctx) == [:all]

      # A gap after the Radio went idle at 73 s.
      at(ctx, 78 * @s)
      assert pings(ctx) == [:all, :all]
    end

    test "pushes under a later generation, in the mesh generation it was given", ctx do
      ctx = start(ctx, macs: [@a], replying: [@a], mesh_generation: 7)
      at(ctx, 0)
      # The reply, read on the next tick, changes the snapshot.
      at(ctx, 1 * @s)
      assert_receive {:tuya_mesh_presence, {7, first}, _snapshot}

      ctx = restart(ctx, 2 * @s)
      at(ctx, 2 * @s)
      assert_receive {:tuya_mesh_presence, {7, second}, _snapshot}
      assert second > first
    end
  end

  describe "the snapshot" do
    test "is pushed when it changes, with the cycle as the interval", ctx do
      ctx = start(ctx, macs: [@a, @b], replying: [@a])

      # The broadcast itself changes nothing; its replies are read on the
      # next tick.
      at(ctx, 0)
      refute_receive {:tuya_mesh_presence, _, _}, 50
      at(ctx, 1 * @s)
      assert_receive {:tuya_mesh_presence, _gen, %{@a => %{last_ms: 0}, @b => b}}
      assert b == %{last_ms: nil, misses: 0, missed_at: nil, interval_ms: @min, pinging: false}
      at(ctx, 2 * @s)
      refute_receive {:tuya_mesh_presence, _, _}, 50

      at(ctx, 5 * @s)
      assert_receive {:tuya_mesh_presence, _gen, %{@b => %{pinging: true}}}
    end
  end

  test "the client API survives a missing server" do
    assert Presence.snapshot(:"no_presence_#{System.unique_integer([:positive])}") ==
             {:error, :not_running}
  end
end
