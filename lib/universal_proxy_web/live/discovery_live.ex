defmodule UniversalProxyWeb.DiscoveryLive do
  @moduledoc """
  Discovery tab — friendly name, hostname and ESPHome device id. The
  friendly name and device id are saved through UniversalProxy.ESPHome;
  hostname and service are derived/read-only.
  """

  use UniversalProxyWeb, :live_view

  import UniversalProxyWeb.Components.UI
  import UniversalProxyWeb.Components.Icons

  alias UniversalProxy.ESPHome
  alias UniversalProxy.ESPHome.MdnsAdapter
  alias UniversalProxyWeb.MockData

  @impl true
  def mount(_params, _session, socket) do
    initial = build_form()

    {:ok,
     socket
     |> assign(:page_title, "Discovery")
     |> assign(:form, initial)
     |> assign(:original, initial)}
  end

  @impl true
  def handle_event("change", %{"discovery" => params}, socket) do
    esphome_id = params["esphome_id"] || socket.assigns.form.esphome_id

    form = %{
      friendly: params["friendly"] || socket.assigns.form.friendly,
      hostname: hostname_for(esphome_id),
      service: socket.assigns.form.service,
      esphome_id: esphome_id
    }

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("save", _params, socket) do
    case ESPHome.update_config(
           name: socket.assigns.form.esphome_id,
           friendly_name: socket.assigns.form.friendly
         ) do
      {:ok, _config} ->
        {:noreply,
         socket
         |> assign(:original, socket.assigns.form)
         |> put_flash(:info, "Saved. We restarted the mDNS advertiser.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
    end
  end

  def handle_event("discard", _params, socket) do
    {:noreply, assign(socket, :form, socket.assigns.original)}
  end

  defp build_form do
    cfg = ESPHome.config()
    defaults = MockData.discovery_defaults()
    esphome_id = Map.get(cfg, :name) || defaults.esphome_id

    %{
      friendly: Map.get(cfg, :friendly_name) || defaults.friendly,
      hostname: hostname_for(esphome_id),
      service: defaults.service,
      esphome_id: esphome_id
    }
  end

  # The device's unique hostname IS the ESPHome node name (which carries
  # the per-device MAC suffix) — `MdnsAdapter` advertises it as
  # `<name>.local`. Derived, never free-typed, and gated through the SAME
  # `host_alias/1` check the adapter uses: a name it would refuse to
  # advertise (spaces, underscores, empty) must not render as a hostname
  # mDNS never answers. In that case fall back to the OS hostname
  # (`nerves-XXXX.local`), which is always advertised — also making the
  # live preview honest while an invalid name is being typed.
  defp hostname_for(esphome_id) do
    case MdnsAdapter.host_alias(esphome_id) do
      nil -> os_hostname()
      alias_name -> "#{alias_name}.local"
    end
  end

  defp os_hostname do
    {:ok, name} = :inet.gethostname()
    "#{name}.local"
  end

  defp dirty?(form, original), do: form != original

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :dirty, dirty?(assigns.form, assigns.original))

    ~H"""
    <div class="max-w-[720px] mx-auto">
      <div class="mb-6">
        <.eyebrow>Discovery</.eyebrow>
        <h2 class="text-xl font-semibold mt-1 mb-1.5 text-fg-1">
          How this device appears on your network
        </h2>
        <p class="text-base text-fg-2 m-0">
          We advertise over mDNS so Home Assistant and ESPHome can find the proxy automatically.
          These settings show up in auto-discovery tiles.
        </p>
      </div>

      <.card padding={:lg}>
        <form phx-change="change" class="space-y-5">
          <.field label="Friendly name" help="Shown on the Home Assistant integrations page.">
            <.text_input name="discovery[friendly]" value={@form.friendly} />
          </.field>

          <div class="grid grid-cols-2 gap-4">
            <.field label="Hostname" help="Follows the ESPHome device name.">
              <.text_input name="discovery[hostname]" value={@form.hostname} readonly mono />
            </.field>
            <.field label="mDNS service">
              <.text_input
                name="discovery[service]"
                value={@form.service}
                readonly
                mono
              />
            </.field>
          </div>

          <.field label="ESPHome device name" help="Used as the device_id in ESPHome config.">
            <.text_input name="discovery[esphome_id]" value={@form.esphome_id} mono />
          </.field>
        </form>
      </.card>

      <%!-- Discovery preview --%>
      <div class="mt-6">
        <.eyebrow class="mb-2.5">Discovery preview</.eyebrow>
        <.card id="discovery-preview" class="!p-[18px] flex gap-4 items-center">
          <div class="w-12 h-12 rounded-md bg-accent-soft text-accent flex items-center justify-center flex-none">
            <.icon name={:plug} size={26} />
          </div>
          <div class="flex-1 min-w-0">
            <div class="text-md font-semibold">{@form.friendly}</div>
            <div class="text-sm text-fg-3 mt-0.5">
              <span class="font-mono">{@form.hostname}</span>
            </div>
          </div>
          <.button variant={:primary} size={:sm}>Add to Home Assistant</.button>
        </.card>
      </div>

      <.save_bar dirty={@dirty} msg="We'll restart the mDNS advertiser when you save." />
    </div>
    """
  end
end
