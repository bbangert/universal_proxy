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

  The whole module is tagged `:hardware` and is skipped from `setup`
  when no USB serial adapter is plugged in — CI reports "skipped"
  rather than silently passing empty. Run with `mix test --include
  hardware` on a machine with a real adapter.
  """
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  import Phoenix.ConnTest

  alias UniversalProxy.Hardware

  @endpoint UniversalProxyWeb.Endpoint
  @moduletag :hardware

  setup do
    case Enum.find(Hardware.list_ports(), &(&1.connected and is_binary(&1.ha_name))) do
      # ExUnit treats the `:skip` context key as a signal to skip the
      # test (with the bound string shown as the skip reason). A bare
      # `{:skip, _}` return tuple is not valid setup output and crashes
      # the test instead.
      nil -> %{skip: "no connected USB serial adapter on this host"}
      port -> %{conn: Phoenix.ConnTest.build_conn(), port: port}
    end
  end

  test "TX frame renders with TX label, slot, and ASCII escapes", %{conn: conn, port: port} do
    {:ok, view, _html} = live(conn, "/traffic")

    send(view.pid, history_frame(port.ha_name, "Hi\x01", :tx))

    html = render(view)

    assert html =~ ">TX<"
    assert html =~ to_string(port.slot)
    assert html =~ "Hi\\x01"
  end

  test "ASCII boundary bytes around 0x20..0x7E escape correctly", %{conn: conn, port: port} do
    {:ok, view, _html} = live(conn, "/traffic")

    # 0x1F sits just below the printable range and must escape; 0x20
    # (space) and 0x7E (~) are the inclusive endpoints and pass through;
    # 0x7F (DEL) sits just above and must escape; 0x00 is the null
    # byte we explicitly want to see as `\x00` (not silent truncation).
    send(view.pid, history_frame(port.ha_name, <<0x00, 0x1F, 0x20, 0x7E, 0x7F>>, :rx))

    html = render(view)

    assert html =~ "\\x00\\x1F ~\\x7F"
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
end
