defmodule UniversalProxyWeb.DashboardLive do
  use UniversalProxyWeb, :live_view

  alias UniversalProxy.UART

  @max_messages 100

  @impl true
  def mount(_params, _session, socket) do
    ports = UART.named_ports()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "uart:port_opened")
      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "uart:port_closed")

      for port <- ports do
        Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "uart:#{port.friendly_name}")
      end
    end

    {:ok,
     socket
     |> assign(:ports, ports)
     |> assign(:messages, [])}
  end

  @impl true
  def handle_info({:uart_data, message}, socket) do
    messages =
      [message | socket.assigns.messages]
      |> Enum.take(@max_messages)

    {:noreply, assign(socket, :messages, messages)}
  end

  def handle_info({:uart_port_opened, %{friendly_name: name}}, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "uart:#{name}")
    end

    ports = UART.named_ports()
    {:noreply, assign(socket, :ports, ports)}
  end

  def handle_info({:uart_port_closed, _info}, socket) do
    ports = UART.named_ports()
    {:noreply, assign(socket, :ports, ports)}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.page_title title="Dashboard" />

      <div class="mt-6">
        <h2 class="text-lg font-semibold text-zinc-800 dark:text-zinc-200 font-mono mb-3">
          Opened UARTs
        </h2>
        <div class="overflow-hidden rounded-lg border border-zinc-200 shadow cyber-surface dark:border-neon-purple/20">
          <table class="min-w-full divide-y divide-zinc-200 dark:divide-neon-purple/20">
            <thead class="bg-zinc-50 dark:bg-cyber-surface/50">
              <tr>
                <th scope="col" class="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-zinc-600 dark:text-neon-purple">
                  Name
                </th>
                <th scope="col" class="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-zinc-600 dark:text-neon-purple">
                  Device Path
                </th>
                <th scope="col" class="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-zinc-600 dark:text-neon-purple">
                  Speed
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-zinc-200 bg-white dark:divide-neon-purple/15 dark:bg-transparent">
              <%= for port <- @ports do %>
                <tr class="hover:bg-zinc-50 dark:hover:bg-neon-purple/5">
                  <td class="whitespace-nowrap px-4 py-3 text-sm font-mono text-zinc-900 dark:text-neon-purple">
                    {port.friendly_name}
                  </td>
                  <td class="whitespace-nowrap px-4 py-3 text-sm font-mono text-zinc-600 dark:text-zinc-300">
                    {port.path}
                  </td>
                  <td class="whitespace-nowrap px-4 py-3 text-sm font-mono text-zinc-600 dark:text-zinc-400">
                    {port.speed}
                  </td>
                </tr>
              <% end %>
              <%= if @ports == [] do %>
                <tr>
                  <td colspan="3" class="px-4 py-8 text-center text-sm text-zinc-500 dark:text-zinc-400">
                    No UART devices currently opened.
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>

      <div class="mt-8">
        <h2 class="text-lg font-semibold text-zinc-800 dark:text-zinc-200 font-mono mb-3">
          Live Message Feed
        </h2>
        <div class="overflow-hidden rounded-lg border border-zinc-200 shadow cyber-surface dark:border-neon-purple/20">
          <div class="max-h-[32rem] overflow-y-auto">
            <table class="min-w-full divide-y divide-zinc-200 dark:divide-neon-purple/20">
              <thead class="bg-zinc-50 dark:bg-cyber-surface/50 sticky top-0">
                <tr>
                  <th scope="col" class="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-zinc-600 dark:text-neon-purple w-44">
                    Timestamp
                  </th>
                  <th scope="col" class="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-zinc-600 dark:text-neon-purple w-36">
                    Source
                  </th>
                  <th scope="col" class="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-zinc-600 dark:text-neon-purple">
                    Data
                  </th>
                </tr>
              </thead>
              <tbody class="divide-y divide-zinc-200 bg-white dark:divide-neon-purple/15 dark:bg-transparent">
                <%= for msg <- @messages do %>
                  <tr class="hover:bg-zinc-50 dark:hover:bg-neon-purple/5">
                    <td class="whitespace-nowrap px-4 py-2 text-xs font-mono text-zinc-500 dark:text-zinc-400">
                      {format_timestamp(msg.timestamp)}
                    </td>
                    <td class="whitespace-nowrap px-4 py-2 text-sm font-mono text-zinc-900 dark:text-neon-purple">
                      {msg.name}
                    </td>
                    <td class="px-4 py-2 text-sm font-mono text-zinc-600 dark:text-zinc-300 break-all">
                      {format_data(msg.data)}
                    </td>
                  </tr>
                <% end %>
                <%= if @messages == [] do %>
                  <tr>
                    <td colspan="3" class="px-4 py-8 text-center text-sm text-zinc-500 dark:text-zinc-400">
                      No messages received yet.
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S.") <> String.pad_leading("#{dt.microsecond |> elem(0) |> div(1000)}", 3, "0")
  end

  defp format_data(data) when is_binary(data) do
    if String.printable?(data) do
      String.trim(data)
    else
      Base.encode16(data, case: :lower)
    end
  end

  defp format_data(data), do: inspect(data)
end
