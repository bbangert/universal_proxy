defmodule UniversalProxyWeb.TrafficLiveTest do
  @moduledoc """
  Exercises TrafficLive's `:uart_history_frame` handler: ensures TX
  frames forwarded from `UniversalProxy.UART.History` render with the
  `TX` label and port slot, and that payload bytes render as ASCII
  with non-printable bytes escaped as `\\xNN`.

  Frames are delivered via `send(view.pid, ...)` rather than going
  through History/PubSub: this isolates the LV's render path from
  History's subscription bookkeeping and avoids fighting the singleton
  state of the application-tree History instance.

  The whole module is tagged `:hardware` so `mix test` excludes it
  on hosts without a real USB serial adapter (see `test_helper.exs`).
  CI reports these as `excluded`, not failed. Run locally against a
  real adapter with `mix test --include hardware`.
  """
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  import Phoenix.ConnTest

  alias UniversalProxy.Hardware

  @endpoint UniversalProxyWeb.Endpoint
  @moduletag :hardware

  setup do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  test "TX frame renders with TX label, slot, and ASCII escapes", %{conn: conn} do
    with_connected_port(fn port ->
      {:ok, view, _html} = live(conn, "/traffic")

      send(view.pid, history_frame(port.ha_name, "Hi\x01", :tx))

      html = render(view)

      assert html =~ ">TX<"
      assert html =~ to_string(port.slot)
      assert html =~ "Hi\\x01"
    end)
  end

  test "ASCII boundary bytes around 0x20..0x7E escape correctly", %{conn: conn} do
    with_connected_port(fn port ->
      {:ok, view, _html} = live(conn, "/traffic")

      # 0x1F sits just below the printable range and must escape; 0x20
      # (space) and 0x7E (~) are the inclusive endpoints and pass through;
      # 0x7F (DEL) sits just above and must escape; 0x00 is the null
      # byte we explicitly want to see as `\x00` (not silent truncation).
      send(view.pid, history_frame(port.ha_name, <<0x00, 0x1F, 0x20, 0x7E, 0x7F>>, :rx))

      html = render(view)

      assert html =~ "\\x00\\x1F ~\\x7F"
    end)
  end

  defp history_frame(name, data, dir) do
    {:uart_history_frame,
     %{
       id: System.unique_integer([:positive, :monotonic]),
       name: name,
       data: data,
       timestamp: DateTime.utc_now(),
       dir: dir
     }}
  end

  # The module is excluded by default via `@moduletag :hardware`; this
  # is the `mix test --include hardware` path. If the dev forces
  # inclusion but has no adapter plugged in, silently pass — they
  # asked for hardware tests on a host that can't satisfy them, and
  # crashing isn't a useful signal.
  defp with_connected_port(fun) do
    case Enum.find(Hardware.list_ports(), &(&1.connected and is_binary(&1.ha_name))) do
      nil -> :ok
      port -> fun.(port)
    end
  end
end
