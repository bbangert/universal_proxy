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
      bulb = Map.get(s.bulbs, mac, %{dps: %{}, last_report_ms: nil})
      bulb = %{bulb | dps: Map.merge(bulb.dps, Commands.expected(batch)), last_report_ms: s.clock}
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
      assert %{key: 77, device_id: 5, state: true, brightness: 1.0} = r
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

  describe "group" do
    test "members that didn't confirm get direct follow-ups; confirmers don't" do
      {pid, _agent} = start(script: %{hears: [@a]})

      Commander.command(cmd({:group, 1}, warm_full_on(), 88), pid)

      assert_receive {:lights, {:group_set, 1, [on: true, mode: :white, temp: 0], [ack: true]}},
                     2_000

      assert_receive {:lights, {:group_set, 1, [brightness: 1000], [ack: true]}}, 2_000
      assert_receive {:push, %LightStateResponse{key: 88, device_id: 6, state: true}}, 2_000

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
      assert_received {:push, %LightStateResponse{key: 77, device_id: 7, state: false}}
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
end
