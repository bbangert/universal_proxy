defmodule UniversalProxy.Display.ModeTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Display.Mode

  test "the HA select's identity and options are frozen" do
    assert Mode.object_id() == "tv_display_mode"
    assert Mode.name() == "TV display mode"
    assert Mode.options() == ["Now Playing", "Visualizer", "Party QR", "Off"]
    assert Mode.default() == :now_playing
  end

  test "every mode round-trips through its option" do
    for mode <- Mode.modes() do
      assert {:ok, ^mode} = mode |> Mode.to_option() |> Mode.parse()
      assert {:ok, ^mode} = Mode.parse(mode)
    end
  end

  test "parse/1 rejects anything else" do
    for bad <- ["now playing", "", "Off ", :bogus, nil, 1] do
      assert Mode.parse(bad) == :error
    end
  end

  test "cycle/2 steps through the remote's modes, wrapping, skipping Off" do
    assert Mode.cycle(:now_playing, 1) == :visualizer
    assert Mode.cycle(:visualizer, 1) == :party_qr
    assert Mode.cycle(:party_qr, 1) == :now_playing
    assert Mode.cycle(:now_playing, -1) == :party_qr
    assert Mode.cycle(:off, 1) == :now_playing
  end
end
