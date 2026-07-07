defmodule UniversalProxy.Bluetooth.AudioManager do
  @moduledoc """
  Owns the lifecycle of Bluetooth A2DP **headsets** (sinks): discovery,
  pairing, connect/disconnect, forget, and auto-reconnect on boot. The audio
  *output* itself surfaces through the existing pipeline once a headset is
  connected (`UniversalProxy.Bluetooth.AudioSink` → composite enumerate →
  `Audio.Server`); this module is the persistent control surface for the
  Bluetooth tab — including paired-but-disconnected headsets, which the
  enumerate path drops.

  ## Roles & multiple audio adapters

  Pairing/scanning only proceed on an adapter assigned the `:audio` role
  (`UniversalProxy.Bluetooth.Settings`). With no `:audio` adapter, the mutating
  calls refuse with `{:error, :no_audio_adapter}`. The audio-role MAC is
  resolved to its `hciX` object path via `Bluez.Client` adapter
  info — the same MAC→path mechanism the proxy uses (hci indices aren't stable
  across boots).

  **Several adapters may be `:audio`** (e.g. one BT radio per speaker).
  Because a BlueZ bond is **per-adapter** — a device paired on hci0 is bonded
  to hci0 and is not usable via hci1 without re-pairing — `scan/2` and `pair/3`
  take an explicit adapter MAC (`nil` = the first audio adapter, the common
  single-adapter case); pass an unknown/non-audio MAC and they refuse with
  `{:error, :not_audio_adapter}`. `list_audio_adapters/1` enumerates the
  choices for a UI selector. `connect`/`disconnect`/`forget`/reconnect are
  adapter-agnostic: they act on the device's existing bond, resolving its real
  managed-object path (and so the adapter it lives on) automatically.

  ## Reconnect

  Headsets do **not** reliably auto-reconnect, so on boot (and on a retry
  timer) this issues `Device1.Connect` for every trusted A2DP-sink headset on
  an `:audio` adapter. `Connect` can take ~25 s, so it runs under a
  `Task.Supervisor` and never blocks the GenServer loop (mirrors
  `Bluez.Gatt`).

  ## D-Bus injection / testability

  All `org.bluez` operations go through an `ops` module (the `Ops` behaviour),
  defaulting to `UniversalProxy.Bluetooth.AudioManager.LiveOps`. Every callback
  takes the rebus `conn` first; tests inject a mock (ignoring `conn`) so the
  pairing state machine, role enforcement, the AudioSink-UUID filter, and
  reconnect-target selection are exercised without a controller.

  Scan results and connection-state changes fan out over PubSub:

    * `"bluetooth:scan"`  — `{:bt_scan, :stopped}` (discovered devices arrive
      via the existing org.bluez signal path the LiveView already consumes).
    * `"bluetooth:audio"` — `{:bt_audio, :pairing, mac, step | {:error, reason}}`
      and `{:bt_audio, :connection, mac, :connected | :disconnected}`.
  """

  use GenServer
  require Logger

  alias UniversalProxy.Bluetooth.Settings

  # A2DP Sink service UUID (headphones advertise this — they're the sink).
  @audio_sink_uuid "0000110b-0000-1000-8000-00805f9b34fb"

  @scan_topic "bluetooth:scan"
  @audio_topic "bluetooth:audio"

  @default_scan_ms 30_000
  @default_reconnect_ms 60_000

  @type mac :: String.t()

  defmodule Ops do
    @moduledoc "org.bluez operations AudioManager depends on; mocked in tests."
    @type conn :: pid() | nil
    # adapters_info entries are `%{path: String, address: String | nil, ...}`.
    @callback adapters_info(conn()) :: [map()]
    @callback managed_devices(conn()) :: [
                %{
                  :path => String.t(),
                  :mac => String.t(),
                  :props => map(),
                  optional(:battery) => non_neg_integer() | nil
                }
              ]
    @callback start_discovery(conn(), adapter_path :: String.t()) :: :ok | {:error, term()}
    @callback stop_discovery(conn(), adapter_path :: String.t()) :: :ok | {:error, term()}
    @callback pair(conn(), device_path :: String.t()) :: :ok | {:error, term()}
    @callback set_trusted(conn(), device_path :: String.t(), boolean()) :: :ok | {:error, term()}
    @callback connect(conn(), device_path :: String.t()) :: :ok | {:error, term()}
    @callback disconnect(conn(), device_path :: String.t()) :: :ok | {:error, term()}
    @callback remove(conn(), adapter_path :: String.t(), device_path :: String.t()) ::
                :ok | {:error, term()}
  end

  # -- Client API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Paired audio headsets with connection status (incl. disconnected)."
  @spec list_headphones(GenServer.server()) :: [map()]
  def list_headphones(server \\ __MODULE__), do: call(server, :list_headphones, [])

  @doc """
  The `:audio`-role adapters available to pair/scan on, as `%{mac, path}` —
  the choices a UI presents when more than one audio radio is configured.
  """
  @spec list_audio_adapters(GenServer.server()) :: [%{mac: String.t(), path: String.t()}]
  def list_audio_adapters(server \\ __MODULE__), do: call(server, :list_audio_adapters, [])

  @doc """
  Begin a (filtered) scan for A2DP speakers/headsets on a specific `:audio`
  adapter (MAC); `nil` uses the first audio adapter (the single-adapter case).
  Auto-stops after ~30 s. Pair on the **same** adapter you scanned (a BlueZ
  bond is per-adapter).
  """
  @spec start_scan(GenServer.server(), mac() | nil) :: :ok | {:error, term()}
  def start_scan(server \\ __MODULE__, adapter_mac),
    do: call(server, {:start_scan, adapter_mac}, {:error, :not_running})

  @doc "Stop an in-progress scan."
  @spec stop_scan(GenServer.server()) :: :ok
  def stop_scan(server \\ __MODULE__), do: call(server, :stop_scan, :ok)

  @doc """
  Pair → trust → connect a speaker/headset by MAC, bonding it to a specific
  `:audio` adapter (MAC); `nil` uses the first audio adapter. The device must
  have been discovered on that same adapter (BlueZ pairings are per-adapter, so
  this choice fixes which radio streams to the device).
  """
  @spec pair(GenServer.server(), mac(), mac() | nil) :: :ok | {:error, term()}
  def pair(server \\ __MODULE__, mac, adapter_mac),
    do: call(server, {:pair, mac, adapter_mac}, {:error, :not_running})

  @doc "Connect an already-paired headset."
  @spec connect(GenServer.server(), mac()) :: :ok | {:error, term()}
  def connect(server \\ __MODULE__, mac),
    do: call(server, {:connect, mac}, {:error, :not_running})

  @doc "Disconnect a connected headset (stays paired)."
  @spec disconnect(GenServer.server(), mac()) :: :ok | {:error, term()}
  def disconnect(server \\ __MODULE__, mac),
    do: call(server, {:disconnect, mac}, {:error, :not_running})

  @doc "Forget (unpair + remove) a headset."
  @spec forget(GenServer.server(), mac()) :: :ok | {:error, term()}
  def forget(server \\ __MODULE__, mac), do: call(server, {:forget, mac}, {:error, :not_running})

  @doc """
  Disconnect + forget every A2DP-sink device bonded to the given adapter MAC.
  Used when an adapter leaves the `:audio` role: a BlueZ bond is per-adapter, so
  deactivating a radio orphans its speakers — this removes them cleanly. The
  adapter is resolved from the raw adapter list (role-independent), so it works
  even after the role has already flipped off. Returns `:ok` (accepted).
  """
  @spec forget_all_on_adapter(GenServer.server(), mac()) :: :ok
  def forget_all_on_adapter(server \\ __MODULE__, adapter_mac),
    do: call(server, {:forget_all_on_adapter, adapter_mac}, :ok)

  # Exit-safe call: off-target/not-running yields the inert default.
  defp call(server, msg, default) do
    GenServer.call(server, msg)
  catch
    :exit, _ -> default
  end

  # -- Pure helpers (public for direct unit testing) --

  @doc "Whether a device's `UUIDs` list marks it an A2DP sink (headphones)."
  @spec audio_sink?([String.t()]) :: boolean()
  def audio_sink?(uuids) when is_list(uuids),
    do: Enum.any?(uuids, &(is_binary(&1) and String.downcase(&1) == @audio_sink_uuid))

  def audio_sink?(_), do: false

  @doc """
  MACs to (re)connect: trusted A2DP-sink headsets that aren't currently
  connected and sit on one of the given `:audio`-role adapter paths.
  `devices` are managed-object maps `%{path, mac, props}`.
  """
  @spec reconnect_targets([map()], [String.t()]) :: [String.t()]
  def reconnect_targets(devices, audio_adapter_paths) do
    for %{mac: mac, path: path, props: props} <- devices,
        on_audio_adapter?(path, audio_adapter_paths),
        props["Trusted"] == true,
        props["Connected"] != true,
        audio_sink?(props["UUIDs"] || []),
        do: mac
  end

  defp on_audio_adapter?(device_path, adapter_paths),
    do: Enum.any?(adapter_paths, &String.starts_with?(device_path, &1 <> "/"))

  @doc false
  @spec audio_sink_uuid() :: String.t()
  def audio_sink_uuid, do: @audio_sink_uuid

  # -- Server callbacks --

  @impl true
  def init(opts) do
    conn = connect_bus(Keyword.get(opts, :conn, :connect))

    state = %{
      conn: conn,
      # Monitor the bus connection like BlueAlsa does: if it dies we stop so
      # the Bluez supervisor restarts us with a fresh connection, rather than
      # silently calling into a dead pid forever.
      conn_ref: if(is_pid(conn), do: Process.monitor(conn), else: nil),
      ops: Keyword.get(opts, :ops, __MODULE__.LiveOps),
      settings: Keyword.get(opts, :settings, Settings),
      pubsub: Keyword.get(opts, :pubsub, UniversalProxy.PubSub),
      task_sup: Keyword.get(opts, :task_supervisor, __MODULE__.TaskSupervisor),
      scan_ms: Keyword.get(opts, :scan_ms, @default_scan_ms),
      reconnect_ms: Keyword.get(opts, :reconnect_ms, @default_reconnect_ms),
      reconnect?: Keyword.get(opts, :reconnect_on_boot, true),
      scanning?: false,
      scan_timer: nil,
      # Adapter path the in-flight scan is running on, so stop targets the
      # right radio when several :audio adapters exist.
      scan_path: nil
    }

    if state.reconnect?, do: {:ok, state, {:continue, :reconnect}}, else: {:ok, state}
  end

  # opts can pass an explicit conn (or nil) for tests; :connect builds a real
  # one. A failed connect is non-fatal — the module stays inert (LiveOps calls
  # would error → mapped failures) rather than crash-looping the BT subtree.
  defp connect_bus(:connect) do
    case Rebus.connect(:system) do
      {:ok, conn} -> conn
      {:error, _} -> nil
    end
  end

  defp connect_bus(conn), do: conn

  @impl true
  def handle_continue(:reconnect, state) do
    spawn_reconnect(state)
    schedule_reconnect(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:list_headphones, _from, state), do: {:reply, headphones(state), state}

  def handle_call(:list_audio_adapters, _from, state),
    do: {:reply, audio_adapters_info(state), state}

  def handle_call({:start_scan, adapter_mac}, _from, state) do
    case resolve_audio_adapter(state, adapter_mac) do
      {:ok, adapter} ->
        case state.ops.start_discovery(state.conn, adapter) do
          :ok ->
            if state.scan_timer, do: Process.cancel_timer(state.scan_timer)
            timer = Process.send_after(self(), :scan_timeout, state.scan_ms)
            {:reply, :ok, %{state | scanning?: true, scan_timer: timer, scan_path: adapter}}

          {:error, _} = err ->
            {:reply, err, state}
        end

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call(:stop_scan, _from, state), do: {:reply, :ok, do_stop_scan(state)}

  # Pair bonds to a SPECIFIC audio adapter (per-adapter bonds); the rest are
  # adapter-agnostic (they act on the device's existing bond). All run in a Task
  # (Pair ~90 s, Connect ~25 s) so the loop stays responsive. The call returns
  # :ok = "accepted"; progress + the final result fan out on "bluetooth:audio".
  def handle_call({:pair, mac, adapter_mac}, _from, state) do
    case resolve_audio_adapter(state, adapter_mac) do
      {:ok, adapter} -> {:reply, dispatch_pair(state, mac, adapter), state}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:connect, mac}, _from, state),
    do: {:reply, dispatch(state, mac, &connect_and_broadcast(state, &1, mac)), state}

  def handle_call({:disconnect, mac}, _from, state),
    do: {:reply, dispatch(state, mac, &disconnect_and_broadcast(state, &1, mac)), state}

  def handle_call({:forget, mac}, _from, state),
    do: {:reply, dispatch(state, mac, &forget_flow(state, mac, &1)), state}

  def handle_call({:forget_all_on_adapter, adapter_mac}, _from, state),
    do: {:reply, forget_all(state, adapter_mac), state}

  @impl true
  def handle_info(:scan_timeout, state), do: {:noreply, do_stop_scan(state)}

  def handle_info(:reconnect_tick, state) do
    spawn_reconnect(state)
    schedule_reconnect(state)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{conn_ref: ref} = state),
    do: {:stop, {:dbus_connection_down, reason}, state}

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Pairing / connect flows --

  # Pair → Trust → Connect, gated through the existing org.bluez Agent so
  # bluetoothd routes pairing IO to us. Failures map to PubSub error events.
  defp pair_flow(state, device_path, mac) do
    expect_pairing(device_path)

    result =
      with :ok <- step(state, mac, :pairing, fn -> state.ops.pair(state.conn, device_path) end),
           :ok <-
             step(state, mac, :trusting, fn ->
               state.ops.set_trusted(state.conn, device_path, true)
             end),
           :ok <-
             step(state, mac, :connecting, fn -> state.ops.connect(state.conn, device_path) end) do
        broadcast_pairing(state, mac, :connected)
        :ok
      end

    pairing_done(device_path)
    result
  end

  defp step(state, mac, label, fun) do
    broadcast_pairing(state, mac, label)

    case fun.() do
      :ok ->
        :ok

      {:error, reason} ->
        mapped = map_failure(reason)
        broadcast_pairing(state, mac, {:error, mapped})
        {:error, mapped}
    end
  end

  # Run `fun.(device_path)` for `mac` in a Task so the loop never blocks on a
  # slow D-Bus call. Returns :ok ("accepted") when an :audio adapter exists,
  # `{:error, :no_audio_adapter}` otherwise. The path is resolved inside the
  # task (a D-Bus round-trip) to the device's real managed-object path.
  defp dispatch(state, mac, fun) do
    if audio_adapter_paths(state) == [] do
      {:error, :no_audio_adapter}
    else
      task = fn ->
        case resolve_device_path(state, mac) do
          {:ok, device_path} ->
            fun.(device_path)

          # The audio adapter went away between the guard above and here (e.g.
          # the dongle was unplugged mid-op). The op can't run, but subscribers
          # must still refresh — the device is gone — so emit a disconnect.
          :no_audio_adapter ->
            broadcast_connection(state, mac, :disconnected)
        end
      end

      # Fall back to running inline if the supervisor is unavailable (keeps the
      # op working, just on the loop — only happens in degenerate test setups).
      case Task.Supervisor.start_child(state.task_sup, task) do
        {:ok, _pid} -> :ok
        {:error, _} -> task.()
      end

      :ok
    end
  end

  # Pair on a SPECIFIC adapter: bond `mac` to `adapter_path`. Use the device's
  # real managed-object path if it was already discovered under that adapter,
  # else construct it there (a freshly-discovered, not-yet-paired device). Runs
  # in a Task; returns :ok ("accepted").
  defp dispatch_pair(state, mac, adapter_path) do
    task = fn ->
      device_path =
        managed_device_path(state, mac, adapter_path) || device_path_under(adapter_path, mac)

      pair_flow(state, device_path, mac)
    end

    case Task.Supervisor.start_child(state.task_sup, task) do
      {:ok, _pid} -> :ok
      {:error, _} -> task.()
    end

    :ok
  end

  # The body of a connect: issue Device1.Connect and broadcast the outcome.
  defp connect_and_broadcast(state, device_path, mac) do
    case state.ops.connect(state.conn, device_path) do
      :ok ->
        broadcast_connection(state, mac, :connected)

      # This is the connect/reconnect path (not pairing), so report the failure
      # as a `:connection` event — that's the stream Audio.Server and the
      # LiveViews watch. (pair_flow/step keeps its own `:pairing` error events.)
      {:error, reason} ->
        Logger.warning("Bluetooth connect failed for #{mac}: #{inspect(reason)}")
        broadcast_connection(state, mac, :disconnected)
    end
  end

  # Disconnect + RemoveDevice every A2DP-sink bonded to `adapter_mac`. Resolves
  # the adapter from the RAW adapter list (not role-filtered) so it works even
  # once the role has flipped off. Runs in a Task; broadcasts a disconnect per
  # device so subscribers refresh.
  defp forget_all(state, adapter_mac) do
    case raw_adapter_path(state, adapter_mac) do
      nil ->
        :ok

      adapter_path ->
        devices =
          Enum.filter(managed_devices(state), fn d ->
            String.starts_with?(d.path, adapter_path <> "/") and
              audio_sink?(d.props["UUIDs"] || [])
          end)

        spawn_task(state, fn ->
          Enum.each(devices, fn d ->
            _ = state.ops.disconnect(state.conn, d.path)
            _ = state.ops.remove(state.conn, adapter_path, d.path)
            broadcast_connection(state, d.mac, :disconnected)
          end)
        end)

        :ok
    end
  end

  # Object path for an adapter MAC across ALL adapters (any role / none).
  defp raw_adapter_path(state, adapter_mac) do
    norm = String.upcase(adapter_mac)

    Enum.find_value(safe_call(fn -> state.ops.adapters_info(state.conn) end, []), fn a ->
      if is_binary(a[:address]) and String.upcase(a[:address]) == norm, do: a[:path]
    end)
  end

  # Run `fun` under the Task.Supervisor; inline fallback if it's unavailable.
  defp spawn_task(state, fun) do
    case Task.Supervisor.start_child(state.task_sup, fun) do
      {:ok, _pid} -> :ok
      {:error, _} -> fun.()
    end
  end

  # RemoveDevice/Disconnect emit no org.bluez signal we currently subscribe to,
  # so subscribers (the Bluetooth tab + Audio.Server, which has no kernel uevent
  # for a BlueALSA PCM) would never learn the device went away. Broadcast a
  # `:disconnected` after the op — for forget, *after* RemoveDevice so a list
  # refresh no longer sees the device. (forget_all/0 already does this per
  # device; the per-device forget/disconnect paths were missing it, which left
  # the UI card lingering after a confirmed Forget.)
  defp forget_flow(state, mac, device_path) do
    _ = state.ops.disconnect(state.conn, device_path)

    result =
      case adapter_path_for_device(device_path, state) do
        nil -> {:error, :no_audio_adapter}
        adapter -> state.ops.remove(state.conn, adapter, device_path)
      end

    broadcast_connection(state, mac, :disconnected)
    result
  end

  defp disconnect_and_broadcast(state, device_path, mac) do
    result = state.ops.disconnect(state.conn, device_path)
    broadcast_connection(state, mac, :disconnected)
    result
  end

  defp spawn_reconnect(state) do
    Task.Supervisor.start_child(state.task_sup, fn -> reconnect_all(state) end)
  end

  # Reconnect every trusted, disconnected A2DP-sink headset to *its own*
  # adapter (using the real managed-object path, not a path reconstructed under
  # the first adapter — a device may live on a different audio adapter). Each
  # Connect runs as its own task so multiple headsets reconnect concurrently.
  defp reconnect_all(state) do
    paths = audio_adapter_paths(state)

    if paths != [] do
      devices = managed_devices(state)
      by_mac = Map.new(devices, &{&1.mac, &1.path})

      devices
      |> reconnect_targets(paths)
      |> Enum.each(fn mac ->
        device_path = Map.fetch!(by_mac, mac)

        Task.Supervisor.start_child(state.task_sup, fn ->
          connect_and_broadcast(state, device_path, mac)
        end)
      end)
    end
  end

  # -- Role / adapter resolution --

  # Resolve a MAC to its device object path: prefer the real managed-object
  # path (so connect/disconnect/forget target the adapter it's actually paired
  # to), falling back to constructing it under the first audio adapter — used
  # when pairing a freshly-discovered device not yet in managed objects.
  defp resolve_device_path(state, mac) do
    case audio_adapter_paths(state) do
      [] ->
        :no_audio_adapter

      [adapter | _] = paths ->
        norm = String.upcase(mac)

        path =
          Enum.find_value(managed_devices(state), fn d ->
            if d.mac == norm and on_audio_adapter?(d.path, paths), do: d.path
          end)

        {:ok, path || device_path_under(adapter, mac)}
    end
  end

  # The :audio-role adapters present on the bus, as %{mac, path}. Joins the
  # Settings role assignment (by MAC) with the live adapter objects (MAC→path),
  # since hci indices aren't stable.
  defp audio_adapters_info(state) do
    settings = Settings.get(state.settings)
    audio_macs = MapSet.new(Settings.audio_adapters(settings))

    for %{path: path, address: addr} <-
          safe_call(fn -> state.ops.adapters_info(state.conn) end, []),
        is_binary(addr),
        mac = String.upcase(addr),
        MapSet.member?(audio_macs, mac),
        do: %{mac: mac, path: path}
  end

  # Object paths of the :audio-role adapters.
  defp audio_adapter_paths(state), do: Enum.map(audio_adapters_info(state), & &1.path)

  # Resolve a requested adapter MAC (nil = first audio adapter) to its object
  # path, validating it actually has the :audio role.
  defp resolve_audio_adapter(state, adapter_mac) do
    case {audio_adapters_info(state), adapter_mac} do
      {[], _} -> {:error, :no_audio_adapter}
      {[first | _], nil} -> {:ok, first.path}
      {adapters, mac} -> find_audio_adapter(adapters, String.upcase(mac))
    end
  end

  defp find_audio_adapter(adapters, mac) do
    case Enum.find(adapters, &(&1.mac == mac)) do
      %{path: path} -> {:ok, path}
      nil -> {:error, :not_audio_adapter}
    end
  end

  # The real managed-object path for `mac` under a specific adapter, if present.
  defp managed_device_path(state, mac, adapter_path) do
    norm = String.upcase(mac)

    Enum.find_value(managed_devices(state), fn d ->
      if d.mac == norm and String.starts_with?(d.path, adapter_path <> "/"), do: d.path
    end)
  end

  defp managed_devices(state),
    do: safe_call(fn -> state.ops.managed_devices(state.conn) end, [])

  # Logged, not silent: the injected ops module is expected to fail only
  # for "subsystem down" reasons, but a bug in it must not be invisible.
  defp safe_call(fun, default) do
    fun.()
  rescue
    e ->
      Logger.warning(
        "AudioManager ops call raised: #{Exception.format(:error, e, __STACKTRACE__)}"
      )

      default
  catch
    :exit, reason ->
      Logger.warning("AudioManager ops call exited: #{inspect(reason)}")
      default
  end

  defp headphones(state) do
    adapters = audio_adapters_info(state)
    paths = Enum.map(adapters, & &1.path)

    for %{mac: mac, path: path, props: props} = device <- managed_devices(state),
        on_audio_adapter?(path, paths),
        audio_sink?(props["UUIDs"] || []) do
      %{
        mac: mac,
        name: props["Alias"] || mac,
        connected: props["Connected"] == true,
        paired: props["Paired"] == true,
        trusted: props["Trusted"] == true,
        # Which audio radio this device is bonded to (bonds are per-adapter).
        adapter: adapter_mac_for(adapters, path),
        # Battery %, when the device reports it (org.bluez.Battery1); else nil.
        battery: Map.get(device, :battery)
      }
    end
  end

  defp adapter_mac_for(adapters, device_path) do
    case Enum.find(adapters, &String.starts_with?(device_path, &1.path <> "/")) do
      %{mac: mac} -> mac
      nil -> nil
    end
  end

  # Build "<adapter>/dev_AA_BB_..." for a MAC (BlueZ's device path convention).
  defp device_path_under(adapter_path, mac) do
    suffix = mac |> String.upcase() |> String.replace(":", "_")
    "#{adapter_path}/dev_#{suffix}"
  end

  defp adapter_path_for_device(device_path, state),
    do: Enum.find(audio_adapter_paths(state), &String.starts_with?(device_path, &1 <> "/"))

  # -- Failure mapping --

  # Normalize org.bluez error names + timeouts to a small UI vocabulary.
  defp map_failure(reason) do
    cond do
      match?({:exit, _}, reason) -> :timeout
      reason == :timeout -> :timeout
      is_binary(reason) and reason =~ "AuthenticationRejected" -> :rejected
      is_binary(reason) and reason =~ "AuthenticationCanceled" -> :rejected
      is_binary(reason) and reason =~ "ConnectionAttemptFailed" -> :out_of_range
      is_binary(reason) and reason =~ "AlreadyExists" -> :already_paired
      true -> :failed
    end
  end

  # -- Misc --

  defp do_stop_scan(%{scanning?: false} = state), do: state

  defp do_stop_scan(state) do
    if state.scan_timer, do: Process.cancel_timer(state.scan_timer)

    # Stop on the adapter the scan was started on; fall back to the first audio
    # adapter if we somehow lost it.
    case List.wrap(state.scan_path) ++ audio_adapter_paths(state) do
      [adapter | _] -> state.ops.stop_discovery(state.conn, adapter)
      [] -> :ok
    end

    Phoenix.PubSub.broadcast(state.pubsub, @scan_topic, {:bt_scan, :stopped})
    %{state | scanning?: false, scan_timer: nil, scan_path: nil}
  end

  defp schedule_reconnect(state),
    do: Process.send_after(self(), :reconnect_tick, state.reconnect_ms)

  defp expect_pairing(device_path) do
    Bluez.Agent.expect_pairing(device_path)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp pairing_done(device_path) do
    Bluez.Agent.pairing_done(device_path)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp broadcast_pairing(state, mac, step),
    do: Phoenix.PubSub.broadcast(state.pubsub, @audio_topic, {:bt_audio, :pairing, mac, step})

  defp broadcast_connection(state, mac, status),
    do:
      Phoenix.PubSub.broadcast(state.pubsub, @audio_topic, {:bt_audio, :connection, mac, status})
end
