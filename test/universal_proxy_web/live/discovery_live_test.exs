defmodule UniversalProxyWeb.DiscoveryLiveTest do
  # async: false — "save" writes the global ESPHome ConfigStore and restarts
  # the ESPHome supervisor.
  use ExUnit.Case, async: false
  import Phoenix.LiveViewTest
  import Phoenix.ConnTest

  alias UniversalProxy.ESPHome

  @endpoint UniversalProxyWeb.Endpoint

  setup do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  test "renders name controls without the unsaved Area and Advertise controls", %{conn: conn} do
    {:ok, view, html} = live(conn, "/discovery")

    assert html =~ "Friendly name"
    assert html =~ "ESPHome device name"
    refute html =~ "Advertise on network"
    refute html =~ ~s(name="discovery[area]")
    assert render(view) =~ "Discovery preview"
  end

  test "editing the friendly name updates the preview; saving persists it", %{conn: conn} do
    original = ESPHome.config()

    on_exit(fn ->
      ESPHome.update_config(
        name: original.name,
        friendly_name: Map.get(original, :friendly_name)
      )
    end)

    {:ok, view, _html} = live(conn, "/discovery")

    html =
      view
      |> element("form")
      |> render_change(%{"discovery" => %{"friendly" => "Rack Proxy Test"}})

    assert html =~ "Rack Proxy Test"

    view |> element("button", "Save changes") |> render_click()
    assert render(view) =~ "Saved."
    assert ESPHome.config().friendly_name == "Rack Proxy Test"
  end
end
