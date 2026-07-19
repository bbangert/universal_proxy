defmodule UniversalProxy.BTD700.Server do
  @moduledoc """
  Orchestrator for Sennheiser BTD 700 devices: inventory, hotplug, and
  worker lifecycle. Modeled on `FMA120.Server` — see that module's
  moduledoc for the shared shape (inventory list, manual monitors, fast-
  crash backoff). Two things differ because the BTD 700 has no tty:

  ## Discovery source: Audio, not Hardware

  The FMA120 correlates its `ttyACM*` control node via
  `Hardware.list_ports/0`/`live_port_keys/0`. The BTD 700 has **no serial
  control channel at all** — its only OS-visible identity is the
  snd-usb-audio card and the hidraw node. So initial inventory and hotplug
  both come from `UniversalProxy.Audio.list_outputs/0` (injectable `audio:`
  collaborator), filtered to the locked BTD 700 VID/PID, and the control
  node is resolved separately via `BTD700.Hidraw.control_node/1`
  (injectable `hidraw:` collaborator) instead of a tty lookup.

  ## Hidraw enumeration race

  The hidraw node can enumerate a beat after the sound card does (they're
  independent kernel subsystems), so a fresh `:output_added` may find no
  control node yet. Rather than a bespoke sleep/poll, that failure is
  routed through the **same fast-crash backoff machinery** used for a
  crashing worker: the device is parked with a retry timer and
  `handle_info({:retry_worker, key}, _)` re-attempts hidraw resolution on
  each firing, growing the backoff (capped) until it succeeds or the
  device is unplugged (`:output_removed` cancels the timer and drops the
  entry either way).

  ## Worker lifecycle

  Workers are `:temporary` children of `BTD700.WorkerSupervisor` (a
  DynamicSupervisor), restarted manually via `Process.monitor/1`. This is
  safe because the parent `BTD700.Supervisor` is `:one_for_all`: a Server
  crash tears the whole subtree down and `init/1` rebuilds inventory from
  scratch — no orphaned PIDs to re-monitor.
  """

  use GenServer

  require Logger

  alias UniversalProxy.Audio
  alias UniversalProxy.BTD700.{DeviceWorker, Hidraw}

  # Sennheiser BTD 700 (BTD 600, PID 0x3000, is a different unsupported
  # device — never widen this match).
  @vendor_id 0x3542
  @product_id 0x3001

  @pubsub UniversalProxy.PubSub
  @topic_added "sendspin:output_added"
  @topic_removed "sendspin:output_removed"

  @default_worker_supervisor UniversalProxy.BTD700.WorkerSupervisor

  # A worker that dies within this window of starting is fast-crashing (or,
  # for BTD 700, its hidraw control node hasn't enumerated yet). Workers are
  # `:temporary`, so they don't count toward any supervisor's restart
  # intensity — an immediate inline respawn would be a tight crash loop
  # nothing ever escalates. Park the entry and retry with exponential
  # backoff instead; a crash after a healthy run resets the counter (a
  # flaky-but-usable device must not ratchet up permanently).
  @fast_crash_window_ms 5_000
  @retry_backoff_base_ms 1_000
  @retry_backoff_cap_ms 30_000

  defstruct inventory: [],
            worker_module: DeviceWorker,
            worker_supervisor: @default_worker_supervisor,
            audio: Audio,
            hidraw: Hidraw,
            # Both overridable via start opts (tests shorten them).
            fast_crash_window_ms: @fast_crash_window_ms,
            retry_backoff_base_ms: @retry_backoff_base_ms

  @type entry :: %{
          key: tuple(),
          usb_port: String.t(),
          device_path: String.t() | nil,
          worker_pid: pid() | nil,
          monitor: reference() | nil,
          crash_count: non_neg_integer(),
          last_start: integer() | nil,
          retry_timer: reference() | nil
        }

  # -- Client API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "List attached BTD 700 devices (key, usb_port, device_path, worker liveness)."
  @spec list_devices(GenServer.server()) :: [map()]
  def list_devices(server \\ __MODULE__), do: GenServer.call(server, :list_devices)

  @doc "Fetch cached protocol state for a device by `{usb_port, vid, pid}` key."
  @spec get_state(GenServer.server(), tuple()) :: {:ok, map()} | {:error, :not_found}
  def get_state(server \\ __MODULE__, key), do: GenServer.call(server, {:get_state, key})

  @doc """
  Resolve the live worker pid for a device key. Callers (the `BTD700`
  boundary) invoke the worker directly so a multi-second blocking command
  never serializes the whole Server behind one device.
  """
  @spec worker_for(GenServer.server(), tuple()) :: {:ok, pid()} | {:error, :not_found}
  def worker_for(server \\ __MODULE__, key), do: GenServer.call(server, {:worker_for, key})

  # -- Server Callbacks --

  @impl true
  def init(opts) do
    state = %__MODULE__{
      worker_module: Keyword.get(opts, :worker_module, DeviceWorker),
      worker_supervisor: Keyword.get(opts, :worker_supervisor, @default_worker_supervisor),
      audio: Keyword.get(opts, :audio, Audio),
      hidraw: Keyword.get(opts, :hidraw, Hidraw),
      fast_crash_window_ms: Keyword.get(opts, :fast_crash_window_ms, @fast_crash_window_ms),
      retry_backoff_base_ms: Keyword.get(opts, :retry_backoff_base_ms, @retry_backoff_base_ms)
    }

    if Keyword.get(opts, :subscribe, true) do
      Phoenix.PubSub.subscribe(@pubsub, @topic_added)
      Phoenix.PubSub.subscribe(@pubsub, @topic_removed)
    end

    inventory = build_initial_inventory(state)

    Logger.info(
      "BTD700 server started: #{length(inventory)} device(s), " <>
        "#{Enum.count(inventory, & &1.worker_pid)} worker(s)"
    )

    {:ok, %{state | inventory: inventory}}
  end

  @impl true
  def handle_call(:list_devices, _from, state) do
    devices =
      Enum.map(state.inventory, fn e ->
        %{key: e.key, usb_port: e.usb_port, device_path: e.device_path, connected: !!e.worker_pid}
      end)

    {:reply, devices, state}
  end

  def handle_call({:get_state, key}, _from, state) do
    case Enum.find(state.inventory, &(&1.key == key and &1.worker_pid)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      entry ->
        result =
          try do
            {:ok, state.worker_module.get_state(entry.worker_pid)}
          catch
            :exit, _ -> {:error, :not_found}
          end

        {:reply, result, state}
    end
  end

  def handle_call({:worker_for, key}, _from, state) do
    case Enum.find(state.inventory, &(&1.key == key and &1.worker_pid)) do
      nil -> {:reply, {:error, :not_found}, state}
      entry -> {:reply, {:ok, entry.worker_pid}, state}
    end
  end

  @impl true
  def handle_info({:sendspin_output_added, %{key: key} = output}, state) do
    cond do
      not btd700_key?(key) ->
        {:noreply, state}

      # A worker is already running for this device — nothing to do.
      live_entry?(state, key) ->
        {:noreply, state}

      # Either no entry, or a stale parked entry (`worker_pid: nil` from a
      # prior start/hidraw-resolution failure). Drop any stale entry
      # (cancelling its retry timer) and (re)start, so a transient boot-time
      # failure can recover on the next output event.
      true ->
        usb_port = elem(key, 0) || Map.get(output, :usb_port)
        state = drop_entry(state, key)
        {:noreply, add_device(state, key, usb_port)}
    end
  end

  def handle_info({:sendspin_output_removed, %{key: key}}, state) do
    if btd700_key?(key), do: {:noreply, remove_device(state, key)}, else: {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case Enum.find(state.inventory, &(&1.worker_pid == pid)) do
      nil ->
        {:noreply, state}

      entry ->
        Logger.warning("BTD700 worker for #{inspect(entry.key)} down: #{inspect(reason)}")
        {:noreply, restart_or_drop(state, entry)}
    end
  end

  # Delayed retry of a parked entry — either a fast-crashing worker or a
  # device whose hidraw control node hadn't enumerated yet. The entry may
  # have been removed (unplug) or already resolved (a later output event
  # racing this timer) since it was armed — only act on a still-parked one.
  def handle_info({:retry_worker, key}, state) do
    case Enum.find(state.inventory, &(&1.key == key and is_nil(&1.worker_pid))) do
      nil ->
        {:noreply, state}

      entry ->
        inventory = Enum.reject(state.inventory, &(&1.key == key))
        new_entry = resolve_and_start_or_park(state, key, entry.usb_port, entry.crash_count)
        {:noreply, %{state | inventory: [new_entry | inventory]}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private: inventory construction --

  defp build_initial_inventory(state) do
    state.audio.list_outputs()
    |> Enum.filter(&btd700_output?/1)
    |> Enum.map(fn %{key: key, usb_port: usb_port} ->
      resolve_and_start_or_park(state, key, usb_port, 0)
    end)
  rescue
    e ->
      Logger.warning(
        "BTD700 inventory build failed: #{Exception.format(:error, e, __STACKTRACE__)}"
      )

      []
  end

  defp add_device(state, key, usb_port) do
    entry = resolve_and_start_or_park(state, key, usb_port, 0)
    %{state | inventory: [entry | state.inventory]}
  end

  defp remove_device(state, key), do: drop_entry(state, key)

  # Cancel any pending retry timer and drop the entry (stopping its worker
  # first, if one is running). Shared by unplug and the stale-entry-replace
  # path in `handle_info({:sendspin_output_added, ...})`.
  defp drop_entry(state, key) do
    case Enum.find(state.inventory, &(&1.key == key)) do
      nil ->
        state

      entry ->
        if entry.retry_timer, do: Process.cancel_timer(entry.retry_timer)
        stop_worker(state, entry)
        %{state | inventory: Enum.reject(state.inventory, &(&1.key == key))}
    end
  end

  defp restart_or_drop(state, entry) do
    now = System.monotonic_time(:millisecond)

    fast_crash? =
      entry.last_start != nil and now - entry.last_start < state.fast_crash_window_ms

    inventory = Enum.reject(state.inventory, &(&1.key == entry.key))

    cond do
      fast_crash? ->
        crash_count = entry.crash_count + 1
        backoff = backoff_ms(state, crash_count)

        Logger.warning(
          "BTD700 worker for #{inspect(entry.key)} fast-crashed " <>
            "(##{crash_count}); retrying in #{backoff} ms"
        )

        timer = Process.send_after(self(), {:retry_worker, entry.key}, backoff)

        parked = %{
          entry
          | worker_pid: nil,
            monitor: nil,
            crash_count: crash_count,
            retry_timer: timer
        }

        %{state | inventory: [parked | inventory]}

      true ->
        # Healthy run before dying — restart inline, counter reset. If the
        # hidraw node no longer resolves the device is presumably gone; the
        # removal event (or next add) handles cleanup, same as FMA120.
        case state.hidraw.control_node(entry.usb_port) do
          {:ok, device_path} ->
            new_entry = start_entry(state, entry.key, entry.usb_port, device_path)
            %{state | inventory: [new_entry | inventory]}

          {:error, :not_found} ->
            %{state | inventory: inventory}
        end
    end
  end

  defp backoff_ms(state, crash_count) do
    min(@retry_backoff_cap_ms, state.retry_backoff_base_ms * Integer.pow(2, crash_count - 1))
  end

  # Try to resolve the hidraw control node and start a worker. On failure
  # (device not yet enumerated, or removed but not yet reaped), park a
  # parked entry with a retry timer through the fast-crash backoff — this is
  # the mechanism that structurally replaces a bespoke sleep/poll for the
  # hidraw-enumeration race (see moduledoc).
  defp resolve_and_start_or_park(state, key, usb_port, crash_count) do
    case state.hidraw.control_node(usb_port) do
      {:ok, device_path} ->
        start_entry(state, key, usb_port, device_path, crash_count)

      {:error, :not_found} ->
        new_crash_count = crash_count + 1
        backoff = backoff_ms(state, new_crash_count)

        Logger.warning(
          "BTD700 hidraw control node not found at #{inspect(usb_port)} " <>
            "(attempt ##{new_crash_count}); retrying in #{backoff} ms"
        )

        timer = Process.send_after(self(), {:retry_worker, key}, backoff)

        %{
          key: key,
          usb_port: usb_port,
          device_path: nil,
          worker_pid: nil,
          monitor: nil,
          crash_count: new_crash_count,
          last_start: System.monotonic_time(:millisecond),
          retry_timer: timer
        }
    end
  end

  # Build an entry and start+monitor its worker. On start failure the entry
  # is kept with `worker_pid: nil` so a later hotplug/DOWN can retry.
  # `crash_count` carries the fast-crash tally across a delayed retry so
  # the backoff keeps growing until a healthy run resets it.
  defp start_entry(state, key, usb_port, device_path, crash_count \\ 0) do
    base = %{
      key: key,
      usb_port: usb_port,
      device_path: device_path,
      worker_pid: nil,
      monitor: nil,
      crash_count: crash_count,
      last_start: System.monotonic_time(:millisecond),
      retry_timer: nil
    }

    spec = %{
      id: key,
      start:
        {state.worker_module, :start_link,
         [[device_path: device_path, usb_port: usb_port, key: key, server_pid: self()]]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(state.worker_supervisor, spec) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        %{base | worker_pid: pid, monitor: ref}

      {:error, reason} ->
        Logger.error("BTD700 worker start failed at #{device_path}: #{inspect(reason)}")
        base
    end
  end

  defp stop_worker(_state, %{worker_pid: nil}), do: :ok

  defp stop_worker(state, %{worker_pid: pid, monitor: ref}) do
    if ref, do: Process.demonitor(ref, [:flush])

    try do
      DynamicSupervisor.terminate_child(state.worker_supervisor, pid)
    catch
      :exit, _ -> :ok
    end
  end

  # -- Private: helpers --

  defp btd700_key?({_usb, vid, pid}), do: vid == @vendor_id and pid == @product_id
  defp btd700_key?(_), do: false

  defp btd700_output?(%{key: key, usb_port: usb_port}),
    do: btd700_key?(key) and is_binary(usb_port)

  defp btd700_output?(_), do: false

  defp live_entry?(state, key),
    do: Enum.any?(state.inventory, &(&1.key == key and &1.worker_pid))
end
