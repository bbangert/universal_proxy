defmodule Circuits.CEC.Errno do
  @moduledoc """
  Linux errno values reported by the `cec_port` helper.

  Names follow the `:file` convention (`:enoent`, `:ebusy`, ...). The table
  covers what the CEC ioctls can return plus the helper's own errors.
  Numbers are the asm-generic ones used by arm, arm64, riscv and x86; an
  errno outside the table is kept as its integer.

  The ones CEC callers act on:

  | errno | from the kernel CEC API |
  |---|---|
  | `:eperm` | transmit with no logical address claimed |
  | `:enonet` | adapter configuring, or physical address invalid |
  | `:ebusy` | another filehandle is the exclusive initiator/follower, or the transmit queue is full |
  | `:einval` | bad struct field (length, header nibble not ours, reply on a broadcast) |
  | `:enotty` | not a CEC device, or the capability is missing |
  | `:enodev` | adapter unregistered |
  | `:enoent` | no such device node |
  | `:eagain` | queue empty |
  """

  @type t :: atom() | non_neg_integer()

  @table [
    eperm: 1,
    enoent: 2,
    eintr: 4,
    eio: 5,
    enxio: 6,
    eagain: 11,
    enomem: 12,
    eacces: 13,
    efault: 14,
    ebusy: 16,
    enodev: 19,
    einval: 22,
    enotty: 25,
    enospc: 28,
    enosys: 38,
    enonet: 64,
    eopnotsupp: 95,
    etimedout: 110
  ]

  @doc """
  Converts an errno number to its name, or returns the number if unknown.

      iex> Circuits.CEC.Errno.to_atom(16)
      :ebusy
      iex> Circuits.CEC.Errno.to_atom(9999)
      9999
  """
  @spec to_atom(non_neg_integer()) :: t()
  for {name, value} <- @table do
    def to_atom(unquote(value)), do: unquote(name)
  end

  def to_atom(value) when is_integer(value) and value >= 0, do: value

  @doc """
  Converts an errno name (or number) back to its number.

      iex> Circuits.CEC.Errno.to_integer(:enonet)
      64
  """
  @spec to_integer(t()) :: non_neg_integer()
  for {name, value} <- @table do
    def to_integer(unquote(name)), do: unquote(value)
  end

  def to_integer(value) when is_integer(value) and value >= 0, do: value
end
