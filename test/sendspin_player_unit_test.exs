defmodule SendspinPlayerUnitTest do
  @moduledoc """
  Builds and runs `sendspin_player_unit_tests` (c_src/sendspin_player/test):
  the C++ checks for the stdout line budget (`started`, `metadata`), artwork
  file retention, text sanitizing and SHA-256. The target is outside the
  default build, so it is built here in the host build dir the
  `:sendspin_player` compiler already configured.
  """

  use ExUnit.Case, async: true

  @moduletag :contract

  test "the C++ unit tests pass" do
    build_dir = Path.join(Mix.Project.build_path(), "sendspin_player")

    {out, status} =
      System.cmd(
        "cmake",
        ["--build", build_dir, "--target", "sendspin_player_unit_tests", "-j"],
        stderr_to_stdout: true
      )

    assert status == 0, "building sendspin_player_unit_tests failed:\n#{out}"

    {out, status} =
      System.cmd(Path.join(build_dir, "sendspin_player_unit_tests"), [], stderr_to_stdout: true)

    assert status == 0, out
    assert out =~ "OK"
  end
end
