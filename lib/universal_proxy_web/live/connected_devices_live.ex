defmodule UniversalProxyWeb.ConnectedDevicesLive do
  use UniversalProxyWeb, :live_view

  @refresh_interval 10_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@refresh_interval, self(), :refresh)
    end

    devices = load_uart_devices()

    {:ok,
     socket
     |> assign(:devices, devices)
     |> assign(:error, nil)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    devices = load_uart_devices()

    {:noreply,
     socket
     |> assign(:devices, devices)
     |> assign(:error, nil)}
  end

  defp load_uart_devices do
    Circuits.UART.enumerate()
    |> Enum.filter(fn {_path, info} -> present?(info[:description]) end)
    |> Enum.map(fn {path, info} ->
      %{
        path: path,
        description: info[:description],
        manufacturer: info[:manufacturer] || "-",
        product_id: format_id(info[:product_id]),
        vendor_id: format_id(info[:vendor_id]),
        serial_number: info[:serial_number] || "-"
      }
    end)
  rescue
    _e ->
      []
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(s) when is_binary(s), do: String.trim(s) != ""
  defp present?(_), do: false

  defp format_id(nil), do: "-"
  defp format_id(id) when is_integer(id), do: "0x#{Integer.to_string(id, 16)}"
  defp format_id(id), do: to_string(id)

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.page_title title="Connected Devices" />
      <.body>
        Connected serial ports from Circuits.UART.enumerate(). Shows only devices with descriptions. Refreshes every 10 seconds.
      </.body>

      <div class="mt-6 overflow-hidden rounded-lg border border-zinc-200 shadow cyber-surface cyberpunk-table">
        <table class="min-w-full divide-y divide-zinc-200 dark:divide-neon-purple/20">
          <thead class="bg-zinc-50 dark:bg-cyber-surface/50">
            <tr>
              <th scope="col" class="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-zinc-600 dark:text-neon-purple">
                Device
              </th>
              <th scope="col" class="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-zinc-600 dark:text-neon-purple">
                Description
              </th>
              <th scope="col" class="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-zinc-600 dark:text-neon-purple">
                Manufacturer
              </th>
              <th scope="col" class="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-zinc-600 dark:text-neon-purple">
                Product ID
              </th>
              <th scope="col" class="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-zinc-600 dark:text-neon-purple">
                Vendor ID
              </th>
              <th scope="col" class="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-zinc-600 dark:text-neon-purple">
                Serial Number
              </th>
            </tr>
          </thead>
          <tbody class="divide-y divide-zinc-200 bg-white dark:divide-neon-purple/15 dark:bg-transparent">
            <%= for device <- @devices do %>
              <tr class="hover:bg-zinc-50 dark:hover:bg-neon-purple/5">
                <td class="whitespace-nowrap px-4 py-3 text-sm font-mono text-zinc-900 dark:text-neon-purple dark:font-mono">
                  <%= device.path %>
                </td>
                <td class="px-4 py-3 text-sm text-zinc-600 dark:text-zinc-300">
                  <%= device.description %>
                </td>
                <td class="px-4 py-3 text-sm text-zinc-600 dark:text-zinc-400">
                  <%= device.manufacturer %>
                </td>
                <td class="px-4 py-3 text-sm text-zinc-600 dark:text-zinc-400 font-mono">
                  <%= device.product_id %>
                </td>
                <td class="px-4 py-3 text-sm text-zinc-600 dark:text-zinc-400 font-mono">
                  <%= device.vendor_id %>
                </td>
                <td class="px-4 py-3 text-sm text-zinc-600 dark:text-zinc-400">
                  <%= device.serial_number %>
                </td>
              </tr>
            <% end %>
            <%= if @devices == [] do %>
              <tr>
                <td colspan="6" class="px-4 py-8 text-center text-sm text-zinc-500 dark:text-zinc-400">
                  No UART devices with descriptions found.
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
