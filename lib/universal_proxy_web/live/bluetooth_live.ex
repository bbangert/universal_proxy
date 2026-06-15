defmodule UniversalProxyWeb.BluetoothLive do
  @moduledoc """
  Bluetooth tab — BLE proxy status, per-radio roles, and Bluetooth audio
  (A2DP speaker/headset) pairing + management.

  The proxy relays nearby Bluetooth advertisements to Home Assistant over
  the ESPHome native API (the `bluetooth_proxy` model): passive scanning
  always, plus optional "active connections" so HA can reach through to
  GATT devices.

  Each radio carries an explicit **role** — `:proxy` (relays BLE to HA;
  at most one), `:audio` (dedicated to A2DP streaming; any number, one
  speaker each), or `:off`. A single controller can't proxy and stream
  well at once, so with one radio it's one or the other; with ≥2 you can
  run both. Roles are set through `UniversalProxy.Bluetooth.set_role/2`,
  which also disconnects + forgets a radio's paired speakers when it
  leaves the `:audio` role (BlueZ bonds are per-radio) — the UI confirms
  that loss first.

  Paired speakers/headsets are the **durable** Bluetooth-audio surface
  (incl. disconnected ones); the Audio tab only shows them while actively
  streaming. They're owned by `UniversalProxy.Bluetooth.AudioManager`.

  Live state comes from five PubSub topics:

    * `state_topic/0`  — `{:bluetooth_state, status}` on proxy toggles /
      role changes / subtree lifecycle
    * `stats_topic/0`  — `{:bluetooth_stats, stats}` every second
    * `radios_topic/0` — `{:bluetooth_radios, radios}` on enumeration change
    * `"bluetooth:scan"`  — `{:bt_scan, :stopped}` when a pairing scan ends
    * `"bluetooth:audio"` — `{:bt_audio, :pairing, mac, step}` /
      `{:bt_audio, :connection, mac, status}`

  The public API is safe on every target, so this view renders the same
  way on the host as on hardware. Proxy setters bounce espex, so the UI
  disables those controls while a write is in flight.
  """

  use UniversalProxyWeb, :live_view

  require Logger

  import UniversalProxyWeb.Components.UI
  import UniversalProxyWeb.Components.Icons

  alias UniversalProxy.Bluetooth
  alias UniversalProxy.Bluetooth.AudioManager

  # Discovered-device list refresh cadence while a pairing scan runs.
  # AudioManager pushes only `{:bt_scan, :stopped}`, but `list_headphones/0`
  # also returns unpaired discovered A2DP sinks (`paired: false`), so the
  # modal polls it to grow the list.
  @scan_poll_ms 1_500

  @audio_topic "bluetooth:audio"
  @scan_topic "bluetooth:scan"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, Bluetooth.state_topic())
      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, Bluetooth.stats_topic())
      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, Bluetooth.radios_topic())
      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, @scan_topic)
      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, @audio_topic)
    end

    {:ok,
     socket
     |> assign(:page_title, "Bluetooth")
     |> assign(:status, Bluetooth.status())
     |> assign(:stats, Bluetooth.stats())
     |> assign(:radios, Bluetooth.list_radios())
     |> assign(:roles, Bluetooth.roles())
     |> assign(:headphones, AudioManager.list_headphones())
     # Set true around a proxy setter call so its controls disable until
     # the resulting `{:bluetooth_state, _}` broadcast lands.
     |> assign(:busy, false)
     # Per-row "more" menu (Forget) open set, keyed by device MAC.
     |> assign(:menu_open, MapSet.new())
     # `nil` when closed; otherwise the confirm/pairing modal state maps.
     |> assign(:forget, nil)
     |> assign(:deactivate, nil)
     |> assign(:pairing, nil)}
  end

  # ── Proxy controls (espex-bouncing; guarded by `busy`) ──────────────────

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

    if status.enabled do
      target = not status.active_connections.allowed?
      {:noreply, run_setter(socket, fn -> Bluetooth.set_active_connections(target) end)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("rescan", _params, socket) do
    {:noreply, assign(socket, :radios, Bluetooth.refresh_radios())}
  end

  # ── Role selector ───────────────────────────────────────────────────────

  def handle_event("set_role", _params, %{assigns: %{busy: true}} = socket),
    do: {:noreply, socket}

  def handle_event("set_role", %{"mac" => mac, "role" => role_str}, socket)
      when is_binary(mac) do
    role = parse_role(role_str)
    current = role_of(socket.assigns.roles, mac)

    cond do
      is_nil(role) or role == current ->
        {:noreply, socket}

      # Leaving :audio with paired devices is destructive — confirm first.
      current == :audio and paired_on(socket.assigns.headphones, mac) != [] ->
        {:noreply,
         assign(socket, :deactivate, %{
           mac: mac,
           role: role,
           radio_name: radio_name_for(socket.assigns.radios, mac),
           devices: paired_on(socket.assigns.headphones, mac)
         })}

      true ->
        {:noreply, apply_role(socket, mac, role)}
    end
  end

  def handle_event("confirm_deactivate", _params, %{assigns: %{deactivate: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("confirm_deactivate", _params, socket) do
    %{mac: mac, role: role} = socket.assigns.deactivate
    {:noreply, socket |> assign(:deactivate, nil) |> apply_role(mac, role)}
  end

  def handle_event("cancel_deactivate", _params, socket),
    do: {:noreply, assign(socket, :deactivate, nil)}

  # ── Audio-device row actions ────────────────────────────────────────────

  def handle_event("connect_device", %{"mac" => mac}, socket) do
    _ = AudioManager.connect(mac)
    {:noreply, socket}
  end

  def handle_event("disconnect_device", %{"mac" => mac}, socket) do
    _ = AudioManager.disconnect(mac)
    {:noreply, socket}
  end

  def handle_event("toggle_menu", %{"mac" => mac}, socket) do
    {:noreply,
     update(socket, :menu_open, fn open ->
       if MapSet.member?(open, mac), do: MapSet.delete(open, mac), else: MapSet.put(open, mac)
     end)}
  end

  def handle_event("ask_forget", %{"mac" => mac}, socket) do
    case Enum.find(socket.assigns.headphones, &(&1.mac == mac)) do
      nil ->
        {:noreply, socket}

      device ->
        {:noreply,
         socket
         |> update(:menu_open, &MapSet.delete(&1, mac))
         |> assign(:forget, device)}
    end
  end

  def handle_event("confirm_forget", _params, %{assigns: %{forget: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("confirm_forget", _params, socket) do
    mac = socket.assigns.forget.mac
    _ = AudioManager.forget(mac)

    {:noreply,
     socket
     |> update(:menu_open, &MapSet.delete(&1, mac))
     |> assign(:forget, nil)}
  end

  def handle_event("cancel_forget", _params, socket),
    do: {:noreply, assign(socket, :forget, nil)}

  # ── Pairing modal ───────────────────────────────────────────────────────

  def handle_event("open_pair", _params, socket) do
    case audio_radios(socket.assigns.radios, socket.assigns.roles) do
      [] ->
        {:noreply, socket}

      [first | _] ->
        {:noreply,
         assign(socket, :pairing, %{
           phase: :preflight,
           adapter: first.address,
           devices: [],
           elapsed: 0,
           # Monotonic second the active scan began; `elapsed` is derived from
           # it so the counter tracks real wall-clock, not poll-tick count.
           started_at: nil,
           scan_done: false,
           target: nil,
           step: 0,
           error: nil,
           poll_ref: nil
         })}
    end
  end

  def handle_event("pick_pair_radio", %{"mac" => mac}, %{assigns: %{pairing: p}} = socket)
      when not is_nil(p) do
    {:noreply, assign(socket, :pairing, %{p | adapter: mac})}
  end

  def handle_event("start_pair_scan", _params, %{assigns: %{pairing: p}} = socket)
      when not is_nil(p) do
    # Cancel any in-flight poll timer first so a re-entry (scripted/double
    # event) can't strand a self-rescheduling `:scan_poll`.
    cancel_timer(p.poll_ref)

    case AudioManager.start_scan(p.adapter) do
      :ok ->
        ref = Process.send_after(self(), :scan_poll, @scan_poll_ms)

        {:noreply,
         assign(socket, :pairing, %{
           p
           | phase: :scanning,
             devices: [],
             elapsed: 0,
             started_at: System.monotonic_time(:second),
             scan_done: false,
             poll_ref: ref
         })}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, scan_error(reason))}
    end
  end

  def handle_event(
        "pick_device",
        %{"mac" => mac, "name" => name},
        %{assigns: %{pairing: p}} = socket
      )
      when not is_nil(p) do
    _ = AudioManager.stop_scan()
    cancel_timer(p.poll_ref)
    _ = AudioManager.pair(mac, p.adapter)

    {:noreply,
     assign(socket, :pairing, %{
       p
       | phase: :pairing,
         target: %{mac: mac, name: name},
         step: 0,
         error: nil,
         poll_ref: nil
     })}
  end

  def handle_event("pair_retry", _params, %{assigns: %{pairing: p}} = socket)
      when not is_nil(p) do
    # Defensive: drop any live poll timer before resetting to pre-flight.
    cancel_timer(p.poll_ref)

    {:noreply,
     assign(socket, :pairing, %{
       p
       | phase: :preflight,
         devices: [],
         scan_done: false,
         target: nil,
         step: 0,
         error: nil,
         poll_ref: nil
     })}
  end

  def handle_event("close_pair", _params, socket) do
    {:noreply, close_pairing(socket)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # ── PubSub ──────────────────────────────────────────────────────────────

  @impl true
  def handle_info({:bluetooth_state, status}, socket) do
    {:noreply,
     socket
     |> assign(:status, status)
     |> assign(:roles, Bluetooth.roles())
     |> assign(:busy, false)}
  end

  def handle_info({:bluetooth_stats, stats}, socket) do
    {:noreply, assign(socket, :stats, stats)}
  end

  def handle_info({:bluetooth_radios, radios}, socket) do
    {:noreply, assign(socket, :radios, radios)}
  end

  # A connection change (incl. forget-on-deactivate) refreshes the list.
  def handle_info({:bt_audio, :connection, _mac, _status}, socket) do
    {:noreply, assign(socket, :headphones, AudioManager.list_headphones())}
  end

  def handle_info({:bt_audio, :pairing, mac, step}, %{assigns: %{pairing: p}} = socket)
      when not is_nil(p) and p.target != nil do
    if p.target.mac == mac do
      {:noreply, assign(socket, :pairing, apply_pairing_step(p, step))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:bt_audio, :pairing, _mac, _step}, socket), do: {:noreply, socket}

  def handle_info({:bt_scan, :stopped}, %{assigns: %{pairing: p}} = socket)
      when not is_nil(p) and p.phase == :scanning do
    cancel_timer(p.poll_ref)
    {:noreply, assign(socket, :pairing, %{p | scan_done: true, poll_ref: nil})}
  end

  def handle_info({:bt_scan, :stopped}, socket), do: {:noreply, socket}

  def handle_info(:scan_poll, %{assigns: %{pairing: p}} = socket)
      when not is_nil(p) and p.phase == :scanning do
    devices = discovered(AudioManager.list_headphones(), p.adapter)

    ref =
      if p.scan_done, do: nil, else: Process.send_after(self(), :scan_poll, @scan_poll_ms)

    {:noreply,
     assign(socket, :pairing, %{
       p
       | devices: devices,
         elapsed: elapsed_seconds(p.started_at),
         poll_ref: ref
     })}
  end

  def handle_info(:scan_poll, socket), do: {:noreply, socket}

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Internal: role + pairing helpers ────────────────────────────────────

  # Apply a role through the public API (handles forget-on-deactivate +
  # proxy re-target), then re-read derived state. Synchronous like
  # `select_radio` — the proxy controls disable via `busy` meanwhile.
  defp apply_role(socket, mac, role) do
    socket = assign(socket, :busy, true)

    case Bluetooth.set_role(mac, role) do
      :ok ->
        socket
        |> assign(:roles, Bluetooth.roles())
        |> assign(:radios, Bluetooth.refresh_radios())
        |> assign(:headphones, AudioManager.list_headphones())
        |> assign(:busy, false)

      {:error, reason} ->
        Logger.warning("Bluetooth set_role failed: #{inspect(reason)}")

        socket
        |> assign(:busy, false)
        |> put_flash(:error, setter_error(reason))
    end
  end

  defp apply_pairing_step(p, :pairing), do: %{p | phase: :pairing, step: 0}
  defp apply_pairing_step(p, :trusting), do: %{p | phase: :pairing, step: 1}
  defp apply_pairing_step(p, :connecting), do: %{p | phase: :pairing, step: 2}
  defp apply_pairing_step(p, :connected), do: %{p | phase: :success}
  defp apply_pairing_step(p, {:error, reason}), do: %{p | phase: :failure, error: reason}
  defp apply_pairing_step(p, _other), do: p

  defp close_pairing(%{assigns: %{pairing: nil}} = socket), do: socket

  defp close_pairing(socket) do
    p = socket.assigns.pairing
    cancel_timer(p.poll_ref)
    if p.phase == :scanning, do: AudioManager.stop_scan()

    socket
    |> assign(:pairing, nil)
    |> assign(:headphones, AudioManager.list_headphones())
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

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
  defp setter_error(:invalid_role), do: "That role can't be assigned."
  defp setter_error(_), do: "Bluetooth setting could not be saved."

  defp scan_error(:no_audio_adapter), do: "Assign a radio to the Audio role first."
  defp scan_error(:not_audio_adapter), do: "That radio isn't set to Audio."
  defp scan_error(_), do: "Couldn't start scanning. Try again."

  defp parse_role("proxy"), do: :proxy
  defp parse_role("audio"), do: :audio
  defp parse_role("off"), do: :off
  defp parse_role(_), do: nil

  # Wall-clock seconds since the scan started (from the monotonic stamp), so
  # the on-screen counter doesn't drift from poll-tick arithmetic.
  defp elapsed_seconds(started_at) when is_integer(started_at),
    do: max(0, System.monotonic_time(:second) - started_at)

  defp elapsed_seconds(_), do: 0

  # ── render ──────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:proxy_status, proxy_status(assigns.status, assigns.roles, assigns.radios))
      |> assign(:radio_count, length(assigns.radios))
      |> assign(:audio_radios, audio_radios(assigns.radios, assigns.roles))
      |> assign(:paired, Enum.filter(assigns.headphones, & &1.paired))

    ~H"""
    <div class="max-w-[720px] mx-auto">
      <%!-- Header --%>
      <div class="mb-6">
        <.eyebrow>Bluetooth</.eyebrow>
        <h2 class="text-xl font-semibold mt-1 mb-1.5 text-fg-1">Bluetooth proxy</h2>
        <p class="text-base text-fg-2 m-0 max-w-[640px]">
          Relays nearby Bluetooth traffic to Home&nbsp;Assistant over the native API —
          a remote antenna for trackers, sensors, and smart locks that are out of
          range of your server. Dedicate a radio to <span class="text-audio font-medium">Audio</span>
          to stream to Bluetooth speakers and headphones.
        </p>
      </div>

      <.proxy_card status={@status} stats={@stats} proxy_status={@proxy_status} busy={@busy} />

      <.radios_section
        radios={@radios}
        radio_count={@radio_count}
        roles={@roles}
        headphones={@headphones}
        status={@status}
        busy={@busy}
      />

      <.audio_devices_section
        paired={@paired}
        audio_radios={@audio_radios}
        radios={@radios}
        menu_open={@menu_open}
      />
    </div>

    <.deactivate_modal :if={@deactivate} deactivate={@deactivate} />
    <.forget_modal :if={@forget} device={@forget} />
    <.pairing_modal :if={@pairing} pairing={@pairing} audio_radios={@audio_radios} paired={@paired} />
    """
  end

  # ── Proxy card ──────────────────────────────────────────────────────────
  attr(:status, :map, required: true)
  attr(:stats, :map, required: true)
  attr(:proxy_status, :map, required: true)
  attr(:busy, :boolean, required: true)

  defp proxy_card(assigns) do
    ~H"""
    <.card padding={:none} class="overflow-hidden">
      <div class="flex items-start gap-4 p-[20px_22px]">
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
              <% @proxy_status.paused? -> %>
                Paused — no radio is assigned to the Proxy role.
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
        :if={@status.enabled and is_nil(@status.adapter) and not @proxy_status.paused?}
        class="mx-[22px] mb-[18px] p-[10px_12px] rounded-md bg-warning-soft text-warning text-xs font-medium flex items-center gap-2"
      >
        <.icon name={:alert} size={14} stroke={2.0} />
        Plug in a USB Bluetooth adapter, or enable the onboard radio. The proxy
        starts automatically when a radio appears.
      </div>

      <%!-- Paused-role notice (a radio exists but none is :proxy) --%>
      <div
        :if={@proxy_status.paused?}
        class="mx-[22px] mb-[18px] p-[10px_12px] rounded-md bg-sunken text-fg-2 text-xs font-medium flex items-center gap-2"
      >
        <.icon name={:info} size={14} />
        {@proxy_status.paused_hint}
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
    """
  end

  # ── Radios section ────────────────────────────────────────────────────
  attr(:radios, :list, required: true)
  attr(:radio_count, :integer, required: true)
  attr(:roles, :map, required: true)
  attr(:headphones, :list, required: true)
  attr(:status, :map, required: true)
  attr(:busy, :boolean, required: true)

  defp radios_section(assigns) do
    assigns = assign(assigns, :single_audio?, single_radio_audio?(assigns.radios, assigns.roles))

    ~H"""
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
          role={role_of(@roles, radio.address)}
          proxying?={@status.proxying?}
          paired_count={length(paired_on(@headphones, radio.address))}
          busy={@busy}
        />
      </.card>

      <%!-- Single-radio contention: only radio is on Audio → proxy paused --%>
      <div
        :if={@single_audio?}
        class="mt-2.5 p-[10px_12px] rounded-md bg-warning-soft text-warning text-xs font-medium flex items-start gap-2"
      >
        <.icon name={:alert} size={14} stroke={2.0} class="mt-px flex-none" />
        <span>
          One radio can't proxy and stream at once. While it's set to
          <strong>Audio</strong>, the BLE proxy is paused. Add a second USB radio to run both.
        </span>
      </div>

      <p :if={@radio_count == 1 and not @single_audio?} class="text-xs text-fg-3 mt-2.5 mx-0.5 leading-normal">
        With one radio you pick proxy <em>or</em> audio. Plug in a USB Bluetooth adapter
        to run both at once.
      </p>
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
  attr(:role, :atom, required: true)
  attr(:proxying?, :boolean, required: true)
  attr(:paired_count, :integer, required: true)
  attr(:busy, :boolean, required: true)

  defp bt_radio_row(assigns) do
    ~H"""
    <div class="flex items-center gap-3.5 p-[14px_18px] border-b border-border-2 last:border-b-0">
      <%!-- Bus tile, tinted by role --%>
      <div class={[
        "w-9 h-9 rounded-md flex items-center justify-center flex-none",
        role_tile_classes(@role)
      ]}>
        <.icon name={if(@radio.bus == :usb, do: :usb, else: :chip)} size={18} />
      </div>

      <%!-- Name + details --%>
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2 flex-wrap">
          <span class="text-sm font-semibold">{radio_name(@radio)}</span>
          <span :if={@radio.chip} class="text-xs text-fg-3">{@radio.chip}</span>
          <.badge :if={@role == :proxy and @proxying?} variant={:success} dot>In use</.badge>
          <.badge
            :if={@role == :audio and @paired_count > 0}
            variant={:neutral}
            class="!text-[10px] !px-1.5 !py-px"
          >
            {@paired_count} paired
          </.badge>
        </div>
        <div class="text-[11px] text-fg-3 mt-0.5 font-mono">
          {@radio.hci}<span :if={@radio.address}> · {@radio.address}</span>
          <span class="font-sans"> · {@radio.detail}</span>
        </div>
      </div>

      <%!-- Role selector --%>
      <.role_seg :if={@radio.address} mac={@radio.address} role={@role} busy={@busy} />
    </div>
    """
  end

  # ── role segmented control ──────────────────────────────────────────────
  attr(:mac, :string, required: true)
  attr(:role, :atom, required: true)
  attr(:busy, :boolean, required: true)

  defp role_seg(assigns) do
    ~H"""
    <div class={[
      "inline-flex gap-0.5 bg-sunken rounded-lg p-0.5 flex-none",
      @busy && "opacity-55 pointer-events-none"
    ]}>
      <.role_seg_btn mac={@mac} value="proxy" label="Proxy" active={@role == :proxy} active_class="bg-surface shadow-xs text-accent" />
      <.role_seg_btn mac={@mac} value="audio" label="Audio" active={@role == :audio} active_class="bg-surface shadow-xs text-audio" />
      <.role_seg_btn mac={@mac} value="off" label="Off" active={@role == :off} active_class="bg-surface shadow-xs text-fg-1" />
    </div>
    """
  end

  attr(:mac, :string, required: true)
  attr(:value, :string, required: true)
  attr(:label, :string, required: true)
  attr(:active, :boolean, required: true)
  attr(:active_class, :string, required: true)

  defp role_seg_btn(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="set_role"
      phx-value-mac={@mac}
      phx-value-role={@value}
      aria-pressed={"#{@active}"}
      class={[
        "px-3 py-[5px] rounded-md text-xs font-semibold border-none cursor-pointer transition-colors duration-150",
        if(@active, do: @active_class, else: "bg-transparent text-fg-3")
      ]}
    >
      {@label}
    </button>
    """
  end

  # ── Bluetooth audio outputs subsection ──────────────────────────────────
  attr(:paired, :list, required: true)
  attr(:audio_radios, :list, required: true)
  attr(:radios, :list, required: true)
  attr(:menu_open, :any, required: true)

  defp audio_devices_section(assigns) do
    assigns =
      assigns
      |> assign(:has_audio?, assigns.audio_radios != [])
      |> assign(:multi?, length(assigns.audio_radios) > 1)

    ~H"""
    <div class="mt-7">
      <div class="flex items-center gap-3 mb-2.5">
        <.eyebrow class="whitespace-nowrap">
          Audio devices{if @paired != [], do: " · #{length(@paired)}", else: ""}
        </.eyebrow>
        <div class="flex-1"></div>
        <.button variant={:primary} size={:sm} phx-click="open_pair" disabled={not @has_audio?}>
          <.icon name={:plus} size={14} /> Pair device
        </.button>
      </div>

      <%!-- Empty states --%>
      <.card :if={@paired == [] and not @has_audio?} padding={:lg} class="text-center !p-9">
        <div class="w-12 h-12 rounded-xl bg-sunken text-fg-4 mx-auto mb-3 flex items-center justify-center">
          <.icon name={:headphones} size={26} stroke={1.7} />
        </div>
        <div class="text-md font-semibold">No audio devices paired</div>
        <p class="text-sm text-fg-2 mt-1.5 mb-0 leading-normal">
          Assign a radio to the <strong>Audio</strong> role above, then pair headphones or a speaker.
        </p>
      </.card>

      <.card :if={@paired == [] and @has_audio?} padding={:lg} class="text-center !p-9">
        <div class="w-12 h-12 rounded-xl bg-audio-soft text-audio mx-auto mb-3 flex items-center justify-center">
          <.icon name={:headphones} size={26} stroke={1.7} />
        </div>
        <div class="text-md font-semibold">No audio devices paired</div>
        <p class="text-sm text-fg-2 mt-1.5 mb-0 leading-normal">
          Put headphones or a speaker into pairing mode and press <strong>Pair device</strong>.
        </p>
      </.card>

      <%!-- Single audio radio: flat list --%>
      <.card :if={@paired != [] and not @multi?} padding={:none} class="overflow-hidden">
        <.bt_headset_row
          :for={device <- @paired}
          device={device}
          radios={@radios}
          menu_open?={MapSet.member?(@menu_open, device.mac)}
        />
      </.card>

      <%!-- Multiple audio radios: group by bound radio --%>
      <div :if={@paired != [] and @multi?} class="flex flex-col gap-4">
        <div :for={radio <- @audio_radios} :if={paired_on(@paired, radio.address) != []}>
          <div class="flex items-center gap-2 mb-2 mx-0.5">
            <span class="w-[7px] h-[7px] rounded-full bg-audio"></span>
            <span class="text-xs font-semibold text-fg-2">{radio_name(radio)}</span>
            <span class="text-[11px] text-fg-3 font-mono">{radio.hci}</span>
          </div>
          <.card padding={:none} class="overflow-hidden">
            <.bt_headset_row
              :for={device <- paired_on(@paired, radio.address)}
              device={device}
              radios={@radios}
              menu_open?={MapSet.member?(@menu_open, device.mac)}
            />
          </.card>
        </div>
      </div>

      <p :if={@paired != []} class="text-xs text-fg-3 mt-2.5 mx-0.5 leading-normal">
        Volume and renaming live on the <.link navigate="/audio" class="text-accent hover:underline">Audio</.link>
        tab, where each connected device is a Sendspin player.
      </p>
    </div>
    """
  end

  # ── headset row ───────────────────────────────────────────────────────
  attr(:device, :map, required: true)
  attr(:radios, :list, required: true)
  attr(:menu_open?, :boolean, required: true)

  defp bt_headset_row(assigns) do
    assigns = assign(assigns, :hci, hci_label(assigns.radios, assigns.device.adapter))

    ~H"""
    <div class="flex items-center gap-3.5 p-[14px_18px] border-b border-border-2 last:border-b-0">
      <div class={[
        "w-9 h-9 rounded-md flex items-center justify-center flex-none",
        if(@device.connected, do: "bg-audio-soft text-audio", else: "bg-sunken text-fg-4")
      ]}>
        <.icon name={:headphones} size={18} />
      </div>

      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2 flex-wrap">
          <span class="text-sm font-semibold truncate">{@device.name}</span>
          <.badge :if={@hci} variant={:neutral} class="!text-[10px] !px-1.5 !py-px !font-mono">
            {@hci}
          </.badge>
          <.battery_pill :if={@device.connected and is_integer(@device.battery)} level={@device.battery} />
        </div>
        <div class="text-[11px] text-fg-3 mt-0.5 font-mono">{@device.mac}</div>
      </div>

      <.badge variant={if(@device.connected, do: :success, else: :warning)} dot>
        {if @device.connected, do: "Connected", else: "Disconnected"}
      </.badge>

      <div class="flex items-center gap-1.5 relative">
        <.button
          :if={@device.connected}
          variant={:secondary}
          size={:sm}
          phx-click="disconnect_device"
          phx-value-mac={@device.mac}
        >
          Disconnect
        </.button>
        <.button
          :if={not @device.connected}
          variant={:secondary}
          size={:sm}
          phx-click="connect_device"
          phx-value-mac={@device.mac}
        >
          Connect
        </.button>

        <button
          type="button"
          phx-click="toggle_menu"
          phx-value-mac={@device.mac}
          aria-label="More"
          class="text-fg-3 hover:text-fg-2 p-1.5 rounded-md flex items-center cursor-pointer bg-transparent border-none"
        >
          <.icon name={:more} size={16} />
        </button>

        <div :if={@menu_open?}>
          <div phx-click="toggle_menu" phx-value-mac={@device.mac} class="fixed inset-0 z-40"></div>
          <div class="absolute right-0 top-[calc(100%+4px)] z-[41] min-w-[140px] p-1 rounded-lg bg-raised border border-border-1 shadow-lg animate-pop">
            <button
              type="button"
              phx-click="ask_forget"
              phx-value-mac={@device.mac}
              class="w-full flex items-center gap-2 px-2.5 py-2 rounded-md text-sm text-danger hover:bg-danger-soft cursor-pointer bg-transparent border-none text-left"
            >
              <.icon name={:x} size={14} /> Forget device
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── modals ──────────────────────────────────────────────────────────────
  attr(:deactivate, :map, required: true)

  defp deactivate_modal(assigns) do
    assigns =
      assign(assigns, :to_label, if(assigns.deactivate.role == :proxy, do: "Proxy", else: "Off"))

    ~H"""
    <.modal open={true} on_close="cancel_deactivate" title={"Deactivate audio on #{@deactivate.radio_name}?"}>
      <:footer>
        <.button variant={:ghost} size={:sm} phx-click="cancel_deactivate">Cancel</.button>
        <.button variant={:danger} size={:sm} phx-click="confirm_deactivate">
          Deactivate &amp; forget
        </.button>
      </:footer>
      <p class="text-sm text-fg-2 mt-0 mb-3">
        Switching this radio to <strong>{@to_label}</strong> will disconnect and
        <strong>forget {length(@deactivate.devices)} {pluralize(length(@deactivate.devices), "device", "devices")}</strong>
        bonded to it. You'll need to pair {pluralize(length(@deactivate.devices), "it", "them")} again to use {pluralize(length(@deactivate.devices), "it", "them")}.
      </p>
      <div class="flex flex-col gap-1.5">
        <div
          :for={device <- @deactivate.devices}
          class="flex items-center gap-2.5 p-[8px_10px] rounded-md bg-sunken"
        >
          <div class="w-[26px] h-[26px] rounded-md bg-surface text-fg-3 flex items-center justify-center flex-none">
            <.icon name={:headphones} size={15} />
          </div>
          <span class="flex-1 text-sm font-semibold truncate">{device.name}</span>
          <span class="text-[11px] text-fg-3 font-mono">{device.mac}</span>
        </div>
      </div>
    </.modal>
    """
  end

  attr(:device, :map, required: true)

  defp forget_modal(assigns) do
    ~H"""
    <.modal open={true} on_close="cancel_forget" title={"Forget #{@device.name}?"}>
      <:footer>
        <.button variant={:ghost} size={:sm} phx-click="cancel_forget">Cancel</.button>
        <.button variant={:danger} size={:sm} phx-click="confirm_forget">Forget</.button>
      </:footer>
      <p class="text-sm text-fg-2 mt-0 mb-0">
        This removes the pairing for <span class="font-semibold">{@device.name}</span>
        (<span class="font-mono">{@device.mac}</span>). To use it again you'll need to put it
        back into pairing mode and pair it.
      </p>
    </.modal>
    """
  end

  # ── pairing modal ─────────────────────────────────────────────────────
  attr(:pairing, :map, required: true)
  attr(:audio_radios, :list, required: true)
  attr(:paired, :list, required: true)

  defp pairing_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-[100] flex items-center justify-center p-5 animate-fade">
      <div phx-click="close_pair" class="absolute inset-0 bg-overlay"></div>
      <div class="relative bg-raised rounded-lg shadow-lg max-w-[520px] w-full animate-pop">
        <%!-- Header --%>
        <div class="px-6 pt-5 pb-3 flex items-start gap-3">
          <div class="w-9 h-9 rounded-md bg-accent-soft text-accent flex items-center justify-center flex-none">
            <.icon name={:bluetooth} size={20} />
          </div>
          <div>
            <h3 class="text-lg font-semibold m-0 text-fg-1">Pair a Bluetooth audio device</h3>
            <p class="text-sm text-fg-2 mt-0.5">{pairing_subtitle(@pairing.phase)}</p>
          </div>
        </div>

        <div class="px-6 pb-2">
          <.pairing_body pairing={@pairing} audio_radios={@audio_radios} />
        </div>

        <div class="flex justify-end gap-2 px-6 py-4 border-t border-border-2">
          <.pairing_footer pairing={@pairing} />
        </div>
      </div>
    </div>
    """
  end

  attr(:pairing, :map, required: true)
  attr(:audio_radios, :list, required: true)

  defp pairing_body(%{pairing: %{phase: :preflight}} = assigns) do
    assigns =
      assigns
      |> assign(:multi?, length(assigns.audio_radios) > 1)
      |> assign(
        :selected,
        Enum.find(assigns.audio_radios, &(&1.address == assigns.pairing.adapter))
      )

    ~H"""
    <%!-- Radio picker (only with >1 audio radio) --%>
    <div :if={@multi?} class="mb-[18px]">
      <.eyebrow class="mb-2">Pair on radio</.eyebrow>
      <div class="flex flex-col gap-1.5">
        <button
          :for={radio <- @audio_radios}
          type="button"
          phx-click="pick_pair_radio"
          phx-value-mac={radio.address}
          class={[
            "flex items-center gap-2.5 w-full p-[10px_12px] rounded-md cursor-pointer text-left border",
            if(radio.address == @pairing.adapter,
              do: "bg-audio-soft border-audio",
              else: "bg-surface border-border-1"
            )
          ]}
        >
          <span class={[
            "w-[18px] h-[18px] rounded-full border-2 flex items-center justify-center flex-none",
            if(radio.address == @pairing.adapter, do: "border-audio", else: "border-border-strong")
          ]}>
            <span :if={radio.address == @pairing.adapter} class="w-2 h-2 rounded-full bg-audio"></span>
          </span>
          <span class="flex-1 text-sm font-semibold">{radio_name(radio)}</span>
          <span class="text-[11px] text-fg-3 font-mono">{radio.hci}</span>
        </button>
      </div>
      <p class="text-[11px] text-fg-3 mt-2 leading-normal">
        Bluetooth bonds are per-radio — the device pairs to whichever radio you pick here,
        and moving it later means pairing again.
      </p>
    </div>

    <%!-- Steps --%>
    <ol class="m-0 p-0 list-none flex flex-col gap-3">
      <.preflight_step n={1} text="Put your speaker or headphones into pairing mode." />
      <.preflight_step n={2} text="Keep the device within a couple of metres of the proxy." />
      <.preflight_step n={3} text="Press Scan, then pick it from the list." />
    </ol>

    <%!-- Single-radio info --%>
    <div :if={not @multi? and @selected} class="mt-3.5 p-[10px_12px] rounded-md bg-sunken text-fg-2 text-xs flex items-center gap-2">
      <.icon name={:info} size={14} />
      <span>
        Pairing on <span class="font-mono text-fg-1">{@selected.hci}</span> — {radio_name(@selected)}.
      </span>
    </div>
    """
  end

  defp pairing_body(%{pairing: %{phase: :scanning}} = assigns) do
    ~H"""
    <div class="flex items-center gap-3 mb-3">
      <div class="relative w-[34px] h-[34px] flex-none">
        <span
          :if={not @pairing.scan_done}
          class="absolute inset-0 rounded-full border-[1.5px] border-accent bt-ping"
        >
        </span>
        <div class="w-[34px] h-[34px] rounded-full bg-accent-soft text-accent flex items-center justify-center">
          <.icon name={:bluetooth} size={18} />
        </div>
      </div>
      <div>
        <div class="text-sm font-semibold">
          {if @pairing.scan_done, do: "Scan finished", else: "Scanning for audio devices…"}
        </div>
        <div class="text-[11px] text-fg-3">
          <%= if @pairing.scan_done do %>
            {length(@pairing.devices)} found · stopped after 30s
          <% else %>
            Headphones and speakers only · {@pairing.elapsed}s
          <% end %>
        </div>
      </div>
    </div>

    <div class="flex flex-col gap-1.5 max-h-[244px] overflow-auto pr-0.5">
      <button
        :for={device <- @pairing.devices}
        type="button"
        phx-click="pick_device"
        phx-value-mac={device.mac}
        phx-value-name={device.name}
        class="flex items-center gap-3 w-full p-[10px_12px] rounded-md bg-surface border border-border-1 hover:border-accent hover:bg-accent-soft cursor-pointer text-left"
      >
        <div class="w-8 h-8 rounded-md bg-audio-soft text-audio flex items-center justify-center flex-none">
          <.icon name={:headphones} size={17} />
        </div>
        <div class="flex-1 min-w-0">
          <div class="text-sm font-semibold truncate">{device.name}</div>
          <div class="text-[11px] text-fg-3 font-mono">{device.mac}</div>
        </div>
        <.icon name={:chevron} size={15} class="-rotate-90 text-fg-3" />
      </button>

      <div :if={@pairing.devices == []} class="p-[18px_8px] text-center text-xs text-fg-3">
        <%= if @pairing.scan_done do %>
          No audio devices found. Re-enter pairing mode and scan again.
        <% else %>
          Make sure your device is in pairing mode…
        <% end %>
      </div>
    </div>
    """
  end

  defp pairing_body(%{pairing: %{phase: :pairing}} = assigns) do
    ~H"""
    <div class="flex items-center gap-3 mb-4">
      <div class="w-9 h-9 rounded-md bg-audio-soft text-audio flex items-center justify-center flex-none">
        <.icon name={:headphones} size={19} />
      </div>
      <div class="min-w-0">
        <div class="text-sm font-semibold truncate">{@pairing.target.name}</div>
        <div class="text-[11px] text-fg-3 font-mono">{@pairing.target.mac}</div>
      </div>
    </div>

    <div class="flex flex-col gap-2.5">
      <.pair_step label="Pairing" index={0} step={@pairing.step} />
      <.pair_step label="Trusting" index={1} step={@pairing.step} />
      <.pair_step label="Connecting" index={2} step={@pairing.step} />
    </div>
    """
  end

  defp pairing_body(%{pairing: %{phase: :success}} = assigns) do
    ~H"""
    <div class="text-center py-2">
      <div class="w-[52px] h-[52px] rounded-full bg-success-soft text-success mx-auto mb-3 flex items-center justify-center">
        <.icon name={:check} size={28} stroke={2.4} />
      </div>
      <div class="text-md font-semibold">Paired{if @pairing.target, do: " — #{@pairing.target.name}"}</div>
      <p class="text-sm text-fg-2 mt-1.5 mb-0 leading-normal">
        It's now an audio output. Find it on the
        <.link navigate="/audio" class="text-accent hover:underline">Audio</.link>
        tab, where Music Assistant can pick it up as a Sendspin player.
      </p>
    </div>
    """
  end

  defp pairing_body(%{pairing: %{phase: :failure}} = assigns) do
    assigns = assign(assigns, :copy, failure_copy(assigns.pairing.error))

    ~H"""
    <div class="text-center py-2">
      <div class="w-[52px] h-[52px] rounded-full bg-warning-soft text-warning mx-auto mb-3 flex items-center justify-center">
        <.icon name={:alert} size={26} stroke={2.2} />
      </div>
      <div class="text-md font-semibold">{@copy.title}</div>
      <div :if={@pairing.target} class="text-xs text-fg-3 font-mono mt-1">
        {@pairing.target.name} · {@pairing.target.mac}
      </div>
      <p class="text-sm text-fg-2 mt-1.5 mb-0 leading-normal">{@copy.body}</p>
    </div>
    """
  end

  attr(:n, :integer, required: true)
  attr(:text, :string, required: true)

  defp preflight_step(assigns) do
    ~H"""
    <li class="flex gap-3 items-start">
      <span class="w-[22px] h-[22px] rounded-full bg-sunken text-fg-2 text-xs font-semibold flex items-center justify-center flex-none">
        {@n}
      </span>
      <span class="text-sm text-fg-2 leading-normal">{@text}</span>
    </li>
    """
  end

  attr(:label, :string, required: true)
  attr(:index, :integer, required: true)
  attr(:step, :integer, required: true)

  defp pair_step(assigns) do
    assigns =
      assign(
        assigns,
        :state,
        cond do
          assigns.index < assigns.step -> :done
          assigns.index == assigns.step -> :active
          true -> :pending
        end
      )

    ~H"""
    <div class="flex items-center gap-3">
      <span class={[
        "w-[22px] h-[22px] rounded-full flex items-center justify-center flex-none",
        case @state do
          :done -> "bg-success-soft text-success"
          :active -> "bg-accent-soft text-accent"
          :pending -> "bg-sunken text-fg-4"
        end
      ]}>
        <%= case @state do %>
          <% :done -> %>
            <.icon name={:check} size={13} stroke={2.6} />
          <% :active -> %>
            <span class="w-3 h-3 rounded-full border-2 border-current border-t-transparent bt-spin"></span>
          <% :pending -> %>
            <span class="w-[5px] h-[5px] rounded-full bg-current"></span>
        <% end %>
      </span>
      <span class={[
        "text-sm",
        case @state do
          :active -> "text-fg-1 font-semibold"
          :pending -> "text-fg-4 font-medium"
          :done -> "text-fg-2 font-medium"
        end
      ]}>
        {@label}{if @state == :active, do: "…"}
      </span>
    </div>
    """
  end

  attr(:pairing, :map, required: true)

  defp pairing_footer(%{pairing: %{phase: :preflight}} = assigns) do
    ~H"""
    <.button variant={:ghost} size={:sm} phx-click="close_pair">Cancel</.button>
    <.button variant={:primary} size={:sm} phx-click="start_pair_scan">
      <.icon name={:search} size={14} /> Scan
    </.button>
    """
  end

  defp pairing_footer(%{pairing: %{phase: :scanning}} = assigns) do
    ~H"""
    <.button variant={:ghost} size={:sm} phx-click="close_pair">Cancel</.button>
    <.button :if={@pairing.scan_done} variant={:secondary} size={:sm} phx-click="start_pair_scan">
      <.icon name={:refresh} size={14} /> Scan again
    </.button>
    """
  end

  defp pairing_footer(%{pairing: %{phase: :pairing}} = assigns) do
    ~H"""
    <.button variant={:ghost} size={:sm} disabled>Pairing…</.button>
    """
  end

  defp pairing_footer(%{pairing: %{phase: :success}} = assigns) do
    ~H"""
    <.button variant={:primary} size={:sm} phx-click="close_pair">Done</.button>
    """
  end

  defp pairing_footer(%{pairing: %{phase: :failure}} = assigns) do
    ~H"""
    <.button variant={:ghost} size={:sm} phx-click="close_pair">Close</.button>
    <.button variant={:primary} size={:sm} phx-click="pair_retry">
      <.icon name={:refresh} size={14} /> Try again
    </.button>
    """
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  # Three-state proxy status, now role-aware: an `enabled` proxy with no
  # `:proxy`-role radio (and radios present) reads as Paused, not Off.
  defp proxy_status(%{proxying?: true}, _roles, _radios),
    do: %{label: "Proxying", variant: :success, paused?: false, paused_hint: nil}

  defp proxy_status(%{enabled: true, adapter: nil}, roles, radios) do
    cond do
      # A radio is present but none holds the :proxy role → paused, not "no adapter".
      radios != [] and is_nil(roles.proxy) ->
        %{
          label: "Paused",
          variant: :neutral,
          paused?: true,
          paused_hint: paused_hint(radios, roles)
        }

      true ->
        %{label: "No adapter", variant: :warning, paused?: false, paused_hint: nil}
    end
    |> Map.put_new(:paused?, false)
  end

  defp proxy_status(_status, _roles, _radios),
    do: %{label: "Off", variant: :neutral, paused?: false, paused_hint: nil}

  defp paused_hint(radios, roles) do
    if single_radio_audio?(radios, roles) do
      "Your only radio is streaming audio. Set it back to Proxy to relay BLE again."
    else
      "Assign a radio to the Proxy role below to start relaying."
    end
  end

  # True when there's exactly one present radio and it holds the :audio role.
  defp single_radio_audio?(radios, roles) do
    case radios do
      [%{address: addr}] when is_binary(addr) -> role_of(roles, addr) == :audio
      _ -> false
    end
  end

  defp active_conn_value(%{active_connections: %{allowed?: true, used: used, limit: limit}}),
    do: "#{used} of #{limit}"

  defp active_conn_value(_), do: "—"

  defp adapter_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp adapter_name(_), do: "Bluetooth radio"

  defp radio_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp radio_name(%{bus: :usb}), do: "USB Bluetooth adapter"
  defp radio_name(_), do: "Onboard radio"

  defp radio_name_for(radios, mac) do
    case Enum.find(radios, &(&1.address == mac)) do
      nil -> "this radio"
      radio -> radio_name(radio)
    end
  end

  # Role of a MAC from the {proxy, audio} role map.
  defp role_of(%{proxy: proxy, audio: audio}, mac) do
    cond do
      mac == proxy -> :proxy
      mac in audio -> :audio
      true -> :off
    end
  end

  defp role_of(_roles, _mac), do: :off

  defp role_tile_classes(:proxy), do: "bg-accent-soft text-accent"
  defp role_tile_classes(:audio), do: "bg-audio-soft text-audio"
  defp role_tile_classes(_), do: "bg-sunken text-fg-3"

  # Present radios holding the :audio role (the pairing/grouping choices).
  defp audio_radios(radios, roles) do
    Enum.filter(radios, fn r -> is_binary(r.address) and role_of(roles, r.address) == :audio end)
  end

  # Paired devices bonded to a given radio MAC. Filters on `:paired` because
  # `AudioManager.list_headphones/0` also returns *unpaired* A2DP sinks that a
  # scan just discovered (BlueZ caches them briefly) — those must not inflate
  # the radio's "N paired" badge or the deactivate-confirm "forget N" list.
  defp paired_on(devices, mac), do: Enum.filter(devices, &(&1.paired and &1.adapter == mac))

  # Discovered (not-yet-paired) audio sinks on the scanning adapter.
  defp discovered(headphones, adapter_mac) do
    Enum.filter(headphones, &(not &1.paired and &1.adapter == adapter_mac))
  end

  # Friendly `hciN` label for a bound-radio MAC, or nil if that radio is
  # not currently present (unplugged).
  defp hci_label(radios, mac) do
    case Enum.find(radios, &(&1.address == mac)) do
      %{hci: hci} when is_binary(hci) -> hci
      _ -> nil
    end
  end

  defp pairing_subtitle(:success), do: "All set — the device is now an audio output."
  defp pairing_subtitle(:failure), do: "We couldn't finish pairing."

  defp pairing_subtitle(_),
    do: "The proxy is the audio source — put your speaker or headphones in pairing mode first."

  defp failure_copy(:rejected),
    do: %{
      title: "Pairing was rejected",
      body:
        "The device turned down the request — it may already be bonded to a phone or its pairing window closed. Clear it there, put it back in pairing mode, and try again."
    }

  defp failure_copy(:out_of_range),
    do: %{
      title: "Out of range",
      body:
        "The signal dropped mid-pairing. Move the speaker or headphones closer to the proxy and try again."
    }

  defp failure_copy(:timeout),
    do: %{
      title: "Couldn't reach the device",
      body: "Pairing mode may have timed out. Re-enter pairing mode on the device and scan again."
    }

  defp failure_copy(:already_paired),
    do: %{
      title: "Already paired",
      body:
        "This device is already bonded to this radio. Disconnect or forget it first, then pair again."
    }

  defp failure_copy(_),
    do: %{
      title: "Pairing failed",
      body: "Something went wrong. Re-enter pairing mode and try again."
    }

  defp pluralize(1, singular, _plural), do: singular
  defp pluralize(_n, _singular, plural), do: plural
end
