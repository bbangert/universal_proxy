defmodule Circuits.CEC.AdapterTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Circuits.CEC.{Adapter, Message, Struct}
  alias Circuits.CEC.Transport.Fake

  @pa 0x1000
  @la 4
  @mask 0x10
  @device "/dev/cec0"

  ## Bring-up

  describe "bring-up" do
    test "becomes the exclusive follower and claims a playback address" do
      %{fake: fake, adapter: adapter} = start(osd_name: "Living Room")
      wait_until(fn -> Adapter.info(adapter).ready? end)

      assert [
               {_, {:s_mode, 0x21}},
               {_, :g_conn},
               {_, :g_log},
               {_, {:s_log, claim}}
             ] = Fake.requests(fake)

      assert %{
               num_log_addrs: 1,
               cec_version: 5,
               vendor_id: 0xFFFFFFFF,
               osd_name: "Living Room",
               flags: 1,
               log_addr_type: [3, 0, 0, 0],
               primary_device_type: [4, 0, 0, 0],
               all_device_types: [0x10, 0, 0, 0]
             } = Struct.decode_log_addrs(claim)

      info = Adapter.info(adapter)
      assert info.follower == :exclusive
      assert info.claim == :claimed
      assert info.caps.driver == "vc4_hdmi"
      assert :connector_info in info.caps.capabilities
      assert info.connector == %{type: :drm, card_no: 0, connector_id: 32}
      assert info.configured? == false
    end

    test "shares the follower role when another process is the exclusive follower" do
      responder = fn
        {:s_mode, 0x21} -> {:error, :ebusy}
        _ -> :default
      end

      %{fake: fake, adapter: adapter} = start(responder: responder)
      wait_until(fn -> Adapter.info(adapter).ready? end)

      assert {:s_mode, 0x11} in requests(fake)
      assert %{follower: :shared, claim: :claimed} = Adapter.info(adapter)
    end

    test "stops when it can't be a follower at all" do
      responder = fn
        {:s_mode, _} -> {:error, :ebusy}
        _ -> :default
      end

      %{adapter: adapter} = start(responder: responder)
      assert_stopped(adapter, {:shutdown, {:s_mode, :ebusy}})
    end

    test "skips the connector query without the capability" do
      caps = Struct.encode_caps(driver: "x", capabilities: [:log_addrs, :transmit])
      %{fake: fake, adapter: adapter} = start(caps: caps)
      wait_until(fn -> Adapter.info(adapter).ready? end)

      refute :g_conn in requests(fake)
      assert Adapter.info(adapter).connector == nil
    end

    test "keeps a claim that already matches" do
      ours =
        Struct.encode_log_addrs(
          log_addr: [@la],
          log_addr_mask: @mask,
          num_log_addrs: 1,
          cec_version: 5,
          vendor_id: 0xFFFFFFFF,
          osd_name: "Pi",
          primary_device_type: [4],
          log_addr_type: [3],
          flags: 1
        )

      %{fake: fake, adapter: adapter} = start(osd_name: "Pi", responder: g_log(ours))
      wait_until(fn -> Adapter.info(adapter).ready? end)

      refute Enum.any?(requests(fake), &match?({:s_log, _}, &1))
      assert Adapter.info(adapter).claim == :kept

      # The mask came from g_log; the physical address from the initial event.
      initial_state(fake, @pa, @mask)
      wait_until(fn -> Adapter.info(adapter).configured? end)
      assert Adapter.info(adapter).log_addrs == [@la]
    end

    test "clears a different claim before making its own" do
      foreign =
        Struct.encode_log_addrs(
          num_log_addrs: 1,
          cec_version: 6,
          osd_name: "Kodi",
          primary_device_type: [4],
          log_addr_type: [3]
        )

      %{fake: fake, adapter: adapter} = start(osd_name: "Pi", responder: g_log(foreign))
      wait_until(fn -> Adapter.info(adapter).claim == :claimed end)

      assert [{:s_log, clear}, {:s_log, claim}] =
               Enum.filter(requests(fake), &match?({:s_log, _}, &1))

      assert Struct.decode_log_addrs(clear).num_log_addrs == 0
      assert %{num_log_addrs: 1, osd_name: "Pi"} = Struct.decode_log_addrs(claim)
    end

    test "a renamed OSD name counts as a different claim" do
      old =
        Struct.encode_log_addrs(
          num_log_addrs: 1,
          cec_version: 5,
          vendor_id: 0xFFFFFFFF,
          osd_name: "Old name",
          primary_device_type: [4],
          log_addr_type: [3]
        )

      %{fake: fake, adapter: adapter} = start(osd_name: "New name", responder: g_log(old))
      wait_until(fn -> Adapter.info(adapter).claim == :claimed end)
      assert length(Enum.filter(requests(fake), &match?({:s_log, _}, &1))) == 2
    end

    test "reports a failed claim and stays up" do
      responder = fn
        {:s_log, _} -> {:error, :ebusy}
        _ -> :default
      end

      %{adapter: adapter} = start(responder: responder)
      wait_until(fn -> Adapter.info(adapter).ready? end)
      assert Adapter.info(adapter).claim == {:error, :ebusy}
    end

    test "reports a failed read of the logical addresses" do
      responder = fn
        :g_log -> {:error, :enotty}
        _ -> :default
      end

      %{adapter: adapter} = start(responder: responder)
      wait_until(fn -> Adapter.info(adapter).ready? end)
      assert Adapter.info(adapter).claim == {:error, :enotty}
    end

    test "truncates the OSD name to 14 bytes on a character boundary" do
      assert Adapter.truncate_osd_name("Living Room Speaker") == "Living Room Sp"
      assert Adapter.truncate_osd_name("Wohnzimmer Küche") == "Wohnzimmer Kü"
      assert Adapter.truncate_osd_name("Short") == "Short"

      %{fake: fake, adapter: adapter} = start(osd_name: "Living Room Speaker")
      wait_until(fn -> Adapter.info(adapter).ready? end)
      [{:s_log, claim}] = Enum.filter(requests(fake), &match?({:s_log, _}, &1))
      assert Struct.decode_log_addrs(claim).osd_name == "Living Room Sp"
    end

    test "stops normally when the device doesn't exist" do
      %{adapter: adapter} = start(ready: {:open_error, :enoent})
      assert_stopped(adapter, :normal)
    end

    test "stops with a shutdown for other open errors" do
      %{adapter: adapter} = start(ready: {:open_error, :eacces})
      assert_stopped(adapter, {:shutdown, {:open_error, :eacces}})
    end

    test "fails to start without a helper" do
      assert {:error, :unsupported} =
               GenServer.start(Adapter, device: @device, transport_opts: [helper: "/nonexistent"])
    end

    test "child_spec is transient and keyed by device" do
      assert %{id: {Adapter, @device}, restart: :transient} = Adapter.child_spec(device: @device)
    end
  end

  ## Addresses and hotplug

  describe "state tracking" do
    test "follows the initial state and configure events, and tells subscribers" do
      %{fake: fake, adapter: adapter} = start()
      :ok = Adapter.subscribe(adapter)
      wait_until(fn -> Adapter.info(adapter).ready? end)

      initial_state(fake, @pa, 0)
      assert_receive {:cec, @device, {:state, %{phys_addr: @pa, configured?: false}}}

      state_change(fake, @pa, @mask)

      assert_receive {:cec, @device,
                      {:state, %{phys_addr: @pa, log_addrs: [@la], configured?: true}}}

      assert %{phys_addr: @pa, log_addrs: [@la], configured?: true} = Adapter.info(adapter)
    end

    test "loses the address on unplug and never re-claims when it comes back" do
      %{fake: fake, adapter: adapter} = configured(receiver: :absent)
      :ok = Adapter.subscribe(adapter)
      active(fake, adapter)

      state_change(fake, 0xFFFF, 0)

      assert_receive {:cec, @device,
                      {:state,
                       %{
                         phys_addr: 0xFFFF,
                         configured?: false,
                         active_source?: false,
                         log_addrs: []
                       }}}

      assert Adapter.info(adapter).receiver == :unknown

      # The kernel re-claims by itself when the physical address returns.
      state_change(fake, @pa, 0)
      state_change(fake, @pa, @mask)
      assert_receive {:cec, @device, {:state, %{configured?: true}}}

      assert length(Enum.filter(requests(fake), &match?({:s_log, _}, &1))) == 1
      # ...and the receiver is polled again.
      assert {_seq, %Message{to: 5, body: :poll}} = nth_tx(fake, 3)
    end

    test "lost messages are counted, reported and followed by a resync" do
      %{fake: fake, adapter: adapter} = configured(phys_addr: 0x2000)
      :ok = Adapter.subscribe(adapter)
      before = length(Fake.requests(fake))

      :ok = Fake.inject(fake, {:event, Struct.encode_event(event: :lost_msgs, lost_msgs: 3)})

      assert_receive {:cec, @device, {:lost_msgs, 3}}
      wait_until(fn -> Adapter.info(adapter).phys_addr == 0x2000 end)

      assert [:g_phys, :g_log] = fake |> requests() |> Enum.drop(before) |> Enum.take(2)
      assert Adapter.info(adapter).counters.lost_msgs == 3
    end

    test "dropped events trigger a resync" do
      %{fake: fake, adapter: adapter} = configured()
      before = length(Fake.requests(fake))

      state_change(fake, @pa, @mask, [:dropped_events])

      wait_until(fn -> Adapter.info(adapter).counters.dropped_events == 1 end)
      wait_until(fn -> :g_phys in Enum.drop(requests(fake), before) end)
    end

    test "other kernel events are ignored" do
      %{fake: fake, adapter: adapter} = configured()
      :ok = Fake.inject(fake, {:event, Struct.encode_event(event: :pin_hpd_low)})
      assert Adapter.info(adapter).configured?
    end
  end

  ## Transmit

  describe "transmit and request" do
    test "transmit sends from our address and returns the result" do
      %{fake: fake, adapter: adapter} = configured()

      task = Task.async(fn -> Adapter.transmit(adapter, 5, {:user_control_pressed, :mute}) end)
      {seq, %Message{from: @la, to: 5}, struct} = nth_tx_struct(fake, 2)
      assert %{reply: 0, timeout: 0} = struct

      complete(fake, seq, tx_status: 0x01)
      assert Task.await(task) == :ok
    end

    test "request waits for the reply and decodes it" do
      %{fake: fake, adapter: adapter} = configured()

      task = Task.async(fn -> Adapter.give_power_status(adapter, 0) end)
      {seq, %Message{to: 0, body: :give_device_power_status}, struct} = nth_tx_struct(fake, 2)
      assert %{reply: 0x90, timeout: 1000} = struct

      reply(fake, seq, <<0x04, 0x90, 0x01>>)
      assert Task.await(task) == {:ok, :standby}
    end

    test "give_audio_status decodes volume and mute" do
      %{fake: fake, adapter: adapter} = configured(receiver: :present)

      task = Task.async(fn -> Adapter.give_audio_status(adapter) end)
      {seq, %Message{to: 5, body: :give_audio_status}} = nth_tx(fake, 2)
      reply(fake, seq, <<0x54, 0x7A, 0x80 + 35>>)
      assert Task.await(task) == {:ok, %{volume: 35, muted: true}}
    end

    test "an unexpected reply body is reported" do
      %{fake: fake, adapter: adapter} = configured()

      task = Task.async(fn -> Adapter.give_power_status(adapter, 0) end)
      {seq, _msg} = nth_tx(fake, 2)
      reply(fake, seq, <<0x04, 0x90>>)
      assert Task.await(task) == {:error, :unexpected_reply}

      task = Task.async(fn -> Adapter.give_audio_status(adapter, 0) end)
      {seq, _msg} = nth_tx(fake, 3)
      reply(fake, seq, <<0x04, 0x7A>>)
      assert Task.await(task) == {:error, :unexpected_reply}
    end

    test "a tx-only result while a reply is due keeps waiting" do
      %{fake: fake, adapter: adapter} = configured()

      task = Task.async(fn -> Adapter.give_power_status(adapter, 0) end)
      {seq, _msg} = nth_tx(fake, 2)
      complete(fake, seq, tx_status: 0x01)
      refute Task.yield(task, 50)

      reply(fake, seq, <<0x04, 0x90, 0x00>>)
      assert Task.await(task) == {:ok, :on}
    end

    test "a result that arrives before the ioctl reply is kept until it does" do
      responder = fn
        {:transmit, _} -> :noreply
        _ -> :default
      end

      %{fake: fake, adapter: adapter} = configured(responder: responder, receiver: :pending)
      task = Task.async(fn -> Adapter.give_power_status(adapter, 0) end)
      {id, {:transmit, body}} = wait_until(fn -> last_transmit(fake, 2) end)

      reply(fake, 77, <<0x04, 0x90, 0x00>>)
      refute Task.yield(task, 50)

      <<head::binary-24, _::binary-4, rest::binary>> = body
      Fake.reply(fake, id, {:ok, <<head::binary, 77::little-32, rest::binary>>})
      assert Task.await(task) == {:ok, :on}
    end

    test "transmit status bits map to typed errors" do
      %{fake: fake, adapter: adapter} = configured()

      for {status, error} <- [
            {0x24, :nack},
            {0x22, :arb_lost},
            {0x28, :low_drive},
            {0x30, :error},
            {0x20, :max_retries},
            {0x60, :aborted},
            {0xA0, :timeout}
          ] do
        n = length(transmits(fake)) + 1
        task = Task.async(fn -> Adapter.transmit(adapter, 0, :image_view_on) end)
        {seq, _msg} = nth_tx(fake, n)
        complete(fake, seq, tx_status: status)
        assert Task.await(task) == {:error, error}, "tx_status #{status}"
      end

      assert Adapter.info(adapter).counters.tx_errors == 7
    end

    test "reply status bits map to typed errors" do
      %{fake: fake, adapter: adapter} = configured()

      task = Task.async(fn -> Adapter.give_power_status(adapter, 0) end)
      {seq, _msg} = nth_tx(fake, 2)
      complete(fake, seq, msg: <<0x04, 0x00, 0x8F, 0x00>>, tx_status: 0x01, rx_status: 0x05)
      assert Task.await(task) == {:error, :feature_abort}

      task = Task.async(fn -> Adapter.give_power_status(adapter, 0) end)
      {seq, _msg} = nth_tx(fake, 3)
      complete(fake, seq, rx_status: 0x02)
      assert Task.await(task) == {:error, :timeout}

      task = Task.async(fn -> Adapter.give_power_status(adapter, 0) end)
      {seq, _msg} = nth_tx(fake, 4)
      complete(fake, seq, rx_status: 0x08)
      assert Task.await(task) == {:error, :aborted}
    end

    test "ioctl errors map to typed errors" do
      for {errno, error} <- [
            {:enonet, :not_configured},
            {:eperm, :not_configured},
            {:ebusy, :busy},
            {:einval, :einval},
            {:enodev, :enodev}
          ] do
        responder = fn
          {:transmit, _} -> {:error, errno}
          _ -> :default
        end

        %{adapter: adapter} = configured(responder: responder, receiver: :pending)
        assert Adapter.transmit(adapter, 0, :image_view_on) == {:error, error}
        stop_supervised!({Adapter, @device})
        stop_supervised!(Fake)
      end
    end

    test "a transmit the kernel completes in the ioctl (poll of our own address)" do
      responder = fn
        {:transmit, body} ->
          msg = Struct.decode_msg(body)
          {:ok, Struct.encode_msg(%{msg | sequence: 9, tx_status: 0x24, tx_nack_cnt: 1})}

        _ ->
          :default
      end

      %{adapter: adapter} = configured(responder: responder, receiver: :pending)
      assert Adapter.poll(adapter, @la) == {:error, :nack}
    end

    test "the safety deadline fails a transmit the kernel never reports" do
      %{fake: fake, adapter: adapter} = configured(tx_deadline_ms: 30, receiver: :pending)

      assert Adapter.transmit(adapter, 0, :image_view_on) == {:error, :timeout}
      assert Adapter.info(adapter).counters.deadline_expired >= 1

      # A late result for it is harmless.
      {seq, _msg} = nth_tx(fake, 2)
      complete(fake, seq, tx_status: 0x01)
      assert Adapter.info(adapter).configured?
    end

    test "unconfigured, only a poll or Image/Text View On to the TV go out, from 15" do
      %{fake: fake, adapter: adapter} = start()
      wait_until(fn -> Adapter.info(adapter).ready? end)

      assert Adapter.standby(adapter, 0) == {:error, :not_configured}
      assert Adapter.transmit(adapter, 5, :image_view_on) == {:error, :not_configured}
      assert Adapter.active_source(adapter) == {:error, :not_configured}

      task = Task.async(fn -> Adapter.image_view_on(adapter) end)
      assert {seq, %Message{from: 15, to: 0, body: :image_view_on}} = nth_tx(fake, 1)
      complete(fake, seq, tx_status: 0x01)
      assert Task.await(task) == :ok
    end

    test "the reply opcode may be a byte" do
      %{fake: fake, adapter: adapter} = configured()

      task = Task.async(fn -> Adapter.request(adapter, 0, :give_device_power_status, 0x90) end)
      {seq, _msg, %{reply: 0x90}} = nth_tx_struct(fake, 2)
      reply(fake, seq, <<0x04, 0x90, 0x00>>)
      assert {:ok, %Message{body: {:report_power_status, :on}}} = Task.await(task)

      assert {:error, {:invalid_message, 0x100}} =
               Adapter.request(adapter, 0, :give_device_power_status, 0x100)
    end

    test "a reply can't be requested for a broadcast or a poll" do
      %{adapter: adapter} = configured()

      assert Adapter.request(adapter, :broadcast, :request_active_source, :active_source) ==
               {:error, :einval}

      assert Adapter.request(adapter, 0, :poll, :report_power_status) == {:error, :einval}
    end

    test "bad messages and targets are refused" do
      %{adapter: adapter} = configured()

      assert {:error, {:invalid_message, _}} = Adapter.transmit(adapter, 0, {:active_source, -1})
      assert {:error, {:invalid_message, _}} = Adapter.transmit(adapter, 99, :standby)

      assert {:error, {:invalid_message, :nowhere}} =
               Adapter.transmit(adapter, :nowhere, :standby)

      assert {:error, {:invalid_message, "5"}} = Adapter.transmit(adapter, "5", :standby)

      assert {:error, {:invalid_message, :bogus}} =
               Adapter.request(adapter, 0, :give_device_power_status, :bogus)

      assert {:error, {:invalid_message, :poll}} =
               Adapter.request(adapter, 0, :give_device_power_status, :poll)
    end

    test "named targets resolve to logical addresses" do
      %{fake: fake, adapter: adapter} = configured()

      task = Task.async(fn -> Adapter.standby(adapter, :tv) end)
      {seq, %Message{to: 0, body: :standby}} = nth_tx(fake, 2)
      complete(fake, seq, tx_status: 0x01)
      assert Task.await(task) == :ok
    end

    test "user_control releases only after the press was acknowledged" do
      %{fake: fake, adapter: adapter} = configured()

      task = Task.async(fn -> Adapter.user_control(adapter, 5, :volume_up) end)
      {seq, %Message{to: 5, body: {:user_control_pressed, :volume_up}}} = nth_tx(fake, 2)
      assert length(transmits(fake)) == 2

      complete(fake, seq, tx_status: 0x01)
      {seq, %Message{to: 5, body: :user_control_released}} = nth_tx(fake, 3)
      complete(fake, seq, tx_status: 0x01)
      assert Task.await(task) == :ok

      task = Task.async(fn -> Adapter.user_control(adapter, 5, :mute) end)
      {seq, _msg} = nth_tx(fake, 4)
      complete(fake, seq, tx_status: 0x24)
      assert Task.await(task) == {:error, :nack}
      assert length(transmits(fake)) == 4
    end

    test "active_source records that we are the active source" do
      %{fake: fake, adapter: adapter} = configured()

      task = Task.async(fn -> Adapter.active_source(adapter) end)
      {seq, %Message{to: 15, body: {:active_source, @pa}}} = nth_tx(fake, 2)
      complete(fake, seq, tx_status: 0x01)
      assert Task.await(task) == :ok
      assert Adapter.info(adapter).active_source?

      task = Task.async(fn -> Adapter.standby(adapter, :broadcast) end)
      {seq, %Message{to: 15, body: :standby}} = nth_tx(fake, 3)
      complete(fake, seq, tx_status: 0x01)
      assert Task.await(task) == :ok
      refute Adapter.info(adapter).active_source?
    end

    test "subscribers see replies to our requests as messages" do
      %{fake: fake, adapter: adapter} = configured()
      :ok = Adapter.subscribe(adapter)

      task = Task.async(fn -> Adapter.give_power_status(adapter, 0) end)
      {seq, _msg} = nth_tx(fake, 2)
      reply(fake, seq, <<0x04, 0x90, 0x00>>)
      assert Task.await(task) == {:ok, :on}

      assert_receive {:cec, @device,
                      {:message, %Message{from: 0, to: 4, body: {:report_power_status, :on}}}}
    end
  end

  ## Follower duties

  describe "follower" do
    test "answers Give Device Power Status to the initiator" do
      %{fake: fake, adapter: adapter} = configured()
      receive_msg(fake, <<0x04, 0x8F>>)

      assert {seq, %Message{from: @la, to: 0, body: {:report_power_status, :on}}} =
               nth_tx(fake, 2)

      complete(fake, seq, tx_status: 0x01)
      assert Adapter.info(adapter).counters.tx_errors == 0
    end

    test "reports the configured power status" do
      %{fake: fake} = configured(power_status: :standby)
      receive_msg(fake, <<0x54, 0x8F>>)
      assert {_seq, %Message{to: 5, body: {:report_power_status, :standby}}} = nth_tx(fake, 2)
    end

    test "Feature-Aborts an unknown directed opcode" do
      %{fake: fake} = configured()
      receive_msg(fake, <<0x04, 0x89, 0x01, 0x02>>)

      assert {_seq,
              %Message{to: 0, body: {:feature_abort, :vendor_command, :unrecognized_opcode}}} =
               nth_tx(fake, 2)
    end

    test "Feature-Aborts an unsupported request" do
      %{fake: fake} = configured()
      receive_msg(fake, <<0x04, 0x70, 0x10, 0x00>>)

      assert {_seq,
              %Message{body: {:feature_abort, :system_audio_mode_request, :unrecognized_opcode}}} =
               nth_tx(fake, 2)
    end

    test "Feature-Aborts a known opcode with missing operands as an invalid operand" do
      %{fake: fake} = configured()
      receive_msg(fake, <<0x04, 0x8D>>)

      assert {_seq, %Message{body: {:feature_abort, :menu_request, :invalid_operand}}} =
               nth_tx(fake, 2)
    end

    test "never answers broadcasts, Feature Aborts, reports, Unregistered or kernel-handled opcodes" do
      %{fake: fake} = configured()

      for bytes <- [
            # broadcast Give Device Power Status / unknown broadcast
            <<0x0F, 0x8F>>,
            <<0x0F, 0x89, 0x01>>,
            # Feature Abort, also with bad operands
            <<0x04, 0x00, 0x8F, 0x00>>,
            <<0x04, 0x00>>,
            # from Unregistered
            <<0xF4, 0x8D, 0x00>>,
            <<0xF4, 0x89>>,
            # the kernel answers these
            <<0x04, 0x9F>>,
            <<0x04, 0x83>>,
            <<0x04, 0x46>>,
            <<0x04, 0x8C>>,
            <<0x04, 0xFF>>,
            <<0x04, 0xA5>>,
            # reports and notices
            <<0x54, 0x7A, 0x20>>,
            <<0x54, 0x72, 0x01>>,
            <<0x04, 0x90, 0x00>>,
            <<0x04, 0x9E, 0x05>>,
            <<0x04, 0x47, ?T, ?V>>,
            <<0x0F, 0x84, 0x00, 0x00, 0x00>>,
            <<0x04, 0x85>>,
            # a poll, and a message for another device
            <<0x04>>,
            <<0x08, 0x8F>>
          ] do
        receive_msg(fake, bytes)
      end

      # A message that does get an answer, to know the ones before were handled.
      receive_msg(fake, <<0x04, 0x8F>>)
      assert {_seq, %Message{body: {:report_power_status, :on}}} = nth_tx(fake, 2)
      assert length(transmits(fake)) == 2
    end

    test "answers Request Active Source only while active" do
      %{fake: fake, adapter: adapter} = configured()

      receive_msg(fake, <<0x0F, 0x85>>)
      active(fake, adapter)
      receive_msg(fake, <<0x0F, 0x85>>)

      assert {_seq, %Message{from: @la, to: 15, body: {:active_source, @pa}}} = nth_tx(fake, 3)
      assert length(transmits(fake)) == 3
    end

    test "Set Stream Path to our address makes us the active source" do
      %{fake: fake, adapter: adapter} = configured()
      receive_msg(fake, <<0x0F, 0x86, 0x10, 0x00>>)

      assert {_seq, %Message{to: 15, body: {:active_source, @pa}}} = nth_tx(fake, 2)
      assert Adapter.info(adapter).active_source?
    end

    test "another source or route ends being the active source" do
      %{fake: fake, adapter: adapter} = configured()

      for bytes <- [
            <<0x8F, 0x82, 0x20, 0x00>>,
            <<0x0F, 0x86, 0x20, 0x00>>,
            <<0x0F, 0x80, 0x10, 0x00, 0x20, 0x00>>,
            <<0x0F, 0x81, 0x20, 0x00>>
          ] do
        active(fake, adapter)
        receive_msg(fake, bytes)
        wait_until(fn -> not Adapter.info(adapter).active_source? end)
      end

      # Our own address in those messages changes nothing.
      active(fake, adapter)
      receive_msg(fake, <<0x0F, 0x80, 0x20, 0x00, 0x10, 0x00>>)
      receive_msg(fake, <<0x0F, 0x81, 0x10, 0x00>>)
      assert Adapter.info(adapter).active_source?
    end

    test "answers Menu Request with Menu Status deactivated" do
      %{fake: fake} = configured()
      receive_msg(fake, <<0x04, 0x8D, 0x02>>)
      assert {_seq, %Message{to: 0, body: {:menu_status, :deactivated}}} = nth_tx(fake, 2)
    end

    test "Standby ends being the active source without an answer" do
      %{fake: fake, adapter: adapter} = configured()
      active(fake, adapter)

      receive_msg(fake, <<0x0F, 0x36>>)
      wait_until(fn -> not Adapter.info(adapter).active_source? end)
      assert Adapter.info(adapter).last_standby == 0
      assert length(transmits(fake)) == 2
    end

    test "deck and remote-control messages need a subscriber to handle them" do
      %{fake: fake, adapter: adapter} = configured()

      receive_msg(fake, <<0x04, 0x44, 0x44>>)

      assert {_seq, %Message{body: {:feature_abort, :user_control_pressed, :unrecognized_opcode}}} =
               nth_tx(fake, 2)

      parent = self()

      subscriber =
        spawn(fn ->
          :ok = Adapter.subscribe(adapter, handle: [:user_control_pressed, :play])
          send(parent, :subscribed)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :subscribed
      :ok = Adapter.subscribe(adapter)

      receive_msg(fake, <<0x04, 0x44, 0x46>>)
      receive_msg(fake, <<0x04, 0x45>>)
      receive_msg(fake, <<0x04, 0x41, 0x24>>)

      assert_receive {:cec, @device, {:message, %Message{body: {:play, :play_forward}}}}
      assert length(transmits(fake)) == 2

      # Deck Control isn't handled by anyone.
      receive_msg(fake, <<0x04, 0x42, 0x03>>)
      assert {_seq, %Message{body: {:feature_abort, :deck_control, _}}} = nth_tx(fake, 3)

      # Once the handler is gone the adapter aborts again.
      ref = Process.monitor(subscriber)
      send(subscriber, :stop)
      assert_receive {:DOWN, ^ref, :process, _, _}
      wait_until(fn -> map_size(:sys.get_state(adapter).subs) == 1 end)
      receive_msg(fake, <<0x04, 0x45>>)

      assert {_seq, %Message{body: {:feature_abort, :user_control_released, _}}} =
               nth_tx(fake, 4)
    end

    test "subscribe rejects opcodes it can't hand over" do
      %{adapter: adapter} = start()
      assert_raise ArgumentError, fn -> Adapter.subscribe(adapter, handle: [:standby]) end
    end

    test "subscribers get every received message until they unsubscribe" do
      %{fake: fake, adapter: adapter} = configured()
      :ok = Adapter.subscribe(adapter)
      :ok = Adapter.subscribe(adapter)

      receive_msg(fake, <<0x0F, 0x36>>)
      assert_receive {:cec, @device, {:message, %Message{from: 0, to: 15, body: :standby}}}
      refute_receive {:cec, @device, {:message, _}}, 20

      :ok = Adapter.unsubscribe(adapter)
      :ok = Adapter.unsubscribe(adapter)
      receive_msg(fake, <<0x0F, 0x36>>)
      refute_receive {:cec, @device, {:message, _}}, 50
    end

    test "follower replies that fail are only logged" do
      %{fake: fake, adapter: adapter} = configured()
      receive_msg(fake, <<0x04, 0x8F>>)
      {seq, _msg} = nth_tx(fake, 2)
      complete(fake, seq, tx_status: 0x24)
      wait_until(fn -> Adapter.info(adapter).counters.tx_errors == 1 end)
    end
  end

  ## One Touch Play

  describe "one_touch_play" do
    test "configured: Image View On, then Active Source" do
      %{fake: fake, adapter: adapter} = configured()

      task = Task.async(fn -> Adapter.one_touch_play(adapter) end)
      {seq, %Message{from: @la, to: 0, body: :image_view_on}} = nth_tx(fake, 2)
      complete(fake, seq, tx_status: 0x01)
      {seq, %Message{to: 15, body: {:active_source, @pa}}} = nth_tx(fake, 3)
      complete(fake, seq, tx_status: 0x01)

      assert Task.await(task) == :ok
      assert Adapter.info(adapter).active_source?
    end

    test "Active Source still goes out when no TV acknowledges Image View On" do
      %{fake: fake, adapter: adapter} = configured()

      task = Task.async(fn -> Adapter.one_touch_play(adapter) end)
      {seq, _ivo} = nth_tx(fake, 2)
      complete(fake, seq, tx_status: 0x24)
      {seq, %Message{body: {:active_source, @pa}}} = nth_tx(fake, 3)
      complete(fake, seq, tx_status: 0x01)
      assert Task.await(task) == :ok
    end

    test "fails when Active Source fails" do
      %{fake: fake, adapter: adapter} = configured()

      task = Task.async(fn -> Adapter.one_touch_play(adapter) end)
      {seq, _ivo} = nth_tx(fake, 2)
      complete(fake, seq, tx_status: 0x01)
      {seq, _as} = nth_tx(fake, 3)
      complete(fake, seq, tx_status: 0x30)
      assert Task.await(task) == {:error, :error}
      refute Adapter.info(adapter).active_source?
    end

    test "without a physical address: Image View On from 15, then Active Source once configured" do
      %{fake: fake, adapter: adapter} = start()
      wait_until(fn -> Adapter.info(adapter).ready? end)
      initial_state(fake, 0xFFFF, 0)

      task = Task.async(fn -> Adapter.one_touch_play(adapter, wait_ms: 1_000) end)
      {seq, %Message{from: 15, to: 0, body: :image_view_on}} = nth_tx(fake, 1)
      complete(fake, seq, tx_status: 0x01)
      refute Task.yield(task, 30)

      # The TV wakes, raises hotplug, and the kernel claims our address.
      state_change(fake, @pa, 0)
      state_change(fake, @pa, @mask)

      {seq, %Message{from: @la, body: {:active_source, @pa}}} =
        wait_until(fn -> find_tx(fake, &match?(%Message{body: {:active_source, _}}, &1)) end)

      complete(fake, seq, tx_status: 0x01)
      assert Task.await(task) == :ok
    end

    test "without a physical address it gives up after the wait" do
      %{fake: fake, adapter: adapter} = start()
      wait_until(fn -> Adapter.info(adapter).ready? end)
      initial_state(fake, 0xFFFF, 0)

      task = Task.async(fn -> Adapter.one_touch_play(adapter, wait_ms: 50) end)
      {seq, _ivo} = nth_tx(fake, 1)
      assert Task.await(task) == {:error, :not_configured}

      # The Image View On result after the run ended changes nothing.
      complete(fake, seq, tx_status: 0x24)
      assert Adapter.info(adapter).ready?
      assert length(transmits(fake)) == 1
    end

    test "while configuring it waits, then sends both" do
      %{fake: fake, adapter: adapter} = start()
      wait_until(fn -> Adapter.info(adapter).ready? end)
      initial_state(fake, @pa, 0)

      task = Task.async(fn -> Adapter.one_touch_play(adapter, wait_ms: 1_000) end)
      refute Task.yield(task, 30)
      assert transmits(fake) == []

      state_change(fake, @pa, @mask)

      {seq, %Message{from: @la, body: :image_view_on}} =
        wait_until(fn -> find_tx(fake, &match?(%Message{body: :image_view_on}, &1)) end)

      complete(fake, seq, tx_status: 0x01)

      {seq, _as} =
        wait_until(fn -> find_tx(fake, &match?(%Message{body: {:active_source, _}}, &1)) end)

      complete(fake, seq, tx_status: 0x01)
      assert Task.await(task) == :ok
    end

    test "System Audio Mode Request is opt-in" do
      %{fake: fake, adapter: adapter} = configured(receiver: :present)

      task = Task.async(fn -> Adapter.one_touch_play(adapter, system_audio_mode: true) end)
      {seq, _ivo} = nth_tx(fake, 2)
      complete(fake, seq, tx_status: 0x01)
      {seq, _as} = nth_tx(fake, 3)
      complete(fake, seq, tx_status: 0x01)

      {seq, %Message{to: 5, body: {:system_audio_mode_request, @pa}}, struct} =
        nth_tx_struct(fake, 4)

      assert struct.reply == 0x72
      complete(fake, seq, msg: <<0x5F, 0x72, 0x01>>, tx_status: 0x01, rx_status: 0x01)
      assert Task.await(task) == :ok

      # Off by default.
      task = Task.async(fn -> Adapter.one_touch_play(adapter) end)
      {seq, _ivo} = nth_tx(fake, 5)
      complete(fake, seq, tx_status: 0x01)
      {seq, _as} = nth_tx(fake, 6)
      complete(fake, seq, tx_status: 0x01)
      assert Task.await(task) == :ok
      assert length(transmits(fake)) == 6
    end

    test "the adapter option enables it, a failed SAM request doesn't fail the call" do
      %{fake: fake, adapter: adapter} = configured(receiver: :present, system_audio_mode: true)

      task = Task.async(fn -> Adapter.one_touch_play(adapter) end)
      {seq, _ivo} = nth_tx(fake, 2)
      complete(fake, seq, tx_status: 0x01)
      {seq, _as} = nth_tx(fake, 3)
      complete(fake, seq, tx_status: 0x01)
      {seq, %Message{body: {:system_audio_mode_request, _}}} = nth_tx(fake, 4)
      complete(fake, seq, tx_status: 0x24)
      assert Task.await(task) == :ok
    end

    test "no System Audio Mode Request without a receiver" do
      %{fake: fake, adapter: adapter} = configured(receiver: :absent, system_audio_mode: true)

      task = Task.async(fn -> Adapter.one_touch_play(adapter) end)
      {seq, _ivo} = nth_tx(fake, 2)
      complete(fake, seq, tx_status: 0x01)
      {seq, _as} = nth_tx(fake, 3)
      complete(fake, seq, tx_status: 0x01)
      assert Task.await(task) == :ok
      assert length(transmits(fake)) == 3
    end

    test "concurrent calls share one run" do
      %{fake: fake, adapter: adapter} = configured()

      t1 = Task.async(fn -> Adapter.one_touch_play(adapter) end)
      {seq, _ivo} = nth_tx(fake, 2)
      t2 = Task.async(fn -> Adapter.one_touch_play(adapter) end)
      wait_until(fn -> length(:sys.get_state(adapter).otp.waiters) == 2 end)

      complete(fake, seq, tx_status: 0x01)
      {seq, _as} = nth_tx(fake, 3)
      complete(fake, seq, tx_status: 0x01)

      assert Task.await(t1) == :ok
      assert Task.await(t2) == :ok
      assert length(transmits(fake)) == 3
    end

    test "transmit errors don't stall the run" do
      responder = fn
        {:transmit, _} -> {:error, :ebusy}
        _ -> :default
      end

      %{adapter: adapter} = configured(responder: responder, receiver: :pending)
      assert Adapter.one_touch_play(adapter) == {:error, :busy}
    end
  end

  ## Receiver

  describe "receiver" do
    test "is polled after configure; absent sends :receiver calls to the TV" do
      %{fake: fake, adapter: adapter} = configured(receiver: :absent)

      assert %{receiver: :absent, receiver_target: 0} = Adapter.info(adapter)
      assert Adapter.receiver(adapter) == 0

      task = Task.async(fn -> Adapter.give_power_status(adapter, :receiver) end)
      {seq, %Message{to: 0}} = nth_tx(fake, 2)
      reply(fake, seq, <<0x04, 0x90, 0x00>>)
      assert Task.await(task) == {:ok, :on}
    end

    test "present: :receiver calls go to it" do
      %{fake: fake, adapter: adapter} = configured(receiver: :present)
      assert %{receiver: :present, receiver_target: 5} = Adapter.info(adapter)

      task = Task.async(fn -> Adapter.user_control(adapter, :receiver, :volume_down) end)
      {seq, %Message{to: 5, body: {:user_control_pressed, :volume_down}}} = nth_tx(fake, 2)
      complete(fake, seq, tx_status: 0x01)
      {seq, %Message{to: 5, body: :user_control_released}} = nth_tx(fake, 3)
      complete(fake, seq, tx_status: 0x01)
      assert Task.await(task) == :ok
    end

    test "a :receiver call NACKed by the receiver falls back to the TV" do
      %{fake: fake, adapter: adapter} = configured(receiver: :present)
      :ok = Adapter.subscribe(adapter)

      task = Task.async(fn -> Adapter.give_power_status(adapter, :receiver) end)
      {seq, %Message{to: 5}} = nth_tx(fake, 2)
      complete(fake, seq, tx_status: 0x24)

      {seq, %Message{to: 0, body: :give_device_power_status}} = nth_tx(fake, 3)
      reply(fake, seq, <<0x04, 0x90, 0x01>>)
      assert Task.await(task) == {:ok, :standby}

      assert_receive {:cec, @device, {:state, %{receiver: :absent}}}
      assert Adapter.receiver(adapter) == 0
    end

    test "the TV's NACK after a fallback is the result" do
      %{fake: fake, adapter: adapter} = configured(receiver: :pending)

      task = Task.async(fn -> Adapter.standby(adapter, :receiver) end)
      {seq, %Message{to: 5, body: :standby}} = nth_tx(fake, 2)
      complete(fake, seq, tx_status: 0x24)
      {seq, %Message{to: 0, body: :standby}} = nth_tx(fake, 3)
      complete(fake, seq, tx_status: 0x24)
      assert Task.await(task) == {:error, :nack}
    end

    test "a :receiver press that falls back releases at the TV" do
      %{fake: fake, adapter: adapter} = configured(receiver: :pending)

      task = Task.async(fn -> Adapter.user_control(adapter, :receiver, :power_on_function) end)
      {seq, %Message{to: 5}} = nth_tx(fake, 2)
      complete(fake, seq, tx_status: 0x24)
      {seq, %Message{to: 0, body: {:user_control_pressed, :power_on_function}}} = nth_tx(fake, 3)
      complete(fake, seq, tx_status: 0x01)
      {seq, %Message{to: 0, body: :user_control_released}} = nth_tx(fake, 4)
      complete(fake, seq, tx_status: 0x01)
      assert Task.await(task) == :ok
    end

    test "an answer from the receiver marks it present" do
      %{fake: fake, adapter: adapter} = configured(receiver: :pending)
      assert Adapter.info(adapter).receiver == :unknown

      task = Task.async(fn -> Adapter.give_audio_status(adapter) end)
      {seq, %Message{to: 5}} = nth_tx(fake, 2)
      complete(fake, seq, msg: <<0x54, 0x00, 0x71, 0x00>>, tx_status: 0x01, rx_status: 0x05)
      assert Task.await(task) == {:error, :feature_abort}
      assert Adapter.info(adapter).receiver == :present
    end

    test "without a receiver address :receiver means the TV and nothing is polled" do
      %{fake: fake, adapter: adapter} = configured(receiver_la: nil, receiver: :none)
      assert Adapter.receiver(adapter) == 0

      task = Task.async(fn -> Adapter.standby(adapter, :receiver) end)
      {seq, %Message{to: 0}} = nth_tx(fake, 1)
      complete(fake, seq, tx_status: 0x24)
      assert Task.await(task) == {:error, :nack}
    end
  end

  ## Lifecycle

  describe "lifecycle" do
    test "gone: subscribers are told, waiting callers fail, the adapter stops normally" do
      %{fake: fake, adapter: adapter} = configured()
      :ok = Adapter.subscribe(adapter)
      ref = Process.monitor(adapter)

      task = Task.async(fn -> Adapter.give_power_status(adapter, 0) end)
      _ = nth_tx(fake, 2)
      :ok = Fake.inject(fake, :gone)

      assert_receive {:cec, @device, :gone}
      assert Task.await(task) == {:error, :closed}
      assert_receive {:DOWN, ^ref, :process, ^adapter, :normal}
      assert Fake.closed?(fake)
    end

    test "a helper exit is a crash, and pending One Touch Play fails" do
      %{fake: fake, adapter: adapter} = configured()
      ref = Process.monitor(adapter)

      task = Task.async(fn -> Adapter.one_touch_play(adapter) end)
      _ = nth_tx(fake, 2)
      :ok = Fake.inject(fake, {:exit, 1})

      assert Task.await(task) == {:error, :closed}
      assert_receive {:DOWN, ^ref, :process, ^adapter, {:port_exit, 1}}
    end

    test "a transient supervisor restarts it after a crash, and the claim is kept" do
      {:ok, fake} = Fake.start_link()
      opts = [device: @device, transport: Fake, transport_opts: [fake: fake]]
      {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
      {:ok, adapter} = DynamicSupervisor.start_child(sup, {Adapter, opts})
      wait_until(fn -> Adapter.info(adapter).claim == :claimed end)

      :ok = Fake.inject(fake, {:exit, 1})
      wait_until(fn -> Fake.owner(fake) not in [nil, adapter] end)
      [restarted] = for {_, pid, _, _} <- DynamicSupervisor.which_children(sup), do: pid
      wait_until(fn -> Adapter.info(restarted).ready? end)

      # The fake kept the claim, as the kernel does.
      assert Adapter.info(restarted).claim == :kept
      assert length(Enum.filter(requests(fake), &match?({:s_log, _}, &1))) == 1
    end

    test "a normal stop closes the transport" do
      %{fake: fake, adapter: adapter} = configured()
      GenServer.stop(adapter)
      assert Fake.closed?(fake)
    end

    test "malformed frames are counted" do
      %{fake: fake, adapter: adapter} = configured()
      :ok = Fake.inject(fake, {:protocol_error, <<1, 2, 3>>})
      wait_until(fn -> Adapter.info(adapter).counters.protocol_errors == 1 end)
    end

    test "stray messages are ignored" do
      %{adapter: adapter} = configured()
      send(adapter, :hello)
      send(adapter, {:tx_deadline, make_ref()})
      send(adapter, {:otp_timeout, make_ref()})
      assert Adapter.info(adapter).configured?
    end

    test "format_status is a summary without buffers" do
      %{adapter: adapter} = configured()
      {:status, _pid, _mod, items} = :sys.get_status(adapter)
      status = items |> List.last() |> Keyword.get_values(:data) |> List.flatten() |> Map.new()
      state = status[~c"State"]

      assert %{device: @device, configured?: true, pending_transmits: _} = state
      refute Map.has_key?(state, :transport)
      refute Map.has_key?(state, :orphans)
    end
  end

  ## Helpers

  defp start(opts \\ []) do
    {fake_opts, opts} = Keyword.split(opts, [:responder, :ready, :caps, :phys_addr])
    fake = start_supervised!({Fake, fake_opts})

    adapter =
      start_supervised!(
        {Adapter, [device: @device, transport: Fake, transport_opts: [fake: fake]] ++ opts},
        restart: :temporary
      )

    %{fake: fake, adapter: adapter}
  end

  # A started adapter at @pa with logical address @la. `:receiver` settles
  # the receiver poll: :absent (NACK, default), :present, :pending (left
  # unanswered) or :none (no poll expected).
  defp configured(opts \\ []) do
    {receiver, opts} = Keyword.pop(opts, :receiver, :absent)
    %{fake: fake, adapter: adapter} = ctx = start(opts)
    wait_until(fn -> Adapter.info(adapter).ready? end)
    initial_state(fake, @pa, @mask)
    wait_until(fn -> Adapter.info(adapter).configured? end)

    case receiver do
      :none ->
        :ok

      :pending ->
        {_seq, %Message{body: :poll}} = nth_tx(fake, 1)

      :present ->
        {seq, %Message{to: 5, body: :poll}} = nth_tx(fake, 1)
        complete(fake, seq, tx_status: 0x01)
        wait_until(fn -> Adapter.info(adapter).receiver == :present end)

      :absent ->
        {seq, %Message{to: 5, body: :poll}} = nth_tx(fake, 1)
        complete(fake, seq, tx_status: 0x24)
        wait_until(fn -> Adapter.info(adapter).receiver == :absent end)
    end

    ctx
  end

  defp active(fake, adapter) do
    n = length(transmits(fake)) + 1
    task = Task.async(fn -> Adapter.active_source(adapter) end)
    {seq, _as} = nth_tx(fake, n)
    complete(fake, seq, tx_status: 0x01)
    :ok = Task.await(task)
  end

  defp g_log(log_addrs) do
    fn
      :g_log -> {:ok, log_addrs}
      _ -> :default
    end
  end

  defp requests(fake), do: for({_id, request} <- Fake.requests(fake), do: request)

  # Transmits so far as {sequence, message, struct}. The default responder
  # numbers transmits from 1.
  defp transmits(fake) do
    for {{:transmit, body}, seq} <-
          fake |> requests() |> transmit_requests() |> Enum.with_index(1) do
      struct = Struct.decode_msg(body)
      {:ok, message} = Message.decode(struct.msg)
      {seq, message, struct}
    end
  end

  defp transmit_requests(requests), do: Enum.filter(requests, &match?({:transmit, _}, &1))

  defp nth_tx_struct(fake, n), do: wait_until(fn -> Enum.at(transmits(fake), n - 1) end)

  defp nth_tx(fake, n) do
    {seq, message, _struct} = nth_tx_struct(fake, n)
    {seq, message}
  end

  defp find_tx(fake, fun) do
    Enum.find_value(transmits(fake), fn {seq, message, _} ->
      if fun.(message), do: {seq, message}
    end)
  end

  defp last_transmit(fake, n) do
    found = Enum.filter(Fake.requests(fake), &match?({_, {:transmit, _}}, &1))
    if length(found) >= n, do: List.last(found)
  end

  defp complete(fake, seq, fields) do
    fields = Keyword.put_new(fields, :msg, <<0x40>>)
    :ok = Fake.inject(fake, {:msg, Struct.encode_msg([sequence: seq] ++ fields)})
  end

  defp reply(fake, seq, bytes),
    do: complete(fake, seq, msg: bytes, tx_status: 0x01, rx_status: 0x01)

  defp receive_msg(fake, bytes),
    do: :ok = Fake.inject(fake, {:msg, Struct.encode_msg(msg: bytes, rx_status: 0x01)})

  defp initial_state(fake, pa, mask), do: state_change(fake, pa, mask, [:initial_state])

  defp state_change(fake, pa, mask, flags \\ []) do
    event =
      Struct.encode_event(event: :state_change, phys_addr: pa, log_addr_mask: mask, flags: flags)

    :ok = Fake.inject(fake, {:event, event})
  end

  defp assert_stopped(pid, reason) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, ^reason}
  end

  defp wait_until(fun, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    case fun.() do
      result when result in [nil, false] ->
        if System.monotonic_time(:millisecond) > deadline, do: flunk("condition never held")
        Process.sleep(5)
        do_wait_until(fun, deadline)

      result ->
        result
    end
  end
end
