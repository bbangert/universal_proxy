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
      s = if reply == :ok, do: Enum.reduce(s.hears, s, &report(&2, &1, batch)), else: s
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
             %{test: test, set: %{}, group_set: [], hears: [], bulbs: %{}, clock: 0},
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
        _ -> :error
      end,
      push: &send(test, {:push, &1}),
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

  defp cmd(target, request, key \\ 77, device_id \\ 5),
    do: %{target: target, key: key, device_id: device_id, settings: @settings, request: request}

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

      Commander.command(cmd({:group, 1}, warm_full_on(), 88, 6), pid)

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
