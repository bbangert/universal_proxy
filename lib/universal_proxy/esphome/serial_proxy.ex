defmodule UniversalProxy.ESPHome.SerialProxy do
  @moduledoc """
  `Espex.SerialProxy` adapter that bridges ESPHome serial-proxy requests
  to the local UART subsystem.

  Inventory is built on demand from the union of saved `UniversalProxy.UART.Store`
  configs and the currently enumerated hardware. Instances are numbered
  in sorted order so the assignment is stable for the lifetime of a
  client connection (espex caches the list at accept time).

  Each opened instance gets a `SerialProxy.Relay` GenServer that subscribes
  to the per-port PubSub topic and forwards incoming bytes to the espex
  connection handler as `{:espex_serial_data, handle, binary}`.
  """

  @behaviour Espex.SerialProxy

  require Logger

  alias Espex.SerialProxy.Info
  alias UniversalProxy.ESPHome.SerialProxy.Relay
  alias UniversalProxy.UART
  alias UniversalProxy.UART.Enumerate, as: UARTEnumerate
  alias UniversalProxy.UART.Store, as: UARTStore

  @impl true
  def list_instances do
    inventory()
    |> Enum.with_index()
    |> Enum.map(fn {entry, idx} ->
      %Info{instance: idx, name: entry.friendly_name, port_type: entry.port_type}
    end)
  end

  @impl true
  def open(instance, opts, subscriber) do
    case Enum.at(inventory(), instance) do
      %{path: path, friendly_name: friendly_name} ->
        with {:ok, _pid} <- UART.open(path, Keyword.put(opts, :friendly_name, friendly_name)),
             {:ok, relay} <-
               Relay.start_link(path: path, friendly_name: friendly_name, subscriber: subscriber) do
          Logger.info(
            "ESPHome serial proxy opened instance #{instance} (#{friendly_name} @ #{path}, #{opts[:speed]} baud)"
          )

          {:ok, {relay, path}}
        else
          {:error, reason} = err ->
            Logger.warning(
              "ESPHome serial proxy failed to open instance #{instance} (#{path}): #{inspect(reason)}"
            )

            err
        end

      nil ->
        {:error, :no_such_instance}
    end
  end

  @impl true
  def write({_relay, path}, data), do: UART.write(path, data)

  @impl true
  def close({relay, path}) do
    if Process.alive?(relay), do: GenServer.stop(relay, :normal, 1_000)

    case UART.close(path) do
      :ok -> :ok
      {:error, _} -> :ok
    end
  end

  # Espex.Connection calls set_modem_pins/3 and get_modem_pins/1 unguarded
  # (no `function_exported?` check), so we provide stubs even though both
  # are declared `@optional_callbacks` in `Espex.SerialProxy`.
  @impl true
  def set_modem_pins(_handle, _rts, _dtr), do: {:error, :not_supported}

  @impl true
  def get_modem_pins(_handle), do: {:error, :not_supported}

  # -- Private --

  defp inventory do
    serial_to_path = UARTEnumerate.serial_to_path(UARTEnumerate.safe())

    UARTStore.all_configs()
    |> Enum.filter(fn config ->
      Map.has_key?(serial_to_path, config[:serial_number]) and
        config[:port_type] not in [:zwave, :infrared]
    end)
    |> Enum.sort_by(fn config -> config[:friendly_name] || "tty#{config[:serial_number]}" end)
    |> Enum.map(fn config ->
      serial = config[:serial_number]

      %{
        path: Map.fetch!(serial_to_path, serial),
        friendly_name: config[:friendly_name] || "tty#{serial}",
        port_type: config[:port_type] || :ttl
      }
    end)
  end
end
