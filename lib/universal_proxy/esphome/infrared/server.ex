defmodule UniversalProxy.ESPHome.Infrared.Server do
  @moduledoc """
  `Espex.InfraredProxy` adapter — coordinates infrared device inventory,
  workers, and ESPHome connection subscriptions.

  Product-agnostic: delegates to product-specific modules (currently only
  `Irdroid.Device`) for device matching and entity building.

  ## Lifecycle

  On init, builds the infrared inventory by joining UART Store configs
  (where `port_type == :infrared`) with `Circuits.UART.enumerate()`.
  For each device, consults the registered product modules to identify it,
  then starts the appropriate worker under the DynamicSupervisor.

  Receive events from workers are forwarded to all subscribed connection pids
  as `{:espex_ir_receive, key, timings}`.

  Workers run as `:temporary` children with manual restart driven by
  `Process.monitor/1`. This is safe because the parent
  `Infrared.Supervisor` uses `:one_for_all`: if this Server crashes, the
  WorkerSupervisor restarts too and `init/1` rebuilds the inventory from
  scratch — no orphaned PIDs to re-monitor.
  """

  use GenServer

  @behaviour Espex.InfraredProxy

  require Logger

  alias Espex.InfraredProxy.Entity
  alias UniversalProxy.ESPHome.Infrared.Irdroid
  alias UniversalProxy.Hardware
  alias UniversalProxy.UART.Enumerate, as: UARTEnumerate
  alias UniversalProxy.UART.Store, as: UARTStore

  @product_modules [Irdroid.Device]

  @worker_supervisor UniversalProxy.ESPHome.Infrared.WorkerSupervisor

  # A worker that dies within this window of starting is fast-crashing.
  # Workers are `:temporary`, so they don't count toward any supervisor's
  # restart intensity — an immediate inline respawn would be a tight
  # crash loop nothing ever escalates. Park the entry and retry with
  # exponential backoff instead; a crash after a healthy run resets the
  # counter. Same constants as `UniversalProxy.FMA120.Server`.
  @fast_crash_window_ms 5_000
  @retry_backoff_base_ms 1_000
  @retry_backoff_cap_ms 30_000

  defstruct inventory: [],
            subscribers: MapSet.new(),
            monitors: %{}

  # -- Client API / behaviour callbacks --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Espex.InfraredProxy
  def list_entities do
    GenServer.call(__MODULE__, :list_entities)
  end

  @impl Espex.InfraredProxy
  def transmit_raw(key, timings, opts) do
    GenServer.call(__MODULE__, {:transmit_raw, key, timings, opts}, 15_000)
  end

  @impl Espex.InfraredProxy
  def subscribe(pid) when is_pid(pid) do
    GenServer.call(__MODULE__, {:subscribe, pid})
  end

  @impl Espex.InfraredProxy
  def unsubscribe(pid) when is_pid(pid) do
    GenServer.call(__MODULE__, {:unsubscribe, pid})
  end

  # -- Server Callbacks --

  @impl GenServer
  def init(_opts) do
    inventory = build_inventory()

    Logger.info(
      "Infrared proxy started: #{length(inventory)} device(s), #{Enum.count(inventory, & &1.worker_pid)} worker(s)"
    )

    {:ok, %__MODULE__{inventory: inventory}}
  end

  @impl GenServer
  def handle_call(:list_entities, _from, state) do
    {:reply, Enum.map(state.inventory, & &1.entity), state}
  end

  def handle_call({:transmit_raw, key, timings, opts}, _from, state) do
    case Enum.find(state.inventory, &(&1.entity.key == key)) do
      nil ->
        {:reply, {:error, :unknown_device}, state}

      %{worker_pid: nil} ->
        {:reply, {:error, :worker_unavailable}, state}

      %{device_module: mod, worker_pid: pid} ->
        result =
          try do
            mod.transmit(pid, timings, opts)
          catch
            :exit, _reason -> {:error, :worker_unavailable}
          end

        {:reply, result, state}
    end
  end

  def handle_call({:subscribe, pid}, _from, state) do
    if MapSet.member?(state.subscribers, pid) do
      {:reply, :ok, state}
    else
      ref = Process.monitor(pid)

      state = %{
        state
        | subscribers: MapSet.put(state.subscribers, pid),
          monitors: Map.put(state.monitors, pid, ref)
      }

      Logger.debug("Infrared subscriber added: #{inspect(pid)}")
      {:reply, :ok, state}
    end
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {:reply, :ok, remove_subscriber(state, pid)}
  end

  @impl GenServer
  def handle_info({:infrared_receive, key, timings}, state) do
    Enum.each(state.subscribers, fn pid ->
      send(pid, {:espex_ir_receive, key, timings})
    end)

    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    if MapSet.member?(state.subscribers, pid) do
      Logger.debug("Infrared subscriber #{inspect(pid)} down, auto-unsubscribing")
      {:noreply, remove_subscriber(state, pid)}
    else
      case find_entry_by_worker(state.inventory, pid) do
        nil -> {:noreply, state}
        %{entity: %{key: key}} -> {:noreply, restart_worker(state, key)}
      end
    end
  end

  # Delayed respawn of a fast-crashing worker. The entry may have been
  # rebuilt or already restarted since the timer was armed — only act on
  # a parked entry.
  def handle_info({:retry_worker, key}, state) do
    case Enum.find(state.inventory, &(&1.entity.key == key and is_nil(&1.worker_pid))) do
      nil -> {:noreply, state}
      entry -> {:noreply, update_entry(state, key, start_worker_for(entry))}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # -- Private --

  defp find_entry_by_worker(inventory, pid) do
    Enum.find(inventory, &(&1.worker_pid == pid))
  end

  defp restart_worker(state, key) do
    case Enum.find(state.inventory, &(&1.entity.key == key)) do
      nil ->
        state

      entry ->
        now = System.monotonic_time(:millisecond)

        if entry.last_start != nil and now - entry.last_start < @fast_crash_window_ms do
          crash_count = entry.crash_count + 1
          backoff = backoff_ms(crash_count)

          Logger.warning(
            "Infrared worker for key #{key} fast-crashed (##{crash_count}); " <>
              "retrying in #{backoff} ms"
          )

          timer = Process.send_after(self(), {:retry_worker, key}, backoff)

          update_entry(state, key, %{
            entry
            | worker_pid: nil,
              crash_count: crash_count,
              retry_timer: timer
          })
        else
          # Healthy run before dying — restart inline, counter reset.
          update_entry(state, key, start_worker_for(%{entry | crash_count: 0}))
        end
    end
  end

  # Start (or restart) the worker for an entry, stamping `last_start` and
  # preserving `crash_count` so a delayed retry keeps growing its backoff
  # until a healthy run resets it.
  defp start_worker_for(entry) do
    entry = %{entry | last_start: System.monotonic_time(:millisecond), retry_timer: nil}

    case start_worker(entry) do
      {:ok, pid} ->
        Logger.info("Infrared worker for key #{entry.entity.key} restarted")
        %{entry | worker_pid: pid}

      {:error, reason} ->
        Logger.error(
          "Failed to restart infrared worker for key #{entry.entity.key}: #{inspect(reason)}"
        )

        %{entry | worker_pid: nil}
    end
  end

  defp update_entry(state, key, new_entry) do
    inventory =
      Enum.map(state.inventory, fn
        %{entity: %{key: ^key}} -> new_entry
        e -> e
      end)

    %{state | inventory: inventory}
  end

  defp backoff_ms(crash_count) do
    min(@retry_backoff_cap_ms, @retry_backoff_base_ms * Integer.pow(2, crash_count - 1))
  end

  defp remove_subscriber(state, pid) do
    {ref, monitors} = Map.pop(state.monitors, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    %{state | subscribers: MapSet.delete(state.subscribers, pid), monitors: monitors}
  end

  defp build_inventory do
    enumerated = UARTEnumerate.safe()
    key_to_tty = Hardware.live_port_keys(enumerated: enumerated)

    # Auto-detected IR adapters from Hardware.list_ports/0 — these
    # don't need a saved config (they're branded products that the
    # device-table classifies as :ir on sight).
    auto =
      Hardware.list_ports()
      |> Enum.filter(&(&1.connected and &1.kind == :ir))
      |> Enum.flat_map(fn port ->
        info = Map.get(enumerated, port.tty_name, %{})

        # Pretend a synthetic config so start_entry/2 can render an
        # entity for these unsaved-but-classified ports.
        synthesized = %{
          port_type: :infrared,
          serial_number: port.serial,
          friendly_name: port.name,
          slot_sub: port.slot_sub,
          vendor_id: port.vendor_id,
          product_id: port.product_id
        }

        start_entry(synthesized, port.tty_name, info)
      end)

    # User-saved IR overrides on otherwise-unclassified hardware.
    saved =
      UARTStore.all_configs()
      |> Enum.flat_map(fn config ->
        key = {config[:slot_sub], config[:vendor_id], config[:product_id]}

        with true <- config[:port_type] == :infrared,
             tty when is_binary(tty) <- Map.get(key_to_tty, key) do
          info = Map.get(enumerated, tty, %{})
          start_entry(config, tty, info)
        else
          _ -> []
        end
      end)

    auto ++ saved
  rescue
    e ->
      Logger.warning(
        "Infrared inventory build failed: #{Exception.format(:error, e, __STACKTRACE__)}"
      )

      []
  end

  defp start_entry(config, tty_name, info) do
    serial = config[:serial_number]
    # Match what `Circuits.UART.enumerate/0` returned originally: just
    # the basename (e.g. "ttyUSB0"), not "/dev/ttyUSB0".
    path = tty_name

    case find_product_module(info) do
      {:ok, mod} ->
        entity = mod.build_entity(config, path, info)

        entry = %{
          entity: entity,
          device_module: mod,
          serial_number: serial,
          port_path: path,
          worker_pid: nil,
          crash_count: 0,
          last_start: System.monotonic_time(:millisecond),
          retry_timer: nil
        }

        case start_worker(entry) do
          {:ok, pid} ->
            [%{entry | worker_pid: pid}]

          {:error, reason} ->
            Logger.warning("Failed to start infrared worker at #{path}: #{inspect(reason)}")
            [entry]
        end

      :error ->
        Logger.debug("No product module matched infrared device at #{path}")
        []
    end
  end

  defp find_product_module(info) do
    case Enum.find(@product_modules, fn mod -> mod.match?(info) end) do
      nil -> :error
      mod -> {:ok, mod}
    end
  end

  defp start_worker(entry) do
    spec = entry.device_module.child_spec(entry, self())

    with {:ok, pid} <- DynamicSupervisor.start_child(@worker_supervisor, spec) do
      Process.monitor(pid)
      {:ok, pid}
    end
  end

  # -- Helpers exposed to product modules --

  @doc """
  Build an `Espex.InfraredProxy.Entity` with our deterministic key/object_id
  conventions. Helper for product `Device` modules.
  """
  @spec build_entity(keyword()) :: Entity.t()
  def build_entity(attrs) do
    serial = Keyword.fetch!(attrs, :serial_number)

    Entity.new(
      key: :erlang.phash2({serial, "infrared"}, 0xFFFFFFFF),
      object_id: "infrared_#{serial}",
      name: Keyword.get(attrs, :name, "Infrared"),
      capabilities: Keyword.fetch!(attrs, :capabilities)
    )
  end
end
