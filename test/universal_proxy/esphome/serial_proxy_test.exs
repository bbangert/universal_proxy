defmodule UniversalProxy.ESPHome.SerialProxyTest do
  # Locks in the wire-level contract between this repo's adapter and
  # espex's dispatcher for SerialProxyRequest ordering. Two cases:
  #
  #   1. SUBSCRIBE before CONFIGURE — serialx >= the puddly/serialx#91
  #      fix sends this order. Espex must stash the intent and OK the
  #      request; CONFIGURE then emits the {:serial_open, ...} +
  #      {:replay_pending_subscribe, ...} action pair.
  #
  #   2. CONFIGURE then SUBSCRIBE — the original aioesphomeapi order.
  #      SUBSCRIBE on an opened port routes to {:serial_request, ...}
  #      with no pending stash.
  #
  # These tests drive `Espex.Dispatch.handle_request/2` directly. They
  # do NOT call our adapter's `request/2` — that path is covered by
  # `UniversalProxy.ESPHome.SerialProxy.RelayTest`. The value here is
  # protecting against an espex regression that would silently revert
  # to the pre-fix gate.
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

  describe "SUBSCRIBE before CONFIGURE (serialx >= puddly/serialx#91)" do
    test "stashes pending intent and replies OK without calling the adapter" do
      {new_state, actions} = Dispatch.handle_request(state(), subscribe_req())

      assert ConnectionState.pending_subscription?(new_state, @instance)
      refute ConnectionState.port_open?(new_state, @instance)

      assert [{:send, %Proto.SerialProxyRequestResponse{} = resp}] = actions
      assert resp.instance == @instance
      assert resp.status == :SERIAL_PROXY_STATUS_OK
      assert resp.type == :SERIAL_PROXY_REQUEST_TYPE_SUBSCRIBE
      assert resp.error_message == ""

      # No adapter-bound actions until CONFIGURE arrives.
      refute Enum.any?(actions, &match?({:serial_open, _, _}, &1))
      refute Enum.any?(actions, &match?({:serial_request, _, _}, &1))
    end

    test "CONFIGURE after pending SUBSCRIBE emits :serial_open then :replay_pending_subscribe" do
      {state, _} = Dispatch.handle_request(state(), subscribe_req())
      {_state, actions} = Dispatch.handle_request(state, configure_req())

      assert [
               {:serial_open, @instance, opts},
               {:replay_pending_subscribe, @instance}
             ] = actions

      assert opts[:speed] == 9600
    end

    test "UNSUBSCRIBE while pending drops the intent and replies OK" do
      {state, _} = Dispatch.handle_request(state(), subscribe_req())
      assert ConnectionState.pending_subscription?(state, @instance)

      {state, actions} = Dispatch.handle_request(state, unsubscribe_req())

      refute ConnectionState.pending_subscription?(state, @instance)

      assert [{:send, %Proto.SerialProxyRequestResponse{status: :SERIAL_PROXY_STATUS_OK}}] =
               actions
    end
  end

  describe "CONFIGURE then SUBSCRIBE (legacy / aioesphomeapi order)" do
    test "CONFIGURE alone emits :serial_open + (no-op) :replay_pending_subscribe with no pending intent" do
      {state, actions} = Dispatch.handle_request(state(), configure_req())

      refute ConnectionState.pending_subscription?(state, @instance)

      # Replay action is always emitted; interpreter no-ops when there's no
      # pending intent. We assert the action shape here, not the runtime
      # effect — those belong in espex's own tests.
      assert [
               {:serial_open, @instance, _opts},
               {:replay_pending_subscribe, @instance}
             ] = actions
    end

    test "SUBSCRIBE on an open port routes through :serial_request (not stashed)" do
      # Drive CONFIGURE through Dispatch so we catch a regression that would
      # incorrectly stash pending during CONFIGURE. Then simulate "open
      # succeeded" by storing a fake handle so port_open? returns true for
      # the subsequent SUBSCRIBE.
      {state, _configure_actions} = Dispatch.handle_request(state(), configure_req())
      opened = ConnectionState.put_port(state, @instance, {self(), "/dev/null"})

      refute ConnectionState.pending_subscription?(opened, @instance)

      {new_state, actions} = Dispatch.handle_request(opened, subscribe_req())

      refute ConnectionState.pending_subscription?(new_state, @instance)
      assert [{:serial_request, @instance, :subscribe}] = actions
    end
  end

  describe "unknown instance" do
    test "SUBSCRIBE for an instance not in list_instances rejects with 'unknown instance'" do
      {state, actions} = Dispatch.handle_request(state(), %{subscribe_req() | instance: 99})

      refute ConnectionState.pending_subscription?(state, 99)

      assert [
               {:log, :warning, _},
               {:send,
                %Proto.SerialProxyRequestResponse{status: :SERIAL_PROXY_STATUS_ERROR} = resp}
             ] = actions

      assert resp.error_message == "unknown instance"
    end
  end
end
