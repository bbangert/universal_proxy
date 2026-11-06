defmodule MilkdropRendererUnitTest do
  @moduledoc """
  Builds and runs `milkdrop_renderer_unit_tests` (c_src/milkdrop_renderer/test):
  the C++ checks for the renderer's GL-free core — protocol, manifest and
  skip list, preset rotation and history, the cost-guard ladder, frame
  pacing, the thermal guard, stderr filtering and PCM ring alignment. The
  target is outside the default build, so it is built here in the host build
  dir the `:milkdrop_renderer` compiler already configured.
  """

  use ExUnit.Case, async: true

  @moduletag :contract

  test "the C++ unit tests pass" do
    build_dir = Path.join(Mix.Project.build_path(), "milkdrop_renderer")

    {out, status} =
      System.cmd(
        "cmake",
        ["--build", build_dir, "--target", "milkdrop_renderer_unit_tests", "-j"],
        stderr_to_stdout: true
      )

    assert status == 0, "building milkdrop_renderer_unit_tests failed:\n#{out}"

    {out, status} =
      System.cmd(Path.join(build_dir, "milkdrop_renderer_unit_tests"), [], stderr_to_stdout: true)

    assert status == 0, out
    assert out =~ "OK"
  end

  test "the renderer's pcm_tap.h is the player's, verbatim" do
    assert File.read!("c_src/milkdrop_renderer/src/pcm_tap.h") ==
             File.read!("c_src/sendspin_player/src/pcm_tap.h"),
           "re-copy c_src/sendspin_player/src/pcm_tap.h into c_src/milkdrop_renderer/src/"
  end
end
