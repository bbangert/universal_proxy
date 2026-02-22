defmodule UniversalProxyWeb.ConnectedDevicesLive do
  use UniversalProxyWeb, :live_view

  alias UniversalProxy.UART

  @refresh_interval 10_000
  @port_type_options [:ttl, :rs232, :rs485]

  # -- Mount --

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@refresh_interval, self(), :refresh)
    end

    devices = build_device_list()

    {:ok,
     socket
     |> assign(:devices, devices)
     |> assign(:editing, nil)
     |> assign(:form_data, default_form_data())
     |> assign(:port_type_options, @port_type_options)}
  end

  # -- Events --

  @impl true
  def handle_event("configure", %{"serial" => serial}, socket) do
    form_data = default_form_data()
    {:noreply, assign(socket, editing: serial, form_data: form_data)}
  end

  def handle_event("edit", %{"serial" => serial}, socket) do
    form_data =
      case UART.get_config(serial) do
        {:ok, config} -> config_to_form(config)
        :error -> default_form_data()
      end

    {:noreply, assign(socket, editing: serial, form_data: form_data)}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, editing: nil)}
  end

  def handle_event("validate", %{"config" => params}, socket) do
    {:noreply, assign(socket, :form_data, params)}
  end

  def handle_event("save", %{"config" => params}, socket) do
    serial = socket.assigns.editing

    UART.save_config(serial, %{
      port_type: params["port_type"]
    })

    devices = build_device_list()

    {:noreply,
     socket
     |> assign(:devices, devices)
     |> assign(:editing, nil)
     |> put_flash(:info, "Configuration saved for #{serial}. ESPHome clients will reconnect.")}
  end

  def handle_event("delete_config", %{"serial" => serial}, socket) do
    UART.delete_config(serial)
    devices = build_device_list()

    {:noreply,
     socket
     |> assign(:devices, devices)
     |> put_flash(:info, "Configuration deleted for #{serial}. ESPHome clients will reconnect.")}
  end

  # -- Info callbacks --

  @impl true
  def handle_info(:refresh, socket) do
    devices = build_device_list()
    {:noreply, assign(socket, :devices, devices)}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # -- Data helpers --

  defp build_device_list do
    enumerated = enumerate_devices()
    saved = UART.saved_configs()

    saved_map =
      saved
      |> Enum.into(%{}, fn config -> {config[:serial_number], config} end)

    hw_devices =
      enumerated
      |> Enum.map(fn device ->
        serial = device.serial_number
        saved_config = if serial != "-", do: Map.get(saved_map, serial)

        status = if saved_config, do: :configured, else: :unconfigured

        device
        |> Map.put(:status, status)
        |> Map.put(:saved_config, saved_config)
      end)

    # Show saved configs for disconnected devices
    enumerated_serials =
      enumerated
      |> Enum.map(& &1.serial_number)
      |> MapSet.new()

    orphaned =
      saved
      |> Enum.reject(fn config -> MapSet.member?(enumerated_serials, config[:serial_number]) end)
      |> Enum.map(fn config ->
        %{
          path: "not connected",
          description: config[:friendly_name] || "tty#{config[:serial_number]}",
          manufacturer: "-",
          product_id: "-",
          vendor_id: "-",
          serial_number: config[:serial_number],
          status: :configured,
          saved_config: config
        }
      end)

    hw_devices ++ orphaned
  end

  defp enumerate_devices do
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
    _e -> []
  end

  defp default_form_data do
    %{"port_type" => "ttl"}
  end

  defp config_to_form(config) do
    %{"port_type" => to_string(config[:port_type] || :ttl)}
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(s) when is_binary(s), do: String.trim(s) != ""
  defp present?(_), do: false

  defp format_id(nil), do: "-"
  defp format_id(id) when is_integer(id), do: "0x#{Integer.to_string(id, 16)}"
  defp format_id(id), do: to_string(id)

  defp port_type_label(:ttl), do: "TTL"
  defp port_type_label(:rs232), do: "RS-232"
  defp port_type_label(:rs485), do: "RS-485"
  defp port_type_label(:zwave), do: "Z-Wave"
  defp port_type_label(other), do: to_string(other) |> String.upcase()

  # -- Template --

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.page_title title="Connected Devices" />
      <.body>
        Serial devices discovered via hardware enumeration. Configure a port type to advertise the
        device as a serial proxy to ESPHome clients. Serial settings are provided by clients at runtime.
        Home Assistant Connect ZWA-2 controllers are auto-detected and configured as Z-Wave proxies.
      </.body>

      <div class="mt-6 space-y-4">
        <%= for device <- @devices do %>
          <.device_card
            device={device}
            editing={@editing}
            form_data={@form_data}
            port_type_options={@port_type_options}
          />
        <% end %>

        <%= if @devices == [] do %>
          <div class="rounded-lg border border-zinc-200 dark:border-neon-purple/20 cyber-surface px-6 py-8 text-center text-sm text-zinc-500 dark:text-zinc-400">
            No UART devices found.
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # -- Device card component --

  defp device_card(assigns) do
    ~H"""
    <div class="rounded-lg border border-zinc-200 dark:border-neon-purple/20 cyber-surface shadow overflow-hidden">
      <%!-- Header row --%>
      <div class="flex items-center justify-between px-4 py-3 bg-zinc-50 dark:bg-cyber-surface/50">
        <div class="flex items-center gap-3">
          <.status_badge status={@device.status} />
          <span class="text-sm font-mono font-medium text-zinc-900 dark:text-neon-purple">
            <%= @device.path %>
          </span>
          <span class="text-xs text-zinc-500 dark:text-zinc-400">
            <%= @device.description %>
          </span>
          <%= if @device.serial_number != "-" do %>
            <span class="text-xs font-mono text-zinc-400 dark:text-zinc-500">
              SN: <%= @device.serial_number %>
            </span>
          <% end %>
        </div>
        <div class="flex items-center gap-2">
          <.device_actions device={@device} />
        </div>
      </div>

      <%!-- Config summary when configured --%>
      <%= if @device.status == :configured do %>
        <.config_summary device={@device} />
      <% end %>

      <%!-- Inline edit form --%>
      <%= if @editing == @device.serial_number and @device.serial_number != "-" do %>
        <.config_form
          serial={@device.serial_number}
          form_data={@form_data}
          port_type_options={@port_type_options}
        />
      <% end %>
    </div>
    """
  end

  # -- Status badge --

  defp status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium",
      status_classes(@status)
    ]}>
      <%= status_label(@status) %>
    </span>
    """
  end

  defp status_classes(:configured), do: "bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-300"
  defp status_classes(:unconfigured), do: "bg-zinc-100 text-zinc-600 dark:bg-zinc-800/50 dark:text-zinc-400"

  defp status_label(:configured), do: "Configured"
  defp status_label(:unconfigured), do: "Unconfigured"

  # -- Action buttons --

  defp device_actions(assigns) do
    ~H"""
    <%= case @device.status do %>
      <% :unconfigured -> %>
        <%= if @device.serial_number != "-" do %>
          <button
            phx-click="configure"
            phx-value-serial={@device.serial_number}
            class="inline-flex items-center rounded-md border border-neon-purple/40 bg-transparent px-3 py-1.5 text-xs font-medium text-zinc-700 transition hover:bg-neon-purple/10 dark:text-neon-purple dark:hover:bg-neon-purple/20"
          >
            Configure
          </button>
        <% else %>
          <span class="text-xs text-zinc-400 dark:text-zinc-500 italic">No serial number</span>
        <% end %>

      <% :configured -> %>
        <button
          phx-click="edit"
          phx-value-serial={@device.serial_number}
          class="inline-flex items-center rounded-md border border-neon-purple/40 bg-transparent px-3 py-1.5 text-xs font-medium text-zinc-700 transition hover:bg-neon-purple/10 dark:text-neon-purple dark:hover:bg-neon-purple/20"
        >
          Edit
        </button>
        <button
          phx-click="delete_config"
          phx-value-serial={@device.serial_number}
          data-confirm="Remove this device configuration? ESPHome clients will reconnect."
          class="inline-flex items-center rounded-md border border-red-400/40 bg-transparent px-3 py-1.5 text-xs font-medium text-red-700 transition hover:bg-red-100 dark:text-red-300 dark:hover:bg-red-900/20"
        >
          Delete
        </button>
    <% end %>
    """
  end

  # -- Config summary --

  defp config_summary(assigns) do
    config = assigns.device.saved_config || %{}
    port_type = config[:port_type] || :ttl
    friendly_name = config[:friendly_name] || "tty#{assigns.device.serial_number}"

    assigns =
      assigns
      |> assign(:port_type, port_type)
      |> assign(:friendly_name, friendly_name)

    ~H"""
    <div class="border-t border-zinc-200 dark:border-neon-purple/10 px-4 py-2 flex flex-wrap gap-x-6 gap-y-1 text-xs text-zinc-500 dark:text-zinc-400">
      <span><strong class="text-zinc-600 dark:text-zinc-300">Port type:</strong> <%= port_type_label(@port_type) %></span>
      <span><strong class="text-zinc-600 dark:text-zinc-300">Friendly name:</strong> <%= @friendly_name %></span>
      <%= if @port_type == :zwave do %>
        <span class="inline-flex items-center rounded-full bg-blue-100 px-2 py-0.5 text-xs font-medium text-blue-800 dark:bg-blue-900/30 dark:text-blue-300">
          Auto-detected
        </span>
      <% end %>
    </div>
    """
  end

  # -- Inline config form --

  defp config_form(assigns) do
    ~H"""
    <div class="border-t border-neon-purple/20 bg-zinc-50/50 dark:bg-cyber-surface/30 px-4 py-4">
      <form phx-change="validate" phx-submit="save">
        <div class="flex items-end gap-4">
          <div>
            <label for="config_port_type" class="block text-xs font-medium text-zinc-600 dark:text-neon-purple mb-1">
              Port type
            </label>
            <select
              name="config[port_type]"
              id="config_port_type"
              class="w-48 rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-sm font-mono shadow-sm dark:border-neon-purple/30 dark:bg-[rgba(18,18,26,0.9)] dark:text-zinc-200"
            >
              <%= for pt <- @port_type_options do %>
                <option value={pt} selected={to_string(pt) == @form_data["port_type"]}>
                  <%= port_type_label(pt) %>
                </option>
              <% end %>
            </select>
          </div>

          <div class="flex gap-3">
            <button
              type="button"
              phx-click="cancel"
              class="rounded-md border border-zinc-300 bg-white px-4 py-1.5 text-xs font-medium text-zinc-700 shadow-sm transition hover:bg-zinc-50 dark:border-zinc-600 dark:bg-transparent dark:text-zinc-300 dark:hover:bg-zinc-800"
            >
              Cancel
            </button>
            <button
              type="submit"
              class="rounded-md border border-neon-purple bg-neon-purple/10 px-4 py-1.5 text-xs font-medium text-neon-purple shadow-sm transition hover:bg-neon-purple/20 dark:bg-neon-purple/20 dark:hover:bg-neon-purple/30"
            >
              Save
            </button>
          </div>
        </div>
      </form>
    </div>
    """
  end
end
