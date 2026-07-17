defmodule UniversalProxy.ESPHome.SerialProxyTest do
  # Locks in the wire-level contract between this repo's adapter and
  # espex's dispatcher for SerialProxyRequest/SerialProxyConfigureRequest/
  # SerialProxyWriteRequest ordering, under the espex 0.8 lazy-open +
  # persistent-subscribe-intent semantics (the old espex 0.7 contract —
  # `{:replay_pending_subscribe, _}` actions, one-shot pending-subscribe
  # stash — is gone; see `Espex.SerialProxy`'s moduledoc after the bump).
  #
  #   * SUBSCRIBE / UNSUBSCRIBE / WRITE against an advertised-but-unopened
  #     instance lazily open it via `{:serial_open, instance, :default_opts}`
  #     and are otherwise handled inline (no stash, no replay action).
  #   * CONFIGURE always attempts an open (closing first if already open)
  #     and never emits a replay action.
  #   * SUBSCRIBE/UNSUBSCRIBE against an already-open instance route
  #     straight through `{:serial_request, instance, type}`.
  #
  # These tests drive `Espex.Dispatch.handle_request/2` directly. They
  # do NOT call our adapter's `request/2` — that path is covered by
  # `UniversalProxy.ESPHome.SerialProxy.RelayTest`. The value here is
  # protecting against an espex regression that would silently revert
  # to the pre-0.8 gate.
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

  describe "SUBSCRIBE on an advertised-but-unopened instance (lazy open)" do
    test "lazily opens, replies OK, and records subscribe intent" do
      {new_state, actions} = Dispatch.handle_request(state(), subscribe_req())

      assert [
               {:log, :debug, _},
               {:serial_open, @instance, :default_opts},
               {:send, %Proto.SerialProxyRequestResponse{} = resp}
             ] = actions

      assert resp.instance == @instance
      assert resp.status == :SERIAL_PROXY_STATUS_OK
      assert resp.type == :SERIAL_PROXY_REQUEST_TYPE_SUBSCRIBE
      assert resp.error_message == ""

      assert ConnectionState.serial_subscribed?(new_state, @instance)
    end
  end

  describe "UNSUBSCRIBE on an advertised-but-unopened instance" do
    test "replies OK and clears subscribe intent without opening" do
      {state, actions} = Dispatch.handle_request(state(), unsubscribe_req())

      refute ConnectionState.serial_subscribed?(state, @instance)

      assert [{:send, %Proto.SerialProxyRequestResponse{status: :SERIAL_PROXY_STATUS_OK} = resp}] =
               actions

      assert resp.type == :SERIAL_PROXY_REQUEST_TYPE_UNSUBSCRIBE
    end
  end

  describe "CONFIGURE" do
    test "on an unopened instance emits :serial_open with translated opts and no replay action" do
      {_state, actions} = Dispatch.handle_request(state(), configure_req())

      assert [{:serial_open, @instance, opts}] = actions
      assert opts[:speed] == 9600
      refute Enum.any?(actions, &match?({:replay_pending_subscribe, _}, &1))
    end

    test "on an already-open instance closes then re-opens" do
      opened = ConnectionState.put_port(state(), @instance, {self(), "/dev/null"})

      {_state, actions} = Dispatch.handle_request(opened, configure_req())

      assert [{:serial_close, @instance}, {:serial_open, @instance, _opts}] = actions
    end
  end

  describe "WRITE on an advertised-but-unopened instance (restart-resume guard)" do
    test "lazily opens then writes, with no CONFIGURE required" do
      {_state, actions} = Dispatch.handle_request(state(), write_req())

      assert [
               {:log, :debug, _},
               {:serial_open, @instance, :default_opts},
               {:serial_write, @instance, "hi"}
             ] = actions
    end
  end

  describe "SUBSCRIBE on an already-open instance" do
    test "routes straight through :serial_request and records intent" do
      opened = ConnectionState.put_port(state(), @instance, {self(), "/dev/null"})

      {new_state, actions} = Dispatch.handle_request(opened, subscribe_req())

      assert [{:serial_request, @instance, :subscribe}] = actions
      assert ConnectionState.serial_subscribed?(new_state, @instance)
    end
  end

  describe "unknown instance" do
    test "SUBSCRIBE for an instance not in list_instances rejects with 'unknown instance'" do
      {state, actions} = Dispatch.handle_request(state(), %{subscribe_req() | instance: 99})

      refute ConnectionState.serial_subscribed?(state, 99)

      assert [
               {:log, :warning, _},
               {:send,
                %Proto.SerialProxyRequestResponse{status: :SERIAL_PROXY_STATUS_ERROR} = resp}
             ] = actions

      assert resp.error_message == "unknown instance"
    end
  end

  describe "default_open_opts/1" do
    test "falls back to espex defaults when the instance has no matching hardware" do
      assert UniversalProxy.ESPHome.SerialProxy.default_open_opts(99) ==
               Espex.SerialProxy.default_open_opts()
    end

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

              :ok = UniversalProxy.ESPHome.SerialProxy.SettingsStore.put_opts(port.id, opts)

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
