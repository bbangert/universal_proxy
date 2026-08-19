defmodule UniversalProxy.BluezSpecTest do
  use ExUnit.Case, async: true

  # The children/1 order/opts tests live in the bluez library itself (a hex
  # dep now); the app owns only its bluez_spec/0 wiring.

  defp id_of({mod, _opts}), do: mod
  defp id_of(mod) when is_atom(mod), do: mod

  test "bluez_spec/0 mounts the AudioManager pair then Improv LAST in the slot" do
    assert {Bluez, opts} = UniversalProxy.Bluetooth.bluez_spec()

    extra_ids = opts |> Keyword.fetch!(:extra_children) |> Enum.map(&id_of/1)

    assert extra_ids == [
             Task.Supervisor,
             UniversalProxy.Bluetooth.AudioManager,
             Improv.Supervisor
           ]
  end

  test "bluez_spec/0 wires the client opts (advert callback, pubsub, RSSI heartbeat)" do
    assert {Bluez, opts} = UniversalProxy.Bluetooth.bluez_spec()

    client_opts = Keyword.fetch!(opts, :client)

    assert client_opts[:on_advertisement] ==
             (&UniversalProxy.ESPHome.BluetoothScanner.on_advertisement/1)

    assert client_opts[:pubsub] == UniversalProxy.PubSub
    assert client_opts[:rssi_heartbeat_ms] == 1_500
  end
end
