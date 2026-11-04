defmodule Circuits.CEC.PortTest do
  use ExUnit.Case, async: true

  alias Circuits.CEC.{Errno, Port, Struct}

  doctest Errno

  describe "encode_request/2" do
    test "header-only requests" do
      assert Port.encode_request(1, :caps) == <<0x01, 0x00, 0x01>>
      assert Port.encode_request(2, :g_phys) == <<0x02, 0x00, 0x02>>
      assert Port.encode_request(3, :g_log) == <<0x03, 0x00, 0x03>>
      assert Port.encode_request(0x1234, :g_mode) == <<0x05, 0x12, 0x34>>
      assert Port.encode_request(0xFFFF, :g_conn) == <<0x08, 0xFF, 0xFF>>
    end

    test "requests with a body" do
      log_addrs = Struct.encode_log_addrs([])
      msg = Struct.encode_msg(msg: <<0x40, 0x04>>)

      assert Port.encode_request(4, {:s_log, log_addrs}) == <<0x04, 0, 4, log_addrs::binary>>
      assert Port.encode_request(5, {:s_mode, 0x21}) == <<0x06, 0, 5, 0x21, 0, 0, 0>>
      assert Port.encode_request(6, {:transmit, msg}) == <<0x07, 0, 6, msg::binary>>
    end

    test "rejects bodies of the wrong size and req_id 0" do
      assert_raise ArgumentError, fn -> Port.encode_request(1, {:transmit, <<0x40, 0x04>>}) end
      assert_raise ArgumentError, fn -> Port.encode_request(1, {:s_log, <<0::8>>}) end
      bogus = Process.get(:not_set, :bogus)
      assert_raise ArgumentError, fn -> Port.encode_request(1, bogus) end
      assert_raise FunctionClauseError, fn -> Port.encode_request(0, :caps) end
    end
  end

  describe "decode_frame/1" do
    test "replies" do
      assert Port.decode_frame(<<0x80, 0, 7, 0x00, 0x10>>) ==
               {:ok, {:reply, 7, {:ok, <<0x00, 0x10>>}}}

      assert Port.decode_frame(<<0x80, 0, 7>>) == {:ok, {:reply, 7, {:ok, <<>>}}}

      assert Port.decode_frame(<<0x81, 0, 8, 16::little-32>>) ==
               {:ok, {:reply, 8, {:error, :ebusy}}}

      assert Port.decode_frame(<<0x81, 0, 8, 999::little-32>>) ==
               {:ok, {:reply, 8, {:error, 999}}}
    end

    test "unsolicited frames" do
      caps = Struct.encode_caps(driver: "vc4_hdmi")
      msg = Struct.encode_msg(msg: <<0x0F, 0x36>>)
      event = Struct.encode_event(event: :lost_msgs, lost_msgs: 1)

      assert Port.decode_frame(<<0x90, 0, 0, caps::binary>>) == {:ok, {:ready, caps}}
      assert Port.decode_frame(<<0x91, 0, 0, 2::little-32>>) == {:ok, {:open_error, :enoent}}
      assert Port.decode_frame(<<0x92, 0, 0, msg::binary>>) == {:ok, {:msg, msg}}
      assert Port.decode_frame(<<0x93, 0, 0, event::binary>>) == {:ok, {:event, event}}
      assert Port.decode_frame(<<0x94, 0, 0>>) == {:ok, :gone}
    end

    test "malformed frames" do
      for frame <- [
            <<>>,
            <<0x80>>,
            <<0x80, 0, 0>>,
            <<0x81, 0, 1, 1, 2>>,
            <<0x92, 0, 0, 1, 2, 3>>,
            <<0x92, 0, 1, 0::448>>,
            <<0x94, 0, 0, 1>>,
            <<0x55, 0, 0>>
          ] do
        assert Port.decode_frame(frame) == {:error, :malformed}, inspect(frame)
      end
    end
  end
end
