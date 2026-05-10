defmodule UniversalProxyWeb.TrafficLive do
  @moduledoc """
  Traffic tab — terminal-style live stream of decoded frames flowing through
  every connected port. Filterable by port. Auto-scrolls.
  """

  use UniversalProxyWeb, :live_view

  import UniversalProxyWeb.Components.UI
  import UniversalProxyWeb.Components.Icons

  alias UniversalProxyWeb.MockData

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Traffic")
     |> assign(:ports, MockData.ports())
     |> assign(:lines, MockData.seed_traffic())
     |> assign(:filter, "all")
     |> assign(:paused, false)
     |> assign(:autoscroll, true)}
  end

  @impl true
  def handle_event("filter", %{"id" => id}, socket) do
    {:noreply, assign(socket, :filter, id)}
  end

  def handle_event("toggle_paused", _params, socket) do
    {:noreply, assign(socket, :paused, !socket.assigns.paused)}
  end

  def handle_event("clear", _params, socket) do
    {:noreply, assign(socket, :lines, [])}
  end

  def handle_event("toggle_autoscroll", %{"value" => v}, socket) do
    {:noreply, assign(socket, :autoscroll, v == "on")}
  end

  def handle_event("toggle_autoscroll", _params, socket) do
    {:noreply, assign(socket, :autoscroll, !socket.assigns.autoscroll)}
  end

  @impl true
  def render(assigns) do
    filtered =
      if assigns.filter == "all",
        do: assigns.lines,
        else: Enum.filter(assigns.lines, &(&1.port == assigns.filter))

    chips =
      [%{id: "all", name: "All ports", count: length(assigns.lines)}] ++
        for p <- assigns.ports, p.connected do
          %{
            id: p.id,
            name: p.slot,
            count: Enum.count(assigns.lines, &(&1.port == p.id))
          }
        end

    assigns = assign(assigns, filtered: filtered, chips: chips)

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
        <.button variant={:secondary} size={:sm}>
          <.icon name={:download} size={14} /> Export
        </.button>
      </.card>

      <%!-- Terminal --%>
      <.card padding={:none} class="overflow-hidden">
        <div class="px-3.5 py-2.5 border-b border-border-1 bg-surface flex items-center gap-2.5 text-sm text-fg-3">
          <.icon name={:logs} size={14} />
          <span>Live traffic</span>
          <span class="text-fg-4">·</span>
          <span class="font-mono text-xs">{length(@filtered)} frames</span>
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
          <div :if={@filtered == []} class="text-fg-4 text-center py-16 font-sans text-sm">
            Nothing to show yet — traffic stream is empty.
          </div>
          <.frame_line :for={line <- @filtered} line={line} ports={@ports} />
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
    <div class="flex gap-2.5 py-px">
      <span class="text-fg-4 flex-none w-[86px]">{@line.ts}</span>
      <span class={["flex-none w-[64px] font-semibold", @tint_class]}>
        {@port && @port.slot}
      </span>
      <span class={["flex-none w-[22px] font-bold", @dir_class]}>{@dir_label}</span>
      <span class="text-fg-3 flex-none w-12">{@line.proto}</span>
      <span class="text-fg-1 flex-1 break-all whitespace-pre-wrap">
        {@line.summary}
        <span :if={@line.hex} class="text-fg-3 ml-2">{@line.hex}</span>
      </span>
    </div>
    """
  end
end
