defmodule UniversalProxyWeb.OverviewLive do
  @moduledoc """
  Overview tab — device summary strip + connected-hardware table.
  Clicking a row opens a right-side detail drawer.
  """

  use UniversalProxyWeb, :live_view

  import UniversalProxyWeb.Components.UI
  import UniversalProxyWeb.Components.Icons

  alias UniversalProxy.Audio
  alias UniversalProxy.Hardware
  alias UniversalProxy.System, as: Sys
  alias UniversalProxy.UART
  alias UniversalProxy.UART.History
  alias UniversalProxyWeb.Components.PortSparkline
  alias UniversalProxyWeb.MockData

  @refresh_interval 10_000

  @impl true
  def mount(_params, _session, socket) do
    ports = Hardware.list_ports()

    {packet_rate, snapshots} =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "uart:port_opened")
        Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "uart:port_closed")
        Phoenix.PubSub.subscribe(UniversalProxy.PubSub, History.packet_rate_topic())
        Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "sendspin:output_added")
        Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "sendspin:output_removed")
        Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "sendspin:state")
        :timer.send_interval(@refresh_interval, self(), :refresh)
        {History.packets_per_minute(), reconcile_throughputs(%{}, ports)}
      else
        {0, %{}}
      end

    {:ok,
     socket
     |> assign(:page_title, "Overview")
     |> assign(:target, Sys.device_summary())
     |> assign(:selected_port, nil)
     |> assign(:throughput_snapshots, snapshots)
     |> assign(:packet_rate, packet_rate)
     |> assign(:pending_kind_change, nil)
     |> assign(:audio_outputs, build_audio_index(Audio.list_outputs()))
     |> set_ports(ports)}
  end

  @impl true
  def handle_event("select_port", %{"id" => id}, socket) do
    {:noreply, assign(socket, :selected_port, id)}
  end

  def handle_event("close_drawer", _params, socket) do
    {:noreply, assign(socket, :selected_port, nil)}
  end

  def handle_event("ignore", _params, socket), do: {:noreply, socket}

  def handle_event(
        "request_kind_change",
        %{"port" => port_id, "kind" => new_kind},
        socket
      )
      when new_kind in ["ttl", "rs232", "rs485"] do
    port = Enum.find(socket.assigns.ports, &(&1.id == port_id))

    cond do
      is_nil(port) or port.in_use ->
        {:noreply, socket}

      to_string(port.kind) == new_kind ->
        # User picked the kind that's already in effect — nothing to do.
        {:noreply, socket}

      port.configured ->
        {:noreply,
         assign(socket, :pending_kind_change, %{
           port_id: port_id,
           new_kind: new_kind,
           from_label: port.kind_label
         })}

      true ->
        {:noreply, apply_kind_change(socket, port_id, new_kind)}
    end
  end

  def handle_event("confirm_kind_change", _params, socket) do
    case socket.assigns.pending_kind_change do
      %{port_id: id, new_kind: kind} ->
        socket =
          socket
          |> apply_kind_change(id, kind)
          |> assign(:pending_kind_change, nil)
          |> put_flash(:info, "Port reconfigured. Restart the ESPHome client to pick up changes.")

        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_kind_change", _params, socket) do
    {:noreply, assign(socket, :pending_kind_change, nil)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, refresh_ports(socket)}
  end

  def handle_info({:uart_port_opened, _info}, socket) do
    {:noreply, refresh_ports(socket)}
  end

  def handle_info({:uart_port_closed, _info}, socket) do
    {:noreply, refresh_ports(socket)}
  end

  # Per-port throughput updates land here once per second per
  # subscribed port. Storing the samples in socket assigns would dirty
  # the entire table on every tick; instead, we route the update
  # straight to the matching `PortSparkline` LiveComponent(s) so only
  # their assigns are re-rendered. There are up to two instances per
  # port — one in the table row, one in the drawer (when open).
  def handle_info({:uart_throughput, %{name: name, samples: samples}}, socket) do
    port = Enum.find(socket.assigns.ports, &(&1.ha_name == name))

    if port do
      Phoenix.LiveView.send_update(PortSparkline,
        id: table_spark_id(port.id),
        samples: samples
      )

      if socket.assigns.selected_port == port.id do
        Phoenix.LiveView.send_update(PortSparkline,
          id: drawer_spark_id(port.id),
          samples: samples
        )
      end
    end

    {:noreply, socket}
  end

  def handle_info({:uart_packet_rate, count}, socket) do
    {:noreply, assign(socket, :packet_rate, count)}
  end

  def handle_info({:sendspin_output_added, output}, socket) do
    {:noreply, update(socket, :audio_outputs, &Map.put(&1, output.key, output))}
  end

  def handle_info({:sendspin_output_removed, %{key: key}}, socket) do
    {:noreply, update(socket, :audio_outputs, &Map.delete(&1, key))}
  end

  # Track binary-emitted connection events per key so the "Streaming" /
  # "Connected" / "Stopped" badge on the Overview row can flip without
  # re-fetching the output list. Server-originated `:sendspin_state`
  # partials (enable, rename, etc.) patch other fields on the same map.
  def handle_info({:sendspin_state, key, %{event: "connected"}}, socket) do
    {:noreply, update_audio_output(socket, key, %{connection: :connected})}
  end

  def handle_info({:sendspin_state, key, %{event: event}}, socket)
      when event in ["disconnected", "shutdown"] do
    # Disconnecting must clear the cached stream snapshot — the binary
    # can't be playing audio over a socket it doesn't have. Without
    # this, the row would read "Streaming" right up until the next
    # `stream_end` event, which never arrives because the server is
    # gone.
    {:noreply, update_audio_output(socket, key, %{connection: :disconnected, stream: nil})}
  end

  def handle_info({:sendspin_state, key, %{event: "stream_start"} = payload}, socket) do
    {:noreply, update_audio_output(socket, key, %{stream: stream_summary(payload)})}
  end

  def handle_info({:sendspin_state, key, %{event: "stream_end"}}, socket) do
    {:noreply, update_audio_output(socket, key, %{stream: nil})}
  end

  def handle_info({:sendspin_state, key, %{enabled: enabled?}}, socket)
      when is_boolean(enabled?) do
    {:noreply, update_audio_output(socket, key, %{enabled: enabled?})}
  end

  def handle_info({:sendspin_state, key, %{friendly_name: name}}, socket) when is_binary(name) do
    {:noreply, update_audio_output(socket, key, %{friendly_name: name})}
  end

  def handle_info({:sendspin_state, _key, _partial}, socket), do: {:noreply, socket}

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Refresh the port list AND reconcile throughput subscriptions so new
  # hot-plugged adapters get a live sparkline and removed ones stop
  # leaking subscriptions to History. Short-circuits when the port list
  # is unchanged — the 10s `:refresh` tick normally lands here with the
  # same ports, and re-assigning would force a full table re-render.
  defp refresh_ports(socket) do
    ports = Hardware.list_ports()

    if ports == socket.assigns.ports do
      assign(socket, :target, Sys.device_summary())
    else
      socket
      |> assign(:target, Sys.device_summary())
      |> assign(
        :throughput_snapshots,
        reconcile_throughputs(socket.assigns.throughput_snapshots, ports)
      )
      |> set_ports(ports)
    end
  end

  # Memoize derived counts so the device-summary card doesn't recompute
  # them on every render — only when `:ports` actually changes.
  defp set_ports(socket, ports) do
    socket
    |> assign(:ports, ports)
    |> assign(:connected_count, Enum.count(ports, & &1.connected))
    |> assign(:active_count, Enum.count(ports, & &1.in_use))
    |> assign(:idle_count, Enum.count(ports, &(&1.connected and not &1.in_use)))
    |> assign(:total_count, length(ports))
  end

  # Subscribe to History throughput for every port the table will draw
  # a sparkline for (`connected and configured`). Unsubscribe from any
  # name that is no longer in the desired set. The snapshots returned
  # by `throughput_subscribe_and_snapshot/1` are kept so newly mounted
  # `PortSparkline` LiveComponents can be seeded via `:initial_samples`
  # instead of waiting up to a full second for the first tick. Returns
  # a `%{name => samples}` map.
  defp reconcile_throughputs(existing, ports) do
    desired = throughput_target_names(ports)
    current = existing |> Map.keys() |> MapSet.new()

    MapSet.difference(current, desired)
    |> Enum.each(&History.throughput_unsubscribe/1)

    additions =
      desired
      |> MapSet.difference(current)
      |> Map.new(fn name -> {name, History.throughput_subscribe_and_snapshot(name)} end)

    existing
    |> Map.take(MapSet.to_list(desired))
    |> Map.merge(additions)
  end

  defp build_audio_index(outputs) do
    Map.new(outputs, fn output -> {output.key, output} end)
  end

  # Cheap projection of the binary's stream_start payload to a non-nil
  # term — the Overview row's badge only branches on `is_nil(stream)`,
  # so we don't need the full codec/rate/bit-depth breakdown that
  # AudioLive renders.
  defp stream_summary(payload) when is_map(payload) do
    %{codec: Map.get(payload, :codec)}
  end

  defp update_audio_output(socket, key, patch) do
    update(socket, :audio_outputs, fn outputs ->
      case Map.fetch(outputs, key) do
        {:ok, existing} -> Map.put(outputs, key, Map.merge(existing, patch))
        :error -> outputs
      end
    end)
  end

  defp throughput_target_names(ports) do
    for %{connected: true, configured: true, ha_name: name} <- ports,
        is_binary(name),
        into: MapSet.new(),
        do: name
  end

  defp table_spark_id(port_id), do: "spark-#{port_id}"
  defp drawer_spark_id(port_id), do: "drawer-spark-#{port_id}"

  defp apply_kind_change(socket, port_id, kind_str) do
    port = Enum.find(socket.assigns.ports, &(&1.id == port_id))

    if port && port.connected do
      key = {port.slot_sub, port.vendor_id, port.product_id}
      UART.save_config(key, save_params(kind_str, port.serial))
    end

    assign(socket, :ports, Hardware.list_ports())
  end

  # `Hardware.build_port/6` substitutes the em-dash placeholder for a
  # nil/missing serial number at render time. Don't let that placeholder
  # leak into DETS — pass `serial_number` only when the underlying
  # serial is real.
  defp save_params(kind_str, serial) do
    base = %{port_type: kind_str}

    case serial do
      s when is_binary(s) and s not in ["—", "-", ""] -> Map.put(base, :serial_number, s)
      _ -> base
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-[1120px] mx-auto space-y-4">
      <.device_summary
        target={@target}
        connected={@connected_count}
        active={@active_count}
        idle={@idle_count}
        total={@total_count}
        packet_rate={@packet_rate}
      />

      <.hardware_table ports={@ports} throughput_snapshots={@throughput_snapshots} />

      <.audio_outputs_card :if={map_size(@audio_outputs) > 0} outputs={@audio_outputs} />
    </div>

    <.maybe_port_drawer
      port={find_port(@ports, @selected_port)}
      throughput_snapshots={@throughput_snapshots}
    />

    <.modal
      open={@pending_kind_change != nil}
      on_close="cancel_kind_change"
      title="Change port type?"
      subtitle={
        @pending_kind_change &&
          "Reconfiguring this port from #{@pending_kind_change.from_label} to #{kind_label(@pending_kind_change.new_kind)} " <>
            "will drop any in-flight frames and force the ESPHome client to rebind. " <>
            "Existing automations referencing this port will need to be updated."
      }
    >
      <:footer>
        <.button variant={:ghost} size={:sm} phx-click="cancel_kind_change">Cancel</.button>
        <.button variant={:primary} size={:sm} phx-click="confirm_kind_change">
          Change type
        </.button>
      </:footer>
    </.modal>
    """
  end

  defp find_port(_ports, nil), do: nil
  defp find_port(ports, id), do: Enum.find(ports, &(&1.id == id))

  attr(:port, :map, default: nil)
  attr(:throughput_snapshots, :map, required: true)

  defp maybe_port_drawer(assigns) do
    ~H"""
    <.port_drawer
      :if={@port}
      port={@port}
      initial_samples={@throughput_snapshots[@port.ha_name]}
    />
    """
  end

  defp kind_label("ttl"), do: "TTL"
  defp kind_label("rs232"), do: "RS-232"
  defp kind_label("rs485"), do: "RS-485"
  defp kind_label(_), do: ""

  # ── Device summary card ───────────────────────────────────────────────
  attr(:target, :map, required: true)
  attr(:connected, :integer, required: true)
  attr(:active, :integer, required: true)
  attr(:idle, :integer, required: true)
  attr(:total, :integer, required: true)
  attr(:packet_rate, :integer, required: true)

  defp device_summary(assigns) do
    ~H"""
    <.card padding={:none} class="!p-[18px_22px] grid grid-cols-[auto_1fr] gap-5 items-center">
      <div class="flex items-center gap-3.5">
        <div class="w-11 h-11 rounded-md bg-accent-soft text-accent flex items-center justify-center">
          <.icon name={:plug} size={22} />
        </div>
        <div>
          <div class="text-md font-semibold tracking-tight">{@target.hostname}</div>
          <div class="text-sm text-fg-3 mt-0.5">
            {@target.hardware} · <span class="font-mono">{@target.ip}</span> · firmware {@target.firmware}
          </div>
        </div>
      </div>
      <div class="flex gap-7 justify-end pr-2">
        <.summary_stat label="Slots in use" value={@connected} total={@total} tint="text-accent" />
        <.summary_stat label="Active" value={@active} tint="text-success" />
        <.summary_stat label="Idle" value={@idle} tint="text-warning" />
        <.summary_stat label="Packets/min" value={@packet_rate} tint="text-fg-1" />
      </div>
    </.card>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :integer, required: true)
  attr(:total, :integer, default: nil)
  attr(:tint, :string, default: "text-fg-1")

  defp summary_stat(assigns) do
    ~H"""
    <div class="text-center">
      <div class={["text-xl font-semibold tabular-nums leading-tight", @tint]}>
        {@value}<span :if={@total} class="text-fg-3 text-base font-normal">/{@total}</span>
      </div>
      <div class="text-[11px] text-fg-3 uppercase tracking-caps font-semibold mt-0.5">
        {@label}
      </div>
    </div>
    """
  end

  # ── Connected hardware table ──────────────────────────────────────────
  attr(:ports, :list, required: true)
  attr(:throughput_snapshots, :map, required: true)

  defp hardware_table(assigns) do
    ~H"""
    <.card padding={:none} class="overflow-hidden">
      <div class="flex items-center px-4 py-3.5 border-b border-border-1">
        <div class="text-base font-semibold">Connected hardware</div>
      </div>
      <table class="w-full table-fixed border-collapse">
        <colgroup>
          <col class="w-[88px]" />
          <col />
          <col class="w-[132px]" />
          <col class="w-[200px]" />
          <col class="w-[110px]" />
          <col class="w-[130px]" />
        </colgroup>
        <thead>
          <tr class="bg-sunken">
            <th class="text-left text-xs font-bold uppercase tracking-wide text-fg-1 px-4 py-2.5 border-b border-border-1">
              Slot
            </th>
            <th class="text-left text-xs font-bold uppercase tracking-wide text-fg-1 px-4 py-2.5 border-b border-border-1">
              Adapter
            </th>
            <th class="text-left text-xs font-bold uppercase tracking-wide text-fg-1 px-4 py-2.5 border-b border-border-1">
              Type
            </th>
            <th class="text-left text-xs font-bold uppercase tracking-wide text-fg-1 px-4 py-2.5 border-b border-border-1">
              In use by
            </th>
            <th class="text-left text-xs font-bold uppercase tracking-wide text-fg-1 px-4 py-2.5 border-b border-border-1">
              Throughput
            </th>
            <th class="text-left text-xs font-bold uppercase tracking-wide text-fg-1 px-4 py-2.5 border-b border-border-1">
              Status
            </th>
          </tr>
        </thead>
        <tbody>
          <.port_row
            :for={port <- @ports}
            port={port}
            throughput_snapshots={@throughput_snapshots}
          />
        </tbody>
      </table>
    </.card>
    """
  end

  # ── Single row in the hardware table ──────────────────────────────────
  attr(:port, :map, required: true)
  attr(:throughput_snapshots, :map, required: true)

  defp port_row(assigns) do
    assigns = assign(assigns, :status, MockData.port_status(assigns.port))

    ~H"""
    <tr
      class="cursor-pointer hover:bg-sunken last:[&_td]:border-b-0"
      phx-click="select_port"
      phx-value-id={@port.id}
    >
      <td class="px-4 py-4 text-sm text-fg-1 border-b border-border-2 align-middle">
        <div class="text-xs font-semibold text-fg-2 tracking-wide">{@port.slot}</div>
        <div class="font-mono text-[11px] text-fg-3 mt-0.5">{@port.slot_sub}</div>
      </td>
      <td class="px-4 py-4 text-sm text-fg-1 border-b border-border-2 align-middle">
        <.adapter_cell port={@port} />
      </td>
      <td class="px-4 py-4 text-sm text-fg-1 border-b border-border-2 align-middle">
        <.type_cell port={@port} />
      </td>
      <td class="px-4 py-4 text-sm text-fg-1 border-b border-border-2 align-middle">
        <a
          :if={@port.user}
          href={@port.user_href}
          phx-click="ignore"
          onclick="event.stopPropagation()"
          class="text-accent text-base no-underline"
        >
          {@port.user}
        </a>
        <span :if={!@port.user} class="text-fg-3 text-base">
          {if @port.connected, do: "Not claimed", else: "—"}
        </span>
      </td>
      <td class="px-4 py-4 text-sm text-fg-1 border-b border-border-2 align-middle">
        <.live_component
          :if={@port.connected and @port.configured}
          module={PortSparkline}
          id={"spark-#{@port.id}"}
          port_kind={@port.kind}
          variant={:compact}
          initial_samples={@throughput_snapshots[@port.ha_name]}
        />
        <span :if={!(@port.connected and @port.configured)} class="text-fg-4 text-base">
          —
        </span>
      </td>
      <td class="px-4 py-4 text-sm text-fg-1 border-b border-border-2 align-middle">
        <.badge variant={@status.variant} dot>{@status.label}</.badge>
      </td>
    </tr>
    """
  end

  # ── Adapter cell (icon tile + name + sub-line + HA picker hint) ───────
  attr(:port, :map, required: true)

  defp adapter_cell(assigns) do
    ~H"""
    <div :if={@port.connected} class="flex items-center gap-3">
      <div class="w-8 h-8 rounded-sm bg-sunken flex items-center justify-center flex-none">
        <span class={MockData.kind_meta(@port.kind).tint_class}>
          <.port_glyph kind={@port.kind || :unknown} size={18} />
        </span>
      </div>
      <div class="min-w-0">
        <div class="flex items-center gap-2">
          <span class="text-base font-medium text-fg-1">{@port.name}</span>
          <.detection_badge port={@port} />
        </div>
        <div class="text-sm text-fg-3 mt-px">{@port.vendor} · {@port.chip}</div>
        <div
          class="font-mono text-[11px] text-fg-1 mt-1 inline-flex items-center gap-1.5 px-1.5 py-0.5 rounded-xs bg-surface border border-border-1"
          title="This is how the adapter appears in Home Assistant's serial port picker."
        >
          <span class="font-sans text-fg-2 uppercase tracking-wide text-[9px] font-bold">HA</span>
          <span class="text-fg-1">{@port.ha_name}</span>
        </div>
      </div>
    </div>
    <div :if={!@port.connected} class="flex items-center gap-3 text-fg-4">
      <div class="w-8 h-8 rounded-sm border border-dashed border-border-strong flex-none"></div>
      <div class="text-sm italic">No adapter</div>
    </div>
    """
  end

  attr(:port, :map, required: true)

  defp detection_badge(assigns) do
    ~H"""
    <.badge :if={@port.detection == :auto} variant={:accent} class="!text-[10px] !px-1.5 !py-0">
      Auto-detected
    </.badge>
    <.badge :if={@port.detection == :manual} variant={:neutral} class="!text-[10px] !px-1.5 !py-0">
      Manual
    </.badge>
    <.badge
      :if={@port.detection == :unknown or @port.configured == false}
      variant={:warning}
      class="!text-[10px] !px-1.5 !py-0"
    >
      Needs setup
    </.badge>
    """
  end

  # ── Type cell (kind dot + name OR pickable select) ────────────────────
  attr(:port, :map, required: true)

  defp type_cell(assigns) do
    ~H"""
    <span :if={!@port.connected} class="text-fg-4">—</span>
    <div
      :if={@port.connected and @port.locked}
      class="flex items-center gap-2"
    >
      <span
        class="w-1.5 h-1.5 rounded-full flex-none"
        style={"background: #{MockData.kind_meta(@port.kind).tint};"}
      >
      </span>
      <span class="text-sm text-fg-1">{@port.kind_label}</span>
    </div>
    <div
      :if={@port.connected and !@port.locked}
      class="flex items-center gap-1.5"
    >
      <span
        :if={@port.kind}
        class="w-1.5 h-1.5 rounded-full flex-none"
        style={"background: #{MockData.kind_meta(@port.kind).tint};"}
      >
      </span>
      <%!--
      The select sits in a tiny form. `phx-change` on a form sends every
      named field — so the hidden `id` field plus the select's value
      both reach the handler. (`phx-value-*` only ships with `phx-click`,
      not `phx-change`, which is why the bare select didn't carry the
      port id.)
      --%>
      <form phx-change="request_kind_change">
        <input type="hidden" name="port" value={@port.id} />
        <select
          name="kind"
          disabled={@port.in_use}
          onclick="event.stopPropagation()"
          title={
            if @port.in_use,
              do: "Disconnect the ESPHome client to change this port's type.",
              else: "Pick the kind of serial adapter."
          }
          class={[
            "text-base font-normal text-fg-1 px-1.5 py-0.5 rounded-sm",
            if(@port.configured,
              do: "bg-canvas border border-solid border-border-1",
              else: "bg-surface border border-dashed border-border-strong"
            ),
            "cursor-pointer disabled:cursor-not-allowed"
          ]}
        >
          <option :if={!@port.configured} value="" disabled selected>Pick type…</option>
          <option value="ttl" selected={@port.kind == :ttl}>TTL</option>
          <option value="rs232" selected={@port.kind == :rs232}>RS-232</option>
          <option value="rs485" selected={@port.kind == :rs485}>RS-485</option>
        </select>
      </form>
    </div>
    """
  end

  # ── Right-side detail drawer ──────────────────────────────────────────
  attr(:port, :map, required: true)
  attr(:initial_samples, :any, default: nil)

  defp port_drawer(assigns) do
    assigns = assign(assigns, :status, MockData.port_status(assigns.port))

    ~H"""
    <div class="fixed inset-0 z-[90] flex justify-end animate-fade">
      <%!--
      Backdrop and content are siblings so clicks on the drawer body
      don't bubble to the backdrop's phx-click. Stopping propagation on
      the content (the previous approach) blocks LiveView's click
      delegation from reaching phx-click handlers on inner buttons —
      including the X close button.
      --%>
      <div phx-click="close_drawer" class="absolute inset-0 bg-overlay"></div>
      <div class="relative w-[440px] bg-raised h-full shadow-lg overflow-auto animate-slide-in flex flex-col">
        <%!-- Header --%>
        <div class="px-6 py-5 border-b border-border-1 flex items-start gap-3">
          <div class={[
            "w-10 h-10 rounded-md flex items-center justify-center",
            if(@port.connected,
              do: "bg-sunken",
              else: "border border-dashed border-border-strong"
            )
          ]}>
            <span :if={@port.connected} class={MockData.kind_meta(@port.kind).tint_class}>
              <.port_glyph kind={@port.kind || :unknown} size={22} />
            </span>
          </div>
          <div class="flex-1 min-w-0">
            <div class="text-xs font-bold text-fg-3 tracking-caps">{@port.slot}</div>
            <div class="text-lg font-semibold tracking-tight mt-0.5">
              {if @port.connected, do: @port.name, else: "No adapter"}
            </div>
            <div class="mt-2"><.badge variant={@status.variant} dot>{@status.label}</.badge></div>
          </div>
          <.button variant={:ghost} size={:sm} phx-click="close_drawer">
            <.icon name={:x} size={16} />
          </.button>
        </div>

        <%!-- Facts --%>
        <dl class="px-6 py-4 m-0 grid grid-cols-[120px_1fr] gap-x-4 gap-y-2.5 text-base">
          <.fact :for={{k, v, mono?} <- fact_rows(@port)} label={k} value={v} mono={mono?} />
        </dl>

        <%!-- Live throughput --%>
        <.live_component
          :if={@port.connected and @port.in_use}
          module={PortSparkline}
          id={"drawer-spark-#{@port.id}"}
          port_kind={@port.kind}
          variant={:full}
          initial_samples={@initial_samples}
        />

        <%!-- Footer actions --%>
        <div class="mt-auto px-6 py-4 border-t border-border-1 flex gap-2 flex-wrap">
          <.button :if={@port.connected} variant={:secondary} size={:sm}>
            <.icon name={:logs} size={14} /> View traffic
          </.button>
          <.button :if={@port.connected} variant={:secondary} size={:sm}>
            <.icon name={:refresh} size={14} /> Reset link
          </.button>
          <div :if={@port.connected} class="flex-1"></div>
          <.button :if={@port.connected} variant={:ghost} size={:sm}>Forget</.button>
          <.button :if={!@port.connected} variant={:secondary} size={:sm}>
            <.icon name={:refresh} size={14} /> Rescan
          </.button>
        </div>
      </div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:mono, :boolean, default: false)

  defp fact(assigns) do
    ~H"""
    <dt class="text-fg-3">{@label}</dt>
    <dd class={["m-0 text-fg-1", @mono && "font-mono"]}>{@value}</dd>
    """
  end

  defp fact_rows(%{connected: false} = port) do
    [
      {"Slot", "#{port.slot} — #{port.slot_sub}", false},
      {"Status", "No adapter detected", false},
      {"Tip", "Plug in any supported USB adapter to get started.", false}
    ]
  end

  defp fact_rows(port) do
    base = [
      {"Slot", "#{port.slot} — #{port.slot_sub}", false},
      {"Adapter", "#{port.vendor} #{port.name}", false},
      {"Chipset", port.chip, false},
      {"Serial", port.serial, true},
      {"Device node", port.device, true},
      {"HA serial picker", port.ha_name, true}
    ]

    serial =
      if port.kind in [:rs232, :rs485, :ttl] and port.baud do
        parity = port |> Map.get(:parity, "none") |> String.first() |> String.upcase()
        data = Map.get(port, :data_bits, 8)
        stop = Map.get(port, :stop_bits, 1)
        [{"Serial settings", "#{port.baud} · #{data}-#{parity}-#{stop}", false}]
      else
        []
      end

    tail =
      [
        {"Claimed by", port.user || "Not claimed", false},
        {"Connected", port.since || "—", false},
        {"Errors (24h)", to_string(port.errors), false}
      ] ++ if port.notes, do: [{"Notes", port.notes, false}], else: []

    base ++ serial ++ tail
  end

  # ── Audio outputs summary (links to /audio) ───────────────────────────
  attr(:outputs, :map, required: true)

  defp audio_outputs_card(assigns) do
    sorted =
      assigns.outputs
      |> Map.values()
      |> Enum.sort_by(& &1.friendly_name)

    assigns = assign(assigns, :sorted, sorted)

    ~H"""
    <.card padding={:none} class="overflow-hidden">
      <div class="flex items-center justify-between px-4 py-3.5 border-b border-border-1">
        <div class="text-base font-semibold">Audio outputs</div>
        <.link
          navigate="/audio"
          class="text-sm text-accent hover:underline"
        >
          Manage
        </.link>
      </div>
      <ul class="divide-y divide-border-2">
        <li :for={out <- @sorted} class="px-4 py-3 flex items-center gap-3">
          <div class="flex-1 min-w-0">
            <div class="text-base text-fg-1 font-medium truncate">{out.friendly_name}</div>
            <div class="text-xs text-fg-3 mt-0.5">
              <span class="font-mono">{out.alsa_device}</span> · {out.card_name}
            </div>
          </div>
          <.audio_status_badge
            enabled={out.enabled}
            connection={Map.get(out, :connection, :unknown)}
            stream={Map.get(out, :stream)}
          />
        </li>
      </ul>
    </.card>
    """
  end

  attr(:enabled, :boolean, required: true)
  attr(:connection, :atom, required: true)
  attr(:stream, :any, required: true)

  # "Streaming" requires both a live WebSocket (`:connected`) AND a
  # current `stream_start` (non-nil `:stream`). The Sendspin client
  # holds the WebSocket open between songs, so a bare `:connected`
  # signal alone leaves the badge stuck on "Streaming" even after
  # playback ends. See `AudioLive.status_badge/1` for the same logic.
  #
  # `:unknown` connection (enabled, no event yet) renders as "Stopped"
  # on Overview to keep the row consistent with the surrounding UART
  # vocabulary ("Active / Idle / Stopped"). AudioLive renders the same
  # state as "Idle" — see `AudioLive.status_badge/1` for the rationale.
  defp audio_status_badge(assigns) do
    cond do
      not assigns.enabled ->
        ~H"<.badge variant={:neutral} dot>Disabled</.badge>"

      assigns.connection == :connected and not is_nil(assigns.stream) ->
        ~H"<.badge variant={:success} dot>Streaming</.badge>"

      assigns.connection == :connected ->
        ~H"<.badge variant={:accent} dot>Connected</.badge>"

      assigns.connection == :disconnected ->
        ~H"<.badge variant={:warning} dot>Searching</.badge>"

      true ->
        ~H"<.badge variant={:neutral} dot>Stopped</.badge>"
    end
  end
end
