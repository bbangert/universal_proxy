defmodule UniversalProxyWeb.BluetoothLiveTest do
  @moduledoc """
  Host-target tests. `UniversalProxy.Bluetooth` is compile-gated off on
  the host (`child_spec/1` → `:ignore`), so the subsystem is down: the
  public API returns its disabled-shaped reads and `{:error, :unavailable}`
  setters. These tests cover the view's behavior against exactly that.
  """
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  import Phoenix.ConnTest

  @endpoint UniversalProxyWeb.Endpoint

  setup do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  test "renders the disabled status and empty-radio state", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/bluetooth")

    assert html =~ "Bluetooth proxy"
    assert html =~ "Off"
    assert html =~ "Passive scanning and active connections are stopped."
    assert html =~ "No Bluetooth radios found"
    # No live stats row while not proxying.
    refute html =~ "Advertisements / s"
  end

  test "toggling the master switch surfaces the unavailable error", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/bluetooth")

    html = view |> element("button[phx-click=toggle_enabled]") |> render_click()

    assert html =~ "Bluetooth is unavailable on this device."
  end

  test "rescan is a no-op that keeps the empty state", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/bluetooth")

    html = view |> element("button", "Rescan") |> render_click()
    assert html =~ "No Bluetooth radios found"
  end
end
