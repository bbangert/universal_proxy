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

  Matches the ESPHome reference semantics for `SerialProxyRequest`:
  `open/3` configures the port but the relay does **not** subscribe to
  UART PubSub until the client issues a
  `SERIAL_PROXY_REQUEST_TYPE_SUBSCRIBE`. `unsubscribe/1` detaches the
  subscription so no `:uart_data` messages enter the mailbox while idle.
  The `:subscribed?` flag exists only to make both operations
  idempotent (subscribing twice would duplicate-deliver via PubSub).
  """

  use GenServer

  @pubsub UniversalProxy.PubSub

  @spec start_link(keyword()) :: GenServer.on_start()
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

    ref = Process.monitor(subscriber)

    {:ok,
     %{
       path: path,
       friendly_name: friendly_name,
       subscriber: subscriber,
       monitor_ref: ref,
       subscribed?: false
     }}
  end

  @impl true
  def handle_call(:subscribe, _from, %{subscribed?: false} = state) do
    # PubSub topic keys on `friendly_name`; the forwarded espex handle uses
    # `path`. They are intentionally different identifiers for the same port.
    :ok = Phoenix.PubSub.subscribe(@pubsub, "uart:#{state.friendly_name}")
    {:reply, :ok, %{state | subscribed?: true}}
  end

  def handle_call(:subscribe, _from, state), do: {:reply, :ok, state}

  def handle_call(:unsubscribe, _from, %{subscribed?: true} = state) do
    :ok = Phoenix.PubSub.unsubscribe(@pubsub, "uart:#{state.friendly_name}")
    {:reply, :ok, %{state | subscribed?: false}}
  end

  def handle_call(:unsubscribe, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info({:uart_data, %{data: data}}, %{subscribed?: true} = state) do
    send(state.subscriber, {:espex_serial_data, {self(), state.path}, data})
    {:noreply, state}
  end

  # Race-window guard: a `:uart_data` broadcast can land in the mailbox during
  # the gap between the broadcaster's send and our `PubSub.unsubscribe` taking
  # effect. The flag check drops those stragglers instead of forwarding after
  # the client believes the channel is closed.
  def handle_info({:uart_data, _msg}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor_ref: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
