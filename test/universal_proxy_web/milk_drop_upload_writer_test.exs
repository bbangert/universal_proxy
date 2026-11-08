defmodule UniversalProxyWeb.MilkDropUploadWriterTest do
  use ExUnit.Case, async: true

  alias UniversalProxyWeb.MilkDropUploadWriter, as: Writer

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    dir = Path.join(tmp_dir, "incoming")
    File.mkdir_p!(dir)
    {:ok, dir: dir, tasks: start_supervised!(Task.Supervisor)}
  end

  defp init!(ctx, max_bytes \\ 100) do
    {:ok, state} = Writer.init(dir: ctx.dir, max_bytes: max_bytes, task_supervisor: ctx.tasks)
    state
  end

  defp wait_until(fun, timeout \\ 2_000) do
    cond do
      fun.() ->
        :ok

      timeout <= 0 ->
        flunk("condition not met in time")

      true ->
        Process.sleep(10)
        wait_until(fun, timeout - 10)
    end
  end

  test "writes a server-named 0644 file directly inside the dir", ctx do
    state = init!(ctx)
    %{path: path} = Writer.meta(state)

    assert Path.dirname(path) == ctx.dir
    assert Path.basename(path) =~ ~r/\Aup-[0-9a-f]{24}\.part\z/
    assert {:ok, %File.Stat{type: :regular, mode: mode}} = File.lstat(path)
    assert Bitwise.band(mode, 0o777) == 0o644

    {:ok, state} = Writer.write_chunk("abc", state)
    {:ok, state} = Writer.write_chunk("def", state)
    {:ok, _state} = Writer.close(state, :done)
    assert File.read!(path) == "abcdef"
  end

  test "each upload gets its own name", ctx do
    paths = for _ <- 1..5, do: Writer.meta(init!(ctx)).path
    assert paths |> Enum.uniq() |> length() == 5
  end

  test "refuses bytes past max_bytes, whatever the client declared", ctx do
    state = init!(ctx, 5)
    {:ok, state} = Writer.write_chunk("abcd", state)
    assert {:error, :too_large, state} = Writer.write_chunk("ef", state)

    {:ok, _state} = Writer.close(state, {:error, :too_large})
    refute File.exists?(Writer.meta(state).path)
  end

  test "a cancelled upload deletes its file", ctx do
    state = init!(ctx)
    {:ok, state} = Writer.write_chunk("abc", state)
    {:ok, _state} = Writer.close(state, :cancel)
    assert File.ls!(ctx.dir) == []
  end

  test "claim renames a finished upload and refuses anything else", ctx do
    state = init!(ctx)
    {:ok, state} = Writer.write_chunk("abc", state)
    {:ok, _state} = Writer.close(state, :done)
    part = Writer.meta(state).path

    assert {:ok, claimed} = Writer.claim(part)
    assert Path.dirname(claimed) == ctx.dir
    assert Path.basename(claimed) == Path.basename(part, ".part")
    assert File.read!(claimed) == "abc"
    refute File.exists?(part)

    assert {:error, :enoent} = Writer.claim(part)
    assert {:error, :not_an_upload} = Writer.claim(claimed)
    assert {:error, :not_an_upload} = Writer.claim(Path.join(ctx.dir, "a.milk.part"))
  end

  test "an unclaimed upload is deleted when its owner exits; a claimed one isn't", ctx do
    test = self()

    run = fn claim? ->
      {pid, ref} =
        spawn_monitor(fn ->
          state = init!(ctx)
          {:ok, state} = Writer.write_chunk("abc", state)
          {:ok, state} = Writer.close(state, :done)
          path = Writer.meta(state).path
          path = if claim?, do: elem(Writer.claim(path), 1), else: path
          send(test, {:path, path})
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      assert_receive {:path, path}
      path
    end

    unclaimed = run.(false)
    wait_until(fn -> not File.exists?(unclaimed) end)

    claimed = run.(true)
    Process.sleep(50)
    assert File.read!(claimed) == "abc"
  end

  test "refuse fails init with its reason and writes nothing", ctx do
    assert {:error, :no_space} = Writer.init(refuse: :no_space)
    assert File.ls!(ctx.dir) == []
  end

  test "a missing dir fails init", ctx do
    assert {:error, {:io, :enoent}} =
             Writer.init(
               dir: Path.join(ctx.dir, "gone"),
               max_bytes: 10,
               task_supervisor: ctx.tasks
             )
  end
end
