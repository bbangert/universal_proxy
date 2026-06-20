defmodule UniversalProxyWeb.HeaderClientsTest do
  @moduledoc """
  The connected-clients pill lives in the shared app layout and is wired
  through NavHooks, so it appears on every tab. With no native-API client
  connected in the test environment, it shows the empty state.
  """

  use ExUnit.Case, async: false
  import Phoenix.LiveViewTest
  import Phoenix.ConnTest

  @endpoint UniversalProxyWeb.Endpoint

  setup do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  test "header pill renders the no-clients state and is collapsed", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    assert html =~ "No clients"
    assert html =~ ~s(phx-click="toggle_ha_clients")
    # Popover content not present until opened.
    refute html =~ "ESPHome API clients"
  end

  test "clicking the pill toggles the popover open and closed", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    opened = view |> element("button[phx-click='toggle_ha_clients']") |> render_click()
    assert opened =~ "ESPHome API clients"
    assert opened =~ "Nothing is talking to the proxy over the native API yet"

    closed = view |> element("div[phx-click='close_ha_clients']") |> render_click()
    refute closed =~ "ESPHome API clients"
  end

  test "the pill is present on a non-root tab too", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/system")
    assert html =~ ~s(phx-click="toggle_ha_clients")
  end
end
