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

  alias UniversalProxy.{Audio, Bluetooth, FirmwareUpdate, System}
  alias UniversalProxy.Bluetooth.{RadioMonitor, Stats}
  alias UniversalProxy.ESPHome.Clients
  alias UniversalProxy.FirmwareUpdate.ConfigStore

  @default_tick_ms 30_000

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

  # ── GenServer callbacks ─────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    state = %{
      server: Keyword.get(opts, :server, Espex.Server),
      tick_ms: Keyword.get(opts, :tick_ms, @default_tick_ms),
      supported?: Keyword.get(opts, :supported?, default_supported?()),
      sources: build_sources(opts),
      keys: key_lookup(),
      last: %{}
    }

    # Firmware-update progress is event-driven, not poll-driven: a 30 s tick
    # would render HA's progress bar useless during an install. Subscribing is
    # best-effort — PubSub may not be up yet during a supervised restart, and
    # the poll tick still backstops the entity either way.
    if Keyword.get(opts, :subscribe, true), do: subscribe_fw_progress()

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
    new_state = %{state | last: read_values(state.sources, state.supported?)}
    schedule(new_state.tick_ms)
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_call(:list_entities, _from, state) do
    {:reply, advertisements(@specs, state.supported?), state}
  end

  # Returns the last-polled values (seeded at startup) — no source reads on
  # the connection-accept path. Values may be up to one tick stale.
  def handle_call(:initial_states, _from, state) do
    {:reply, state_responses(@specs, state.last, state.supported?), state}
  end

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
  def handle_info({:fw_update_progress, _payload}, state) do
    value = read_update_value(state.sources)

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

  def handle_info(_msg, state), do: {:noreply, state}

  # Read every source, push only changed values, and return the new state.
  defp do_poll(state) do
    values = read_values(state.sources, state.supported?)

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
      {"firmware_update", :UPDATE_COMMAND_UPDATE} -> log_fw(FirmwareUpdate.install_latest())
      {"firmware_update", :UPDATE_COMMAND_CHECK} -> log_fw(FirmwareUpdate.check())
      other -> Logger.info("EntityProvider: ignoring update command #{inspect(other)}")
    end

    {:noreply, state}
  end

  def handle_cast({:command, other}, state) do
    Logger.debug("EntityProvider: ignoring unknown command #{inspect(other)}")
    {:noreply, state}
  end

  defp log_fw(:ok), do: :ok

  defp log_fw({:error, reason}),
    do: Logger.info("EntityProvider: firmware update command rejected: #{inspect(reason)}")

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
  def read_values(sources, supported?) do
    metrics = safe(sources.metrics, %{})
    wifi = safe(sources.wifi, nil)
    firmware = safe(sources.firmware, %{})
    audio = safe(sources.audio, [])

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
      "firmware_version" => Map.get(firmware, :version),
      "board_target" => Map.get(firmware, :target),
      "network_type" => network_type_label(safe(sources.network_type, :disconnected)),
      "ip_address" => safe(sources.ip, nil),
      "firmware_update" => read_update_value(sources)
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

  @doc false
  @spec read_update_value(map()) :: map() | nil
  def read_update_value(sources) do
    update_value(
      safe(sources.fw_update, nil),
      safe(sources.fw_version, nil),
      safe(sources.fw_repo, nil)
    )
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
      bt_stats: &Stats.current/0,
      adapters: &bt_adapters/0,
      fw_update: &FirmwareUpdate.state/0,
      fw_version: &FirmwareUpdate.current_version/0,
      fw_repo: &ConfigStore.get_repo/0
    }

    Map.merge(defaults, Map.new(Keyword.get(opts, :sources, [])))
  end

  defp device_ip, do: System.device_summary().ip
  defp client_count, do: length(Clients.list())

  # Prefer the BlueZ Powered property; fall back to radio presence if the
  # D-Bus client isn't answering.
  defp bt_adapters do
    case Bluez.Client.adapters_info() do
      [] -> Enum.map(RadioMonitor.list(), &%{powered: Map.get(&1, :in_use?, false)})
      infos -> infos
    end
  end
end
