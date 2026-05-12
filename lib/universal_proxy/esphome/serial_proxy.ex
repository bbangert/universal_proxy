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

  ## Subscribe / unsubscribe

  Forwarding is gated by an explicit subscribe/unsubscribe toggle that
  matches the ESPHome reference semantics: after `open/3`, the port is
  configured but *no* RX data flows until the client issues a
  `SERIAL_PROXY_REQUEST_TYPE_SUBSCRIBE`. `UNSUBSCRIBE` halts forwarding
  again. Both are handled through `c:Espex.SerialProxy.request/2` and
  routed to the per-instance `Relay`.
  """

  @behaviour Espex.SerialProxy

  require Logger

  alias Espex.SerialProxy.Info
  alias UniversalProxy.ESPHome.SerialProxy.Relay
  alias UniversalProxy.Hardware
  alias UniversalProxy.UART

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
             {:ok, relay} <- start_relay_or_close(path, friendly_name, subscriber) do
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

  # If the UART port opened but the relay can't start, the port would stay
  # registered against this connection forever — release it before bubbling
  # the error.
  defp start_relay_or_close(path, friendly_name, subscriber) do
    case Relay.start_link(path: path, friendly_name: friendly_name, subscriber: subscriber) do
      {:ok, relay} ->
        {:ok, relay}

      {:error, _} = err ->
        _ = UART.close(path)
        err
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

  @impl true
  def request({relay, _path}, :subscribe) do
    :ok = Relay.subscribe(relay)
    {:ok, :ok}
  end

  def request({relay, _path}, :unsubscribe) do
    :ok = Relay.unsubscribe(relay)
    {:ok, :ok}
  end

  def request(_handle, _type), do: {:ok, :not_supported}

  # -- Private --

  # Build the serial-port inventory from `Hardware.list_ports/0` so we
  # surface auto-detected chipset defaults AND user-saved overrides
  # uniformly. The `:ha_name` field on each port matches what Home
  # Assistant's serial picker shows in the Overview UI ("FTDI FT232RL
  # (1-1.1.2)") so the user sees the same label everywhere.
  defp inventory do
    Hardware.list_ports()
    |> Enum.filter(fn port ->
      port.connected and port.configured and port.kind in [:ttl, :rs232, :rs485]
    end)
    |> Enum.map(fn port ->
      %{
        path: port.tty_name,
        friendly_name: port.ha_name,
        port_type: port.kind
      }
    end)
    |> Enum.sort_by(& &1.friendly_name)
  end
end
