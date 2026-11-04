defmodule Circuits.CEC.TestSupport do
  @moduledoc false

  @golden_path Path.expand("../fixtures/golden.txt", __DIR__)
  @external_resource @golden_path

  @golden @golden_path
          |> File.read!()
          |> String.split("\n", trim: true)
          |> Map.new(fn line ->
            [name, hex] = String.split(line, " ")
            {name, Base.decode16!(hex, case: :lower)}
          end)

  @doc "A struct from test/fixtures/golden.txt (see gen_golden.c)."
  def golden(name), do: Map.fetch!(@golden, name)

  @doc "All golden fixtures whose name starts with `prefix`."
  def golden_prefixed(prefix) do
    for {name, bin} <- @golden, String.starts_with?(name, prefix), do: {name, bin}
  end

  @doc "The stubbed-ioctl build of the helper (built only in MIX_ENV=test)."
  def test_backend_path, do: Path.join(Mix.Project.app_path(), "obj/cec_port_test")

  @doc "True when both helper builds exist (Linux hosts)."
  def helpers_available? do
    match?({:unix, :linux}, :os.type()) and Circuits.CEC.Port.available?() and
      File.regular?(test_backend_path())
  end
end
