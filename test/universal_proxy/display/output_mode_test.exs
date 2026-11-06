defmodule UniversalProxy.Display.OutputModeTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Display.OutputMode

  defp mode(w, h, hz, opts \\ []) do
    %{
      width: w,
      height: h,
      refresh_hz: hz,
      preferred: Keyword.get(opts, :preferred, false),
      interlaced: Keyword.get(opts, :interlaced, false)
    }
  end

  # An LG C2's list, roughly: 4K preferred, plus the usual TV modes.
  defp tv do
    [
      mode(3840, 2160, 60.0, preferred: true),
      mode(3840, 2160, 30.0),
      mode(1920, 1080, 60.0),
      mode(1920, 1080, 50.0),
      mode(1920, 1080, 60.0, interlaced: true),
      mode(1280, 720, 60.0),
      mode(1280, 720, 59.94),
      mode(720, 480, 59.94)
    ]
  end

  describe "choose/2" do
    test "the closest size to the wanted one, at the highest refresh" do
      assert %{width: 1280, height: 720, refresh_hz: 60.0} = OutputMode.choose(tv(), {1280, 720})

      assert %{width: 1920, height: 1080, refresh_hz: 60.0, interlaced: false} =
               OutputMode.choose(tv(), {1920, 1080})

      assert %{width: 1280, height: 720} = OutputMode.choose(tv(), {1366, 768})
    end

    test "without a wanted size, the preferred mode's size" do
      assert %{width: 3840, height: 2160, refresh_hz: 60.0} = OutputMode.choose(tv(), nil)
    end

    test "prefers the preferred flag on a tie, and progressive over interlaced" do
      tie = [mode(1920, 1080, 60.0), mode(1920, 1080, 60.0, preferred: true)]
      assert %{preferred: true} = OutputMode.choose(tie, {1920, 1080})

      assert %{interlaced: true} =
               OutputMode.choose([mode(1920, 1080, 60.0, interlaced: true)], {1280, 720})
    end

    test "nothing advertised, nothing chosen" do
      assert OutputMode.choose([], {1280, 720}) == nil
    end
  end

  test "size/1 reads a mode map or an Emerge mode id" do
    assert OutputMode.size(mode(1280, 720, 60.0)) == {1280, 720}
    assert OutputMode.size("1920x1080:148500:2008:2052:2200:0:1084:1089:1125:0:5") == {1920, 1080}
    assert OutputMode.size("bogus") == nil
    assert OutputMode.size(nil) == nil
  end

  test "renderer_mode/1 is the reported size with no refresh pinned" do
    assert OutputMode.renderer_mode({1280, 720}) == %{width: 1280, height: 720}
    assert OutputMode.renderer_mode({1920, 1080}) == %{width: 1920, height: 1080}
  end

  describe "connector_card/3" do
    @describetag :tmp_dir

    # A fake /sys/class/drm and /dev/dri: `cards` are the card nodes,
    # `entries` the sysfs entries.
    defp drm(tmp_dir, cards, entries) do
      sysfs = Path.join(tmp_dir, "sys")
      dri = Path.join(tmp_dir, "dri")
      File.mkdir_p!(sysfs)
      File.mkdir_p!(dri)
      Enum.each(cards, &File.write!(Path.join(dri, &1), ""))
      Enum.each(entries, &File.mkdir_p!(Path.join(sysfs, &1)))
      {sysfs, dri}
    end

    test "the card whose sysfs entries have the connector", %{tmp_dir: tmp_dir} do
      # As on a Pi 4: card0 is v3d (no connectors), card1 is vc4.
      {sysfs, dri} =
        drm(tmp_dir, ~w(card0 card1), ~w(card0 card1 card1-HDMI-A-1 card1-HDMI-A-2 renderD128))

      assert OutputMode.connector_card("HDMI-A-1", sysfs, dri) == Path.join(dri, "card1")
      assert OutputMode.connector_card("HDMI-A-2", sysfs, dri) == Path.join(dri, "card1")
    end

    test "nil without a card for it", %{tmp_dir: tmp_dir} do
      {sysfs, dri} = drm(tmp_dir, ~w(card0), ~w(card0 card0-HDMI-A-1 card0-HDMI-A-10))
      assert OutputMode.connector_card("HDMI-A-2", sysfs, dri) == nil
      # A prefix of another connector's name isn't it.
      assert OutputMode.connector_card("HDMI-A", sysfs, dri) == nil
      # No card node for the sysfs entry.
      {sysfs, dri} = drm(Path.join(tmp_dir, "nonode"), [], ~w(card3-HDMI-A-1))
      assert OutputMode.connector_card("HDMI-A-1", sysfs, dri) == nil
      assert OutputMode.connector_card("HDMI-A-1", Path.join(tmp_dir, "missing"), dri) == nil
    end

    test "of several, the first card path in sort order", %{tmp_dir: tmp_dir} do
      {sysfs, dri} = drm(tmp_dir, ~w(card1 card2), ~w(card2-HDMI-A-1 card1-HDMI-A-1))
      assert OutputMode.connector_card("HDMI-A-1", sysfs, dri) == Path.join(dri, "card1")
    end

    test "nil for a name that isn't a connector name", %{tmp_dir: tmp_dir} do
      {sysfs, dri} = drm(tmp_dir, ~w(card0), ~w(card0-HDMI-A-1))
      assert OutputMode.connector_card("*", sysfs, dri) == nil
      assert OutputMode.connector_card("../HDMI-A-1", sysfs, dri) == nil
      assert OutputMode.connector_card(nil, sysfs, dri) == nil
    end
  end
end
