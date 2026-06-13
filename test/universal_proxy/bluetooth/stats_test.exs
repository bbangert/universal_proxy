defmodule UniversalProxy.Bluetooth.StatsTest do
  # async: false — bump_ad/0 routes through a global :persistent_term
  # counter ref that each Stats instance (re)publishes.
  use ExUnit.Case, async: false

  alias UniversalProxy.Bluetooth.Stats

  @pubsub UniversalProxy.PubSub

  setup do
    :ok = Phoenix.PubSub.subscribe(@pubsub, UniversalProxy.Bluetooth.stats_topic())
    :ok
  end

  defp start_stats(opts \\ []) do
    start_supervised!(
      {Stats,
       opts ++
         [
           name: nil,
           pubsub: @pubsub,
           tick_ms: 50,
           devices_fun: fn -> 7 end,
           connections_fun: fn -> %{used: 1, limit: 3} end
         ]}
    )
  end

  test "ticks broadcast the full stats map and update current/1" do
    stats = start_stats()

    assert_receive {:bluetooth_stats, %{ads_per_s: 0, devices_15min: 7, connections: %{used: 1}}},
                   1_000

    assert %{devices_15min: 7, connections: %{used: 1, limit: 3}} = Stats.current(stats)
  end

  test "bump_ad/0 counts adverts exactly once, then the counter drains" do
    stats = start_stats()
    # Wait for one tick so we know the counter is being drained per tick.
    assert_receive {:bluetooth_stats, _}, 1_000

    for _ <- 1..5, do: Stats.bump_ad()

    # The bumps may straddle a 50 ms tick boundary — assert the total
    # across ticks is exactly 5 (no loss, no double count)…
    assert collect_ads(0) == 5

    # …and once drained, ticks are back to zero.
    assert_receive {:bluetooth_stats, %{ads_per_s: 0}}, 1_000
    assert %{ads_per_s: 0} = Stats.current(stats)
  end

  # Sum ads_per_s over successive ticks until the expected total arrives
  # (an overshoot returns the larger sum and fails the caller's assert).
  defp collect_ads(sum) when sum >= 5, do: sum

  defp collect_ads(sum) do
    assert_receive {:bluetooth_stats, %{ads_per_s: n}}, 1_000
    collect_ads(sum + n)
  end

  test "bump_ad/0 is a no-op without a counter published" do
    # A previous instance's ref can linger (terminate/2 doesn't run on a
    # plain supervisor shutdown) — force the no-counter branch.
    :persistent_term.erase({Stats, :ad_counter})
    assert Stats.bump_ad() == :ok
  end

  test "connections_changed/1 pushes an off-tick connections update" do
    counter = :counters.new(1, [])

    stats =
      start_stats(
        tick_ms: 60_000,
        connections_fun: fn ->
          %{used: :counters.get(counter, 1), limit: 3}
        end
      )

    # Drain the boot tick race: nothing broadcast yet (first tick is 60 s out).
    refute_receive {:bluetooth_stats, _}, 100

    :counters.put(counter, 1, 2)
    :ok = Stats.connections_changed(stats)

    assert_receive {:bluetooth_stats, %{connections: %{used: 2, limit: 3}}}, 1_000
    assert %{connections: %{used: 2}} = Stats.current(stats)
  end

  test "defensive defaults: sources down → zeros (host shape)" do
    # Default funs hit the real (not running) Client/Gatt — exit-safe.
    stats = start_supervised!({Stats, name: nil, pubsub: @pubsub, tick_ms: 50})

    assert_receive {:bluetooth_stats,
                    %{ads_per_s: 0, devices_15min: 0, connections: %{used: 0, limit: 3}}},
                   1_000

    assert %{devices_15min: 0} = Stats.current(stats)
  end
end
