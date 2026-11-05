defmodule UniversalProxy.Display.ViewTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Display.{Model, Spec, View}

  @party %{url: "https://ma.example/party", name: "Garden party"}

  defp nodes(:none), do: []

  defp nodes({_tag, _attrs, children} = node) when is_list(children),
    do: [node | Enum.flat_map(children, &nodes/1)]

  defp nodes(node), do: [node]

  defp keyed(spec, key), do: Enum.filter(nodes(spec), &(attr(&1, :key) == key))

  defp attr({_tag, attrs, _content}, name), do: Keyword.get(attrs, name)
  defp attr(_node, _name), do: nil

  defp model(fields), do: struct(Model.new(), fields)

  defp texts(spec), do: for({:text, _attrs, s} <- nodes(spec), do: s)

  describe "screens" do
    for {label, fields, keys, absent} <- [
          {"Now Playing", [playback: :playing], ["art", "title", "transport", "viz"],
           ["qr-overlay", "party"]},
          {"Now Playing with the party overlay", [playback: :playing, party: @party],
           ["art", "viz", "qr-overlay", "qr"], ["party"]},
          {"Visualizer", [mode: :visualizer, playback: :playing], ["viz", "title"],
           ["art", "transport"]},
          {"the party QR", [mode: :party_qr, party: @party], ["party", "qr"], ["viz"]},
          {"party off", [mode: :party_qr], ["message"], ["viz", "qr"]}
        ] do
      test label do
        spec = View.render(model(unquote(Macro.escape(fields))))
        for key <- unquote(keys), do: assert(keyed(spec, key) != [], "missing #{key}")
        for key <- unquote(absent), do: assert(keyed(spec, key) == [], "unexpected #{key}")
      end
    end

    test "blank and Off are a black frame" do
      assert View.render(model(blanked: true, playback: :playing)) == Spec.blank()
      assert View.render(model(mode: :off, playback: :playing)) == Spec.blank()
    end
  end

  describe "Now Playing" do
    test "shows the metadata, artwork and a fallback" do
      spec =
        View.render(
          model(
            playback: :playing,
            metadata: %{title: "Song", artist: "Band", album: "Record"},
            artwork: %{path: "/tmp/up_artwork/x/a.jpg"}
          )
        )

      assert ["Song"] = for({:text, _, s} <- keyed(spec, "title"), do: s)
      assert "Band" in texts(spec) and "Record" in texts(spec)
      assert [{:image, _, "/tmp/up_artwork/x/a.jpg"}] = keyed(spec, "art")

      assert "Nothing playing" in texts(View.render(model([])))
    end

    test "the play/pause control says what Select would do" do
      assert "Pause" in texts(View.render(model(playback: :playing)))
      assert "Play" in texts(View.render(model(playback: :paused)))
    end

    test "the focus ring shows only while a CEC TV is present" do
      ringed = fn fields ->
        spec = View.render(model([playback: :playing] ++ fields))

        for id <- ["ctl-prev", "ctl-play_pause", "ctl-next"],
            [node] = keyed(spec, id),
            attr(node, :background),
            do: id
      end

      assert ringed.(tv_presence: :present, focus: :next) == ["ctl-next"]
      assert ringed.(tv_presence: :present, focus: :prev) == ["ctl-prev"]
      assert ringed.(tv_presence: :absent, focus: :next) == []
      assert ringed.(tv_presence: :unknown, focus: :next) == []
    end

    test "uses the color@v1 palette, falling back to the default" do
      spec =
        View.render(
          model(playback: :playing, color: %{background_dark: [1, 2, 3], primary: [9, 8, 7]})
        )

      assert [root | _] = keyed(spec, "root")
      assert attr(root, :background) == {1, 2, 3}
      assert [bars] = keyed(spec, "viz")
      assert attr(bars, :color) == {9, 8, 7}

      spec = View.render(model(playback: :playing, color: %{background_dark: [999, 0, 0]}))
      assert attr(hd(keyed(spec, "root")), :background) == {12, 14, 22}
    end
  end

  describe "output size" do
    test "the reported size wins over the :size hint; margins are 5% per axis" do
      root = fn spec -> hd(keyed(spec, "root")) end

      assert attr(root.(View.render(model(playback: :playing))), :padding) == {36, 64, 36, 64}

      big = View.render(model(playback: :playing), size: {1920, 1080})
      assert attr(root.(big), :padding) == {54, 96, 54, 96}

      reported = View.render(model(playback: :playing, size: {1920, 1080}), size: {1280, 720})
      assert reported == big
    end
  end

  describe "visualizer bars" do
    test "a fixed-size, paint-only row of zeroed bars, sized by the :bars option" do
      for fields <- [[playback: :playing], [mode: :visualizer, playback: :playing]] do
        assert [{:bars, attrs, heights}] = keyed(View.render(model(fields), bars: 24), "viz")
        assert heights == List.duplicate(0.0, 24)
        assert attrs[:bar_mode] == :offset
        assert {:px, _} = attrs[:width]
        assert is_integer(attrs[:max_height])
      end
    end

    test "full screen bars are taller than the strip" do
      [strip] = keyed(View.render(model(playback: :playing)), "viz")
      [full] = keyed(View.render(model(mode: :visualizer, playback: :playing)), "viz")
      assert attr(full, :max_height) > attr(strip, :max_height)
    end

    test "scale with :size" do
      [small] = keyed(View.render(model(playback: :playing), size: {1280, 720}), "viz")
      [big] = keyed(View.render(model(playback: :playing), size: {1920, 1080}), "viz")
      assert attr(big, :max_height) > attr(small, :max_height)
    end
  end

  test "the party card shows the party's name and a QR image once there is one" do
    spec = View.render(model(mode: :party_qr, party: Map.put(@party, :qr_path, "/tmp/qr.png")))
    assert "Garden party" in texts(spec)
    assert [{:image, _, "/tmp/qr.png"}] = keyed(spec, "qr")
  end
end
