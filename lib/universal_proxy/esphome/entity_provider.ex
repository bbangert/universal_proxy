defmodule UniversalProxy.ESPHome.EntityProvider do
  @moduledoc """
  Advertises Universal Proxy's own diagnostic/identity sensors plus
  Factory-reset and Reboot config buttons to Home Assistant over the
  ESPHome Native API (`Espex.EntityProvider` behaviour).

  A single poll timer (default 30 s) reads every source each tick and
  `Espex.push_state/2`s only the values that changed since the last tick
  (push is a silent no-op when no client is subscribed). Entity advertisements
  are frozen per-connection at accept time, so the set is static for the
  life of a connection; a reconnect picks up changes (e.g. a target that
  gains Bluetooth).

  ## Bluetooth gating

  The four BLE entities are advertised only when
  `UniversalProxy.Bluetooth.supported?()` is true. On non-BT targets the
  BT subtree doesn't exist, so advertising them would leave permanently
  unavailable entities and risk crashing the source reads.

  ## Missing state

  Numeric/text values that are unavailable (e.g. Wi-Fi RSSI on an
  Ethernet-only device, or a source that's momentarily down) are sent
  with `missing_state: true` rather than a bogus `0`, so HA shows them as
  unavailable.

  ## USB storage entities

  `usb_storage_free`/`usb_storage_used`/`usb_storage_share` are
  advertised unconditionally on every target, unlike the Bluetooth
  entities: advertisements freeze per-connection at accept time, so a
  drive-conditional set would only pick up a plugged-in drive on the
  next reconnect (an espex bounce), not live. Instead the two sensors
  report `missing_state: true` while `UniversalProxy.Storage.state/0`
  reports no `capacity` (no drive mounted); the binary sensor always has
  a real value (`false` when off/no drive).

  ## Tuya mesh entities

  On Bluetooth targets the mesh's bulbs and groups are advertised too, as
  ESPHome sub-devices with entities (`UniversalProxy.TuyaMesh.Entities`),
  after the static ones. That set is held here (with the key lookup it
  adds) and rebuilt from the Store, the mesh role and the mesh settings
  when any of them may have changed: on the Store's `{:tuya_mesh_store,
  _}` broadcasts (uploads, clears, group changes, settings) and the
  Bluetooth Manager's `{:bluetooth_state, _}` (role changes), debounced
  (`:mesh_debounce_ms`, 1 s). Only when the sub-devices or the
  advertisements differ from the held ones does it switch to the new set,
  then `Espex.update_device_config(devices: ...)` and
  `Espex.disconnect_clients/1`, in that order, so Home Assistant
  reconnects and re-reads both. A label rename is a sub-device name
  change, so it reconnects too. Inputs that can't be read keep the held
  set: an unreadable Store must not read as "no bulbs" and make HA delete
  them. `ESPHome.Supervisor` starts Espex with the held sub-devices
  (`mesh_devices/0`), so a restarted Espex agrees with these entities.

  Live values for the initial states (connectivity, last seen) come from
  the Resolver's `{:tuya_mesh_status, status}` broadcasts. Mesh light
  commands are acknowledged and logged, not acted on yet.

  ## Testability

  Every data source is an injectable 0-arity fun (mirroring the
  `devices_fun`/`connections_fun` idiom in `Bluetooth.Stats`). The pure
  functions (`advertisements/2`, `read_values/2`, `state_responses/3`,
  `changed/2`) are unit-testable without starting the GenServer.
  """

  @behaviour Espex.EntityProvider
  use GenServer

  require Logger

  alias Espex.Proto

  alias UniversalProxy.{Audio, Bluetooth, FirmwareUpdate, Storage, System}
  alias UniversalProxy.Bluetooth.{RadioMonitor, Stats}
  alias UniversalProxy.ESPHome.Clients
  alias UniversalProxy.FirmwareUpdate.ConfigStore
  alias UniversalProxy.TuyaMesh
  alias UniversalProxy.TuyaMesh.{Entities, Store}

  @default_tick_ms 30_000
  @default_mesh_debounce_ms 1_000

  # Updater phases that mean "an install is running" for HA's progress bar.
  @in_progress_phases [:downloading, :installing]

  # `release_summary` is free-form in the proto, but the release body is
  # unbounded (GitHub auto-generated notes run to several KB) and it rides
  # every progress push. Cap it so a chatty install doesn't spam large frames.
  @summary_limit 1_500

  # ── Entity specifications ───────────────────────────────────────────
  # `key` (fixed32) is derived from `object_id` via crc32 so it is stable
  # across reboots (HA's unique_id dedupe requirement). `bt: true` marks
  # entities that are only advertised on Bluetooth-capable targets.

  @specs [
    # numeric sensors
    %{
      object_id: "cpu_temperature",
      type: :sensor,
      name: "CPU Temperature",
      device_class: "temperature",
      unit: "°C",
      decimals: 1
    },
    %{object_id: "memory_used", type: :sensor, name: "Memory Used", unit: "%", decimals: 0},
    %{object_id: "load_1min", type: :sensor, name: "Load (1 min)", decimals: 2},
    %{
      object_id: "data_storage_used",
      type: :sensor,
      name: "Data Storage Used",
      unit: "%",
      decimals: 0
    },
    %{
      object_id: "uptime",
      type: :sensor,
      name: "Uptime",
      device_class: "timestamp",
      decimals: 0,
      state_class: :STATE_CLASS_NONE
    },
    %{
      object_id: "wifi_signal",
      type: :sensor,
      name: "Wi-Fi Signal",
      device_class: "signal_strength",
      unit: "dBm",
      decimals: 0
    },
    %{object_id: "api_clients", type: :sensor, name: "Connected API Clients", decimals: 0},
    %{
      object_id: "ble_devices_15m",
      type: :sensor,
      name: "BLE Devices (15 min)",
      decimals: 0,
      bt: true
    },
    %{
      object_id: "ble_ads_per_sec",
      type: :sensor,
      name: "BLE Advertisements/s",
      unit: "1/s",
      decimals: 0,
      bt: true
    },
    %{
      object_id: "gatt_connections",
      type: :sensor,
      name: "Active GATT Connections",
      decimals: 0,
      bt: true
    },
    %{
      object_id: "audio_outputs_active",
      type: :sensor,
      name: "Active Audio Outputs",
      decimals: 0
    },
    %{
      object_id: "usb_storage_free",
      type: :sensor,
      name: "USB Storage Free",
      device_class: "data_size",
      unit: "GB",
      decimals: 1
    },
    %{
      object_id: "usb_storage_used",
      type: :sensor,
      name: "USB Storage Used",
      unit: "%",
      decimals: 0
    },
    # text sensors
    %{object_id: "firmware_version", type: :text_sensor, name: "Firmware Version"},
    %{object_id: "board_target", type: :text_sensor, name: "Board / Target"},
    %{object_id: "network_type", type: :text_sensor, name: "Network Type"},
    %{object_id: "ip_address", type: :text_sensor, name: "IP Address"},
    %{object_id: "wifi_ssid", type: :text_sensor, name: "Wi-Fi SSID"},
    # binary sensors
    %{
      object_id: "bluetooth_powered",
      type: :binary_sensor,
      name: "Bluetooth Adapter Powered",
      device_class: "connectivity",
      bt: true
    },
    %{
      object_id: "audio_streaming",
      type: :binary_sensor,
      name: "Audio Streaming",
      device_class: "running"
    },
    %{
      object_id: "usb_storage_share",
      type: :binary_sensor,
      name: "USB Storage Share",
      device_class: "running"
    },
    # config buttons
    %{
      object_id: "factory_reset",
      type: :button,
      name: "Factory Reset",
      category: :ENTITY_CATEGORY_CONFIG,
      disabled_by_default: true
    },
    %{
      object_id: "reboot",
      type: :button,
      name: "Reboot",
      category: :ENTITY_CATEGORY_CONFIG
    },
    # firmware update — renders in HA as a native `update.` entity with an
    # Install button, release notes and a progress bar, and feeds the
    # Settings → Updates panel.
    %{
      object_id: "firmware_update",
      type: :update,
      name: "Firmware Update",
      device_class: "firmware",
      category: :ENTITY_CATEGORY_CONFIG
    }
  ]

  # ── Public API ──────────────────────────────────────────────────────

  @doc false
  @spec specs() :: [map()]
  def specs, do: @specs

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  # ── EntityProvider callbacks ────────────────────────────────────────

  @impl Espex.EntityProvider
  def list_entities, do: GenServer.call(__MODULE__, :list_entities)

  @impl Espex.EntityProvider
  def initial_states, do: GenServer.call(__MODULE__, :initial_states)

  @impl Espex.EntityProvider
  def handle_command(command), do: GenServer.cast(__MODULE__, {:command, command})

  @doc """
  The Tuya mesh sub-devices the advertised entities belong to, `{:ok,
  devices}`, or `:error` when this provider isn't running.
  """
  @spec mesh_devices(GenServer.server()) :: {:ok, [Espex.DeviceConfig.Device.t()]} | :error
  def mesh_devices(server \\ __MODULE__) do
    GenServer.call(server, :mesh_devices)
  catch
    :exit, _reason -> :error
  end

  # Entities whose commands can reboot, wipe or reflash the device.
  @privileged_object_ids ~w(firmware_update factory_reset reboot)

  @doc """
  Command entry point that also gets the connection's security context.

  Espex prefers this over `handle_command/1` when exported. On a keyless
  server every connection is anonymous — the ESPHome protocol answers
  `AuthenticationRequest` unconditionally, so a Noise session is the only
  real credential — which means anything on the LAN can drive entity
  commands until Home Assistant provisions a PSK.

  That's tolerable for the diagnostic entities, which is why the whole
  surface isn't simply closed: the keyless window is how HA adopts the
  device in the first place. It isn't tolerable for Factory Reset, Reboot
  or Firmware Update, so **every** command on those three entities is
  refused unless the connection is encrypted.

  Note that includes the update entity's Check, not just Install — the
  gate is per-entity, not per-command. That is deliberate: Check reaches
  `FirmwareUpdate.check/0`, which makes an outbound GitHub request with no
  debounce, so leaving it open would let an unauthenticated client drive
  the API into its secondary rate limits. Nothing legitimate is lost:
  the keyless window is pre-adoption, HA refreshes over an encrypted
  connection once it has provisioned a PSK, and the 24 h poller checks
  regardless.

  Refusals return `:ok`: the protocol has no "denied" reply for a command,
  and reporting an error would only surface as an adapter failure in the
  server's logs. The warning is the audit trail.
  """
  @impl Espex.EntityProvider
  def handle_command(command, %{encrypted?: false} = _context) do
    case privileged_object_id(command) do
      nil ->
        handle_command(command)

      object_id ->
        Logger.warning(
          "EntityProvider: refusing #{object_id} command from an unencrypted client — " <>
            "provision API encryption in Home Assistant to enable it"
        )

        :ok
    end
  end

  def handle_command(command, _context), do: handle_command(command)

  @doc false
  @spec privileged_object_id(struct()) :: String.t() | nil
  def privileged_object_id(%{key: key}) do
    object_id = Map.get(key_lookup(), key)
    if object_id in @privileged_object_ids, do: object_id
  end

  def privileged_object_id(_command), do: nil

  # ── GenServer callbacks ─────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    supported? = Keyword.get(opts, :supported?, default_supported?())
    sources = build_sources(opts)

    state = %{
      server: Keyword.get(opts, :server, Espex.Server),
      tick_ms: Keyword.get(opts, :tick_ms, @default_tick_ms),
      supported?: supported?,
      sources: sources,
      keys: key_lookup(),
      last: %{},
      pubsub: Keyword.get(opts, :pubsub, UniversalProxy.PubSub),
      mesh: Entities.empty(),
      mesh_live: %{},
      mesh_timer: nil,
      mesh_debounce_ms: Keyword.get(opts, :mesh_debounce_ms, @default_mesh_debounce_ms),
      update_device_config:
        Keyword.get(opts, :update_device_config, &Espex.update_device_config/2),
      disconnect_clients: Keyword.get(opts, :disconnect_clients, &Espex.disconnect_clients/1)
    }

    # Firmware-update progress is event-driven, not poll-driven: a 30 s tick
    # would render HA's progress bar useless during an install. Subscribing is
    # best-effort — PubSub may not be up yet during a supervised restart, and
    # the poll tick still backstops the entity either way.
    if Keyword.get(opts, :subscribe, true) do
      subscribe_fw_progress()
      if supported?, do: subscribe_mesh(state.pubsub)
    end

    # Before any client can connect (Espex starts after this provider), and
    # without telling Espex: it is started with these sub-devices.
    state = if supported?, do: init_mesh(state), else: state

    # Seed `last` once at startup (before any client can connect) so
    # `initial_states/0` answers instantly off the connection-accept path
    # rather than reading every source synchronously inside that call.
    if Keyword.get(opts, :poll, true) do
      {:ok, state, {:continue, :poll}}
    else
      {:ok, state}
    end
  end

  @impl GenServer
  def handle_continue(:poll, state) do
    # Seed `last` WITHOUT pushing: at boot there are no subscribers yet and,
    # because this provider starts before Espex (rest_for_one), the Espex
    # registry may not exist — pushing would raise. The first scheduled tick
    # does the first real diff-push once Espex is up.
    new_state = %{state | last: read_values(state.sources, state.supported?, state.last)}
    schedule(new_state.tick_ms)
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_call(:list_entities, _from, state) do
    {:reply, advertisements(@specs, state.supported?) ++ Entities.advertisements(state.mesh),
     state}
  end

  # Returns the last-polled values (seeded at startup) — no source reads on
  # the connection-accept path. Values may be up to one tick stale.
  def handle_call(:initial_states, _from, state) do
    {:reply,
     state_responses(@specs, state.last, state.supported?) ++
       Entities.state_responses(state.mesh, state.mesh_live), state}
  end

  def handle_call(:mesh_devices, _from, state), do: {:reply, {:ok, state.mesh.devices}, state}

  # Exposed for tests that drive a tick deterministically (no reschedule).
  def handle_call(:poll_now, _from, state) do
    new_state = do_poll(state)
    {:reply, new_state.last, new_state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    new_state = do_poll(state)
    schedule(new_state.tick_ms)
    {:noreply, new_state}
  end

  # Live install progress. Re-read only the update entity (not every source)
  # and push when it actually changed, so HA's progress bar tracks the flash
  # instead of waiting for the next 30 s tick.
  def handle_info({:fw_update_progress, payload}, state) do
    # Mid-flash the Updater blocks its entire loop, so re-reading here would
    # park this provider for the full call timeout AND come back with
    # `pct: nil` — discarding the very percentage the event carries, which
    # is the whole reason we subscribe. Merge the payload instead, and only
    # re-read once it reports idle (where a freshly fetched release, and so
    # a new latest_version/notes, becomes visible). Same shape as the
    # LiveView handler in UniversalProxyWeb.SystemLive.
    value =
      if Map.get(payload, :phase) == :idle do
        read_update_value(state.sources)
      else
        apply_progress(Map.get(state.last, "firmware_update"), payload)
      end

    if Map.get(state.last, "firmware_update", :__unset__) == value do
      {:noreply, state}
    else
      case state_response_for(spec_for("firmware_update"), value) do
        nil -> :ok
        struct -> push(state.server, struct)
      end

      {:noreply, %{state | last: Map.put(state.last, "firmware_update", value)}}
    end
  end

  # Uploads, clears, group and settings changes, and role changes: the
  # mesh's sub-devices or entities may have changed.
  def handle_info({:tuya_mesh_store, _event}, state), do: {:noreply, arm_mesh_sync(state)}
  def handle_info({:bluetooth_state, _status}, state), do: {:noreply, arm_mesh_sync(state)}

  def handle_info({:tuya_mesh_status, status}, state),
    do: {:noreply, %{state | mesh_live: Entities.live_from_status(status)}}

  def handle_info({:mesh_sync, ref}, %{mesh_timer: ref} = state),
    do: {:noreply, sync_mesh(%{state | mesh_timer: nil})}

  def handle_info(_msg, state), do: {:noreply, state}

  # Read every source, push only changed values, and return the new state.
  defp do_poll(state) do
    values = read_values(state.sources, state.supported?, state.last)

    for {object_id, value} <- changed(state.last, values) do
      case state_response_for(spec_for(object_id), value) do
        nil -> :ok
        struct -> push(state.server, struct)
      end
    end

    %{state | last: values}
  end

  # Tolerate the Espex registry being momentarily unavailable (e.g. during a
  # supervised restart) — `Registry.dispatch` raises if the registry isn't
  # started, and a failed push must never crash the poll loop.
  defp push(server, struct) do
    Espex.push_state(server, struct)
  rescue
    ArgumentError -> :ok
  end

  @impl GenServer
  def handle_cast({:command, %Proto.ButtonCommandRequest{key: key}}, state) do
    case Map.get(state.keys, key) do
      "factory_reset" -> System.factory_reset()
      "reboot" -> System.reboot()
      other -> Logger.info("EntityProvider: ignoring button command for key #{inspect(other)}")
    end

    {:noreply, state}
  end

  # HA's update card maps Install -> UPDATE and its refresh -> CHECK. Both
  # return {:error, :host_mode} off-device; log rather than crash the provider.
  def handle_cast({:command, %Proto.UpdateCommandRequest{key: key, command: cmd}}, state) do
    case {Map.get(state.keys, key), cmd} do
      {"firmware_update", :UPDATE_COMMAND_UPDATE} -> run_fw(state, :fw_install, "install")
      {"firmware_update", :UPDATE_COMMAND_CHECK} -> run_fw(state, :fw_check, "check")
      other -> Logger.info("EntityProvider: ignoring update command #{inspect(other)}")
    end

    {:noreply, state}
  end

  def handle_cast({:command, %Proto.LightCommandRequest{key: key}}, state) do
    case Map.get(state.keys, key) do
      {:tuya_mesh, target} ->
        Logger.debug(
          "EntityProvider: Tuya mesh light command for #{inspect(target)} not yet mapped"
        )

      other ->
        Logger.debug("EntityProvider: ignoring light command for key #{inspect(other)}")
    end

    {:noreply, state}
  end

  def handle_cast({:command, other}, state) do
    Logger.debug("EntityProvider: ignoring unknown command #{inspect(other)}")
    {:noreply, state}
  end

  def handle_cast(other, state) do
    Logger.debug("EntityProvider: ignoring unexpected cast #{inspect(other)}")
    {:noreply, state}
  end

  # ── Tuya mesh ───────────────────────────────────────────────────────

  defp init_mesh(state) do
    state =
      case read_mesh(state) do
        {:ok, mesh} -> put_mesh(state, mesh)
        :unknown -> state
      end

    %{state | mesh_live: Entities.live_from_status(safe(state.sources.mesh_status, %{}))}
  end

  defp arm_mesh_sync(%{supported?: false} = state), do: state
  defp arm_mesh_sync(%{mesh_timer: ref} = state) when is_reference(ref), do: state

  defp arm_mesh_sync(state) do
    ref = make_ref()
    Process.send_after(self(), {:mesh_sync, ref}, state.mesh_debounce_ms)
    %{state | mesh_timer: ref}
  end

  defp sync_mesh(state) do
    with {:ok, mesh} <- read_mesh(state),
         false <- same_mesh?(mesh, state.mesh) do
      state = put_mesh(state, mesh)
      reconnect(state, mesh.devices)
      state
    else
      _unchanged_or_unknown -> state
    end
  end

  defp same_mesh?(a, b),
    do: a.devices == b.devices and Entities.advertisements(a) == Entities.advertisements(b)

  defp read_mesh(state) do
    Entities.read(
      %{
        supported?: true,
        role: state.sources.mesh_role,
        inventory: state.sources.mesh_inventory,
        settings: state.sources.mesh_settings
      },
      reserved_keys: Map.keys(key_lookup()),
      on_collision: Application.get_env(:universal_proxy, :tuya_entity_collisions, :skip)
    )
  end

  defp put_mesh(state, mesh) do
    mesh_keys = Map.new(mesh.keys, fn {key, target} -> {key, {:tuya_mesh, target}} end)
    %{state | mesh: mesh, keys: Map.merge(mesh_keys, key_lookup())}
  end

  # Sub-devices first, then the reconnect, so the new connection reads both
  # the new DeviceInfo and the new entities. With Espex down there is no
  # one to reconnect, and its next start takes `mesh_devices/0`.
  defp reconnect(state, devices) do
    Logger.info("EntityProvider: Tuya mesh entities changed; reconnecting Home Assistant")

    case state.update_device_config.(state.server, devices: devices) do
      :ok ->
        state.disconnect_clients.(state.server)

      {:error, reason} ->
        Logger.warning("EntityProvider: mesh sub-device update refused: #{inspect(reason)}")
    end
  rescue
    ArgumentError -> :ok
  catch
    :exit, reason -> Logger.debug("EntityProvider: Espex not running (#{inspect(reason)})")
  end

  # Same best-effort contract as `subscribe_fw_progress/0`.
  defp subscribe_mesh(pubsub) do
    for topic <- [Store.topic(), TuyaMesh.topic(), Bluetooth.state_topic()],
        do: Phoenix.PubSub.subscribe(pubsub, topic)

    :ok
  rescue
    e in ArgumentError ->
      Logger.debug("EntityProvider: Tuya mesh subscribe failed: #{Exception.message(e)}")
      :ok
  end

  # Run the firmware command off this process. `install_latest/0` is a call
  # into a loop that deliberately blocks for the whole flash, so running it
  # inline would park the provider (and every other entity's state pushes)
  # for the full call timeout. Task.Supervisor per the project convention —
  # never bare Task.start — so a failure is supervised and visible.
  defp run_fw(state, source_key, label) do
    fun = Map.fetch!(state.sources, source_key)
    runner = Map.get(state.sources, :task_runner, &default_task_runner/1)

    runner.(fn ->
      case fun.() do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.info("EntityProvider: firmware #{label} rejected: #{inspect(reason)}")
      end
    end)
  end

  defp default_task_runner(fun) do
    Task.Supervisor.start_child(UniversalProxy.TaskSupervisor, fun)
  end

  # ── Pure: advertisements ────────────────────────────────────────────

  @doc """
  Build the `ListEntities*Response` advertisement structs for all specs,
  dropping Bluetooth entities when `supported?` is false.
  """
  @spec advertisements([map()], boolean()) :: [struct()]
  def advertisements(specs, supported?) do
    specs
    |> visible(supported?)
    |> Enum.map(&advertisement/1)
  end

  defp advertisement(%{type: :sensor} = s) do
    %Proto.ListEntitiesSensorResponse{
      object_id: s.object_id,
      key: key_for(s.object_id),
      name: s.name,
      unit_of_measurement: Map.get(s, :unit, ""),
      accuracy_decimals: Map.get(s, :decimals, 0),
      device_class: Map.get(s, :device_class, ""),
      state_class: Map.get(s, :state_class, :STATE_CLASS_MEASUREMENT),
      entity_category: Map.get(s, :category, :ENTITY_CATEGORY_DIAGNOSTIC),
      disabled_by_default: Map.get(s, :disabled_by_default, false)
    }
  end

  defp advertisement(%{type: :text_sensor} = s) do
    %Proto.ListEntitiesTextSensorResponse{
      object_id: s.object_id,
      key: key_for(s.object_id),
      name: s.name,
      entity_category: Map.get(s, :category, :ENTITY_CATEGORY_DIAGNOSTIC),
      disabled_by_default: Map.get(s, :disabled_by_default, false)
    }
  end

  defp advertisement(%{type: :binary_sensor} = s) do
    %Proto.ListEntitiesBinarySensorResponse{
      object_id: s.object_id,
      key: key_for(s.object_id),
      name: s.name,
      device_class: Map.get(s, :device_class, ""),
      entity_category: Map.get(s, :category, :ENTITY_CATEGORY_DIAGNOSTIC),
      disabled_by_default: Map.get(s, :disabled_by_default, false)
    }
  end

  defp advertisement(%{type: :button} = s) do
    %Proto.ListEntitiesButtonResponse{
      object_id: s.object_id,
      key: key_for(s.object_id),
      name: s.name,
      entity_category: Map.get(s, :category, :ENTITY_CATEGORY_CONFIG),
      disabled_by_default: Map.get(s, :disabled_by_default, false)
    }
  end

  defp advertisement(%{type: :update} = s) do
    %Proto.ListEntitiesUpdateResponse{
      object_id: s.object_id,
      key: key_for(s.object_id),
      name: s.name,
      device_class: Map.get(s, :device_class, ""),
      entity_category: Map.get(s, :category, :ENTITY_CATEGORY_CONFIG),
      disabled_by_default: Map.get(s, :disabled_by_default, false)
    }
  end

  # ── Pure: state responses ───────────────────────────────────────────

  @doc """
  Build `*StateResponse` structs for every stateful (non-button) visible
  entity from a `%{object_id => value}` map. Used by `initial_states/0`.
  """
  @spec state_responses([map()], map(), boolean()) :: [struct()]
  def state_responses(specs, values, supported?) do
    specs
    |> visible(supported?)
    |> Enum.reject(&(&1.type == :button))
    |> Enum.map(&state_response_for(&1, Map.get(values, &1.object_id)))
    |> Enum.reject(&is_nil/1)
  end

  defp state_response_for(%{type: :sensor} = s, value) do
    %Proto.SensorStateResponse{
      key: key_for(s.object_id),
      state: to_float(value),
      missing_state: is_nil(value)
    }
  end

  defp state_response_for(%{type: :text_sensor} = s, value) do
    %Proto.TextSensorStateResponse{
      key: key_for(s.object_id),
      state: value || "",
      missing_state: is_nil(value)
    }
  end

  defp state_response_for(%{type: :binary_sensor} = s, value) do
    %Proto.BinarySensorStateResponse{
      key: key_for(s.object_id),
      state: value == true,
      missing_state: false
    }
  end

  defp state_response_for(%{type: :update} = s, value) do
    v = value || %{}

    %Proto.UpdateStateResponse{
      key: key_for(s.object_id),
      missing_state: is_nil(value),
      in_progress: Map.get(v, :in_progress, false),
      has_progress: Map.get(v, :has_progress, false),
      progress: Map.get(v, :progress, 0.0),
      current_version: Map.get(v, :current_version, ""),
      latest_version: Map.get(v, :latest_version, ""),
      title: Map.get(v, :title, ""),
      release_summary: Map.get(v, :release_summary, ""),
      release_url: Map.get(v, :release_url, "")
    }
  end

  defp state_response_for(_other, _value), do: nil

  # ── Pure: read all sources into a value map ─────────────────────────

  @doc """
  Read every data source once into a `%{object_id => value | nil}` map.
  Bluetooth entries are included only when `supported?` is true. Each
  source read is wrapped so a down dependency yields `nil`/missing rather
  than crashing the poll loop.
  """
  @spec read_values(map(), boolean()) :: map()
  def read_values(sources, supported?), do: read_values(sources, supported?, %{})

  @doc """
  As `read_values/2`, but given the previous tick's values so the firmware
  entity can be carried over instead of re-read while an install runs.
  """
  @spec read_values(map(), boolean(), map()) :: map()
  def read_values(sources, supported?, previous) do
    metrics = safe(sources.metrics, %{})
    wifi = safe(sources.wifi, nil)
    firmware = safe(sources.firmware, %{})
    audio = safe(sources.audio, [])
    storage = safe(sources.storage, %{drives: [], mount: nil, share: :off, capacity: nil})
    capacity = Map.get(storage, :capacity)

    base = %{
      "cpu_temperature" => Map.get(metrics, :cpu_temp_c),
      "memory_used" => Map.get(metrics, :mem_used_pct),
      "load_1min" => Map.get(metrics, :load1),
      "data_storage_used" => Map.get(metrics, :data_used_pct),
      "uptime" => Map.get(metrics, :boot_time_unix),
      "wifi_signal" => wifi && Map.get(wifi, :rssi_dbm),
      "wifi_ssid" => wifi && Map.get(wifi, :ssid),
      "api_clients" => safe(sources.clients_count, nil),
      "audio_outputs_active" => count_connected(audio),
      "audio_streaming" => any_streaming?(audio),
      "usb_storage_free" => storage_free_gb(capacity),
      "usb_storage_used" => capacity && Map.get(capacity, :used_pct),
      "usb_storage_share" => Map.get(storage, :share) == :running,
      "firmware_version" => Map.get(firmware, :version),
      "board_target" => Map.get(firmware, :target),
      "network_type" => network_type_label(safe(sources.network_type, :disconnected)),
      "ip_address" => safe(sources.ip, nil),
      "firmware_update" => poll_update_value(sources, Map.get(previous, "firmware_update"))
    }

    if supported? do
      stats = safe(sources.bt_stats, %{})
      adapters = safe(sources.adapters, [])

      Map.merge(base, %{
        "ble_devices_15m" => Map.get(stats, :devices_15min),
        "ble_ads_per_sec" => Map.get(stats, :ads_per_s),
        "gatt_connections" => get_in(stats, [:connections, :used]),
        "bluetooth_powered" => any_powered?(adapters)
      })
    else
      base
    end
  end

  # While an install runs, the Updater blocks its entire loop, so the 30 s
  # tick would wait out the full call timeout and get back a synthetic
  # snapshot with `pct: nil` and no release — clobbering the live values
  # the progress events maintain, and stalling every other entity's push
  # for 5 s each tick. Carry the cached value instead; the terminal `:idle`
  # progress event does the authoritative re-read.
  #
  # Gated on liveness (a registry lookup, never a call) so a crashed
  # Updater can't leave the entity pinned to a stale in-progress value.
  defp poll_update_value(sources, %{in_progress: true} = cached) do
    if safe(sources.fw_alive, false), do: cached, else: read_update_value(sources)
  end

  defp poll_update_value(sources, _cached), do: read_update_value(sources)

  @doc false
  @spec read_update_value(map()) :: map() | nil
  def read_update_value(sources) do
    case safe(sources.fw_update, {:error, :unavailable}) do
      {:ok, fw_state} ->
        update_value(fw_state, safe(sources.fw_version, nil), safe(sources.fw_repo, nil))

      {:error, :unavailable} ->
        nil
    end
  end

  @doc """
  Fold a `{:fw_update_progress, payload}` event into the cached update
  value without touching the Updater.

  Only the progress-bar fields move; versions and release notes are
  carried over from the last full read, since the payload doesn't carry
  them. With no cached value there is nothing to merge into, so the
  entity stays `missing_state` until the next full read.
  """
  @spec apply_progress(map() | nil, map()) :: map() | nil
  def apply_progress(nil, _payload), do: nil

  def apply_progress(value, payload) when is_map(value) do
    pct = Map.get(payload, :pct)
    in_progress? = Map.get(payload, :phase) in @in_progress_phases

    %{
      value
      | in_progress: in_progress?,
        has_progress: in_progress? and is_number(pct),
        progress: (is_number(pct) && pct * 1.0) || 0.0
    }
  end

  @doc """
  Normalise an `UniversalProxy.FirmwareUpdate.state/0` snapshot into the
  flat value map backing the HA `update.` entity.

  `nil` (updater unavailable) yields `nil`, which renders as
  `missing_state` rather than a bogus "no update available".

  `latest_version` falls back to the current version when no release has
  been fetched yet — reporting an empty latest would make HA show a
  permanently-pending update before the first check runs.
  """
  @spec update_value(map() | nil, String.t() | nil, String.t() | nil) :: map() | nil
  def update_value(nil, _current_version, _repo), do: nil

  def update_value(fw_state, current_version, repo) when is_map(fw_state) do
    release = Map.get(fw_state, :last_release)
    pct = Map.get(fw_state, :pct)
    in_progress? = Map.get(fw_state, :phase) in @in_progress_phases
    tag = release && Map.get(release, :tag_name)
    current = current_version || ""

    %{
      current_version: current,
      latest_version: tag || current,
      title: (release && Map.get(release, :name)) || "",
      release_summary: summary(release),
      release_url: release_url(repo, tag),
      in_progress: in_progress?,
      has_progress: in_progress? and is_number(pct),
      progress: (is_number(pct) && pct * 1.0) || 0.0
    }
  end

  defp summary(nil), do: ""

  defp summary(release) do
    case Map.get(release, :body) do
      body when is_binary(body) -> String.slice(body, 0, @summary_limit)
      _ -> ""
    end
  end

  # The updater's cached release carries no html_url, so reconstruct the
  # canonical GitHub URL from the configured owner/repo + tag.
  defp release_url(repo, tag)
       when is_binary(repo) and is_binary(tag) and repo != "" and tag != "",
       do: "https://github.com/#{repo}/releases/tag/#{tag}"

  defp release_url(_repo, _tag), do: ""

  @doc """
  Return `{object_id, value}` pairs whose value differs from `last`.
  """
  @spec changed(map(), map()) :: [{String.t(), term()}]
  def changed(last, current) do
    Enum.filter(current, fn {object_id, value} ->
      Map.get(last, object_id, :__unset__) != value
    end)
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp visible(specs, true), do: specs
  defp visible(specs, false), do: Enum.reject(specs, &Map.get(&1, :bt, false))

  defp spec_for(object_id), do: Enum.find(@specs, &(&1.object_id == object_id))

  @doc false
  @spec key_for(String.t()) :: non_neg_integer()
  def key_for(object_id), do: :erlang.crc32(object_id)

  defp key_lookup, do: Map.new(@specs, &{key_for(&1.object_id), &1.object_id})

  defp to_float(nil), do: 0.0
  defp to_float(v) when is_integer(v), do: v * 1.0
  defp to_float(v) when is_float(v), do: v
  defp to_float(_), do: 0.0

  # Decimal GB (÷ 1_000_000_000), matching the "GB"/1-decimal unit in the
  # `usb_storage_free` spec — `nil` capacity (no drive mounted) stays `nil`
  # so the sensor reports `missing_state`, not a bogus `0.0`.
  defp storage_free_gb(nil), do: nil
  defp storage_free_gb(capacity), do: Map.get(capacity, :free_bytes) / 1_000_000_000

  defp count_connected(rows), do: Enum.count(rows, &(Map.get(&1, :connection) == :connected))
  defp any_streaming?(rows), do: Enum.any?(rows, &(Map.get(&1, :stream) != nil))
  defp any_powered?(adapters), do: Enum.any?(adapters, &(Map.get(&1, :powered) == true))

  defp network_type_label(:ethernet), do: "Ethernet"
  defp network_type_label(:wifi), do: "Wi-Fi"
  defp network_type_label(_), do: "Disconnected"

  # Call a 0-arity source fun, tolerating a down dependency. Failures are
  # logged (debug) rather than crashing the poll loop, but stay observable.
  defp safe(fun, fallback) do
    fun.()
  rescue
    e ->
      Logger.debug("EntityProvider source read raised: #{Exception.message(e)}")
      fallback
  catch
    :exit, reason ->
      Logger.debug("EntityProvider source read exited: #{inspect(reason)}")
      fallback
  end

  defp schedule(tick_ms), do: Process.send_after(self(), :poll, tick_ms)

  # Best-effort: Phoenix.PubSub.subscribe/2 delegates to Registry.register/3,
  # which RAISES ArgumentError when the registry isn't started (host tests, or
  # a supervised restart racing this provider) rather than exiting — so rescue
  # that specifically, per the project convention. Losing the subscription only
  # costs live progress, not correctness: the poll tick still refreshes the
  # entity. Anything else is a real bug and must not be swallowed here.
  defp subscribe_fw_progress do
    Phoenix.PubSub.subscribe(FirmwareUpdate.pubsub(), FirmwareUpdate.topic())
  rescue
    e in ArgumentError ->
      Logger.debug("EntityProvider: firmware-progress subscribe failed: #{Exception.message(e)}")
      :ok
  end

  defp default_supported?, do: Bluetooth.supported?()

  # Default source funs. Overridable per-key via opts for tests.
  defp build_sources(opts) do
    defaults = %{
      metrics: &System.metrics/0,
      wifi: &System.wifi_info/0,
      network_type: &System.network_type/0,
      firmware: &System.firmware_info/0,
      ip: &device_ip/0,
      clients_count: &client_count/0,
      audio: &Audio.Server.list_outputs/0,
      storage: &Storage.state/0,
      bt_stats: &Stats.current/0,
      adapters: &bt_adapters/0,
      # updater_state/0, not state/0: the entity needs to tell "Updater is
      # gone" (missing_state) apart from "Updater is idle", which state/0
      # deliberately flattens together for the LiveView.
      fw_update: &FirmwareUpdate.updater_state/0,
      fw_alive: &FirmwareUpdate.updater_alive?/0,
      fw_version: &FirmwareUpdate.current_version/0,
      fw_repo: &ConfigStore.get_repo/0,
      fw_check: &FirmwareUpdate.check/0,
      fw_install: &FirmwareUpdate.install_latest/0,
      mesh_role: &Entities.mesh_role/0,
      mesh_inventory: &Store.inventory_summary/0,
      mesh_settings: &Store.settings/0,
      mesh_status: &TuyaMesh.status/0
    }

    Map.merge(defaults, Map.new(Keyword.get(opts, :sources, [])))
  end

  defp device_ip, do: System.device_summary().ip
  defp client_count, do: length(Clients.list())

  # Prefer the BlueZ Powered property; fall back to radio presence if the
  # D-Bus client isn't answering. The Tuya mesh radio is dropped either way:
  # it's dedicated to the mesh, so it must not read as a powered proxy.
  defp bt_adapters do
    adapters =
      case Bluez.Client.adapters_info() do
        [] ->
          Enum.map(
            RadioMonitor.list(),
            &%{address: Map.get(&1, :address), powered: Map.get(&1, :in_use?, false)}
          )

        infos ->
          infos
      end

    without_mesh_adapter(adapters, Bluetooth.roles().tuya_mesh)
  end

  @doc false
  @spec without_mesh_adapter([map()], String.t() | nil) :: [map()]
  def without_mesh_adapter(adapters, nil), do: adapters

  def without_mesh_adapter(adapters, mesh_mac),
    do: Enum.reject(adapters, &(Map.get(&1, :address) == mesh_mac))
end
