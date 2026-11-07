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
  alias UniversalProxy.UART.{PortConfig, SettingsStore}

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

  defp flush_uart_messages do
    receive do
      {:uart_configure, _} -> flush_uart_messages()
    after
      0 -> :ok
    end
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

  describe "configure/2" do
    test "retunes the owner's open tty in place, keeping the session" do
      %{server: server} = ZigbeeFixtures.start_owner!()
      {_instance, handle} = open_zigbee!()
      flush_uart_messages()

      assert SerialProxy.configure(handle, speed: 1200, flow_control: :hardware) == :ok
      assert_receive {:uart_configure, opts}
      assert opts[:speed] == 1200
      refute_received :uart_close
      assert ZigbeeProxy.status(server).attached?
    end

    test "answers an error for a session that is gone" do
      ZigbeeFixtures.start_owner!()
      {_instance, {:zigbee, _} = handle} = open_zigbee!()
      :ok = SerialProxy.close(handle)

      assert {:error, _} = SerialProxy.configure(handle, speed: 1200)
    end
  end

  describe "configure/2 on a UART handle" do
    defmodule FakeUart do
      def close(path) do
        send(Process.get(:test_pid), {:uart_closed, path})
        :ok
      end

      def open(path, opts) do
        send(Process.get(:test_pid), {:uart_opened, path, opts})

        case Process.get(:open_replies, []) do
          [reply | rest] ->
            Process.put(:open_replies, rest)
            reply

          [] ->
            {:ok, self()}
        end
      end

      def port_info(_path), do: Process.get(:port_info, {:error, :not_found})
    end

    setup do
      Process.put(:test_pid, self())
      name = "ttl-#{System.unique_integer([:positive])}"

      entry = %{
        id: name,
        path: "ttyUSB9",
        friendly_name: name,
        serial: nil
      }

      {:ok, relay} =
        UniversalProxy.ESPHome.SerialProxy.Relay.start_link(
          path: entry.path,
          friendly_name: name,
          subscriber: self()
        )

      on_exit(fn -> SettingsStore.delete_opts(name) end)
      %{entry: entry, relay: relay}
    end

    test "reopens the port with the new settings and persists them", %{entry: entry} do
      opts = [speed: 19_200, data_bits: 8, stop_bits: 1, parity: :even, flow_control: :none]

      assert SerialProxy.reconfigure_uart(entry, opts, FakeUart) == :ok
      assert_received {:uart_closed, "ttyUSB9"}
      assert_received {:uart_opened, "ttyUSB9", reopened}
      assert reopened[:speed] == 19_200
      assert reopened[:friendly_name] == entry.friendly_name
      assert SettingsStore.get_opts(entry.id)[:speed] == 19_200
    end

    test "a subscribed relay keeps forwarding across the reopen", %{entry: entry, relay: relay} do
      :ok = UniversalProxy.ESPHome.SerialProxy.Relay.subscribe(relay)
      assert SerialProxy.reconfigure_uart(entry, [speed: 57_600], FakeUart) == :ok

      Phoenix.PubSub.broadcast(
        UniversalProxy.PubSub,
        "uart:#{entry.friendly_name}",
        {:uart_data, %{data: "rx", dir: :rx}}
      )

      assert_receive {:espex_serial_data, {^relay, "ttyUSB9"}, "rx"}
    end

    test "a failed reopen restores the live settings and reports the error", %{entry: entry} do
      Process.put(:port_info, {:ok, PortConfig.new(entry.path, speed: 115_200, parity: :odd)})
      Process.put(:open_replies, [{:error, :eagain}])

      assert SerialProxy.reconfigure_uart(entry, [speed: 9600], FakeUart) == {:error, :eagain}
      assert_received {:uart_closed, "ttyUSB9"}
      assert_received {:uart_opened, "ttyUSB9", attempted}
      assert attempted[:speed] == 9600
      assert_received {:uart_opened, "ttyUSB9", restored}
      assert restored[:speed] == 115_200
      assert restored[:parity] == :odd
      assert restored[:friendly_name] == entry.friendly_name
      assert SettingsStore.get_opts(entry.id) == nil
    end

    test "a failed reopen of a port that wasn't open leaves it closed", %{entry: entry} do
      :ok = SettingsStore.put_opts(SettingsStore, entry.id, speed: 38_400)
      Process.put(:open_replies, [{:error, :eagain}])

      assert SerialProxy.reconfigure_uart(entry, [speed: 9600], FakeUart) == {:error, :eagain}
      assert_received {:uart_opened, "ttyUSB9", attempted}
      assert attempted[:speed] == 9600
      refute_received {:uart_opened, "ttyUSB9", _}
      assert SettingsStore.get_opts(entry.id)[:speed] == 38_400
    end

    test "reports the reconfigure error when the restore fails too", %{entry: entry} do
      Process.put(:port_info, {:ok, PortConfig.new(entry.path, speed: 115_200)})
      Process.put(:open_replies, [{:error, :eagain}, {:error, :enoent}])

      assert SerialProxy.reconfigure_uart(entry, [speed: 9600], FakeUart) == {:error, :eagain}
      assert_received {:uart_opened, "ttyUSB9", _attempted}
      assert_received {:uart_opened, "ttyUSB9", _restored}
    end

    test "nothing to restore without previous settings", %{entry: entry} do
      Process.put(:open_replies, [{:error, :eagain}])

      assert SerialProxy.reconfigure_uart(entry, [speed: 9600], FakeUart) == {:error, :eagain}
      assert_received {:uart_opened, "ttyUSB9", _attempted}
      refute_received {:uart_opened, "ttyUSB9", _}
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

    test "reports the interface description when known" do
      row = ZigbeeFixtures.zbt2_row(%{interface_description: "Home Assistant Connect ZBT-2"})
      inventory = SerialProxy.build_inventory([], Map.put(@attached, :port, row))
      identity = SerialProxy.identity_for(inventory, 0)

      assert identity.usb.interface_description == "Home Assistant Connect ZBT-2"

      decoded =
        identity
        |> Identity.to_proto()
        |> Proto.SerialProxyIdentity.encode()
        |> Proto.SerialProxyIdentity.decode()

      assert decoded.usb.interface_description == "Home Assistant Connect ZBT-2"
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

    test "reports a failing owner as not connected, blank, without the error flag" do
      row = ZigbeeFixtures.zbt2_row()
      inventory = SerialProxy.build_inventory([], %{attached?: false, error?: true, port: row})

      identity = SerialProxy.identity_for(inventory, 0)

      assert %Identity{
               source: :usb,
               connected?: false,
               error?: false,
               manufacturer: "",
               product: "",
               serial_number: "",
               usb: usb
             } = identity

      assert usb == %{}
      assert is_binary(identity |> Identity.to_proto() |> Proto.SerialProxyIdentity.encode())
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

  describe "published owner snapshot" do
    test "a suspended owner keeps the ZBT-2 at the same instance" do
      %{server: server} = ZigbeeFixtures.start_owner!()
      instance = zigbee_instance()
      assert is_integer(instance)

      :sys.suspend(server)

      try do
        assert zigbee_instance() == instance

        assert %Identity{connected?: true, error?: false} = SerialProxy.identity(instance)
      after
        :sys.resume(server)
      end
    end

    test "follows a UART error and the reopen" do
      %{server: server, row: row} = ZigbeeFixtures.start_owner!()
      instance = zigbee_instance()

      send(server, {:circuits_uart, ZigbeeFixtures.tty(), {:error, :eio}})
      _ = ZigbeeProxy.status(server)

      assert ZigbeeProxy.advertised(server) == %{attached?: false, error?: true, port: row}
      assert zigbee_instance() == instance

      assert %Identity{connected?: false, error?: false, product: ""} =
               SerialProxy.identity(instance)

      send(server, :zigbee_reopen)
      assert_receive {:fake_uart, _fake}
      _ = ZigbeeProxy.status(server)

      assert ZigbeeProxy.advertised(server) == %{attached?: true, error?: false, port: row}
    end

    test "an unplug with the owner running keeps every instance number" do
      %{server: server, row: row} = ZigbeeFixtures.start_owner!()
      ports = [ttl_row("Zeta (1-1.4)", "ttyUSB1"), ttl_row("Alpha (1-1.2)", "ttyUSB0")]

      names = fn ->
        ports
        |> SerialProxy.build_inventory(ZigbeeProxy.advertised(server))
        |> Enum.map(& &1.friendly_name)
      end

      before = names.()
      assert before == ["Alpha (1-1.2)", row.ha_name, "Zeta (1-1.4)"]
      instance = zigbee_instance()

      # Unplugged: the tty errors, then the resolver finds nothing.
      :sys.replace_state(server, &%{&1 | resolver: fn -> nil end})
      send(server, {:circuits_uart, ZigbeeFixtures.tty(), {:error, :eio}})
      send(server, :zigbee_reopen)
      _ = ZigbeeProxy.status(server)

      assert names.() == before
      assert zigbee_instance() == instance
      assert %Identity{connected?: false, usb: usb} = SerialProxy.identity(instance)
      assert usb == %{}

      # The kept row never reopens its old tty.
      assert {:error, :not_attached} = SerialProxy.open(instance, [], self())
      send(server, :zigbee_reopen)
      _ = ZigbeeProxy.status(server)
      refute_received {:fake_uart, _}
    end

    test "is erased when the owner stops" do
      %{server: server} = ZigbeeFixtures.start_owner!()
      assert %{attached?: true} = ZigbeeProxy.advertised(server)

      GenServer.stop(server)

      assert :persistent_term.get({ZigbeeProxy, :advertised, server}, :erased) == :erased
      assert ZigbeeProxy.advertised(server) == %{attached?: false, error?: false, port: nil}
      assert zigbee_instance() == nil
    end
  end
end
