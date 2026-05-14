defmodule UniversalProxyWeb.Components.PortSparkline do
  @moduledoc """
  Per-port throughput sparkline as a stateful `Phoenix.LiveComponent`.

  The owning `LiveView` is responsible for subscribing to
  `UniversalProxy.UART.History.throughput_subscribe_and_snapshot/1` for
  each port it shows and routing `{:uart_throughput, %{name, samples}}`
  messages to this component via `Phoenix.LiveView.send_update/3` —
  storing the samples on the parent's assigns would mark *every* row
  dirty on every tick. send_update lets only the targeted instance
  re-render.

  ## Required assigns

  * `:id`         — used by `send_update` to route updates. The owning
    LV uses two different ids per port (table cell and drawer body)
    when both views render simultaneously.
  * `:port_kind`  — `t:UniversalProxy.UART.PortConfig.kind/0` drives
    the tint colour.
  * `:variant`    — `:compact` (table cell, SVG only) or `:full`
    (drawer body, SVG + rate readout). Defaults to `:compact`.

  ## Optional assigns

  * `:samples`         — `[{rx_bytes, tx_bytes}]` newest-first. Comes
    via `send_update` on each tick. Defaults to nil.
  * `:initial_samples` — same shape; consulted once on first mount
    before live samples arrive. The owning LV passes the snapshot it
    got back from `throughput_subscribe_and_snapshot/1`.
  """
  use UniversalProxyWeb, :live_component

  import UniversalProxyWeb.Components.UI

  alias UniversalProxyWeb.MockData

  @width 84
  @height 24
  @window 24

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign_new(:variant, fn -> :compact end)
      |> assign_new(:samples, fn -> nil end)
      |> apply_assigns(assigns)

    {:ok, socket}
  end

  # `send_update` routes live ticks here as `%{samples: …}`. The
  # initial-mount path receives `:port_kind`, `:variant`, and
  # `:initial_samples`. Either path may also carry `:id` (always set by
  # the framework).
  defp apply_assigns(socket, %{samples: samples} = assigns) do
    socket
    |> assign(:samples, samples)
    |> assign(Map.delete(assigns, :samples))
  end

  defp apply_assigns(socket, assigns) do
    case Map.get(assigns, :initial_samples) do
      nil ->
        assign(socket, Map.delete(assigns, :initial_samples))

      initial ->
        socket
        |> assign(Map.delete(assigns, :initial_samples))
        |> assign_new(:samples, fn -> initial end)
    end
  end

  @impl true
  def render(%{variant: :full} = assigns) do
    {unit, in_val, out_val} = format_rate(assigns.samples)

    assigns =
      assigns
      |> assign(:unit, unit)
      |> assign(:in_val, in_val)
      |> assign(:out_val, out_val)

    ~H"""
    <div class="mx-6 mb-4 p-3.5 bg-sunken rounded-md">
      <.eyebrow class="mb-2.5">Live throughput</.eyebrow>
      <.spark_svg samples={@samples} port_kind={@port_kind} />
      <div class="flex gap-5 mt-2.5 text-sm text-fg-3">
        <span>
          <span class="text-fg-2 font-mono">↓ {@in_val} {@unit}</span> in
        </span>
        <span>
          <span class="text-fg-2 font-mono">↑ {@out_val} {@unit}</span> out
        </span>
      </div>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div><.spark_svg samples={@samples} port_kind={@port_kind} /></div>
    """
  end

  attr(:samples, :any, required: true)
  attr(:port_kind, :atom, required: true)

  defp spark_svg(assigns) do
    pts = sparkline_points(assigns.samples)

    path =
      pts
      |> Enum.with_index()
      |> Enum.map_join(" ", fn {v, i} ->
        x = Float.round(i / (length(pts) - 1) * @width, 1)
        y = Float.round(@height - v * @height, 1)
        cmd = if i == 0, do: "M", else: "L"
        "#{cmd}#{x},#{y}"
      end)

    fill_path = "#{path} L#{@width},#{@height} L0,#{@height} Z"
    tint = MockData.kind_meta(assigns.port_kind).tint

    assigns =
      assigns
      |> assign(:path, path)
      |> assign(:fill_path, fill_path)
      |> assign(:tint, tint)
      |> assign(:w, @width)
      |> assign(:h, @height)

    ~H"""
    <svg width={@w} height={@h} class="block">
      <path d={@fill_path} fill={@tint} opacity="0.12" />
      <path d={@path} stroke={@tint} stroke-width="1.5" fill="none" />
    </svg>
    """
  end

  # Samples are newest-first; reverse so the leftmost point is oldest
  # and the rightmost is the most recent tick.
  defp sparkline_points(samples) when is_list(samples) and samples != [] do
    totals = Enum.map(samples, fn {rx, tx} -> rx + tx end)
    max_v = totals |> Enum.max() |> max(1)
    totals |> Enum.reverse() |> Enum.map(&max(0.05, &1 / max_v))
  end

  defp sparkline_points(_), do: List.duplicate(0.05, @window)

  # Human-friendly units for the latest 1-second sample. Picks the
  # larger direction to drive the unit so both values stay comparable.
  defp format_rate([{rx, tx} | _]) do
    max_v = max(rx, tx)

    cond do
      max_v >= 1_000_000 -> {"MB/s", scale(rx, 1_000_000), scale(tx, 1_000_000)}
      max_v >= 1_000 -> {"kB/s", scale(rx, 1_000), scale(tx, 1_000)}
      true -> {"B/s", rx, tx}
    end
  end

  defp format_rate(_), do: {"B/s", 0, 0}

  defp scale(value, divisor), do: Float.round(value / divisor, 1)
end
