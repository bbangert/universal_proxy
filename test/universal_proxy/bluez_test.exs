defmodule UniversalProxy.BluezSpecTest do
  use ExUnit.Case, async: true

  # The children/1 order/opts tests live in the bluez library itself
  # (deps_local/bluez); the app owns only its bluez_spec/0 wiring.

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
end
