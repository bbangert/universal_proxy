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

  test "audio role gated off: no Audio role button, dongle guidance instead", %{conn: conn} do
    Application.put_env(:universal_proxy, :bt_audio_role_override, false)
    on_exit(fn -> Application.delete_env(:universal_proxy, :bt_audio_role_override) end)

    {:ok, view, html} = live(conn, "/bluetooth")

    # Audio-devices section replaced by the dedicated-dongle guidance.
    refute html =~ "Pair device"
    assert html =~ "can&#39;t stream audio reliably"
    assert html =~ "FMA120"

    # A present radio renders Proxy/Off but no Audio segment.
    html = inject_radios(view, [radio()])
    assert html =~ "phx-value-role=\"proxy\""
    assert html =~ "phx-value-role=\"off\""
    refute html =~ "phx-value-role=\"audio\""
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
      paused?: false,
      adapter: %{name: "BlueZ 5.79", address: "11:22:33:44:55:66", hci: "hci1"},
      active_connections: %{allowed?: true, used: 0, limit: 3}
    }

    Phoenix.PubSub.broadcast(@pubsub, "bluetooth:state", {:bluetooth_state, status})
    html = render(view)

    refute html =~ "In use"
  end

  test "role-paused status renders Paused with the assign-a-radio hint", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/bluetooth")

    # The first radio keeps a stale/transient in_use? mark (the subtree
    # still auto-claims one for the radio list while paused) — it must NOT
    # render as the effective proxy: effective_role/3 requires proxying?.
    inject_radios(view, [
      radio(%{in_use?: true}),
      radio(%{hci: "hci1", address: "11:22:33:44:55:66", bus: :usb})
    ])

    status = %{
      enabled: true,
      proxying?: false,
      paused?: true,
      adapter: %{name: "BlueZ 5.79", address: "AA:BB:CC:DD:EE:FF", hci: "hci0"},
      active_connections: %{allowed?: true, used: 0, limit: 3}
    }

    Phoenix.PubSub.broadcast(@pubsub, "bluetooth:state", {:bluetooth_state, status})
    html = render(view)

    assert html =~ "Paused"
    assert html =~ "Assign a radio to the Proxy role below to start relaying."
    refute html =~ "Relaying on"
    refute html =~ "In use"
  end

  test "an auto-claimed radio displays as the effective proxy", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/bluetooth")

    # No roles assigned anywhere (host roles read back empty-shaped); the
    # stack auto-claimed this radio, so its row must say so.
    inject_radios(view, [radio(%{in_use?: true})])

    status = %{
      enabled: true,
      proxying?: true,
      paused?: false,
      adapter: %{name: "BlueZ 5.79", address: "AA:BB:CC:DD:EE:FF", hci: "hci0"},
      active_connections: %{allowed?: true, used: 0, limit: 3}
    }

    Phoenix.PubSub.broadcast(@pubsub, "bluetooth:state", {:bluetooth_state, status})
    html = render(view)

    assert html =~ "In use"
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

  describe "Tuya mesh role" do
    alias UniversalProxy.Bluetooth.{Manager, RadioMonitor, Settings}

    @mesh_a "B8:27:EB:11:22:33"
    @mesh_b "AA:BB:CC:DD:EE:FF"

    defmodule StubBluez do
      @moduledoc false
      use Agent

      def start_link(_opts), do: Agent.start_link(fn -> :ok end)
    end

    # The real Settings/Manager/RadioMonitor under their global names (what
    # the public API calls), over fixture sysfs and a stub Bluez child.
    defp start_subsystem(radios) do
      tmp = Path.join(System.tmp_dir!(), "bt_live_test_#{System.unique_integer([:positive])}")
      sysfs = Path.join(tmp, "sysfs")

      for {hci, mac} <- radios do
        File.mkdir_p!(Path.join(sysfs, hci))
        File.write!(Path.join([sysfs, hci, "address"]), mac <> "\n")
      end

      on_exit(fn ->
        File.rm_rf(tmp)

        for key <- [
              Bluez.DevicePath.desired_adapter_key(),
              Bluez.DevicePath.excluded_adapters_key()
            ],
            do: :persistent_term.erase(key)
      end)

      start_supervised!(
        {Settings, table: :bluetooth_live_test, dets_path: Path.join(tmp, "s.dets")}
      )

      dynsup = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

      start_supervised!(
        {Manager,
         dynamic_supervisor: dynsup,
         bluez_child: StubBluez,
         sysfs_root: sysfs,
         pubsub: @pubsub,
         restart_settle_ms: 0,
         esphome_restart_fun: fn -> :ok end}
      )

      start_supervised!(
        {RadioMonitor,
         sysfs_root: sysfs,
         pubsub: @pubsub,
         adapters_info_fun: fn ->
           for {hci, mac} <- radios,
               do: %{path: "/org/bluez/#{hci}", address: mac, name: hci, powered: true}
         end}
      )

      _ = Manager.status()
      _ = RadioMonitor.list()
      :ok
    end

    test "offered with two radios, hidden on a lone radio", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/bluetooth")

      html = inject_radios(view, [radio(), radio(%{hci: "hci1", address: "11:22:33:44:55:66"})])
      assert html =~ ~s(phx-value-role="tuya_mesh")
      assert html =~ "Tuya mesh"

      refute inject_radios(view, [radio()]) =~ ~s(phx-value-role="tuya_mesh")
    end

    test "a refused lone-radio assignment renders the error inline", %{conn: conn} do
      start_subsystem([{"hci0", @mesh_a}])
      {:ok, view, html} = live(conn, "/bluetooth")
      refute html =~ ~s(phx-value-role="tuya_mesh")

      # The option is hidden, so drive the event directly (a stale page or a
      # scripted client): the server-side refusal is the real guard.
      html = render_click(view, "set_role", %{"mac" => @mesh_a, "role" => "tuya_mesh"})

      assert html =~ "The Tuya mesh needs a radio of its own."
      assert Settings.get().roles == %{}
    end

    test "switching a radio to Tuya mesh marks it dedicated", %{conn: conn} do
      start_subsystem([{"hci0", @mesh_a}, {"hci1", @mesh_b}])
      {:ok, view, html} = live(conn, "/bluetooth")
      refute html =~ "is dedicated to the"

      html =
        view
        |> element(~s(button[phx-value-mac="#{@mesh_b}"][phx-value-role="tuya_mesh"]))
        |> render_click()

      assert html =~ "is dedicated to the"
      assert html =~ "Nothing else uses it"

      assert has_element?(
               view,
               ~s(button[phx-value-mac="#{@mesh_b}"][phx-value-role="tuya_mesh"][aria-pressed="true"])
             )

      assert Settings.tuya_adapter(Settings.get()) == @mesh_b
    end
  end
end
