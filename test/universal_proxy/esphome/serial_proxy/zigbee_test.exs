defmodule UniversalProxy.ESPHome.SerialProxy.ZigbeeTest do
  # The ZBT-2 side of the serial-proxy adapter: inventory, handle routing
  # to the ZigbeeProxy owner, set_mode, default_open_opts and identity.
  # async: false — the adapter finds its owner through the global
  # application env (ZigbeeFixtures.start_owner!/1).
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Espex.Proto
  alias Espex.SerialProxy.{Identity, Info}
  alias UniversalProxy.ESPHome.{SerialProxy, ZigbeeFixtures, ZigbeeProxy}
  alias UniversalProxy.UART.SettingsStore

  @attached %{attached?: true, error?: false}

  defp ttl_row(name, tty) do
    %{
      id: "usb-#{tty}",
      tty_name: tty,
      ha_name: name,
      kind: :ttl,
      connected: true,
      configured: true,
      serial: "S-#{tty}"
    }
  end

  defp zigbee_instance do
    Enum.find_index(SerialProxy.list_instances(), &(&1.port_type == :usb_serial))
  end

  defp open_zigbee!(opts \\ []) do
    instance = zigbee_instance()
    assert {:ok, {:zigbee, ref} = handle} = SerialProxy.open(instance, opts, self())
    assert is_reference(ref)
    {instance, handle}
  end

  describe "inventory" do
    test "advertises the owner's ZBT-2 as USB_SERIAL driving RTS and DTR" do
      %{row: row} = ZigbeeFixtures.start_owner!()

      info = Enum.at(SerialProxy.list_instances(), zigbee_instance())

      assert %Info{name: name, port_type: :usb_serial, configured_line_states: [:rts, :dtr]} =
               info

      assert name == row.ha_name

      proto = Info.to_proto(info)
      assert proto.port_type == :SERIAL_PROXY_PORT_TYPE_USB_SERIAL
      assert proto.configured_line_states == 3
    end

    test "has no ZBT-2 when the owner holds none" do
      ZigbeeFixtures.start_owner!(row: nil)

      assert zigbee_instance() == nil

      assert SerialProxy.build_inventory([], %{attached?: false, error?: false, port: nil}) == []
    end

    test "keeps the row while the owner's open is failing" do
      row = ZigbeeFixtures.zbt2_row()
      status = %{attached?: false, error?: true, port: row}

      assert [%{kind: :zigbee, attached?: false, error?: true}] =
               SerialProxy.build_inventory([], status)
    end

    test "never advertises :zigbee rows from list_ports, only the owner's" do
      row = ZigbeeFixtures.zbt2_row()

      assert SerialProxy.build_inventory([row], %{attached?: false, error?: false, port: nil}) ==
               []
    end

    test "order is deterministic with the ZBT-2 present" do
      zbt2 = ZigbeeFixtures.zbt2_row()
      ports = [ttl_row("Zeta (1-1.4)", "ttyUSB1"), ttl_row("Alpha (1-1.2)", "ttyUSB0")]
      status = Map.put(@attached, :port, zbt2)

      names =
        for ports <- [ports, Enum.reverse(ports)] do
          ports |> SerialProxy.build_inventory(status) |> Enum.map(& &1.friendly_name)
        end

      assert names == [
               ["Alpha (1-1.2)", zbt2.ha_name, "Zeta (1-1.4)"],
               ["Alpha (1-1.2)", zbt2.ha_name, "Zeta (1-1.4)"]
             ]
    end

    test "TTL rows keep their kind and advertise no modem lines" do
      [entry] = SerialProxy.build_inventory([ttl_row("A (1-1.2)", "ttyUSB0")], %{port: nil})
      assert %{kind: :uart, port_type: :ttl, line_states: []} = entry
    end
  end

  describe "handle routing" do
    test "open attaches a session; close detaches it without closing the tty" do
      %{server: server} = ZigbeeFixtures.start_owner!()
      {_instance, handle} = open_zigbee!()

      assert SerialProxy.close(handle) == :ok
      refute_received :uart_close
      assert ZigbeeProxy.status(server).attached?
    end

    test "open fails with the owner's reason when it holds no tty" do
      ZigbeeFixtures.start_owner!(open_fun: fn _path -> {:error, :eacces} end)
      instance = zigbee_instance()

      assert {:error, :not_attached} = SerialProxy.open(instance, [], self())
    end

    test "subscribe delivers RX, write reaches the UART, unsubscribe stops RX" do
      %{server: server} = ZigbeeFixtures.start_owner!()
      {_instance, {:zigbee, ref} = handle} = open_zigbee!()

      assert SerialProxy.request(handle, :subscribe) == {:ok, :ok}
      send(server, {:circuits_uart, ZigbeeFixtures.tty(), "ncp"})
      assert_receive {:espex_serial_data, {:zigbee, ^ref}, "ncp"}

      assert SerialProxy.write(handle, "host") == :ok
      assert_receive {:uart_write, "host"}

      assert SerialProxy.request(handle, :unsubscribe) == {:ok, :ok}
      send(server, {:circuits_uart, ZigbeeFixtures.tty(), "late"})
      _ = :sys.get_state(server)
      refute_received {:espex_serial_data, _, "late"}
    end

    test "a second session's subscribe answers PORT_IN_USE" do
      ZigbeeFixtures.start_owner!()
      {_instance, first} = open_zigbee!()
      {_instance, second} = open_zigbee!()

      assert SerialProxy.request(first, :subscribe) == {:ok, :ok}
      assert SerialProxy.request(second, :subscribe) == {:ok, :port_in_use}
    end

    test "flush stays NOT_SUPPORTED" do
      ZigbeeFixtures.start_owner!()
      {_instance, handle} = open_zigbee!()
      assert SerialProxy.request(handle, :flush) == {:ok, :not_supported}
    end

    test "modem pins go to the owner" do
      ZigbeeFixtures.start_owner!()
      {_instance, handle} = open_zigbee!()

      assert SerialProxy.get_modem_pins(handle) == {:ok, %{rts: true, dtr: true}}
      assert SerialProxy.set_modem_pins(handle, false, true) == :ok
      assert_receive {:uart_set_rts, false}
      refute_received {:uart_set_dtr, _}
      assert SerialProxy.get_modem_pins(handle) == {:ok, %{rts: false, dtr: true}}
    end

    test "set_mode PROTOCOL goes to the owner and needs the subscription" do
      %{server: server} = ZigbeeFixtures.start_owner!()
      {_instance, handle} = open_zigbee!()

      assert SerialProxy.set_mode(handle, :protocol) == {:error, :port_in_use}
      {:ok, :ok} = SerialProxy.request(handle, :subscribe)
      assert SerialProxy.set_mode(handle, :protocol) == :ok
      assert :sys.get_state(server).mode == :protocol
      assert SerialProxy.set_mode(handle, :raw) == :ok
    end
  end

  describe "non-Zigbee handles" do
    @ttl_handle {:relay, "ttyUSB0"}

    test "set_mode is RAW only" do
      assert SerialProxy.set_mode(@ttl_handle, :raw) == :ok
      assert SerialProxy.set_mode(@ttl_handle, :protocol) == {:error, :not_supported}
    end

    test "modem pins stay NOT_SUPPORTED" do
      assert SerialProxy.set_modem_pins(@ttl_handle, true, true) == {:error, :not_supported}
      assert SerialProxy.get_modem_pins(@ttl_handle) == {:error, :not_supported}
    end
  end

  describe "default_open_opts/1" do
    test "serves the owner's live line settings" do
      ZigbeeFixtures.start_owner!()
      instance = zigbee_instance()

      assert SerialProxy.default_open_opts(instance) ==
               [speed: 460_800, data_bits: 8, stop_bits: 1, parity: :none, flow_control: :none]

      {_instance, _handle} = open_zigbee!(speed: 1200)
      assert_receive {:uart_configure, _}

      assert SerialProxy.default_open_opts(instance)[:speed] == 1200
    end

    test "persists nothing for the ZBT-2" do
      %{row: row} = ZigbeeFixtures.start_owner!()
      before = SettingsStore.get_opts(row.id)

      {_instance, handle} = open_zigbee!(speed: 150)
      :ok = SerialProxy.close(handle)

      assert SettingsStore.get_opts(row.id) == before
    end
  end

  describe "identity/1" do
    test "meets Home Assistant's ZBT-2 USB matcher" do
      ZigbeeFixtures.start_owner!()

      identity = SerialProxy.identity(zigbee_instance())

      assert %Identity{source: :usb, connected?: true, error?: false} = identity
      assert identity.usb.vendor_id == 0x303A
      assert identity.usb.product_id in [0x4001, 0x831A]
      assert String.downcase(identity.product) =~ "zbt-2"
      assert identity.manufacturer == "Nabu Casa"
      assert identity.serial_number == "abcd1234"

      assert identity.usb == %{
               vendor_id: 0x303A,
               product_id: 0x831A,
               bcd_device: 0x0100,
               interface_number: 0,
               interface_class: 0x02
             }

      proto = identity |> Identity.to_proto() |> Proto.SerialProxyIdentity.encode()
      decoded = Proto.SerialProxyIdentity.decode(proto)

      assert decoded.source == :SERIAL_PROXY_IDENTITY_SOURCE_USB
      assert decoded.flags == 1
      assert decoded.product == "ZBT-2"
      assert decoded.usb.vendor_id == 0x303A
      assert decoded.usb.interface_class == 0x02
    end

    test "omits unknown descriptor ids, so the identity still encodes" do
      row =
        ZigbeeFixtures.zbt2_row(%{bcd_device: nil, interface_number: nil, interface_class: nil})

      inventory = SerialProxy.build_inventory([], Map.put(@attached, :port, row))
      identity = SerialProxy.identity_for(inventory, 0)

      assert identity.usb == %{vendor_id: 0x303A, product_id: 0x831A}

      decoded =
        identity
        |> Identity.to_proto()
        |> Proto.SerialProxyIdentity.encode()
        |> Proto.SerialProxyIdentity.decode()

      assert decoded.usb.interface_number == 0
    end

    test "a missing descriptor and serial report empty strings and only VID/PID" do
      row = %{ZigbeeFixtures.zbt2_row() | usb_descriptor: nil, serial: "—"}
      inventory = SerialProxy.build_inventory([], Map.put(@attached, :port, row))
      identity = SerialProxy.identity_for(inventory, 0)

      assert identity.serial_number == ""
      assert identity.usb == %{vendor_id: 0x303A, product_id: 0x831A}
      assert is_binary(identity |> Identity.to_proto() |> Proto.SerialProxyIdentity.encode())
    end

    test "reports a failing owner as not connected, with the error flag" do
      row = ZigbeeFixtures.zbt2_row()
      inventory = SerialProxy.build_inventory([], %{attached?: false, error?: true, port: row})

      assert %Identity{connected?: false, error?: true} = SerialProxy.identity_for(inventory, 0)
    end

    test "is nil for TTL ports and unknown instances" do
      zbt2 = ZigbeeFixtures.zbt2_row()

      inventory =
        SerialProxy.build_inventory(
          [ttl_row("Alpha (1-1.2)", "ttyUSB0")],
          Map.put(@attached, :port, zbt2)
        )

      assert SerialProxy.identity_for(inventory, 0) == nil
      assert %Identity{} = SerialProxy.identity_for(inventory, 1)
      assert SerialProxy.identity_for(inventory, 2) == nil
      assert SerialProxy.identity(99) == nil
    end
  end
end
