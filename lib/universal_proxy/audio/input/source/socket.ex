defmodule UniversalProxy.Audio.Input.Source.Socket do
  @moduledoc """
  `WebSock` handler for one accepted Music Assistant connection.

  Deliberately dumb: it owns no protocol state at all. Every inbound frame
  is forwarded to the owning `UniversalProxy.Audio.Input.Source` process and
  every outbound frame arrives from it. The Noise session lives in the
  `Source` GenServer and `Decibel` keeps its session state in the *process
  dictionary*, so all crypto has to happen in exactly one process — this
  handler runs in the cowboy connection process and must never touch it.

  ## Messages

  Sent to the `Source` (its pid comes in via `init/1`'s options):

      {:sendspin_ws_open, socket_pid}
      {:sendspin_ws_in, socket_pid, :text | :binary, data}

  Accepted from the `Source`:

      {:sendspin_ws_push, [{:text | :binary, data}, ...]}
      {:sendspin_ws_close, reason}

  The handler also monitors the `Source` and closes the websocket if it
  dies, so a crashed FSM never leaves a half-open connection that Music
  Assistant would keep believing in.
  """

  @behaviour WebSock

  @impl WebSock
  def init(opts) do
    source = Keyword.fetch!(opts, :source)
    monitor = Process.monitor(source)
    send(source, {:sendspin_ws_open, self()})
    {:ok, %{source: source, monitor: monitor}}
  end

  @impl WebSock
  def handle_in({data, opcode: opcode}, state) do
    send(state.source, {:sendspin_ws_in, self(), opcode, data})
    {:ok, state}
  end

  @impl WebSock
  def handle_info({:sendspin_ws_push, frames}, state), do: {:push, frames, state}

  def handle_info({:sendspin_ws_close, _reason}, state), do: {:stop, :normal, state}

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{monitor: monitor} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl WebSock
  def terminate(_reason, _state), do: :ok
end
