defmodule Circuits.CEC.StructTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise
  import Circuits.CEC.TestSupport

  alias Circuits.CEC.{Message, Struct}

  doctest Struct

  describe "sizes" do
    test "match the kernel structs" do
      assert Struct.msg_size() == 56
      assert Struct.log_addrs_size() == 92
      assert Struct.event_size() == 80
      assert Struct.caps_size() == 76
      assert Struct.connector_info_size() == 68

      for {_name, bin} <- golden_prefixed("msg_"), do: assert(byte_size(bin) == 56)
      for {_name, bin} <- golden_prefixed("log_addrs_"), do: assert(byte_size(bin) == 92)
      for {_name, bin} <- golden_prefixed("event_"), do: assert(byte_size(bin) == 80)
      assert byte_size(golden("caps_vc4")) == 76
      assert byte_size(golden("connector_info_drm")) == 68
    end
  end

  describe "cec_msg golden fixtures" do
    test "transmit requests encode byte for byte" do
      assert Struct.encode_msg(msg: <<0x4F, 0x82, 0x10, 0x00>>) == golden("msg_tx_active_source")

      assert Struct.encode_msg(msg: <<0x40, 0x8F>>, reply: 0x90, timeout: 1000) ==
               golden("msg_tx_give_device_power_status")

      assert Struct.encode_msg(msg: <<0xF0, 0x04>>) ==
               golden("msg_tx_image_view_on_unregistered")
    end

    test "every fixture round-trips through decode and encode" do
      for {name, bin} <- golden_prefixed("msg_") do
        assert Struct.encode_msg(Struct.decode_msg(bin)) == bin, name
      end
    end

    test "a transmit result" do
      msg = Struct.decode_msg(golden("msg_rx_tx_result_ok"))

      assert %{sequence: 7, tx_ts: 123_456_789_012, msg: <<0x40, 0x04>>} = msg
      assert Struct.classify(msg) == :tx_result
      assert Struct.tx_outcome(msg.tx_status) == :ok
      assert Struct.rx_outcome(msg.rx_status) == :none
    end

    test "a NACKed transmit" do
      msg = Struct.decode_msg(golden("msg_rx_tx_result_nack"))

      assert %{sequence: 8, reply: 0x7A, tx_nack_cnt: 2} = msg
      assert Struct.classify(msg) == :tx_result
      assert Struct.flags(:tx_status, msg.tx_status) == [:nack, :max_retries]
      assert Struct.tx_outcome(msg.tx_status) == :nack
    end

    test "a reply" do
      msg = Struct.decode_msg(golden("msg_rx_reply_report_power_status"))

      assert Struct.classify(msg) == :rx_result
      assert Struct.rx_outcome(msg.rx_status) == :ok

      assert Message.decode(msg.msg) ==
               {:ok, %Message{from: 0, to: 4, body: {:report_power_status, :standby}}}
    end

    test "a Feature Abort reply" do
      msg = Struct.decode_msg(golden("msg_rx_reply_feature_abort"))

      assert Struct.classify(msg) == :rx_result
      assert Struct.rx_outcome(msg.rx_status) == :feature_abort

      assert Message.decode(msg.msg) ==
               {:ok,
                %Message{from: 5, to: 4, body: {:feature_abort, :give_audio_status, :refused}}}
    end

    test "an unsolicited broadcast" do
      msg = Struct.decode_msg(golden("msg_rx_unsolicited_standby"))

      assert Struct.classify(msg) == :unsolicited
      assert {:ok, %Message{from: 0, to: 15, body: :standby}} = Message.decode(msg.msg)
    end
  end

  describe "status bits" do
    test "tx_outcome prefers the cause over MAX_RETRIES" do
      assert Struct.tx_outcome(0x00) == :none
      assert Struct.tx_outcome(0x01) == :ok
      assert Struct.tx_outcome(0x02 ||| 0x20) == :arb_lost
      assert Struct.tx_outcome(0x04 ||| 0x20) == :nack
      assert Struct.tx_outcome(0x08 ||| 0x20) == :low_drive
      assert Struct.tx_outcome(0x10 ||| 0x20) == :error
      assert Struct.tx_outcome(0x20) == :max_retries
      assert Struct.tx_outcome(0x40) == :aborted
      assert Struct.tx_outcome(0x80) == :timeout
    end

    test "rx_outcome" do
      assert Struct.rx_outcome(0x00) == :none
      assert Struct.rx_outcome(0x01) == :ok
      assert Struct.rx_outcome(0x02) == :timeout
      assert Struct.rx_outcome(0x05) == :feature_abort
      assert Struct.rx_outcome(0x08) == :aborted
    end

    test "flags names every known bit" do
      assert Struct.flags(:tx_status, 0xFF) ==
               [:ok, :arb_lost, :nack, :low_drive, :error, :max_retries, :aborted, :timeout]

      assert Struct.flags(:rx_status, 0x0F) == [:ok, :timeout, :feature_abort, :aborted]
      assert Struct.flags(:event, 0x03) == [:initial_state, :dropped_events]
      assert Struct.flags_value(:msg, [:reply_to_followers, :raw]) == 0x03
    end

    test "classify" do
      assert Struct.classify(%{sequence: 0, tx_status: 1, rx_status: 0}) == :unsolicited
      assert Struct.classify(%{sequence: 3, tx_status: 1, rx_status: 1}) == :unknown
      assert Struct.classify(%{sequence: 3, tx_status: 0, rx_status: 0}) == :unknown
    end
  end

  describe "cec_log_addrs" do
    test "an empty configuration (clears the claim)" do
      assert Struct.encode_log_addrs([]) == golden("log_addrs_empty")

      assert %{log_addr: [0xFF, 0xFF, 0xFF, 0xFF], num_log_addrs: 0, osd_name: ""} =
               Struct.decode_log_addrs(golden("log_addrs_empty"))
    end

    test "a playback claim" do
      fields = [
        log_addr: [4],
        log_addr_mask: 0x10,
        cec_version: 5,
        num_log_addrs: 1,
        vendor_id: 0xFFFFFFFF,
        flags: [:allow_unreg_fallback],
        osd_name: "Universal Prox",
        primary_device_type: [Message.device_type(:playback)],
        log_addr_type: [Struct.log_addr_type(:playback)],
        all_device_types: [Struct.all_device_type(:playback)]
      ]

      bin = Struct.encode_log_addrs(fields)
      assert bin == golden("log_addrs_playback")

      decoded = Struct.decode_log_addrs(bin)

      assert %{
               log_addr: [4, 0xFF, 0xFF, 0xFF],
               log_addr_mask: 0x10,
               cec_version: 5,
               vendor_id: 0xFFFFFFFF,
               osd_name: "Universal Prox",
               primary_device_type: [4, 0, 0, 0],
               log_addr_type: [3, 0, 0, 0]
             } = decoded

      assert Struct.flags(:log_addrs, decoded.flags) == [:allow_unreg_fallback]
      assert Struct.encode_log_addrs(decoded) == bin
    end

    test "rejects an OSD name over 14 bytes" do
      assert_raise ArgumentError, fn -> Struct.encode_log_addrs(osd_name: "123456789012345") end
    end
  end

  describe "cec_event" do
    test "the initial state change" do
      bin = golden("event_state_change_initial")
      event = Struct.decode_event(bin)

      assert %{
               event: :state_change,
               ts: 1_000_000_000,
               phys_addr: 0x1000,
               log_addr_mask: 0x10,
               have_conn_info: 1
             } = event

      assert Struct.flags(:event, event.flags) == [:initial_state]

      assert Struct.encode_event(
               ts: 1_000_000_000,
               event: :state_change,
               flags: [:initial_state],
               phys_addr: 0x1000,
               log_addr_mask: 0x10,
               have_conn_info: 1
             ) == bin
    end

    test "unplugged" do
      assert %{event: :state_change, phys_addr: 0xFFFF, log_addr_mask: 0} =
               Struct.decode_event(golden("event_state_change_unplugged"))
    end

    test "lost messages" do
      bin = golden("event_lost_msgs")
      event = Struct.decode_event(bin)

      assert %{event: :lost_msgs, lost_msgs: 5} = event
      assert Struct.flags(:event, event.flags) == [:dropped_events]

      assert Struct.encode_event(ts: 3_000_000_000, event: :lost_msgs, flags: 2, lost_msgs: 5) ==
               bin
    end

    test "every fixture round-trips" do
      for {name, bin} <- golden_prefixed("event_") do
        assert Struct.encode_event(Struct.decode_event(bin)) == bin, name
      end
    end

    test "an unknown event number stays an integer" do
      bin = <<0::64, 42::little-32, 0::32, 0::512>>
      assert %{event: 42} = Struct.decode_event(bin)
      assert Struct.encode_event(Struct.decode_event(bin)) == bin
    end
  end

  describe "cec_caps and cec_connector_info" do
    test "caps" do
      bin = golden("caps_vc4")
      caps = Struct.decode_caps(bin)

      assert %{driver: "vc4_hdmi", name: "vc4-hdmi", available_log_addrs: 1, version: 0x061200} =
               caps

      assert Struct.flags(:caps, caps.capabilities) ==
               [:log_addrs, :transmit, :passthrough, :rc, :connector_info]

      assert Struct.encode_caps(caps) == bin
    end

    test "connector info" do
      bin = golden("connector_info_drm")
      conn = Struct.decode_connector_info(bin)

      assert %{type: :drm, card_no: 1, connector_id: 32} = conn
      assert Struct.encode_connector_info(conn) == bin
      assert Struct.encode_connector_info(type: :drm, card_no: 1, connector_id: 32) == bin
      assert %{type: :none} = Struct.decode_connector_info(<<0::544>>)
    end
  end

  describe "scalars and modes" do
    test "physical address and u32" do
      assert Struct.decode_phys_addr(<<0x00, 0x10>>) == 0x1000
      assert Struct.decode_u32(<<0x21, 0, 0, 0>>) == 0x21
    end

    test "modes" do
      assert Struct.mode(:initiator, :exclusive) == 0x21
      assert Struct.mode(:initiator, :follower) == 0x11
      assert Struct.mode(:none, :monitor_all) == 0xF0
      assert Struct.decode_mode(0x11) == {:initiator, :follower}
      assert Struct.decode_mode(0x05) == {5, :none}
    end
  end

  describe "properties" do
    property "decode_msg is total on any 56-byte binary" do
      check all(bin <- binary(length: 56)) do
        msg = Struct.decode_msg(bin)
        assert byte_size(msg.msg) <= 16
        assert Struct.classify(msg) in [:tx_result, :rx_result, :unsolicited, :unknown]
        assert is_atom(Struct.tx_outcome(msg.tx_status))
        assert is_atom(Struct.rx_outcome(msg.rx_status))
      end
    end

    property "the other decoders are total on binaries of their size" do
      check all(
              log_addrs <- binary(length: 92),
              event <- binary(length: 80),
              caps <- binary(length: 76),
              conn <- binary(length: 68)
            ) do
        assert is_map(Struct.decode_log_addrs(log_addrs))
        assert is_map(Struct.decode_event(event))
        assert is_map(Struct.decode_caps(caps))
        assert is_map(Struct.decode_connector_info(conn))
        assert Struct.encode_event(Struct.decode_event(event)) == event
        assert Struct.encode_connector_info(Struct.decode_connector_info(conn)) == conn
      end
    end

    property "encode_msg then decode_msg keeps every field" do
      check all(
              msg <- binary(min_length: 1, max_length: 16),
              timeout <- integer(0..0xFFFFFFFF),
              sequence <- integer(0..0xFFFFFFFF),
              reply <- integer(0..255),
              tx_status <- integer(0..255),
              rx_status <- integer(0..255)
            ) do
        fields = %{
          msg: msg,
          timeout: timeout,
          sequence: sequence,
          reply: reply,
          tx_status: tx_status,
          rx_status: rx_status
        }

        decoded = fields |> Struct.encode_msg() |> Struct.decode_msg()
        assert Map.take(decoded, Map.keys(fields)) == fields
      end
    end
  end
end
