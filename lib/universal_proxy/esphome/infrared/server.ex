defmodule UniversalProxy.ESPHome.Infrared.Server do
  @moduledoc """
  GenServer coordinating infrared device inventory, workers, and ESPHome
  connection subscriptions.

  Product-agnostic: delegates to product-specific modules (currently only
  `Irdroid.Device`) for device matching and entity building.

  ## Lifecycle

  On init, builds the infrared inventory by joining UART Store configs
  (where `port_type == :infrared`) with `Circuits.UART.enumerate()`.
  For each device, consults the registered product modules to identify it,
  then starts the appropriate worker under the DynamicSupervisor.

  Receive events from workers are forwarded to all subscribed connection pids.
  """

  use GenServer

  require Logger

  alias UniversalProxy.ESPHome.Infrared.Entity
  alias UniversalProxy.ESPHome.Infrared.Irdroid

  @product_modules [Irdroid.Device]

  @worker_supervisor UniversalProxy.ESPHome.Infrared.WorkerSupervisor

  defstruct entities: [],
            workers: %{},
            subscribers: MapSet.new(),
            monitors: %{}

  # -- Client API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the list of infrared entities for ListEntitiesRequest."
  @spec list_entities() :: [Entity.t()]
  def list_entities do
    GenServer.call(__MODULE__, :list_entities)
  end

  @doc "Transmit raw IR timings through the device identified by key."
  @spec transmit_raw(non_neg_integer(), [integer()], keyword()) :: :ok | {:error, term()}
  def transmit_raw(key, timings, opts \\ []) do
    GenServer.call(__MODULE__, {:transmit_raw, key, timings, opts}, 15_000)
  end

  @doc "Subscribe a connection pid to receive infrared events."
  @spec subscribe(pid()) :: :ok
  def subscribe(pid) when is_pid(pid) do
    GenServer.call(__MODULE__, {:subscribe, pid})
  end

  @doc "Unsubscribe a connection pid."
  @spec unsubscribe(pid()) :: :ok
  def unsubscribe(pid) when is_pid(pid) do
    GenServer.call(__MODULE__, {:unsubscribe, pid})
  end

  # -- Server Callbacks --

  @impl true
  def init(_opts) do
    {entities, workers} = build_inventory()

    Logger.info(
      "Infrared proxy started: #{length(entities)} device(s), #{map_size(workers)} worker(s)"
    )

    {:ok, %__MODULE__{entities: entities, workers: workers}}
  end

  @impl true
  def handle_call(:list_entities, _from, state) do
    {:reply, state.entities, state}
  end

  def handle_call({:transmit_raw, key, timings, opts}, _from, state) do
    case Map.fetch(state.workers, key) do
      {:ok, {device_module, worker_pid}} ->
        result =
          try do
            device_module.transmit(worker_pid, timings, opts)
          catch
            :exit, reason -> {:error, {:worker_exit, reason}}
          end

        {:reply, result, state}

      :error ->
        {:reply, {:error, :unknown_device}, state}
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
    state = remove_subscriber(state, pid)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:infrared_receive, key, timings}, state) do
    Enum.each(state.subscribers, fn pid ->
      send(pid, {:infrared_receive, key, timings})
    end)

    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    cond do
      MapSet.member?(state.subscribers, pid) ->
        Logger.debug("Infrared subscriber #{inspect(pid)} down, auto-unsubscribing")
        {:noreply, remove_subscriber(state, pid)}

      entry = find_worker_by_pid(state.workers, pid) ->
        {key, _} = entry
        {:noreply, restart_worker(state, key)}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # -- Private --

  defp find_worker_by_pid(workers, pid) do
    Enum.find(workers, fn {_key, {_mod, worker_pid}} -> worker_pid == pid end)
  end

  defp restart_worker(state, key) do
    case Enum.find(state.entities, &(&1.key == key)) do
      nil ->
        %{state | workers: Map.delete(state.workers, key)}

      entity ->
        case start_worker(entity) do
          {:ok, new_pid} ->
            Logger.info("Infrared worker for key #{key} restarted")
            %{state | workers: Map.put(state.workers, key, {entity.device_module, new_pid})}

          {:error, reason} ->
            Logger.error("Failed to restart infrared worker for key #{key}: #{inspect(reason)}")
            %{state | workers: Map.delete(state.workers, key)}
        end
    end
  end

  defp remove_subscriber(state, pid) do
    {ref, monitors} = Map.pop(state.monitors, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    %{state | subscribers: MapSet.delete(state.subscribers, pid), monitors: monitors}
  end

  defp build_inventory do
    configs = UniversalProxy.UART.Store.all_configs()
    enumerated = Circuits.UART.enumerate()

    serial_to_entry =
      for {path, info} <- enumerated,
          present?(info[:serial_number]),
          into: %{},
          do: {info[:serial_number], {path, info}}

    ir_configs =
      Enum.filter(configs, fn config ->
        config[:port_type] == :infrared and
          Map.has_key?(serial_to_entry, config[:serial_number])
      end)

    pairs = Enum.flat_map(ir_configs, &start_entity(&1, serial_to_entry))
    entities = Enum.map(pairs, &elem(&1, 0))
    workers = Map.new(pairs, fn {e, pid} -> {e.key, {e.device_module, pid}} end)
    {entities, workers}
  rescue
    e ->
      Logger.warning(
        "Infrared inventory build failed: #{Exception.format(:error, e, __STACKTRACE__)}"
      )

      {[], %{}}
  end

  defp start_entity(config, serial_to_entry) do
    serial = config[:serial_number]
    {path, info} = Map.fetch!(serial_to_entry, serial)

    with {:ok, mod} <- find_product_module(info),
         entity = mod.build_entity(config, path, info),
         {:ok, pid} <- start_worker(entity) do
      [{entity, pid}]
    else
      :error ->
        Logger.debug("No product module matched infrared device at #{path}")
        []

      {:error, reason} ->
        Logger.warning("Failed to start infrared worker at #{path}: #{inspect(reason)}")
        []
    end
  end

  defp find_product_module(info) do
    case Enum.find(@product_modules, fn mod -> mod.match?(info) end) do
      nil -> :error
      mod -> {:ok, mod}
    end
  end

  defp start_worker(entity) do
    spec = entity.device_module.child_spec(entity, self())

    with {:ok, pid} <- DynamicSupervisor.start_child(@worker_supervisor, spec) do
      Process.monitor(pid)
      {:ok, pid}
    end
  end

  defp present?(s) when is_binary(s) and s != "", do: String.trim(s) != ""
  defp present?(_), do: false
end
