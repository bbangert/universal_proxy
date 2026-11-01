defmodule UniversalProxy.TuyaMesh.FakeLights do
  @moduledoc false
  # Answers `Lights.all/1` and `Lights.ping/2` (both plain calls). Bulbs in
  # `replying` answer a ping at once: their `last_report_ms` becomes the
  # clock. `ping_reply` is what every ping returns.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

  def put(server, key, value), do: GenServer.call(server, {:put, key, value})
  def report(server, mac, ms), do: GenServer.call(server, {:report, mac, ms})
  def pings(server), do: GenServer.call(server, :pings)

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       bulbs: Map.new(Keyword.get(opts, :macs, []), &{&1, nil}),
       replying: MapSet.new(Keyword.get(opts, :replying, [])),
       clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
       ping_reply: :ok,
       pings: []
     }}
  end

  @impl GenServer
  def handle_call(:all, _from, state) do
    bulbs =
      state.bulbs
      |> Enum.sort()
      |> Enum.map(fn {mac, last} -> %{mac: mac, last_report_ms: last} end)

    {:reply, {:ok, bulbs}, state}
  end

  def handle_call({:ping, mac}, _from, state) do
    state = %{state | pings: [mac | state.pings]}

    state =
      if state.ping_reply == :ok and mac in state.replying,
        do: %{state | bulbs: Map.put(state.bulbs, mac, state.clock.())},
        else: state

    {:reply, state.ping_reply, state}
  end

  def handle_call({:put, :replying, macs}, _from, state),
    do: {:reply, :ok, %{state | replying: MapSet.new(macs)}}

  def handle_call({:put, :macs, macs}, _from, state),
    do: {:reply, :ok, %{state | bulbs: Map.new(macs, &{&1, Map.get(state.bulbs, &1)})}}

  def handle_call({:put, :bulbs, bulbs}, _from, state),
    do: {:reply, :ok, %{state | bulbs: bulbs}}

  def handle_call({:put, key, value}, _from, state), do: {:reply, :ok, Map.put(state, key, value)}

  def handle_call({:report, mac, ms}, _from, state),
    do: {:reply, :ok, %{state | bulbs: Map.put(state.bulbs, mac, ms)}}

  def handle_call(:pings, _from, state), do: {:reply, Enum.reverse(state.pings), state}
end

defmodule UniversalProxy.TuyaMesh.FakeRadio do
  @moduledoc false
  # Answers `Radio.status/1` with whatever was put; accepts subscriptions.
  use GenServer

  @idle %{ready: true, last_error: nil, queued: 0, tx: nil}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

  def put(server, changes), do: GenServer.call(server, {:put, changes})

  @impl GenServer
  def init(opts), do: {:ok, Map.merge(@idle, Map.new(Keyword.get(opts, :status, [])))}

  @impl GenServer
  def handle_call(:status, _from, state), do: {:reply, {:ok, state}, state}
  def handle_call({:put, changes}, _from, state), do: {:reply, :ok, Map.merge(state, changes)}
  def handle_call({:subscribe, _pid, _filter}, _from, state), do: {:reply, :ok, state}
end
