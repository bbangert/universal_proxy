defmodule MilkdropPackToolsTest do
  @moduledoc """
  The MilkDrop preset pack pipeline (tools/milkdrop_pack, host-only Python):
  its own unit tests (names, texture rules, manifest schema, tarball safety,
  brightness thresholds, the device sweep), and a tarball made by its code
  going through the consumers — `UniversalProxy.MilkDrop.Pack` downloads,
  verifies and extracts it, and the renderer's manifest parser
  (`milkdrop_manifest_check`) accepts every entry.
  """

  # async: false — the Req.Test stub is shared with the Pack's download task.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias UniversalProxy.MilkDrop
  alias UniversalProxy.MilkDrop.Pack

  @moduletag :python3
  @moduletag :contract
  @moduletag :tmp_dir
  @tool "tools/milkdrop_pack"
  @stub __MODULE__

  setup {Req.Test, :set_req_test_to_shared}

  test "the pipeline's Python unit tests pass" do
    {out, status} =
      System.cmd("python3", ["-m", "unittest", "discover", "-s", "tests", "-t", "."],
        cd: @tool,
        stderr_to_stdout: true
      )

    assert status == 0, out
    assert out =~ ~r/^OK/m
  end

  test "a pipeline tarball installs through MilkDrop.Pack and parses in the renderer",
       %{tmp_dir: tmp_dir} do
    fixture = python!(["tests/make_fixture_pack.py", tmp_dir])
    body = File.read!(fixture["tarball"])
    assert sha256(body) == fixture["sha256"]

    Req.Test.stub(@stub, &Plug.Conn.send_resp(&1, 200, body))
    Phoenix.PubSub.subscribe(UniversalProxy.PubSub, MilkDrop.pack_topic())
    root = Path.join(tmp_dir, "milkdrop")
    version = fixture["version"]

    server =
      start_supervised!(
        {Pack,
         name: nil,
         root: root,
         pin: %{
           version: version,
           url: "https://example.test/pack.tar.gz",
           sha256: fixture["sha256"]
         },
         task_supervisor: start_supervised!(Task.Supervisor),
         req_options: [plug: {Req.Test, @stub}]}
      )

    Pack.ensure(server)
    dir = Path.join(root, version)
    assert await_final() == {:ready, version, dir}

    for id <- fixture["presets"] do
      assert File.regular?(Path.join([dir, "presets", id])), id
    end

    assert File.regular?(Path.join(dir, "NOTICE"))

    check = manifest_check!(Path.join(dir, "manifest.json"), dir)
    assert check["ok"]
    assert check["version"] == version
    assert check["presets"] == length(fixture["presets"])
    assert check["rejected"] == 0
    assert check["missing"] == 0
    assert check["high_frequency"] == 2
    assert check["rpi3_skip"] == 1
  end

  test "the device sweep's Elixir extracts the pack and runs a renderer", %{tmp_dir: tmp_dir} do
    fixture = python!(["tests/make_fixture_pack.py", tmp_dir])
    version = fixture["version"]
    elixir = python!(["tests/sweep_elixir.py", tmp_dir, version, fixture["sha256"]])
    remote = elixir["remote"]
    File.mkdir_p!(remote)
    File.cp!(fixture["tarball"], Path.join(remote, version <> ".tar.gz"))

    assert eval(elixir["extract"]) =~ "EXTRACTED"
    assert File.regular?(Path.join([remote, version, "manifest.json"]))
    refute File.exists?(Path.join(remote, version <> ".tar.gz"))

    probe = elixir["probe"] |> eval() |> last_line() |> Jason.decode!()
    assert probe["pack_ok"]

    run = eval(elixir["run"])
    assert run =~ ~s("event":"stats")
    assert run =~ ~s("preset":"Geiss - Chrome.milk")
    assert run =~ "EXIT_STATUS 0"

    [args] =
      elixir["renderer"] |> Kernel.<>(".calls") |> File.read!() |> String.split("\n", trim: true)

    assert "--headless-frames" in Jason.decode!(args)
  end

  defp eval(code), do: capture_io(fn -> Code.eval_string(code) end)

  defp last_line(text), do: text |> String.split("\n", trim: true) |> List.last()

  # Runs a tools/milkdrop_pack script; its last stdout line is JSON.
  defp python!(args) do
    {out, status} = System.cmd("python3", args, cd: @tool, stderr_to_stdout: true)
    assert status == 0, out
    out |> last_line() |> Jason.decode!()
  end

  defp manifest_check!(manifest, dir) do
    build_dir = Path.join(Mix.Project.build_path(), "milkdrop_renderer")

    {out, status} =
      System.cmd("cmake", ["--build", build_dir, "--target", "milkdrop_manifest_check", "-j"],
        stderr_to_stdout: true
      )

    assert status == 0, "building milkdrop_manifest_check failed:\n#{out}"

    {out, status} = System.cmd(Path.join(build_dir, "milkdrop_manifest_check"), [manifest, dir])
    assert status == 0, out
    Jason.decode!(out)
  end

  defp await_final do
    receive do
      {:milkdrop_pack, {:downloading, _}} -> await_final()
      {:milkdrop_pack, status} -> status
    after
      10_000 -> flunk("no final pack status")
    end
  end

  defp sha256(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
end
