defmodule Circuits.CEC.Transport.FakeTest do
  use ExUnit.Case, async: true

  alias Circuits.CEC.Struct
  alias Circuits.CEC.Transport.Fake

  setup do
    {:ok, fake} = start_supervised(Fake)
    %{fake: fake}
  end

  test "open sends ready with vc4-like caps", %{fake: fake} do
    {:ok, t} = Fake.open("/dev/cec0", fake: fake)
    assert {[{:ready, caps}], _t} = await(t)
    assert %{driver: "vc4_hdmi", available_log_addrs: 1} = Struct.decode_caps(caps)
    assert Fake.owner(fake) == self()
  end

  test "ready: {:open_error, errno}" do
    {:ok, fake} = Fake.start_link(ready: {:open_error, :enoent})
    {:ok, t} = Fake.open("/dev/cec0", fake: fake)
    assert {[{:open_error, :enoent}], _t} = await(t)
  end

  test "records requests and answers with the default responder", %{fake: fake} do
    t = opened(fake)
    claim = Struct.encode_log_addrs(num_log_addrs: 1, osd_name: "UP")
    tx = Struct.encode_msg(msg: <<0x40, 0x04>>)

    {t, {:ok, <<0x00, 0x10>>}} = request(t, :g_phys)
    {t, {:ok, <<>>}} = request(t, {:s_mode, 0x21})
    {t, {:ok, <<0x21, 0, 0, 0>>}} = request(t, :g_mode)
    {t, {:ok, ^claim}} = request(t, {:s_log, claim})
    {t, {:ok, ^claim}} = request(t, :g_log)
    {t, {:ok, sent}} = request(t, {:transmit, tx})
    {t, {:ok, sent2}} = request(t, {:transmit, tx})
    {_t, {:ok, conn}} = request(t, :g_conn)

    assert %{sequence: 1} = Struct.decode_msg(sent)
    assert %{sequence: 2} = Struct.decode_msg(sent2)
    assert %{type: :drm} = Struct.decode_connector_info(conn)

    assert [{1, :g_phys}, {2, {:s_mode, 0x21}}, {3, :g_mode} | _] = Fake.requests(fake)
    assert length(Fake.requests(fake)) == 8
  end

  test "a custom responder, deferred replies and errors", %{fake: fake} do
    t = opened(fake)

    :ok =
      Fake.set_responder(fake, fn
        {:s_mode, 0x21} -> {:error, :ebusy}
        {:transmit, _} -> :noreply
        _ -> :default
      end)

    {t, {:error, :ebusy}} = request(t, {:s_mode, 0x21})
    {t, {:ok, <<>>}} = request(t, {:s_mode, 0x11})

    {:ok, id, t} = Fake.send_request(t, {:transmit, Struct.encode_msg(msg: <<0x40, 0x04>>)})
    refute_received {Fake, _, _}
    :ok = Fake.reply(fake, id, {:error, :enonet})
    assert {[{:reply, ^id, {:error, :enonet}}], _t} = await(t)
  end

  test "injected messages, events, gone and exit", %{fake: fake} do
    t = opened(fake)
    msg = Struct.encode_msg(msg: <<0x04, 0x8F>>, rx_status: 1)
    event = Struct.encode_event(event: :lost_msgs, lost_msgs: 3)

    :ok = Fake.inject(fake, {:msg, msg})
    :ok = Fake.inject(fake, {:event, event})
    :ok = Fake.inject(fake, :gone)
    :ok = Fake.inject(fake, {:exit, 1})

    assert {[{:msg, ^msg}], t} = await(t)
    assert {[{:event, ^event}], t} = await(t)
    assert {[:gone], t} = await(t)
    assert {[{:exit, 1}], t} = await(t)
    assert Fake.send_request(t, :caps) == {:error, :closed}
    assert Fake.closed?(fake)
  end

  test "close/1 is recorded and tolerates a dead fake", %{fake: fake} do
    t = opened(fake)
    refute Fake.closed?(fake)
    assert :ok = Fake.close(t)
    assert Fake.closed?(fake)

    stop_supervised!(Fake)
    assert :ok = Fake.close(t)
  end

  test "other messages are :unknown", %{fake: fake} do
    t = opened(fake)
    assert Fake.handle_message(t, {Fake, make_ref(), :gone}) == :unknown
    assert Fake.handle_message(t, :hello) == :unknown
  end

  defp opened(fake) do
    {:ok, t} = Fake.open("/dev/cec0", fake: fake)
    {[{:ready, _}], t} = await(t)
    t
  end

  defp await(t) do
    ref = t.ref

    receive do
      {Fake, ^ref, _} = message ->
        {:ok, events, t} = Fake.handle_message(t, message)
        {events, t}
    after
      1_000 -> flunk("nothing from the fake")
    end
  end

  defp request(t, request) do
    {:ok, id, t} = Fake.send_request(t, request)
    {[{:reply, ^id, result}], t} = await(t)
    {t, result}
  end
end
