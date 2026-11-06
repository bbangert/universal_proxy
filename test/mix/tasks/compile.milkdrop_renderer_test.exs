defmodule Mix.Tasks.Compile.MilkdropRendererTest do
  @moduledoc """
  Pure-Elixir tests for the `:milkdrop_renderer` Mix compiler's path and
  flag logic, without invoking CMake. The host build itself is exercised by
  `test/milkdrop_renderer_unit_test.exs`.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Compile.MilkdropRenderer

  describe "clean_paths/1" do
    test "scopes the priv path to the given target" do
      {_build, priv_rpi3} = MilkdropRenderer.clean_paths(:rpi3)
      assert priv_rpi3 == Path.join(["priv", "milkdrop_renderer", "rpi3"])
      {_build, priv_rpi5} = MilkdropRenderer.clean_paths(:rpi5)
      refute priv_rpi3 == priv_rpi5
    end

    test "scopes the build path under Mix.Project.build_path/0" do
      {build_root, _priv} = MilkdropRenderer.clean_paths(Mix.target())
      assert build_root == Path.join(Mix.Project.build_path(), "milkdrop_renderer")
    end
  end

  describe "cmake_flags/2" do
    test "the host builds the GL-free core only, with no projectM override" do
      flags = MilkdropRenderer.cmake_flags(:host, %{"MILKDROP_PROJECTM_SOURCE_DIR" => "/src/pm"})
      assert "-DMILKDROP_CORE_ONLY=ON" in flags
      refute Enum.any?(flags, &String.contains?(&1, "FETCHCONTENT"))
    end

    test "rpi3 builds GLES 2, rpi4 and rpi5 GLES 3" do
      assert "-DMILKDROP_GLES2=ON" in MilkdropRenderer.cmake_flags(:rpi3, %{})
      assert "-DMILKDROP_GLES2=OFF" in MilkdropRenderer.cmake_flags(:rpi4, %{})
      assert "-DMILKDROP_GLES2=OFF" in MilkdropRenderer.cmake_flags(:rpi5, %{})
      assert "-DMILKDROP_CORE_ONLY=OFF" in MilkdropRenderer.cmake_flags(:rpi3, %{})
    end

    test "a local projectM checkout is forwarded, and dropped again when unset" do
      flags = MilkdropRenderer.cmake_flags(:rpi3, %{"MILKDROP_PROJECTM_SOURCE_DIR" => "/src/pm"})
      assert "-DFETCHCONTENT_SOURCE_DIR_PROJECTM=/src/pm" in flags

      assert "-UFETCHCONTENT_SOURCE_DIR_PROJECTM" in MilkdropRenderer.cmake_flags(:rpi3, %{})

      assert "-UFETCHCONTENT_SOURCE_DIR_PROJECTM" in MilkdropRenderer.cmake_flags(:rpi3, %{
               "MILKDROP_PROJECTM_SOURCE_DIR" => ""
             })
    end
  end
end
