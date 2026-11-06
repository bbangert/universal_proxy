defmodule Mix.Tasks.Compile.MilkdropRenderer do
  @moduledoc """
  Mix compiler that builds the `milkdrop_renderer` C++ binary (projectM on
  KMS for the MilkDrop TV display mode) via CMake.

  On device targets the binary is built into `_build/<env>/milkdrop_renderer/`
  and copied (atomically renamed) to
  `priv/milkdrop_renderer/<MIX_TARGET>/milkdrop_renderer`, where
  `UniversalProxy.Display.MilkDrop` finds it.

  ## Supported targets

    * `rpi3` — Mesa vc4, GLES 2.0: projectM is built with `ENABLE_GLES2`;
    * `rpi4`, `rpi5` — Mesa v3d, GLES 3: the upstream GLES 3 path of the
      same fork;
    * `host` — the GL-free core only (`MILKDROP_CORE_ONLY`), so
      `test/milkdrop_renderer_unit_test.exs` can build and run its unit
      tests. No binary is produced: the host has no DRM master to use, and
      CI fetches no projectM.

  Other targets skip this step; `Display.MilkDrop` reports the binary as
  missing there.

  ## projectM source

  `c_src/milkdrop_renderer/CMakeLists.txt` pins the `bbangert/projectm` fork
  by commit SHA. Set `MILKDROP_PROJECTM_SOURCE_DIR` to a local checkout to
  build against it instead (forwarded as `FETCHCONTENT_SOURCE_DIR_PROJECTM`;
  CMake warns when its HEAD is not the pinned SHA). Unsetting it drops the
  override from the CMake cache on the next compile.

  ## Cross-compile

  Nerves exports `CC`/`CXX` and `CMAKE_TOOLCHAIN_FILE` for the active
  system, which roots `find_path`/`find_library` (EGL, GLESv2, GBM, libdrm)
  in its sysroot.

  ## Failure modes

  Missing `cmake` is fatal, as for `:sendspin_player`.
  """

  use Mix.Task.Compiler

  @supported_targets ~w(host rpi3 rpi4 rpi5)a
  @gles2_targets ~w(rpi3)a

  @impl Mix.Task.Compiler
  def run(_args) do
    target = Mix.target()

    cond do
      target not in @supported_targets ->
        Mix.shell().info("[milkdrop_renderer] target #{target} not supported; skipping")
        {:noop, []}

      System.find_executable("cmake") == nil ->
        error_diagnostic(
          "cmake not found on PATH — install cmake to build milkdrop_renderer",
          nil
        )

      true ->
        build(target)
    end
  end

  @impl Mix.Task.Compiler
  def clean do
    {build_root, priv_target_dir} = clean_paths(Mix.target())
    File.rm_rf!(build_root)
    File.rm_rf!(priv_target_dir)
    :ok
  end

  @doc false
  # The paths `clean/0` deletes, for tests that check per-target scoping.
  @spec clean_paths(atom()) :: {Path.t(), Path.t()}
  def clean_paths(target) do
    build_root = Path.join(Mix.Project.build_path(), "milkdrop_renderer")
    priv_target_dir = Path.join(["priv", "milkdrop_renderer", Atom.to_string(target)])
    {build_root, priv_target_dir}
  end

  @doc false
  # The CMake configure flags for a target and environment, for tests.
  @spec cmake_flags(atom(), %{optional(String.t()) => String.t()}) :: [String.t()]
  def cmake_flags(target, env \\ System.get_env()) do
    base = ["-DCMAKE_BUILD_TYPE=Release"]

    target_flags =
      if target == :host do
        ["-DMILKDROP_CORE_ONLY=ON"]
      else
        gles2 = if target in @gles2_targets, do: "ON", else: "OFF"
        ["-DMILKDROP_CORE_ONLY=OFF", "-DMILKDROP_GLES2=#{gles2}"]
      end

    source_flags =
      case env["MILKDROP_PROJECTM_SOURCE_DIR"] do
        dir when is_binary(dir) and dir != "" and target != :host ->
          ["-DFETCHCONTENT_SOURCE_DIR_PROJECTM=#{Path.expand(dir)}"]

        _ when target != :host ->
          ["-UFETCHCONTENT_SOURCE_DIR_PROJECTM"]

        _ ->
          []
      end

    base ++ target_flags ++ source_flags
  end

  defp build(target) do
    source_dir = Path.absname("c_src/milkdrop_renderer")
    {build_dir, _} = clean_paths(target)

    File.mkdir_p!(build_dir)
    Mix.shell().info("[milkdrop_renderer] configuring (#{target}) → #{build_dir}")

    with :ok <- cmake_configure(source_dir, build_dir, cmake_flags(target)),
         :ok <- cmake_build(build_dir, build_target(target)),
         :ok <- install(target, build_dir) do
      {:ok, []}
    else
      {:error, msg, file} -> error_diagnostic(msg, file)
    end
  end

  defp build_target(:host), do: "milkdrop_core"
  defp build_target(_target), do: "milkdrop_renderer"

  defp install(:host, _build_dir), do: :ok

  defp install(target, build_dir) do
    priv_target_dir =
      Path.absname(Path.join(["priv", "milkdrop_renderer", Atom.to_string(target)]))

    File.mkdir_p!(priv_target_dir)
    dest = Path.join(priv_target_dir, "milkdrop_renderer")

    with :ok <- copy_binary(Path.join(build_dir, "milkdrop_renderer"), dest) do
      Mix.shell().info("[milkdrop_renderer] built → #{dest}")
      :ok
    end
  end

  defp cmake_configure(source_dir, build_dir, flags) do
    case run_cmake(["-S", source_dir, "-B", build_dir | flags]) do
      0 -> :ok
      code -> {:error, "cmake configure failed (exit #{code}) — see output above", nil}
    end
  end

  defp cmake_build(build_dir, cmake_target) do
    jobs = System.schedulers_online() |> to_string()

    case run_cmake(["--build", build_dir, "--target", cmake_target, "-j", jobs]) do
      0 -> :ok
      code -> {:error, "cmake build failed (exit #{code}) — see output above", nil}
    end
  end

  # Streamed so FetchContent downloads and cross-compiles show progress.
  defp run_cmake(args) do
    {_output, code} =
      System.cmd("cmake", args, stderr_to_stdout: true, into: IO.stream(:stdio, :line))

    code
  end

  # Copy then rename, so a running instance's binary can be replaced
  # (a direct overwrite gives ETXTBSY).
  defp copy_binary(src, dest) do
    if File.exists?(src) do
      tmp = dest <> ".new"
      File.cp!(src, tmp)
      File.chmod!(tmp, 0o755)
      File.rename!(tmp, dest)
      :ok
    else
      {:error, "expected binary at #{src} but it was not produced", src}
    end
  end

  defp error_diagnostic(msg, file) do
    diagnostic = %Mix.Task.Compiler.Diagnostic{
      compiler_name: "milkdrop_renderer",
      file: file,
      message: msg,
      position: nil,
      severity: :error
    }

    {:error, [diagnostic]}
  end
end
