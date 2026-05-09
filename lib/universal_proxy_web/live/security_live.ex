defmodule UniversalProxyWeb.SecurityLive do
  @moduledoc """
  Security tab — ESPHome native API encryption.

  Encryption is opt-in, off by default. Flipping the toggle on generates
  a fresh 32-byte base64 key (kept in socket assigns for now — real
  storage will land with the encryption-key backend).
  """

  use UniversalProxyWeb, :live_view

  import UniversalProxyWeb.Components.UI
  import UniversalProxyWeb.Components.Icons

  alias UniversalProxyWeb.MockData

  @impl true
  def mount(_params, _session, socket) do
    initial = %{enc_enabled: false, api_key: ""}

    {:ok,
     socket
     |> assign(:page_title, "Security")
     |> assign(:sec, initial)
     |> assign(:original, initial)
     |> assign(:show_key, false)
     |> assign(:copied, nil)}
  end

  @impl true
  def handle_event("toggle_enc", _params, socket) do
    sec =
      if socket.assigns.sec.enc_enabled do
        %{socket.assigns.sec | enc_enabled: false}
      else
        %{
          socket.assigns.sec
          | enc_enabled: true,
            api_key:
              if(socket.assigns.sec.api_key == "",
                do: MockData.generate_api_key(),
                else: socket.assigns.sec.api_key
              )
        }
      end

    {:noreply, assign(socket, :sec, sec)}
  end

  def handle_event("regenerate_key", _params, socket) do
    sec = %{socket.assigns.sec | api_key: MockData.generate_api_key()}
    {:noreply, assign(socket, :sec, sec)}
  end

  def handle_event("toggle_show_key", _params, socket) do
    {:noreply, assign(socket, :show_key, !socket.assigns.show_key)}
  end

  def handle_event("copy_key", _params, socket) do
    Process.send_after(self(), :reset_copied, 2_000)

    {:noreply,
     socket
     |> assign(:copied, true)
     |> push_event("copy", %{text: socket.assigns.sec.api_key})}
  end

  def handle_event("save", _params, socket) do
    {:noreply,
     socket
     |> assign(:original, socket.assigns.sec)
     |> put_flash(:info, "Saved. Encryption settings are live.")}
  end

  def handle_event("discard", _params, socket) do
    {:noreply, assign(socket, :sec, socket.assigns.original)}
  end

  @impl true
  def handle_info(:reset_copied, socket) do
    {:noreply, assign(socket, :copied, false)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    enabled = assigns.sec.enc_enabled
    dirty = assigns.sec != assigns.original

    save_msg =
      if enabled,
        do: "Connected clients will be disconnected on save.",
        else: "Encryption will be turned off on save — clients can connect without a key."

    assigns =
      assigns
      |> assign(:enabled, enabled)
      |> assign(:dirty, dirty)
      |> assign(:save_msg, save_msg)

    ~H"""
    <div class="max-w-[720px] mx-auto">
      <div class="mb-6">
        <.eyebrow>Security</.eyebrow>
        <h2 class="text-xl font-semibold mt-1 mb-1.5 text-fg-1">Keep the proxy locked down</h2>
        <p class="text-base text-fg-2 m-0">
          The native API can run encrypted or in the clear. We recommend turning encryption on
          for any network you don't fully trust.
        </p>
      </div>

      <.card padding={:lg}>
        <div class="flex items-start gap-4">
          <div class={[
            "w-9 h-9 rounded-sm flex items-center justify-center flex-none",
            if(@enabled, do: "bg-accent-soft text-accent", else: "bg-sunken text-fg-3")
          ]}>
            <.icon name={:lock} size={18} />
          </div>
          <div class="flex-1">
            <div class="text-base font-semibold">API encryption</div>
            <div class="text-sm text-fg-3 mt-0.5">
              {if @enabled,
                do: "Native API traffic is encrypted with a 32-byte pre-shared key.",
                else: "Off by default. Native API traffic is sent in the clear on your LAN."}
            </div>
          </div>
          <.badge :if={@enabled} variant={:success} dot>Enforced</.badge>
          <.badge :if={!@enabled} variant={:neutral} dot>Off</.badge>
        </div>

        <div class="mt-4 flex items-center gap-3 px-3.5 py-3 border border-border-1 rounded-md">
          <.toggle checked={@enabled} phx-click="toggle_enc" />
          <div class="flex-1 min-w-0">
            <div class="text-sm font-semibold">
              {if @enabled, do: "Encryption is on", else: "Enable encryption"}
            </div>
            <div class="text-sm text-fg-3 mt-0.5">
              {if @enabled,
                do: "Clients must present the key below to connect.",
                else: "We'll generate a fresh 32-byte key for you to paste into Home Assistant."}
            </div>
          </div>
        </div>

        <div :if={@enabled}>
          <div class="mt-3.5 text-sm font-semibold text-fg-2">Pre-shared key</div>
          <div class="text-sm text-fg-3 mt-0.5 mb-2">
            Paste into <span class="font-mono">api: encryption: key:</span>
            in your Home Assistant config.
          </div>
          <div class="flex gap-2">
            <input
              type={if @show_key, do: "text", else: "password"}
              readonly
              value={@sec.api_key}
              class="flex-1 h-9 px-3 rounded-md text-xs font-mono outline-none bg-sunken text-fg-2 border border-border-strong"
            />
            <.button variant={:secondary} size={:sm} phx-click="toggle_show_key">
              {if @show_key, do: "Hide", else: "Show"}
            </.button>
            <.button variant={:secondary} size={:sm} phx-click="copy_key">
              <.icon name={:check} size={14} /> {if @copied, do: "Copied", else: "Copy"}
            </.button>
            <.button variant={:ghost} size={:sm} phx-click="regenerate_key">
              <.icon name={:refresh} size={14} /> Regenerate
            </.button>
          </div>
          <div class="mt-2.5 px-3 py-2.5 bg-warning-soft text-warning rounded-sm text-sm flex gap-2 items-start">
            <.icon name={:alert} size={14} stroke={2.0} />
            <span class="text-fg-1">
              Regenerating this key will disconnect Home Assistant. You'll need to paste the new
              value into your ESPHome config and reload.
            </span>
          </div>
        </div>

        <div
          :if={!@enabled}
          class="mt-3.5 px-3 py-2.5 bg-sunken rounded-sm text-sm flex gap-2 items-start text-fg-2"
        >
          <.icon name={:info} size={14} stroke={2.0} />
          <span>
            Fine for trusted home networks and first-run setup. Turn it on before exposing the
            proxy beyond your LAN.
          </span>
        </div>
      </.card>

      <.save_bar dirty={@dirty} msg={@save_msg} />
    </div>
    """
  end
end
