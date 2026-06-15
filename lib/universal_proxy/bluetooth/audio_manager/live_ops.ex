defmodule UniversalProxy.Bluetooth.AudioManager.LiveOps do
  @moduledoc """
  Live `org.bluez` implementation of the
  `UniversalProxy.Bluetooth.AudioManager.Ops` behaviour. Thin wrappers over
  `UniversalProxy.Bluez.DBus` on the AudioManager's rebus connection, mirroring
  the call shapes in `UniversalProxy.Bluez.Client`/`Gatt`. Tests use a mock
  instead, so this module carries no logic worth unit-testing — only D-Bus
  marshalling validated on hardware (plan 1.5).
  """

  @behaviour UniversalProxy.Bluetooth.AudioManager.Ops

  alias UniversalProxy.Bluez.{DBus, Variant}
  alias UniversalProxy.Bluetooth.AudioManager

  @adapter_iface "org.bluez.Adapter1"
  @device_iface "org.bluez.Device1"
  @battery_iface "org.bluez.Battery1"
  @props_iface "org.freedesktop.DBus.Properties"

  # Device1.Connect/Pair block until the link is up or BlueZ gives up.
  @connect_timeout 30_000
  @pair_timeout 60_000
  @op_timeout 10_000

  @dev_mac_re ~r"/dev_([0-9A-Fa-f_]{17})$"

  @impl true
  def adapters_info(_conn), do: UniversalProxy.Bluez.Client.adapters_info()

  @impl true
  def managed_devices(conn) do
    case DBus.get_managed_objects(conn, @op_timeout) do
      {:ok, objects} ->
        Enum.flat_map(objects, fn
          {path, ifaces} ->
            case List.keyfind(ifaces, @device_iface, 0) do
              {_iface, props} ->
                case mac_from_path(path) do
                  {:ok, mac} ->
                    [
                      %{
                        path: path,
                        mac: mac,
                        props: Variant.unwrap_props(props),
                        battery: battery_pct(ifaces)
                      }
                    ]

                  :error ->
                    []
                end

              nil ->
                []
            end

          _ ->
            []
        end)

      {:error, _} ->
        []
    end
  end

  @impl true
  def start_discovery(conn, adapter) do
    # Classic BR/EDR + filter to A2DP-sink so the scan list is just headsets.
    filter = [
      {"Transport", {"s", "bredr"}},
      {"UUIDs", {"as", [AudioManager.audio_sink_uuid()]}}
    ]

    with {:ok, _} <-
           DBus.call(conn, adapter, @adapter_iface, "SetDiscoveryFilter", "a{sv}", [filter]),
         {:ok, _} <- ok_or_in_progress(start(conn, adapter)) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp start(conn, adapter),
    do: DBus.call(conn, adapter, @adapter_iface, "StartDiscovery", "", [])

  defp ok_or_in_progress({:error, "org.bluez.Error.InProgress"}), do: {:ok, []}
  defp ok_or_in_progress(other), do: other

  @impl true
  def stop_discovery(conn, adapter) do
    DBus.call(conn, adapter, @adapter_iface, "StopDiscovery", "", []) |> normalize()
  end

  @impl true
  def pair(conn, device_path) do
    DBus.call(conn, device_path, @device_iface, "Pair", "", [], @pair_timeout) |> normalize()
  end

  @impl true
  def set_trusted(conn, device_path, value) when is_boolean(value) do
    DBus.call(conn, device_path, @props_iface, "Set", "ssv", [
      @device_iface,
      "Trusted",
      {"b", value}
    ])
    |> normalize()
  end

  @impl true
  def connect(conn, device_path) do
    DBus.call(conn, device_path, @device_iface, "Connect", "", [], @connect_timeout)
    |> normalize()
  end

  @impl true
  def disconnect(conn, device_path) do
    DBus.call(conn, device_path, @device_iface, "Disconnect", "", [], @op_timeout) |> normalize()
  end

  @impl true
  def remove(conn, adapter, device_path) do
    DBus.call(conn, adapter, @adapter_iface, "RemoveDevice", "o", [device_path], @op_timeout)
    |> normalize()
  end

  defp normalize({:ok, _}), do: :ok
  defp normalize({:error, _} = err), do: err

  # org.bluez exposes a device's battery (via the GATT Battery Service or HFP
  # indicators, gated by bluetoothd's experimental flag) as a separate
  # `Battery1` interface on the same object — present only when the device
  # reports it. `nil` when absent.
  defp battery_pct(ifaces) do
    with {_iface, props} <- List.keyfind(ifaces, @battery_iface, 0),
         pct when is_integer(pct) <- Variant.unwrap_props(props)["Percentage"] do
      pct
    else
      _ -> nil
    end
  end

  defp mac_from_path(path) do
    case Regex.run(@dev_mac_re, path) do
      [_, dev] -> {:ok, dev |> String.replace("_", ":") |> String.upcase()}
      _ -> :error
    end
  end
end
