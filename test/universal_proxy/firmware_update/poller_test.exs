defmodule UniversalProxy.FirmwareUpdate.PollerTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.FirmwareUpdate.Poller

  defp state(overrides \\ %{}) do
    Map.merge(
      %{interval_ms: :timer.hours(24), rand_fun: &:rand.uniform/1},
      overrides
    )
  end

  describe "startup_delay/1" do
    test "lands in the 1–15 minute window" do
      for _ <- 1..200 do
        delay = Poller.startup_delay(state())
        assert delay >= :timer.minutes(1)
        assert delay <= :timer.minutes(15)
      end
    end

    test "is actually spread, not a constant" do
      delays = Enum.map(1..100, fn _ -> Poller.startup_delay(state()) end)
      assert length(Enum.uniq(delays)) > 1
    end
  end

  describe "next_delay/1" do
    test "stays within ±10% of the configured interval" do
      interval = :timer.hours(24)
      spread = trunc(interval * 0.1)

      for _ <- 1..200 do
        delay = Poller.next_delay(state(%{interval_ms: interval}))
        assert delay >= interval - spread
        assert delay <= interval + spread
      end
    end

    test "is jittered rather than fixed" do
      delays = Enum.map(1..100, fn _ -> Poller.next_delay(state()) end)
      assert length(Enum.uniq(delays)) > 1
    end

    test "never returns a non-positive delay for a tiny interval" do
      # A pathological interval must not produce a 0/negative send_after.
      for _ <- 1..100 do
        assert Poller.next_delay(state(%{interval_ms: 1})) >= 1
      end
    end
  end

  describe "check scheduling" do
    test "fires a check after the scheduled delay and reschedules" do
      test_pid = self()

      pid =
        start_supervised!({
          Poller,
          # Collapse both jitter windows to ~0 so the test doesn't wait.
          name: :"poller_#{System.unique_integer([:positive])}",
          enabled: true,
          interval_ms: 40,
          rand_fun: fn _n -> 1 end,
          check_fun: fn ->
            send(test_pid, :checked)
            :ok
          end
        })

      # Startup delay is jitter-floored to 1 min, so drive the first tick
      # directly rather than waiting on wall-clock time.
      send(pid, :check)
      assert_receive :checked, 500

      # Having rescheduled at ~interval_ms, a second check follows on its own.
      assert_receive :checked, 500
    end

    test "a rejected check keeps the loop running" do
      test_pid = self()

      pid =
        start_supervised!(
          {Poller,
           name: :"poller_#{System.unique_integer([:positive])}",
           enabled: true,
           interval_ms: 40,
           rand_fun: fn _n -> 1 end,
           check_fun: fn ->
             send(test_pid, :checked)
             {:error, :busy}
           end}
        )

      send(pid, :check)
      assert_receive :checked, 500
      # Still scheduled despite the rejection.
      assert_receive :checked, 500
      assert Process.alive?(pid)
    end

    test "disabled arms no timer" do
      pid =
        start_supervised!(
          {Poller,
           name: :"poller_#{System.unique_integer([:positive])}",
           enabled: false,
           check_fun: fn -> flunk("must not check when disabled") end}
        )

      assert :sys.get_state(pid).timer == nil
      refute_receive :checked, 150
      assert Process.alive?(pid)
    end
  end
end
