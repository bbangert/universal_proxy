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

  test "bluez_spec/0 clears any exclusion and leaves Mgmt off" do
    assert {Bluez, opts} = UniversalProxy.Bluetooth.bluez_spec()

    assert Keyword.fetch!(opts, :exclude_adapters) == []
    refute Keyword.has_key?(opts, :mgmt)
  end

  test "bluez_spec/1 with a mesh adapter excludes it and starts Mgmt" do
    mac = "AA:BB:CC:DD:EE:FF"
    assert {Bluez, opts} = UniversalProxy.Bluetooth.bluez_spec(tuya_adapter: mac)

    assert Keyword.fetch!(opts, :exclude_adapters) == [mac]
    assert Keyword.fetch!(opts, :mgmt) == true
    # The rest of the wiring is unchanged.
    {Bluez, base} = UniversalProxy.Bluetooth.bluez_spec()

    assert Keyword.drop(opts, [:exclude_adapters, :mgmt, :extra_children]) ==
             Keyword.drop(base, [:exclude_adapters, :extra_children])
  end

  test "bluez_spec/1 with a mesh adapter mounts the mesh subtree before Improv" do
    mac = "AA:BB:CC:DD:EE:FF"
    assert {Bluez, opts} = UniversalProxy.Bluetooth.bluez_spec(tuya_adapter: mac)

    extra = Keyword.fetch!(opts, :extra_children)

    assert Enum.map(extra, &id_of/1) == [
             Task.Supervisor,
             UniversalProxy.Bluetooth.AudioManager,
             UniversalProxy.TuyaMesh.Supervisor,
             Improv.Supervisor
           ]

    assert {UniversalProxy.TuyaMesh.Supervisor, [tuya_adapter: ^mac]} =
             Enum.at(extra, 2)
  end
end
