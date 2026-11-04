defmodule Circuits.CEC.Transport.PortTest do
  # Runs the real cec_port helper, and its stubbed-ioctl build, on the host.
  use ExUnit.Case, async: true

  import Circuits.CEC.TestSupport

  alias Circuits.CEC.{Message, Struct}
  alias Circuits.CEC.Port, as: Protocol
  alias Circuits.CEC.Transport.Port, as: Transport

  test "open/2 without a helper is unsupported" do
    assert Transport.open("/dev/cec0", helper: "/nonexistent/cec_port") == {:error, :unsupported}
  end

  describe "real helper" do
    @describetag :helper

    test "a missing device reports ENOENT and exits 1" do
      {:ok, t} = Transport.open("/dev/cec-does-not-exist")
      assert {[{:open_error, :enoent}], t} = await(t)
      assert {[{:exit, 1}], t} = await(t)
      assert Transport.send_request(t, :caps) == {:error, :closed}
    end

    test "a device that isn't CEC reports ENOTTY and exits 1" do
      {:ok, t} = Transport.open("/dev/null")
      assert {[{:open_error, :enotty}], t} = await(t)
      assert {[{:exit, 1}], _t} = await(t)
    end
  end

  describe "stubbed helper" do
    @describetag :helper

    setup do
      {:ok, t} = Transport.open("test", helper: test_backend_path())
      {[{:ready, caps}], t} = await(t)
      {[{:event, initial}], t} = await(t)
      %{t: t, caps: caps, initial: initial}
    end

    test "ready carries the caps, then the initial state change", %{caps: caps, initial: initial} do
      assert %{driver: "cec_port_test", available_log_addrs: 1} = Struct.decode_caps(caps)

      assert %{event: :state_change, phys_addr: 0x1000, flags: flags} =
               Struct.decode_event(initial)

      assert Struct.flags(:event, flags) == [:initial_state]
    end

    test "getters", %{t: t} do
      {t, {:ok, caps}} = request(t, :caps)
      assert %{name: "test adapter"} = Struct.decode_caps(caps)

      {t, {:ok, pa}} = request(t, :g_phys)
      assert Struct.decode_phys_addr(pa) == 0x1000

      {t, {:ok, las}} = request(t, :g_log)

      assert %{num_log_addrs: 0, log_addr: [0xFF, 0xFF, 0xFF, 0xFF]} =
               Struct.decode_log_addrs(las)

      {_t, {:ok, conn}} = request(t, :g_conn)
      assert %{type: :drm, card_no: 0, connector_id: 32} = Struct.decode_connector_info(conn)
    end

    test "modes, and an ioctl error carries errno", %{t: t} do
      mode = Struct.mode(:initiator, :exclusive)
      assert {t, {:ok, <<>>}} = request(t, {:s_mode, mode})
      assert {t, {:ok, got}} = request(t, :g_mode)
      assert Struct.decode_u32(got) == mode
      assert {_t, {:error, :einval}} = request(t, {:s_mode, 0x99})
    end

    test "claim answers with the updated struct, then a state change", %{t: t} do
      claim =
        Struct.encode_log_addrs(
          num_log_addrs: 1,
          osd_name: "UP",
          log_addr_type: [Struct.log_addr_type(:playback)]
        )

      {t, {:ok, reply}} = request(t, {:s_log, claim})

      assert %{log_addr: [4 | _], log_addr_mask: 0x10, osd_name: "UP"} =
               Struct.decode_log_addrs(reply)

      assert {[{:event, event}], _t} = await(t)
      assert %{event: :state_change, log_addr_mask: 0x10} = Struct.decode_event(event)
    end

    test "transmit fills in the sequence, then the result arrives", %{t: t} do
      bytes = Message.encode!(%Message{from: 4, to: 0, body: :image_view_on})

      {t, {:ok, sent}} = request(t, {:transmit, Struct.encode_msg(msg: bytes)})
      assert %{sequence: 1, msg: ^bytes} = Struct.decode_msg(sent)

      assert {[{:msg, result}], _t} = await(t)
      result = Struct.decode_msg(result)
      assert Struct.classify(result) == :tx_result
      assert Struct.tx_outcome(result.tx_status) == :ok
      assert result.sequence == 1
    end

    test "replies correlate with in-flight requests", %{t: t} do
      {:ok, id1, t} = Transport.send_request(t, :g_phys)
      {:ok, id2, t} = Transport.send_request(t, :g_mode)
      {:ok, id3, t} = Transport.send_request(t, {:s_mode, 0x99})
      assert Enum.uniq([id1, id2, id3]) == [id1, id2, id3]

      {[{:reply, ^id1, {:ok, <<0x00, 0x10>>}}], t} = await(t)
      {[{:reply, ^id2, {:ok, <<0::32>>}}], t} = await(t)
      {[{:reply, ^id3, {:error, :einval}}], t} = await(t)
      assert MapSet.size(t.pending) == 0
    end

    test "frames the helper rejects", %{t: t} do
      # Unknown tag, and a body of the wrong size, are answered with errno.
      Port.command(t.port, <<0x7F, 0x00, 0x09>>)
      assert raw_frame(t) == {:reply, 9, {:error, :enosys}}

      Port.command(t.port, <<0x04, 0x00, 0x0A, 1, 2, 3>>)
      assert raw_frame(t) == {:reply, 10, {:error, :einval}}

      # Too long for the helper's buffer: a protocol error, exit 2.
      Port.command(t.port, <<0x01, 0x00, 0x0B, 0::size(300 * 8)>>)
      assert {[{:exit, 2}], _t} = await(t)
    end

    test "a reply nobody asked for is a protocol error", %{t: t} do
      assert {:ok, [{:protocol_error, <<0x80, 0, 42>>}], _t} =
               Transport.handle_message(t, {t.port, {:data, <<0x80, 0, 42>>}})
    end

    test "close/1 ends the helper", %{t: t} do
      {:os_pid, pid} = Port.info(t.port, :os_pid)
      assert :ok = Transport.close(t)
      assert eventually(fn -> not File.exists?("/proc/#{pid}") end)
      assert Transport.send_request(t, :caps) == {:error, :closed}
      assert :ok = Transport.close(t)
    end

    test "messages that aren't the transport's are :unknown", %{t: t} do
      assert Transport.handle_message(t, {:something, :else}) == :unknown
      assert Transport.handle_message(t, {make_ref(), {:data, <<>>}}) == :unknown
    end
  end

  describe "stubbed helper, lifecycle" do
    @describetag :helper

    test "stdin EOF exits 0 after ready" do
      {out, status} =
        System.cmd("sh", ["-c", ~s(exec "$0" test < /dev/null), test_backend_path()])

      assert status == 0
      assert <<len::16, ready::binary-size(len), _rest::binary>> = out
      assert {:ok, {:ready, _caps}} = Protocol.decode_frame(ready)
    end

    test "an unregistered adapter is gone, then exit 0" do
      {:ok, t} = Transport.open("test-hup", helper: test_backend_path())
      assert {[{:ready, _}], t} = await(t)
      assert {[:gone], t} = await(t)
      assert {[{:exit, 0}], t} = await(t)
      assert Transport.send_request(t, :caps) == {:error, :closed}
    end

    test "a trapping owner's :EXIT after exit_status is bookkeeping" do
      Process.flag(:trap_exit, true)
      {:ok, t} = Transport.open("missing", helper: test_backend_path())
      assert {[{:open_error, :enoent}], t} = await(t)
      assert {[{:exit, 1}], t} = await(t)

      port = t.port
      assert_receive {:EXIT, ^port, _reason}
      assert Transport.handle_message(t, {:EXIT, port, :normal}) == {:ok, [], t}
    end
  end

  defp await(t) do
    port = t.port

    receive do
      {^port, _} = message -> handled(t, message)
    after
      2_000 -> flunk("no message from the helper")
    end
  end

  defp handled(t, message) do
    {:ok, events, t} = Transport.handle_message(t, message)
    {events, t}
  end

  defp request(t, request) do
    {:ok, id, t} = Transport.send_request(t, request)
    {[{:reply, ^id, result}], t} = await(t)
    {t, result}
  end

  defp raw_frame(t) do
    port = t.port
    assert_receive {^port, {:data, data}}, 2_000
    {:ok, frame} = Protocol.decode_frame(data)
    frame
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(20)
        eventually(fun, tries - 1)
    end
  end
end
