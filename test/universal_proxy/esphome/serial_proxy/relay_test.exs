defmodule UniversalProxy.ESPHome.SerialProxy.RelayTest do
  # Drives the relay directly (no UART hardware): publishes synthetic
  # `:uart_data` messages on the per-port PubSub topic and asserts
  # they are forwarded to the espex subscriber only while the
  # relay is in the subscribed state.
  use ExUnit.Case, async: true

  alias UniversalProxy.ESPHome.SerialProxy.Relay

  @pubsub UniversalProxy.PubSub

  setup do
    friendly_name = "test-port-#{System.unique_integer([:positive])}"
    path = "/dev/null-#{friendly_name}"

    {:ok, relay} =
      Relay.start_link(path: path, friendly_name: friendly_name, subscriber: self())

    # Make sure the relay's PubSub.subscribe has run before we publish.
    _ = :sys.get_state(relay)

    {:ok, relay: relay, friendly_name: friendly_name, path: path}
  end

  defp publish(friendly_name, data) do
    Phoenix.PubSub.broadcast(@pubsub, "uart:#{friendly_name}", {:uart_data, %{data: data}})
  end

  test "drops RX bytes by default (not subscribed)", %{
    friendly_name: friendly_name
  } do
    publish(friendly_name, "ignored")
    refute_receive {:espex_serial_data, _, _}, 50
  end

  test "subscribe enables forwarding to the espex subscriber", %{
    relay: relay,
    friendly_name: friendly_name,
    path: path
  } do
    assert :ok = Relay.subscribe(relay)

    publish(friendly_name, "hello")
    assert_receive {:espex_serial_data, {^relay, ^path}, "hello"}, 200
  end

  test "unsubscribe halts forwarding again", %{
    relay: relay,
    friendly_name: friendly_name
  } do
    :ok = Relay.subscribe(relay)
    publish(friendly_name, "first")
    assert_receive {:espex_serial_data, _, "first"}, 200

    :ok = Relay.unsubscribe(relay)
    publish(friendly_name, "dropped")
    refute_receive {:espex_serial_data, _, "dropped"}, 50
  end

  test "subscribe and unsubscribe are idempotent", %{
    relay: relay,
    friendly_name: friendly_name
  } do
    assert :ok = Relay.unsubscribe(relay)
    assert :ok = Relay.subscribe(relay)
    assert :ok = Relay.subscribe(relay)

    publish(friendly_name, "ok")
    assert_receive {:espex_serial_data, _, "ok"}, 200

    assert :ok = Relay.unsubscribe(relay)
    assert :ok = Relay.unsubscribe(relay)
    publish(friendly_name, "no")
    refute_receive {:espex_serial_data, _, _}, 50
  end

  test "relay shuts down when its subscriber exits" do
    friendly_name = "owner-port-#{System.unique_integer([:positive])}"

    parent = self()

    owner =
      spawn(fn ->
        {:ok, relay} =
          Relay.start_link(
            path: "/dev/null",
            friendly_name: friendly_name,
            subscriber: self()
          )

        send(parent, {:relay, relay})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:relay, relay}, 200
    ref = Process.monitor(relay)

    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^relay, :normal}, 500
  end
end
