defmodule UniversalProxy.Audio.DisplayRolesTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Audio.DisplayRoles

  @hp {"bcm2835 Headphones", nil, nil}
  @hdmi {"vc4-hdmi", nil, nil}
  @hdmi0 {"vc4-hdmi-0", nil, nil}
  @hdmi1 {"vc4-hdmi-1", nil, nil}

  defp outputs(keys), do: Enum.map(keys, &%{key: &1})

  describe "choose/2" do
    test "nil without an HDMI output" do
      assert DisplayRoles.choose(outputs([@hp]), fn _ -> :connected end) == nil
      assert DisplayRoles.choose([], fn _ -> :connected end) == nil
    end

    test "the single-port HDMI output, whatever its connector says" do
      for status <- [:connected, :disconnected, :unknown] do
        assert DisplayRoles.choose(outputs([@hp, @hdmi]), fn _ -> status end) == @hdmi
      end
    end

    test "prefers HDMI 0 when it is connected" do
      assert DisplayRoles.choose(outputs([@hdmi1, @hdmi0]), fn _ -> :connected end) == @hdmi0
    end

    test "the first connected port when HDMI 0 is not" do
      status = fn
        0 -> :disconnected
        1 -> :connected
      end

      assert DisplayRoles.choose(outputs([@hdmi0, @hdmi1]), status) == @hdmi1
    end

    test "falls back to the lowest port when none reports connected" do
      assert DisplayRoles.choose(outputs([@hdmi1, @hdmi0]), fn _ -> :unknown end) == @hdmi0
    end
  end

  describe "connector_status/2" do
    @tag :tmp_dir
    test "reads the HDMI-A-<port + 1> connector on any DRM card", %{tmp_dir: root} do
      write = fn name, status ->
        File.mkdir_p!(Path.join(root, name))
        File.write!(Path.join([root, name, "status"]), status <> "\n")
      end

      write.("card1-HDMI-A-1", "connected")
      write.("card1-HDMI-A-2", "disconnected")
      write.("card1-Composite-1", "connected")

      assert DisplayRoles.connector_status(0, root) == :connected
      assert DisplayRoles.connector_status(1, root) == :disconnected
      assert DisplayRoles.connector_status(2, root) == :unknown
    end

    test ":unknown without a DRM sysfs" do
      assert DisplayRoles.connector_status(0, "/nonexistent/drm") == :unknown
    end
  end

  test "player_opts/2 puts artwork under <root>/<client_id>" do
    cfg = Keyword.merge(DisplayRoles.config(), artwork_root: "/tmp/up_artwork", viz_bins: 48)

    assert %{
             artwork_dir: "/tmp/up_artwork/abc123",
             artwork_size: {480, 480},
             artwork_keep: 8,
             viz_bins: 48,
             viz_rate: 20,
             viz_offset_ms: 100
           } = DisplayRoles.player_opts(%{client_id: "abc123"}, cfg)
  end

  test "player_opts/2 defaults the artwork root to the system tmp dir" do
    %{artwork_dir: dir} = DisplayRoles.player_opts(%{client_id: "abc123"}, DisplayRoles.config())
    assert dir == Path.join([System.tmp_dir!(), "up_artwork", "abc123"])
  end
end
