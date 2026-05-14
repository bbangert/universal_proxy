defmodule UniversalProxyWeb.TrafficLive do
  @moduledoc """
  Traffic tab — terminal-style live stream of bytes flowing through every
  connected port. Filterable by port. Auto-scrolls.

  Frames are sourced from `UniversalProxy.UART.History`, a bounded
  in-memory ring buffer (100 frames per port) that survives LV reloads
  and reconnects. On mount we atomically register as a subscriber and
  pull a snapshot; thereafter live frames arrive as
  `{:uart_history_frame, frame}` messages.

  Port lifecycle (open/close) is tracked separately via
  `"uart:port_opened"` / `"uart:port_closed"` on `Phoenix.PubSub` so the
  port chip row stays in sync with hardware state. Z-Wave/IR adapters
  that bypass `UART.Server` will not appear here.

  ## Disconnected-port frames

  History intentionally retains buffered frames past `port_closed` so a
  briefly unplugged adapter still shows its last bytes when it comes
  back. `frame_to_line/2` here filters out any frame whose
  `friendly_name` no longer resolves against `Hardware.list_ports/0`,
  so the Traffic log only displays frames for ports currently
  enumerated by the hardware tree. If a port is physically removed,
  its retained frames disappear from this view (but remain in the
  History buffer until the eviction grace window — see
  `@port_eviction_grace_ms` in `UART.History` — expires).

  Payloads render as ASCII: printable bytes (0x20–0x7E) appear
  verbatim, everything else is escaped as `\\xNN`.
  """

  use UniversalProxyWeb, :live_view

  import UniversalProxyWeb.Components.UI
  import UniversalProxyWeb.Components.Icons

  alias UniversalProxy.Hardware
  alias UniversalProxy.UART.History
  alias UniversalProxyWeb.MockData

  @pubsub UniversalProxy.PubSub
  @max_lines 500

  @impl true
  def mount(_params, _session, socket) do
    ports = Hardware.list_ports()

    snapshot =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(@pubsub, "uart:port_opened")
        Phoenix.PubSub.subscribe(@pubsub, "uart:port_closed")
        History.subscribe_and_snapshot()
      else
        []
      end

    lines =
      snapshot
      |> Enum.map(&frame_to_line(&1, ports))
      |> Enum.reject(&is_nil/1)
      # Newest-first internally; the snapshot is oldest-first.
      |> Enum.reverse()
      |> Enum.take(@max_lines)

    {:ok,
     socket
     |> assign(:page_title, "Traffic")
     |> assign(:ports, ports)
     |> assign(:lines, lines)
     |> assign(:filter, "all")
     |> assign(:paused, false)
     |> assign(:autoscroll, true)
     |> recompute_view()}
  end

  @impl true
  def handle_event("filter", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:filter, id) |> recompute_view()}
  end

  def handle_event("toggle_paused", _params, socket) do
    {:noreply, assign(socket, :paused, !socket.assigns.paused)}
  end

  def handle_event("clear", _params, socket) do
    {:noreply, socket |> assign(:lines, []) |> recompute_view()}
  end

  def handle_event("toggle_autoscroll", %{"value" => v}, socket) do
    {:noreply, assign(socket, :autoscroll, v == "on")}
  end

  def handle_event("toggle_autoscroll", _params, socket) do
    {:noreply, assign(socket, :autoscroll, !socket.assigns.autoscroll)}
  end

  def handle_event("export", _params, socket) do
    content = format_export(socket.assigns.lines, socket.assigns.ports)
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d-%H%M%S")
    filename = "traffic-#{stamp}.log"

    {:noreply, push_event(socket, "traffic-export", %{filename: filename, content: content})}
  end

  @impl true
  def handle_info({:uart_port_opened, _info}, socket) do
    {:noreply, socket |> assign(:ports, Hardware.list_ports()) |> recompute_view()}
  end

  def handle_info({:uart_port_closed, _info}, socket) do
    {:noreply, socket |> assign(:ports, Hardware.list_ports()) |> recompute_view()}
  end

  def handle_info({:uart_history_frame, _frame}, %{assigns: %{paused: true}} = socket) do
    {:noreply, socket}
  end

  def handle_info({:uart_history_frame, frame}, socket) do
    case frame_to_line(frame, socket.assigns.ports) do
      nil -> {:noreply, socket}
      line -> {:noreply, push_line(socket, line)}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # -- Line buffer --

  # Newest-first internally; rendered reversed so newest is at the bottom
  # of the terminal stream and autoscroll lands on it.
  defp push_line(socket, line) do
    lines = [line | socket.assigns.lines] |> Enum.take(@max_lines)
    socket |> assign(:lines, lines) |> recompute_view()
  end

  # Pre-compute the derived view (oldest→newest visible list + per-port
  # chip counts) so `render/1` doesn't redo it on every change-tracking
  # pass. Called from every handler that mutates `:lines`, `:filter`, or
  # `:ports`.
  defp recompute_view(socket) do
    %{lines: lines, filter: filter, ports: ports} = socket.assigns

    filtered =
      if filter == "all",
        do: lines,
        else: Enum.filter(lines, &(&1.port == filter))

    counts = Enum.frequencies_by(lines, & &1.port)

    chips =
      [%{id: "all", name: "All ports", count: length(lines)}] ++
        for p <- ports, p.connected do
          %{id: p.id, name: p.slot, count: Map.get(counts, p.id, 0)}
        end

    socket
    |> assign(:visible, Enum.reverse(filtered))
    |> assign(:visible_count, length(filtered))
    |> assign(:chips, chips)
  end

  # Returns nil when the frame's source port is no longer in
  # `Hardware.list_ports/0` (e.g. the adapter was physically unplugged
  # after the frame was buffered).
  defp frame_to_line(%{name: name, data: data, timestamp: ts, dir: dir, id: id}, ports) do
    case Enum.find(ports, &(&1.ha_name == name)) do
      nil -> nil
      port -> build_line(id, port, data, ts, dir)
    end
  end

  defp build_line(id, port, data, ts, dir) do
    %{
      id: id,
      ts: format_ts(ts),
      port: port.id,
      dir: dir,
      proto: proto_label(port.kind),
      summary: summary_for(data),
      text: printable_ascii(data)
    }
  end

  defp format_ts(%DateTime{} = dt) do
    millis = div(dt.microsecond |> elem(0), 1_000)

    Calendar.strftime(dt, "%H:%M:%S") <>
      "." <> String.pad_leading(Integer.to_string(millis), 3, "0")
  end

  defp format_ts(_), do: "—"

  defp proto_label(:zwave), do: "Z-Wave"
  defp proto_label(:ir), do: "IR"
  defp proto_label(:rs232), do: "RS-232"
  defp proto_label(:rs485), do: "RS-485"
  defp proto_label(:ttl), do: "TTL"
  defp proto_label(_), do: "Serial"

  defp summary_for(data) when is_binary(data) do
    "#{byte_size(data)} B"
  end

  # Render bytes as ASCII: printable codepoints (0x20–0x7E) appear
  # verbatim; everything else escapes as `\xNN` (uppercase, 2 digits).
  # The per-line `@max_lines` cap is the only bound — no per-frame
  # truncation here.
  defp printable_ascii(data) when is_binary(data) do
    data
    |> :binary.bin_to_list()
    |> Enum.map_join("", fn
      b when b in 0x20..0x7E -> <<b>>
      b -> "\\x" <> (b |> Integer.to_string(16) |> String.upcase() |> String.pad_leading(2, "0"))
    end)
  end

  # -- Export --

  defp format_export(lines, ports) do
    port_index = Map.new(ports, &{&1.id, &1})

    lines
    |> Enum.reverse()
    |> Enum.map(fn line ->
      slot =
        case Map.get(port_index, line.port) do
          %{slot: slot} -> slot
          _ -> "—"
        end

      dir = if line.dir == :rx, do: "RX", else: "TX"
      text = line.text || ""
      "#{line.ts}  #{slot}  #{dir}  #{line.proto}  #{line.summary}  #{text}"
    end)
    |> Enum.join("\n")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-[1120px] mx-auto space-y-4">
      <%!-- Toolbar --%>
      <.card padding={:none} class="!px-3.5 !py-2.5 flex items-center gap-2.5 flex-wrap">
        <div class="flex gap-1.5 flex-wrap">
          <button
            :for={c <- @chips}
            phx-click="filter"
            phx-value-id={c.id}
            class={[
              "px-3 py-1 rounded-full text-sm font-medium border",
              if(@filter == c.id,
                do: "bg-accent-soft text-accent border-accent-soft-border",
                else: "bg-transparent text-fg-2 border-border-1 hover:text-fg-1"
              )
            ]}
          >
            {c.name}
            <span class="opacity-60 ml-1 tabular-nums">{c.count}</span>
          </button>
        </div>
        <div class="flex-1"></div>
        <label class="flex items-center gap-2 text-sm text-fg-2 cursor-pointer">
          <input
            type="checkbox"
            checked={@autoscroll}
            phx-click="toggle_autoscroll"
            class="rounded-sm"
          /> Autoscroll
        </label>
        <.button variant={:ghost} size={:sm} phx-click="toggle_paused">
          <.icon name={if @paused, do: :play, else: :pause} size={14} />
          {if @paused, do: "Resume", else: "Pause"}
        </.button>
        <.button variant={:ghost} size={:sm} phx-click="clear">
          <.icon name={:x} size={14} /> Clear
        </.button>
        <.button variant={:secondary} size={:sm} phx-click="export" disabled={@lines == []}>
          <.icon name={:download} size={14} /> Export
        </.button>
      </.card>

      <%!-- Terminal --%>
      <.card padding={:none} class="overflow-hidden">
        <div class="px-3.5 py-2.5 border-b border-border-1 bg-surface flex items-center gap-2.5 text-sm text-fg-3">
          <.icon name={:logs} size={14} />
          <span>Live traffic</span>
          <span class="text-fg-4">·</span>
          <span class="font-mono text-xs">{@visible_count} frames</span>
          <div class="flex-1"></div>
          <span :if={!@paused} class="flex items-center gap-1.5 text-success text-xs">
            <span class="w-1.5 h-1.5 rounded-full bg-current animate-rec-pulse"></span>
            RECORDING
          </span>
          <span :if={@paused} class="text-xs text-fg-3">Paused</span>
        </div>
        <div
          id="traffic-stream"
          phx-hook={if @autoscroll, do: "AutoScroll", else: nil}
          class="h-[460px] overflow-auto bg-sunken font-mono text-xs leading-[1.55] px-3.5 py-2.5"
        >
          <div :if={@visible == []} class="text-fg-4 text-center py-16 font-sans text-sm">
            Nothing to show yet — waiting for traffic on connected ports.
          </div>
          <.frame_line :for={line <- @visible} line={line} ports={@ports} />
        </div>
      </.card>
    </div>
    """
  end

  attr(:line, :map, required: true)
  attr(:ports, :list, required: true)

  defp frame_line(assigns) do
    port = Enum.find(assigns.ports, &(&1.id == assigns.line.port))
    tint_class = if port, do: MockData.kind_meta(port.kind).tint_class, else: "text-fg-3"
    dir_class = if assigns.line.dir == :rx, do: "text-accent", else: "text-success"
    dir_label = if assigns.line.dir == :rx, do: "RX", else: "TX"

    assigns =
      assigns
      |> assign(:tint_class, tint_class)
      |> assign(:dir_class, dir_class)
      |> assign(:dir_label, dir_label)
      |> assign(:port, port)

    ~H"""
    <div class="flex gap-2.5 py-px items-baseline whitespace-nowrap overflow-hidden">
      <span class="text-fg-4 flex-none w-[86px]">{@line.ts}</span>
      <span class={["flex-none w-[52px] font-semibold", @tint_class]}>
        {@port && @port.slot}
      </span>
      <span class={["flex-none w-[22px] font-bold", @dir_class]}>{@dir_label}</span>
      <span class="text-fg-3 flex-none w-12">{@line.proto}</span>
      <span class="text-fg-4 flex-none w-12 tabular-nums">{@line.summary}</span>
      <span class="text-fg-1 flex-1 truncate">{@line.text}</span>
    </div>
    """
  end
end
