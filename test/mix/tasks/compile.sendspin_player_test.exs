defmodule Mix.Tasks.Compile.SendspinPlayerTest do
  @moduledoc """
  Pure-Elixir tests for the `:sendspin_player` Mix compiler. Exercises path
  logic without actually invoking CMake or touching the filesystem.

  The full compile path is covered by the contract test
  (`test/sendspin_player_contract_test.exs`) which builds and runs the
  real binary; unit tests here guard the guard clauses.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Compile.SendspinPlayer

  describe "clean_paths/1" do
    test "scopes the priv path to the given target, not all targets" do
      {_build, priv_rpi3} = SendspinPlayer.clean_paths(:rpi3)
      assert priv_rpi3 == Path.join(["priv", "sendspin_player", "rpi3"])

      {_build, priv_host} = SendspinPlayer.clean_paths(:host)
      assert priv_host == Path.join(["priv", "sendspin_player", "host"])

      refute priv_rpi3 == priv_host,
             "different targets must produce different priv paths"
    end

    test "scopes the build path under Mix.Project.build_path/0" do
      {build_root, _priv} = SendspinPlayer.clean_paths(Mix.target())

      assert build_root == Path.join(Mix.Project.build_path(), "sendspin_player"),
             "build path must live under the env-specific _build/ dir " <>
               "(otherwise alternating MIX_TARGET clobbers cache)"
    end
  end
end
