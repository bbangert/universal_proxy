defmodule UniversalProxy.Display.SupervisorTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Display
  alias UniversalProxy.Display.FakeRenderer
  alias UniversalProxy.Display.Renderer.Null
  alias UniversalProxy.Display.State
  alias UniversalProxy.Display.Supervisor, as: DisplaySupervisor

  @moduletag :tmp_dir

  defp names(context) do
    base = "#{inspect(__MODULE__)}.#{context.test}"

    [
      name: :"#{base}.Supervisor",
      state_name: :"#{base}.State",
      viewport_supervisor: :"#{base}.ViewportSupervisor",
      milkdrop_task_supervisor: :"#{base}.MilkDropTaskSupervisor"
    ]
  end

  test "is off by default on host" do
    refute Display.enabled?()
    assert DisplaySupervisor.start_link() == :ignore
  end

  test "returns :ignore when disabled" do
    assert DisplaySupervisor.start_link(enabled: false) == :ignore
  end

  test "with the Null renderer and no DRM card it starts no viewport", context do
    names = names(context)

    start_supervised!(
      {DisplaySupervisor,
       names ++
         [enabled: true, renderer: Null, ui: false, dri_dir: context.tmp_dir]}
    )

    assert %{running: true, renderer: Null, display_card: false, viewport: nil} =
             GenServer.call(names[:state_name], :status)

    assert DynamicSupervisor.count_children(names[:viewport_supervisor]).active == 0
    assert is_pid(Process.whereis(names[:milkdrop_task_supervisor]))
  end

  test "a State crash also takes the viewport down (:one_for_all)", context do
    names = names(context)

    start_supervised!(
      {DisplaySupervisor,
       names ++
         [
           enabled: true,
           renderer: FakeRenderer,
           ui: false,
           viewport_opts: [test_pid: self()]
         ]}
    )

    {:ok, viewport} = GenServer.call(names[:state_name], {:start_viewport, []})
    ref = Process.monitor(viewport)

    Process.exit(Process.whereis(names[:state_name]), :kill)

    assert_receive {:DOWN, ^ref, :process, ^viewport, _reason}
    assert is_pid(wait_for(names[:state_name]))
    assert DynamicSupervisor.count_children(names[:viewport_supervisor]).active == 0
    assert GenServer.call(names[:state_name], :viewport) == nil
  end

  defp wait_for(name, tries \\ 50) do
    case Process.whereis(name) do
      nil when tries > 0 ->
        Process.sleep(10)
        wait_for(name, tries - 1)

      pid ->
        pid
    end
  end

  test "display_card?/1 is false without a card node" do
    assert State.display_card?("/nonexistent/dri") == false
  end
end
