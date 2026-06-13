defmodule UniversalProxyWeb.BluetoothLive do
  @moduledoc """
  Bluetooth tab — BLE proxy status, master/active-connections toggles, and
  radio selection.

  The proxy relays nearby Bluetooth advertisements to Home Assistant over
  the ESPHome native API (the `bluetooth_proxy` model): passive scanning
  always, plus optional "active connections" so HA can reach through to
  GATT devices. Exactly one radio is bound at a time; the rest sit idle.

  All state is read from `UniversalProxy.Bluetooth` and kept live via its
  three PubSub topics:

    * `state_topic/0`  — `{:bluetooth_state, status}` on any toggle / radio
      switch / subtree lifecycle change
    * `stats_topic/0`  — `{:bluetooth_stats, stats}` every second
    * `radios_topic/0` — `{:bluetooth_radios, radios}` on enumeration change

  The public API is safe on every target (disabled-shaped maps + clean
  errors off-target / while the subtree is down), so this view renders the
  same way on the host as on hardware. Every setter bounces espex on the
  backend; the UI disables the controls while a write is in flight to keep
  a click-storm from stacking restarts (the documented LiveView-layer
  obligation).
  """

  use UniversalProxyWeb, :live_view

  require Logger

  import UniversalProxyWeb.Components.UI
  import UniversalProxyWeb.Components.Icons

  alias UniversalProxy.Bluetooth

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, Bluetooth.state_topic())
      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, Bluetooth.stats_topic())
      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, Bluetooth.radios_topic())
    end

    {:ok,
     socket
     |> assign(:page_title, "Bluetooth")
     |> assign(:status, Bluetooth.status())
     |> assign(:stats, Bluetooth.stats())
     |> assign(:radios, Bluetooth.list_radios())
     # Set true around a setter call so the controls disable until the
     # resulting `{:bluetooth_state, _}` broadcast lands (or the call
     # returns) — one mechanism guarding every espex-bouncing write.
     |> assign(:busy, false)}
  end

  # The mutating handlers below early-return while `busy`. The HTML
  # `disabled` attribute already stops a normal browser from firing these,
  # but a scripted websocket client could still send one mid-write — and
  # every setter bounces espex, so this is the authoritative server-side
  # guard against stacking restarts (the HTML disabled is only UX).
  @impl true
  def handle_event("toggle_enabled", _params, %{assigns: %{busy: true}} = socket),
    do: {:noreply, socket}

  def handle_event("toggle_enabled", _params, socket) do
    target = not socket.assigns.status.enabled
    {:noreply, run_setter(socket, fn -> Bluetooth.set_enabled(target) end)}
  end

  def handle_event("toggle_active_connections", _params, %{assigns: %{busy: true}} = socket),
    do: {:noreply, socket}

  def handle_event("toggle_active_connections", _params, socket) do
    status = socket.assigns.status

    # Inert while the master switch is off — mirrors the disabled control.
    if status.enabled do
      target = not status.active_connections.allowed?
      {:noreply, run_setter(socket, fn -> Bluetooth.set_active_connections(target) end)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("select_radio", _params, %{assigns: %{busy: true}} = socket),
    do: {:noreply, socket}

  def handle_event("select_radio", %{"mac" => mac}, socket) when is_binary(mac) do
    {:noreply, run_setter(socket, fn -> Bluetooth.select_radio(mac) end)}
  end

  def handle_event("rescan", _params, socket) do
    radios = Bluetooth.refresh_radios()
    {:noreply, assign(socket, :radios, radios)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:bluetooth_state, status}, socket) do
    # A state broadcast is the completion signal for an in-flight setter.
    {:noreply, socket |> assign(:status, status) |> assign(:busy, false)}
  end

  def handle_info({:bluetooth_stats, stats}, socket) do
    {:noreply, assign(socket, :stats, stats)}
  end

  def handle_info({:bluetooth_radios, radios}, socket) do
    {:noreply, assign(socket, :radios, radios)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Run a setter, flash on error, and mark the view busy so controls
  # disable until the state broadcast clears it. The setters are safe
  # (never raise) and return `:ok | {:error, reason}`.
  defp run_setter(socket, fun) do
    case fun.() do
      :ok ->
        assign(socket, :busy, true)

      {:error, reason} ->
        Logger.warning("Bluetooth setter failed: #{inspect(reason)}")
        put_flash(socket, :error, setter_error(reason))
    end
  end

  defp setter_error(:unknown_radio), do: "That radio is no longer available."
  defp setter_error(:unavailable), do: "Bluetooth is unavailable on this device."
  defp setter_error(_), do: "Bluetooth setting could not be saved."

  # ── render ────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:proxy_status, proxy_status(assigns.status))
      |> assign(:radio_count, length(assigns.radios))

    ~H"""
    <div class="max-w-[720px] mx-auto">
      <%!-- Header --%>
      <div class="mb-6">
        <.eyebrow>Bluetooth</.eyebrow>
        <h2 class="text-xl font-semibold mt-1 mb-1.5 text-fg-1">Bluetooth proxy</h2>
        <p class="text-base text-fg-2 m-0 max-w-[640px]">
          Relays nearby Bluetooth traffic to Home&nbsp;Assistant over the native API —
          a remote antenna for trackers, sensors, and smart locks that are out of
          range of your server.
        </p>
      </div>

      <%!-- Proxy card --%>
      <.card padding={:none} class="overflow-hidden">
        <div class="flex items-start gap-4 p-[20px_22px]">
          <%!-- Icon tile with pulse ring while relaying --%>
          <div class="relative flex-none w-11 h-11">
            <span
              :if={@status.proxying?}
              class="absolute inset-0 rounded-[10px] border-[1.5px] border-accent animate-ping motion-reduce:hidden"
            >
            </span>
            <div class={[
              "w-11 h-11 rounded-[10px] flex items-center justify-center transition-colors duration-200",
              if(@status.proxying?, do: "bg-accent-soft text-accent", else: "bg-sunken text-fg-4")
            ]}>
              <.icon name={:bluetooth} size={24} stroke={1.7} />
            </div>
          </div>

          <div class="flex-1 min-w-0">
            <div class="flex items-center gap-2.5">
              <span class="text-md font-semibold">Bluetooth proxy</span>
              <.badge variant={@proxy_status.variant} dot>{@proxy_status.label}</.badge>
            </div>
            <div class="text-xs text-fg-3 mt-1">
              <%= cond do %>
                <% @status.proxying? and @status.adapter -> %>
                  Relaying on <span class="font-mono">{@status.adapter.hci}</span>
                  · {adapter_name(@status.adapter)}
                <% @status.enabled and is_nil(@status.adapter) -> %>
                  Enabled, but no Bluetooth radio is available.
                <% true -> %>
                  Passive scanning and active connections are stopped.
              <% end %>
            </div>
          </div>

          <div class="pt-1">
            <.toggle checked={@status.enabled} phx-click="toggle_enabled" disabled={@busy} />
          </div>
        </div>

        <%!-- Waiting-for-adapter notice --%>
        <div
          :if={@status.enabled and is_nil(@status.adapter)}
          class="mx-[22px] mb-[18px] p-[10px_12px] rounded-md bg-warning-soft text-warning text-xs font-medium flex items-center gap-2"
        >
          <.icon name={:alert} size={14} stroke={2.0} />
          Plug in a USB Bluetooth adapter, or enable the onboard radio. The proxy
          starts automatically when a radio appears.
        </div>

        <%!-- Live stats --%>
        <div :if={@status.proxying?} class="grid grid-cols-3 border-t border-border-2">
          <.bt_stat label="Advertisements / s" value={@stats.ads_per_s} />
          <.bt_stat label="Devices seen · 15 min" value={@stats.devices_15min} divider />
          <.bt_stat label="Active connections" value={active_conn_value(@status)} divider />
        </div>

        <%!-- Active connections toggle --%>
        <div class={[
          "flex items-center gap-3 p-[14px_22px] border-t border-border-2 bg-sunken",
          not @status.enabled && "opacity-55"
        ]}>
          <.toggle
            checked={@status.active_connections.allowed?}
            phx-click="toggle_active_connections"
            disabled={@busy or not @status.enabled}
          />
          <div class="flex-1">
            <div class="text-sm font-medium">Active connections</div>
            <div class="text-[11px] text-fg-3 mt-0.5">
              Let Home&nbsp;Assistant connect to devices through this proxy — needed for
              locks and anything with GATT reads. Passive scanning works either way.
            </div>
          </div>
        </div>
      </.card>

      <%!-- Radios --%>
      <div class="mt-7">
        <div class="flex items-center justify-between mb-2.5">
          <.eyebrow>Radios{if @radio_count > 0, do: " · #{@radio_count}", else: ""}</.eyebrow>
          <button
            type="button"
            phx-click="rescan"
            class="text-xs text-accent font-medium flex items-center gap-1 px-2 py-1 rounded-sm hover:underline bg-transparent border-none cursor-pointer"
          >
            <.icon name={:refresh} size={13} /> Rescan
          </button>
        </div>

        <.card :if={@radio_count == 0} padding={:lg} class="text-center !p-9">
          <div class="w-12 h-12 rounded-xl bg-sunken text-fg-4 mx-auto mb-3 flex items-center justify-center">
            <.icon name={:bluetooth} size={26} stroke={1.7} />
          </div>
          <div class="text-md font-semibold">No Bluetooth radios found</div>
          <p class="text-sm text-fg-2 mt-1.5 mb-0 leading-normal">
            Plug in a USB Bluetooth adapter — most chipsets are detected automatically.
            On an SBC, check that the onboard radio isn't disabled
            (e.g. <span class="font-mono">dtoverlay=disable-bt</span> in the boot config).
          </p>
        </.card>

        <.card :if={@radio_count > 0} padding={:none} class="overflow-hidden">
          <.bt_radio_row
            :for={radio <- @radios}
            radio={radio}
            proxying?={@status.proxying?}
            busy={@busy}
          />
        </.card>

        <p :if={@radio_count == 1} class="text-xs text-fg-3 mt-2.5 mx-0.5 leading-normal">
          Plug in a USB Bluetooth adapter to add another radio — useful if the onboard
          antenna is weak or shielded by the case.
        </p>
      </div>
    </div>
    """
  end

  # ── stat cell ───────────────────────────────────────────────────────────
  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:divider, :boolean, default: false)

  defp bt_stat(assigns) do
    ~H"""
    <div class={["p-[14px_22px]", @divider && "border-l border-border-2"]}>
      <div class="text-md font-semibold font-mono tabular-nums text-fg-1">{@value}</div>
      <div class="text-[11px] text-fg-3 mt-0.5">{@label}</div>
    </div>
    """
  end

  # ── radio row ─────────────────────────────────────────────────────────
  attr(:radio, :map, required: true)
  attr(:proxying?, :boolean, required: true)
  attr(:busy, :boolean, required: true)

  defp bt_radio_row(assigns) do
    ~H"""
    <div class="flex items-center gap-3.5 p-[14px_18px] border-b border-border-2 last:border-b-0">
      <%!-- Bus tile --%>
      <div class={[
        "w-9 h-9 rounded-md flex items-center justify-center flex-none",
        if(@radio.in_use?, do: "bg-accent-soft text-accent", else: "bg-sunken text-fg-3")
      ]}>
        <.icon name={if(@radio.bus == :usb, do: :usb, else: :chip)} size={18} />
      </div>

      <%!-- Name + details --%>
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2 flex-wrap">
          <span class="text-sm font-semibold">{radio_name(@radio)}</span>
          <span :if={@radio.chip} class="text-xs text-fg-3">{@radio.chip}</span>
          <.badge :if={@radio.bt_version} variant={:neutral} class="!text-[10px] !px-1.5 !py-px">
            BT {@radio.bt_version}
          </.badge>
          <.badge :if={@radio.ble?} variant={:neutral} class="!text-[10px] !px-1.5 !py-px">
            BLE
          </.badge>
          <.badge :if={@radio.bredr?} variant={:neutral} class="!text-[10px] !px-1.5 !py-px">
            BR/EDR
          </.badge>
        </div>
        <div class="text-[11px] text-fg-3 mt-0.5 font-mono">
          {@radio.hci}<span :if={@radio.address}> · {@radio.address}</span>
          <span class="font-sans"> · {@radio.detail}</span>
        </div>
      </div>

      <%!-- Selection --%>
      <.badge :if={@radio.in_use?} variant={if(@proxying?, do: :success, else: :accent)} dot>
        {if @proxying?, do: "In use", else: "Selected"}
      </.badge>
      <.button
        :if={not @radio.in_use? and @radio.address}
        variant={:secondary}
        size={:sm}
        phx-click="select_radio"
        phx-value-mac={@radio.address}
        disabled={@busy}
      >
        Use this radio
      </.button>
    </div>
    """
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  # Three-state status badge, derived from the status map (mirrors the
  # design): proxying → success, enabled-but-no-radio → warning, else off.
  defp proxy_status(%{proxying?: true}), do: %{label: "Proxying", variant: :success}
  defp proxy_status(%{enabled: true, adapter: nil}), do: %{label: "No adapter", variant: :warning}
  defp proxy_status(_), do: %{label: "Off", variant: :neutral}

  defp active_conn_value(%{active_connections: %{allowed?: true, used: used, limit: limit}}),
    do: "#{used} of #{limit}"

  defp active_conn_value(_), do: "—"

  # Adapter/radio display name — fall back to a generic label when the
  # daemon hasn't reported a Name yet (nil right after a switch).
  defp adapter_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp adapter_name(_), do: "Bluetooth radio"

  defp radio_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp radio_name(%{bus: :usb}), do: "USB Bluetooth adapter"
  defp radio_name(_), do: "Onboard radio"
end
