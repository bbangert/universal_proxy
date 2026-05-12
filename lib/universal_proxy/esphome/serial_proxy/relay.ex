defmodule UniversalProxy.ESPHome.SerialProxy.Relay do
  @moduledoc """
  Per-instance relay process that subscribes to the UART PubSub topic
  for a single port and forwards incoming bytes to the espex connection
  handler as `{:espex_serial_data, handle, data}`.

  One relay is started per `Espex.SerialProxy.open/3` call. The relay's
  pid is the first element of the handle returned to espex, so closing
  the connection (or the connection handler crashing) tears down the
  relay automatically through espex's normal `close/1` callback.

  ## Subscribe / unsubscribe

  The relay tracks an explicit `:subscribed?` flag that gates forwarding
  of UART RX bytes to the espex subscriber. This matches the ESPHome
  reference semantics for `SerialProxyRequest` (subscribe before any data
  flows, unsubscribe to stop). The flag starts as `false` — `open/3`
  configures the port but does **not** stream data until the client
  issues a `SERIAL_PROXY_REQUEST_TYPE_SUBSCRIBE`.

  Use `subscribe/1` and `unsubscribe/1` to toggle; both are idempotent.
  """

  use GenServer

  @pubsub UniversalProxy.PubSub

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Enable forwarding of UART RX data to the espex subscriber."
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(relay), do: GenServer.call(relay, :subscribe)

  @doc "Disable forwarding of UART RX data to the espex subscriber."
  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(relay), do: GenServer.call(relay, :unsubscribe)

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    friendly_name = Keyword.fetch!(opts, :friendly_name)
    subscriber = Keyword.fetch!(opts, :subscriber)

    Phoenix.PubSub.subscribe(@pubsub, "uart:#{friendly_name}")
    ref = Process.monitor(subscriber)

    {:ok,
     %{
       path: path,
       subscriber: subscriber,
       monitor_ref: ref,
       subscribed?: false
     }}
  end

  @impl true
  def handle_call(:subscribe, _from, state) do
    {:reply, :ok, %{state | subscribed?: true}}
  end

  def handle_call(:unsubscribe, _from, state) do
    {:reply, :ok, %{state | subscribed?: false}}
  end

  @impl true
  def handle_info({:uart_data, %{data: data}}, %{subscribed?: true} = state) do
    send(state.subscriber, {:espex_serial_data, {self(), state.path}, data})
    {:noreply, state}
  end

  # While unsubscribed, drop incoming bytes — mirrors the ESPHome native
  # implementation, which keeps the read loop disabled until a client
  # subscribes.
  def handle_info({:uart_data, _msg}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor_ref: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
