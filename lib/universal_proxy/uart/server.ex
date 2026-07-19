defmodule UniversalProxy.UART.Server do
  @moduledoc """
  GenServer that manages a registry of opened UART ports.

  Each opened port gets its own `Circuits.UART` GenServer started under
  the `UniversalProxy.UART.PortSupervisor` DynamicSupervisor. This server
  tracks the mapping of port names to their PIDs and configurations, and
  monitors each UART process to clean up on unexpected exits.

  Ports are opened and closed exclusively by ESPHome clients via serial
  proxy protocol messages. There is no auto-open behaviour.

  Periodically polls `Circuits.UART.enumerate()` to detect USB hotplug
  events. When the set of connected serial numbers changes, the ESPHome
  supervisor is restarted so clients reconnect with the updated device list.
  A removed device's persisted line settings are also cleared from
  `UniversalProxy.UART.SettingsStore`, so a different adapter later
  plugged into the same physical port never inherits a stale baud rate.

  Incoming UART data is broadcast to PubSub topic `"uart:<friendly_name>"`.
  """

  use GenServer

  require Logger

  alias UniversalProxy.Hardware
  alias UniversalProxy.UART.PortConfig
  alias UniversalProxy.UART.SettingsStore

  @pubsub UniversalProxy.PubSub
  @hotplug_interval 5_000
  @irdroid_vendor_id 0x04D8
  @irdroid_product_ids MapSet.new([0xFD08, 0xF58B])

  # -- Client API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Open a serial port with the given options.

  Starts a `Circuits.UART` GenServer under the DynamicSupervisor,
  opens the named port, and registers it in the server state.

  Returns `{:ok, pid}` on success or `{:error, reason}` on failure.
  """
  @spec open_port(binary(), keyword()) :: {:ok, pid()} | {:error, term()}
  def open_port(port_name, opts \\ []) do
    GenServer.call(__MODULE__, {:open_port, port_name, opts})
  end

  @doc """
  Close a previously opened serial port.

  Closes the underlying `Circuits.UART` connection, stops the GenServer,
  and removes it from the registry.
  """
  @spec close_port(binary()) :: :ok | {:error, term()}
  def close_port(port_name) do
    GenServer.call(__MODULE__, {:close_port, port_name})
  end

  @doc """
  Write binary data to an opened serial port.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec write_port(binary(), binary()) :: :ok | {:error, term()}
  def write_port(port_name, data) do
    GenServer.call(__MODULE__, {:write_port, port_name, data})
  end

  @doc """
  List all currently opened ports and their configurations.

  Returns a list of `{port_name, %PortConfig{}}` tuples.
  """
  @spec list_ports() :: [{binary(), PortConfig.t()}]
  def list_ports do
    GenServer.call(__MODULE__, :list_ports)
  end

  @doc """
  List opened ports with their friendly names for display.

  Returns a sorted list of maps with `:path`, `:friendly_name`, and `:speed`.
  """
  @spec named_ports() :: [map()]
  def named_ports do
    GenServer.call(__MODULE__, :named_ports)
  end

  @doc """
  Get the configuration for a specific opened port.

  Returns `{:ok, %PortConfig{}}` or `{:error, :not_found}`.
  """
  @spec port_info(binary()) :: {:ok, PortConfig.t()} | {:error, :not_found}
  def port_info(port_name) do
    GenServer.call(__MODULE__, {:port_info, port_name})
  end

  @doc """
  Close all currently open UART ports.

  Used during ESPHome supervisor restarts to ensure ports opened by
  connection handlers are properly released before the handlers are killed.
  """
  @spec close_all_ports() :: :ok
  def close_all_ports do
    GenServer.call(__MODULE__, :close_all_ports)
  end

  # -- Server Callbacks --

  @impl true
  def init(opts) do
    # Restart hygiene: a Server-only crash leaves PortSupervisor children
    # running (`:rest_for_one` restarts the Server but never touches the
    # PortSupervisor started before it), and the fresh Server has no
    # record of them — orphaned Circuits.UART processes holding ttys
    # open. Terminate any leftovers; ESPHome clients reopen ports via
    # the serial-proxy protocol. Mirrors `Audio.Server.init`'s
    # `terminate_all_players` sweep.
    sweep_orphaned_ports()

    :timer.send_interval(@hotplug_interval, self(), :check_hotplug)
    known = current_serial_set()
    Logger.info("UART server started, #{MapSet.size(known)} serial devices detected")

    {:ok,
     %{
       ports: %{},
       known_serials: known,
       port_ids_by_serial: safe_port_ids_by_serial(),
       settings_store: Keyword.get(opts, :settings_store, SettingsStore)
     }}
  end

  @impl true
  def handle_call({:open_port, port_name, opts}, _from, state) do
    if Map.has_key?(state.ports, port_name) do
      {:reply, {:error, :already_open}, state}
    else
      case start_and_open(port_name, opts) do
        {:ok, pid, config} ->
          ref = Process.monitor(pid)
          entry = %{pid: pid, config: config, monitor_ref: ref}
          new_state = put_in(state, [:ports, port_name], entry)
          broadcast_lifecycle("uart:port_opened", port_name, config)
          {:reply, {:ok, pid}, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:close_port, port_name}, _from, state) do
    case Map.fetch(state.ports, port_name) do
      {:ok, %{pid: pid, config: config, monitor_ref: ref}} ->
        Process.demonitor(ref, [:flush])
        Circuits.UART.close(pid)
        Circuits.UART.stop(pid)
        new_state = %{state | ports: Map.delete(state.ports, port_name)}
        broadcast_lifecycle("uart:port_closed", port_name, config)
        {:reply, :ok, new_state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:write_port, port_name, data}, _from, state) do
    case Map.fetch(state.ports, port_name) do
      {:ok, %{pid: pid, config: config}} ->
        case Circuits.UART.write(pid, data) do
          :ok ->
            friendly_name = config.friendly_name || port_name
            broadcast_data(friendly_name, data, DateTime.utc_now(), :tx)
            {:reply, :ok, state}

          other ->
            {:reply, other, state}
        end

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list_ports, _from, state) do
    result =
      state.ports
      |> Enum.map(fn {name, %{config: config}} -> {name, config} end)
      |> Enum.sort_by(fn {name, _} -> name end)

    {:reply, result, state}
  end

  def handle_call(:named_ports, _from, state) do
    result =
      state.ports
      |> Enum.map(fn {path, %{config: config}} ->
        %{
          path: path,
          friendly_name: config.friendly_name || path,
          speed: config.speed
        }
      end)
      |> Enum.sort_by(& &1.friendly_name)

    {:reply, result, state}
  end

  def handle_call({:port_info, port_name}, _from, state) do
    case Map.fetch(state.ports, port_name) do
      {:ok, %{config: config}} ->
        {:reply, {:ok, config}, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:close_all_ports, _from, state) do
    Enum.each(state.ports, fn {port_name, %{pid: pid, config: config, monitor_ref: ref}} ->
      Process.demonitor(ref, [:flush])

      try do
        Circuits.UART.close(pid)
        Circuits.UART.stop(pid)
      catch
        _, _ -> :ok
      end

      broadcast_lifecycle("uart:port_closed", port_name, config)

      Logger.info(
        "UART closed #{config.friendly_name || port_name} (#{port_name}) during ESPHome restart"
      )
    end)

    {:reply, :ok, %{state | ports: %{}}}
  end

  @impl true
  def handle_info(:check_hotplug, state) do
    current = current_serial_set()

    if current != state.known_serials do
      added = MapSet.difference(current, state.known_serials)
      removed = MapSet.difference(state.known_serials, current)

      if MapSet.size(added) > 0 do
        Logger.info("UART hotplug: devices added: #{Enum.join(added, ", ")}")
      end

      if MapSet.size(removed) > 0 do
        Logger.info("UART hotplug: devices removed: #{Enum.join(removed, ", ")}")
        clear_removed_settings(removed, state.port_ids_by_serial, state.settings_store)
      end

      Task.Supervisor.start_child(UniversalProxy.TaskSupervisor, fn ->
        UniversalProxy.ESPHome.Supervisor.restart()
      end)

      # Refreshed only here, in the changed branch — a same-set poll
      # can't move a device between slots without its serial
      # appearing/disappearing in some tick, EXCEPT an unplug+replug of
      # the same device into a DIFFERENT slot within one
      # @hotplug_interval window. That corner keeps the old entry keyed
      # to the old slot, which the next open in the new slot re-learns
      # anyway, so it's left unhandled.
      {:noreply, %{state | known_serials: current, port_ids_by_serial: safe_port_ids_by_serial()}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:circuits_uart, port_name, {:error, reason}}, state) do
    case Map.fetch(state.ports, port_name) do
      {:ok, %{config: config, pid: pid, monitor_ref: ref}} ->
        friendly_name = config.friendly_name || port_name

        Logger.warning(
          "UART #{friendly_name} (#{port_name}) error: #{inspect(reason)} -- closing port and restarting ESPHome"
        )

        Process.demonitor(ref, [:flush])

        try do
          Circuits.UART.close(pid)
          Circuits.UART.stop(pid)
        catch
          _, _ -> :ok
        end

        new_state = %{state | ports: Map.delete(state.ports, port_name)}
        broadcast_lifecycle("uart:port_closed", port_name, config)

        Task.Supervisor.start_child(UniversalProxy.TaskSupervisor, fn ->
          UniversalProxy.ESPHome.Supervisor.restart()
        end)

        {:noreply, new_state}

      :error ->
        Logger.debug("UART error from untracked port #{port_name}: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info({:circuits_uart, port_name, data}, state) when is_binary(data) do
    case Map.fetch(state.ports, port_name) do
      {:ok, %{config: config}} ->
        friendly_name = config.friendly_name || port_name
        broadcast_data(friendly_name, data, DateTime.utc_now(), :rx)

      :error ->
        Logger.debug("UART data from untracked port: #{port_name}")
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {port_name, entry} =
      Enum.find(state.ports, {nil, nil}, fn {_name, %{monitor_ref: r}} -> r == ref end)

    if port_name do
      if entry, do: broadcast_lifecycle("uart:port_closed", port_name, entry.config)
      new_state = %{state | ports: Map.delete(state.ports, port_name)}
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # -- Private Helpers --

  # `:temporary` so the DynamicSupervisor never respawns a port process
  # on its own — Circuits.UART children default to `:permanent`, and a
  # permanent child restarts even on the normal exit from `stop/1`,
  # leaving an untracked replacement (plus its C port program) leaked
  # on every close. This Server's monitor + `:DOWN` bookkeeping is the
  # single owner of port lifecycle. Public (`@doc false`) so tests can
  # exercise the exact production spec.
  @doc false
  def port_child_spec do
    Supervisor.child_spec({Circuits.UART, []}, restart: :temporary)
  end

  defp sweep_orphaned_ports do
    UniversalProxy.UART.PortSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn {_id, pid, _type, _modules} when is_pid(pid) ->
      Logger.warning("UART sweeping orphaned port process #{inspect(pid)} from previous Server")
      _ = DynamicSupervisor.terminate_child(UniversalProxy.UART.PortSupervisor, pid)
    end)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp start_and_open(port_name, opts) do
    config = PortConfig.new(port_name, opts)
    uart_opts = PortConfig.to_uart_opts(config)

    with {:ok, pid} <-
           DynamicSupervisor.start_child(UniversalProxy.UART.PortSupervisor, port_child_spec()),
         :ok <- Circuits.UART.open(pid, port_name, uart_opts) do
      {:ok, pid, config}
    else
      {:error, _reason} = error ->
        error
    end
  end

  @spec current_serial_set() :: MapSet.t(String.t())
  defp current_serial_set do
    serials =
      try do
        Circuits.UART.enumerate()
        |> Enum.filter(fn {_path, info} -> present?(info[:serial_number]) end)
        |> Enum.map(fn {_path, info} -> info[:serial_number] end)
      rescue
        e ->
          Logger.warning("UART enumerate failed: #{Exception.format(:error, e, __STACKTRACE__)}")

          []
      end

    MapSet.new(serials)
  end

  # `Hardware.port_ids_by_serial/1` only walks sysfs and reads
  # `Circuits.UART.enumerate/0` today — no GenServer call involved — but
  # this runs on every hotplug poll, so keep it defensive and cheap
  # rather than assume that stays true forever.
  @spec safe_port_ids_by_serial() :: %{String.t() => String.t()}
  defp safe_port_ids_by_serial do
    Hardware.port_ids_by_serial()
  rescue
    e ->
      Logger.warning(
        "UART port_ids_by_serial failed: #{Exception.format(:error, e, __STACKTRACE__)}"
      )

      %{}
  catch
    :exit, _ -> %{}
  end

  # Public (`@doc false`) so tests can exercise the settings-clearing
  # logic directly against a test-local SettingsStore, without going
  # through `handle_info(:check_hotplug, _)` — that handler always fires
  # a real `ESPHome.Supervisor.restart/0` on a serial-set change, which
  # must not run against the app-global supervision tree from a test.
  @doc false
  def clear_removed_settings(removed, port_ids_by_serial, settings_store) do
    Enum.each(removed, fn serial ->
      case Map.fetch(port_ids_by_serial, serial) do
        {:ok, port_id} -> clear_settings(port_id, serial, settings_store)
        :error -> :ok
      end
    end)
  end

  # Best-effort: a wedged or absent SettingsStore must not crash the
  # UART server over a hotplug event it can't fully act on (public-API
  # `catch :exit` idiom, CLAUDE.md) — worst case a stale baud lingers
  # until a later unplug succeeds in clearing it.
  defp clear_settings(port_id, serial, settings_store) do
    case SettingsStore.delete_opts(settings_store, port_id) do
      :ok ->
        Logger.info(
          "UART hotplug: cleared persisted line settings for #{port_id} (#{serial} unplugged)"
        )

      {:error, reason} ->
        Logger.warning(
          "UART hotplug: failed to clear persisted line settings for #{port_id}: #{inspect(reason)}"
        )
    end
  catch
    :exit, reason ->
      Logger.warning(
        "UART hotplug: settings store unavailable while clearing #{port_id}: #{inspect(reason)}"
      )
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(s) when is_binary(s), do: String.trim(s) != ""
  defp present?(_), do: false

  # Broadcasts run synchronously inside the GenServer so subscribers
  # receive `:uart_data` messages in the same order this process saw
  # the underlying read/write. `UART.History` assigns its display id
  # on arrival, so an out-of-order broadcast (e.g. via
  # `Task.Supervisor.start_child`) would show TX echoes in the
  # Traffic log *after* the RX response they triggered. At our scale
  # (single node, ≤ a few subscribers per port, in-process PG2
  # backend) the fanout cost is negligible — if it ever isn't, a
  # dedicated serial broadcaster GenServer is the right next step
  # rather than fire-and-forget tasks.
  defp broadcast_data(friendly_name, data, timestamp, dir) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      "uart:#{friendly_name}",
      {:uart_data, %{name: friendly_name, data: data, timestamp: timestamp, dir: dir}}
    )
  end

  # Two lifecycle topics; the broadcast tag mirrors the topic name so
  # subscribers can pattern-match on `{:uart_port_opened, info}` etc.
  # The atoms must be created statically — never via `String.to_atom/1`
  # — to avoid atom-exhaustion exposure if `topic` ever became dynamic.
  defp broadcast_lifecycle("uart:port_opened" = topic, port_name, config) do
    do_broadcast(topic, :uart_port_opened, port_name, config)
  end

  defp broadcast_lifecycle("uart:port_closed" = topic, port_name, config) do
    do_broadcast(topic, :uart_port_closed, port_name, config)
  end

  defp do_broadcast(topic, event, port_name, config) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      topic,
      {event, %{path: port_name, friendly_name: config.friendly_name || port_name}}
    )
  end

  # Branded-device VID/PID predicates retained for the test suite and
  # for any caller that wants to ask "is this a ZWA-2/IRdroid?" by USB
  # descriptor. Auto-classification of the saved-config kind is handled
  # by `UniversalProxy.Hardware`'s `@usb_devices` table — those branded
  # entries carry `locked: true` so ESPHome consumers (Supervisor and
  # Infrared.Server) pick them up directly via `Hardware.list_ports/0`
  # without needing a saved-config row.

  # ZWA-2 USB VID/PID from Home Assistant's zwave_js manifest.
  @zwa2_vid 0x303A
  @zwa2_pid 0x4001

  @doc false
  def zwa2_device?(info) do
    info[:vendor_id] == @zwa2_vid and info[:product_id] == @zwa2_pid
  end

  @doc false
  def irdroid_device?(info) do
    vendor_id_matches?(info[:vendor_id]) and product_id_matches?(info[:product_id])
  end

  defp vendor_id_matches?(id) when is_integer(id), do: id == @irdroid_vendor_id

  defp vendor_id_matches?(id) when is_binary(id),
    do: UniversalProxy.USB.parse_id(id) == @irdroid_vendor_id

  defp vendor_id_matches?(_), do: false

  defp product_id_matches?(id) when is_integer(id), do: MapSet.member?(@irdroid_product_ids, id)

  defp product_id_matches?(id) when is_binary(id),
    do: MapSet.member?(@irdroid_product_ids, UniversalProxy.USB.parse_id(id))

  defp product_id_matches?(_), do: false
end
