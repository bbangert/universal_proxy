defmodule UniversalProxy.TuyaBeaconMesh.Seq do
  @moduledoc """
  Monotonic 16-bit sequence counter for phone→mesh frames.

  Every bulb tracks the highest phone SN it has heard (across all
  destinations) and silently drops anything at or behind it. Keep one
  counter for the whole mesh; persist it (`value/1`) whenever a block is
  reserved so a restart never goes backwards.

  The counter wraps modulo 2^16 (`reserve/2` hands out `65_535, 0, 1, …`),
  so "ahead" and "behind" are serial-number comparisons (RFC 1982 style,
  `ahead?/2`): `b` is ahead of `a` when it is 1..32_767 steps forward of
  it. A value exactly half the range away is ambiguous and counts as not
  ahead.

  Pure data: no process. Callers hold the struct and pass the updated one
  back after `reserve/2` / `advance_to/2`.
  """

  @max 65_536
  @half 32_768
  @default_block 32
  @max_block 99

  @type t :: %{__struct__: __MODULE__, next: non_neg_integer()}

  defstruct next: 0

  @doc "Starts a counter at `start` (taken modulo 65536)."
  @spec new(non_neg_integer()) :: t()
  def new(start \\ 0) when is_integer(start) and start >= 0 do
    %__MODULE__{next: rem(start, @max)}
  end

  @doc "Current next-to-hand-out value (the persisted cursor)."
  @spec value(t()) :: non_neg_integer()
  def value(%__MODULE__{next: n}), do: n

  @doc """
  Reserves `n` sequence numbers (1..99). Returns `{:ok, sns, new_seq}`
  with the counter already advanced past the block — persist `value/1`
  of `new_seq` before using any of `sns`. The block wraps past 65535 to 0.
  """
  @spec reserve(t(), pos_integer()) ::
          {:ok, [non_neg_integer()], t()} | {:error, :block_too_large | :bad_block_size}
  def reserve(seq, n \\ @default_block)

  def reserve(%__MODULE__{next: start}, n) when is_integer(n) and n in 1..@max_block do
    block = Enum.map(0..(n - 1), fn i -> rem(start + i, @max) end)
    {:ok, block, %__MODULE__{next: rem(start + n, @max)}}
  end

  def reserve(%__MODULE__{}, n) when is_integer(n) and n > @max_block,
    do: {:error, :block_too_large}

  def reserve(%__MODULE__{}, _n), do: {:error, :bad_block_size}

  @doc """
  Moves the cursor forward to `value` when `value` is ahead of it
  (`ahead?/2`); otherwise returns `seq` unchanged. Never goes backwards,
  so merging a loaded cursor with the in-memory one can't reuse SNs
  already handed out or reserved.
  """
  @spec advance_to(t(), non_neg_integer()) :: t()
  def advance_to(%__MODULE__{next: n} = seq, value) when is_integer(value) and value >= 0 do
    value = rem(value, @max)
    if ahead?(n, value), do: %__MODULE__{next: value}, else: seq
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
end
