defmodule UniversalProxy.ESPHome.BluetoothProxyTest do
  # async: false — tests register a stub process under the global
  # UniversalProxy.Bluez.Gatt name.
  use ExUnit.Case, async: false

  alias UniversalProxy.Bluez.Gatt
  alias UniversalProxy.ESPHome.BluetoothProxy

  @address 0xAABBCCDDEEFF

  defp start_gatt_stub(test_pid) do
    # Forwards every cast/call it receives to the test for inspection.
    # Registered under the real Gatt name so the adapter's casts land here.
    pid =
      spawn(fn ->
        receive_loop = fn loop ->
          receive do
            {:"$gen_cast", msg} ->
              send(test_pid, {:cast, msg})
              loop.(loop)

            {:"$gen_call", from, msg} ->
              send(test_pid, {:call, msg})
              GenServer.reply(from, {2, 3})
              loop.(loop)
          end
        end

        receive_loop.(receive_loop)
      end)

    Process.register(pid, Gatt)

    on_exit(fn ->
      # Unregister synchronously BEFORE killing: Process.exit is async, so
      # relying on pid-death to free the name races the next test's
      # Process.register under the same name.
      if Process.whereis(Gatt) == pid, do: Process.unregister(Gatt)
      Process.exit(pid, :kill)
    end)

    pid
  end

  describe "with Bluez.Gatt not running" do
    test "connect/3 reports a failed connection instead of dropping silently" do
      assert BluetoothProxy.connect(@address, [], self()) == :ok
      assert_receive {:espex_ble_connection, @address, {:error, -1}}
    end

    test "cast-style callbacks are safe no-ops" do
      assert BluetoothProxy.disconnect(@address) == :ok
      assert BluetoothProxy.gatt_get_services(@address) == :ok
      assert BluetoothProxy.gatt_read(@address, 12) == :ok
      assert BluetoothProxy.gatt_write(@address, 12, <<1>>, true) == :ok
      assert BluetoothProxy.gatt_read_descriptor(@address, 13) == :ok
      assert BluetoothProxy.gatt_write_descriptor(@address, 13, <<1, 0>>) == :ok
      assert BluetoothProxy.gatt_notify(@address, 12, true) == :ok
    end

    test "connections_free/0 reports zero free slots with the real limit" do
      assert BluetoothProxy.connections_free() == {0, Gatt.max_connections()}
    end
  end

  describe "with Bluez.Gatt running" do
    setup do
      start_gatt_stub(self())
      :ok
    end

    test "connect/3 forwards to Gatt without a premature error" do
      subscriber = self()
      assert BluetoothProxy.connect(@address, [address_type: 0], subscriber) == :ok
      assert_receive {:cast, {:connect, @address, [address_type: 0], ^subscriber}}
      refute_received {:espex_ble_connection, _, _}
    end

    test "connect/3 refuses a non-48-bit address without reaching Gatt" do
      # uint64 on the wire — values above 0xFFFFFFFFFFFF are not MACs.
      for bad <- [0x1_0000_0000_0000, 0xFFFFFFFFFFFFFFFF] do
        assert BluetoothProxy.connect(bad, [], self()) == :ok
        assert_receive {:espex_ble_connection, ^bad, {:error, -1}}
        refute_received {:cast, _}
      end
    end

    test "GATT callbacks forward address/handle/data unchanged" do
      BluetoothProxy.disconnect(@address)
      assert_receive {:cast, {:disconnect, @address}}

      BluetoothProxy.gatt_get_services(@address)
      assert_receive {:cast, {:get_services, @address}}

      BluetoothProxy.gatt_read(@address, 12)
      assert_receive {:cast, {:read, @address, 12}}

      BluetoothProxy.gatt_write(@address, 12, <<0xAB>>, false)
      assert_receive {:cast, {:write, @address, 12, <<0xAB>>, false}}

      BluetoothProxy.gatt_read_descriptor(@address, 13)
      assert_receive {:cast, {:read_descriptor, @address, 13}}

      BluetoothProxy.gatt_write_descriptor(@address, 13, <<1, 0>>)
      assert_receive {:cast, {:write_descriptor, @address, 13, <<1, 0>>}}

      BluetoothProxy.gatt_notify(@address, 12, true)
      assert_receive {:cast, {:notify, @address, 12, true}}

      BluetoothProxy.pair(@address)
      assert_receive {:cast, {:pair, @address}}

      BluetoothProxy.unpair(@address)
      assert_receive {:cast, {:unpair, @address}}

      BluetoothProxy.clear_cache(@address)
      assert_receive {:cast, {:clear_cache, @address}}
    end

    test "connections_free/0 returns Gatt's answer" do
      assert BluetoothProxy.connections_free() == {2, 3}
      assert_receive {:call, :connections_free}
    end
  end

  describe "behaviour contract" do
    setup do
      # `function_exported?/3` reports false for a not-yet-loaded module. Under
      # a random test seed nothing may have referenced BluetoothProxy before
      # these introspection tests run, so load it explicitly first (otherwise
      # the export checks spuriously fail / pass for the wrong reason).
      Code.ensure_loaded!(BluetoothProxy)
      :ok
    end

    test "exports the Phase 2 optional callbacks (PAIRING + CACHE_CLEARING flags)" do
      # Espex requires BOTH pair/1 and unpair/1 for the PAIRING bit (0x08)
      # and clear_cache/1 for CACHE_CLEARING (0x10) — together with Phase 1
      # this advertises 0x7F, full ESP32-proxy feature parity.
      assert function_exported?(BluetoothProxy, :pair, 1)
      assert function_exported?(BluetoothProxy, :unpair, 1)
      assert function_exported?(BluetoothProxy, :clear_cache, 1)
    end

    test "does NOT export set_connection_params/2 (no org.bluez API for it)" do
      refute function_exported?(BluetoothProxy, :set_connection_params, 2)
    end
  end
end
