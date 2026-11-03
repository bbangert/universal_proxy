defmodule UniversalProxy.TuyaMesh.CommanderTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Espex.Proto.LightCommandRequest, as: Req
  alias Espex.Proto.LightStateResponse
  alias UniversalProxy.TuyaMesh.{Commander, Commands}

  @settings %{min_mireds: 154, max_mireds: 370, invert: false}
  @a "DC23530FB34A"
  @b "DC23533FCD62"
  @c "DC2353000001"
  @d "DC2353000002"
  @e "DC2353000003"
  @ids %{
    {:bulb, @a} => 5,
    {:bulb, @b} => 7,
    {:bulb, @c} => 8,
    {:bulb, @d} => 12,
    {:bulb, @e} => 14,
    {:group, 5} => 13,
    {:group, 1} => 6,
    {:group, 2} => 9,
    {:group, 3} => 11
  }

  # A Lights stand-in: records calls to the test, replies from a script,
  # and makes the `hears` bulbs report what a group frame set.
  defmodule FakeLights do
    alias UniversalProxy.TuyaMesh.Commands

    def set(mac, batch, opts), do: call(opts, {:set, mac, batch, Keyword.delete(opts, :server)})

    def group_set(gid, batch, opts),
      do: call(opts, {:group_set, gid, batch, Keyword.delete(opts, :server)})

    def all(opts), do: call(opts, :all)
    def status(mac, opts), do: call(opts, {:status, mac})

    defp call(opts, request) do
      Agent.get_and_update(Keyword.fetch!(opts, :server), fn s ->
        case refusing(s, request) do
          nil -> handle(request, s)
          refused -> {refused, s}
        end
      end)
    end

    defp handle({:set, mac, batch, opts} = req, s) do
      s = s.on_set.(mac, s)
      send(s.test, {:lights, req})
      send(s.test, {:set_at, mac, System.monotonic_time(:millisecond)})
      {reply, rest} = pop(Map.get(s.set, mac, []))
      s = %{s | set: Map.put(s.set, mac, rest)}
      s = if reply == :ok and opts[:ack], do: report(s, mac, batch), else: s
      {reply, s}
    end

    defp handle({:group_set, _gid, batch, _opts} = req, s) do
      send(s.test, {:lights, req})
      {reply, rest} = pop(s.group_set)
      s = %{s | group_set: rest}
      hears = if is_function(s.hears, 1), do: s.hears.(batch), else: s.hears
      s = if reply == :ok, do: Enum.reduce(hears, s, &report(&2, &1, batch)), else: s
      {reply, s}
    end

    # `on_all` runs on every read (the count includes this one), e.g. to
    # replace the mesh while a read is in flight.
    defp handle(:all, s) do
      s = %{s | all_reads: s.all_reads + 1}
      s = s.on_all.(s)
      bulbs = for {mac, b} <- s.bulbs, do: Map.put(b, :mac, mac)
      {{:ok, bulbs}, s}
    end

    defp handle({:status, mac}, s) do
      send(s.test, {:lights, {:status, mac}})
      {{:ok, %{dps: get_in(s.bulbs, [mac, :dps]) || %{}}}, s}
    end

    # Every send is refused for capacity (and not recorded) until
    # `refuse_until` (monotonic ms).
    defp refusing(%{refuse_until: until} = s, {kind, _, _, _})
         when is_integer(until) and kind in [:set, :group_set] do
      if System.monotonic_time(:millisecond) < until do
        send(s.test, {:lights, :refused})
        {:error, :queue_full}
      end
    end

    defp refusing(_s, _request), do: nil

    defp pop([]), do: {:ok, []}
    defp pop([reply | rest]), do: {reply, rest}

    defp report(s, mac, batch) do
      s = %{s | clock: s.clock + 1}
      sent = Commands.expected(batch)
      bulb = Map.get(s.bulbs, mac, %{dps: %{}, last_report_ms: nil})

      stamps =
        Map.merge(
          Map.get(bulb, :dp_reported_at, %{}),
          Map.new(sent, fn {dp, _} -> {dp, s.clock} end)
        )

      bulb =
        Map.merge(bulb, %{
          dps: Map.merge(bulb.dps, sent),
          last_report_ms: s.clock,
          dp_reported_at: stamps
        })

      %{s | bulbs: Map.put(s.bulbs, mac, bulb)}
    end
  end

  defp start(opts \\ []) do
    test = self()
    {script, opts} = Keyword.pop(opts, :script, %{})

    agent =
      start_supervised!(
        {Agent,
         fn ->
           Map.merge(
             %{
               test: test,
               set: %{},
               group_set: [],
               hears: [],
               bulbs: %{},
               clock: 0,
               ids: @ids,
               all_reads: 0,
               on_all: & &1,
               on_set: fn _mac, s -> s end
             },
             script
           )
         end}
      )

    defaults = [
      name: nil,
      lights: FakeLights,
      lights_opts: [server: agent],
      members: fn
        1 -> {:ok, [@a, @b, @c]}
        3 -> {:ok, [@b, @c]}
        5 -> {:ok, [@d]}
        _ -> :error
      end,
      push: &send(test, {:push, &1}),
      device_ids: fn -> Agent.get(agent, & &1.ids) end,
      radio_status: fn -> Agent.get(agent, &radio_status/1) end,
      radio_poll_ms: 10,
      # Status-driven pushes only where a test asks for them.
      push_debounce_ms: 60_000,
      settings: fn -> @settings end,
      subscribe: false,
      window_ms: 20,
      retry_ms: 1,
      max_retry_ms: 5,
      followup_gap_ms: 0,
      presence: test,
      max_followups: 10
    ]

    {:ok, pid} = Commander.start_link(Keyword.merge(defaults, opts))
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {pid, agent}
  end

  defp cmd(target, request, key \\ 77, device_id \\ nil) do
    %{
      target: target,
      key: key,
      device_id: device_id || Map.fetch!(@ids, target),
      settings: @settings,
      request: request
    }
  end

  defp cb(value), do: %Req{has_color_brightness: true, color_brightness: value}

  defp new_mesh(agent, changes),
    do: Agent.update(agent, fn s -> %{s | ids: Map.merge(s.ids, changes)} end)

  defp on, do: %Req{has_state: true, state: true}

  defp warm_full_on do
    %Req{
      has_state: true,
      state: true,
      has_brightness: true,
      brightness: 1.0,
      has_color_mode: true,
      color_mode: :COLOR_MODE_COLOR_TEMPERATURE,
      has_color_temperature: true,
      color_temperature: 370.0
    }
  end

  # Waits until no command has work left (timers included).
  defp idle(pid, deadline \\ System.monotonic_time(:millisecond) + 10_000) do
    state = :sys.get_state(pid)

    cond do
      state.jobs == %{} -> state
      System.monotonic_time(:millisecond) > deadline -> flunk("commands still running")
      true -> wait_and_idle(pid, deadline)
    end
  end

  defp wait_and_idle(pid, deadline) do
    Process.sleep(5)
    idle(pid, deadline)
  end

  defp now, do: System.monotonic_time(:millisecond)

  @groups [%{local_id: 1, members: [@a, @b, @c]}, %{local_id: 3, members: [@b, @c]}]

  # A Resolver status: `bulbs` as {mac, dps, dps_at}.
  defp status(bulbs, groups \\ @groups) do
    %{
      bulbs:
        for {mac, dps, at} <- bulbs do
          %{mac: mac, dps: dps, dp_at: Map.new(dps, fn {dp, _v} -> {dp, at} end), dps_at: at}
        end,
      groups: groups
    }
  end

  defp report(pid, bulbs) do
    send(pid, {:tuya_mesh_status, status(bulbs)})
    flushed(pid)
  end

  # Waits until nothing is waiting to be pushed.
  defp flushed(pid, deadline \\ System.monotonic_time(:millisecond) + 10_000) do
    state = :sys.get_state(pid)

    cond do
      state.flush == nil and MapSet.size(state.dirty) == 0 ->
        state

      System.monotonic_time(:millisecond) > deadline ->
        flunk("pushes still pending")

      true ->
        Process.sleep(5)
        flushed(pid, deadline)
    end
  end

  # Every push so far, by device id, in order.
  defp pushes(acc \\ []) do
    receive do
      {:push, %LightStateResponse{} = r} -> pushes([r | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp key_of({:bulb, mac}),
    do:
      UniversalProxy.TuyaMesh.Entities.key_for(
        UniversalProxy.TuyaMesh.Entities.object_id({:bulb, mac, :light})
      )

  defp key_of({:group, gid}),
    do:
      UniversalProxy.TuyaMesh.Entities.key_for(
        UniversalProxy.TuyaMesh.Entities.object_id({:group, gid, :light})
      )

  defp of(pushed, device_id), do: Enum.filter(pushed, &(&1.device_id == device_id))

  defp last_push(pushed, device_id),
    do: pushed |> Enum.filter(&(&1.device_id == device_id)) |> List.last()

  # The Radio's queue as the test sets it (`:radio_queued`, default empty;
  # `:down` for a Radio that doesn't answer).
  defp radio_status(s) do
    case Map.get(s, :radio_queued, 0) do
      :down -> {:error, :not_running}
      queued -> {:ok, %{queued: queued}}
    end
  end

  defp flush_activity(n \\ 0) do
    receive do
      {:"$gen_cast", {:command_activity, _hold}} -> flush_activity(n + 1)
    after
      0 -> n
    end
  end

  defp refusals(n \\ 0) do
    receive do
      {:lights, :refused} -> refusals(n + 1)
    after
      0 -> n
    end
  end

  defp last_group_set(last \\ nil) do
    receive do
      {:lights, {:group_set, _gid, batch, _opts}} -> last_group_set(batch)
      {:lights, :refused} -> last_group_set(last)
    after
      0 -> last
    end
  end

  # Every set's MAC and call time, in order.
  defp set_times(acc \\ []) do
    receive do
      {:set_at, mac, at} -> set_times([{mac, at} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp sets(acc \\ []) do
    receive do
      {:lights, {:set, mac, batch, _opts}} -> sets([{mac, batch} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "bulb" do
    test "batches go out in order, acked, then the optimistic state is pushed" do
      {pid, _agent} = start()
      Commander.command(cmd({:bulb, @a}, warm_full_on()), pid)

      assert_receive {:lights, {:status, @a}}, 2_000
      assert_receive {:lights, {:set, @a, [on: true, mode: :white, temp: 0], [ack: true]}}, 2_000
      assert_receive {:lights, {:set, @a, [brightness: 1000], [ack: true]}}, 2_000

      assert_receive {:push, %LightStateResponse{} = r}, 2_000
      assert %{device_id: 5, state: true, brightness: 1.0} = r
      assert r.color_mode == :COLOR_MODE_COLOR_TEMPERATURE
      assert r.color_temperature == 370.0
      assert idle(pid).jobs == %{}
    end

    test "busy and queue_full are retried, then it goes on" do
      script = %{set: %{@a => [{:error, :busy}, {:error, :queue_full}, :ok]}}
      {pid, _agent} = start(script: script)

      Commander.command(cmd({:bulb, @a}, on()), pid)
      idle(pid)

      assert sets() == List.duplicate({@a, [on: true]}, 3)
      assert_received {:push, %LightStateResponse{state: true}}
    end

    test "a command that can't be sent within the bound is dropped, pushing nothing" do
      {pid, agent} = start(stale_ms: 100)
      Agent.update(agent, &Map.put(&1, :refuse_until, now() + 60_000))

      Commander.command(cmd({:bulb, @a}, on()), pid)
      idle(pid)

      assert :sys.get_state(pid).jobs == %{}
      assert sets() == []
      refute_received {:push, _}
    end

    test "capacity refusals well past the old retry cap still end in the command running" do
      {pid, agent} = start(max_retry_ms: 20)
      Agent.update(agent, &Map.put(&1, :refuse_until, now() + 400))

      Commander.command(cmd({:bulb, @a}, on()), pid)
      idle(pid)

      assert [{@a, [on: true]}] = sets()
      assert refusals() > 5
      assert_received {:push, %LightStateResponse{state: true}}
    end

    test "two rapid commands to different lights both complete" do
      script = %{set: %{@b => [{:error, :queue_full}, {:error, :queue_full}, :ok]}}
      {pid, _agent} = start(script: script)

      Commander.command(cmd({:bulb, @a}, on()), pid)
      Commander.command(cmd({:bulb, @b}, %Req{has_state: true, state: false}), pid)
      idle(pid)

      assert {@a, [on: true]} in sets()
      assert_received {:push, %LightStateResponse{device_id: 5, state: true}}
      assert_received {:push, %LightStateResponse{device_id: 7, state: false}}
    end

    test "each command tells Presence to hold off pings" do
      {pid, _agent} = start()
      Commander.command(cmd({:bulb, @a}, on()), pid)
      assert_receive {:"$gen_cast", {:command_activity, 5_000}}, 2_000
      idle(pid)
    end

    test "any other error stops the command" do
      script = %{set: %{@a => [{:error, :not_ready}]}}
      {pid, _agent} = start(script: script)

      Commander.command(cmd({:bulb, @a}, warm_full_on()), pid)
      idle(pid)

      assert [{@a, [on: true, mode: :white, temp: 0]}] = sets()
      refute_received {:push, _}
    end

    test "a light whose on/off is unknown gets no optimistic push" do
      {pid, _agent} = start()
      Commander.command(cmd({:bulb, @a}, %Req{has_brightness: true, brightness: 0.5}), pid)
      idle(pid)

      assert [{@a, [brightness: 500]}] = sets()
      refute_received {:push, _}
    end

    test "the view carries over: a later brightness keeps the colour" do
      {pid, _agent} = start()

      red = %Req{has_state: true, state: true, has_rgb: true, red: 1.0, green: 0.0, blue: 0.0}
      Commander.command(cmd({:bulb, @a}, red), pid)
      idle(pid)
      assert [{@a, [on: true, mode: :colour, colour: {0, 100, 100}]}] = sets()
      assert_received {:push, %{color_mode: :COLOR_MODE_RGB}}

      Commander.command(cmd({:bulb, @a}, %Req{has_brightness: true, brightness: 0.2}), pid)
      idle(pid)
      assert [{@a, [colour: {0, 100, 20}]}] = sets()
      assert_received {:push, %{color_mode: :COLOR_MODE_RGB, brightness: 0.2, red: 1.0}}
    end

    test "a newer command supersedes the older one's remaining batches and retries" do
      script = %{set: %{@a => [{:error, :busy}]}}
      {pid, _agent} = start(script: script, retry_ms: 200)

      Commander.command(cmd({:bulb, @a}, warm_full_on()), pid)
      assert_receive {:lights, {:set, @a, [on: true, mode: :white, temp: 0], _}}, 2_000

      Commander.command(cmd({:bulb, @a}, %Req{has_state: true, state: false}), pid)
      idle(pid)

      assert sets() == [{@a, [on: false]}]

      assert_received {:push, %LightStateResponse{state: false}}
      refute_received {:push, %LightStateResponse{state: true}}
    end

    test "colour brightness is kept apart from brightness, so repeats are stable" do
      {pid, _agent} = start()

      red = %Req{has_state: true, state: true, has_rgb: true, red: 1.0, green: 0.0, blue: 0.0}
      Commander.command(cmd({:bulb, @a}, red), pid)
      idle(pid)
      assert [{@a, [on: true, mode: :colour, colour: {0, 100, 100}]}] = sets()

      for {request, v} <- [
            {cb(0.5), 50},
            {cb(0.5), 50},
            {%Req{has_brightness: true, brightness: 0.4}, 20},
            {cb(1.0), 40},
            {cb(1.0), 40}
          ] do
        Commander.command(cmd({:bulb, @a}, request), pid)
        idle(pid)
        assert [{@a, [colour: {0, 100, ^v}]}] = sets()
      end

      assert %{brightness: 0.4, color_brightness: 1.0} =
               :sys.get_state(pid).views[{:bulb, @a}].dps
    end

    test "a brightness frame that failed leaves the kept brightness as it was" do
      script = %{set: %{@a => [:ok, :ok, {:error, :not_ready}]}}
      {pid, _agent} = start(script: script)

      red = %Req{has_state: true, state: true, has_rgb: true, red: 1.0, green: 0.0, blue: 0.0}
      Commander.command(cmd({:bulb, @a}, red), pid)
      idle(pid)
      assert [_red] = sets()

      white = %{warm_full_on() | brightness: 0.3}
      Commander.command(cmd({:bulb, @a}, white), pid)
      idle(pid)
      assert [{@a, [on: true, mode: :white, temp: 0]}, {@a, [brightness: 300]}] = sets()
      assert :sys.get_state(pid).views[{:bulb, @a}].dps.brightness == 1.0

      green = %Req{has_rgb: true, red: 0.0, green: 1.0, blue: 0.0}
      Commander.command(cmd({:bulb, @a}, green), pid)
      idle(pid)
      assert [{@a, [mode: :colour, colour: {120, 100, 100}]}] = sets()
    end

    test "nothing mappable sends nothing" do
      {pid, _agent} = start()
      Commander.command(cmd({:bulb, @a}, %Req{has_effect: true, effect: "x"}), pid)
      idle(pid)
      assert sets() == []
    end
  end

  describe "light state" do
    @on_white %{1 => true, 2 => 0, 3 => 1000, 4 => 0}
    @off %{1 => false, 2 => 0, 3 => 1000, 4 => 0}

    test "a group command, then member reports: members pushed, groups re-derived" do
      {pid, _agent} = start(push_debounce_ms: 10)
      report(pid, [])

      Commander.command(cmd({:group, 1}, on()), pid)
      idle(pid)
      flushed(pid)
      # The group's own optimistic state at once (no member known yet).
      assert %{state: true} = last_push(pushes(), 6)

      at = now()
      report(pid, for(mac <- [@a, @b, @c], do: {mac, @on_white, at}))
      pushed = pushes()

      for id <- [5, 7, 8] do
        assert %{state: true, brightness: 1.0, color_temperature: 370.0} = last_push(pushed, id)
      end

      # Group 3 (B, C) is derived too; group 1 already showed on.
      assert %{state: true} = last_push(pushed, 11)
      assert key_of({:group, 3}) == last_push(pushed, 11).key
      assert key_of({:bulb, @a}) == last_push(pushed, 5).key
    end

    test "overlapping groups stay consistent: 'all' off clears a stale 'on'" do
      {pid, _agent} = start(push_debounce_ms: 10)
      at = now()
      report(pid, for(mac <- [@a, @b, @c], do: {mac, @off, at}))
      _ = pushes()

      # Group 3 is turned on (optimistic, members follow), then group 1 off.
      Commander.command(cmd({:group, 3}, on()), pid)
      idle(pid)
      flushed(pid)
      assert %{state: true} = last_push(pushes(), 11)

      Commander.command(cmd({:group, 1}, %Req{has_state: true, state: false}), pid)
      idle(pid)
      flushed(pid)
      pushed = pushes()
      assert %{state: false} = last_push(pushed, 6)
      assert %{state: false} = last_push(pushed, 11)

      # The bulbs then report off: nothing changes, nothing more is pushed.
      later = now() + 1
      report(pid, for(mac <- [@a, @b, @c], do: {mac, @off, later}))
      assert pushes() == []
    end

    test "a real report supersedes only what was set before it" do
      {pid, _agent} = start(push_debounce_ms: 10)
      at = now()
      report(pid, [{@a, @on_white, at}])
      assert [%{device_id: 5, brightness: 1.0}] = of(pushes(), 5)

      Commander.command(cmd({:bulb, @a}, %Req{has_brightness: true, brightness: 0.5}), pid)
      idle(pid)
      assert %{brightness: 0.5} = last_push(pushes(), 5)

      # A report older than the send: its brightness doesn't win.
      report(pid, [{@a, Map.put(@on_white, 1, true), at + 1}])
      assert of(pushes(), 5) == []

      # A newer one does.
      report(pid, [{@a, @on_white, now() + 1}])
      assert [%{device_id: 5, brightness: 1.0}] = of(pushes(), 5)
    end

    test "a reported colour resets components its v doesn't match" do
      {pid, _agent} = start(push_debounce_ms: 10)
      report(pid, [{@a, %{1 => true, 2 => 1, 11 => <<120::16, 100, 40>>}, now()}])

      assert [%{device_id: 5, brightness: 0.4, color_brightness: 1.0}] = of(pushes(), 5)

      assert %{brightness: 0.4, color_brightness: 1.0, peak: 1.0} =
               :sys.get_state(pid).views[{:bulb, @a}].dps
    end

    test "no push for unknown on/off, a stale sub-device, or an unchanged state" do
      {pid, _agent} = start(push_debounce_ms: 10)

      report(pid, [{@a, %{3 => 500}, now()}, {"FFFFFFFFFFFF", @on_white, now()}])
      assert pushes() == []

      report(pid, [{@a, @on_white, now()}])
      assert [_] = of(pushes(), 5)
      report(pid, [{@a, @on_white, now() + 5}])
      assert pushes() == []
    end

    test "a burst of reports is one push per light" do
      {pid, _agent} = start(push_debounce_ms: 100)
      at = now()

      for {dps, i} <- Enum.with_index([@off, @on_white, %{@on_white | 3 => 300}]) do
        send(pid, {:tuya_mesh_status, status([{@a, dps, at + i}])})
      end

      flushed(pid)

      assert [%{device_id: 5, state: true, brightness: 0.3}] = of(pushes(), 5)
    end

    test "a ping after a local send never brings an old report back" do
      {pid, _agent} = start(push_debounce_ms: 10)
      at = now()
      report(pid, [{@a, @on_white, at}])

      Commander.command(cmd({:bulb, @a}, %Req{has_brightness: true, brightness: 0.5}), pid)
      idle(pid)
      flushed(pid)
      _ = pushes()

      # The ping reply moved no DP's report time: the same stamps again.
      send(pid, {:tuya_mesh_status, status([{@a, @on_white, at}])})
      flushed(pid)
      assert pushes() == []
      assert :sys.get_state(pid).views[{:bulb, @a}].dps[3] == 500
    end

    test "a group whose members change is derived again without a report" do
      {pid, _agent} = start(push_debounce_ms: 10)
      at = now()
      groups = [%{local_id: 3, members: [@b]}]

      send(pid, {:tuya_mesh_status, status([{@b, @on_white, at}, {@c, @off, at}], groups)})
      flushed(pid)
      assert %{state: true} = last_push(pushes(), 11)

      # Group 3 moves from the on bulb to the off one; nothing reports.
      send(pid, {:tuya_mesh_status, status([], [%{local_id: 3, members: [@c]}])})
      flushed(pid)
      assert %{state: false} = last_push(pushes(), 11)

      # A new group over known bulbs gets its state at once.
      send(
        pid,
        {:tuya_mesh_status,
         status([], [%{local_id: 3, members: [@c]}, %{local_id: 1, members: [@b]}])}
      )

      flushed(pid)
      assert [%{device_id: 6, state: true}] = pushes()
    end

    test "a settings change re-encodes every light, kept initial states too" do
      settings = start_supervised!({Agent, fn -> @settings end}, id: :settings)
      read_settings = fn -> Agent.get(settings, & &1) end

      {pid, _agent} =
        start(push_debounce_ms: 10, states_table: :unnamed, settings: read_settings)

      report(pid, [{@a, @on_white, now()}])
      assert %{color_temperature: 370.0} = last_push(pushes(), 5)

      Agent.update(settings, fn _ -> %{@settings | invert: true} end)
      send(pid, {:tuya_mesh_store, :settings_changed})
      flushed(pid)

      assert %{color_temperature: 154.0} = last_push(pushes(), 5)
      states = Commander.light_states(:sys.get_state(pid).states)
      assert [%{color_temperature: 154.0}] = of(states, 5)
    end

    test "a group under a new sub-device gets its state again without a report" do
      {pid, agent} = start(push_debounce_ms: 10)
      report(pid, for(mac <- [@a, @b, @c], do: {mac, @on_white, now()}))
      assert %{state: true} = last_push(pushes(), 6)

      # A new mesh keeps group 1's local id and members, not its sub-device.
      new_mesh(agent, %{{:group, 1} => 42})
      send(pid, {:tuya_mesh_store, :inventory_changed})
      flushed(pid)

      assert [%{device_id: 42, state: true}] = of(pushes(), 42)
    end

    test "an all-off group keeps its mode and colour for the next on" do
      {pid, _agent} = start(push_debounce_ms: 10, script: %{hears: [@a, @b, @c]})
      colour = %{1 => true, 2 => 1, 11 => <<120::16, 100, 100>>}
      report(pid, for(mac <- [@a, @b, @c], do: {mac, colour, now()}))
      assert %{color_mode: :COLOR_MODE_RGB} = last_push(pushes(), 6)

      off = %{colour | 1 => false}
      report(pid, for(mac <- [@a, @b, @c], do: {mac, off, now() + 1}))
      assert %{state: false, color_mode: :COLOR_MODE_RGB} = last_push(pushes(), 6)

      # On at half brightness, no mode: still the colour's v, not DP3.
      on_half = %Req{has_state: true, state: true, has_brightness: true, brightness: 0.5}
      Commander.command(cmd({:group, 1}, on_half), pid)
      assert_receive {:lights, {:group_set, 1, [on: true, colour: {120, 100, 50}], _}}, 2_000
      idle(pid)
    end

    test "a view dropped by an identity blip is rebuilt from the retained report" do
      {pid, agent} = start(push_debounce_ms: 10, states_table: :unnamed)
      at = now()
      report(pid, [{@a, @on_white, at}])
      assert [_] = of(Commander.light_states(:sys.get_state(pid).states), 5)

      # The Store briefly answers without any sub-device.
      Agent.update(agent, &%{&1 | ids: %{}})
      send(pid, {:tuya_mesh_store, :inventory_changed})
      flushed(pid)
      refute Map.has_key?(:sys.get_state(pid).views, {:bulb, @a})

      # Back; the Resolver's next status carries the same retained stamps.
      Agent.update(agent, &%{&1 | ids: @ids})
      send(pid, {:tuya_mesh_store, :inventory_changed})
      report(pid, [{@a, @on_white, at}])

      assert [%LightStateResponse{state: true}] =
               of(Commander.light_states(:sys.get_state(pid).states), 5)
    end

    test "a member's report older than a group send never wins, even before it is known" do
      {pid, _agent} = start(push_debounce_ms: 10)
      report(pid, [])
      before = now()

      Commander.command(cmd({:group, 1}, on()), pid)
      idle(pid)
      flushed(pid)
      assert %{state: true} = last_push(pushes(), 6)

      # A's off report, sent before the group's on, arrives late.
      report(pid, [{@a, @off, before - 1}])
      assert of(pushes(), 5) == []
      assert of(pushes(), 6) == []

      # A report after the send is taken.
      report(pid, [{@a, @off, now() + 1}])
      pushed = pushes()
      assert %{state: false} = last_push(pushed, 5)
      assert %{state: false} = last_push(pushed, 6)
    end

    test "a member's report older than a diverted direct send never wins, even before it is known" do
      script = %{group_set: [{:error, :busy}]}
      {pid, _agent} = start(push_debounce_ms: 10, script: script, retry_ms: 100)
      report(pid, [])
      before = now()

      Commander.command(cmd({:group, 1}, on()), pid)
      assert_receive {:lights, {:group_set, 1, [on: true], _}}, 2_000
      Commander.command(cmd({:bulb, @b}, %Req{has_state: true, state: false}, 99, 7), pid)
      idle(pid)
      flushed(pid)
      assert {@a, [on: true]} in sets()
      _ = pushes()

      # A's off report, sent before the diverted on, arrives late.
      report(pid, [{@a, @off, before - 1}])
      assert of(pushes(), 5) == []
      refute Map.has_key?(:sys.get_state(pid).views[{:bulb, @a}].dps, 1)

      report(pid, [{@a, @off, now() + 1}])
      assert %{state: false} = last_push(pushes(), 5)
    end

    test "a view rebuilt by a group send after an identity blip takes the retained report" do
      {pid, agent} = start(push_debounce_ms: 10)
      at = now()
      report(pid, [{@a, @on_white, at}])

      Agent.update(agent, &%{&1 | ids: %{}})
      send(pid, {:tuya_mesh_store, :inventory_changed})
      flushed(pid)
      refute Map.has_key?(:sys.get_state(pid).views, {:bulb, @a})

      # Back, and a group send stamps A before the Resolver's next status.
      Agent.update(agent, &%{&1 | ids: @ids})
      send(pid, {:tuya_mesh_store, :inventory_changed})
      Commander.command(cmd({:group, 1}, on()), pid)
      idle(pid)
      assert :sys.get_state(pid).views[{:bulb, @a}].dps == %{}

      # The same retained stamps: every DP the send didn't touch is taken.
      report(pid, [{@a, @on_white, at}])
      assert %{2 => 0, 3 => 1000, 4 => 0} = :sys.get_state(pid).views[{:bulb, @a}].dps
    end

    test "what was pushed is kept for new connections" do
      {pid, _agent} = start(push_debounce_ms: 10, states_table: :unnamed)
      report(pid, [{@a, @on_white, now()}])

      states = Commander.light_states(:sys.get_state(pid).states)
      assert [%LightStateResponse{state: true}] = of(states, 5)
      # A's groups were derived from it.
      assert [%LightStateResponse{state: true}] = of(states, 6)
    end
  end

  describe "saved light states" do
    @on_white %{1 => true, 2 => 0, 3 => 1000, 4 => 0}
    @off %{1 => false, 2 => 0, 3 => 1000, 4 => 0}

    test "seed the initial states at start, groups derived from them" do
      saved = %{@a => @on_white, @b => @off, "FFFFFFFFFFFF" => @on_white}

      {pid, _agent} =
        start(push_debounce_ms: 10, states_table: :unnamed, saved_states: fn -> saved end)

      # The groups come with the first status (no bulb reported yet).
      report(pid, [])
      states = Commander.light_states(:sys.get_state(pid).states)

      assert [%{state: true, brightness: 1.0}] = of(states, 5)
      assert [%{state: false}] = of(states, 7)
      # Group 1 (A, B, C): A on; group 3 (B, C): B off, C unknown.
      assert [%{state: true}] = of(states, 6)
      assert [%{state: false}] = of(states, 11)
      # No sub-device, no state.
      assert length(states) == 4
    end

    test "a seed loses to any report Lights holds, however old its stamps" do
      {pid, _agent} =
        start(push_debounce_ms: 10, saved_states: fn -> %{@a => %{@on_white | 3 => 500}} end)

      flushed(pid)
      assert [%{state: true, brightness: 0.5}] = of(pushes(), 5)

      # Only DP1 reported, stamped long before the seed was read: taken,
      # the seeded brightness kept.
      report(pid, [{@a, %{1 => false}, -1_000_000}])
      assert [%{state: false, brightness: 0.5}] = of(pushes(), 5)
    end

    test "a seed loses to a command, which starts from it" do
      {pid, _agent} = start(push_debounce_ms: 10, saved_states: fn -> %{@a => @off} end)
      flushed(pid)
      assert [%{state: false}] = of(pushes(), 5)

      Commander.command(cmd({:bulb, @a}, on()), pid)
      # Known from the seed: only DP1 goes, and Lights isn't asked.
      assert_receive {:lights, {:set, @a, [on: true], _}}, 2_000
      refute_received {:lights, {:status, @a}}
      idle(pid)
      assert %{state: true, brightness: 1.0} = last_push(pushes(), 5)
    end

    test "every pushed bulb state is saved, its state DPs only; groups aren't" do
      test = self()

      {pid, _agent} =
        start(push_debounce_ms: 10, save_state: &send(test, {:saved, &1, &2}))

      report(pid, [{@a, Map.put(@on_white, 21, 3), now()}])
      assert last_push(pushes(), 6)

      assert_received {:saved, @a, %{1 => true, 2 => 0, 3 => 1000, 4 => 0} = saved}
      refute Map.has_key?(saved, 21)
      refute_received {:saved, _, _}

      # An unchanged state isn't pushed, so not saved again.
      report(pid, [{@a, @on_white, now() + 1}])
      refute_received {:saved, _, _}
    end

    test "a state DP change the response doesn't show is saved too" do
      test = self()

      {pid, _agent} =
        start(push_debounce_ms: 10, save_state: &send(test, {:saved, &1, &2}))

      white = Map.put(@on_white, 11, <<120::16, 100, 100>>)
      report(pid, [{@a, white, now()}])
      assert [_] = of(pushes(), 5)
      assert_received {:saved, @a, %{11 => <<120::16, 100, 100>>}}

      # A new colour while white: the same response, a new state.
      report(pid, [{@a, %{11 => <<240::16, 100, 100>>}, now() + 1}])
      assert of(pushes(), 5) == []
      assert_received {:saved, @a, %{2 => 0, 11 => <<240::16, 100, 100>>}}
    end

    test "a subscription that comes late seeds what the Store kept meanwhile" do
      pubsub = :"commander_seed_pubsub_#{System.unique_integer([:positive])}"
      saved = start_supervised!({Agent, fn -> %{} end}, id: :saved)

      {pid, _agent} =
        start(
          push_debounce_ms: 10,
          subscribe: true,
          pubsub: pubsub,
          resubscribe_ms: 20,
          status: fn -> status([]) end,
          saved_states: fn -> Agent.get(saved, & &1) end
        )

      # Started, nothing seeded; the Store comes up (its :ready unheard)
      # while PubSub is down.
      _ = :sys.get_state(pid)
      Agent.update(saved, fn _ -> %{@b => @off} end)
      refute_receive {:push, _}, 50
      start_supervised!({Phoenix.PubSub, name: pubsub}, id: :seed_pubsub)

      assert_receive {:push, %LightStateResponse{device_id: 7, state: false}}, 2_000
      assert Registry.keys(pubsub, pid) != []
    end

    test "a restarted Store gets every known bulb again, changed or not" do
      test = self()

      {pid, _agent} =
        start(push_debounce_ms: 10, save_state: &send(test, {:saved, &1, &2}))

      report(pid, [{@a, @on_white, now()}, {@b, %{3 => 500}, now()}])
      assert_received {:saved, @a, %{1 => true}}
      refute_received {:saved, _, _}

      # It may have lost a held change in a crash: A goes again, and B,
      # whose on/off is unknown, doesn't. Nothing is pushed to HA.
      _ = pushes()
      send(pid, {:tuya_mesh_store, :ready})
      flushed(pid)
      assert_received {:saved, @a, %{1 => true, 3 => 1000}}
      refute_received {:saved, _, _}
      assert pushes() == []
    end

    test "after an inventory change, the next unchanged state is saved again" do
      test = self()

      {pid, _agent} =
        start(push_debounce_ms: 10, save_state: &send(test, {:saved, &1, &2}))

      report(pid, [{@a, @on_white, now()}])
      assert_received {:saved, @a, _}

      # The Store may have dropped it: nothing is restored eagerly...
      send(pid, {:tuya_mesh_store, :inventory_changed})
      flushed(pid)
      refute_received {:saved, _, _}

      # ...but the next report, the same state, is saved.
      report(pid, [{@a, @on_white, now() + 1}])
      assert_received {:saved, @a, %{1 => true}}
    end

    test "a Store that starts late seeds the bulbs still unknown" do
      saved = start_supervised!({Agent, fn -> %{} end}, id: :saved)

      {pid, _agent} =
        start(push_debounce_ms: 10, saved_states: fn -> Agent.get(saved, & &1) end)

      at = now()
      report(pid, [{@a, @on_white, at}])
      assert [%{state: true}] = of(pushes(), 5)

      Agent.update(saved, fn _ -> %{@a => @off, @b => @off} end)
      send(pid, {:tuya_mesh_store, :ready})
      flushed(pid)

      # A has a view already; B is seeded.
      pushed = pushes()
      assert of(pushed, 5) == []
      assert [%{state: false}] = of(pushed, 7)
    end
  end

  describe "subscriptions" do
    test "a PubSub down at start is retried, then a fresh status is read" do
      pubsub = :"commander_late_pubsub_#{System.unique_integer([:positive])}"
      test = self()

      {pid, _agent} =
        start(
          subscribe: true,
          pubsub: pubsub,
          resubscribe_ms: 20,
          status: fn ->
            send(test, :status_read)
            status([])
          end
        )

      refute_received :status_read
      start_supervised!({Phoenix.PubSub, name: pubsub}, id: :late_pubsub)

      assert_receive :status_read, 2_000
      _ = :sys.get_state(pid)

      topics = Registry.keys(pubsub, pid) |> Enum.sort()

      assert topics ==
               Enum.sort([UniversalProxy.TuyaMesh.Store.topic(), UniversalProxy.TuyaMesh.topic()])

      # Retries stop once subscribed: never held twice.
      Process.sleep(60)
      assert Registry.keys(pubsub, pid) |> Enum.sort() == topics
    end
  end

  describe "group" do
    test "members that didn't confirm get direct follow-ups; confirmers don't" do
      {pid, _agent} = start(script: %{hears: [@a]})

      Commander.command(cmd({:group, 1}, warm_full_on(), 88), pid)

      assert_receive {:lights, {:group_set, 1, [on: true, mode: :white, temp: 0], [ack: true]}},
                     2_000

      assert_receive {:lights, {:group_set, 1, [brightness: 1000], [ack: true]}}, 2_000
      assert_receive {:push, %LightStateResponse{device_id: 6, state: true}}, 2_000

      idle(pid)
      followups = sets()

      for mac <- [@b, @c] do
        assert {mac, [on: true, mode: :white, temp: 0]} in followups
        assert {mac, [brightness: 1000]} in followups
      end

      refute Enum.any?(followups, &match?({@a, _}, &1))
      assert length(followups) == 4
    end

    test "a member that reported only part gets only what it is missing" do
      # B heard the first frame only (its report for the second is missing).
      {pid, agent} = start(script: %{hears: [@a, @b]})

      Commander.command(cmd({:group, 1}, warm_full_on()), pid)
      assert_receive {:lights, {:group_set, 1, [brightness: 1000], _}}, 2_000

      Agent.update(agent, fn s ->
        put_in(s, [:bulbs, @b, :dps], Map.delete(s.bulbs[@b].dps, 3))
      end)

      idle(pid)
      followups = sets()
      assert {@b, [brightness: 1000]} in followups
      refute {@b, [on: true, mode: :white, temp: 0]} in followups
      refute Enum.any?(followups, &match?({@a, _}, &1))
    end

    test "follow-ups are capped per command" do
      {pid, _agent} = start(max_followups: 1)
      Commander.command(cmd({:group, 1}, on()), pid)
      idle(pid)
      assert [{_mac, [on: true]}] = sets()
    end

    test "busy follow-ups wait for capacity, then every bulb gets its own" do
      script = %{set: %{@a => List.duplicate({:error, :busy}, 8)}}
      {pid, _agent} = start(script: script)

      Commander.command(cmd({:group, 1}, on()), pid)
      idle(pid)

      followups = sets()
      assert Enum.count(followups, &match?({@a, _}, &1)) == 9
      assert {@b, [on: true]} in followups
      assert {@c, [on: true]} in followups
    end

    test "follow-ups don't starve a new command for another light" do
      {pid, _agent} = start(followup_gap_ms: 1_000)

      Commander.command(cmd({:group, 1}, on()), pid)
      assert_receive {:lights, {:set, first, [on: true], _}}, 1_000

      Commander.command(cmd({:bulb, @d}, on()), pid)
      idle(pid)

      [next | rest] = sets()
      assert next == {@d, [on: true]}
      assert length(rest) == 2
      refute {first, [on: true]} in rest
    end

    test "follow-ups of two groups share one pacing, and a user command goes first" do
      gap = 300
      {pid, _agent} = start(followup_gap_ms: gap)

      # Nobody hears either broadcast: group 1 (A, B, C) and group 5 (D)
      # both run a follow-up pass at once.
      Commander.command(cmd({:group, 1}, on()), pid)
      Commander.command(cmd({:group, 5}, on()), pid)
      assert_receive {:lights, {:set, _first, [on: true], _}}, 2_000

      Commander.command(cmd({:bulb, @e}, on()), pid)
      idle(pid)

      sent = set_times()
      followups = Enum.reject(sent, &match?({@e, _}, &1))
      assert length(followups) == 4

      for [{_m1, t1}, {_m2, t2}] <- Enum.chunk_every(followups, 2, 1, :discard),
          do: assert(t2 - t1 >= gap)

      # The user command went before the second follow-up.
      assert [{_first, _}, {@e, _} | _] = sent
    end

    test "a confirmation pass during a capacity hold only plans" do
      script = %{set: %{@e => [{:error, :queue_full}, :ok]}}
      {pid, _agent} = start(script: script, retry_ms: 300, max_retry_ms: 300)

      Commander.command(cmd({:group, 1}, on()), pid)
      Commander.command(cmd({:bulb, @e}, on()), pid)
      idle(pid)

      # The refused user frame, then (after the hold) that frame again,
      # and only then the follow-ups the check planned during the hold.
      assert [{@e, _}, {@e, _} | followups] = sets()
      assert length(followups) == 3
    end

    test "a newer command arriving during a failed send is admitted before the next old frame" do
      # A's follow-up fails; while that call runs, B is turned off.
      off = cmd({:bulb, @b}, %Req{has_state: true, state: false})

      on_set = fn
        @a, %{commander: commander} = s ->
          Commander.command(off, commander)
          s

        _mac, s ->
          s
      end

      {pid, agent} = start(script: %{set: %{@a => [{:error, :not_ready}]}, on_set: on_set})
      Agent.update(agent, &Map.put(&1, :commander, pid))

      Commander.command(cmd({:group, 1}, on()), pid)
      idle(pid)

      followups = sets()
      assert {@b, [on: false]} in followups
      refute {@b, [on: true]} in followups
      assert {@c, [on: true]} in followups
    end

    test "an expiring command whose light was replaced is abandoned, not pushed" do
      script = %{group_set: [:ok, {:error, :busy}]}

      {pid, agent} =
        start(script: script, retry_ms: 10_000, max_retry_ms: 10_000, stale_ms: 200)

      # The first frame is accepted, the second held past the bound.
      Commander.command(cmd({:group, 1}, warm_full_on()), pid)
      assert_receive {:lights, {:group_set, 1, [brightness: 1000], _}}, 2_000
      assert Map.has_key?(:sys.get_state(pid).views, {:group, 1})

      # The mesh is replaced and no Store broadcast reaches us.
      new_mesh(agent, %{{:group, 1} => 42})
      idle(pid)

      refute_received {:push, _}
      refute Map.has_key?(:sys.get_state(pid).views, {:group, 1})
    end

    test "follow-ups wait for the Radio's queue to drain; user commands don't" do
      {pid, agent} = start()
      Agent.update(agent, &Map.put(&1, :radio_queued, 2))

      Commander.command(cmd({:group, 1}, on()), pid)
      assert_receive {:lights, {:group_set, 1, [on: true], _}}, 2_000

      # Past the window, the follow-ups are planned but held.
      Process.sleep(150)
      assert sets() == []

      # A Radio that doesn't answer holds them too.
      Agent.update(agent, &Map.put(&1, :radio_queued, :down))
      Process.sleep(50)
      assert sets() == []

      # A new user command goes regardless.
      Commander.command(cmd({:bulb, @e}, on()), pid)
      assert_receive {:lights, {:set, @e, [on: true], _}}, 2_000
      assert sets() == []

      # Drained: the follow-ups resume.
      Agent.update(agent, &Map.put(&1, :radio_queued, 0))
      idle(pid)
      assert length(sets()) == 3
    end

    test "a burst of group on/off/on ends in the last state" do
      {pid, agent} = start(script: %{hears: [@a, @b, @c]}, max_retry_ms: 20)
      Agent.update(agent, &Map.put(&1, :refuse_until, now() + 300))

      Commander.command(cmd({:group, 1}, on()), pid)
      Commander.command(cmd({:group, 1}, %Req{has_state: true, state: false}), pid)
      Commander.command(cmd({:group, 1}, on()), pid)
      idle(pid)

      assert last_group_set() == [on: true]
      assert :sys.get_state(pid).views[{:group, 1}].dps[1] == true
      assert sets() == []
    end

    test "a newer bulb command keeps the group's follow-up off that bulb" do
      {pid, _agent} = start(window_ms: 100)

      Commander.command(cmd({:group, 1}, on()), pid)
      Commander.command(cmd({:bulb, @b}, %Req{has_state: true, state: false}, 99, 7), pid)
      idle(pid)

      followups = sets()
      assert {@b, [on: false]} in followups
      refute {@b, [on: true]} in followups
      assert {@a, [on: true]} in followups
      assert {@c, [on: true]} in followups
    end

    test "a newer group command supersedes the older one's follow-ups" do
      {pid, _agent} = start(window_ms: 50)

      Commander.command(cmd({:group, 1}, on()), pid)
      Commander.command(cmd({:group, 1}, %Req{has_state: true, state: false}), pid)
      idle(pid)

      followups = sets()
      assert length(followups) == 3
      assert Enum.all?(followups, &match?({_mac, [on: false]}, &1))
    end

    test "a group command replaces its members' pending bulb commands" do
      script = %{set: %{@a => [{:error, :busy}]}, hears: [@a, @b, @c]}
      {pid, _agent} = start(script: script, retry_ms: 200)

      Commander.command(cmd({:bulb, @a}, on()), pid)
      assert_receive {:lights, {:set, @a, [on: true], _}}, 2_000

      Commander.command(cmd({:group, 1}, %Req{has_state: true, state: false}), pid)
      idle(pid)

      assert sets() == []
    end

    test "a busy group retry never turns back on a member a newer command turned off" do
      {pid, _agent} = start(script: %{group_set: [{:error, :busy}]}, retry_ms: 100)

      Commander.command(cmd({:group, 1}, on()), pid)
      assert_receive {:lights, {:group_set, 1, [on: true], _}}, 2_000

      Commander.command(cmd({:bulb, @b}, %Req{has_state: true, state: false}, 99, 7), pid)
      idle(pid)

      # The retry went direct to the other members, not as a broadcast.
      refute_received {:lights, {:group_set, 1, _, _}}
      followups = sets()
      assert {@b, [on: false]} in followups
      refute {@b, [on: true]} in followups
      assert {@a, [on: true]} in followups
      assert {@c, [on: true]} in followups
    end

    test "overlapping groups: the latest command wins per bulb" do
      {pid, _agent} = start(script: %{group_set: [{:error, :busy}]}, retry_ms: 100)

      # Group 1 is A, B, C; group 3 is B, C.
      Commander.command(cmd({:group, 1}, on()), pid)
      assert_receive {:lights, {:group_set, 1, [on: true], _}}, 2_000

      Commander.command(cmd({:group, 3}, %Req{has_state: true, state: false}), pid)
      idle(pid)

      assert_received {:lights, {:group_set, 3, [on: false], _}}
      refute_received {:lights, {:group_set, 1, _, _}}

      followups = sets()
      assert {@a, [on: true]} in followups
      for mac <- [@b, @c], do: refute({mac, [on: true]} in followups)
      for mac <- [@b, @c], do: assert({mac, [on: false]} in followups)
    end

    test "a group superseded on every member sends nothing more" do
      {pid, _agent} = start(script: %{group_set: [{:error, :busy}]}, retry_ms: 100)

      Commander.command(cmd({:group, 3}, on()), pid)
      assert_receive {:lights, {:group_set, 3, [on: true], _}}, 2_000

      Commander.command(cmd({:group, 1}, %Req{has_state: true, state: false}), pid)
      idle(pid)

      refute_received {:lights, {:group_set, 3, _, _}}
      refute Enum.any?(sets(), &match?({_mac, [on: true]}, &1))
    end

    test "a follow-up that fails drops that bulb's later frames" do
      script = %{set: %{@a => [{:error, :not_ready}]}}
      {pid, _agent} = start(script: script)

      Commander.command(cmd({:group, 1}, warm_full_on()), pid)
      idle(pid)

      followups = sets()

      assert [{@a, [on: true, mode: :white, temp: 0]}] =
               Enum.filter(followups, &match?({@a, _}, &1))

      for mac <- [@b, @c], do: assert({mac, [brightness: 1000]} in followups)
    end

    test "follow-ups that can't go out within their bound are dropped" do
      script = %{set: %{@a => List.duplicate({:error, :busy}, 1_000)}}
      {pid, _agent} = start(script: script, stale_ms: 100)

      Commander.command(cmd({:group, 1}, warm_full_on()), pid)
      idle(pid)

      followups = sets()
      assert Enum.all?(followups, &match?({@a, [on: true, mode: :white, temp: 0]}, &1))
      assert length(followups) > 1
    end

    test "a cached DP that already matched isn't confirmed by a partial report" do
      # A's stale cache already shows brightness 1000; it hears only the
      # first frame, so its report carries on, mode and temp.
      hears = fn
        [{:on, _} | _] -> [@a]
        _other -> []
      end

      script = %{hears: hears, bulbs: %{@a => %{dps: %{3 => 1000}, last_report_ms: 0}}}
      {pid, _agent} = start(script: script)

      Commander.command(cmd({:group, 1}, warm_full_on()), pid)
      idle(pid)

      followups = sets()
      assert {@a, [brightness: 1000]} in followups
      refute {@a, [on: true, mode: :white, temp: 0]} in followups
    end

    test "every diverted send failing pushes nothing and keeps the cache" do
      script = %{
        group_set: [{:error, :busy}],
        set: %{@a => [{:error, :not_ready}], @c => [{:error, :not_ready}]}
      }

      {pid, _agent} = start(script: script, retry_ms: 100)

      Commander.command(cmd({:group, 1}, on()), pid)
      assert_receive {:lights, {:group_set, 1, [on: true], _}}, 2_000
      Commander.command(cmd({:bulb, @b}, %Req{has_state: true, state: false}), pid)
      idle(pid)

      assert {@a, [on: true]} in sets()
      assert_received {:push, %LightStateResponse{device_id: 7, state: false}}
      refute_received {:push, _}
      assert Map.keys(:sys.get_state(pid).views) == [{:bulb, @b}]
    end

    test "a diversion plans every member's first frame before any second one" do
      {pid, _agent} =
        start(script: %{group_set: [{:error, :busy}]}, retry_ms: 100, max_followups: 3)

      Commander.command(cmd({:group, 1}, warm_full_on()), pid)
      assert_receive {:lights, {:group_set, 1, _, _}}, 2_000
      Commander.command(cmd({:bulb, @b}, %Req{has_state: true, state: false}), pid)
      idle(pid)

      # The group's command is the older one: its diverted frames go first.
      assert sets() == [
               {@a, [on: true, mode: :white, temp: 0]},
               {@c, [on: true, mode: :white, temp: 0]},
               {@a, [brightness: 1000]},
               {@b, [on: false]}
             ]
    end

    test "the direct-frame budget is shared by the diversion and the confirmation pass" do
      script = %{group_set: [:ok, {:error, :busy}]}
      {pid, _agent} = start(script: script, retry_ms: 100, max_followups: 3)

      # The first frame goes out as a broadcast nobody hears; the second
      # is diverted once B has a newer command.
      Commander.command(cmd({:group, 1}, warm_full_on()), pid)
      assert_receive {:lights, {:group_set, 1, [brightness: 1000], _}}, 2_000
      Commander.command(cmd({:bulb, @b}, %Req{has_state: true, state: false}), pid)
      idle(pid)

      direct = Enum.reject(sets(), &match?({@b, _}, &1))

      assert direct == [
               {@a, [brightness: 1000]},
               {@c, [brightness: 1000]},
               {@a, [on: true, mode: :white, temp: 0]}
             ]
    end

    test "a pending group retry across a new-mesh upload sends nothing" do
      {pid, agent} = start(script: %{group_set: [{:error, :busy}]}, retry_ms: 50)

      Commander.command(cmd({:group, 1}, on()), pid)
      assert_receive {:lights, {:group_set, 1, [on: true], _}}, 2_000

      # The new mesh reuses local id 1 for another group: a new sub-device.
      new_mesh(agent, %{{:group, 1} => 42})
      idle(pid)

      refute_received {:lights, {:group_set, _, _, _}}
      assert sets() == []
      refute_received {:push, _}
    end

    test "a stale group command never touches its members' pending work" do
      script = %{set: %{@b => [{:error, :busy}]}}
      {pid, agent} = start(script: script, retry_ms: 60_000)

      Commander.command(cmd({:bulb, @b}, on()), pid)
      assert_receive {:lights, {:set, @b, [on: true], _}}, 2_000
      before = :sys.get_state(pid)

      # The Store moved group 1 to a new sub-device; the provider hasn't
      # caught up and still sends the old one.
      new_mesh(agent, %{{:group, 1} => 42})
      Commander.command(cmd({:group, 1}, %Req{has_state: true, state: false}), pid)

      after_cmd = :sys.get_state(pid)
      assert after_cmd.jobs == before.jobs
      assert after_cmd.touched == before.touched
      assert after_cmd.views == before.views
      refute_received {:lights, {:group_set, _, _, _}}
    end

    test "a mesh change during the confirmation read sends no direct frame" do
      # Read 1 is the snapshot at the command, read 2 the confirmation pass.
      on_all = fn
        %{all_reads: 2} = s -> %{s | ids: Map.put(s.ids, {:group, 1}, 42)}
        s -> s
      end

      {pid, _agent} = start(script: %{on_all: on_all})

      Commander.command(cmd({:group, 1}, on()), pid)
      assert_receive {:lights, {:group_set, 1, [on: true], _}}, 2_000
      idle(pid)

      assert sets() == []
      refute Map.has_key?(:sys.get_state(pid).views, {:group, 1})
    end

    test "a kept view of another sub-device is never used" do
      {pid, agent} = start(script: %{hears: [@a, @b, @c]})

      red = %Req{has_state: true, state: true, has_rgb: true, red: 1.0, green: 0.0, blue: 0.0}
      Commander.command(cmd({:group, 1}, red), pid)
      idle(pid)
      assert_receive {:lights, {:group_set, 1, [on: true, mode: :colour, colour: _], _}}, 2_000

      # The mesh was replaced with no Store broadcast reaching us.
      new_mesh(agent, %{{:group, 1} => 42})
      half = %Req{has_brightness: true, brightness: 0.5}
      Commander.command(cmd({:group, 1}, half, 77, 42), pid)
      idle(pid)

      assert_received {:lights, {:group_set, 1, [brightness: 500], _}}
      assert %{device_id: 42, dps: dps} = :sys.get_state(pid).views[{:group, 1}]
      refute Map.has_key?(dps, 11)
      refute_received {:push, %LightStateResponse{device_id: 42}}
    end

    test "a Store change drops stale commands and the kept DPs of changed lights" do
      {pid, agent} = start(script: %{group_set: [:ok, {:error, :busy}]}, retry_ms: 60_000)

      Commander.command(cmd({:bulb, @a}, on()), pid)
      Commander.command(cmd({:group, 3}, on()), pid)
      idle(pid)
      Commander.command(cmd({:group, 1}, on()), pid)
      assert_receive {:lights, {:group_set, 1, [on: true], _}}, 2_000

      assert %{{:bulb, @a} => _, {:group, 3} => _} = :sys.get_state(pid).views
      assert Map.has_key?(:sys.get_state(pid).jobs, {:group, 1})

      new_mesh(agent, %{{:group, 1} => 42, {:group, 3} => 43})
      send(pid, {:tuya_mesh_store, :inventory_changed})
      state = :sys.get_state(pid)

      assert state.jobs == %{}
      assert Map.has_key?(state.views, {:bulb, @a})
      refute Map.has_key?(state.views, {:group, 3})
    end

    test "it follows the Store's broadcasts" do
      pubsub = :"commander_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub})

      {pid, agent} =
        start(
          script: %{group_set: [{:error, :busy}]},
          retry_ms: 60_000,
          pubsub: pubsub,
          subscribe: true
        )

      Commander.command(cmd({:group, 1}, on()), pid)
      assert_receive {:lights, {:group_set, 1, [on: true], _}}, 2_000

      new_mesh(agent, %{{:group, 1} => 42})

      Phoenix.PubSub.broadcast(
        pubsub,
        UniversalProxy.TuyaMesh.Store.topic(),
        {:tuya_mesh_store, :inventory_changed}
      )

      assert :sys.get_state(pid).jobs == %{}
    end

    test "unknown members means no follow-ups" do
      {pid, _agent} = start()
      Commander.command(cmd({:group, 2}, on()), pid)
      assert_receive {:lights, {:group_set, 2, [on: true], _}}, 2_000
      idle(pid)
      assert sets() == []
      assert :sys.get_state(pid).jobs == %{}
    end
  end

  describe "membership changes" do
    # A joins group 3.
    @joined [%{local_id: 1, members: [@a, @b, @c]}, %{local_id: 3, members: [@b, @c, @a]}]

    test "a bulb that joins after a broadcast aired gets nothing from it" do
      {pid, _agent} = start(script: %{hears: [@b, @c]}, window_ms: 200)
      send(pid, {:tuya_mesh_status, status([])})

      Commander.command(cmd({:group, 3}, on()), pid)
      assert_receive {:lights, {:group_set, 3, [on: true], _}}, 2_000

      send(pid, {:tuya_mesh_status, status([], @joined)})
      idle(pid)

      assert sets() == []
    end

    test "a joiner takes a broadcast that airs after it joined, with no direct frame" do
      {pid, agent} = start(script: %{hears: [@b, @c]})
      send(pid, {:tuya_mesh_status, status([])})

      Agent.update(agent, &Map.put(&1, :refuse_until, now() + 200))
      Commander.command(cmd({:group, 3}, on()), pid)
      assert_receive {:lights, :refused}, 2_000

      send(pid, {:tuya_mesh_status, status([], @joined)})
      idle(pid)

      assert_received {:lights, {:group_set, 3, [on: true], _}}
      assert sets() == []
      assert %{sent_at: %{1 => _}} = :sys.get_state(pid).views[{:bulb, @a}]
    end

    test "a joiner with a newer command of its own keeps a pending broadcast off the air" do
      {pid, agent} = start()
      send(pid, {:tuya_mesh_status, status([])})

      Agent.update(agent, &Map.put(&1, :refuse_until, now() + 200))
      Commander.command(cmd({:group, 3}, on()), pid)
      Commander.command(cmd({:bulb, @a}, %Req{has_state: true, state: false}, 99), pid)
      assert_receive {:lights, :refused}, 2_000

      send(pid, {:tuya_mesh_status, status([], @joined)})
      idle(pid)

      # Group 3 goes to its other members directly; A only gets its own.
      refute_received {:lights, {:group_set, _, _, _}}
      followups = sets()
      assert {@a, [on: false]} in followups
      refute {@a, [on: true]} in followups
      assert {@b, [on: true]} in followups
      assert {@c, [on: true]} in followups
    end

    test "a broadcast a joiner took is never overridden by an older group's follow-up" do
      hears = fn
        [on: true] -> []
        _off -> [@a, @b, @c]
      end

      {pid, agent} = start(script: %{hears: hears}, window_ms: 300)
      send(pid, {:tuya_mesh_status, status([])})

      Commander.command(cmd({:group, 1}, on()), pid)
      assert_receive {:lights, {:group_set, 1, [on: true], _}}, 2_000

      # Group 3's newer "off" waits for capacity while A joins it.
      Agent.update(agent, &Map.put(&1, :refuse_until, now() + 100))
      Commander.command(cmd({:group, 3}, %Req{has_state: true, state: false}), pid)
      assert_receive {:lights, :refused}, 2_000
      send(pid, {:tuya_mesh_status, status([], @joined)})
      idle(pid)

      assert_received {:lights, {:group_set, 3, [on: false], _}}
      assert sets() == []
    end

    test "admission takes the membership the statuses reported, in order" do
      {pid, _agent} = start()
      send(pid, {:tuya_mesh_status, status([])})
      send(pid, {:tuya_mesh_status, status([], [%{local_id: 1, members: [@a, @b]}])})

      # `:members` would say A, B and C: the statuses, already applied, win.
      Commander.command(cmd({:group, 1}, on()), pid)
      assert_receive {:lights, {:group_set, 1, [on: true], _}}, 2_000
      assert %{members: [@a, @b]} = :sys.get_state(pid).jobs[{:group, 1}]

      send(pid, {:tuya_mesh_status, status([])})
      idle(pid)

      assert sets() == [{@a, [on: true]}, {@b, [on: true]}]
    end

    test "a command admitted before any status keeps its members through queued changes" do
      {pid, _agent} = start(window_ms: 100)

      # Admitted through `:members`, which already read the latest
      # membership; older statuses (C removed, then back) come after.
      Commander.command(cmd({:group, 1}, on()), pid)
      send(pid, {:tuya_mesh_status, status([])})
      send(pid, {:tuya_mesh_status, status([], [%{local_id: 1, members: [@a, @b]}])})
      send(pid, {:tuya_mesh_status, status([])})
      idle(pid)

      assert sets() == [{@a, [on: true]}, {@b, [on: true]}, {@c, [on: true]}]
    end

    test "a bulb that leaves mid-diversion still gets what it took pushed" do
      script = %{set: %{@b => [{:error, :busy}]}}
      {pid, _agent} = start(script: script, retry_ms: 300, push_debounce_ms: 10)
      at = now()
      report(pid, for(mac <- [@a, @b, @c], do: {mac, @off, at}))
      _ = pushes()

      # C's newer command diverts group 1 to A and B; B waits for capacity.
      Commander.command(cmd({:group, 1}, on()), pid)
      Commander.command(cmd({:bulb, @c}, %Req{has_state: true, state: false}, 99), pid)
      assert_receive {:lights, {:set, @a, [on: true], _}}, 2_000

      send(pid, {:tuya_mesh_status, status([], [%{local_id: 1, members: [@b, @c]}])})
      flushed(pid)
      assert %{state: true} = last_push(pushes(), 5)
      idle(pid)
    end

    test "a group deleted mid-diversion still gets its members' taken sends pushed" do
      script = %{set: %{@b => [{:error, :busy}]}}
      {pid, _agent} = start(script: script, retry_ms: 300, push_debounce_ms: 10)
      at = now()
      report(pid, for(mac <- [@a, @b, @c], do: {mac, @off, at}))
      _ = pushes()

      Commander.command(cmd({:group, 1}, on()), pid)
      Commander.command(cmd({:bulb, @c}, %Req{has_state: true, state: false}, 99), pid)
      assert_receive {:lights, {:set, @a, [on: true], _}}, 2_000

      send(pid, {:tuya_mesh_status, status([], [%{local_id: 3, members: [@b, @c]}])})
      flushed(pid)
      assert %{state: true} = last_push(pushes(), 5)
      refute Map.has_key?(:sys.get_state(pid).jobs, {:group, 1})
      idle(pid)
    end

    test "a group the Store drops mid-diversion still gets its members' taken sends pushed" do
      script = %{set: %{@b => [{:error, :busy}]}}
      {pid, agent} = start(script: script, retry_ms: 300, push_debounce_ms: 10)
      at = now()
      report(pid, for(mac <- [@a, @b, @c], do: {mac, @off, at}))
      _ = pushes()

      Commander.command(cmd({:group, 1}, on()), pid)
      Commander.command(cmd({:bulb, @c}, %Req{has_state: true, state: false}, 99), pid)
      assert_receive {:lights, {:set, @a, [on: true], _}}, 2_000

      # The Store's change arrives before the Resolver's status.
      Agent.update(agent, fn s -> %{s | ids: Map.delete(s.ids, {:group, 1})} end)
      send(pid, {:tuya_mesh_store, :inventory_changed})
      flushed(pid)
      assert %{state: true} = last_push(pushes(), 5)
      refute Map.has_key?(:sys.get_state(pid).jobs, {:group, 1})

      send(pid, {:tuya_mesh_status, status([], [%{local_id: 3, members: [@b, @c]}])})
      idle(pid)
    end

    test "statuses during pending work never postpone the Presence keepalive" do
      {pid, _agent} = start(window_ms: 2_000, keepalive_ms: 100, activity_hold_ms: 250)
      send(pid, {:tuya_mesh_status, status([])})

      Commander.command(cmd({:group, 1}, on()), pid)
      assert_receive {:lights, {:group_set, 1, [on: true], _}}, 2_000
      flush_activity()

      # A status every 20 ms for 600 ms, while the group waits to confirm.
      for _ <- 1..30 do
        send(pid, {:tuya_mesh_status, status([])})
        Process.sleep(20)
      end

      assert flush_activity() >= 4
    end

    test "a bulb that leaves gets none of the command's remaining follow-ups" do
      {pid, _agent} = start(followup_gap_ms: 200)
      send(pid, {:tuya_mesh_status, status([])})

      Commander.command(cmd({:group, 1}, on()), pid)
      assert_receive {:lights, {:set, @a, [on: true], _}}, 2_000

      send(pid, {:tuya_mesh_status, status([], [%{local_id: 1, members: [@a, @b]}])})
      assert %{members: [@a, @b], pending: pending} = :sys.get_state(pid).jobs[{:group, 1}]
      refute Enum.any?(pending, &match?({@c, _}, &1))
      idle(pid)

      assert sets() == [{@b, [on: true]}]
    end

    test "a deleted group's pending command is dropped with its state" do
      {pid, _agent} = start(window_ms: 200, push_debounce_ms: 10)
      send(pid, {:tuya_mesh_status, status([])})

      Commander.command(cmd({:group, 1}, on()), pid)
      assert_receive {:lights, {:group_set, 1, [on: true], _}}, 2_000
      assert_receive {:push, %LightStateResponse{device_id: 6, state: true}}, 2_000
      assert Map.has_key?(:sys.get_state(pid).pushed, {:group, 1})

      send(pid, {:tuya_mesh_status, status([], [%{local_id: 3, members: [@b, @c]}])})
      state = :sys.get_state(pid)
      assert state.jobs == %{}
      refute Map.has_key?(state.views, {:group, 1})
      refute Map.has_key?(state.pushed, {:group, 1})

      Process.sleep(300)
      assert sets() == []
    end

    test "the group is derived from its new members, and a pending send skips the old ones" do
      {pid, agent} = start(script: %{hears: [@b, @c]}, push_debounce_ms: 10)
      at = now()
      report(pid, [{@a, @on_white, at}, {@b, @off, at}, {@c, @off, at}])
      assert %{state: true} = last_push(pushes(), 6)

      # Group 1's "off" waits for capacity while A leaves the group.
      Agent.update(agent, &Map.put(&1, :refuse_until, now() + 300))
      Commander.command(cmd({:group, 1}, %Req{has_state: true, state: false}), pid)
      assert_receive {:lights, :refused}, 2_000

      send(pid, {:tuya_mesh_status, status([], [%{local_id: 1, members: [@b, @c]}])})
      flushed(pid)
      assert %{members: [@b, @c]} = :sys.get_state(pid).jobs[{:group, 1}]
      assert [%{state: false}] = of(pushes(), 6)

      idle(pid)
      assert_received {:lights, {:group_set, 1, [on: false], _}}
      assert %{1 => true} = :sys.get_state(pid).views[{:bulb, @a}].dps
      refute Enum.any?(pushes(), &(&1.device_id == 5))
    end
  end
end
