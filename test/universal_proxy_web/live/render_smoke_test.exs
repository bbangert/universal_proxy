defmodule UniversalProxyWeb.RenderSmokeTest do
  @moduledoc """
  Smoke test that each LiveView mounts and renders without raising.
  Catches HEEx and assign errors that compile-time validation misses.
  """
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  import Phoenix.ConnTest

  @endpoint UniversalProxyWeb.Endpoint

  setup do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  test "Overview tab renders", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "Connected hardware"
    assert html =~ "Slots in use"
    assert html =~ "Universal Proxy"
  end

  test "Traffic tab renders", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/traffic")
    assert html =~ "Live traffic"
    assert html =~ "All ports"
  end

  test "Discovery tab renders", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/discovery")
    assert html =~ "How this device appears on your network"
    assert html =~ "Friendly name"
  end

  test "Security tab renders (off by default)", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/security")
    assert html =~ "API encryption"
    assert html =~ "Off by default"
  end

  test "System tab renders", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/system")
    assert html =~ "Firmware"
    assert html =~ "System log"
    assert html =~ "Factory reset"
  end

  test "Overview drawer opens on row click", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")

    # Pick the first row id from the rendered table; skip if the test
    # environment has no USB serial adapters at all.
    case Regex.run(~r/phx-value-id="(p_[^"]+)"/, html) do
      [_, id] ->
        drawer_html = view |> element("tr[phx-value-id='#{id}']") |> render_click()
        # Detail drawer always renders the Slot fact row.
        assert drawer_html =~ ~r/<dt[^>]*>Slot<\/dt>/

      nil ->
        :ok
    end
  end

  test "Security toggle generates a key when turned on", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/security")

    html = view |> element("button[role=switch]") |> render_click()
    assert html =~ "Encryption is on"
    assert html =~ "Pre-shared key"
  end
end
