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
  @ids %{
    {:bulb, @a} => 5,
    {:bulb, @b} => 7,
    {:bulb, @c} => 8,
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
      Agent.get_and_update(Keyword.fetch!(opts, :server), &handle(request, &1))
    end

    defp handle({:set, mac, batch, opts} = req, s) do
      send(s.test, {:lights, req})
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

    defp handle(:all, s) do
      bulbs = for {mac, b} <- s.bulbs, do: Map.put(b, :mac, mac)
      {{:ok, bulbs}, s}
    end

    defp handle({:status, mac}, s) do
      send(s.test, {:lights, {:status, mac}})
      {{:ok, %{dps: get_in(s.bulbs, [mac, :dps]) || %{}}}, s}
    end

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
             %{test: test, set: %{}, group_set: [], hears: [], bulbs: %{}, clock: 0, ids: @ids},
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
        _ -> :error
      end,
      push: &send(test, {:push, &1}),
      device_ids: fn -> Agent.get(agent, & &1.ids) end,
      subscribe: false,
      window_ms: 20,
      retry_ms: 1,
      max_retries: 3,
      followup_gap_ms: 0,
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
  defp idle(pid, deadline \\ System.monotonic_time(:millisecond) + 3_000) do
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

      assert_receive {:lights, {:status, @a}}
      assert_receive {:lights, {:set, @a, [on: true, mode: :white, temp: 0], [ack: true]}}
      assert_receive {:lights, {:set, @a, [brightness: 1000], [ack: true]}}

      assert_receive {:push, %LightStateResponse{} = r}
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

    test "retries are bounded and a refused command pushes nothing" do
      script = %{set: %{@a => List.duplicate({:error, :busy}, 10)}}
      {pid, _agent} = start(script: script, max_retries: 2)

      Commander.command(cmd({:bulb, @a}, on()), pid)
      idle(pid)

      assert length(sets()) == 3
      refute_received {:push, _}
      assert :sys.get_state(pid).jobs == %{}
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
      assert_receive {:lights, {:set, @a, [on: true, mode: :white, temp: 0], _}}

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

      assert_receive {:lights, {:group_set, 1, [on: true, mode: :white, temp: 0], [ack: true]}}

      assert_receive {:lights, {:group_set, 1, [brightness: 1000], [ack: true]}}
      assert_receive {:push, %LightStateResponse{key: 88, device_id: 6, state: true}}

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
      assert_receive {:lights, {:group_set, 1, [brightness: 1000], _}}

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

    test "busy follow-ups are retried, bounded, then the next bulb goes" do
      script = %{set: %{@a => List.duplicate({:error, :busy}, 10)}}
      {pid, _agent} = start(script: script, max_retries: 2)

      Commander.command(cmd({:group, 1}, on()), pid)
      idle(pid)

      followups = sets()
      assert Enum.count(followups, &match?({@a, _}, &1)) == 3
      assert {@b, [on: true]} in followups
      assert {@c, [on: true]} in followups
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
      assert_receive {:lights, {:set, @a, [on: true], _}}

      Commander.command(cmd({:group, 1}, %Req{has_state: true, state: false}), pid)
      idle(pid)

      assert sets() == []
    end

    test "a busy group retry never turns back on a member a newer command turned off" do
      {pid, _agent} = start(script: %{group_set: [{:error, :busy}]}, retry_ms: 100)

      Commander.command(cmd({:group, 1}, on()), pid)
      assert_receive {:lights, {:group_set, 1, [on: true], _}}

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
      assert_receive {:lights, {:group_set, 1, [on: true], _}}

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
      assert_receive {:lights, {:group_set, 3, [on: true], _}}

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

    test "a follow-up out of retries drops that bulb's later frames" do
      script = %{set: %{@a => List.duplicate({:error, :busy}, 10)}}
      {pid, _agent} = start(script: script, max_retries: 2)

      Commander.command(cmd({:group, 1}, warm_full_on()), pid)
      idle(pid)

      followups = sets()
      a_frames = Enum.filter(followups, &match?({@a, _}, &1))
      assert a_frames == List.duplicate({@a, [on: true, mode: :white, temp: 0]}, 3)
      for mac <- [@b, @c], do: assert({mac, [brightness: 1000]} in followups)
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
      assert_receive {:lights, {:group_set, 1, [on: true], _}}
      Commander.command(cmd({:bulb, @b}, %Req{has_state: true, state: false}), pid)
      assert_receive {:push, %LightStateResponse{key: 77, device_id: 7, state: false}}
      views = :sys.get_state(pid).views

      idle(pid)
      assert {@a, [on: true]} in sets()
      refute_received {:push, _}
      assert :sys.get_state(pid).views == views
    end

    test "a diversion plans every member's first frame before any second one" do
      {pid, _agent} =
        start(script: %{group_set: [{:error, :busy}]}, retry_ms: 100, max_followups: 3)

      Commander.command(cmd({:group, 1}, warm_full_on()), pid)
      assert_receive {:lights, {:group_set, 1, _, _}}
      Commander.command(cmd({:bulb, @b}, %Req{has_state: true, state: false}), pid)
      idle(pid)

      assert sets() == [
               {@b, [on: false]},
               {@a, [on: true, mode: :white, temp: 0]},
               {@c, [on: true, mode: :white, temp: 0]},
               {@a, [brightness: 1000]}
             ]
    end

    test "the direct-frame budget is shared by the diversion and the confirmation pass" do
      script = %{group_set: [:ok, {:error, :busy}]}
      {pid, _agent} = start(script: script, retry_ms: 100, max_followups: 3)

      # The first frame goes out as a broadcast nobody hears; the second
      # is diverted once B has a newer command.
      Commander.command(cmd({:group, 1}, warm_full_on()), pid)
      assert_receive {:lights, {:group_set, 1, [brightness: 1000], _}}
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
      assert_receive {:lights, {:group_set, 1, [on: true], _}}

      # The new mesh reuses local id 1 for another group: a new sub-device.
      new_mesh(agent, %{{:group, 1} => 42})
      idle(pid)

      refute_received {:lights, {:group_set, _, _, _}}
      assert sets() == []
      refute_received {:push, _}
    end

    test "a Store change drops stale commands and the kept DPs of changed lights" do
      {pid, agent} = start(script: %{group_set: [:ok, {:error, :busy}]}, retry_ms: 60_000)

      Commander.command(cmd({:bulb, @a}, on()), pid)
      Commander.command(cmd({:group, 3}, on()), pid)
      idle(pid)
      Commander.command(cmd({:group, 1}, on()), pid)
      assert_receive {:lights, {:group_set, 1, [on: true], _}}

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
      assert_receive {:lights, {:group_set, 1, [on: true], _}}

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
      assert_receive {:lights, {:group_set, 2, [on: true], _}}
      idle(pid)
      assert sets() == []
      assert :sys.get_state(pid).jobs == %{}
    end
  end
end
