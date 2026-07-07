defmodule UniversalProxy.BluezTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Bluez

  # Normalize the mixed child shapes (child_spec maps for the daemons,
  # bare modules, {module, opts} tuples) down to a comparable id.
  defp id_of(%{id: id}), do: id
  defp id_of({mod, _opts}), do: mod
  defp id_of(mod) when is_atom(mod), do: mod

  describe "children/1" do
    test "extra_children append after BlueAlsa, in caller order" do
      # Restart-ordering contract under :rest_for_one — extra children (the
      # app's audio consumers + Improv, appended last by the caller) restart
      # with the audio path but a fault there never disturbs the proxy
      # scanning/GATT stack. A regression here silently changes crash
      # semantics. Mirrors bluez_spec/0's real slot content.
      extra = [
        {Task.Supervisor, name: __MODULE__.ExtraTaskSup},
        __MODULE__.ExtraChild,
        {UniversalProxy.Improv.Supervisor, [pubsub: __MODULE__.PubSub]}
      ]

      ids = Bluez.children(extra_children: extra) |> Enum.map(&id_of/1)

      assert ids == [
               :dbus_daemon,
               Bluez.BusReady,
               :bluetoothd,
               Bluez.Client,
               Bluez.Agent,
               Task.Supervisor,
               Bluez.Gatt,
               :bluealsad,
               Bluez.BlueAlsa,
               # extra_children, in caller order
               Task.Supervisor,
               __MODULE__.ExtraChild,
               UniversalProxy.Improv.Supervisor
             ]
    end

    test "opts thread through to the Client/Gatt/BlueAlsa children" do
      fan_out = fn _advert -> :ok end

      children =
        Bluez.children(
          client: [on_advertisement: fan_out],
          gatt: [on_connections_changed: fan_out],
          blue_alsa: [pubsub: __MODULE__.PubSub]
        )

      assert {Bluez.Client, [on_advertisement: ^fan_out]} =
               Enum.find(children, &match?({Bluez.Client, _}, &1))

      assert {Bluez.Gatt, [on_connections_changed: ^fan_out]} =
               Enum.find(children, &match?({Bluez.Gatt, _}, &1))

      assert {Bluez.BlueAlsa, [pubsub: __MODULE__.PubSub]} =
               Enum.find(children, &match?({Bluez.BlueAlsa, _}, &1))
    end

    test "bluez_spec/0 mounts the AudioManager pair then Improv LAST in the slot" do
      assert {UniversalProxy.Bluez, opts} = UniversalProxy.Bluetooth.bluez_spec()

      extra_ids = opts |> Keyword.fetch!(:extra_children) |> Enum.map(&id_of/1)

      assert extra_ids == [
               Task.Supervisor,
               UniversalProxy.Bluetooth.AudioManager,
               UniversalProxy.Improv.Supervisor
             ]
    end

    test "no opts yields the default children with an empty extra slot" do
      ids = Bluez.children([]) |> Enum.map(&id_of/1)

      assert ids == [
               :dbus_daemon,
               Bluez.BusReady,
               :bluetoothd,
               Bluez.Client,
               Bluez.Agent,
               Task.Supervisor,
               Bluez.Gatt,
               :bluealsad,
               Bluez.BlueAlsa
             ]
    end
  end
end
