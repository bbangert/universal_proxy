defmodule UniversalProxy.Display.Renderer.NullTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Display.Renderer.Null
  alias UniversalProxy.Display.Spec

  test "is never available" do
    refute Null.available?()
  end

  test "accepts every call without starting anything" do
    sup = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    assert {:ok, handle} = Null.start(sup, spec: Spec.now_playing())
    assert :ok = Null.push(handle, Spec.now_playing(title: "x"))
    assert :ok = Null.set_display(handle, :off)
    assert :ok = Null.stop(handle)
    assert DynamicSupervisor.count_children(sup).active == 0
  end
end
