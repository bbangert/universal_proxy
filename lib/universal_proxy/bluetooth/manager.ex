defmodule UniversalProxy.Bluetooth.Manager do
  @moduledoc """
  Runtime lifecycle owner for the BlueZ stack.

  The BlueZ subtree runs **whenever the hardware supports it** — the
  `enabled` setting does NOT stop it. All radios stay powered and the
  scanner keeps running on the selected one; what `enabled` (and
  `active_connections`) gate is the *espex wiring*
  (`UniversalProxy.ESPHome.Supervisor.bluetooth_opts/2`): with Bluetooth
  disabled, espex advertises no BT feature flags and nothing subscribes,
  so scan data is simply ignored at the Elixir layer. That keeps toggles
  instant (no daemon churn) and keeps the radio list (whose MACs only
  exist via the daemon) fully populated while disabled.

  What this Manager owns is subtree *liveness* (start at boot, retry
  failed starts, re-bind after crashes) and **radio switching**: a
  `reconcile(restart: true)` stop/start cycle re-points the stack at a
  newly selected adapter.

  ## Adapter-selection ordering invariant

  Before every (re)start of the Bluez subtree the Manager publishes the
  persisted radio MAC (or `nil` = auto) as `:persistent_term`
  (`UniversalProxy.Bluez.DevicePath.desired_adapter_key/0`). The kernel
  exposes no BT MAC in sysfs, so the MAC → hciX resolution happens
  inside the subtree: `UniversalProxy.Bluez.Client` matches the desired
  MAC against bluetoothd's `Adapter1` objects during setup and writes
  the resolved adapter path (`adapter_path_key/0`) itself, falling back
  to the lowest-index adapter when the MAC is absent. A crash-restart
  re-resolves against the same desired MAC — consistent by construction.

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

  # Delay before re-binding the monitor after the subtree dies — the
  # DynamicSupervisor restarts a :permanent child immediately, so one tick
  # is normally enough; the rebind loops while enabled in case it isn't.
  @rebind_ms 1_000

  # Retry delay after DynamicSupervisor.start_child returns an error. A
  # failed START isn't a crash — nothing restarts it for us (unlike a
  # started-then-crashed :permanent child), so the Manager owns this loop.
  # Hardware-found: the first start after a runtime stop can lose a race
  # with the old subtree's teardown remnants.
  @start_retry_ms 2_000

  # Settle time between stop and start on a restart (radio switch).
  # Hardware-found: the old bluetoothd releases its L2CAP listening
  # sockets a beat after its process is told to exit; a new bluetoothd
  # started immediately fails adapter registration ("l2cap_bind: Address
  # already in use") and sits adapterless until the Client's :no_adapter
  # loop bounces the subtree (~10 s). This pause makes switches clean.
  @restart_settle_ms 1_500

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
  Re-read settings and converge: the subtree is (re)started if it isn't
  running — the `enabled` setting doesn't stop it, it only changes the
  broadcast status. `restart: true` forces a stop/start cycle even when
  already running — used by radio selection, which must re-resolve the
  desired adapter.

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
      start_retry_ms: Keyword.get(opts, :start_retry_ms, @start_retry_ms),
      restart_settle_ms: Keyword.get(opts, :restart_settle_ms, @restart_settle_ms),
      bluez_pid: nil,
      monitor: nil
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
        # Not back yet (restart backoff / escalation in progress). The
        # subtree is always supposed to be up — keep looking.
        Process.send_after(self(), :rebind, @rebind_ms)
        {:noreply, state}
    end
  end

  def handle_info(:rebind, state), do: {:noreply, state}

  # A start_child failure scheduled this.
  def handle_info(:retry_start, %{bluez_pid: nil} = state) do
    state = do_reconcile(state, [])
    broadcast(state)
    {:noreply, state}
  end

  def handle_info(:retry_start, state), do: {:noreply, state}

  def handle_info(_other, state), do: {:noreply, state}

  # ── reconcile ────────────────────────────────────────────────────────────

  defp do_reconcile(state, opts) do
    config = settings(state)
    restart? = Keyword.get(opts, :restart, false)
    running? = running?(state)

    cond do
      not running? ->
        start_bluez(state, config)

      restart? ->
        state = stop_bluez(state)
        # Blocking the Manager here is fine: radio switches are rare,
        # explicit user actions, and the caller waits anyway.
        Process.sleep(state.restart_settle_ms)
        start_bluez(state, config)

      true ->
        state
    end
  end

  defp start_bluez(state, config) do
    # MUST land before the subtree boots: Bluez.Client resolves this MAC
    # against bluetoothd's adapters during setup (a crash-restart
    # re-resolves the same term).
    :persistent_term.put(DevicePath.desired_adapter_key(), config.adapter)

    case DynamicSupervisor.start_child(state.dynsup, state.bluez_child) do
      {:ok, pid} ->
        Logger.info(
          "Bluetooth.Manager: Bluez subtree started (radio: #{config.adapter || "auto"})"
        )

        %{state | bluez_pid: pid, monitor: Process.monitor(pid)}

      {:error, {:already_started, pid}} ->
        # A replacement child we hadn't re-bound to yet (crash-restart racing
        # a reconcile). Drop any stale monitor before taking the new one, or
        # its late :DOWN would clear bluez_pid on a live subtree.
        if state.monitor, do: Process.demonitor(state.monitor, [:flush])
        %{state | bluez_pid: pid, monitor: Process.monitor(pid)}

      {:error, reason} ->
        Logger.error(
          "Bluetooth.Manager: Bluez subtree failed to start " <>
            "(retrying in #{state.start_retry_ms} ms): #{inspect(reason)}"
        )

        Process.send_after(self(), :retry_start, state.start_retry_ms)
        %{state | bluez_pid: nil, monitor: nil}
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

  # ── status ───────────────────────────────────────────────────────────────

  defp build_status(state) do
    config = settings(state)
    running? = running?(state)
    {used, limit} = connection_usage()

    %{
      enabled: config.enabled,
      # The stack itself is always on — "proxying" means HA-facing: data
      # only reaches espex (and the flags are only advertised) when the
      # user has Bluetooth enabled.
      proxying?: config.enabled and running?,
      adapter: adapter_status(state, running?),
      active_connections: %{allowed?: config.active_connections, used: used, limit: limit}
    }
  end

  # While running: identify the claimed adapter (path published by
  # Bluez.Client) with its live Adapter1 identity. The kernel exposes no
  # BT MAC in sysfs, so while the subtree is DOWN all we can show is the
  # first controller's hci name — address/name appear once the daemon is
  # up (adapters_info_fun is exit-safe and returns [] until then).
  defp adapter_status(state, running?) do
    if running? do
      path = DevicePath.adapter_path()
      hci = Path.basename(path)

      case Enum.find(state.adapters_info_fun.(), &(&1.path == path)) do
        %{address: address, name: name} -> %{hci: hci, address: address, name: name}
        nil -> %{hci: hci, address: nil, name: nil}
      end
    else
      case Radios.sysfs_adapters(state.sysfs_root) do
        [%{hci: hci} | _] -> %{hci: hci, address: nil, name: nil}
        [] -> nil
      end
    end
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
