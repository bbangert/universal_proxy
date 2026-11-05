defmodule UniversalProxy.Cec.TvPresenceTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Cec.TvPresence

  @pa 0x1000
  @timings %{first_check: 5, nack_retries: [10, 20, 30], idle: 300, present: 720}

  defp configured do
    {t, [{:recheck_in, 5}]} = TvPresence.link(TvPresence.new(@timings), true, @pa)
    t
  end

  defp observe_all(t, results) do
    Enum.reduce(results, t, fn result, t -> t |> TvPresence.observe(result) |> elem(0) end)
  end

  test "defaults: 5 s first check, 5/30/60 s after NACKs, 5 min idle, 12 min present" do
    assert %{
             first_check: 5_000,
             nack_retries: [5_000, 30_000, 60_000],
             idle: 300_000,
             present: 720_000
           } = TvPresence.new().timings
  end

  test "unknown and quiet while unconfigured" do
    t = TvPresence.new(@timings)
    assert t.presence == :unknown
    assert {^t, []} = TvPresence.observe(t, :present)
    assert {^t, []} = TvPresence.recheck(t)
    assert {%{presence: :unknown}, [:cancel]} = TvPresence.link(t, false, 0xFFFF)
  end

  test "configuring waits for the adapter's own poll, with a fallback recheck" do
    assert {%{presence: :unknown, configured?: true}, [{:recheck_in, 5}]} =
             TvPresence.link(TvPresence.new(@timings), true, @pa)
  end

  test "an ACK is present at once and rechecked at the present cadence" do
    assert {%{presence: :present, nacks: 0}, [{:recheck_in, 720}]} =
             TvPresence.observe(configured(), :present)
  end

  test "absent takes two NACKs, retried after 10, 20, 30 ms then idle" do
    t = configured()

    assert {%{presence: :unknown, nacks: 1} = t, [{:recheck_in, 10}]} =
             TvPresence.observe(t, :absent)

    assert {%{presence: :absent, nacks: 2} = t, [{:recheck_in, 20}]} =
             TvPresence.observe(t, :absent)

    assert {%{presence: :absent, nacks: 3} = t, [{:recheck_in, 30}]} =
             TvPresence.observe(t, :absent)

    assert {%{presence: :absent, nacks: 4}, [{:recheck_in, 300}]} = TvPresence.observe(t, :absent)
  end

  test "a present TV that NACKs once (standby) stays present until the second" do
    t = observe_all(configured(), [:present])

    assert {%{presence: :present, nacks: 1} = t, [{:recheck_in, 10}]} =
             TvPresence.observe(t, :absent)

    assert {%{presence: :absent}, _} = TvPresence.observe(t, :absent)

    # An ACK in between resets the count.
    t = observe_all(t, [:present, :absent])
    assert %{presence: :present, nacks: 1} = t
  end

  test "a TV that comes up after a NACK is present" do
    t = observe_all(configured(), [:absent, :absent, :present])
    assert %{presence: :present, nacks: 0} = t
  end

  test "a bus error counts for nothing" do
    t = configured()

    assert {%{presence: :unknown, nacks: 0}, [{:recheck_in, 300}]} =
             TvPresence.observe(t, :unknown)

    t = observe_all(t, [:absent])

    assert {%{presence: :unknown, nacks: 1}, [{:recheck_in, 10}]} =
             TvPresence.observe(t, :unknown)

    t = observe_all(configured(), [:present])
    assert {%{presence: :present}, [{:recheck_in, 720}]} = TvPresence.observe(t, :unknown)
  end

  test "a recheck polls and sets a fallback at the current cadence" do
    assert {_t, [:poll, {:recheck_in, 300}]} = TvPresence.recheck(configured())

    assert {_t, [:poll, {:recheck_in, 720}]} =
             configured() |> observe_all([:present]) |> TvPresence.recheck()

    assert {_t, [:poll, {:recheck_in, 10}]} =
             configured() |> observe_all([:absent]) |> TvPresence.recheck()
  end

  test "losing the configuration forgets the TV" do
    t = observe_all(configured(), [:present])

    assert {%{presence: :unknown, nacks: 0, configured?: false}, [:cancel]} =
             TvPresence.link(t, false, 0xFFFF)
  end

  test "a new physical address while configured polls at once" do
    t = observe_all(configured(), [:present])
    assert {^t, []} = TvPresence.link(t, true, @pa)

    assert {%{presence: :unknown, phys_addr: 0x2000}, [:poll, {:recheck_in, 5}]} =
             TvPresence.link(t, true, 0x2000)
  end
end
