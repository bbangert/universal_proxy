defmodule UniversalProxy.TuyaBeaconMesh.Seq do
  @moduledoc """
  Monotonic 16-bit sequence counter for phone→mesh frames.

  Every bulb tracks the highest phone SN it has heard (across all
  destinations) and silently drops anything at or behind it. Keep one
  counter for the whole mesh, and persist `value/1` before using any
  number it covers so a restart never goes backwards.

  The counter holds two cursors: `next/1`, the next number to hand out,
  and `value/1`, the persisted-form cursor, which is at or ahead of
  `next/1` and past every number handed out or leased. Numbers are handed
  out in one of two ways:

    * `reserve/2` takes a block of 1..99 numbers at once and moves both
      cursors past it;
    * `lease/2` moves only `value/1`, by up to 899 numbers; persist it,
      then `take/1` numbers from the lease one at a time. `give_back/2`
      returns the number just taken (one that provably never went on
      air), and `tighten/2` pulls `value/1` back to `next/1` or a floor
      (see it for when that is safe).

  The counter wraps modulo 2^16 (`65_535, 0, 1, …`), so "ahead" and
  "behind" are serial-number comparisons (RFC 1982 style, `ahead?/2`): `b`
  is ahead of `a` when it is 1..32_767 steps forward of it. A value
  exactly half the range away is ambiguous and counts as not ahead.

  Pure data: no process. Callers hold the struct and pass the updated one
  back.
  """

  @max 65_536
  @half 32_768
  @default_block 32
  @max_block 99
  # A restart resumes at the persisted lease end. The last number that may
  # have gone on air is at least the one before the lease's start (its
  # first number can be given back), so a crash makes the bulbs' tracker
  # jump forward by at most lease + 1. Jumps of about 900 were accepted on
  # hardware and the real limit was never measured, so that jump is capped
  # at 900 and a lease at one less. Both sit far inside the half range
  # that ahead?/2 needs.
  @max_jump 900
  @max_lease @max_jump - 1

  @type t :: %{
          __struct__: __MODULE__,
          next: non_neg_integer(),
          until: non_neg_integer()
        }

  defstruct next: 0, until: 0

  @doc "Starts a counter at `start` (taken modulo 65536), with no lease."
  @spec new(non_neg_integer()) :: t()
  def new(start \\ 0) when is_integer(start) and start >= 0 do
    start = rem(start, @max)
    %__MODULE__{next: start, until: start}
  end

  @doc """
  The persisted-form cursor: past every number handed out, reserved or
  leased. Persist this; a restart resumes from it.
  """
  @spec value(t()) :: non_neg_integer()
  def value(%__MODULE__{until: until}), do: until

  @doc "The number `take/1` hands out next."
  @spec next(t()) :: non_neg_integer()
  def next(%__MODULE__{next: n}), do: n

  @doc "How many leased numbers `take/1` can still hand out."
  @spec remaining(t()) :: non_neg_integer()
  def remaining(%__MODULE__{next: n, until: until}), do: Integer.mod(until - n, @max)

  @doc """
  The largest lease `lease/2` grants (#{@max_lease}): one less than
  `max_jump/0`, so resuming at a lease end after a crash is at most a
  #{@max_jump}-step jump past the last number that may have gone on air.
  """
  @spec max_lease() :: pos_integer()
  def max_lease, do: @max_lease

  @doc """
  The largest forward jump (#{@max_jump}) that **one** crash restart may
  make past the last number that may have gone on air: about what the
  bulbs were seen to accept.

  The bound is per abandoned lease, not cumulative. A restart resumes at
  the lease end (at most `max_lease + 1` past the last number on air);
  if that run is cut short too before any number of its own lease goes
  out (its first number refused, then another crash), the next restart
  resumes at that lease's end in turn. A caller whose first lease after
  a start is `min_lease` therefore jumps at most `max_lease + 1 + k *
  min_lease` after `k` such further restarts: only a crash loop
  accumulates, at the pace its supervisor's restart budget allows.
  """
  @spec max_jump() :: pos_integer()
  def max_jump, do: @max_jump

  @doc """
  Reserves `n` sequence numbers (1..99). Returns `{:ok, sns, new_seq}`
  with the counter already advanced past the block — persist `value/1`
  of `new_seq` before using any of `sns`. The block wraps past 65535 to 0.
  """
  @spec reserve(t(), pos_integer()) ::
          {:ok, [non_neg_integer()], t()} | {:error, :block_too_large | :bad_block_size}
  def reserve(seq, n \\ @default_block)

  def reserve(%__MODULE__{next: start} = seq, n) when is_integer(n) and n in 1..@max_block do
    block = Enum.map(0..(n - 1), fn i -> rem(start + i, @max) end)
    next = rem(start + n, @max)
    {:ok, block, %{seq | next: next, until: later(seq.until, next)}}
  end

  def reserve(%__MODULE__{}, n) when is_integer(n) and n > @max_block,
    do: {:error, :block_too_large}

  def reserve(%__MODULE__{}, _n), do: {:error, :bad_block_size}

  @doc """
  Leases `n` numbers (1..#{@max_lease}) starting at `next/1`: `value/1`
  moves to `next + n`, wrapping past 65535. It never moves back, so a
  lease that still has more than `n` numbers left is kept as it is.
  Persist `value/1` of the result before `take/1` hands any of them out.
  """
  @spec lease(t(), pos_integer()) :: {:ok, t()} | {:error, :lease_too_large | :bad_lease_size}
  def lease(%__MODULE__{next: n} = seq, size) when is_integer(size) and size in 1..@max_lease,
    do: {:ok, %{seq | until: later(seq.until, rem(n + size, @max))}}

  def lease(%__MODULE__{}, size) when is_integer(size) and size > @max_lease,
    do: {:error, :lease_too_large}

  def lease(%__MODULE__{}, _size), do: {:error, :bad_lease_size}

  @doc """
  Hands out the next leased number: `{:ok, sn, new_seq}`, or `{:error,
  :lease_exhausted}` once `next/1` has reached `value/1`.
  """
  @spec take(t()) :: {:ok, non_neg_integer(), t()} | {:error, :lease_exhausted}
  def take(%__MODULE__{next: n, until: n}), do: {:error, :lease_exhausted}
  def take(%__MODULE__{next: n} = seq), do: {:ok, n, %{seq | next: rem(n + 1, @max)}}

  @doc """
  Hands `sn` out again when it is the number `take/1` handed out last
  (one before `next/1`); any other `sn` leaves `seq` unchanged, which
  keeps it used. Only give back a number that provably never went on
  air: the next `take/1` returns it.
  """
  @spec give_back(t(), non_neg_integer()) :: t()
  def give_back(%__MODULE__{next: n} = seq, sn) when is_integer(sn) do
    if Integer.mod(n - sn, @max) == 1, do: %{seq | next: sn}, else: seq
  end

  @doc """
  Ends the lease at `next/1`, or at `floor` when that is later:
  `value/1` becomes the later of the two, dropping the leased numbers
  not yet taken below it. A `floor` at or past `value/1` leaves `seq`
  unchanged (this only ever moves the persisted cursor back).

  Persist the result only when no number at or past it was ever used:
  every number `take/1` handed out is behind `next/1` (whether or not its
  frame went on air), and a given-back number never went on air. Pass a
  `floor` for a cursor that may be stored, or heard, beyond `next/1`.
  """
  @spec tighten(t(), non_neg_integer() | nil) :: t()
  def tighten(seq, floor \\ nil)

  def tighten(%__MODULE__{next: n} = seq, nil), do: tighten(seq, n)

  def tighten(%__MODULE__{next: n, until: until} = seq, floor)
      when is_integer(floor) and floor >= 0 do
    target = later(n, rem(floor, @max))
    if ahead?(target, until), do: %{seq | until: target}, else: seq
  end

  @doc """
  Moves the cursor forward to `value` when `value` is ahead of it
  (`ahead?/2`); otherwise returns `seq` unchanged. Never goes backwards,
  so merging a loaded cursor with the in-memory one can't reuse SNs
  already handed out or reserved. A lease that ends past `value` keeps
  its end; one that ends before it is used up.
  """
  @spec advance_to(t(), non_neg_integer()) :: t()
  def advance_to(%__MODULE__{next: n} = seq, value) when is_integer(value) and value >= 0 do
    value = rem(value, @max)

    if ahead?(n, value),
      do: %{seq | next: value, until: later(seq.until, value)},
      else: seq
  end

  @doc """
  Whether 16-bit serial number `b` is ahead of `a`: 1..32_767 steps
  forward modulo 65536. Equal values and values exactly half the range
  apart are not ahead.
  """
  @spec ahead?(non_neg_integer(), non_neg_integer()) :: boolean()
  def ahead?(a, b) when is_integer(a) and is_integer(b) do
    distance = Integer.mod(b - a, @max)
    distance > 0 and distance < @half
  end

  defp later(a, b), do: if(ahead?(a, b), do: b, else: a)
end
