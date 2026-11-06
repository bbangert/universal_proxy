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

  test "renderer_mode/2 is the reported size at 60 Hz unless told otherwise" do
    assert OutputMode.renderer_mode({1280, 720}) == %{width: 1280, height: 720, refresh: 60}
    assert OutputMode.renderer_mode({1920, 1080}, 50) == %{width: 1920, height: 1080, refresh: 50}
  end
end
