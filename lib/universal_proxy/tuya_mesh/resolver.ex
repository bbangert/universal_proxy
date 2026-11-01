defmodule UniversalProxy.TuyaMesh.Resolver do
  @moduledoc """
  Decides when the mesh runs, starts and stops it, and publishes its status.

  The mesh (`UniversalProxy.TuyaMesh.Mesh`) is started under the sibling
  DynamicSupervisor only when all of these hold:

    1. a radio holds the `:tuya_mesh` role (`:tuya_adapter`);
    2. the Store holds a valid inventory;
    3. that MAC is a present adapter (`Bluez.Client.adapters_info/0`), whose
       object path `/org/bluez/hciN` gives the Radio's `adapter_index`;
    4. it is not the only adapter present (the mesh adapter is dedicated,
       so a lone one would leave nothing for the proxy).

  Otherwise the Resolver stays idle with a `reason`. A missing adapter or a
  lone radio (a dongle that enumerates late, a claim that lags) is
  re-checked on a timer (2 s, doubling up to 30 s). No role and no
  inventory wait for an event instead: a role change restarts the whole
  Bluez subtree, and an upload goes through `replace/3`.

  The mesh is `:temporary`. If it exhausts its own restart budget it stops,
  and the Resolver tries again after 30 s rather than letting the failure
  escalate into the Bluez subtree. While it runs, the adapter index is
  re-checked every 30 s; a replugged dongle that came back under another
  index gets the mesh restarted on it.

  `replace/3` and `clear/1` stop the mesh before touching the Store and
  start it again after, so no Lights is left running on an inventory that
  is no longer stored (the Store refuses such a writer anyway, see
  `UniversalProxy.TuyaMesh.Store`).

  ## Status

  `status/1` is served from this process's state, never by calling into the
  mesh, so it stays cheap. The state is kept current by subscribing to the
  Radio's reports (each burst triggers one `Lights.all/1` read, 300 ms
  later) and by a 5 s tick that reads `Radio.status/1` (the Radio publishes
  no readiness events) and re-evaluates reachability. Every change is
  broadcast on `UniversalProxy.PubSub` topic `"tuya_mesh"` as
  `{:tuya_mesh_status, status}`. Statuses carry no keys.

  Options: `:tuya_adapter`, `:dynsup`, `:name`, and test seams `:store`,
  `:adapters_fun`, `:mesh_spec_fun` (`(index -> child_spec)`), `:radio`,
  `:lights`, `:pubsub`, `:retry_ms`, `:restart_ms`, `:tick_ms`,
  `:reachable_ms`.
  """

  use GenServer

  require Logger

  alias UniversalProxy.TuyaBeaconMesh.{Inventory, Lights, Radio}
  alias UniversalProxy.TuyaMesh.{Mesh, Store}

  @topic "tuya_mesh"
  @retry_ms 2_000
  @max_retry_ms 30_000
  @restart_ms 30_000
  @tick_ms 5_000
  @index_check_ticks 6
  @report_debounce_ms 300
  @reachable_ms 300_000
  # Stopping the mesh waits for the Radio's teardown (up to 10 s).
  @change_timeout 30_000

  @type reason ::
          :no_role
          | :no_inventory
          | :invalid_inventory
          | :store_unavailable
          | :adapter_missing
          | :lone_radio
          | :start_failed
          | :mesh_exited
          | :not_running

  @type status :: %{
          role_mac: String.t() | nil,
          state: :running | :idle,
          reason: reason() | nil,
          adapter_index: non_neg_integer() | nil,
          radio: %{ready: boolean(), last_error: term(), queued: non_neg_integer()} | nil,
          lights_running: boolean(),
          bulbs: [
            %{
              mac: String.t(),
              label: String.t() | nil,
              node_id: non_neg_integer(),
              last_seen: DateTime.t() | nil,
              reachable: boolean()
            }
          ],
          groups: [%{local_id: 0..254, name: String.t() | nil, members: [String.t()]}]
        }

  @doc "PubSub topic of `{:tuya_mesh_status, status}` broadcasts."
  @spec topic() :: String.t()
  def topic, do: @topic

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The current status (see the moduledoc). Exits when not running."
  @spec status(GenServer.server()) :: status()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Stops the mesh, runs `Store.replace/3`, then re-evaluates. Exits when not running."
  @spec replace(Inventory.t(), keyword(), GenServer.server()) ::
          {:ok, :same_mesh | :new_mesh} | {:error, term()}
  def replace(inventory, opts, server \\ __MODULE__),
    do: GenServer.call(server, {:replace, inventory, opts}, @change_timeout)

  @doc "Stops the mesh and clears the Store. Exits when not running."
  @spec clear(GenServer.server()) :: :ok | {:error, term()}
  def clear(server \\ __MODULE__), do: GenServer.call(server, :clear, @change_timeout)

  @doc false
  # The status shape for when no Resolver runs (`UniversalProxy.TuyaMesh`'s
  # fallback): idle, inventory from `load_result`, nothing live.
  @spec offline_status(String.t() | nil, reason(), {:ok, Inventory.t()} | {:error, term()}) ::
          status()
  def offline_status(mac, reason, load_result) do
    inventory =
      case load_result do
        {:ok, %Inventory{} = inv} -> summarize(inv)
        _ -> %{bulbs: [], groups: []}
      end

    %{
      role_mac: normalize_mac(mac),
      state: :idle,
      reason: reason,
      adapter_index: nil,
      radio: nil,
      lights_running: false,
      bulbs: Enum.map(inventory.bulbs, &Map.merge(&1, %{last_seen: nil, reachable: false})),
      groups: inventory.groups
    }
  end

  # ── Server ───────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    retry_ms = Keyword.get(opts, :retry_ms, @retry_ms)

    state = %{
      mac: opts |> Keyword.get(:tuya_adapter) |> normalize_mac(),
      dynsup: Keyword.fetch!(opts, :dynsup),
      store: Keyword.get(opts, :store, Store),
      adapters_fun: Keyword.get(opts, :adapters_fun, &Bluez.Client.adapters_info/0),
      mesh_spec_fun: Keyword.get(opts, :mesh_spec_fun, &Mesh.child_spec(adapter_index: &1)),
      radio: Keyword.get(opts, :radio, Radio),
      lights: Keyword.get(opts, :lights, Lights),
      pubsub: Keyword.get(opts, :pubsub, UniversalProxy.PubSub),
      retry_ms: retry_ms,
      backoff_ms: retry_ms,
      restart_ms: Keyword.get(opts, :restart_ms, @restart_ms),
      tick_ms: Keyword.get(opts, :tick_ms, @tick_ms),
      reachable_ms: Keyword.get(opts, :reachable_ms, @reachable_ms),
      timer: nil,
      refresh_timer: nil,
      ticks: 0,
      mesh: nil,
      reason: nil,
      inventory: nil,
      inventory_error: nil,
      radio_status: nil,
      subscribed: nil,
      lights_running: false,
      last_reports: %{},
      published: nil
    }

    {:ok, state, {:continue, :evaluate}}
  end

  @impl GenServer
  def handle_continue(:evaluate, state), do: {:noreply, state |> evaluate() |> publish()}

  @impl GenServer
  def handle_call(:status, _from, state), do: {:reply, build_status(state), state}

  def handle_call({:replace, inventory, opts}, _from, state) do
    state = stop_mesh(state)
    reply = Store.replace(inventory, opts, state.store)
    {:reply, reply, %{state | backoff_ms: state.retry_ms} |> evaluate() |> publish()}
  end

  def handle_call(:clear, _from, state) do
    state = stop_mesh(state)
    reply = Store.clear(state.store)
    {:reply, reply, %{state | backoff_ms: state.retry_ms} |> evaluate() |> publish()}
  end

  @impl GenServer
  # Timer messages carry the token they were armed with, so one that was
  # already delivered when its timer was cancelled is recognised and dropped.
  def handle_info({:evaluate, token}, %{timer: {token, _}} = state),
    do: {:noreply, %{state | timer: nil} |> evaluate() |> publish()}

  def handle_info({:tick, token}, %{timer: {token, _}, mesh: %{}} = state) do
    state = %{state | timer: nil, ticks: state.ticks + 1}

    state =
      if rem(state.ticks, @index_check_ticks) == 0,
        do: check_index(state),
        else: state

    {:noreply, state |> observe() |> schedule_tick() |> publish()}
  end

  def handle_info({:tuya_report, _report}, %{refresh_timer: nil, mesh: %{}} = state) do
    {:noreply, %{state | refresh_timer: arm(:refresh_reports, @report_debounce_ms)}}
  end

  def handle_info({:tuya_report, _report}, state), do: {:noreply, state}

  def handle_info({:refresh_reports, token}, %{refresh_timer: {token, _}} = state) do
    {:noreply, %{state | refresh_timer: nil} |> read_lights() |> publish()}
  end

  def handle_info({:DOWN, mon, :process, _pid, _reason}, %{mesh: %{mon: mon}} = state) do
    Logger.warning("TuyaMesh: mesh stopped on its own; retrying in #{state.restart_ms} ms")
    state = %{clear_mesh(state) | backoff_ms: state.restart_ms}
    {:noreply, state |> idle(:mesh_exited, true) |> publish()}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ── Lifecycle ────────────────────────────────────────────────────────

  defp evaluate(%{mesh: %{}} = state), do: state

  defp evaluate(state) do
    state = state |> cancel_timer() |> load_inventory()

    case start_conditions(state) do
      {:ok, index} -> start_mesh(state, index)
      {:idle, reason, retry?} -> idle(state, reason, retry?)
    end
  end

  defp start_conditions(%{mac: nil}), do: {:idle, :no_role, false}

  defp start_conditions(%{inventory: nil, inventory_error: :store_unavailable}),
    do: {:idle, :store_unavailable, true}

  defp start_conditions(%{inventory: nil, inventory_error: reason}), do: {:idle, reason, false}

  defp start_conditions(state) do
    case resolve_index(state) do
      {:ok, index} -> {:ok, index}
      {:error, reason} -> {:idle, reason, true}
    end
  end

  defp resolve_index(state) do
    adapters = state.adapters_fun.()

    with %{path: path} <- Enum.find(adapters, &(normalize_mac(&1[:address]) == state.mac)),
         {:ok, index} <- Bluez.Hci.adapter_index(path) do
      if Enum.any?(adapters, &(normalize_mac(&1[:address]) != state.mac)),
        do: {:ok, index},
        else: {:error, :lone_radio}
    else
      _ -> {:error, :adapter_missing}
    end
  end

  defp start_mesh(state, index) do
    case DynamicSupervisor.start_child(state.dynsup, state.mesh_spec_fun.(index)) do
      {:ok, pid} ->
        Logger.info("TuyaMesh: mesh started on hci#{index} (#{state.mac})")
        mesh = %{pid: pid, mon: Process.monitor(pid), index: index}

        %{state | mesh: mesh, reason: nil, backoff_ms: state.retry_ms, ticks: 0}
        |> observe()
        |> schedule_tick()

      other ->
        # Only the shape: a start error can carry child specs and args.
        Logger.warning("TuyaMesh: mesh failed to start (#{error_kind(other)})")
        idle(state, :start_failed, true)
    end
  end

  defp error_kind({:error, {reason, _detail}}) when is_atom(reason), do: inspect(reason)
  defp error_kind({:error, reason}) when is_atom(reason), do: inspect(reason)
  defp error_kind(:ignore), do: ":ignore"
  defp error_kind(_other), do: "error"

  defp idle(state, reason, retry?) do
    if reason != state.reason, do: log_idle(state, reason)

    state = %{state | reason: reason}

    if retry? do
      %{
        state
        | timer: arm(:evaluate, state.backoff_ms),
          backoff_ms: min(state.backoff_ms * 2, @max_retry_ms)
      }
    else
      state
    end
  end

  defp log_idle(state, reason) when reason in [:adapter_missing, :lone_radio] do
    Logger.warning("TuyaMesh: mesh idle (#{reason}) for #{state.mac}; retrying")
  end

  defp log_idle(_state, reason), do: Logger.info("TuyaMesh: mesh idle (#{reason})")

  defp stop_mesh(%{mesh: %{pid: pid, mon: mon}} = state) do
    Process.demonitor(mon, [:flush])
    _ = DynamicSupervisor.terminate_child(state.dynsup, pid)
    clear_mesh(state)
  end

  defp stop_mesh(state), do: cancel_timer(state)

  defp clear_mesh(state) do
    with {_token, tref} <- state.refresh_timer, do: Process.cancel_timer(tref)

    %{
      cancel_timer(state)
      | mesh: nil,
        refresh_timer: nil,
        radio_status: nil,
        subscribed: nil,
        lights_running: false,
        last_reports: %{}
    }
  end

  # A dongle replugged under a new index: move the mesh there. A missing
  # one is left to the Radio's own retries.
  defp check_index(%{mesh: %{index: index}} = state) do
    case resolve_index(state) do
      {:ok, ^index} ->
        state

      {:ok, new_index} ->
        Logger.info("TuyaMesh: #{state.mac} moved to hci#{new_index}; restarting the mesh")
        state |> stop_mesh() |> evaluate()

      {:error, _reason} ->
        state
    end
  end

  defp schedule_tick(%{mesh: %{}} = state) do
    %{cancel_timer(state) | timer: arm(:tick, state.tick_ms)}
  end

  defp schedule_tick(state), do: state

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: {_token, tref}} = state) do
    Process.cancel_timer(tref)
    %{state | timer: nil}
  end

  defp arm(tag, ms) do
    token = make_ref()
    {token, Process.send_after(self(), {tag, token}, ms)}
  end

  # ── Observation ──────────────────────────────────────────────────────

  defp load_inventory(state) do
    case Store.load(state.store) do
      {:ok, inv} -> %{state | inventory: summarize(inv), inventory_error: nil}
      {:error, :no_inventory} -> %{state | inventory: nil, inventory_error: :no_inventory}
      {:error, :unavailable} -> %{state | inventory: nil, inventory_error: :store_unavailable}
      {:error, _invalid} -> %{state | inventory: nil, inventory_error: :invalid_inventory}
    end
  end

  defp summarize(%Inventory{bulbs: bulbs, groups: groups}) do
    %{
      bulbs: Enum.map(bulbs, &%{mac: &1.mac, label: &1.label, node_id: &1.node_id}),
      groups: Enum.map(groups, &%{local_id: &1.local_id, name: &1.name, members: &1.members})
    }
  end

  defp observe(%{mesh: nil} = state), do: state
  defp observe(state), do: state |> subscribe_radio() |> read_radio() |> read_lights()

  # Radio subscriptions die with the Radio, so follow its current pid.
  defp subscribe_radio(state) do
    case GenServer.whereis(state.radio) do
      pid when is_pid(pid) and pid == state.subscribed ->
        state

      pid when is_pid(pid) ->
        case Radio.subscribe(self(), :all, server: pid) do
          :ok -> %{state | subscribed: pid}
          {:error, _} -> %{state | subscribed: nil}
        end

      _ ->
        %{state | subscribed: nil}
    end
  end

  defp read_radio(state) do
    radio_status =
      case Radio.status(server: state.radio) do
        {:ok, s} -> %{ready: s.ready, last_error: s.last_error, queued: s.queued}
        {:error, reason} -> %{ready: false, last_error: reason, queued: 0}
      end

    %{state | radio_status: radio_status}
  end

  defp read_lights(%{mesh: nil} = state), do: state

  defp read_lights(state) do
    case Lights.all(server: state.lights) do
      {:ok, bulbs} ->
        reports = Map.new(bulbs, &{&1.mac, &1.last_report_ms})
        %{state | lights_running: true, last_reports: reports}

      {:error, _} ->
        %{state | lights_running: false}
    end
  end

  defp build_status(state) do
    now = System.monotonic_time(:millisecond)
    inventory = state.inventory || %{bulbs: [], groups: []}

    %{
      role_mac: state.mac,
      state: if(state.mesh, do: :running, else: :idle),
      reason: state.reason,
      adapter_index: state.mesh && state.mesh.index,
      radio: state.radio_status,
      lights_running: state.lights_running,
      bulbs:
        Enum.map(inventory.bulbs, fn bulb ->
          last = Map.get(state.last_reports, bulb.mac)

          Map.merge(bulb, %{
            last_seen: last_seen(last),
            reachable: last != nil and now - last <= state.reachable_ms
          })
        end),
      groups: inventory.groups
    }
  end

  # Monotonic → wall clock, to the second so a slewing clock doesn't make
  # every tick look like a change.
  defp last_seen(nil), do: nil

  defp last_seen(ms) do
    (ms + System.time_offset(:millisecond))
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.truncate(:second)
  end

  defp publish(state) do
    status = build_status(state)

    if status != state.published do
      broadcast(state.pubsub, status)
      %{state | published: status}
    else
      state
    end
  end

  # PubSub's registry raises (not exits) when it isn't started.
  defp broadcast(pubsub, status) do
    Phoenix.PubSub.broadcast(pubsub, @topic, {:tuya_mesh_status, status})
  rescue
    ArgumentError -> :ok
  end

  defp normalize_mac(mac) when is_binary(mac), do: String.upcase(mac)
  defp normalize_mac(_mac), do: nil
end
