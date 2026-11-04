defmodule UniversalProxy.CecBus do
  @moduledoc """
  Drives a `Circuits.CEC.Transport.Fake` as the kernel side of a CEC
  adapter: the requests the adapter made, transmit results, received
  messages and state changes.
  """

  import ExUnit.Assertions

  alias Circuits.CEC.{Message, Struct}
  alias Circuits.CEC.Transport.Fake

  @tx_ok 0x01
  @tx_nack 0x24

  @doc "Requests the adapter made, oldest first."
  def requests(fake), do: for({_id, request} <- Fake.requests(fake), do: request)

  @doc """
  Transmits so far as `{sequence, %Message{}}`. The fake's default responder
  numbers transmits from 1.
  """
  def transmits(fake) do
    for {{:transmit, body}, seq} <-
          fake |> requests() |> Enum.filter(&match?({:transmit, _}, &1)) |> Enum.with_index(1) do
      {:ok, message} = body |> Struct.decode_msg() |> Map.fetch!(:msg) |> Message.decode()
      {seq, message}
    end
  end

  @doc "Waits for the n-th transmit (1-based)."
  def nth_tx(fake, n), do: wait_until(fn -> Enum.at(transmits(fake), n - 1) end)

  @doc "Waits for the first transmit after the first `after_n` matching `fun`."
  def await_tx(fake, fun, after_n \\ 0) do
    wait_until(fn ->
      fake |> transmits() |> Enum.drop(after_n) |> Enum.find(fn {_seq, m} -> fun.(m) end)
    end)
  end

  @doc "Acknowledges transmit `seq`."
  def ack(fake, seq), do: complete(fake, seq, tx_status: @tx_ok)

  @doc "NACKs transmit `seq` (nobody at the destination)."
  def nack(fake, seq), do: complete(fake, seq, tx_status: @tx_nack)

  @doc "Answers request `seq` with the reply `bytes`."
  def reply(fake, seq, bytes),
    do: complete(fake, seq, msg: bytes, tx_status: @tx_ok, rx_status: 0x01)

  def complete(fake, seq, fields) do
    fields = Keyword.put_new(fields, :msg, <<0x40>>)
    :ok = Fake.inject(fake, {:msg, Struct.encode_msg([sequence: seq] ++ fields)})
  end

  @doc "A message from the bus (`bytes` with its header)."
  def receive_msg(fake, bytes),
    do: :ok = Fake.inject(fake, {:msg, Struct.encode_msg(msg: bytes, rx_status: 0x01)})

  @doc "A STATE_CHANGE: physical address and logical-address mask."
  def state_change(fake, pa, mask) do
    event = Struct.encode_event(event: :state_change, phys_addr: pa, log_addr_mask: mask)
    :ok = Fake.inject(fake, {:event, event})
  end

  @doc "Polls `fun` until it returns something other than nil/false."
  def wait_until(fun, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    case fun.() do
      result when result in [nil, false] ->
        if System.monotonic_time(:millisecond) > deadline, do: flunk("condition never held")
        Process.sleep(5)
        do_wait_until(fun, deadline)

      result ->
        result
    end
  end
end
