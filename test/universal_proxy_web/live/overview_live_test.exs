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

  test "a connected Bluetooth output renders in the audio summary", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    bt =
      sample_output(%{
        key: {"AA:BB:CC:DD:EE:FF", nil, nil},
        card_index: nil,
        alsa_device: "bluealsa:DEV=AA:BB:CC:DD:EE:FF,PROFILE=a2dp",
        card_name: "Bluetooth A2DP",
        friendly_name: "Kitchen Speaker"
      })

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:output_added",
      {:sendspin_output_added, bt}
    )

    html = render(view)
    assert html =~ "Audio outputs"
    assert html =~ "Kitchen Speaker"
    assert html =~ "bluealsa:DEV=AA:BB:CC:DD:EE:FF"
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

  describe "hardware_rows/3 (USB hub tree)" do
    defp card(sub, name) do
      %{type_label: "Sound card", slot: "Sound card", slot_sub: sub, name: name}
    end

    @hub %{vendor_id: 0x0A12, product_id: 0x4010, name: "USB hub"}

    test "renders a hub at its slot with devices behind it indented (depth 1)" do
      ports = [slot("1-1.1.2", 1), slot("1-1.1.3", 2), slot("1-1.2", 3), slot("1-1.3", 4)]
      peripherals = [card("1-1.1.3.1", "FlooGoo FMA120")]
      hubs = %{"1-1.1.3" => @hub}

      assert [
               {:port, %{slot_sub: "1-1.1.2"}},
               {:hub,
                %{slot: "USB 2", slot_sub: "1-1.1.3", name: "USB hub", vidpid: "0A12:4010"}},
               {:peripheral, %{slot_sub: "1-1.1.3.1", depth: 1}},
               {:port, %{slot_sub: "1-1.2"}},
               {:port, %{slot_sub: "1-1.3"}}
             ] = OverviewLive.hardware_rows(ports, peripherals, hubs)
    end

    test "collapses a child that has both a serial port and a peripheral into the peripheral" do
      # The FMA120's ttyACM (a bonus port) and its sound card share 1-1.1.3.1.
      child_port = slot("1-1.1.3.1", 5, connected: true)
      ports = [slot("1-1.1.3", 2), child_port]
      peripherals = [card("1-1.1.3.1", "FlooGoo FMA120")]
      hubs = %{"1-1.1.3" => @hub}

      rows = OverviewLive.hardware_rows(ports, peripherals, hubs)

      # One hub + exactly one child row (the peripheral), no stray child port.
      assert [
               {:hub, %{slot_sub: "1-1.1.3"}},
               {:peripheral, %{slot_sub: "1-1.1.3.1", depth: 1}}
             ] = rows

      refute Enum.any?(rows, &match?({:port, %{slot_sub: "1-1.1.3.1"}}, &1))
    end

    test "orders children by bus path, interleaving ports and peripherals" do
      # Hub with a serial port at .1 and a sound card at .2 — must render in
      # bus-path order (.1 then .2), not peripherals-then-ports.
      child_port = slot("1-1.1.3.1", 5, connected: true)
      ports = [slot("1-1.1.3", 2), child_port]
      peripherals = [card("1-1.1.3.2", "Card")]
      hubs = %{"1-1.1.3" => @hub}

      assert [
               {:hub, %{slot_sub: "1-1.1.3"}},
               {:port, %{slot_sub: "1-1.1.3.1", depth: 1}},
               {:peripheral, %{slot_sub: "1-1.1.3.2", depth: 1}}
             ] = OverviewLive.hardware_rows(ports, peripherals, hubs)
    end

    test "a child port with no peripheral renders as an indented port row" do
      child_port = slot("1-1.1.3.1", 5, connected: true)
      ports = [slot("1-1.1.3", 2), child_port]
      hubs = %{"1-1.1.3" => @hub}

      assert [
               {:hub, %{slot_sub: "1-1.1.3"}},
               {:port, %{slot_sub: "1-1.1.3.1", depth: 1}}
             ] = OverviewLive.hardware_rows(ports, [], hubs)
    end

    test "ignores hubs that aren't a rendered slot (board-internal ancestor hubs)" do
      # The board's internal hubs (1-1, 1-1.1) are ancestors of the declared
      # slots and class-09, so usb_hubs/0 reports them — but they must NOT be
      # treated as tree-roots or they'd swallow every slot as a child.
      ports = [slot("1-1.1.2", 1), slot("1-1.1.3", 2), slot("1-1.2", 3), slot("1-1.3", 4)]

      hubs = %{
        "1-1" => @hub,
        "1-1.1" => @hub,
        "1-1.1.3" => @hub
      }

      assert [
               {:port, %{slot_sub: "1-1.1.2"}},
               {:hub, %{slot_sub: "1-1.1.3"}},
               {:port, %{slot_sub: "1-1.2"}},
               {:port, %{slot_sub: "1-1.3"}}
             ] = OverviewLive.hardware_rows(ports, [], hubs)
    end

    test "with no hubs the output is identical to hardware_rows/2" do
      ports = [slot("1-1.1.2", 1), slot("1-1.1.3", 2)]
      peripherals = [card("1-1.1.2", "DAC")]

      assert OverviewLive.hardware_rows(ports, peripherals, %{}) ==
               OverviewLive.hardware_rows(ports, peripherals)
    end
  end

  describe "slot_summary/5 (physical-slot occupancy across device types)" do
    @slots ["1-1.1.2", "1-1.1.3", "1-1.2", "1-1.3"]

    # All four receptacles full, by different device types: USB1 BT dongle,
    # USB2 FMA120 (audio+serial behind its hub), USB3 streaming audio, USB4 idle
    # audio. The serial-only count used to read "1/5"; this must read 4/4.
    defp full_board do
      ports = [
        %{connected: false, slot_sub: "1-1.1.2", in_use: false},
        %{connected: false, slot_sub: "1-1.1.3", in_use: false},
        %{connected: false, slot_sub: "1-1.2", in_use: false},
        %{connected: false, slot_sub: "1-1.3", in_use: false},
        %{connected: true, slot_sub: "1-1.1.3.1", in_use: false}
      ]

      audio = %{
        a: %{key: {"1-1.1.3.1", 0x0A12, 0x4007}, usb_port: "1-1.1.3.1", stream: nil},
        b: %{key: {"1-1.2", 1, 1}, usb_port: "1-1.2", stream: %{codec: "flac"}},
        c: %{key: {"1-1.3", 2, 2}, usb_port: "1-1.3", stream: nil}
      }

      bt = [%{bus: :usb, port: "1-1.1.2", hci: "hci1", in_use?: true}]
      hubs = %{"1-1" => %{}, "1-1.1" => %{}, "1-1.1.3" => %{}}
      {ports, audio, bt, hubs}
    end

    test "counts every occupied receptacle, not just serial ports" do
      {ports, audio, bt, hubs} = full_board()
      s = OverviewLive.slot_summary(ports, audio, bt, hubs, @slots)
      assert s.total == 4
      assert s.in_use == 4
      # Active: USB1 (BT in use) + USB3 (audio streaming).
      assert s.active == 2
      assert s.idle == 2
    end

    test "an empty board reads 0 in use" do
      s = OverviewLive.slot_summary([], %{}, [], %{}, @slots)
      assert s == %{in_use: 0, total: 4, active: 0, idle: 0}
    end

    test "dynamic target (no slot map) reports devices as N/N" do
      {ports, audio, bt, hubs} = full_board()
      s = OverviewLive.slot_summary(ports, audio, bt, hubs, nil)
      # Distinct device paths: 1-1.1.3.1 (serial+audio), 1-1.2, 1-1.3, 1-1.1.2.
      assert s == %{in_use: 4, total: 4, active: 2, idle: 2}
    end
  end
end
