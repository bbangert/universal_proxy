defmodule UniversalProxy.Sendspin.ClockFilterTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Sendspin.ClockFilter

  # Local timestamps start negative on purpose: BEAM monotonic time
  # does, and the upstream `time_added <= 0` guard would reject it.
  @t0 -1_000_000_000
  # Server clock an hour ahead of the local basis.
  @server_offset 3_600_000_000

  setup do
    :rand.seed(:exsss, {101, 102, 103})
    :ok
  end

  describe "new/1" do
    test "starts unconverged and maps timestamps through unchanged" do
      filter = ClockFilter.new()

      refute ClockFilter.converged?(filter)
      assert ClockFilter.count(filter) == 0
      assert ClockFilter.error(filter) == :infinity
      assert ClockFilter.server_time(filter, @t0) == @t0
      assert ClockFilter.client_time(filter, @t0) == @t0
    end

    test "accepts upstream tuning overrides" do
      filter = ClockFilter.new(forget_factor: 3.0, min_samples: 4, max_error_scale: 1.0)

      assert filter.forget_variance_factor == 9.0
      assert filter.min_samples == 4
      assert filter.max_error_scale == 1.0
    end
  end

  describe "update_measurement/4 (upstream parity)" do
    test "the first measurement establishes the offset baseline" do
      filter = ClockFilter.update_measurement(ClockFilter.new(), 1000, 100, 5000)

      assert ClockFilter.count(filter) == 1
      assert ClockFilter.server_time(filter, 5000) == 6000
      assert ClockFilter.client_time(filter, 6000) == 5000
    end

    test "ignores measurements whose timestamp does not advance" do
      filter =
        ClockFilter.new()
        |> ClockFilter.update_measurement(1000, 100, 5000)

      before = ClockFilter.server_time(filter, 5000)

      # Same timestamp, then an earlier one: both dropped, wild
      # measurements must not move the estimate.
      filter = ClockFilter.update_measurement(filter, 999_999, 100, 5000)
      assert ClockFilter.server_time(filter, 5000) == before

      filter = ClockFilter.update_measurement(filter, -999_999, 100, 4000)
      assert ClockFilter.server_time(filter, 5000) == before
      assert ClockFilter.count(filter) == 1
    end

    test "converges on a constant offset with shrinking uncertainty" do
      filter =
        Enum.reduce(1..100, ClockFilter.new(), fn i, filter ->
          ClockFilter.update_measurement(filter, 5000, 100, i * 100_000)
        end)

      t = 100 * 100_000
      assert_in_delta ClockFilter.server_time(filter, t) - t, 5000, 5

      error = ClockFilter.error(filter)
      assert error > 0
      assert error < 50
    end
  end

  describe "update/5" do
    test "converged?/1 flips only once two exchanges have landed" do
      filter = ClockFilter.new()
      refute ClockFilter.converged?(filter)

      filter = exchange(filter, @t0)
      refute ClockFilter.converged?(filter)

      filter = exchange(filter, @t0 + 1_000_000)
      assert ClockFilter.converged?(filter)
    end

    test "converges within a handful of exchanges under network jitter" do
      filter = run_exchanges(ClockFilter.new(), 5, jitter: 400)

      assert ClockFilter.converged?(filter)
      assert abs(mapping_error(filter, @t0 + 10_000_000)) < 1_000
    end

    test "tracks a drifting server clock and extrapolates past the last sync" do
      filter = run_exchanges(ClockFilter.new(), 60, ppm: 50, jitter: 200)

      assert filter.use_drift
      assert_in_delta filter.drift, 50.0e-6, 5.0e-6

      # 60 s past the last exchange, where a filter that dropped the
      # drift term would already be 3 ms out (60 s * 50 ppm).
      assert abs(mapping_error(filter, @t0 + 120 * 1_000_000, 50)) < 500
    end

    test "accepts negative local timestamps" do
      filter = run_exchanges(ClockFilter.new(), 5, jitter: 100)

      assert ClockFilter.converged?(filter)
      assert filter.last_update < 0
      assert ClockFilter.server_time(filter, @t0) > 0
    end

    test "an RTT outlier does not wreck a converged estimate" do
      filter = run_exchanges(ClockFilter.new(), 20, jitter: 200)
      before = mapping_error(filter, @t0 + 100_000_000)

      # One badly asymmetric exchange: 250 ms of extra upstream delay
      # inflates max_error, so the sample earns almost no Kalman gain.
      filter = exchange(filter, @t0 + 21 * 1_000_000, jitter: 200, up: 250_000)

      assert ClockFilter.converged?(filter)
      after_outlier = mapping_error(filter, @t0 + 100_000_000)
      assert abs(after_outlier - before) < 2_000
      assert abs(after_outlier) < 2_000
    end

    test "frame timestamps stay non-decreasing across mid-stream updates" do
      warm = run_exchanges(ClockFilter.new(), 5, jitter: 200)
      start = @t0 + 6 * 1_000_000

      # 500 frames of 20 ms audio, with a sync exchange every 25 frames.
      {stamps, _filter} =
        Enum.map_reduce(0..499, warm, fn i, filter ->
          local = start + i * 20_000

          filter =
            if rem(i, 25) == 0 and i > 0 do
              exchange(filter, local, jitter: 200)
            else
              filter
            end

          {ClockFilter.server_time(filter, local), filter}
        end)

      assert stamps == Enum.sort(stamps)
    end
  end

  describe "conversions" do
    test "server_time/2 and client_time/2 round-trip" do
      filter = run_exchanges(ClockFilter.new(), 10, ppm: 50, jitter: 100)
      local = @t0 + 11_000_000

      assert_in_delta ClockFilter.client_time(filter, ClockFilter.server_time(filter, local)),
                      local,
                      1
    end
  end

  describe "reset/1" do
    test "clears the estimate but keeps the tuning" do
      filter = run_exchanges(ClockFilter.new(min_samples: 4), 5, jitter: 100)
      reset = ClockFilter.reset(filter)

      refute ClockFilter.converged?(reset)
      assert ClockFilter.count(reset) == 0
      assert ClockFilter.error(reset) == :infinity
      assert reset.min_samples == 4
      assert ClockFilter.server_time(reset, @t0) == @t0
    end
  end

  ## Helpers

  defp run_exchanges(filter, count, opts) do
    Enum.reduce(1..count, filter, fn i, filter ->
      exchange(filter, @t0 + i * 1_000_000, opts)
    end)
  end

  # One client/time -> server/time round trip against a synthetic
  # server clock, with independent up/down network delays.
  defp exchange(filter, t1, opts \\ []) do
    ppm = Keyword.get(opts, :ppm, 0)
    jitter = Keyword.get(opts, :jitter, 0)
    up = Keyword.get(opts, :up, 1_000) + jitter(jitter)
    down = Keyword.get(opts, :down, 1_000) + jitter(jitter)
    processing = 200

    server_received = server_clock(t1 + up, ppm)
    server_transmitted = server_received + processing
    t4 = t1 + up + processing + down

    ClockFilter.update(filter, t1, server_received, server_transmitted, t4)
  end

  defp server_clock(local_us, ppm) do
    local_us + @server_offset + round((local_us - @t0) * ppm / 1_000_000)
  end

  defp mapping_error(filter, local_us, ppm \\ 0) do
    ClockFilter.server_time(filter, local_us) - server_clock(local_us, ppm)
  end

  defp jitter(0), do: 0
  defp jitter(bound), do: :rand.uniform(2 * bound + 1) - 1 - bound
end
