defmodule UniversalProxy.FMA120.Server do
  @moduledoc """
  Orchestrator for FlooGoo FMA120 devices: inventory, hotplug, and worker
  lifecycle.

  ## Discovery & hotplug

  On `init`, builds the initial inventory by scanning `Hardware.list_ports/0`
  for connected ports the device table classifies as `:bt_audio` (the locked
  FMA120 VID/PID). It also subscribes to the audio subsystem's
  `"sendspin:output_added"` / `"sendspin:output_removed"` events: the FMA120's
  snd-usb-audio card hotplugs through that path, and on an `:output_added`
  matching the FMA120 VID/PID the Server correlates the `ttyACM*` control node
  at the same USB bus path (`Hardware.live_port_keys/0`) and starts a
  `FMA120.DeviceWorker`. `:output_removed` stops the matching worker.

  ## Worker lifecycle

  Workers are `:temporary` children of `FMA120.WorkerSupervisor` (a
  DynamicSupervisor), restarted manually via `Process.monitor/1`. This is safe
  because the parent `FMA120.Supervisor` is `:one_for_all`: a Server crash
  tears the whole subtree down and `init/1` rebuilds inventory from scratch —
  no orphaned PIDs to re-monitor.
  """

  use GenServer

  require Logger

  alias UniversalProxy.FMA120.DeviceWorker
  alias UniversalProxy.Hardware

  # FlooGoo FMA120 (Flairmesh / Qualcomm-CSR).
  @vendor_id 0x0A12
  @product_id 0x4007

  @pubsub UniversalProxy.PubSub
  @topic_added "sendspin:output_added"
  @topic_removed "sendspin:output_removed"

  @default_worker_supervisor UniversalProxy.FMA120.WorkerSupervisor

  defstruct inventory: [],
            worker_module: DeviceWorker,
            worker_supervisor: @default_worker_supervisor,
            hardware: Hardware

  @type entry :: %{
          key: tuple(),
          usb_port: String.t(),
          port_path: String.t(),
          worker_pid: pid() | nil,
          monitor: reference() | nil
        }

  # -- Client API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "List attached FMA120 devices (key, usb_port, port_path, worker liveness)."
  @spec list_devices(GenServer.server()) :: [map()]
  def list_devices(server \\ __MODULE__), do: GenServer.call(server, :list_devices)

  @doc "Fetch cached protocol state for a device by `{usb_port, vid, pid}` key."
  @spec get_state(GenServer.server(), tuple()) :: {:ok, map()} | {:error, :not_found}
  def get_state(server \\ __MODULE__, key), do: GenServer.call(server, {:get_state, key})

  @doc """
  Resolve the live worker pid for a device key. Callers (the `FMA120` boundary)
  invoke the worker directly so a multi-second blocking command never serializes
  the whole Server behind one device.
  """
  @spec worker_for(GenServer.server(), tuple()) :: {:ok, pid()} | {:error, :not_found}
  def worker_for(server \\ __MODULE__, key), do: GenServer.call(server, {:worker_for, key})

  # -- Server Callbacks --

  @impl true
  def init(opts) do
    state = %__MODULE__{
      worker_module: Keyword.get(opts, :worker_module, DeviceWorker),
      worker_supervisor: Keyword.get(opts, :worker_supervisor, @default_worker_supervisor),
      hardware: Keyword.get(opts, :hardware, Hardware)
    }

    if Keyword.get(opts, :subscribe, true) do
      Phoenix.PubSub.subscribe(@pubsub, @topic_added)
      Phoenix.PubSub.subscribe(@pubsub, @topic_removed)
    end

    inventory = build_initial_inventory(state)

    Logger.info(
      "FMA120 server started: #{length(inventory)} device(s), " <>
        "#{Enum.count(inventory, & &1.worker_pid)} worker(s)"
    )

    {:ok, %{state | inventory: inventory}}
  end

  @impl true
  def handle_call(:list_devices, _from, state) do
    devices =
      Enum.map(state.inventory, fn e ->
        %{key: e.key, usb_port: e.usb_port, port_path: e.port_path, connected: !!e.worker_pid}
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
      not fma120_key?(key) ->
        {:noreply, state}

      # A worker is already running for this device — nothing to do.
      live_entry?(state, key) ->
        {:noreply, state}

      # Either no entry, or a stale failed entry (`worker_pid: nil` from a
      # start failure). Drop any stale entry and (re)start, so a transient
      # boot-time failure can recover on the next output event.
      true ->
        usb_port = elem(key, 0) || Map.get(output, :usb_port)
        state = %{state | inventory: Enum.reject(state.inventory, &(&1.key == key))}
        {:noreply, add_device(state, key, usb_port)}
    end
  end

  def handle_info({:sendspin_output_removed, %{key: key}}, state) do
    if fma120_key?(key), do: {:noreply, remove_device(state, key)}, else: {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case Enum.find(state.inventory, &(&1.worker_pid == pid)) do
      nil ->
        {:noreply, state}

      entry ->
        Logger.warning("FMA120 worker for #{inspect(entry.key)} down: #{inspect(reason)}")
        {:noreply, restart_or_drop(state, entry)}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private: inventory construction --

  defp build_initial_inventory(state) do
    state.hardware.list_ports()
    |> Enum.filter(&(&1.connected and &1.kind == :bt_audio and fma120_port?(&1)))
    |> Enum.map(fn port ->
      key = {port.slot_sub, port.vendor_id, port.product_id}
      start_entry(state, key, port.slot_sub, port.tty_name)
    end)
  rescue
    e ->
      Logger.warning(
        "FMA120 inventory build failed: #{Exception.format(:error, e, __STACKTRACE__)}"
      )

      []
  end

  defp add_device(state, key, usb_port) do
    case resolve_tty(state, usb_port) do
      nil ->
        Logger.warning("FMA120 output added but no ttyACM at #{inspect(usb_port)}")
        state

      tty ->
        entry = start_entry(state, key, usb_port, tty)
        %{state | inventory: [entry | state.inventory]}
    end
  end

  defp remove_device(state, key) do
    case Enum.find(state.inventory, &(&1.key == key)) do
      nil ->
        state

      entry ->
        stop_worker(state, entry)
        %{state | inventory: Enum.reject(state.inventory, &(&1.key == key))}
    end
  end

  defp restart_or_drop(state, entry) do
    inventory = Enum.reject(state.inventory, &(&1.key == entry.key))

    case resolve_tty(state, entry.usb_port) do
      nil ->
        # Device is gone; the removal event (or next add) handles it.
        %{state | inventory: inventory}

      tty ->
        new_entry = start_entry(state, entry.key, entry.usb_port, tty)
        %{state | inventory: [new_entry | inventory]}
    end
  end

  # Build an entry and start+monitor its worker. On start failure the entry
  # is kept with `worker_pid: nil` so a later hotplug/DOWN can retry.
  defp start_entry(state, key, usb_port, tty) do
    base = %{key: key, usb_port: usb_port, port_path: tty, worker_pid: nil, monitor: nil}

    spec = %{
      id: key,
      start:
        {state.worker_module, :start_link,
         [[port_path: tty, usb_port: usb_port, key: key, server_pid: self()]]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(state.worker_supervisor, spec) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        %{base | worker_pid: pid, monitor: ref}

      {:error, reason} ->
        Logger.error("FMA120 worker start failed at #{tty}: #{inspect(reason)}")
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

  defp fma120_key?({_usb, vid, pid}), do: vid == @vendor_id and pid == @product_id
  defp fma120_key?(_), do: false

  defp fma120_port?(%{vendor_id: vid, product_id: pid}),
    do: vid == @vendor_id and pid == @product_id

  defp live_entry?(state, key),
    do: Enum.any?(state.inventory, &(&1.key == key and &1.worker_pid))

  # Find the ttyACM basename at the same USB bus path as the audio output.
  defp resolve_tty(state, usb_port) do
    state.hardware.live_port_keys()
    |> Enum.find_value(fn
      {{^usb_port, @vendor_id, @product_id}, tty} -> tty
      _ -> nil
    end)
  end
end
