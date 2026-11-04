defmodule UniversalProxy.TuyaBeaconMesh.FakeHciUser do
  @moduledoc """
  A stand-in for `Bluez.HciUser` with the functions
  `UniversalProxy.TuyaBeaconMesh.Radio.Transport.UserChannel` calls, the
  same arities (checked by `fake_bluez_test.exs`) and the same messages.
  Compile-only test support, never deployed.

  Started through `start/1` with the transport's `:hci_user_opts`, which
  must hold `test:` (a pid told every call as `{:hci, server, call}`) and
  `control:` (an Agent holding a map of results to return instead of
  success, keyed by function name: `:start` → `{:error, reason}`,
  `:bd_addr` → the address Read BD_ADDR answers (default the bound
  `:address`), `:index` (default 0), and any command name → its
  result; `{name, first_arg}` keys one variant, e.g.
  `{:le_set_advertising_enable, false}`). A list is a queue of results,
  one per call. A result `{:close, reply, reason}` replies `reply`, then sends
  the owner `{:closed, reason}` and stops, as the real server does for a
  command that timed out in flight.

  `emit/2` makes the server send its owner `{:bluez_hci_user, server,
  event}`; `{:closed, reason}` also stops it.
  """

  use GenServer

  alias Bluez.HciUser.Codec

  # ── Bluez.HciUser API ────────────────────────────────────────────────

  def start(opts) do
    test = Keyword.fetch!(opts, :test)
    control = Keyword.fetch!(opts, :control)

    send(
      test,
      {:hci, nil, {:start, Keyword.fetch!(opts, :address), Keyword.fetch!(opts, :owner)}}
    )

    case control(control, :start) do
      nil -> GenServer.start(__MODULE__, opts)
      {:error, _reason} = error -> error
    end
  end

  def start_link(opts), do: start(opts)

  def close(server) do
    GenServer.stop(server, :normal)
  catch
    :exit, _reason -> :ok
  end

  def index(server), do: call(server, :index)

  def command(server, opcode, params \\ <<>>, timeout \\ 2_000),
    do: call(server, {:command, {opcode, params, timeout}})

  def reset(server, timeout \\ 5_000), do: cmd(server, :reset, [timeout])
  def read_bd_addr(server, timeout \\ 2_000), do: call(server, {:read_bd_addr, timeout})

  def read_local_version(server, timeout \\ 2_000),
    do: cmd(server, :read_local_version, [timeout])

  def le_read_local_supported_features(server, timeout \\ 2_000),
    do: cmd(server, :le_read_local_supported_features, [timeout])

  def le_read_num_supported_adv_sets(server, timeout \\ 2_000),
    do: cmd(server, :le_read_num_supported_adv_sets, [timeout])

  def set_event_mask(server, mask, timeout \\ 2_000),
    do: cmd(server, :set_event_mask, [mask, timeout])

  def le_set_event_mask(server, mask, timeout \\ 2_000),
    do: cmd(server, :le_set_event_mask, [mask, timeout])

  # The real codec runs in the caller, so bad parameters raise there too.
  def le_set_scan_parameters(server, opts, timeout \\ 2_000) do
    _ = Codec.scan_parameters(opts)
    cmd(server, :le_set_scan_parameters, [opts, timeout])
  end

  def le_set_scan_enable(server, enable, filter_duplicates, timeout \\ 2_000),
    do: cmd(server, :le_set_scan_enable, [enable, filter_duplicates, timeout])

  def le_set_advertising_parameters(server, opts, timeout \\ 2_000) do
    _ = Codec.advertising_parameters(opts)
    cmd(server, :le_set_advertising_parameters, [opts, timeout])
  end

  def le_set_advertising_data(server, data, timeout \\ 2_000) do
    _ = Codec.advertising_data(data)
    cmd(server, :le_set_advertising_data, [data, timeout])
  end

  def le_set_advertising_enable(server, enable, timeout \\ 2_000),
    do: cmd(server, :le_set_advertising_enable, [enable, timeout])

  # ── Test helpers ─────────────────────────────────────────────────────

  @doc "Makes `server` send its owner `event`."
  def emit(server, event), do: GenServer.call(server, {:emit, event})

  defp cmd(server, name, args), do: call(server, {:command, name, args})

  # The real server's exit-safe wrapper: a gone server is :closed.
  defp call(server, request) do
    GenServer.call(server, request)
  catch
    :exit, _reason -> {:error, :closed}
  end

  # A list is a queue of results, one per call (then success); anything
  # else is returned on every call.
  defp control(control, key) do
    Agent.get_and_update(control, fn map ->
      case Map.get(map, key) do
        [next | rest] -> {next, Map.put(map, key, rest)}
        [] -> {nil, map}
        value -> {value, map}
      end
    end)
  end

  # ── Server ───────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    state = %{
      test: Keyword.fetch!(opts, :test),
      control: Keyword.fetch!(opts, :control),
      owner: Keyword.fetch!(opts, :owner),
      address: Keyword.fetch!(opts, :address)
    }

    Process.monitor(state.owner)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:index, _from, state) do
    tell(state, :index)
    {:reply, {:ok, control(state.control, :index) || 0}, state}
  end

  def handle_call({:read_bd_addr, timeout}, _from, state) do
    tell(state, {:read_bd_addr, timeout})

    case control(state.control, :read_bd_addr) do
      nil -> {:reply, {:ok, control(state.control, :bd_addr) || state.address}, state}
      result -> reply(result, state)
    end
  end

  def handle_call({:command, name, args}, _from, state) do
    tell(state, List.to_tuple([name | args]))

    # `{name, first_arg}` (e.g. `{:le_set_advertising_enable, false}`)
    # before `name`.
    key =
      if args != [] and control?(state.control, {name, hd(args)}),
        do: {name, hd(args)},
        else: name

    case control(state.control, key) do
      nil -> {:reply, default(name), state}
      result -> reply(result, state)
    end
  end

  def handle_call({:emit, {:closed, _reason} = event}, _from, state) do
    notify(state, event)
    {:stop, :normal, :ok, state}
  end

  def handle_call({:emit, event}, _from, state) do
    notify(state, event)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:DOWN, _mon, :process, owner, _reason}, %{owner: owner} = state),
    do: {:stop, :normal, state}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    tell(state, :closed)
    :ok
  end

  defp reply({:close, reply, reason}, state) do
    notify(state, {:closed, reason})
    {:stop, :normal, reply, state}
  end

  defp reply(result, state), do: {:reply, result, state}

  defp default(:read_local_version),
    do:
      {:ok,
       %{
         hci_version: 10,
         hci_revision: 0xD922,
         lmp_version: 10,
         manufacturer: 93,
         lmp_subversion: 0xD922
       }}

  defp default(:le_read_local_supported_features), do: {:ok, 0x665FBD}
  defp default(:le_read_num_supported_adv_sets), do: {:ok, 4}
  defp default(_name), do: :ok

  defp control?(control, key), do: Agent.get(control, &Map.has_key?(&1, key))

  defp tell(state, call), do: send(state.test, {:hci, self(), call})
  defp notify(state, event), do: send(state.owner, {:bluez_hci_user, self(), event})
end
