defmodule UniversalProxy.ESPHome.SupervisorTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.ESPHome.{BluetoothProxy, BluetoothScanner}
  alias UniversalProxy.ESPHome.Supervisor, as: ESPHomeSupervisor

  describe "bluetooth_opts/2 (enabled × active_connections matrix)" do
    test "unsupported target wires nothing, whatever the settings say" do
      for enabled <- [true, false], active <- [true, false] do
        assert ESPHomeSupervisor.bluetooth_opts(false, %{
                 enabled: enabled,
                 active_connections: active
               }) == []
      end
    end

    test "disabled wires nothing (flags 0), whatever active_connections says" do
      for active <- [true, false] do
        assert ESPHomeSupervisor.bluetooth_opts(true, %{
                 enabled: false,
                 active_connections: active
               }) == []
      end
    end

    test "enabled without active connections wires the scanner only (passive-only proxy)" do
      assert ESPHomeSupervisor.bluetooth_opts(true, %{enabled: true, active_connections: false}) ==
               [bluetooth_scanner: BluetoothScanner]
    end

    test "enabled with active connections wires scanner + GATT proxy (full flags)" do
      assert ESPHomeSupervisor.bluetooth_opts(true, %{enabled: true, active_connections: true}) ==
               [bluetooth_scanner: BluetoothScanner, bluetooth_proxy: BluetoothProxy]
    end

    test "extra settings fields are tolerated (full Settings map shape)" do
      settings = %{enabled: true, active_connections: true, adapter: "AA:BB:CC:DD:EE:FF"}

      assert [bluetooth_scanner: _, bluetooth_proxy: _] =
               ESPHomeSupervisor.bluetooth_opts(true, settings)
    end
  end
end
