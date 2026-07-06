defmodule UniversalProxy.ESPHome.SupervisorTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.ESPHome.{BluetoothProxy, BluetoothScanner}
  alias UniversalProxy.ESPHome.Supervisor, as: ESPHomeSupervisor

  # The full Settings.get/0 shape bluetooth_opts/2 consumes.
  defp settings(overrides) do
    Map.merge(
      %{enabled: true, active_connections: true, adapter: nil, roles: %{}},
      Map.new(overrides)
    )
  end

  describe "bluetooth_opts/2 (enabled × paused × active_connections matrix)" do
    test "unsupported target wires nothing, whatever the settings say" do
      for enabled <- [true, false], active <- [true, false] do
        assert ESPHomeSupervisor.bluetooth_opts(
                 false,
                 settings(enabled: enabled, active_connections: active)
               ) == []
      end
    end

    test "disabled wires nothing (flags 0), whatever active_connections says" do
      for active <- [true, false] do
        assert ESPHomeSupervisor.bluetooth_opts(
                 true,
                 settings(enabled: false, active_connections: active)
               ) == []
      end
    end

    test "enabled without active connections wires the scanner only (passive-only proxy)" do
      assert ESPHomeSupervisor.bluetooth_opts(true, settings(active_connections: false)) ==
               [bluetooth_scanner: BluetoothScanner]
    end

    test "enabled with active connections wires scanner + GATT proxy (full flags)" do
      assert ESPHomeSupervisor.bluetooth_opts(true, settings([])) ==
               [bluetooth_scanner: BluetoothScanner, bluetooth_proxy: BluetoothProxy]
    end

    test "role-paused wires nothing, whatever active_connections says" do
      # Roles engaged, none :proxy — "Off" must mean HA receives nothing.
      for active <- [true, false] do
        assert ESPHomeSupervisor.bluetooth_opts(
                 true,
                 settings(
                   active_connections: active,
                   roles: %{"AA:BB:CC:DD:EE:FF" => :audio}
                 )
               ) == []
      end
    end

    test "a surviving legacy fallback still wires the full set" do
      # A different radio holds a role; the legacy adapter keeps proxying.
      assert [bluetooth_scanner: _, bluetooth_proxy: _] =
               ESPHomeSupervisor.bluetooth_opts(
                 true,
                 settings(
                   adapter: "AA:BB:CC:DD:EE:FF",
                   roles: %{"11:22:33:44:55:66" => :audio}
                 )
               )
    end

    test "an explicit :proxy role wires the full set" do
      assert [bluetooth_scanner: _, bluetooth_proxy: _] =
               ESPHomeSupervisor.bluetooth_opts(
                 true,
                 settings(roles: %{"AA:BB:CC:DD:EE:FF" => :proxy})
               )
    end
  end
end
