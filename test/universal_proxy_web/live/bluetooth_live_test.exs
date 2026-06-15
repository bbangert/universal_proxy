defmodule UniversalProxyWeb.BluetoothLiveTest do
  @moduledoc """
  Host-target tests. `UniversalProxy.Bluetooth` is compile-gated off on
  the host (`child_spec/1` → `:ignore`), so the subsystem is down: the
  public API returns its disabled-shaped reads and `{:error, :unavailable}`
  setters. These tests cover the view's behavior against exactly that.
  """
  use ExUnit.Case, async: false
  import Phoenix.LiveViewTest
  import Phoenix.ConnTest

  @endpoint UniversalProxyWeb.Endpoint
  @pubsub UniversalProxy.PubSub

  setup do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  # A present radio as `UniversalProxy.Bluetooth.RadioMonitor` would list it.
  defp radio(overrides \\ %{}) do
    Map.merge(
      %{
        hci: "hci0",
        address: "AA:BB:CC:DD:EE:FF",
        name: "Onboard radio",
        chip: "BCM4345C0",
        bus: :uart,
        detail: "UART",
        bt_version: "5.0",
        ble?: true,
        bredr?: true,
        in_use?: false
      },
      overrides
    )
  end

  defp inject_radios(view, radios) do
    Phoenix.PubSub.broadcast(@pubsub, "bluetooth:radios", {:bluetooth_radios, radios})
    render(view)
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

  test "no audio radio: audio-devices empty state + disabled Pair button", %{conn: conn} do
    {:ok, view, html} = live(conn, "/bluetooth")

    assert html =~ "No audio devices paired"
    assert html =~ "Assign a radio to the"
    # Pair device is rendered but disabled until a radio holds the Audio role.
    assert html =~ "Pair device"
    assert has_element?(view, ~s(button[phx-click="open_pair"][disabled]))
  end

  test "an injected radio renders the role selector (proxy/audio/off)", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/bluetooth")

    html = inject_radios(view, [radio()])

    assert html =~ ~s(phx-value-role="proxy")
    assert html =~ ~s(phx-value-role="audio")
    assert html =~ ~s(phx-value-role="off")
    assert html =~ "AA:BB:CC:DD:EE:FF"
  end

  test "choosing a role surfaces the unavailable error off-target", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/bluetooth")
    inject_radios(view, [radio()])

    html =
      view
      |> element(~s(button[phx-value-role="audio"]))
      |> render_click()

    assert html =~ "Bluetooth is unavailable on this device."
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
