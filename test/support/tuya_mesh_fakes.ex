defmodule UniversalProxy.TuyaMesh.FakeLights do
  @moduledoc false
  # Answers `Lights.all/1`, `Lights.ping/2` and `Lights.ping_all/1` (plain
  # calls; a broadcast is recorded as `:all` in `pings`). Bulbs in
  # `replying` answer a ping at once: their `last_report_ms` becomes the
  # clock; those also in `deaf` don't answer broadcasts (a collision).
  # Bulbs in `held` answer with a frame Lights holds (a reset counter):
  # only their `heard_ms` moves. `ping_reply` is what every ping returns;
  # `on_ping` (`mac | :all -> any`) runs for each accepted one (to air it on
  # a FakeRadio, say). `all_reply`, when set, replaces `Lights.all/1`'s
  # answer. `heard` (`mac => ms`) adds frames heard but held (not
  # accepted), as Lights' `heard_ms` does.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

  def put(server, key, value), do: GenServer.call(server, {:put, key, value})
  def report(server, mac, ms), do: GenServer.call(server, {:report, mac, ms})
  # A DP report at `ms`: Lights merges `dps` into the bulb's.
  def report_dps(server, mac, ms, dps), do: GenServer.call(server, {:report_dps, mac, ms, dps})
  def pings(server), do: server |> log() |> Enum.map(&elem(&1, 0))
  # `[{mac | :all, at}]`, oldest first.
  def log(server), do: GenServer.call(server, :pings)

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       bulbs: Map.new(Keyword.get(opts, :macs, []), &{&1, nil}),
       replying: MapSet.new(Keyword.get(opts, :replying, [])),
       held: MapSet.new(Keyword.get(opts, :held, [])),
       deaf: MapSet.new(Keyword.get(opts, :deaf, [])),
       clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
       ping_reply: :ok,
       all_reply: nil,
       heard: %{},
       dps: %{},
       on_ping: Keyword.get(opts, :on_ping, fn _mac -> :ok end),
       pings: []
     }}
  end

  @impl GenServer
  def handle_call(:all, _from, %{all_reply: reply} = state) when reply != nil,
    do: {:reply, reply, state}

  def handle_call(:all, _from, state) do
    bulbs =
      state.bulbs
      |> Enum.sort()
      |> Enum.map(fn {mac, last} ->
        {dps, event} = Map.get(state.dps, mac, {%{}, nil})

        %{
          mac: mac,
          last_report_ms: last,
          heard_ms: later(Map.get(state.heard, mac), last),
          dps: dps,
          last_event: event
        }
      end)

    {:reply, {:ok, bulbs}, state}
  end

  def handle_call({:ping, mac}, _from, state) do
    state = %{state | pings: [{mac, state.clock.()} | state.pings]}
    if state.ping_reply == :ok, do: state.on_ping.(mac)

    state =
      cond do
        state.ping_reply != :ok -> state
        mac in state.replying -> %{state | bulbs: Map.put(state.bulbs, mac, state.clock.())}
        mac in state.held -> %{state | heard: Map.put(state.heard, mac, state.clock.())}
        true -> state
      end

    {:reply, state.ping_reply, state}
  end

  def handle_call(:ping_all, _from, state) do
    state = %{state | pings: [{:all, state.clock.()} | state.pings]}
    if state.ping_reply == :ok, do: state.on_ping.(:all)

    state =
      if state.ping_reply == :ok,
        do: Enum.reduce(state.bulbs, state, &answer_broadcast(&2, elem(&1, 0))),
        else: state

    {:reply, state.ping_reply, state}
  end

  def handle_call({:put, set, macs}, _from, state) when set in [:replying, :deaf, :held],
    do: {:reply, :ok, Map.put(state, set, MapSet.new(macs))}

  def handle_call({:put, :macs, macs}, _from, state),
    do: {:reply, :ok, %{state | bulbs: Map.new(macs, &{&1, Map.get(state.bulbs, &1)})}}

  def handle_call({:put, :bulbs, bulbs}, _from, state),
    do: {:reply, :ok, %{state | bulbs: bulbs}}

  def handle_call({:put, key, value}, _from, state), do: {:reply, :ok, Map.put(state, key, value)}

  def handle_call({:report, mac, ms}, _from, state),
    do: {:reply, :ok, %{state | bulbs: Map.put(state.bulbs, mac, ms)}}

  def handle_call({:report_dps, mac, ms, dps}, _from, state) do
    {known, _event} = Map.get(state.dps, mac, {%{}, nil})

    {:reply, :ok,
     %{
       state
       | bulbs: Map.put(state.bulbs, mac, ms),
         dps: Map.put(state.dps, mac, {Map.merge(known, dps), {:dp_report, 7}})
     }}
  end

  def handle_call(:pings, _from, state), do: {:reply, Enum.reverse(state.pings), state}

  defp answer_broadcast(state, mac) do
    cond do
      mac in state.deaf -> state
      mac in state.replying -> %{state | bulbs: Map.put(state.bulbs, mac, state.clock.())}
      mac in state.held -> %{state | heard: Map.put(state.heard, mac, state.clock.())}
      true -> state
    end
  end

  # As in Lights: heard_ms is never behind last_report_ms.
  defp later(nil, b), do: b
  defp later(a, nil), do: a
  defp later(a, b), do: max(a, b)
end

defmodule UniversalProxy.TuyaMesh.FakeRadio do
  @moduledoc false
  # Answers `Radio.status/1` with whatever was put; accepts subscriptions.
  # `air/1` puts the next frame on air for 3 s of the clock, as the Radio
  # does for a send while idle.
  use GenServer

  @idle %{
    ready: true,
    discovering: true,
    listening: true,
    last_error: nil,
    queued: 0,
    tx: nil,
    last_tx_sn: 0
  }

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

  def put(server, changes), do: GenServer.call(server, {:put, changes})
  def air(server), do: GenServer.call(server, :air)

  @impl GenServer
  def init(opts) do
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
    status = Map.merge(@idle, Map.new(Keyword.get(opts, :status, [])))
    {:ok, %{status: status, clock: clock, air_until: nil}}
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    airing = state.air_until != nil and state.clock.() < state.air_until
    tx = state.status.tx || if(airing, do: %{class: :normal, instance: 1})
    {:reply, {:ok, %{state.status | tx: tx}}, state}
  end

  def handle_call({:put, changes}, _from, state),
    do: {:reply, :ok, %{state | status: Map.merge(state.status, changes)}}

  def handle_call(:air, _from, state) do
    sn = rem((state.status.last_tx_sn || 0) + 1, 65_536)

    {:reply, :ok,
     %{state | status: %{state.status | last_tx_sn: sn}, air_until: state.clock.() + 3_000}}
  end

  def handle_call({:subscribe, _pid, _filter}, _from, state), do: {:reply, :ok, state}
end
