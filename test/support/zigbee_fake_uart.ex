defmodule UniversalProxy.ESPHome.ZigbeeProxy.FakeUART do
  @moduledoc """
  Stands in for the Circuits.UART GenServer under
  `UniversalProxy.ESPHome.ZigbeeProxy`: reports every wire-level call to
  the test process and replies `:ok` unless told otherwise with
  `reply_with/3`.
  """

  use GenServer

  def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

  def reply_with(fake, op, reply), do: GenServer.call(fake, {:fake_reply, op, reply})

  @impl true
  def init(test_pid), do: {:ok, %{test: test_pid, replies: %{}}}

  @impl true
  def handle_call({:fake_reply, op, reply}, _from, state) do
    {:reply, :ok, put_in(state.replies[op], reply)}
  end

  def handle_call({:write, data, _timeout}, _from, state) do
    report(state, :write, {:uart_write, IO.iodata_to_binary(data)})
  end

  def handle_call({:configure, opts}, _from, state) do
    report(state, :configure, {:uart_configure, opts})
  end

  def handle_call({:set_dtr, value}, _from, state) do
    report(state, :set_dtr, {:uart_set_dtr, value})
  end

  def handle_call({:set_rts, value}, _from, state) do
    report(state, :set_rts, {:uart_set_rts, value})
  end

  def handle_call(:close, _from, state), do: report(state, :close, :uart_close)

  def handle_call(_msg, _from, state), do: {:reply, :ok, state}

  defp report(state, op, message) do
    send(state.test, message)
    {:reply, Map.get(state.replies, op, :ok), state}
  end
end
