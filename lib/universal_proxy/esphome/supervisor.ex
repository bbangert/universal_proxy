defmodule UniversalProxy.ESPHome.Supervisor do
  @moduledoc """
  Supervisor that wires our hardware adapters into the `Espex` ESPHome
  Native API server.

  Children, started in `:rest_for_one` order:

    1. `ZWaveProxy.Advertiser` — the `_zwave._tcp` mDNS advertisement,
       kept off the UART owner because MdnsLite calls can block
    2. `ZWaveProxy` — GenServer that owns the Z-Wave UART port and
       implements the `Espex.ZWaveProxy` behaviour
    3. `ZigbeeProxy` — GenServer that holds the ZBT-2's tty open and
       serves serial-proxy sessions on it
    4. `Infrared.Supervisor` — DynamicSupervisor + `Infrared.Server`
       (the `Espex.InfraredProxy` adapter)
    5. `Espex` — the library supervisor: registry, server, TCP acceptor,
       and (optionally) mDNS advertiser
    6. `UniversalProxy.TuyaMesh.Commander` (Bluetooth targets) — runs the
       Tuya mesh light commands the `EntityProvider` hands it

  `ConfigStore` lives one level up in the application supervisor so a
  `restart/0` of this tree does not close and reopen the DETS file.

  ## Tuya mesh sub-devices

  The device config carries the mesh's ESPHome sub-devices
  (`UniversalProxy.TuyaMesh.Entities`). At runtime the `EntityProvider`
  keeps them current with `Espex.update_device_config/2`, which only lasts
  for the running Espex. So `init/1` merges the current ones, and every
  Espex start (`start_espex/2`, also a restart of Espex alone) takes the
  provider's, the ones its entities are advertised with. Without that, a
  restart would come back with fewer sub-devices and Home Assistant would
  delete the missing ones, and their history, on the next connect.
  """

  use Supervisor

  alias UniversalProxy.ESPHome.{
    BluetoothProxy,
    BluetoothScanner,
    Clients,
    ConfigStore,
    EntityProvider,
    Infrared,
    PskStore,
    SerialProxy,
    ZigbeeProxy,
    ZWaveProxy
  }

  alias UniversalProxy.Bluetooth.Settings, as: BluetoothSettings
  alias UniversalProxy.ESPHome.EntityProvider.MeshSync
  alias UniversalProxy.Hardware
  alias UniversalProxy.TuyaMesh.Commander
  alias UniversalProxy.UART.Enumerate
  alias UniversalProxy.UART.Store, as: UARTStore

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc """
  Restart the ESPHome supervisor tree.

  Closes all UART ports opened by serial-proxy connections, then terminates
  and restarts this supervisor under the application supervisor. Active
  client connections are dropped so they reconnect with the updated device
  info (refreshed `serial_proxies`, etc.).
  """
  @spec restart() :: {:ok, pid()} | {:error, term()}
  def restart do
    try do
      UniversalProxy.UART.Server.close_all_ports()
    catch
      :exit, _ -> :ok
    end

    Supervisor.terminate_child(UniversalProxy.Supervisor, __MODULE__)
    Supervisor.restart_child(UniversalProxy.Supervisor, __MODULE__)
  end

  @impl true
  def init(init_arg) do
    opts = if Keyword.keyword?(init_arg), do: init_arg, else: []
    mesh_devices_fun = Keyword.get(opts, :mesh_devices_fun, &MeshSync.boot_devices/0)
    live_devices_fun = Keyword.get(opts, :live_devices_fun, &EntityProvider.mesh_devices/0)

    # Seed the persisted PSK into device_config so a previously
    # HA-provisioned key survives restart/reboot. accepts_key_provisioning
    # is opened only while keyless: once a key exists, no LAN client can
    # re-provision (espex's own documented idiom).
    psk = PskStore.load_psk()

    device_config =
      ConfigStore.device_config_opts()
      |> Keyword.merge(psk: psk, accepts_key_provisioning: psk == nil)
      |> merge_devices(mesh_devices(mesh_devices_fun))

    espex_opts =
      [
        device_config: device_config,
        serial_proxy: SerialProxy,
        zwave_proxy: ZWaveProxy,
        infrared_proxy: Infrared.Server,
        mdns: UniversalProxy.ESPHome.MdnsAdapter,
        psk_store: PskStore,
        connection_listener: Clients,
        entity_provider: EntityProvider
      ] ++ bluetooth_opts()

    children = [
      # Before ZWaveProxy, which casts to it.
      ZWaveProxy.Advertiser,
      # No port is resolved here — the proxy resolves (and re-resolves)
      # through the resolver on its open/rescan loop, so boot, hotplug,
      # and replug all take the same path.
      {ZWaveProxy, resolver: &__MODULE__.resolve_zwave_port/0},
      # Before Espex (rest_for_one): serial-proxy sessions attach to it.
      {ZigbeeProxy, resolver: &__MODULE__.resolve_zigbee_port/0},
      Infrared.Supervisor,
      # Must start BEFORE Espex (rest_for_one): Espex calls
      # EntityProvider.list_entities/0 at connection-accept time, and a
      # provider crash should restart Espex so clients re-read entities.
      # Pushes go to the default Espex.Server name (espex_opts sets no
      # :server_name).
      {EntityProvider, server: Espex.Server},
      Supervisor.child_spec({Espex, espex_opts},
        start: {__MODULE__, :start_espex, [espex_opts, live_devices_fun]}
      )
    ]

    # Last, so its crash restarts only itself. Runs the provider's mesh
    # light commands; Bluetooth targets only, like the mesh.
    children =
      if Keyword.get(opts, :mesh_commander?, UniversalProxy.Bluetooth.supported?()),
        do: children ++ [{Commander, server: Espex.Server}],
        else: children

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  Starts Espex with the sub-devices `live_devices_fun` gives (`{:ok,
  devices}`, the provider's), falling back to the ones in `espex_opts`
  when it gives anything else: a provider that doesn't know the mesh yet
  must not start Espex without it.
  """
  @spec start_espex(keyword(), (-> {:ok, [Espex.DeviceConfig.Device.t()]} | term())) ::
          Supervisor.on_start()
  def start_espex(espex_opts, live_devices_fun) do
    espex_opts
    |> refresh_devices(live_devices_fun.())
    |> Espex.Supervisor.start_link()
  end

  @doc false
  @spec refresh_devices(keyword(), {:ok, [Espex.DeviceConfig.Device.t()]} | term()) :: keyword()
  def refresh_devices(espex_opts, {:ok, devices}),
    do: Keyword.update!(espex_opts, :device_config, &merge_devices(&1, devices))

  def refresh_devices(espex_opts, _unavailable), do: espex_opts

  @doc """
  `device_config` with `devices` as its sub-devices (replacing any).
  """
  @spec merge_devices(keyword(), [Espex.DeviceConfig.Device.t()]) :: keyword()
  def merge_devices(device_config, devices), do: Keyword.put(device_config, :devices, devices)

  # `MeshSync.boot_devices/0` never raises, but a supervisor init must not
  # fail over sub-devices: none is the safe answer.
  defp mesh_devices(fun) do
    fun.()
  rescue
    _e -> []
  catch
    :exit, _reason -> []
  end

  # Wire the BLE adapters (passive scanner + active GATT proxy) into espex
  # ONLY on BT-capable targets — and on those, only as far as the user's
  # Bluetooth settings allow. Off target (or BT disabled) both keys are
  # omitted entirely, so espex leaves the bluetooth feature flags at 0.
  #
  # Boot ordering: `UniversalProxy.Bluetooth` (the registry, settings
  # store, and Bluez lifecycle) starts BEFORE this supervisor (see
  # `application.ex`), so the settings read here sees the persisted state
  # on first boot. The adapters stay defensive regardless:
  # `BluetoothScanner.subscribe/1` rescues an un-started Registry's
  # `ArgumentError` and `BluetoothProxy` handles a not-running `Bluez.Gatt`.
  defp bluetooth_opts do
    bluetooth_opts(UniversalProxy.Bluetooth.supported?(), bluetooth_settings())
  end

  @doc """
  The espex adapter wiring for a given BT support level + settings — pure,
  so the enabled × paused × active_connections matrix is host-testable.

    * unsupported target or `enabled: false` → no adapters (flags 0)
    * role-paused (`Settings.proxy_paused?/1` — non-mesh roles assigned,
      none `:proxy`) → no adapters: "Off" on every radio must mean HA gets
      nothing, not a silent auto-fallback. A `:tuya_mesh` role alone is not
      a pause: the mesh radio is excluded from the BlueZ claim and the auto
      fallback proxies on another radio
    * `active_connections: false` → scanner only (HA sees a passive-only
      proxy: no ACTIVE_CONNECTIONS / REMOTE_CACHING / PAIRING flags)
    * both on → scanner + GATT proxy (full flag set, 0x7F)
  """
  @spec bluetooth_opts(boolean(), %{
          required(:enabled) => boolean(),
          required(:active_connections) => boolean(),
          required(:roles) => %{optional(String.t()) => atom()},
          required(:adapter) => String.t() | nil,
          optional(atom()) => term()
        }) :: keyword()
  def bluetooth_opts(false, _settings), do: []
  def bluetooth_opts(true, %{enabled: false}), do: []

  def bluetooth_opts(true, settings) do
    cond do
      BluetoothSettings.proxy_paused?(settings) ->
        []

      settings.active_connections == false ->
        [bluetooth_scanner: BluetoothScanner]

      true ->
        [bluetooth_scanner: BluetoothScanner, bluetooth_proxy: BluetoothProxy]
    end
  end

  # Defensive read: if the settings store isn't up (it always is on BT
  # targets by boot order, but stay safe), fall back to the defaults.
  defp bluetooth_settings do
    BluetoothSettings.get()
  catch
    :exit, _ -> BluetoothSettings.defaults()
  end

  # Resolve the Z-Wave-classified port as `%{path: tty, display_name:
  # ha_name}` (or nil). Two sources cooperate:
  #
  #   1. `Hardware.list_ports/0` already auto-classifies the Nabu Casa
  #      Connect ZWA-2 by VID/PID (`0x303A:0x4001`), so the common case
  #      needs no saved config.
  #   2. A user-saved `:zwave` override on a generic port still wins
  #      (e.g. a SONOFF Z-Wave 800 dongle on a CP2102, `0x10C4:0xEA60`).
  #      Locked (branded) ports are skipped: their kind is fixed by
  #      hardware, so a stale saved `:zwave` row must never claim a
  #      ZBT-2 (`:zigbee`).
  #
  # `display_name` is the row's `ha_name` — the key the Overview
  # subscribes to `UART.History` throughput with, so the proxy's
  # broadcasts land on the sparkline. Public because `ZWaveProxy`
  # invokes it from its open/rescan loop.
  @doc false
  def resolve_zwave_port do
    enumerated = Enumerate.safe()

    pick_zwave_port(
      Hardware.list_ports(enumerated: enumerated),
      Hardware.live_port_keys(enumerated: enumerated),
      UARTStore.all_configs()
    )
  end

  # Pure core of `resolve_zwave_port/0`: `ports` from `Hardware.list_ports/0`,
  # `key_to_tty` from `Hardware.live_port_keys/0`, `configs` from
  # `UART.Store.all_configs/0`.
  @doc false
  def pick_zwave_port(ports, key_to_tty, configs) do
    case Enum.find(ports, &(&1.connected and &1.kind == :zwave)) do
      nil ->
        # Fallback for pre-existing saved configs that target a port
        # whose adapter isn't currently classified as Z-Wave by
        # Hardware (e.g. a CP2102N on a non-ZWA-2 device).
        locked_ttys = for %{locked: true, tty_name: tty} <- ports, into: MapSet.new(), do: tty

        Enum.find_value(configs, fn cfg ->
          tty = Map.get(key_to_tty, {cfg[:slot_sub], cfg[:vendor_id], cfg[:product_id]})

          if cfg[:port_type] == :zwave and is_binary(tty) and
               not MapSet.member?(locked_ttys, tty) do
            %{path: tty, display_name: display_name_for(ports, tty)}
          end
        end)

      port ->
        %{path: port.tty_name, display_name: port.ha_name}
    end
  end

  # Resolve the ZBT-2 (the first connected `:zigbee` port, one per
  # device) as `%{path: tty, display_name: ha_name, port: row}`, or nil.
  # Public because `ZigbeeProxy` invokes it from its open/rescan loop.
  @doc false
  def resolve_zigbee_port, do: pick_zigbee_port(Hardware.list_ports())

  @doc false
  def pick_zigbee_port(ports) do
    case Enum.find(ports, &(&1.connected and &1.kind == :zigbee and is_binary(&1.tty_name))) do
      nil -> nil
      port -> %{path: port.tty_name, display_name: port.ha_name, port: port}
    end
  end

  defp display_name_for(ports, tty) do
    case Enum.find(ports, &(&1.tty_name == tty)) do
      %{ha_name: name} when is_binary(name) -> name
      _ -> tty
    end
  end
end
