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
    # The Security tab reads the global ESPHome PSK store; ensure a plaintext
    # baseline so the smoke assertions don't see a key left in the on-disk
    # DETS by a prior run.
    UniversalProxy.ESPHome.PskStore.clear()
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
    assert html =~ "waiting for traffic"
  end

  test "Discovery tab renders", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/discovery")
    assert html =~ "How this device appears on your network"
    assert html =~ "Friendly name"
  end

  test "Audio tab renders", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/audio")
    assert html =~ "Sendspin players"
    # NullEnumerate in test env → empty list → empty-state copy.
    assert html =~ "No audio outputs detected"
  end

  test "Bluetooth tab renders", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/bluetooth")
    assert html =~ "Bluetooth proxy"
    # Non-BT host target → subsystem down → disabled status + empty radios.
    assert html =~ "Off"
    assert html =~ "No Bluetooth radios found"
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

  test "Security tab shows the connection-driven plaintext info panel", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/security")

    # No manual toggle anymore: plaintext until a client provisions a key.
    assert html =~ "turns on automatically"
    refute html =~ "role=\"switch\""
  end
end
