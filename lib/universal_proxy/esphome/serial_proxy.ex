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

  espex 0.8 tracks subscribe *intent* per connection rather than a
  one-shot stash: the client's first operation of any kind (write,
  subscribe, modem pins, flush) against an advertised-but-unopened
  instance lazily opens it via `open/3`, and a previously-set subscribe
  intent is reattached (another `request/2` call) after *every*
  successful open — whether that open was triggered by CONFIGURE or by
  the lazy path. This lets a client resume traffic (e.g. Home Assistant
  writing to a Zigbee coordinator, or re-subscribing) after a proxy
  restart without re-sending CONFIGURE first.

  ## Persisted line settings

  A lazily-opened instance has no CONFIGURE to draw options from, so
  `default_open_opts/1` below serves the settings the port was last
  successfully opened with (persisted in `SettingsStore`) instead of
  espex's 9600-8-N-1 fallback. Real ESPHome hardware retains its UART
  settings across a client reconnect, so this keeps a resumed connection
  talking at the baud rate the attached device actually expects.
  """

  @behaviour Espex.SerialProxy

  require Logger

  alias Espex.SerialProxy.Info
  alias UniversalProxy.ESPHome.SerialProxy.Relay
  alias UniversalProxy.ESPHome.SerialProxy.SettingsStore
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
      %{id: id, path: path, friendly_name: friendly_name} ->
        with {:ok, _pid} <- UART.open(path, Keyword.put(opts, :friendly_name, friendly_name)),
             {:ok, relay} <- start_relay_or_close(path, friendly_name, subscriber) do
          Logger.info(
            "ESPHome serial proxy opened instance #{instance} (#{friendly_name} @ #{path}, #{opts[:speed]} baud)"
          )

          persist_opts(id, opts)

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
  def default_open_opts(instance) do
    # espex 0.8 calls this when a client operates on an advertised
    # instance without a prior CONFIGURE on this connection (e.g. HA
    # resuming after a proxy restart). Serve the settings the port was
    # last successfully opened with; fall back to espex's 9600-8-N-1.
    with %{id: id} <- Enum.at(inventory(), instance),
         opts when is_list(opts) <- get_stored_opts(id) do
      opts
    else
      _ -> Espex.SerialProxy.default_open_opts()
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
    # No alive?-guard: it was a TOCTOU (the relay can die between the
    # check and the stop). Stopping an already-dead process exits with
    # :noproc — catch it and move on; close is idempotent.
    try do
      GenServer.stop(relay, :normal, 1_000)
    catch
      :exit, _ -> :ok
    end

    case UART.close(path) do
      :ok -> :ok
      {:error, _} -> :ok
    end
  end

  # espex 0.8 guards both set_modem_pins/3 and get_modem_pins/1 with
  # function_exported? and would otherwise fall back to its own
  # omitted-callback default (all lines low / no-op). We keep these stubs
  # anyway to answer NOT_SUPPORTED explicitly rather than relying on that
  # fallback.
  @impl true
  def set_modem_pins(_handle, _rts, _dtr), do: {:error, :not_supported}

  @impl true
  def get_modem_pins(_handle), do: {:error, :not_supported}

  @doc """
  Handle an `Espex.SerialProxy` request.

  Routes `:subscribe` and `:unsubscribe` to the per-instance `Relay` to
  toggle UART RX forwarding (ESPHome `SerialProxyRequest` semantics).
  Any unknown request type returns `{:ok, :not_supported}` so the espex
  layer can respond to the client without crashing.
  """
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
        id: port.id,
        path: port.tty_name,
        friendly_name: port.ha_name,
        port_type: port.kind
      }
    end)
    |> Enum.sort_by(& &1.friendly_name)
  end

  # Best-effort: a `SettingsStore` hiccup (down, wedged, or DETS write
  # failure) must not fail an otherwise-good open. Follows this project's
  # public-API `catch :exit` idiom (CLAUDE.md) — a wedged store degrades
  # to "settings not persisted" rather than failing the connection.
  defp persist_opts(id, opts) do
    case SettingsStore.put_opts(id, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("ESPHome serial settings store write failed for #{id}: #{inspect(reason)}")
    end
  catch
    :exit, reason ->
      Logger.warning("ESPHome serial settings store unavailable for #{id}: #{inspect(reason)}")
  end

  # Same idiom as persist_opts/2: a down/wedged store must degrade to the
  # espex default, not crash the espex connection process.
  defp get_stored_opts(id) do
    SettingsStore.get_opts(id)
  catch
    :exit, _ -> nil
  end
end
