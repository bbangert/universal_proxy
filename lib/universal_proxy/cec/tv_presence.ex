defmodule UniversalProxy.Cec.TvPresence do
  @moduledoc """
  Whether a CEC TV is on an adapter's bus: a pure reducer over the
  adapter's link state and its TV poll results (`Circuits.CEC.Adapter`'s
  `{:tv_poll, presence}` events), run by `UniversalProxy.Cec.Server`.

  Rules:

    * `:unknown` while the adapter is unconfigured. No HDMI sink, a TV in
      standby that dropped hotplug and a bad EDID all look the same there,
      so nothing about the TV follows from it.
    * The adapter polls the TV itself when it becomes configured; a
      physical-address change while configured polls at once.
    * An ACK (or a Feature Abort) is `:present` straight away.
    * `:absent` takes two NACKs in a row: a TV still booting, or in deep
      standby, misses one. After a NACK the TV is polled again after 5 s,
      30 s and 60 s, which also rides out a booting TV. A `:present` TV
      that NACKs once stays `:present` until the second.
    * A bus error (arbitration lost, timeout, ...) counts for nothing.
    * Otherwise rechecks run every 5 min while `:absent` or `:unknown`
      and every 12 min while `:present`.

  Every step returns the new reducer and its effects: `:poll` (poll the TV
  now), `{:recheck_in, ms}` (replace the recheck timer) or `:cancel` (drop
  it). Each recheck sets the next one too, as a fallback for a poll whose
  result never arrives.
  """

  @type presence :: :present | :absent | :unknown
  @type effect :: :poll | {:recheck_in, pos_integer()} | :cancel

  @typedoc """
  `first_check` is the fallback after a configure (the adapter's own poll
  normally answers first), `nack_retries` the delays after the 1st, 2nd,
  ... NACK in a row, `idle` the recheck while absent or unknown and
  `present` the one while present.
  """
  @type timings :: %{
          first_check: pos_integer(),
          nack_retries: [pos_integer()],
          idle: pos_integer(),
          present: pos_integer()
        }

  @type t :: %__MODULE__{
          presence: presence(),
          nacks: non_neg_integer(),
          configured?: boolean(),
          phys_addr: non_neg_integer() | nil,
          timings: timings()
        }

  @default_timings %{
    first_check: 5_000,
    nack_retries: [5_000, 30_000, 60_000],
    idle: 300_000,
    present: 720_000
  }

  @absent_after 2

  defstruct presence: :unknown,
            nacks: 0,
            configured?: false,
            phys_addr: nil,
            timings: @default_timings

  @doc "A reducer for an unconfigured adapter; `timings` override the defaults."
  @spec new(map() | keyword()) :: t()
  def new(timings \\ %{}),
    do: %__MODULE__{timings: Map.merge(@default_timings, Map.new(timings))}

  @spec default_timings() :: timings()
  def default_timings, do: @default_timings

  @doc "The adapter's link changed (or was seen for the first time)."
  @spec link(t(), boolean(), non_neg_integer() | nil) :: {t(), [effect()]}
  def link(t, false, phys_addr) do
    t = %{t | configured?: false, phys_addr: phys_addr, presence: :unknown, nacks: 0}
    {t, [:cancel]}
  end

  def link(%{configured?: false} = t, true, phys_addr) do
    t = %{t | configured?: true, phys_addr: phys_addr, presence: :unknown, nacks: 0}
    {t, [{:recheck_in, t.timings.first_check}]}
  end

  def link(%{phys_addr: phys_addr} = t, true, phys_addr), do: {t, []}

  def link(t, true, phys_addr) do
    t = %{t | phys_addr: phys_addr, presence: :unknown, nacks: 0}
    {t, [:poll, {:recheck_in, t.timings.first_check}]}
  end

  @doc "A TV poll result: `:present`, `:absent` (NACK) or `:unknown` (bus error)."
  @spec observe(t(), presence()) :: {t(), [effect()]}
  def observe(%{configured?: false} = t, _result), do: {t, []}

  def observe(t, :present) do
    t = %{t | presence: :present, nacks: 0}
    {t, [{:recheck_in, next_delay(t)}]}
  end

  def observe(t, :absent) do
    nacks = t.nacks + 1
    presence = if nacks >= @absent_after, do: :absent, else: t.presence
    t = %{t | presence: presence, nacks: nacks}
    {t, [{:recheck_in, next_delay(t)}]}
  end

  def observe(t, :unknown), do: {t, [{:recheck_in, next_delay(t)}]}

  @doc "The recheck timer fired."
  @spec recheck(t()) :: {t(), [effect()]}
  def recheck(%{configured?: false} = t), do: {t, []}
  def recheck(t), do: {t, [:poll, {:recheck_in, next_delay(t)}]}

  @doc "How long until the next poll in this state."
  @spec next_delay(t()) :: pos_integer()
  def next_delay(%{nacks: nacks, timings: timings} = t) when nacks > 0 do
    Enum.at(timings.nack_retries, nacks - 1) || cadence(t)
  end

  def next_delay(t), do: cadence(t)

  defp cadence(%{presence: :present, timings: timings}), do: timings.present
  defp cadence(%{timings: timings}), do: timings.idle
end
