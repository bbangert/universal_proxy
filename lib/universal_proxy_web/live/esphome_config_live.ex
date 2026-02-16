defmodule UniversalProxyWeb.ESPhomeConfigLive do
  use UniversalProxyWeb, :live_view

  alias UniversalProxy.ESPHome

  @config_fields [
    {:name, "Device Name", "Hostname used in mDNS and the Native API"},
    {:friendly_name, "Friendly Name", "Human-readable name shown in dashboards"},
    {:mac_address, "MAC Address", "Hardware address reported to clients"},
    {:esphome_version, "ESPHome Version", "Emulated ESPHome firmware version"},
    {:compilation_time, "Compilation Time", "Build timestamp string"},
    {:model, "Model", "Device hardware model"},
    {:manufacturer, "Manufacturer", "Device manufacturer"},
    {:suggested_area, "Suggested Area", "Default area hint for Home Assistant"},
    {:project_name, "Project Name", "Project identifier"},
    {:project_version, "Project Version", "Project version string"},
    {:port, "API Port", "TCP port for the ESPHome Native API (requires restart)"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    config = ESPHome.config()

    {:ok,
     socket
     |> assign(:config, config)
     |> assign(:editing, false)
     |> assign(:form_data, config_to_form(config))
     |> assign(:config_fields, @config_fields)}
  end

  @impl true
  def handle_event("edit", _params, socket) do
    form_data = config_to_form(socket.assigns.config)
    {:noreply, assign(socket, editing: true, form_data: form_data)}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, editing: false)}
  end

  def handle_event("validate", %{"config" => params}, socket) do
    {:noreply, assign(socket, :form_data, params)}
  end

  def handle_event("save", %{"config" => params}, socket) do
    updates = form_to_keyword(params)
    new_config = ESPHome.update_config(updates)

    {:noreply,
     socket
     |> assign(:config, new_config)
     |> assign(:form_data, config_to_form(new_config))
     |> assign(:editing, false)
     |> put_flash(:info, "Configuration updated successfully.")}
  end

  # -- Private helpers --

  defp config_to_form(config) do
    @config_fields
    |> Enum.map(fn {key, _label, _hint} ->
      {Atom.to_string(key), to_string(Map.get(config, key))}
    end)
    |> Map.new()
  end

  defp form_to_keyword(params) do
    @config_fields
    |> Enum.map(fn {key, _label, _hint} ->
      raw = Map.get(params, Atom.to_string(key), "")

      value =
        if key == :port do
          case Integer.parse(raw) do
            {n, _} -> n
            :error -> 6053
          end
        else
          raw
        end

      {key, value}
    end)
  end

  # -- Template --

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.page_title title="ESPHome Config" />
      <.body>
        Device identity for the ESPHome Native API. These values are reported
        to clients during the handshake and advertised via mDNS.
      </.body>

      <%= if @editing do %>
        <.edit_form form_data={@form_data} config_fields={@config_fields} />
      <% else %>
        <.config_display config={@config} config_fields={@config_fields} />
      <% end %>
    </div>
    """
  end

  # -- Read-only display --

  defp config_display(assigns) do
    ~H"""
    <div class="mt-6">
      <div class="flex justify-end mb-4">
        <button
          phx-click="edit"
          class="inline-flex items-center gap-2 rounded-md border border-neon-purple/40 bg-transparent px-4 py-2 text-sm font-medium text-zinc-700 shadow-sm transition hover:bg-neon-purple/10 dark:text-neon-purple dark:hover:bg-neon-purple/20"
        >
          <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" viewBox="0 0 20 20" fill="currentColor">
            <path d="M13.586 3.586a2 2 0 112.828 2.828l-.793.793-2.828-2.828.793-.793zM11.379 5.793L3 14.172V17h2.828l8.38-8.379-2.83-2.828z" />
          </svg>
          Edit
        </button>
      </div>

      <div class="overflow-hidden rounded-lg border border-zinc-200 shadow cyber-surface dark:border-neon-purple/20">
        <dl class="divide-y divide-zinc-200 dark:divide-neon-purple/15">
          <%= for {key, label, hint} <- @config_fields do %>
            <div class="grid grid-cols-3 gap-4 px-4 py-3">
              <dt class="text-sm font-medium text-zinc-600 dark:text-neon-purple" title={hint}>
                {label}
              </dt>
              <dd class="col-span-2 text-sm text-zinc-900 dark:text-zinc-200 font-mono">
                <% value = Map.get(@config, key) %>
                <%= if value == "" or is_nil(value) do %>
                  <span class="text-zinc-400 dark:text-zinc-500 italic">not set</span>
                <% else %>
                  {to_string(value)}
                <% end %>
              </dd>
            </div>
          <% end %>
        </dl>
      </div>
    </div>
    """
  end

  # -- Edit form --

  defp edit_form(assigns) do
    ~H"""
    <div class="mt-6">
      <form phx-change="validate" phx-submit="save">
        <div class="overflow-hidden rounded-lg border border-neon-purple/30 shadow cyber-surface dark:border-neon-purple/40">
          <div class="divide-y divide-zinc-200 dark:divide-neon-purple/15">
            <%= for {key, label, hint} <- @config_fields do %>
              <div class="grid grid-cols-3 gap-4 px-4 py-3 items-center">
                <label
                  for={"config_#{key}"}
                  class="text-sm font-medium text-zinc-600 dark:text-neon-purple"
                  title={hint}
                >
                  {label}
                </label>
                <div class="col-span-2">
                  <input
                    type={if key == :port, do: "number", else: "text"}
                    name={"config[#{key}]"}
                    id={"config_#{key}"}
                    value={Map.get(@form_data, Atom.to_string(key), "")}
                    placeholder={hint}
                    class="w-full rounded-md border border-zinc-300 bg-white px-3 py-1.5 text-sm font-mono text-zinc-900 shadow-sm transition placeholder:text-zinc-400 focus:border-neon-purple focus:ring-1 focus:ring-neon-purple dark:border-neon-purple/30 dark:bg-[rgba(18,18,26,0.9)] dark:text-zinc-200 dark:placeholder:text-zinc-600 dark:focus:border-neon-purple dark:focus:ring-neon-purple/50"
                  />
                </div>
              </div>
            <% end %>
          </div>
        </div>

        <div class="mt-4 flex justify-end gap-3">
          <button
            type="button"
            phx-click="cancel"
            class="rounded-md border border-zinc-300 bg-white px-4 py-2 text-sm font-medium text-zinc-700 shadow-sm transition hover:bg-zinc-50 dark:border-zinc-600 dark:bg-transparent dark:text-zinc-300 dark:hover:bg-zinc-800"
          >
            Cancel
          </button>
          <button
            type="submit"
            class="rounded-md border border-neon-purple bg-neon-purple/10 px-4 py-2 text-sm font-medium text-neon-purple shadow-sm transition hover:bg-neon-purple/20 dark:bg-neon-purple/20 dark:hover:bg-neon-purple/30"
          >
            Save &amp; Reload
          </button>
        </div>
      </form>
    </div>
    """
  end
end
