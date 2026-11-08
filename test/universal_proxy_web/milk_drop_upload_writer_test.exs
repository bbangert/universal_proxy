defmodule UniversalProxyWeb.MilkDropUploadWriterTest do
  # Per-test PubSub, ETS and DETS names: nothing shared between tests.
  use ExUnit.Case, async: true

  alias UniversalProxy.MilkDrop.{Store, UserPresets}
  alias UniversalProxyWeb.MilkDropUploadWriter, as: Writer

  @moduletag :tmp_dir
  @mib 1024 * 1024

  setup %{tmp_dir: tmp_dir} do
    n = System.unique_integer([:positive])
    pubsub = :"upload_writer_test_pubsub_#{n}"
    table = :"upload_writer_test_#{n}"
    start_supervised!({Phoenix.PubSub, name: pubsub})

    store =
      start_supervised!(
        {Store,
         name: nil,
         table: :"upload_writer_test_store_#{n}",
         dets_path: Path.join(tmp_dir, "settings.dets"),
         pubsub: pubsub,
         pack_version: "v1",
         user_sha: &UserPresets.sha256(table, &1)}
      )

    root = Path.join(tmp_dir, "milkdrop")

    server =
      start_supervised!(
        {UserPresets,
         name: nil,
         root: root,
         table: table,
         store: store,
         pubsub: pubsub,
         task_supervisor: start_supervised!(Task.Supervisor),
         free_space: fn _ -> {:ok, %{total_bytes: 1000 * @mib, free_bytes: 900 * @mib}} end,
         pack_textures: fn -> [] end,
         max_upload_bytes: 1000}
      )

    {:ok, server: server, dir: UserPresets.incoming_dir(root)}
  end

  defp init!(ctx, bytes) do
    {:ok, state} = Writer.init(server: ctx.server, bytes: bytes)
    state
  end

  defp files(ctx), do: ctx.dir |> File.ls!() |> Enum.reject(&String.starts_with?(&1, "."))

  test "writes the reserved, server-named 0644 file directly inside incoming/", ctx do
    state = init!(ctx, 6)
    %{path: path, ref: ref} = Writer.meta(state)
    assert is_reference(ref)

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
    paths = for _ <- 1..5, do: Writer.meta(init!(ctx, 1)).path
    assert paths |> Enum.uniq() |> length() == 5
  end

  test "refuses bytes past the reserved size, and anything over the server's cap", ctx do
    state = init!(ctx, 5)
    {:ok, state} = Writer.write_chunk("abcd", state)
    assert {:error, :too_large, state} = Writer.write_chunk("ef", state)

    {:ok, _state} = Writer.close(state, {:error, :too_large})
    assert files(ctx) == []

    assert Writer.init(server: ctx.server, bytes: 1001) == {:error, {:too_large, 1000}}
    assert files(ctx) == []
  end

  test "a cancelled upload deletes its file and frees its reservation", ctx do
    state = init!(ctx, 1000)
    {:ok, state} = Writer.write_chunk("abc", state)
    {:ok, _state} = Writer.close(state, :cancel)
    assert files(ctx) == []
    _ = UserPresets.list(ctx.server)
  end

  test "a finished upload is deleted when its channel exits unclaimed", ctx do
    test = self()

    {pid, ref} =
      spawn_monitor(fn ->
        state = init!(ctx, 3)
        {:ok, state} = Writer.write_chunk("abc", state)
        {:ok, state} = Writer.close(state, :done)
        send(test, {:path, Writer.meta(state).path})
      end)

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    assert_receive {:path, path}, 2_000
    _ = UserPresets.list(ctx.server)
    refute File.exists?(path)
  end

  test "refuse fails init with its reason and writes nothing", ctx do
    assert {:error, :no_space} = Writer.init(refuse: :no_space)
    assert files(ctx) == []
  end
end
