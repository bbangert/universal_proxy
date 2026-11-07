defmodule UniversalProxy.ESPHome.ZigbeeFixtures do
  @moduledoc """
  A `UniversalProxy.ESPHome.ZigbeeProxy` holding a `FakeUART` on a
  realistic ZBT-2 `Hardware` row, wired in as the serial-proxy adapter's
  owner (the `:serial_proxy_zigbee_server` application env). Callers must
  run `async: false`: the env is global.
  """

  import ExUnit.Callbacks, only: [start_supervised!: 2, on_exit: 1]
  import ExUnit.Assertions, only: [assert_receive: 1]

  alias UniversalProxy.ESPHome.ZigbeeProxy
  alias UniversalProxy.ESPHome.ZigbeeProxy.FakeUART
  alias UniversalProxy.Hardware

  @tty "ttyACM0"

  @doc "The tty the fixture row and FakeUART stand for."
  def tty, do: @tty

  @doc """
  A `Hardware.list_ports/1` row for a ZBT-2 on `#{@tty}`, with the
  descriptor ids sysfs would supply (`descriptor` overrides them).
  """
  def zbt2_row(descriptor \\ %{}) do
    [row] =
      Hardware.list_ports(
        slots: nil,
        enumerated: %{
          @tty => %{
            vendor_id: 0x303A,
            product_id: 0x831A,
            manufacturer: "Nabu Casa",
            description: "ZBT-2",
            serial_number: "abcd1234"
          }
        },
        bus_paths: %{@tty => "1-1.3"},
        saved_configs: %{},
        line_settings: %{},
        in_use_ports: MapSet.new(),
        zwave_claim: nil,
        zigbee_claim: nil,
        tty_class_dir: "/nonexistent-#{System.unique_integer([:positive])}"
      )

    %{
      row
      | usb_descriptor:
          Map.merge(
            %{
              bcd_device: 0x0100,
              interface_number: 0,
              interface_class: 0x02,
              interface_description: nil
            },
            descriptor
          )
    }
  end

  @doc """
  Start the owner (`:row` overrides the resolved row, `nil` for none;
  `:on_change` is passed through) and point the adapter at it. Every UART open sends `{:fake_uart, pid}` to
  the caller. Returns `%{server:, fake:, row:}` (`fake: nil` without a row).
  """
  def start_owner!(opts \\ []) do
    test_pid = self()
    row = Keyword.get_lazy(opts, :row, fn -> zbt2_row() end)

    resolver = fn ->
      if row, do: %{path: row.tty_name, display_name: row.ha_name, port: row}
    end

    open_fun =
      Keyword.get(opts, :open_fun, fn _path ->
        {:ok, fake} = FakeUART.start_link(test_pid)
        send(test_pid, {:fake_uart, fake})
        {:ok, fake}
      end)

    server =
      start_supervised!(
        {ZigbeeProxy,
         name: nil,
         resolver: resolver,
         open_fun: open_fun,
         on_change: Keyword.get(opts, :on_change)},
        id: {:zigbee_owner, System.unique_integer()}
      )

    Application.put_env(:universal_proxy, :serial_proxy_zigbee_server, server)
    on_exit(fn -> Application.delete_env(:universal_proxy, :serial_proxy_zigbee_server) end)

    fake =
      if row && !Keyword.has_key?(opts, :open_fun) do
        assert_receive {:fake_uart, fake}
        fake
      end

    # The open runs in handle_continue; a call returns after it.
    _ = ZigbeeProxy.status(server)
    %{server: server, fake: fake, row: row}
  end
end
