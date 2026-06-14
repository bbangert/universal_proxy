defmodule UniversalProxyWeb.OverviewLiveTest do
  @moduledoc """
  Focused tests for the audio-outputs summary row that was layered onto
  the Overview tab in Phase 4. The full-page smoke check stays in
  [render_smoke_test.exs](render_smoke_test.exs); this file drives the
  audio PubSub plumbing.
  """

  use ExUnit.Case, async: false
  import Phoenix.LiveViewTest
  import Phoenix.ConnTest
  import UniversalProxy.AudioFixtures

  alias UniversalProxyWeb.OverviewLive

  @endpoint UniversalProxyWeb.Endpoint
  @pubsub UniversalProxy.PubSub

  @hp_key UniversalProxy.AudioFixtures.hp_key()

  setup do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  test "USB Bluetooth row is keyed by its physical USB port, not its hci name",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    # A USB dongle the kernel resolved to receptacle 1-1.1.2. The Overview
    # hardware table should present it by that physical port (matching how
    # the Bluetooth page reads), never by the placeless "hci1" sysfs name.
    Phoenix.PubSub.broadcast(
      @pubsub,
      "bluetooth:radios",
      {:bluetooth_radios,
       [
         %{
           hci: "hci1",
           bus: :usb,
           port: "1-1.1.2",
           detail: "USB 2.0 · port 1-1.1.2",
           chip: "Realtek RTL8761B",
           bt_version: "5.1",
           ble?: true,
           bredr?: true,
           name: "ASUS USB-BT500",
           address: nil,
           in_use?: false
         }
       ]}
    )

    html = render(view)
    assert html =~ "1-1.1.2"
    assert html =~ "Bluetooth proxy"
    refute html =~ "hci1"
  end

  test "Overview omits the audio card when no outputs are present", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    # Audio summary card is gated on a non-empty list, and the
    # test-env NullEnumerate keeps the Audio.Server list empty.
    refute html =~ "Audio outputs"
  end

  test "Overview renders an audio row when :sendspin_output_added arrives", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:output_added",
      {:sendspin_output_added, sample_output()}
    )

    html = render(view)
    assert html =~ "Audio outputs"
    assert html =~ "Headphones"
    assert html =~ "plughw:0,0"
    # Default badge for enabled-but-no-event-yet output. Audio + Overview
    # collapse to one vocabulary; "Searching" is the warning-tinted
    # "we'd like to be streaming but nothing has connected" label.
    assert html =~ "Searching"
  end

  test "binary events progress the badge through Searching → Connected → Streaming",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:output_added",
      {:sendspin_output_added, sample_output()}
    )

    assert render(view) =~ "Searching"

    # WebSocket up but no audio yet → "Connected", not "Streaming".
    # The Sendspin client holds the socket open between songs, so this
    # is the long-lived idle-but-attached state.
    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:state",
      {:sendspin_state, @hp_key, %{event: "connected"}}
    )

    html = render(view)
    assert html =~ "Connected"
    refute html =~ ">Streaming<"

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:state",
      {:sendspin_state, @hp_key,
       %{event: "stream_start", codec: "opus", sample_rate: 48_000, bit_depth: 16, channels: 2}}
    )

    assert render(view) =~ "Streaming"
  end

  test "stream_end while still connected drops the badge back to Connected", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:output_added",
      {:sendspin_output_added, sample_output()}
    )

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:state",
      {:sendspin_state, @hp_key, %{event: "connected"}}
    )

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:state",
      {:sendspin_state, @hp_key,
       %{event: "stream_start", codec: "opus", sample_rate: 48_000, bit_depth: 16, channels: 2}}
    )

    assert render(view) =~ "Streaming"

    # The exact bug PR #41 fixes — track ends, server keeps the
    # WebSocket open, badge must NOT stay on "Streaming".
    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:state",
      {:sendspin_state, @hp_key, %{event: "stream_end"}}
    )

    html = render(view)
    assert html =~ "Connected"
    refute html =~ ">Streaming<"
  end

  test "disconnected clears the stream snapshot so badge can't read Streaming",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:output_added",
      {:sendspin_output_added, sample_output()}
    )

    # Race scenario: server pushed `stream_start`, then the socket
    # dropped before `stream_end`. The disconnected handler must clear
    # the cached stream — otherwise the badge would read "Streaming"
    # right up until the next `stream_end`, which never arrives.
    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:state",
      {:sendspin_state, @hp_key, %{event: "connected"}}
    )

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:state",
      {:sendspin_state, @hp_key,
       %{event: "stream_start", codec: "opus", sample_rate: 48_000, bit_depth: 16, channels: 2}}
    )

    assert render(view) =~ "Streaming"

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:state",
      {:sendspin_state, @hp_key, %{event: "disconnected"}}
    )

    html = render(view)
    assert html =~ "Searching"
    refute html =~ ">Streaming<"
  end

  test "Manage link points at /audio", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:output_added",
      {:sendspin_output_added, sample_output()}
    )

    assert render(view) =~ ~s|href="/audio"|
  end

  # `hardware_rows/2` is the slot-promotion + ordering core. It can't be
  # exercised through a live mount here: the host test env enumerates ports
  # dynamically (no declared `@external_slots`), so no empty slot ever
  # exists for a peripheral to be promoted into. Drive it directly instead.
  describe "hardware_rows/2 (slot promotion + ordering)" do
    defp slot(sub, n, opts \\ []) do
      %{slot: "USB #{n}", slot_sub: sub, connected: Keyword.get(opts, :connected, false)}
    end

    defp bt(sub) do
      %{type_label: "Bluetooth", slot: "Bluetooth", slot_sub: sub, name: "Dongle"}
    end

    defp audio do
      %{type_label: "Sound card", slot: "Sound card", slot_sub: nil, name: "Card"}
    end

    test "promotes a dongle into its matching empty slot, keeping declared order" do
      ports = [slot("1-1.1.2", 1), slot("1-1.1.3", 2), slot("1-1.2", 3), slot("1-1.3", 4)]

      assert [
               {:peripheral, %{slot: "USB 1", slot_sub: "1-1.1.2"}},
               {:port, %{slot_sub: "1-1.1.3"}},
               {:port, %{slot_sub: "1-1.2"}},
               {:port, %{slot_sub: "1-1.3"}}
             ] = OverviewLive.hardware_rows(ports, [bt("1-1.1.2")])
    end

    test "promotes into the correct slot regardless of which one the dongle fills" do
      ports = [slot("1-1.1.2", 1), slot("1-1.1.3", 2), slot("1-1.2", 3)]

      assert [
               {:port, %{slot_sub: "1-1.1.2"}},
               {:port, %{slot_sub: "1-1.1.3"}},
               {:peripheral, %{slot: "USB 3", slot_sub: "1-1.2"}}
             ] = OverviewLive.hardware_rows(ports, [bt("1-1.2")])
    end

    test "never replaces a connected port; an unclaimed dongle trails" do
      ports = [slot("1-1.1.2", 1, connected: true)]

      assert [
               {:port, %{slot_sub: "1-1.1.2", connected: true}},
               {:peripheral, %{slot: "Bluetooth", slot_sub: "1-1.1.2"}}
             ] = OverviewLive.hardware_rows(ports, [bt("1-1.1.2")])
    end

    test "audio cards (no slot path) and unmatched dongles trail in order" do
      ports = [slot("1-1.1.2", 1), slot("1-1.1.3", 2)]
      peripherals = [audio(), bt("1-1.1.2"), bt("9-9.9")]

      assert [
               {:peripheral, %{slot: "USB 1", slot_sub: "1-1.1.2"}},
               {:port, %{slot_sub: "1-1.1.3"}},
               {:peripheral, %{type_label: "Sound card"}},
               {:peripheral, %{slot: "Bluetooth", slot_sub: "9-9.9"}}
             ] = OverviewLive.hardware_rows(ports, peripherals)
    end

    test "promotes a USB sound card into its slot; an SoC card still trails" do
      ports = [slot("1-1.1.2", 1), slot("1-1.3", 2)]
      usb_card = %{type_label: "Sound card", slot: "Sound card", slot_sub: "1-1.3", name: "DAC"}

      assert [
               {:port, %{slot_sub: "1-1.1.2"}},
               {:peripheral, %{slot: "USB 2", slot_sub: "1-1.3", name: "DAC"}},
               {:peripheral, %{type_label: "Sound card", slot_sub: nil}}
             ] = OverviewLive.hardware_rows(ports, [audio(), usb_card])
    end
  end
end
