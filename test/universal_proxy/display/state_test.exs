defmodule UniversalProxy.Display.StateTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log
  @moduletag :tmp_dir

  alias UniversalProxy.Display
  alias UniversalProxy.Display.FakeRenderer
  alias UniversalProxy.Display.Spec
  alias UniversalProxy.Display.State

  setup context do
    sup = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    dri_dir = Path.join(context.tmp_dir, "dri")
    File.mkdir_p!(dri_dir)
    if context[:card], do: File.write!(Path.join(dri_dir, "card0"), "")

    state =
      start_supervised!(
        {State,
         name: :"#{inspect(__MODULE__)}.#{context.test}",
         renderer: FakeRenderer,
         viewport_supervisor: sup,
         dri_dir: dri_dir,
         autostart: Map.get(context, :autostart, false),
         viewport_opts: [test_pid: self(), layer_cache_mb: 48],
         spec: Spec.now_playing(title: "Placeholder")}
      )

    %{state: state, sup: sup}
  end

  describe "autostart" do
    @tag autostart: true, card: true
    test "shows the placeholder when a DRM card exists" do
      assert_receive {:fake_renderer, :start, opts}
      assert opts[:layer_cache_mb] == 48
      assert {:column, _, _} = opts[:spec]
    end

    @tag autostart: true
    test "starts nothing without a DRM card", %{state: state} do
      refute_receive {:fake_renderer, :start, _}
      assert GenServer.call(state, :viewport) == nil
    end

    test "is off by default", %{state: state} do
      refute_receive {:fake_renderer, :start, _}
      assert GenServer.call(state, :viewport) == nil
    end
  end

  test "start_viewport merges options and replaces a running viewport", %{state: state} do
    assert {:ok, first} = GenServer.call(state, {:start_viewport, [api: :raster]})
    assert_receive {:fake_renderer, :start, opts}
    assert opts[:api] == :raster
    assert opts[:layer_cache_mb] == 48

    assert {:ok, second} = GenServer.call(state, {:start_viewport, [layer_cache_mb: 8]})
    assert_receive {:fake_renderer, :stop, ^first}
    assert_receive {:fake_renderer, :start, opts}
    assert opts[:layer_cache_mb] == 8
    refute Process.alive?(first)
    assert GenServer.call(state, :viewport) == second
  end

  test "show/1 pushes to the viewport and seeds the next one", %{state: state} do
    spec = Spec.now_playing(title: "Next")

    GenServer.cast(state, {:show, spec})
    {:ok, viewport} = GenServer.call(state, {:start_viewport, []})
    assert_receive {:fake_renderer, :start, opts}
    assert opts[:spec] == spec

    other = Spec.now_playing(title: "Other")
    GenServer.cast(state, {:show, other})
    assert_receive {:fake_renderer, :push, ^viewport, ^other}
  end

  test "stop_viewport stops it", %{state: state} do
    {:ok, viewport} = GenServer.call(state, {:start_viewport, []})
    assert :ok = GenServer.call(state, :stop_viewport)
    assert_receive {:fake_renderer, :stop, ^viewport}
    assert GenServer.call(state, :viewport) == nil
  end

  test "forgets a viewport that exits", %{state: state} do
    {:ok, viewport} = GenServer.call(state, {:start_viewport, []})
    Agent.stop(viewport, :boom)
    assert GenServer.call(state, :status).viewport == nil
  end

  describe "facade while the subsystem is off" do
    test "returns defaults instead of exiting" do
      assert Display.start_viewport() == {:error, :not_running}
      assert Display.stop_viewport() == :ok
      assert Display.show(Spec.now_playing()) == :ok
      assert Display.viewport() == nil
      assert Display.status() == %{running: false}
    end
  end
end
