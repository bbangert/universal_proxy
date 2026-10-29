defmodule UniversalProxy.TuyaBeaconMesh.Seq do
  @moduledoc """
  Monotonic 16-bit sequence counter for phone→mesh frames.

  Every bulb tracks the highest phone SN it has heard (across all
  destinations) and silently drops anything at or behind it. Keep one
  counter for the whole mesh; persist it (`value/1`) whenever a block is
  reserved so a restart never goes backwards.

  Pure data: no process. Callers hold the struct and pass the updated one
  back after `reserve/2`.
  """

  @max 65_536
  @default_block 32
  @max_block 99

  @type t :: %{__struct__: __MODULE__, next: non_neg_integer()}

  defstruct next: 0

  @doc "Starts a counter at `start` (0..65535)."
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
  of `new_seq` before using any of `sns`.
  """
  @spec reserve(t(), pos_integer()) ::
          {:ok, [non_neg_integer()], t()} | {:error, :block_too_large}
  def reserve(seq, n \\ @default_block)

  def reserve(%__MODULE__{next: start} = _seq, n) when is_integer(n) and n in 1..@max_block do
    block = Enum.map(0..(n - 1), fn i -> rem(start + i, @max) end)
    {:ok, block, %__MODULE__{next: rem(start + n, @max)}}
  end

  def reserve(%__MODULE__{}, _n), do: {:error, :block_too_large}
end
