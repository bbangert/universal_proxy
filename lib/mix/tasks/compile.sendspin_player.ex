defmodule Mix.Tasks.Compile.SendspinPlayer do
  @moduledoc """
  Mix compiler that builds the `sendspin_player` C++ binary via CMake.

  Runs once per `mix compile`. On supported targets, the binary is built into
  `_build/<MIX_TARGET>/sendspin_player/` and copied (atomically renamed) to
  `priv/sendspin_player/<MIX_TARGET>/sendspin_player` where the runtime can
  locate it via `Application.app_dir(:universal_proxy, "priv/...")`.

  ## Supported targets

  Host plus the RPi Nerves systems listed in `mix.exs`. Other targets compile
  the firmware unchanged with this step skipped — the BEAM-side
  `UniversalProxy.Audio.Player` self-disables when the expected binary path
  is missing.

  ## Cross-compile

  Nerves sets `CC`, `CXX`, `CFLAGS`, `LDFLAGS`, and `STRIP` for the active
  `nerves_system_*` toolchain. CMake honours `CC`/`CXX` from the environment,
  and the toolchain's sysroot supplies libasound. No CMake toolchain file is
  needed.

  ## Patch lifecycle

  The CMakeLists.txt applies a small patch to `sendspin-cpp` via
  `FetchContent` PATCH_COMMAND so the WebSocket port can be set via the
  `SENDSPIN_WS_PORT` environment variable. See
  `c_src/sendspin_player/patches/0001-configurable-ws-port.patch`.

  ## Failure modes

  Missing `cmake` on PATH is intentionally fatal (returns a `:error`
  diagnostic) rather than a soft skip, because every supported target needs
  cmake to produce a runnable binary. Contributors who genuinely want to
  bypass the native build can switch `MIX_TARGET` to something outside
  `@supported_targets`, which routes through the `:noop` branch instead.
  """

  use Mix.Task.Compiler

  @supported_targets ~w(host rpi rpi0 rpi0_2 rpi2 rpi3 rpi4 rpi5)a

  @impl Mix.Task.Compiler
  def run(_args) do
    target = Mix.target()

    cond do
      target not in @supported_targets ->
        Mix.shell().info("[sendspin_player] target #{target} not supported; skipping")
        {:noop, []}

      System.find_executable("cmake") == nil ->
        error_diagnostic(
          "cmake not found on PATH — install cmake to build sendspin_player",
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
  # Exposes the paths `clean/0` would delete so tests can assert per-target
  # scoping without actually touching the filesystem.
  @spec clean_paths(atom()) :: {Path.t(), Path.t()}
  def clean_paths(target) do
    build_root = Path.join(Mix.Project.build_path(), "sendspin_player")
    priv_target_dir = Path.join(["priv", "sendspin_player", Atom.to_string(target)])
    {build_root, priv_target_dir}
  end

  defp build(target) do
    source_dir = Path.absname("c_src/sendspin_player")
    build_dir = Path.join(Mix.Project.build_path(), "sendspin_player")
    priv_target_dir = Path.absname(Path.join(["priv", "sendspin_player", Atom.to_string(target)]))
    binary_dest = Path.join(priv_target_dir, "sendspin_player")
    binary_src = Path.join(build_dir, "sendspin_player")

    File.mkdir_p!(build_dir)
    File.mkdir_p!(priv_target_dir)

    Mix.shell().info("[sendspin_player] configuring (#{target}) → #{build_dir}")

    with :ok <- cmake_configure(source_dir, build_dir),
         :ok <- cmake_build(build_dir),
         :ok <- copy_binary(binary_src, binary_dest) do
      Mix.shell().info("[sendspin_player] built → #{binary_dest}")
      {:ok, []}
    else
      {:error, msg, file} -> error_diagnostic(msg, file)
    end
  end

  defp cmake_configure(source_dir, build_dir) do
    args = [
      "-S",
      source_dir,
      "-B",
      build_dir,
      "-DCMAKE_BUILD_TYPE=Release"
    ]

    case run_cmake(args) do
      0 -> :ok
      code -> {:error, "cmake configure failed (exit #{code}) — see output above", nil}
    end
  end

  defp cmake_build(build_dir) do
    jobs = System.schedulers_online() |> to_string()
    args = ["--build", build_dir, "-j", jobs]

    case run_cmake(args) do
      0 -> :ok
      code -> {:error, "cmake build failed (exit #{code}) — see output above", nil}
    end
  end

  # Stream cmake stdout/stderr to the user's terminal in real time so multi-
  # minute FetchContent downloads and ARM cross-compiles show progress. The
  # exit code is captured for diagnostics; the actual error text is already
  # visible above the diagnostic message thanks to streaming.
  defp run_cmake(args) do
    {_output, code} =
      System.cmd("cmake", args,
        stderr_to_stdout: true,
        into: IO.stream(:stdio, :line)
      )

    code
  end

  defp copy_binary(src, dest) do
    if File.exists?(src) do
      # Copy to a temp path then atomically rename so we can replace the
      # binary even when an old instance is still executing it (Linux
      # gives ETXTBSY on direct overwrite of a running executable, but
      # rename swaps the directory entry transparently).
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
      compiler_name: "sendspin_player",
      file: file,
      message: msg,
      position: nil,
      severity: :error
    }

    {:error, [diagnostic]}
  end
end
