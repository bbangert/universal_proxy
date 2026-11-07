defmodule UniversalProxy.ESPHome.SerialProxy.ZigbeeIntegrationTest do
  # End to end over a real Espex listener: a plaintext Native API client
  # drives the serial proxy the way serialx does (SUBSCRIBE, SET_MODE,
  # CONFIGURE, data, UNSUBSCRIBE), through this app's adapter, into a
  # ZigbeeProxy holding a FakeUART. async: false — the adapter finds its
  # owner through the global application env.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Espex.{Frame, MessageTypes, Proto}
  alias UniversalProxy.ESPHome.{SerialProxy, ZigbeeFixtures, ZigbeeProxy}

  hex = fn s -> s |> String.replace(" ", "") |> Base.decode16!() end

  # NCP DATA frame 0 (ESPHome ezsp_proxy_tap test vector) and the ACK the
  # acknowledger answers it with.
  @data_0 hex.("00 43 21 A8 50 9B 98 7E")
  @data_1 hex.("10 43 21 A8 50 9F C2 7E")
  @data_5 hex.("50 43 21 A8 50 8E AA 7E")
  @ack_1 hex.("7E 81 60 59 7E")
  @ack_2 hex.("7E 82 50 3A 7E")

  # Half of the 1 s USF 1.3.0 gives the whole esphome-hass:// open for
  # SUBSCRIBE + SET_MODE + CONFIGURE acks: loose enough for a loaded CI
  # host, tight enough to catch a call timing out on the way.
  @open_budget_ms 500

  setup do
    id = System.unique_integer([:positive])
    server_name = :"zigbee_espex_server_#{id}"

    # Its first push precedes the Espex start, as at boot.
    owner =
      ZigbeeFixtures.start_owner!(
        on_change: fn -> SerialProxy.push_zigbee_identity(server_name) end
      )

    sup =
      start_supervised!(
        {Espex.Supervisor,
         name: :"zigbee_espex_#{id}",
         server_name: server_name,
         port: 0,
         device_config: [name: "zigbee-test"],
         serial_proxy: SerialProxy}
      )

    {:ok, port} = Espex.Supervisor.bound_port(sup)
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1_000)
    on_exit(fn -> :gen_tcp.close(socket) end)

    instance =
      Enum.find_index(SerialProxy.list_instances(), &(&1.port_type == :usb_serial))

    assert is_integer(instance)

    Map.merge(owner, %{socket: socket, instance: instance, buffer: make_ref()})
  end

  # -- Client --

  defp send_msg(%{socket: socket}, message) do
    {:ok, frame} = MessageTypes.encode_message(message)
    :ok = :gen_tcp.send(socket, frame)
  end

  # The next message matching `fun`, skipping any others (pings etc).
  defp await(ctx, fun, timeout \\ 1_000) do
    case next_message(ctx, timeout) do
      {:ok, message} -> if fun.(message), do: message, else: await(ctx, fun, timeout)
      {:error, reason} -> flunk("no matching message: #{inspect(reason)}")
    end
  end

  defp next_message(%{socket: socket, buffer: key} = ctx, timeout) do
    buffer = Process.get(key, <<>>)

    case Frame.decode_frame(buffer) do
      {:ok, type_id, payload, rest} ->
        Process.put(key, rest)
        MessageTypes.decode_message(type_id, payload)

      {:incomplete, _} ->
        case :gen_tcp.recv(socket, 0, timeout) do
          {:ok, data} ->
            Process.put(key, buffer <> data)
            next_message(ctx, timeout)

          {:error, _} = error ->
            error
        end
    end
  end

  defp ack(ctx, type) do
    wire = :"SERIAL_PROXY_REQUEST_TYPE_#{type |> Atom.to_string() |> String.upcase()}"

    %Proto.SerialProxyRequestResponse{} =
      await(ctx, &match?(%Proto.SerialProxyRequestResponse{type: ^wire}, &1))
  end

  defp request(ctx, type) do
    wire = :"SERIAL_PROXY_REQUEST_TYPE_#{type |> Atom.to_string() |> String.upcase()}"
    send_msg(ctx, %Proto.SerialProxyRequest{instance: ctx.instance, type: wire})
    ack(ctx, type)
  end

  defp set_mode(ctx, mode) do
    wire = :"SERIAL_PROXY_MODE_#{mode |> Atom.to_string() |> String.upcase()}"
    send_msg(ctx, %Proto.SerialProxySetModeRequest{instance: ctx.instance, mode: wire})
    ack(ctx, :set_mode)
  end

  # serialx sends every field.
  defp configure(ctx, baudrate, flow_control) do
    send_msg(ctx, %Proto.SerialProxyConfigureRequest{
      instance: ctx.instance,
      baudrate: baudrate,
      flow_control: flow_control,
      parity: :SERIAL_PROXY_PARITY_NONE,
      stop_bits: 1,
      data_size: 8
    })

    ack(ctx, :configure)
  end

  # Everything the FakeUART reported so far.
  defp uart_calls(acc \\ []) do
    receive do
      {:uart_write, _} = call -> uart_calls([call | acc])
      {:uart_configure, _} = call -> uart_calls([call | acc])
      {:uart_set_dtr, _} = call -> uart_calls([call | acc])
      {:uart_set_rts, _} = call -> uart_calls([call | acc])
      :uart_close -> uart_calls([:uart_close | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "advertises the ZBT-2 and its USB identity", ctx do
    send_msg(ctx, %Proto.DeviceInfoRequest{})
    info = await(ctx, &match?(%Proto.DeviceInfoResponse{}, &1))
    proxy = Enum.at(info.serial_proxies, ctx.instance)

    assert proxy.port_type == :SERIAL_PROXY_PORT_TYPE_USB_SERIAL
    assert proxy.configured_line_states == 3

    send_msg(ctx, %Proto.SubscribeSerialProxyIdentityRequest{})
    instance = ctx.instance

    identity =
      await(ctx, &match?(%Proto.SerialProxyIdentity{instance: ^instance}, &1))

    assert identity.source == :SERIAL_PROXY_IDENTITY_SOURCE_USB
    assert identity.flags == 1
    assert identity.product == "ZBT-2"
    assert identity.serial_number == "abcd1234"
    assert %Proto.UsbDeviceDescriptor{vendor_id: 0x303A, product_id: 0x831A} = identity.usb
  end

  test "pushes the identity live across a UART error and the reopen", ctx do
    send_msg(ctx, %Proto.SubscribeSerialProxyIdentityRequest{})
    instance = ctx.instance

    assert %{flags: 1, product: "ZBT-2"} =
             await(ctx, &match?(%Proto.SerialProxyIdentity{instance: ^instance}, &1))

    send(ctx.server, {:circuits_uart, ZigbeeFixtures.tty(), {:error, :eio}})

    assert %{flags: 0, product: "", serial_number: ""} =
             await(ctx, &match?(%Proto.SerialProxyIdentity{instance: ^instance}, &1))

    send(ctx.server, :zigbee_reopen)

    assert %{flags: 1, product: "ZBT-2", serial_number: "abcd1234"} =
             await(ctx, &match?(%Proto.SerialProxyIdentity{instance: ^instance}, &1))
  end

  test "ZHA: SUBSCRIBE, SET_MODE(protocol), CONFIGURE(460800, hardware), then ACKed RX", ctx do
    started = System.monotonic_time(:millisecond)

    assert request(ctx, :subscribe).status == :SERIAL_PROXY_STATUS_OK
    assert set_mode(ctx, :protocol).status == :SERIAL_PROXY_STATUS_OK
    assert configure(ctx, 460_800, true).status == :SERIAL_PROXY_STATUS_OK

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed < @open_budget_ms, "open path took #{elapsed} ms"

    # 460800 is already live: only the flow control changes, in place.
    assert [{:uart_configure, opts}] = uart_calls()
    assert opts[:speed] == 460_800
    assert opts[:flow_control] == :hardware

    send(ctx.server, {:circuits_uart, ZigbeeFixtures.tty(), @data_0})

    data = await(ctx, &match?(%Proto.SerialProxyDataReceived{}, &1))
    assert data.instance == ctx.instance
    assert data.data == @data_0

    # The ACK reached the NCP too. That it is written before the bytes
    # are forwarded is pinned by the owner's unit tests, not here.
    assert_receive {:uart_write, @ack_1}, 1_000
    assert uart_calls() == []

    # Host → NCP writes pass through.
    send_msg(ctx, %Proto.SerialProxyWriteRequest{instance: ctx.instance, data: "host"})
    assert_receive {:uart_write, "host"}, 1_000

    # UNSUBSCRIBE releases the session, never the tty.
    assert request(ctx, :unsubscribe).status == :SERIAL_PROXY_STATUS_OK
    assert ctx.server |> ZigbeeProxy.status() |> Map.fetch!(:attached?)
    refute :uart_close in uart_calls()
  end

  test "flasher: three SUBSCRIBE/RAW/CONFIGURE/UNSUBSCRIBE cycles keep the tty open", ctx do
    for baud <- [150, 300, 1200] do
      started = System.monotonic_time(:millisecond)

      assert request(ctx, :subscribe).status == :SERIAL_PROXY_STATUS_OK
      assert set_mode(ctx, :raw).status == :SERIAL_PROXY_STATUS_OK
      assert configure(ctx, baud, false).status == :SERIAL_PROXY_STATUS_OK

      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed < @open_budget_ms, "open path at #{baud} took #{elapsed} ms"

      assert request(ctx, :unsubscribe).status == :SERIAL_PROXY_STATUS_OK
    end

    # One line-coding change per distinct baud, no close, no modem lines.
    assert ctx.server |> ZigbeeProxy.status() |> Map.fetch!(:attached?)
    calls = uart_calls()

    assert for({:uart_configure, opts} <- calls, do: opts[:speed]) == [150, 300, 1200]
    assert Enum.all?(calls, &match?({:uart_configure, _}, &1)), inspect(calls)

    # The released port is RAW and unsubscribed.
    state = :sys.get_state(ctx.server)
    assert state.mode == :raw
    assert state.subscribed == nil
  end

  test "CONFIGURE keeps the session: PROTOCOL mode, subscription and the same acker", ctx do
    request(ctx, :subscribe)
    set_mode(ctx, :protocol)
    session = :sys.get_state(ctx.server).subscribed

    assert configure(ctx, 115_200, false).status == :SERIAL_PROXY_STATUS_OK

    state = :sys.get_state(ctx.server)
    assert state.mode == :protocol
    assert state.subscribed == session
    assert [{:uart_configure, opts}] = uart_calls()
    assert opts[:speed] == 115_200
  end

  test "CONFIGURE does not reset the acker: out-of-sequence DATA_5 after a baud change is not ACKed",
       ctx do
    request(ctx, :subscribe)
    set_mode(ctx, :protocol)

    send(ctx.server, {:circuits_uart, ZigbeeFixtures.tty(), @data_0})
    await(ctx, &match?(%Proto.SerialProxyDataReceived{}, &1))
    assert_receive {:uart_write, @ack_1}

    assert configure(ctx, 115_200, false).status == :SERIAL_PROXY_STATUS_OK

    # A reset acker would resync to DATA_5 and ACK it 6; the kept one
    # expects frame 1, so DATA_5 earns nothing. The bytes still reach the
    # client (no RX drop window across the CONFIGURE).
    send(ctx.server, {:circuits_uart, ZigbeeFixtures.tty(), @data_5})
    data = await(ctx, &match?(%Proto.SerialProxyDataReceived{}, &1))
    assert data.data == @data_5
    refute_receive {:uart_write, _}, 100

    send(ctx.server, {:circuits_uart, ZigbeeFixtures.tty(), @data_1})
    assert await(ctx, &match?(%Proto.SerialProxyDataReceived{}, &1)).data == @data_1
    assert_receive {:uart_write, @ack_2}
  end
end
