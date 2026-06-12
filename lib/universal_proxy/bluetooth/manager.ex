defmodule UniversalProxy.Bluetooth.Manager do
  @moduledoc """
  Runtime lifecycle owner for the BlueZ stack.

  The compile-time gate (`UniversalProxy.Bluetooth.supported?/0`) decides
  whether this subsystem exists at all; this Manager adds the *runtime*
  gate: it starts and stops the `UniversalProxy.Bluez` subtree under the
  sibling `DynamicSupervisor` according to the persisted
  `UniversalProxy.Bluetooth.Settings`.

  ## Adapter-path ordering invariant

  Before every (re)start of the Bluez subtree the Manager resolves the
  persisted radio MAC to an adapter object path (via sysfs — works while
  `bluetoothd` is down) and publishes it as
  `:persistent_term` `{UniversalProxy.Bluez, :adapter_path}`. Everything
  inside the subtree reads the path through
  `UniversalProxy.Bluez.DevicePath.adapter_path/0`, so a crash-restart of
  the subtree re-reads the same term — consistent by construction. The
  default (term never written) is `/org/bluez/hci0`.

  Resolution falls back to the first (lowest-index) controller when the
  persisted MAC isn't present (dongle unplugged), and to `hci0` when sysfs
  shows no controller at all — the subtree's benign ~10 s retry loop
  handles actual absence.

  ## Broadcasts

  The full status map (`status/0` shape) is published on
  `UniversalProxy.Bluetooth.state_topic()` as `{:bluetooth_state, status}`
  after every reconcile and when the subtree goes down or comes back
  (crash-restarts are performed by the DynamicSupervisor; this Manager
  only re-binds its monitor and tells subscribers).

  ## Options (host-testability)

  `start_link/1` accepts `:name`, `:settings` (Settings server ref),
  `:dynamic_supervisor`, `:bluez_child` (child spec started under it),
  `:sysfs_root`, and `:pubsub` — production defaults wire the real
  modules; tests substitute fixtures and stubs.
  """

  use GenServer
  require Logger

  alias UniversalProxy.Bluetooth.{Radios, Settings}
  alias UniversalProxy.Bluez.DevicePath

  @default_adapter_path "/org/bluez/hci0"

  # Delay before re-binding the monitor after the subtree dies — the
  # DynamicSupervisor restarts a :permanent child immediately, so one tick
  # is normally enough; the rebind loops while enabled in case it isn't.
  @rebind_ms 1_000

  def start_link(opts \\ []) do
    gen_opts =
      case Keyword.get(opts, :name, __MODULE__) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  The status map the Bluetooth tab renders (see
  `UniversalProxy.Bluetooth.status/0` for the defensive public wrapper).
  """
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  @doc """
  Re-read settings and converge the Bluez subtree on them: start it when
  enabled and down, stop it when disabled and up. `restart: true` forces a
  stop/start cycle even when already running — used by radio selection,
  which must re-resolve the adapter path.

  Broadcasts the resulting status either way.
  """
  @spec reconcile(GenServer.server(), keyword()) :: :ok
  def reconcile(server \\ __MODULE__, opts \\ [])

  # `reconcile(restart: true)` — a lone keyword list is the opts, not the
  # server (default-arg filling would otherwise bind it to `server`).
  def reconcile(opts, []) when is_list(opts), do: GenServer.call(__MODULE__, {:reconcile, opts})
  def reconcile(server, opts), do: GenServer.call(server, {:reconcile, opts})

  @impl GenServer
  def init(opts) do
    state = %{
      settings: Keyword.get(opts, :settings, Settings),
      dynsup: Keyword.get(opts, :dynamic_supervisor, UniversalProxy.Bluetooth.DynamicSupervisor),
      bluez_child: Keyword.get(opts, :bluez_child, UniversalProxy.Bluez),
      sysfs_root: Keyword.get(opts, :sysfs_root, "/sys/class/bluetooth"),
      pubsub: Keyword.get(opts, :pubsub, UniversalProxy.PubSub),
      adapters_info_fun:
        Keyword.get(opts, :adapters_info_fun, &UniversalProxy.Bluez.Client.adapters_info/0),
      bluez_pid: nil,
      monitor: nil,
      # The sysfs adapter the path was resolved to at the last subtree
      # start (%{hci:, address:} | nil) — what status reports while running.
      adapter: nil
    }

    {:ok, state, {:continue, :reconcile}}
  end

  @impl GenServer
  def handle_continue(:reconcile, state) do
    state = do_reconcile(state, [])
    broadcast(state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    {:reply, build_status(state), state}
  end

  def handle_call({:reconcile, opts}, _from, state) do
    state = do_reconcile(state, opts)
    broadcast(state)
    {:reply, :ok, state}
  end

  @impl GenServer
  # The Bluez subtree died. The DynamicSupervisor owns the restart
  # (:permanent child); we just tell subscribers and re-bind the monitor to
  # the replacement once it's up.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{monitor: ref} = state) do
    Logger.warning("Bluetooth.Manager: Bluez subtree down: #{inspect(reason)}")
    state = %{state | bluez_pid: nil, monitor: nil}
    broadcast(state)
    Process.send_after(self(), :rebind, @rebind_ms)
    {:noreply, state}
  end

  def handle_info(:rebind, %{bluez_pid: nil} = state) do
    case running_child(state.dynsup) do
      pid when is_pid(pid) ->
        state = %{state | bluez_pid: pid, monitor: Process.monitor(pid)}
        broadcast(state)
        {:noreply, state}

      nil ->
        # Not back yet (restart backoff / escalation in progress). Keep
        # looking while the subtree is supposed to be up.
        if settings(state).enabled, do: Process.send_after(self(), :rebind, @rebind_ms)
        {:noreply, state}
    end
  end

  def handle_info(:rebind, state), do: {:noreply, state}

  def handle_info(_other, state), do: {:noreply, state}

  # ── reconcile ────────────────────────────────────────────────────────────

  defp do_reconcile(state, opts) do
    config = settings(state)
    restart? = Keyword.get(opts, :restart, false)
    running? = running?(state)

    cond do
      config.enabled and not running? -> start_bluez(state, config)
      config.enabled and restart? -> state |> stop_bluez() |> start_bluez(config)
      not config.enabled and running? -> stop_bluez(state)
      true -> state
    end
  end

  defp start_bluez(state, config) do
    {path, adapter} = resolve_adapter(config, state.sysfs_root)
    # MUST land before the subtree boots: everything under Bluez reads the
    # adapter path from this term (a crash-restart re-reads it unchanged).
    :persistent_term.put(DevicePath.adapter_path_key(), path)

    case DynamicSupervisor.start_child(state.dynsup, state.bluez_child) do
      {:ok, pid} ->
        Logger.info("Bluetooth.Manager: Bluez subtree started on #{path}")
        %{state | bluez_pid: pid, monitor: Process.monitor(pid), adapter: adapter}

      {:error, {:already_started, pid}} ->
        %{state | bluez_pid: pid, monitor: Process.monitor(pid), adapter: adapter}

      {:error, reason} ->
        Logger.error("Bluetooth.Manager: Bluez subtree failed to start: #{inspect(reason)}")
        %{state | bluez_pid: nil, monitor: nil, adapter: adapter}
    end
  end

  # Sweep ALL children rather than just the tracked pid: after a crash the
  # DynamicSupervisor restarts the subtree under a pid we may not have
  # re-bound yet, and a stale-pid terminate_child would silently leave the
  # replacement running.
  defp stop_bluez(state) do
    if state.monitor, do: Process.demonitor(state.monitor, [:flush])

    for {_id, pid, _type, _mods} <- DynamicSupervisor.which_children(state.dynsup),
        is_pid(pid) do
      DynamicSupervisor.terminate_child(state.dynsup, pid)
    end

    Logger.info("Bluetooth.Manager: Bluez subtree stopped")
    %{state | bluez_pid: nil, monitor: nil}
  end

  # ── adapter resolution ───────────────────────────────────────────────────

  # MAC → "/org/bluez/hciX" via sysfs. Falls back to the first controller
  # when the persisted MAC isn't present, and to hci0 when there are no
  # controllers at all.
  defp resolve_adapter(config, sysfs_root) do
    adapters = Radios.sysfs_adapters(sysfs_root)

    chosen =
      case config.adapter do
        nil ->
          List.first(adapters)

        mac ->
          case Enum.find(adapters, &(&1.address == mac)) do
            nil ->
              Logger.warning(
                "Bluetooth.Manager: selected radio #{mac} not present, " <>
                  "falling back to #{inspect(List.first(adapters) || "hci0")}"
              )

              List.first(adapters)

            found ->
              found
          end
      end

    case chosen do
      nil -> {@default_adapter_path, nil}
      %{hci: hci} = adapter -> {"/org/bluez/#{hci}", adapter}
    end
  end

  # ── status ───────────────────────────────────────────────────────────────

  defp build_status(state) do
    config = settings(state)
    running? = running?(state)

    adapter =
      if running? do
        state.adapter
      else
        {_path, adapter} = resolve_adapter(config, state.sysfs_root)
        adapter
      end

    {used, limit} = connection_usage()

    %{
      enabled: config.enabled,
      proxying?: running?,
      adapter:
        adapter &&
          %{hci: adapter.hci, address: adapter.address, name: adapter_name(state, adapter.hci)},
      active_connections: %{allowed?: config.active_connections, used: used, limit: limit}
    }
  end

  # Live Adapter1.Name from the daemon, when it's up (nil otherwise —
  # adapters_info/0 is exit-safe and returns [] with the subtree down).
  defp adapter_name(state, hci) do
    state.adapters_info_fun.()
    |> Enum.find_value(fn %{path: path, name: name} ->
      if Path.basename(path) == hci, do: name
    end)
  end

  defp connection_usage do
    {free, total} = UniversalProxy.Bluez.Gatt.connections_free()
    {total - free, total}
  catch
    # Gatt not running (subtree down, host) — nothing in use.
    :exit, _ -> {0, UniversalProxy.Bluez.Gatt.max_connections()}
  end

  defp running?(state), do: state.bluez_pid != nil and Process.alive?(state.bluez_pid)

  defp running_child(dynsup) do
    Enum.find_value(DynamicSupervisor.which_children(dynsup), fn
      {_id, pid, _type, _mods} when is_pid(pid) -> pid
      _ -> nil
    end)
  end

  defp settings(state), do: Settings.get(state.settings)

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(
      state.pubsub,
      UniversalProxy.Bluetooth.state_topic(),
      {:bluetooth_state, build_status(state)}
    )
  end
end
