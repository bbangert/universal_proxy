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

    {:ok, relay: relay, friendly_name: friendly_name, path: path}
  end

  # Phoenix.PubSub broadcasts `:uart_data` on `uart:<friendly_name>` to
  # simulate inbound UART RX without real hardware.
  defp publish(friendly_name, data) do
    Phoenix.PubSub.broadcast(@pubsub, "uart:#{friendly_name}", {:uart_data, %{data: data}})
  end

  # Synchronous round-trip through the GenServer: forces all preceding
  # messages in the relay's mailbox to be drained before the test proceeds.
  defp drain(relay), do: :sys.get_state(relay)

  test "drops RX bytes by default (not subscribed)", %{
    relay: relay,
    friendly_name: friendly_name
  } do
    publish(friendly_name, "ignored")
    drain(relay)
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
    drain(relay)
    refute_receive {:espex_serial_data, _, _}, 50
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
    drain(relay)
    refute_receive {:espex_serial_data, _, _}, 50
  end

  test "subscribe → unsubscribe → subscribe cycle restores forwarding", %{
    relay: relay,
    friendly_name: friendly_name
  } do
    :ok = Relay.subscribe(relay)
    publish(friendly_name, "first")
    assert_receive {:espex_serial_data, _, "first"}, 200

    :ok = Relay.unsubscribe(relay)
    publish(friendly_name, "gap")
    drain(relay)
    refute_receive {:espex_serial_data, _, _}, 50

    :ok = Relay.subscribe(relay)
    publish(friendly_name, "back")
    assert_receive {:espex_serial_data, _, "back"}, 200
  end

  test "no buffered replay: messages broadcast while unsubscribed are not delivered on subscribe",
       %{
         relay: relay,
         friendly_name: friendly_name
       } do
    for chunk <- ["a", "b", "c", "d", "e"] do
      publish(friendly_name, chunk)
    end

    drain(relay)
    :ok = Relay.subscribe(relay)
    refute_receive {:espex_serial_data, _, _}, 50

    publish(friendly_name, "after")
    assert_receive {:espex_serial_data, _, "after"}, 200
  end

  test "relay shuts down when its subscriber exits normally" do
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
    assert_receive {:DOWN, ^ref, :process, ^relay, reason}, 500
    assert reason == :normal
  end
end
