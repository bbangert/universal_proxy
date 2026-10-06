defmodule UniversalProxy.ESPHome.SerialProxyTest do
  # Locks in the wire-level contract between this repo's adapter and
  # espex's dispatcher for SerialProxyRequest/SerialProxyConfigureRequest/
  # SerialProxyWriteRequest, under espex 0.11's API 1.17 single-owner rule
  # (on top of the 0.8 lazy-open + persistent-subscribe-intent semantics):
  #
  #   * SUBSCRIBE / UNSUBSCRIBE for an advertised instance are handed to
  #     the connection whole as `{:serial_subscribe, instance}` /
  #     `{:serial_unsubscribe, instance}`: it claims (or releases) the
  #     instance on the Server, records the intent, lazily opens and
  #     acks. Dispatch itself records nothing.
  #   * CONFIGURE and WRITE are gated on ownership (= this connection has
  #     SUBSCRIBEd). A non-owner's CONFIGURE is refused with PORT_IN_USE;
  #     its WRITE is dropped (no ack exists to carry an error).
  #   * For the owner, CONFIGURE always attempts an open (closing first if
  #     already open), and WRITE against an advertised-but-unopened
  #     instance lazily opens via `{:serial_open, instance, :default_opts}`.
  #
  # These tests drive `Espex.Dispatch.handle_request/2` directly. They
  # do NOT call our adapter's `request/2` — that path is covered by
  # `UniversalProxy.ESPHome.SerialProxy.RelayTest`. The value here is
  # protecting against an espex change that would silently alter the
  # contract this adapter is written against.
  use ExUnit.Case, async: true

  alias Espex.{ConnectionState, DeviceConfig, Dispatch, Proto, SerialProxy}

  @instance 0

  defp state(overrides \\ []) do
    info = SerialProxy.Info.new(instance: @instance, name: "test-port", port_type: :ttl)

    defaults = [
      device_config: %DeviceConfig{name: "test", project_name: "test", project_version: "0.0.1"},
      peer: "127.0.0.1:0",
      serial_proxies: [info],
      adapters: %{
        serial_proxy: UniversalProxy.ESPHome.SerialProxy,
        zwave_proxy: nil,
        infrared_proxy: nil,
        entity_provider: nil
      }
    ]

    ConnectionState.new(Keyword.merge(defaults, overrides))
  end

  defp subscribe_req,
    do: %Proto.SerialProxyRequest{
      instance: @instance,
      type: :SERIAL_PROXY_REQUEST_TYPE_SUBSCRIBE
    }

  defp unsubscribe_req,
    do: %Proto.SerialProxyRequest{
      instance: @instance,
      type: :SERIAL_PROXY_REQUEST_TYPE_UNSUBSCRIBE
    }

  defp configure_req,
    do: %Proto.SerialProxyConfigureRequest{instance: @instance, baudrate: 9600}

  defp write_req,
    do: %Proto.SerialProxyWriteRequest{instance: @instance, data: "hi"}

  # Ownership is recorded by the connection after a successful claim;
  # this is the state it leaves behind.
  defp owned(state), do: ConnectionState.put_serial_subscription(state, @instance)

  defp opened(state), do: ConnectionState.put_port(state, @instance, {self(), "/dev/null"})

  describe "SUBSCRIBE" do
    test "on an advertised-but-unopened instance is handed to the connection whole" do
      {new_state, actions} = Dispatch.handle_request(state(), subscribe_req())

      assert [{:serial_subscribe, @instance}] = actions
      refute ConnectionState.serial_subscribed?(new_state, @instance)
    end

    test "on an already-open instance is handed to the connection whole" do
      {_state, actions} = Dispatch.handle_request(opened(state()), subscribe_req())

      assert [{:serial_subscribe, @instance}] = actions
    end
  end

  describe "UNSUBSCRIBE" do
    test "is handed to the connection whole without opening" do
      {_state, actions} = Dispatch.handle_request(owned(state()), unsubscribe_req())

      assert [{:serial_unsubscribe, @instance}] = actions
    end
  end

  describe "CONFIGURE" do
    test "from a non-owner is refused with PORT_IN_USE and opens nothing" do
      {_state, actions} = Dispatch.handle_request(state(), configure_req())

      assert [
               {:log, :info, _},
               {:send, %Proto.SerialProxyRequestResponse{} = resp}
             ] = actions

      assert resp.instance == @instance
      assert resp.status == :SERIAL_PROXY_STATUS_PORT_IN_USE
      refute Enum.any?(actions, &match?({:serial_open, _, _}, &1))
    end

    test "from the owner on an unopened instance emits :serial_open with translated opts" do
      {_state, actions} = Dispatch.handle_request(owned(state()), configure_req())

      assert [{:serial_open, @instance, opts}] = actions
      assert opts[:speed] == 9600
    end

    test "from the owner on an already-open instance closes then re-opens" do
      {_state, actions} = Dispatch.handle_request(opened(owned(state())), configure_req())

      assert [{:serial_close, @instance}, {:serial_open, @instance, _opts}] = actions
    end
  end

  describe "WRITE" do
    test "from the owner on an advertised-but-unopened instance lazily opens then writes" do
      {_state, actions} = Dispatch.handle_request(owned(state()), write_req())

      assert [
               {:log, :debug, _},
               {:serial_open, @instance, :default_opts},
               {:serial_write, @instance, "hi"}
             ] = actions
    end

    test "from a non-owner is dropped without opening the port" do
      {_state, actions} = Dispatch.handle_request(state(), write_req())

      assert [{:log, :debug, _}] = actions
    end
  end

  describe "unknown instance" do
    test "SUBSCRIBE for an instance not in list_instances rejects with 'unknown instance'" do
      {state, actions} = Dispatch.handle_request(state(), %{subscribe_req() | instance: 99})

      refute ConnectionState.serial_subscribed?(state, 99)

      # espex 0.10 narrowed the unknown-instance rejection from the generic
      # ERROR to INVALID_ARGUMENT (API 1.16 acknowledgement statuses).
      assert [
               {:log, :warning, _},
               {:send,
                %Proto.SerialProxyRequestResponse{
                  status: :SERIAL_PROXY_STATUS_INVALID_ARGUMENT
                } = resp}
             ] = actions

      assert resp.error_message == "unknown instance"
    end
  end

  describe "default_open_opts/1" do
    test "falls back to espex defaults when the instance has no matching hardware" do
      assert UniversalProxy.ESPHome.SerialProxy.default_open_opts(99) ==
               Espex.SerialProxy.default_open_opts()
    end

    # Writes to the app-started SettingsStore (real persisted DETS state),
    # so it must never run in a default `mix test` — opt in with
    # `--include hardware` on a machine where mutating that state is fine.
    @tag :hardware
    test "round-trips settings persisted through a real port, if hardware is present" do
      case UniversalProxy.Hardware.list_ports() do
        [] ->
          :ok

        ports ->
          case Enum.find(
                 ports,
                 &(&1.connected and &1.configured and &1.kind in [:ttl, :rs232, :rs485])
               ) do
            nil ->
              :ok

            port ->
              opts = [
                speed: 19_200,
                data_bits: 8,
                stop_bits: 1,
                parity: :none,
                flow_control: :none
              ]

              :ok = UniversalProxy.UART.SettingsStore.put_opts(port.id, opts)

              instance =
                UniversalProxy.ESPHome.SerialProxy.list_instances()
                |> Enum.find_index(&(&1.name == port.ha_name))

              assert instance != nil
              assert UniversalProxy.ESPHome.SerialProxy.default_open_opts(instance) == opts
          end
      end
    end
  end
end
