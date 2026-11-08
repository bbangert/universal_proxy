defmodule UniversalProxy.Display.StateStartFailureTest do
  # Not async: the State module's log level is set globally so debug lines
  # reach the capture.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias UniversalProxy.Display.FakeRenderer
  alias UniversalProxy.Display.State

  @moduletag :tmp_dir

  @key {"vc4-hdmi", nil, nil}
  @output %{key: @key, client_id: "c0", card_index: 1, display_roles: true}

  @warning ~r/\[warning\] \[Display\] viewport did not start/
  @debug "[debug] [Display] viewport did not start"

  setup context do
    Logger.put_module_level(State, :debug)
    on_exit(fn -> Logger.delete_module_level(State) end)

    sup = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    dri_dir = Path.join(context.tmp_dir, "dri")
    File.mkdir_p!(dri_dir)
    File.write!(Path.join(dri_dir, "card0"), "")
    %{sup: sup, dri_dir: dri_dir}
  end

  # Each start pops the next scripted result (a reason fails, :ok succeeds;
  # the last entry repeats).
  defp scripted(results) do
    {:ok, agent} = Agent.start_link(fn -> results end)

    fn ->
      result =
        Agent.get_and_update(agent, fn
          [last] -> {last, [last]}
          [head | rest] -> {head, rest}
        end)

      if result == :ok, do: :ok, else: {:error, result}
    end
  end

  defp start_state(context, results) do
    test = self()
    pubsub = :"#{inspect(__MODULE__)}.#{context.test}.PubSub"
    start_supervised!({Phoenix.PubSub, name: pubsub})
    tasks = start_supervised!(Task.Supervisor)

    audio = %{
      list_outputs: fn -> [@output] end,
      display_snapshot: fn _key -> {0, %{}} end,
      controller: fn _key, _cmd -> :ok end,
      viz_enable: fn _key, _on? -> :ok end,
      update_config: fn _key, _params -> :ok end
    }

    cec = %{
      list_adapters: fn -> [] end,
      claim_keys: fn _dev, _pid -> :ok end,
      release_keys: fn _dev -> :ok end
    }

    start_supervised!({
      State,
      name: :"#{inspect(__MODULE__)}.#{context.test}",
      ui: true,
      renderer: FakeRenderer,
      viewport_supervisor: context.sup,
      dri_dir: context.dri_dir,
      viewport_opts: [test_pid: test, start_error: scripted(results)],
      view_opts: [bars: 8, drift_period_ms: 1_000_000_000_000],
      model_opts: [idle_ms: 60_000, restart_ms: 1, restart_max_ms: 4, stable_ms: 60_000],
      pubsub: pubsub,
      task_supervisor: tasks,
      audio: audio,
      cec: cec
    })
  end

  # Waits for the nth start, then syncs so the failure's log line (written
  # after the renderer returns) is inside the capture.
  defp await_start(pid) do
    assert_receive {:fake_renderer, :start, _}, 2_000
    _ = :sys.get_state(pid)
  end

  defp warnings(log), do: length(Regex.scan(@warning, log))

  test "an identical repeated failure warns once", context do
    log =
      capture_log([level: :debug], fn ->
        pid = start_state(context, [:boom])
        await_start(pid)
        await_start(pid)
      end)

    assert warnings(log) == 1
    assert log =~ @debug
  end

  test "a changed reason warns again", context do
    log =
      capture_log([level: :debug], fn ->
        pid = start_state(context, [:boom, :bang])
        await_start(pid)
        await_start(pid)
      end)

    assert warnings(log) == 2
  end

  test "a success resets, so the same failure warns again", context do
    log =
      capture_log([level: :debug], fn ->
        pid = start_state(context, [:boom, :ok, :boom])
        await_start(pid)
        await_start(pid)
        Agent.stop(GenServer.call(pid, :viewport), :crashed)
        await_start(pid)
      end)

    assert warnings(log) == 2
  end

  test "the no-display reason is calm info, not a warning", context do
    reason = {:mode_not_found, :auto, []}

    log =
      capture_log([level: :debug], fn ->
        pid = start_state(context, [reason])
        await_start(pid)
        await_start(pid)
      end)

    assert log =~ "[info] [Display] no display connected; will retry"
    assert warnings(log) == 0
    assert log =~ @debug
  end

  test "other mode_not_found cases still warn", context do
    log =
      capture_log([level: :debug], fn ->
        pid = start_state(context, [{:mode_not_found, :auto, [{800, 600, 60.0}]}])
        await_start(pid)
      end)

    assert warnings(log) == 1
  end
end
