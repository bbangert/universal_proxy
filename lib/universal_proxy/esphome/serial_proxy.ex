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
  again; since espex 0.11 it also closes the handle (`close/1`) and
  releases the instance for the next client. Both are handled through
  `c:Espex.SerialProxy.request/2` and routed to the per-instance `Relay`.

  espex 0.11 enforces the API 1.17 single-owner rule: the connection
  that SUBSCRIBEs an instance owns it, and a second connection's
  SUBSCRIBE is refused with PORT_IN_USE until the owner unsubscribes or
  disconnects. Every other operation (configure, write, modem pins,
  flush, set mode) is accepted only from the owner — a non-owner's write
  is dropped and the rest are refused with PORT_IN_USE. For the owner,
  the first operation against an advertised-but-unopened instance still
  lazily opens it via `open/3`, and the subscribe intent is reattached
  (another `request/2` call) after every successful open. A client
  resuming after a proxy restart (e.g. Home Assistant talking to a
  Zigbee coordinator) re-SUBSCRIBEs on its new connection and can then
  write without re-sending CONFIGURE first.

  ## Persisted line settings

  A lazily-opened instance has no CONFIGURE to draw options from, so
  `default_open_opts/1` below serves the settings the port was last
  successfully opened with (persisted in `SettingsStore`) instead of
  espex's 9600-8-N-1 fallback. Real ESPHome hardware retains its UART
  settings across a client reconnect, so this keeps a resumed connection
  talking at the baud rate the attached device actually expects.

  ## Home Assistant Connect ZBT-2

  The ZBT-2 that `UniversalProxy.ESPHome.ZigbeeProxy` holds is advertised
  as a `:usb_serial` port that drives RTS and DTR from the owner's first
  resolved row until the owner stops, including while the tty is closed
  after an error or an unplug. Keeping the row keeps every instance
  number stable for connected clients (an unplug renumbers only when the
  hotplug restart of the ESPHome tree drops them); meanwhile the identity
  reports it not connected, with blank strings and no USB ids, and an
  open answers `:not_attached`.

  Its handles are `{:zigbee, session}`: `open/3` attaches a session to
  the owner and `close/1` detaches it, so the tty (and its DTR/RTS) stay
  put across sessions and CONFIGUREs. Subscribe, writes, modem pins and
  `set_mode/2` go to the owner, which runs the ASH acknowledger in
  `:protocol` mode. `default_open_opts/1` serves the owner's live line
  settings (a lazy open is then a no-op) and nothing is persisted, since
  a flasher's magic-baud CONFIGUREs are signalling, not settings.

  `identity/1` reports the USB identity Home Assistant's ZBT-2 discovery
  matches on. Every other port reports none: an identity on our
  CP210x/CH34x adapters would match ZHA's USB matchers and offer them as
  Zigbee radios.

  `identity/1` only answers a client's identity subscription. The owner
  attaches and detaches without an ESPHome tree restart (a UART error
  and the reopen after it, or a first open that fails and later
  succeeds), so it calls `push_zigbee_identity/1` whenever its attach
  state or row changes, and subscribed clients see each change live.
  """

  @behaviour Espex.SerialProxy

  require Logger

  alias Espex.SerialProxy.{Identity, Info}
  alias UniversalProxy.ESPHome.SerialProxy.Relay
  alias UniversalProxy.ESPHome.ZigbeeProxy
  alias UniversalProxy.Hardware
  alias UniversalProxy.UART
  alias UniversalProxy.UART.{PortConfig, SettingsStore}

  @impl true
  def list_instances do
    inventory()
    |> Enum.with_index()
    |> Enum.map(fn {entry, idx} ->
      %Info{
        instance: idx,
        name: entry.friendly_name,
        port_type: entry.port_type,
        configured_line_states: entry.line_states
      }
    end)
  end

  @impl true
  def open(instance, opts, subscriber) do
    case Enum.at(inventory(), instance) do
      %{kind: :zigbee} = entry ->
        open_zigbee(instance, entry, opts, subscriber)

      %{id: id, path: path, friendly_name: friendly_name, serial: serial} ->
        with {:ok, _pid} <- UART.open(path, Keyword.put(opts, :friendly_name, friendly_name)),
             {:ok, relay} <- start_relay_or_close(path, friendly_name, subscriber) do
          Logger.info(
            "ESPHome serial proxy opened instance #{instance} (#{friendly_name} @ #{path}, #{opts[:speed]} baud)"
          )

          persist_opts(id, opts, serial)

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
    case Enum.at(inventory(), instance) do
      # Live, not persisted: a stale value would retune the ZBT-2's line
      # on every lazy open.
      %{kind: :zigbee} ->
        ZigbeeProxy.current_opts(zigbee_proxy())

      %{id: id} ->
        case get_stored_opts(id) do
          opts when is_list(opts) -> opts
          _ -> Espex.SerialProxy.default_open_opts()
        end

      nil ->
        Espex.SerialProxy.default_open_opts()
    end
  end

  @impl true
  def identity(instance), do: identity_for(inventory(), instance)

  # Pure core of `identity/1`, over a `build_inventory/2` result.
  @doc false
  def identity_for(inventory, instance) do
    case Enum.at(inventory, instance) do
      %{kind: :zigbee} = entry -> zigbee_identity(instance, entry)
      _ -> nil
    end
  end

  @doc """
  Push the ZBT-2's current identity to espex's subscribed clients, under
  the instance number `list_instances/0` advertises for it.

  A no-op without a ZBT-2 row, or while espex (`server`, default
  `Espex.Server`) isn't running.
  """
  @spec push_zigbee_identity(atom()) :: :ok
  def push_zigbee_identity(server \\ Espex.Server) do
    inventory = inventory()

    case Enum.find_index(inventory, &(&1.kind == :zigbee)) do
      nil -> :ok
      instance -> push_identity(server, identity_for(inventory, instance))
    end
  end

  # `Registry.dispatch/3` raises, not exits, when espex's registry isn't
  # started (early boot: the owner starts before Espex).
  defp push_identity(server, identity) do
    Espex.push_serial_proxy_identity(server, identity)
  rescue
    ArgumentError -> :ok
  end

  # No `persist_opts`: the owner keeps the line settings itself.
  defp open_zigbee(instance, entry, opts, subscriber) do
    case ZigbeeProxy.attach(zigbee_proxy(), opts, subscriber) do
      {:ok, session} ->
        Logger.info(
          "ESPHome serial proxy opened instance #{instance} (#{entry.friendly_name} @ #{entry.path}, #{opts[:speed]} baud)"
        )

        {:ok, {:zigbee, session}}

      {:error, reason} = err ->
        Logger.warning(
          "ESPHome serial proxy failed to open instance #{instance} (#{entry.path}): #{inspect(reason)}"
        )

        err
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

  # Zigbee clauses come first throughout: `{:zigbee, session}` would also
  # match the `{relay, path}` patterns.
  @impl true
  def write({:zigbee, session}, data), do: ZigbeeProxy.write(zigbee_proxy(), session, data)
  def write({_relay, path}, data), do: UART.write(path, data)

  @impl true
  def close({:zigbee, session}) do
    _ = ZigbeeProxy.detach(zigbee_proxy(), session)
    :ok
  end

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

  # In place from espex's side: the handle, subscription and mode stay.
  # The ZBT-2 retunes its open tty (no close, so DTR/RTS hold). A UART
  # port is reopened under the same relay, which keeps its PubSub
  # subscription, so a subscribed relay keeps forwarding and the handle
  # stays valid; only the `Circuits.UART` process is replaced, as the
  # close+open it replaces did.
  @impl true
  def configure({:zigbee, session}, opts),
    do: ZigbeeProxy.configure(zigbee_proxy(), session, opts)

  def configure({_relay, path}, opts) do
    case Enum.find(inventory(), &(&1.path == path)) do
      nil -> {:error, :no_such_instance}
      entry -> reconfigure_uart(entry, opts, UART)
    end
  end

  # `uart` is the module owning the tty (injectable for tests). A reopen
  # that fails goes back to the settings an open port had, so a rejected
  # CONFIGURE never leaves the tty closed under a live handle; the
  # CONFIGURE itself still fails.
  @doc false
  def reconfigure_uart(%{id: id, path: path, friendly_name: name, serial: serial}, opts, uart) do
    previous = previous_opts(uart, path)
    _ = uart.close(path)

    case uart.open(path, Keyword.put(opts, :friendly_name, name)) do
      {:ok, _pid} ->
        persist_opts(id, opts, serial)
        :ok

      {:error, reason} = err ->
        Logger.warning("ESPHome serial proxy failed to reconfigure #{path}: #{inspect(reason)}")
        restore_uart(uart, path, name, previous)
        err
    end
  end

  # The open port's live settings, or nil when it wasn't open: a port that
  # was already closed has no previous state to go back to.
  defp previous_opts(uart, path) do
    case uart.port_info(path) do
      {:ok, %PortConfig{} = config} -> PortConfig.to_uart_opts(config)
      _ -> nil
    end
  end

  defp restore_uart(_uart, _path, _name, nil), do: :ok

  defp restore_uart(uart, path, name, previous) do
    case uart.open(path, Keyword.put(previous, :friendly_name, name)) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "ESPHome serial proxy failed to reopen #{path} with its previous settings: #{inspect(reason)}"
        )
    end
  end

  # espex 0.8 guards both set_modem_pins/3 and get_modem_pins/1 with
  # function_exported? and would otherwise fall back to its own
  # omitted-callback default (all lines low / no-op). Only the ZBT-2
  # drives its lines; every other port answers NOT_SUPPORTED explicitly
  # rather than relying on that fallback.
  @impl true
  def set_modem_pins({:zigbee, session}, rts, dtr),
    do: ZigbeeProxy.set_modem_pins(zigbee_proxy(), session, rts, dtr)

  def set_modem_pins(_handle, _rts, _dtr), do: {:error, :not_supported}

  @impl true
  def get_modem_pins({:zigbee, session}), do: ZigbeeProxy.get_modem_pins(zigbee_proxy(), session)
  def get_modem_pins(_handle), do: {:error, :not_supported}

  @doc """
  Switch a port between RAW and PROTOCOL mode. Only the ZBT-2 has a
  protocol handler (the ASH acknowledger); every other port is RAW only.
  """
  @impl true
  def set_mode({:zigbee, session}, mode), do: ZigbeeProxy.set_mode(zigbee_proxy(), session, mode)
  def set_mode(_handle, :raw), do: :ok
  def set_mode(_handle, :protocol), do: {:error, :not_supported}

  @doc """
  Handle an `Espex.SerialProxy` request.

  Routes `:subscribe` and `:unsubscribe` to the per-instance `Relay` to
  toggle UART RX forwarding (ESPHome `SerialProxyRequest` semantics).
  Any unknown request type returns `{:ok, :not_supported}` so the espex
  layer can respond to the client without crashing.
  """
  @impl true
  def request({:zigbee, session}, :subscribe) do
    zigbee_status(ZigbeeProxy.subscribe(zigbee_proxy(), session))
  end

  def request({:zigbee, session}, :unsubscribe) do
    zigbee_status(ZigbeeProxy.unsubscribe(zigbee_proxy(), session))
  end

  def request({relay, _path}, :subscribe) do
    :ok = Relay.subscribe(relay)
    {:ok, :ok}
  end

  def request({relay, _path}, :unsubscribe) do
    :ok = Relay.unsubscribe(relay)
    {:ok, :ok}
  end

  def request(_handle, _type), do: {:ok, :not_supported}

  # espex logs these answers (the ack is OK regardless), so keep the
  # statuses it has names for.
  defp zigbee_status(:ok), do: {:ok, :ok}
  defp zigbee_status({:error, status}) when status in [:port_in_use, :timeout], do: {:ok, status}
  defp zigbee_status({:error, _reason} = error), do: error

  # -- Private --

  # The owner's registered name; tests point it at their own instance.
  defp zigbee_proxy,
    do: Application.get_env(:universal_proxy, :serial_proxy_zigbee_server, ZigbeeProxy)

  # Build the serial-port inventory from `Hardware.list_ports/1` so we
  # surface auto-detected chipset defaults AND user-saved overrides
  # uniformly. The `:ha_name` field on each port matches what Home
  # Assistant's serial picker shows in the Overview UI ("FTDI FT232RL
  # (1-1.1.2)") so the user sees the same label everywhere.
  #
  # Both reads stay off the owners' mailboxes: these run in the espex
  # connection process inside Home Assistant's open budget, and a busy
  # owner must not drop the ZBT-2 row (shifting every later instance
  # number). The proxies' claims only label ports in use, which nothing
  # here reads.
  defp inventory do
    build_inventory(
      Hardware.list_ports(zwave_claim: nil, zigbee_claim: nil),
      ZigbeeProxy.advertised(zigbee_proxy())
    )
  end

  # Pure core of `inventory/0`: `ports` from `Hardware.list_ports/1`,
  # `zigbee` from `ZigbeeProxy.advertised/1`. The ZBT-2 comes from the owner's
  # own row, never from `ports`, so only the one it holds is advertised.
  @doc false
  def build_inventory(ports, zigbee) do
    ports
    |> Enum.filter(fn port ->
      port.connected and port.configured and port.kind in [:ttl, :rs232, :rs485]
    end)
    |> Enum.map(fn port ->
      %{
        kind: :uart,
        id: port.id,
        path: port.tty_name,
        friendly_name: port.ha_name,
        port_type: port.kind,
        line_states: [],
        # The device's USB serial, tagging persisted line settings so a
        # delayed unplug-clear can never wipe a different adapter's write
        # (list_ports renders missing serials as an em-dash placeholder).
        serial: usb_serial(port.serial)
      }
    end)
    |> Kernel.++(zigbee_entries(zigbee))
    |> Enum.sort_by(&{&1.friendly_name, &1.path})
  end

  defp zigbee_entries(%{port: %{ha_name: name, tty_name: tty} = port} = status)
       when is_binary(name) and is_binary(tty) do
    [
      %{
        kind: :zigbee,
        id: Map.get(port, :id),
        path: tty,
        friendly_name: name,
        port_type: :usb_serial,
        line_states: [:rts, :dtr],
        serial: usb_serial(Map.get(port, :serial)),
        port: port,
        attached?: status.attached?,
        error?: status.error?
      }
    ]
  end

  defp zigbee_entries(_status), do: []

  defp usb_serial("—"), do: nil
  defp usb_serial(serial), do: serial

  # What Home Assistant's ZBT-2 matcher reads: VID/PID and the product
  # string, plus the serial (its config-flow unique id). espex copies `usb`
  # into the protobuf as given, so unknown ids are left out, never nil.
  #
  # Per espex's Identity contract, `error?` means the USB host stack refused
  # the descriptor query (strings and ids then empty), not that our tty
  # open failed; while the device isn't attached the `:usb` strings are
  # blank and `usb` is empty.
  defp zigbee_identity(instance, %{attached?: false}) do
    %Identity{
      instance: instance,
      source: :usb,
      connected?: false,
      error?: false,
      manufacturer: "",
      product: "",
      serial_number: "",
      usb: %{}
    }
  end

  defp zigbee_identity(instance, entry) do
    port = entry.port
    descriptor = Map.get(port, :usb_descriptor) || %{}

    usb =
      %{
        vendor_id: Map.get(port, :vendor_id),
        product_id: Map.get(port, :product_id),
        bcd_device: descriptor[:bcd_device],
        interface_number: descriptor[:interface_number],
        interface_class: descriptor[:interface_class]
      }
      |> Map.filter(fn {_key, value} -> is_integer(value) end)

    %Identity{
      instance: instance,
      source: :usb,
      connected?: true,
      error?: false,
      manufacturer: Map.get(port, :usb_manufacturer) || "",
      product: Map.get(port, :usb_product) || "",
      serial_number: entry.serial || "",
      usb: usb_with_interface_description(usb, descriptor[:interface_description])
    }
  end

  defp usb_with_interface_description(usb, description)
       when is_binary(description) and description != "",
       do: Map.put(usb, :interface_description, description)

  defp usb_with_interface_description(usb, _description), do: usb

  # Best-effort: a `SettingsStore` hiccup (down, wedged, or DETS write
  # failure) must not fail an otherwise-good open. Follows this project's
  # public-API `catch :exit` idiom (CLAUDE.md) — a wedged store degrades
  # to "settings not persisted" rather than failing the connection.
  defp persist_opts(id, opts, serial) do
    # Explicit server arg: put_opts/4 defaults BOTH its first and last
    # params, so a 3-arg call binds `id` as the server (dialyzer-caught).
    case SettingsStore.put_opts(SettingsStore, id, opts, serial) do
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
