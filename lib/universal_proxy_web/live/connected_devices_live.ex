defmodule UniversalProxyWeb.ConnectedDevicesLive do
  use UniversalProxyWeb, :live_view

  alias UniversalProxy.UART

  @refresh_interval 10_000

  @speed_options [9600, 19_200, 38_400, 57_600, 115_200, 230_400, 460_800, 921_600]
  @data_bits_options [5, 6, 7, 8]
  @stop_bits_options [1, 2]
  @parity_options [:none, :even, :odd]
  @flow_control_options [:none, :hardware, :software]

  # -- Mount --

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@refresh_interval, self(), :refresh)
      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "uart:port_opened")
      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "uart:port_closed")
    end

    devices = build_device_list()

    {:ok,
     socket
     |> assign(:devices, devices)
     |> assign(:editing, nil)
     |> assign(:form_data, default_form_data())
     |> assign(:speed_options, @speed_options)
     |> assign(:data_bits_options, @data_bits_options)
     |> assign(:stop_bits_options, @stop_bits_options)
     |> assign(:parity_options, @parity_options)
     |> assign(:flow_control_options, @flow_control_options)}
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
      speed: params["speed"],
      data_bits: params["data_bits"],
      stop_bits: params["stop_bits"],
      parity: params["parity"],
      flow_control: params["flow_control"],
      auto_open: params["auto_open"]
    })

    devices = build_device_list()

    {:noreply,
     socket
     |> assign(:devices, devices)
     |> assign(:editing, nil)
     |> put_flash(:info, "Configuration saved for #{serial}.")}
  end

  def handle_event("open", %{"serial" => serial}, socket) do
    case find_device_path(serial) do
      nil ->
        {:noreply, put_flash(socket, :error, "Device #{serial} not currently connected.")}

      path ->
        case UART.get_config(serial) do
          {:ok, config} ->
            opts = [
              speed: config[:speed] || 9600,
              data_bits: config[:data_bits] || 8,
              stop_bits: config[:stop_bits] || 1,
              parity: config[:parity] || :none,
              flow_control: config[:flow_control] || :none,
              friendly_name: config[:friendly_name] || "tty#{serial}"
            ]

            case UART.open(path, opts) do
              {:ok, _pid} ->
                devices = build_device_list()
                {:noreply,
                 socket
                 |> assign(:devices, devices)
                 |> put_flash(:info, "Opened #{path} (#{config[:friendly_name] || serial}).")}

              {:error, reason} ->
                {:noreply, put_flash(socket, :error, "Failed to open #{path}: #{inspect(reason)}")}
            end

          :error ->
            {:noreply, put_flash(socket, :error, "No saved config for #{serial}. Configure first.")}
        end
    end
  end

  def handle_event("close", %{"path" => path}, socket) do
    case UART.close(path) do
      :ok ->
        devices = build_device_list()
        {:noreply,
         socket
         |> assign(:devices, devices)
         |> put_flash(:info, "Closed #{path}.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to close #{path}: #{inspect(reason)}")}
    end
  end

  def handle_event("delete_config", %{"serial" => serial}, socket) do
    UART.delete_config(serial)
    devices = build_device_list()

    {:noreply,
     socket
     |> assign(:devices, devices)
     |> put_flash(:info, "Configuration deleted for #{serial}.")}
  end

  # -- Info callbacks --

  @impl true
  def handle_info(:refresh, socket) do
    devices = build_device_list()
    {:noreply, assign(socket, :devices, devices)}
  end

  def handle_info({:uart_port_opened, _info}, socket) do
    devices = build_device_list()
    {:noreply, assign(socket, :devices, devices)}
  end

  def handle_info({:uart_port_closed, _info}, socket) do
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
    open_ports = UART.ports()

    open_map =
      open_ports
      |> Enum.into(%{}, fn {path, config} -> {path, config} end)

    saved_map =
      saved
      |> Enum.into(%{}, fn config -> {config[:serial_number], config} end)

    # Build from enumerated hardware
    hw_devices =
      enumerated
      |> Enum.map(fn device ->
        serial = device.serial_number
        saved_config = if serial != "-", do: Map.get(saved_map, serial)
        is_open = Map.has_key?(open_map, device.path)

        status =
          cond do
            is_open -> :open
            saved_config != nil -> :configured
            true -> :unconfigured
          end

        open_config = if is_open, do: Map.get(open_map, device.path)

        device
        |> Map.put(:status, status)
        |> Map.put(:saved_config, saved_config)
        |> Map.put(:open_config, open_config)
      end)

    # Check for saved configs whose serial is not in the enumerated set
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
          saved_config: config,
          open_config: nil
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

  defp find_device_path(serial) do
    Circuits.UART.enumerate()
    |> Enum.find_value(fn {path, info} ->
      if info[:serial_number] == serial, do: path
    end)
  rescue
    _e -> nil
  end

  defp default_form_data do
    %{
      "speed" => "9600",
      "data_bits" => "8",
      "stop_bits" => "1",
      "parity" => "none",
      "flow_control" => "none",
      "auto_open" => "false"
    }
  end

  defp config_to_form(config) do
    %{
      "speed" => to_string(config[:speed] || 9600),
      "data_bits" => to_string(config[:data_bits] || 8),
      "stop_bits" => to_string(config[:stop_bits] || 1),
      "parity" => to_string(config[:parity] || :none),
      "flow_control" => to_string(config[:flow_control] || :none),
      "auto_open" => to_string(config[:auto_open] || false)
    }
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(s) when is_binary(s), do: String.trim(s) != ""
  defp present?(_), do: false

  defp format_id(nil), do: "-"
  defp format_id(id) when is_integer(id), do: "0x#{Integer.to_string(id, 16)}"
  defp format_id(id), do: to_string(id)

  # -- Template --

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.page_title title="Connected Devices" />
      <.body>
        Serial devices discovered via hardware enumeration. Configure settings, open, or close each device.
        Saved configurations persist across reboots.
      </.body>

      <div class="mt-6 space-y-4">
        <%= for device <- @devices do %>
          <.device_card
            device={device}
            editing={@editing}
            form_data={@form_data}
            speed_options={@speed_options}
            data_bits_options={@data_bits_options}
            stop_bits_options={@stop_bits_options}
            parity_options={@parity_options}
            flow_control_options={@flow_control_options}
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

      <%!-- Config summary when configured or open --%>
      <%= if @device.status in [:configured, :open] do %>
        <.config_summary device={@device} />
      <% end %>

      <%!-- Inline edit form --%>
      <%= if @editing == @device.serial_number and @device.serial_number != "-" do %>
        <.config_form
          serial={@device.serial_number}
          form_data={@form_data}
          speed_options={@speed_options}
          data_bits_options={@data_bits_options}
          stop_bits_options={@stop_bits_options}
          parity_options={@parity_options}
          flow_control_options={@flow_control_options}
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

  defp status_classes(:open), do: "bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-300"
  defp status_classes(:configured), do: "bg-yellow-100 text-yellow-800 dark:bg-yellow-900/30 dark:text-yellow-300"
  defp status_classes(:unconfigured), do: "bg-zinc-100 text-zinc-600 dark:bg-zinc-800/50 dark:text-zinc-400"

  defp status_label(:open), do: "Open"
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
        <%= if @device.path != "not connected" do %>
          <button
            phx-click="open"
            phx-value-serial={@device.serial_number}
            class="inline-flex items-center rounded-md border border-green-400/40 bg-transparent px-3 py-1.5 text-xs font-medium text-green-700 transition hover:bg-green-100 dark:text-green-300 dark:hover:bg-green-900/20"
          >
            Open
          </button>
        <% end %>
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
          data-confirm="Delete saved config for this device?"
          class="inline-flex items-center rounded-md border border-red-400/40 bg-transparent px-3 py-1.5 text-xs font-medium text-red-700 transition hover:bg-red-100 dark:text-red-300 dark:hover:bg-red-900/20"
        >
          Delete
        </button>

      <% :open -> %>
        <button
          phx-click="close"
          phx-value-path={@device.path}
          class="inline-flex items-center rounded-md border border-red-400/40 bg-transparent px-3 py-1.5 text-xs font-medium text-red-700 transition hover:bg-red-100 dark:text-red-300 dark:hover:bg-red-900/20"
        >
          Close
        </button>
        <%= if @device.serial_number != "-" do %>
          <button
            phx-click="edit"
            phx-value-serial={@device.serial_number}
            class="inline-flex items-center rounded-md border border-neon-purple/40 bg-transparent px-3 py-1.5 text-xs font-medium text-zinc-700 transition hover:bg-neon-purple/10 dark:text-neon-purple dark:hover:bg-neon-purple/20"
          >
            Edit
          </button>
        <% end %>
    <% end %>
    """
  end

  # -- Config summary --

  defp config_summary(assigns) do
    config = assigns.device.saved_config || %{}
    open_config = assigns.device.open_config

    speed = if open_config, do: open_config.speed, else: config[:speed] || "-"
    data_bits = if open_config, do: open_config.data_bits, else: config[:data_bits] || "-"
    stop_bits = if open_config, do: open_config.stop_bits, else: config[:stop_bits] || "-"
    parity = if open_config, do: open_config.parity, else: config[:parity] || "-"
    flow_control = if open_config, do: open_config.flow_control, else: config[:flow_control] || "-"
    auto_open = config[:auto_open] || false

    assigns =
      assigns
      |> assign(:speed, speed)
      |> assign(:data_bits, data_bits)
      |> assign(:stop_bits, stop_bits)
      |> assign(:parity, parity)
      |> assign(:flow_control, flow_control)
      |> assign(:auto_open, auto_open)

    ~H"""
    <div class="border-t border-zinc-200 dark:border-neon-purple/10 px-4 py-2 flex flex-wrap gap-x-6 gap-y-1 text-xs text-zinc-500 dark:text-zinc-400">
      <span><strong class="text-zinc-600 dark:text-zinc-300">Speed:</strong> <%= @speed %></span>
      <span><strong class="text-zinc-600 dark:text-zinc-300">Data bits:</strong> <%= @data_bits %></span>
      <span><strong class="text-zinc-600 dark:text-zinc-300">Stop bits:</strong> <%= @stop_bits %></span>
      <span><strong class="text-zinc-600 dark:text-zinc-300">Parity:</strong> <%= @parity %></span>
      <span><strong class="text-zinc-600 dark:text-zinc-300">Flow:</strong> <%= @flow_control %></span>
      <span>
        <strong class="text-zinc-600 dark:text-zinc-300">Auto-open:</strong>
        <%= if @auto_open, do: "Yes", else: "No" %>
      </span>
    </div>
    """
  end

  # -- Inline config form --

  defp config_form(assigns) do
    ~H"""
    <div class="border-t border-neon-purple/20 bg-zinc-50/50 dark:bg-cyber-surface/30 px-4 py-4">
      <form phx-change="validate" phx-submit="save">
        <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-4">
          <%!-- Speed --%>
          <div>
            <label for="config_speed" class="block text-xs font-medium text-zinc-600 dark:text-neon-purple mb-1">
              Speed (baud)
            </label>
            <select
              name="config[speed]"
              id="config_speed"
              class="w-full rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-sm font-mono shadow-sm dark:border-neon-purple/30 dark:bg-[rgba(18,18,26,0.9)] dark:text-zinc-200"
            >
              <%= for speed <- @speed_options do %>
                <option value={speed} selected={to_string(speed) == @form_data["speed"]}>
                  <%= speed %>
                </option>
              <% end %>
            </select>
          </div>

          <%!-- Data bits --%>
          <div>
            <label for="config_data_bits" class="block text-xs font-medium text-zinc-600 dark:text-neon-purple mb-1">
              Data bits
            </label>
            <select
              name="config[data_bits]"
              id="config_data_bits"
              class="w-full rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-sm font-mono shadow-sm dark:border-neon-purple/30 dark:bg-[rgba(18,18,26,0.9)] dark:text-zinc-200"
            >
              <%= for bits <- @data_bits_options do %>
                <option value={bits} selected={to_string(bits) == @form_data["data_bits"]}>
                  <%= bits %>
                </option>
              <% end %>
            </select>
          </div>

          <%!-- Stop bits --%>
          <div>
            <label for="config_stop_bits" class="block text-xs font-medium text-zinc-600 dark:text-neon-purple mb-1">
              Stop bits
            </label>
            <select
              name="config[stop_bits]"
              id="config_stop_bits"
              class="w-full rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-sm font-mono shadow-sm dark:border-neon-purple/30 dark:bg-[rgba(18,18,26,0.9)] dark:text-zinc-200"
            >
              <%= for bits <- @stop_bits_options do %>
                <option value={bits} selected={to_string(bits) == @form_data["stop_bits"]}>
                  <%= bits %>
                </option>
              <% end %>
            </select>
          </div>

          <%!-- Parity --%>
          <div>
            <label for="config_parity" class="block text-xs font-medium text-zinc-600 dark:text-neon-purple mb-1">
              Parity
            </label>
            <select
              name="config[parity]"
              id="config_parity"
              class="w-full rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-sm font-mono shadow-sm dark:border-neon-purple/30 dark:bg-[rgba(18,18,26,0.9)] dark:text-zinc-200"
            >
              <%= for parity <- @parity_options do %>
                <option value={parity} selected={to_string(parity) == @form_data["parity"]}>
                  <%= parity %>
                </option>
              <% end %>
            </select>
          </div>

          <%!-- Flow control --%>
          <div>
            <label for="config_flow_control" class="block text-xs font-medium text-zinc-600 dark:text-neon-purple mb-1">
              Flow control
            </label>
            <select
              name="config[flow_control]"
              id="config_flow_control"
              class="w-full rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-sm font-mono shadow-sm dark:border-neon-purple/30 dark:bg-[rgba(18,18,26,0.9)] dark:text-zinc-200"
            >
              <%= for fc <- @flow_control_options do %>
                <option value={fc} selected={to_string(fc) == @form_data["flow_control"]}>
                  <%= fc %>
                </option>
              <% end %>
            </select>
          </div>

          <%!-- Auto-open checkbox --%>
          <div class="flex items-end pb-1">
            <label class="flex items-center gap-2 cursor-pointer">
              <input
                type="hidden"
                name="config[auto_open]"
                value="false"
              />
              <input
                type="checkbox"
                name="config[auto_open]"
                value="true"
                checked={@form_data["auto_open"] == "true"}
                class="rounded border-zinc-300 text-neon-purple focus:ring-neon-purple dark:border-neon-purple/30 dark:bg-[rgba(18,18,26,0.9)]"
              />
              <span class="text-xs font-medium text-zinc-600 dark:text-neon-purple">Auto-open</span>
            </label>
          </div>
        </div>

        <div class="mt-4 flex justify-end gap-3">
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
      </form>
    </div>
    """
  end
end
