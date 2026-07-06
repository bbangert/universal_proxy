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

  test "a dead radio (no address) never renders as the in-use proxy", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/bluetooth")

    # A dead onboard radio (BlueZ not answering for it → nil address)
    # alongside a live USB one.
    inject_radios(view, [
      radio(%{address: nil}),
      radio(%{hci: "hci1", bus: :usb, name: "BlueZ 5.79", address: "11:22:33:44:55:66"})
    ])

    # Proxying is up (on the USB radio) while the proxy *role* is
    # unassigned — roles stay empty-shaped (proxy: nil) on host. The dead
    # radio's nil address must not match the nil proxy role.
    status = %{
      enabled: true,
      proxying?: true,
      adapter: %{name: "BlueZ 5.79", address: "11:22:33:44:55:66", hci: "hci1"},
      active_connections: %{allowed?: true, used: 0, limit: 3}
    }

    Phoenix.PubSub.broadcast(@pubsub, "bluetooth:state", {:bluetooth_state, status})
    html = render(view)

    refute html =~ "In use"
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

  describe "Improv Wi-Fi provisioning status row" do
    defp push_improv(view, status) do
      Phoenix.PubSub.broadcast(@pubsub, "bluetooth:improv", {:improv_status, status})
      render(view)
    end

    test "hidden while disarmed (the default)", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/bluetooth")
      refute html =~ "Wi-Fi setup over Bluetooth"
    end

    test "renders the status across states", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/bluetooth")

      html = push_improv(view, %{state: :advertising, error: nil})
      assert html =~ "Wi-Fi setup over Bluetooth"
      assert html =~ "Ready"
      assert html =~ "improv-wifi.com"

      html = push_improv(view, %{state: :provisioning, error: nil})
      assert html =~ "Connecting"
      assert html =~ "Joining the Wi-Fi network"

      html = push_improv(view, %{state: :provisioned, error: nil})
      assert html =~ "Done"
      assert html =~ "now online"
    end

    test "shows the error line on a failed connect", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/bluetooth")

      html = push_improv(view, %{state: :connected, error: :unable_to_connect})
      assert html =~ "Wi-Fi setup over Bluetooth"
      assert html =~ "check the password"
    end

    test "returns to hidden when disarmed again", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/bluetooth")

      assert push_improv(view, %{state: :advertising, error: nil}) =~ "Wi-Fi setup over Bluetooth"
      refute push_improv(view, %{state: :disarmed, error: nil}) =~ "Wi-Fi setup over Bluetooth"
    end
  end
end
