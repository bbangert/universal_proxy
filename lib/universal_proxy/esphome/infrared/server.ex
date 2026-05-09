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
  alias UniversalProxy.UART.Enumerate, as: UARTEnumerate
  alias UniversalProxy.UART.Store, as: UARTStore

  @product_modules [Irdroid.Device]

  @worker_supervisor UniversalProxy.ESPHome.Infrared.WorkerSupervisor

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
        case start_worker(entry) do
          {:ok, new_pid} ->
            Logger.info("Infrared worker for key #{key} restarted")

            inventory =
              Enum.map(state.inventory, fn
                %{entity: %{key: ^key}} = e -> %{e | worker_pid: new_pid}
                e -> e
              end)

            %{state | inventory: inventory}

          {:error, reason} ->
            Logger.error("Failed to restart infrared worker for key #{key}: #{inspect(reason)}")

            inventory =
              Enum.map(state.inventory, fn
                %{entity: %{key: ^key}} = e -> %{e | worker_pid: nil}
                e -> e
              end)

            %{state | inventory: inventory}
        end
    end
  end

  defp remove_subscriber(state, pid) do
    {ref, monitors} = Map.pop(state.monitors, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    %{state | subscribers: MapSet.delete(state.subscribers, pid), monitors: monitors}
  end

  defp build_inventory do
    serial_to_entry =
      for {path, info} <- UARTEnumerate.safe(),
          UARTEnumerate.present?(info[:serial_number]),
          into: %{},
          do: {info[:serial_number], {path, info}}

    UARTStore.all_configs()
    |> Enum.filter(fn config ->
      config[:port_type] == :infrared and
        Map.has_key?(serial_to_entry, config[:serial_number])
    end)
    |> Enum.flat_map(&start_entry(&1, serial_to_entry))
  rescue
    e ->
      Logger.warning(
        "Infrared inventory build failed: #{Exception.format(:error, e, __STACKTRACE__)}"
      )

      []
  end

  defp start_entry(config, serial_to_entry) do
    serial = config[:serial_number]
    {path, info} = Map.fetch!(serial_to_entry, serial)

    case find_product_module(info) do
      {:ok, mod} ->
        entity = mod.build_entity(config, path, info)

        entry = %{
          entity: entity,
          device_module: mod,
          serial_number: serial,
          port_path: path,
          worker_pid: nil
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
