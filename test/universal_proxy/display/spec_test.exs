defmodule UniversalProxy.Display.SpecTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Display.Spec

  defp find_all(:none, _fun), do: []

  defp find_all({_tag, _attrs, children} = node, fun) when is_list(children) do
    matches = if fun.(node), do: [node], else: []
    matches ++ Enum.flat_map(children, &find_all(&1, fun))
  end

  defp find_all(node, fun), do: if(fun.(node), do: [node], else: [])

  defp keyed(spec, key), do: find_all(spec, &match?({_, [{:key, ^key} | _], _}, &1))

  describe "now_playing/1" do
    test "shows title, artist and album as text nodes" do
      spec = Spec.now_playing(title: "Song", artist: "Band", album: "Record")

      assert [{:text, _, "Song"}] = keyed(spec, "title")
      assert [{:text, _, "Band"}] = keyed(spec, "artist")
      assert [{:text, _, "Record"}] = keyed(spec, "album")
    end

    test "fills the screen with the background colour" do
      assert {:column, attrs, _} = Spec.now_playing(background: {1, 2, 3})
      assert attrs[:width] == :fill
      assert attrs[:height] == :fill
      assert attrs[:background] == {1, 2, 3}
    end

    test "shows artwork as an image node when given a path, a placeholder otherwise" do
      assert [{:image, _, "/tmp/art.jpg"}] = keyed(Spec.now_playing(art: "/tmp/art.jpg"), "art")
      assert [{:column, _, []}] = keyed(Spec.now_playing(), "art")
    end

    test "has a bar strip with the given bars, or :bar_count zero bars" do
      assert [{:bars, _, [0.5, 1.0]}] = keyed(Spec.now_playing(bars: [0.5, 1.0]), "viz")
      assert [{:bars, _, bars}] = keyed(Spec.now_playing(bar_count: 16), "viz")
      assert bars == List.duplicate(0.0, 16)
    end

    test "uses unique keys" do
      keys =
        Spec.now_playing(art: "/tmp/a.png")
        |> find_all(&match?({_, [{:key, _} | _], _}, &1))
        |> Enum.map(fn {_, attrs, _} -> attrs[:key] end)

      assert keys == Enum.uniq(keys)
    end
  end

  describe "bars/2" do
    test "clamps heights to 0.0..1.0 and keeps attrs" do
      assert Spec.bars([-1, 0.25, 7, :nan], key: "b") ==
               {:bars, [key: "b"], [0.0, 0.25, 1.0, 0.0]}
    end
  end

  test "present/1 drops :none children, which element_count/1 doesn't count" do
    a = {:text, [key: "a"], "a"}
    b = {:column, [key: "b"], []}

    assert Spec.present([a, :none, b, :none]) == [a, b]
    assert Spec.present([]) == []

    assert Spec.element_count({:column, [], [a, :none, b]}) ==
             Spec.element_count({:column, [], [a, b]})
  end

  test "clamp_unit/1 always returns a float" do
    assert Spec.clamp_unit(0) === 0.0
    assert Spec.clamp_unit(1) === 1.0
    assert Spec.clamp_unit(0.5) === 0.5
    assert Spec.clamp_unit(nil) === 0.0
  end
end
