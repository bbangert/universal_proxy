defmodule UniversalProxy.Display.ModeTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Display.Mode

  test "the HA select's identity and options are frozen" do
    assert Mode.object_id() == "tv_display_mode"
    assert Mode.name() == "TV display mode"
    assert Mode.options(false) == ["Now Playing", "Visualizer", "Party QR", "Off"]
    assert Mode.options(true) == ["Now Playing", "Visualizer", "MilkDrop", "Party QR", "Off"]
    assert Mode.default() == :now_playing
  end

  test "MilkDrop is off on the host (an unsupported target), whatever the flag" do
    refute UniversalProxy.MilkDrop.enabled?()
    assert Mode.options() == Mode.options(false)
    assert Mode.modes() == [:now_playing, :visualizer, :party_qr, :off]
    assert Mode.parse("MilkDrop") == :error
    assert Mode.cycle(:visualizer, 1) == :party_qr
  end

  test "every mode round-trips through its option" do
    for milkdrop? <- [true, false], mode <- Mode.modes(milkdrop?) do
      assert {:ok, ^mode} = mode |> Mode.to_option() |> Mode.parse(milkdrop?)
      assert {:ok, ^mode} = Mode.parse(mode, milkdrop?)
    end
  end

  test "parse/2 rejects anything else, and MilkDrop while it is disabled" do
    for bad <- ["now playing", "", "Off ", "milkdrop", :bogus, nil, 1] do
      assert Mode.parse(bad, true) == :error
    end

    assert Mode.parse("MilkDrop", false) == :error
    assert Mode.parse(:milkdrop, false) == :error
    assert Mode.parse("MilkDrop", true) == {:ok, :milkdrop}
    assert Mode.to_option(:milkdrop) == "MilkDrop"
  end

  test "cycle/3 steps through the remote's modes, wrapping, skipping Off" do
    assert Mode.cycle(:now_playing, 1, false) == :visualizer
    assert Mode.cycle(:visualizer, 1, false) == :party_qr
    assert Mode.cycle(:party_qr, 1, false) == :now_playing
    assert Mode.cycle(:now_playing, -1, false) == :party_qr
    assert Mode.cycle(:off, 1, false) == :now_playing
  end

  test "cycle/3 includes MilkDrop after the Visualizer only while enabled" do
    assert Mode.cycle(:visualizer, 1, true) == :milkdrop
    assert Mode.cycle(:milkdrop, 1, true) == :party_qr
    assert Mode.cycle(:party_qr, -1, true) == :milkdrop
    assert Mode.cycle(:milkdrop, -1, true) == :visualizer
    # A disabled MilkDrop (the flag turned off) steps to Now Playing.
    assert Mode.cycle(:milkdrop, 1, false) == :now_playing
  end
end
