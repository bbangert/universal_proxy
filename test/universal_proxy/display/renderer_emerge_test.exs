# Emerge is only a dependency on the display targets, so on host (the CI
# default) this file compiles to nothing.
if Code.ensure_loaded?(UniversalProxy.Display.Renderer.Emerge) do
  defmodule UniversalProxy.Display.Renderer.EmergeTest do
    use ExUnit.Case, async: true

    alias UniversalProxy.Display.Renderer.Emerge, as: Renderer

    defp keyed(key), do: {:text, [key: key], key}

    defp types(elements), do: Enum.map(elements, & &1.type)

    # Emerge raises when it reconciles keyed and unkeyed siblings together.
    defp reconcile!(tree),
      do: Emerge.Engine.diff_state_update(Emerge.Engine.diff_state_new(), tree)

    test "a column's and a row's :none children are left out" do
      for tag <- [:column, :row] do
        tree = Renderer.tree({tag, [], [keyed("a"), :none, keyed("b"), :none]})

        assert types(tree.children) == [:el, :el]
        assert Enum.map(tree.children, & &1.key) == [keyed_key("a"), keyed_key("b")]
        assert reconcile!(tree)
      end
    end

    test "a stack's :none overlays are left out of its nearby mounts" do
      tree = Renderer.tree({:stack, [], [keyed("base"), :none, keyed("over"), :none]})

      assert [{:in_front, overlay}] = tree.nearby
      assert overlay.key == keyed_key("over")
      assert reconcile!(tree)
    end

    test "a parent whose children are all :none has none" do
      assert Renderer.tree({:column, [], [:none, :none]}).children == []
    end

    defp keyed_key(key), do: Renderer.tree(keyed(key)).key
  end
end
