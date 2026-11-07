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

    test "a mesh-only role wires the full set (the other radio auto-proxies)" do
      # The mesh radio is excluded from the BlueZ claim, so the client's auto
      # fallback proxies on the remaining radio: not a pause.
      assert [bluetooth_scanner: _, bluetooth_proxy: _] =
               ESPHomeSupervisor.bluetooth_opts(
                 true,
                 settings(roles: %{"AA:BB:CC:DD:EE:FF" => :tuya_mesh})
               )
    end

    test "a mesh role with every other radio :off wires nothing" do
      assert ESPHomeSupervisor.bluetooth_opts(
               true,
               settings(roles: %{"AA:BB:CC:DD:EE:FF" => :tuya_mesh, "11:22:33:44:55:66" => :off})
             ) == []
    end

    test "an explicit :proxy role wires the full set" do
      assert [bluetooth_scanner: _, bluetooth_proxy: _] =
               ESPHomeSupervisor.bluetooth_opts(
                 true,
                 settings(roles: %{"AA:BB:CC:DD:EE:FF" => :proxy})
               )
    end
  end

  describe "Tuya mesh sub-devices in the device config" do
    alias Espex.DeviceConfig.Device

    @devices [%Device{id: 1, name: "path light 2"}, %Device{id: 3, name: "path and post"}]

    # The Espex child's start args: its options and the live-devices fun.
    defp espex_start(init_opts) do
      {:ok, {_flags, children}} = ESPHomeSupervisor.init(init_opts)

      %{start: {ESPHomeSupervisor, :start_espex, [opts, fun]}} =
        Enum.find(children, &(&1.id == Espex))

      {opts, fun}
    end

    defp devices_of(opts), do: Keyword.fetch!(opts[:device_config], :devices)

    test "init merges the current mesh devices" do
      {opts, _fun} = espex_start(mesh_devices_fun: fn -> @devices end)
      assert devices_of(opts) == @devices
      # The rest of the device config is untouched.
      assert Keyword.has_key?(opts[:device_config], :accepts_key_provisioning)
    end

    test "no mesh role, or the Store down, means no devices (the default reader on this host)" do
      {opts, _fun} = espex_start([])
      assert devices_of(opts) == []
    end

    test "a failing mesh read never fails the init" do
      for fun <- [fn -> raise "boom" end, fn -> exit(:noproc) end] do
        {opts, _fun} = espex_start(mesh_devices_fun: fun)
        assert devices_of(opts) == []
      end
    end

    test "every Espex start takes the provider's devices, else keeps the init ones" do
      live = [%Device{id: 7, name: "added later"}]

      {opts, fun} =
        espex_start(mesh_devices_fun: fn -> @devices end, live_devices_fun: fn -> {:ok, live} end)

      assert devices_of(ESPHomeSupervisor.refresh_devices(opts, fun.())) == live
      assert devices_of(ESPHomeSupervisor.refresh_devices(opts, :error)) == @devices
      # A provider that doesn't know the mesh yet never empties Espex's list.
      assert devices_of(ESPHomeSupervisor.refresh_devices(opts, {:error, :unknown})) == @devices
    end

    test "the default live source is the running provider (no Bluetooth here: no devices)" do
      {_opts, fun} = espex_start(mesh_devices_fun: fn -> @devices end)
      assert fun.() in [:error, {:ok, []}]
    end

    test "merge_devices replaces the sub-devices and keeps the rest" do
      merged = ESPHomeSupervisor.merge_devices([name: "x", devices: []], @devices)
      assert merged[:name] == "x"
      assert Keyword.get_values(merged, :devices) == [@devices]
    end
  end

  describe "pick_zwave_port/3" do
    alias UniversalProxy.Hardware

    defp ports(enumerated, bus_paths) do
      Hardware.list_ports(
        slots: nil,
        enumerated: enumerated,
        bus_paths: bus_paths,
        saved_configs: %{},
        line_settings: %{},
        in_use_ports: MapSet.new(),
        zwave_claim: nil,
        tty_class_dir: "/nonexistent-#{System.unique_integer([:positive])}"
      )
    end

    defp zbt2(product_id) do
      %{
        vendor_id: 0x303A,
        product_id: product_id,
        manufacturer: "Nabu Casa",
        description: "Home Assistant Connect ZBT-2",
        serial_number: "ZB0001"
      }
    end

    test "claims a ZWA-2 by its auto-classified kind" do
      ports =
        ports(
          %{
            "ttyACM0" => %{
              vendor_id: 0x303A,
              product_id: 0x4001,
              description: "Home Assistant Connect ZWA-2",
              serial_number: "DH001K8R"
            }
          },
          %{"ttyACM0" => "1-1.1"}
        )

      assert %{path: "ttyACM0"} = ESPHomeSupervisor.pick_zwave_port(ports, %{}, [])
    end

    test "never returns a ZBT-2, whatever PID it enumerates with" do
      for pid <- [0x4001, 0x831A] do
        ports = ports(%{"ttyACM0" => zbt2(pid)}, %{"ttyACM0" => "1-1.1"})
        assert [%{kind: :zigbee}] = ports
        assert ESPHomeSupervisor.pick_zwave_port(ports, %{}, []) == nil
      end
    end

    test "a stale saved :zwave config on a ZBT-2's port is ignored (locked ports ignore saved config)" do
      for pid <- [0x4001, 0x831A] do
        ports = ports(%{"ttyACM0" => zbt2(pid)}, %{"ttyACM0" => "1-1.1"})
        key = {"1-1.1", 0x303A, pid}

        config = %{
          port_type: :zwave,
          slot_sub: "1-1.1",
          vendor_id: 0x303A,
          product_id: pid
        }

        assert ESPHomeSupervisor.pick_zwave_port(ports, %{key => "ttyACM0"}, [config]) == nil
      end
    end

    test "ports and keys derived from one snapshot never let a saved :zwave config claim a ZBT-2" do
      enumerated = %{"ttyACM0" => zbt2(0x4001)}
      bus_paths = %{"ttyACM0" => "1-1.1"}
      ports = ports(enumerated, bus_paths)
      keys = Hardware.live_port_keys(enumerated: enumerated, bus_paths: bus_paths)

      assert Map.values(keys) == ["ttyACM0"]
      assert [%{tty_name: "ttyACM0", locked: true}] = ports

      config = %{port_type: :zwave, slot_sub: "1-1.1", vendor_id: 0x303A, product_id: 0x4001}
      assert ESPHomeSupervisor.pick_zwave_port(ports, keys, [config]) == nil
    end

    test "a saved :zwave override on an unlocked generic port still wins" do
      ports =
        ports(
          %{"ttyUSB0" => %{vendor_id: 0x10C4, product_id: 0xEA60, serial_number: "X"}},
          %{"ttyUSB0" => "1-1.2"}
        )

      config = %{port_type: :zwave, slot_sub: "1-1.2", vendor_id: 0x10C4, product_id: 0xEA60}
      key = {"1-1.2", 0x10C4, 0xEA60}

      assert %{path: "ttyUSB0"} =
               ESPHomeSupervisor.pick_zwave_port(ports, %{key => "ttyUSB0"}, [config])
    end
  end

  describe "Zigbee proxy wiring" do
    alias UniversalProxy.ESPHome.ZigbeeProxy

    test "the ZigbeeProxy child starts before Espex (rest_for_one)" do
      {:ok, {%{strategy: :rest_for_one}, children}} = ESPHomeSupervisor.init([])
      ids = Enum.map(children, & &1.id)

      assert Enum.find_index(ids, &(&1 == ZigbeeProxy)) <
               Enum.find_index(ids, &(&1 == Espex))
    end

    test "pick_zigbee_port/1 takes the first connected :zigbee row, keeping the row" do
      zbt2 = %{connected: true, kind: :zigbee, tty_name: "ttyACM1", ha_name: "ZBT-2 (1-1.2)"}
      second = %{zbt2 | tty_name: "ttyACM2", ha_name: "ZBT-2 (1-1.3)"}

      ports = [
        %{connected: true, kind: :zwave, tty_name: "ttyACM0", ha_name: "ZWA-2"},
        %{zbt2 | connected: false},
        zbt2,
        second
      ]

      assert ESPHomeSupervisor.pick_zigbee_port(ports) ==
               %{path: "ttyACM1", display_name: "ZBT-2 (1-1.2)", port: zbt2}

      assert ESPHomeSupervisor.pick_zigbee_port(Enum.take(ports, 2)) == nil
    end
  end
end
