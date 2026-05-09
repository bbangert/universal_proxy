defmodule UniversalProxy.ESPHome.SerialProxy.Relay do
  @moduledoc """
  Per-instance relay process that subscribes to the UART PubSub topic
  for a single port and forwards incoming bytes to the espex connection
  handler as `{:espex_serial_data, handle, data}`.

  One relay is started per `Espex.SerialProxy.open/3` call. The relay's
  pid is the first element of the handle returned to espex, so closing
  the connection (or the connection handler crashing) tears down the
  relay automatically through espex's normal `close/1` callback.
  """

  use GenServer

  @pubsub UniversalProxy.PubSub

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    friendly_name = Keyword.fetch!(opts, :friendly_name)
    subscriber = Keyword.fetch!(opts, :subscriber)

    Phoenix.PubSub.subscribe(@pubsub, "uart:#{friendly_name}")
    ref = Process.monitor(subscriber)

    {:ok, %{path: path, subscriber: subscriber, monitor_ref: ref}}
  end

  @impl true
  def handle_info({:uart_data, %{data: data}}, state) do
    send(state.subscriber, {:espex_serial_data, {self(), state.path}, data})
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor_ref: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
