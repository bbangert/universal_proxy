defmodule UniversalProxy.MilkDrop.UserPresetsTest do
  # Per-test PubSub, ETS and DETS names: nothing shared between tests.
  use ExUnit.Case, async: true

  import Bitwise
  import ExUnit.CaptureLog
  import UniversalProxy.MilkDropUploadFixtures

  alias UniversalProxy.MilkDrop
  alias UniversalProxy.MilkDrop.{Store, UserPresets}

  @moduletag :tmp_dir
  @mib 1024 * 1024
  @quota_bytes 64 * 1024 * 1024
  @roomy {:ok, %{total_bytes: 1000 * @mib, free_bytes: 900 * @mib}}

  setup %{tmp_dir: tmp_dir} do
    n = System.unique_integer([:positive])
    pubsub = :"user_presets_test_pubsub_#{n}"
    table = :"user_presets_test_#{n}"
    start_supervised!({Phoenix.PubSub, name: pubsub})

    store =
      start_supervised!(
        {Store,
         name: nil,
         table: :"user_presets_test_store_#{n}",
         dets_path: Path.join(tmp_dir, "settings.dets"),
         pubsub: pubsub,
         pack_version: "v1",
         user_sha: &UserPresets.sha256(table, &1)}
      )

    Phoenix.PubSub.subscribe(pubsub, MilkDrop.user_presets_topic())
    root = Path.join(tmp_dir, "milkdrop")

    {:ok,
     root: root,
     user: UserPresets.user_dir(root),
     incoming: UserPresets.incoming_dir(root),
     store: store,
     pubsub: pubsub,
     table: table,
     tasks: start_supervised!(Task.Supervisor)}
  end

  defp start_library(ctx, opts \\ []) do
    opts =
      Keyword.merge(
        [
          name: nil,
          root: ctx.root,
          table: ctx.table,
          store: ctx.store,
          pubsub: ctx.pubsub,
          task_supervisor: ctx.tasks,
          free_space: fn _path -> @roomy end,
          pack_textures: fn -> [] end
        ],
        opts
      )

    start_supervised!({UserPresets, opts})
  end

  defp restart_library(ctx, opts \\ []) do
    :ok = stop_supervised(UserPresets)
    start_library(ctx, opts)
  end

  # An upload as the web UI leaves it: a file under incoming/.
  defp upload(ctx, client_name, data) do
    File.mkdir_p!(ctx.incoming)
    path = Path.join(ctx.incoming, "upload-#{System.unique_integer([:positive])}")
    File.write!(path, data)
    {client_name, path}
  end

  defp import!(server, uploads) do
    assert {:ok, results} = UserPresets.import(server, uploads)
    results
  end

  defp statuses(results), do: Enum.map(results, &{&1.entry || &1.upload, &1.status})

  defp manifest(ctx),
    do: ctx.user |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()

  defp preset_path(ctx, name), do: Path.join([ctx.user, "presets", name])
  defp texture_path(ctx, name), do: Path.join([ctx.user, "textures", name])

  defp sha(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp mode(path), do: File.stat!(path).mode &&& 0o777

  describe "importing" do
    test "a single .milk is installed, listed and announced, its upload consumed", ctx do
      server = start_library(ctx)
      data = milk()
      {_name, path} = up = upload(ctx, "My  Preset.MILK", data)

      assert [
               %{
                 upload: "My  Preset.MILK",
                 kind: :preset,
                 name: "My Preset.milk",
                 id: "user/My Preset.milk",
                 status: :added,
                 sha256: sha,
                 size: size,
                 warnings: []
               } = result
             ] = import!(server, [up])

      refute Map.has_key?(result, :data)
      assert sha == sha(data) and size == byte_size(data)
      refute File.exists?(path)

      file = preset_path(ctx, "My Preset.milk")
      assert File.read!(file) == data
      assert mode(file) == 0o644

      assert %{
               "format" => 1,
               "version" => "user",
               "presets" => [
                 %{
                   "file" => "My Preset.milk",
                   "tags" => ["uploaded"],
                   "sha256" => ^sha,
                   "size" => ^size,
                   "uploaded_at" => at
                 }
               ],
               "textures" => []
             } = manifest(ctx)

      assert is_integer(at)

      assert_receive {:milkdrop_user_presets,
                      %{added: ["user/My Preset.milk"], replaced: [], removed: [], updated: []}}

      assert %{
               presets: [
                 %{
                   id: "user/My Preset.milk",
                   name: "My Preset.milk",
                   sha256: ^sha,
                   high_frequency: false,
                   uploaded_at: %DateTime{}
                 }
               ],
               textures: []
             } = UserPresets.list(server)

      assert %{bytes: ^size, presets: 1, textures: 0, quota: %{bytes: @quota_bytes}} =
               UserPresets.usage(server)

      assert UserPresets.sha256(ctx.table, "user/My Preset.milk") == sha
      assert UserPresets.sha256(ctx.table, "user/other.milk") == nil
    end

    test "a zip of presets and textures is flattened into presets/ and textures/", ctx do
      server = start_library(ctx, pack_textures: fn -> ["Stars.jpg"] end)

      bin =
        zip([
          [name: "pack/"],
          [name: "pack/presets/One.milk", data: milk(), method: :deflate],
          [name: "pack/textures/stars.png", data: png(16, 16)],
          [name: "pack/textures/moon.jpg", data: jpeg(16, 16)],
          [name: "pack/readme.txt", data: "hi"],
          [name: "__MACOSX/pack/._One.milk", data: "junk"]
        ])

      results = import!(server, [upload(ctx, "pack.zip", bin)])

      assert statuses(results) == [
               {"pack/presets/One.milk", :added},
               {"pack/textures/stars.png", :added},
               {"pack/textures/moon.jpg", :added},
               {"pack/readme.txt", :ignored}
             ]

      assert [_, %{warnings: [:texture_shadowed]}, %{warnings: []}, _] = results
      assert File.read!(preset_path(ctx, "One.milk")) == milk()
      assert File.regular?(texture_path(ctx, "stars.png"))
      assert mode(texture_path(ctx, "moon.jpg")) == 0o644

      assert ctx.user |> Path.join("textures") |> File.ls!() |> Enum.sort() ==
               ~w(moon.jpg stars.png)

      assert %{"textures" => [%{"file" => "moon.jpg"}, %{"file" => "stars.png"}]} = manifest(ctx)
      assert_receive {:milkdrop_user_presets, %{added: ["user/One.milk"], textures: textures}}
      assert Enum.sort(textures) == ~w(moon.jpg stars.png)
      assert %{presets: 1, textures: 2} = UserPresets.usage(server)
    end

    test "a hostile zip writes nothing", ctx do
      server = start_library(ctx)

      for {bin, reason} <- [
            {zip([[name: "../x.milk", data: milk()]]), {:unsafe_path, "../x.milk"}},
            {zip([[name: "a.milk", data: milk(), ext_attr: 0o120777 <<< 16]]),
             {:not_regular_file, "a.milk"}},
            {zip([[name: "a.milk", data: milk(), flags: 0x0801]]), {:encrypted, "a.milk"}}
          ] do
        assert [%{kind: :archive, status: {:rejected, ^reason}}] =
                 import!(server, [upload(ctx, "evil.zip", bin)])
      end

      assert File.ls!(Path.join(ctx.user, "presets")) == []
      assert File.ls!(ctx.incoming) == []
      refute_received {:milkdrop_user_presets, _}
    end

    test "replaced, unchanged and renamed replacements", ctx do
      server = start_library(ctx)
      [%{status: :added}] = import!(server, [upload(ctx, "Foo.milk", milk())])
      assert_receive {:milkdrop_user_presets, %{added: ["user/Foo.milk"]}}
      :ok = UserPresets.set_high_frequency(server, "user/Foo.milk", true)
      assert_receive {:milkdrop_user_presets, %{updated: ["user/Foo.milk"]}}

      # The same content: nothing to write.
      assert [%{status: :unchanged, name: "Foo.milk"}] =
               import!(server, [upload(ctx, "foo.milk", milk())])

      refute_receive {:milkdrop_user_presets, _}, 50

      # New content, same name: replaced in place, still flagged.
      new = milk("x=1\r\n")

      assert [%{status: :replaced, name: "Foo.milk", replaces: "Foo.milk"}] =
               import!(server, [upload(ctx, "Foo.milk", new)])

      assert File.read!(preset_path(ctx, "Foo.milk")) == new
      assert_receive {:milkdrop_user_presets, %{replaced: ["user/Foo.milk"], added: []}}
      assert [%{high_frequency: true, sha256: sha}] = UserPresets.list(server).presets
      assert sha == sha(new)

      # New content in another case: the old file and id go, and with the
      # id its selection entries.
      {:ok, _} = Store.favourite(ctx.store, "user/Foo.milk", true)
      {:ok, _} = Store.playlist_add(ctx.store, "user/Foo.milk")
      newer = milk("y=2\r\n")

      assert [%{status: :replaced, name: "FOO.milk", replaces: "Foo.milk"}] =
               import!(server, [upload(ctx, "FOO.milk", newer)])

      refute File.exists?(preset_path(ctx, "Foo.milk"))
      assert File.read!(preset_path(ctx, "FOO.milk")) == newer

      assert_receive {:milkdrop_user_presets,
                      %{removed: ["user/Foo.milk"], added: ["user/FOO.milk"], replaced: []}}

      assert UserPresets.sha256(ctx.table, "user/Foo.milk") == nil
      assert UserPresets.sha256(ctx.table, "user/FOO.milk") == sha(newer)
      assert %{"presets" => [%{"file" => "FOO.milk", "tags" => tags}]} = manifest(ctx)
      assert "high_frequency" in tags
      assert %{favourites: [], playlist: []} = Store.selection(ctx.store)
    end

    test "replacing a preset clears its skips; the lock stays", ctx do
      server = start_library(ctx)
      [_] = import!(server, [upload(ctx, "a.milk", milk())])
      :ok = Store.skip(ctx.store, "v1", "user/a.milk", "draw")
      {:ok, _} = Store.update(ctx.store, %{locked: "user/a.milk"})
      assert Store.skipped(ctx.store, "v1") == %{"user/a.milk" => "draw"}

      [%{status: :replaced}] = import!(server, [upload(ctx, "a.milk", milk("x=1"))])

      assert Store.skipped(ctx.store, "v1") == %{}
      assert Store.settings(ctx.store).locked == "user/a.milk"
    end

    test "uploads not directly in incoming/ are refused and left alone", ctx do
      server = start_library(ctx)
      outside = Path.join(ctx.root, "elsewhere.milk")
      File.write!(outside, milk())
      hidden = Path.join(ctx.incoming, ".hidden")
      File.write!(hidden, milk())
      link = Path.join(ctx.incoming, "link")
      File.ln_s!(outside, link)

      results =
        import!(server, [
          {"a.milk", outside},
          {"b.milk", Path.join([ctx.incoming, "..", "elsewhere.milk"])},
          {"c.milk", hidden},
          {"d.milk", link}
        ])

      assert Enum.map(results, & &1.status) == List.duplicate({:rejected, :bad_source}, 4)
      assert File.exists?(outside)
      assert File.ls!(Path.join(ctx.user, "presets")) == []
    end

    test "an upload over the size cap is refused unopened", ctx do
      server = start_library(ctx, max_upload_bytes: 100)

      assert [%{kind: :archive, status: {:rejected, :too_large}}] =
               import!(server, [upload(ctx, "big.zip", :binary.copy("x", 101))])
    end
  end

  describe "quota" do
    test "files past a limit are rejected in order; later ones may fit", ctx do
      server = start_library(ctx, quota: %{presets: 2})

      results =
        import!(server, [
          upload(ctx, "a.milk", milk()),
          upload(ctx, "b.milk", milk()),
          upload(ctx, "c.milk", milk())
        ])

      assert Enum.map(results, & &1.status) == [:added, :added, {:rejected, :quota}]

      # A replacement doesn't add to the count.
      assert [%{status: :replaced}] = import!(server, [upload(ctx, "a.milk", milk("x=1"))])
      refute File.exists?(preset_path(ctx, "c.milk"))
    end

    test "the byte quota counts a replacement's size difference", ctx do
      small = milk()
      big = milk(String.duplicate("x=1\r\n", 100))
      server = start_library(ctx, quota: %{bytes: byte_size(small) + byte_size(big)})

      results =
        import!(server, [
          upload(ctx, "a.milk", small),
          upload(ctx, "b.milk", big),
          upload(ctx, "c.milk", small)
        ])

      assert Enum.map(results, & &1.status) == [:added, :added, {:rejected, :quota}]

      # Growing a: over; shrinking b makes room for c.
      results =
        import!(server, [
          upload(ctx, "a.milk", big),
          upload(ctx, "b.milk", milk("y=2")),
          upload(ctx, "c.milk", small)
        ])

      assert Enum.map(results, & &1.status) == [{:rejected, :quota}, :replaced, :added]
    end

    test "the texture quota", ctx do
      server = start_library(ctx, quota: %{textures: 1})
      bin = zip([[name: "a.png", data: png(4, 4)], [name: "b.png", data: png(4, 4)]])

      assert statuses(import!(server, [upload(ctx, "t.zip", bin)])) == [
               {"a.png", :added},
               {"b.png", {:rejected, :quota}}
             ]
    end
  end

  # Until `n` requests wait for the server's free-space measurement.
  defp await_waiting(server, n, timeout \\ 2_000) do
    cond do
      length(:sys.get_state(server).budget.waiting) >= n -> :ok
      timeout <= 0 -> flunk("#{n} admissions never queued")
      true -> Process.sleep(5) && await_waiting(server, n, timeout - 5)
    end
  end

  defp incoming_files(ctx),
    do: ctx.incoming |> File.ls!() |> Enum.reject(&String.starts_with?(&1, "."))

  # `room` bytes above the 200 MiB floor of a 1000 MiB filesystem, less
  # the uploads, staging and library files on disk, as `df` would see them.
  defp du_free(ctx, room) do
    fn _path ->
      used =
        [ctx.incoming, Path.join(ctx.user, "presets"), Path.join(ctx.user, "textures")]
        |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*"), match_dot: true))
        |> Enum.map(fn path ->
          case File.lstat(path) do
            {:ok, %File.Stat{type: :regular, size: size}} -> size
            _ -> 0
          end
        end)
        |> Enum.sum()

      {:ok, %{total_bytes: 1000 * @mib, free_bytes: 200 * @mib + room - used}}
    end
  end

  describe "free space" do
    test "an import must leave max(200 MiB, 10%) free", ctx do
      data = milk()
      # The two uploads take two of the three files' room.
      server = start_library(ctx, free_space: du_free(ctx, 3 * byte_size(data)))

      # The first fits exactly; the second would dip under the floor.
      results = import!(server, [upload(ctx, "a.milk", data), upload(ctx, "b.milk", data)])
      assert Enum.map(results, & &1.status) == [:added, {:rejected, :no_space}]

      # On a large filesystem the floor is 10%.
      server =
        restart_library(ctx,
          free_space: fn _path -> {:ok, %{total_bytes: 4000 * @mib, free_bytes: 400 * @mib}} end
        )

      assert [%{status: {:rejected, :no_space}}] =
               import!(server, [upload(ctx, "c.milk", data)])
    end

    test "below the floor after staging, nothing is installed", ctx do
      counter = :counters.new(1, [])

      free_space = fn _path ->
        :counters.add(counter, 1, 1)

        free = if :counters.get(counter, 1) == 1, do: 900 * @mib, else: 100 * @mib
        {:ok, %{total_bytes: 1000 * @mib, free_bytes: free}}
      end

      server = start_library(ctx, free_space: free_space)

      assert [%{status: {:rejected, :no_space}}] =
               import!(server, [upload(ctx, "a.milk", milk())])

      assert File.ls!(Path.join(ctx.user, "presets")) == []
      assert File.ls!(ctx.incoming) == []
    end

    test "an unknown free space fails the import", ctx do
      server = start_library(ctx, free_space: fn _path -> {:error, :no_df} end)
      {_name, path} = up = upload(ctx, "a.milk", milk())

      assert UserPresets.import(server, [up]) == {:error, {:free_space, :no_df}}
      refute File.exists?(path)
    end

    test "the default measures the filesystem with df", ctx do
      server =
        start_supervised!(
          {UserPresets,
           name: nil,
           root: ctx.root,
           table: ctx.table,
           store: ctx.store,
           pubsub: ctx.pubsub,
           task_supervisor: ctx.tasks,
           pack_textures: fn -> [] end,
           min_free_bytes: 0,
           min_free_pct: 0}
        )

      assert [%{status: :added}] = import!(server, [upload(ctx, "a.milk", milk())])
    end
  end

  describe "the import task" do
    test "is bounded: a timed-out import installs nothing and frees the server", ctx do
      test = self()

      slow = fn _path ->
        send(test, :measuring)
        Process.sleep(5_000)
        @roomy
      end

      server = start_library(ctx, free_space: slow, import_timeout_ms: 100)
      {_name, path} = up = upload(ctx, "a.milk", milk())
      caller = Task.async(fn -> UserPresets.import(server, [up]) end)

      assert_receive :measuring
      assert UserPresets.delete(server, "user/a.milk") == {:error, :busy}
      assert UserPresets.import(server, []) == {:error, :busy}
      # Reads are served meanwhile.
      assert UserPresets.list(server) == %{presets: [], textures: []}

      assert capture_log(fn -> assert Task.await(caller) == {:error, :timeout} end) =~
               "took over 100 ms"

      refute File.exists?(path)
      assert File.ls!(ctx.incoming) == []
      assert File.ls!(Path.join(ctx.user, "presets")) == []
      assert UserPresets.delete(server, "user/a.milk") == {:error, :not_found}
    end

    test "a crash is reported and cleaned up", ctx do
      server = start_library(ctx, free_space: fn _path -> raise "boom" end)
      {_name, path} = up = upload(ctx, "a.milk", milk())

      log =
        capture_log(fn ->
          assert {:error, {:crashed, {%RuntimeError{message: "boom"}, _}}} =
                   UserPresets.import(server, [up])
        end)

      assert log =~ "crashed"
      refute File.exists?(path)
      assert File.ls!(ctx.incoming) == []
    end
  end

  describe "deleting" do
    test "removes the file, its skips and the lock on it", ctx do
      server = start_library(ctx)
      bin = zip([[name: "a.milk", data: milk()], [name: "b.milk", data: milk()]])
      [_, _] = import!(server, [upload(ctx, "p.zip", bin)])
      assert_receive {:milkdrop_user_presets, %{added: _}}

      :ok = Store.skip(ctx.store, "v1", "user/a.milk", "draw")
      :ok = Store.skip(ctx.store, "v1", "user/b.milk", "draw")
      :ok = Store.skip(ctx.store, "v1", "pack.milk", "draw")
      {:ok, _} = Store.update(ctx.store, %{locked: "user/a.milk"})
      {:ok, _} = Store.hide(ctx.store, "user/a.milk", true)
      {:ok, _} = Store.favourite(ctx.store, "user/b.milk", true)

      assert :ok = UserPresets.delete(server, "user/a.milk")

      refute File.exists?(preset_path(ctx, "a.milk"))
      assert %{"presets" => [%{"file" => "b.milk"}]} = manifest(ctx)
      assert_receive {:milkdrop_user_presets, %{removed: ["user/a.milk"], added: []}}
      assert UserPresets.sha256(ctx.table, "user/a.milk") == nil
      assert Store.settings(ctx.store).locked == nil
      assert Store.skipped(ctx.store, "v1") == %{"user/b.milk" => "draw", "pack.milk" => "draw"}
      assert [%{id: "user/b.milk"}] = UserPresets.list(server).presets
      assert %{hidden: [], favourites: ["user/b.milk"]} = Store.selection(ctx.store)
    end

    test "a lock on another preset stays", ctx do
      server = start_library(ctx)
      [_] = import!(server, [upload(ctx, "a.milk", milk())])
      {:ok, _} = Store.update(ctx.store, %{locked: "pack.milk"})

      :ok = UserPresets.delete(server, "user/a.milk")
      assert Store.settings(ctx.store).locked == "pack.milk"
    end

    test "only library ids are resolved", ctx do
      server = start_library(ctx)
      File.write!(Path.join(ctx.root, "victim.milk"), milk())

      for id <- ["user/../victim.milk", "../victim.milk", "victim.milk", "user/", "user/x.milk"] do
        assert UserPresets.delete(server, id) == {:error, :not_found}
      end

      assert File.exists?(Path.join(ctx.root, "victim.milk"))
      assert UserPresets.delete_texture(server, "../../victim.milk") == {:error, :not_found}
    end

    test "a texture", ctx do
      server = start_library(ctx)
      [_] = import!(server, [upload(ctx, "t.zip", zip([[name: "t.png", data: png(4, 4)]]))])
      assert_receive {:milkdrop_user_presets, _}

      assert :ok = UserPresets.delete_texture(server, "t.png")
      refute File.exists?(texture_path(ctx, "t.png"))
      assert %{"textures" => []} = manifest(ctx)
      assert_receive {:milkdrop_user_presets, %{textures: ["t.png"], removed: []}}
    end
  end

  test "set_high_frequency/3 toggles the tag", ctx do
    server = start_library(ctx)
    [_] = import!(server, [upload(ctx, "a.milk", milk())])
    assert_receive {:milkdrop_user_presets, %{added: _}}

    assert :ok = UserPresets.set_high_frequency(server, "user/a.milk", true)
    assert %{"presets" => [%{"tags" => ["uploaded", "high_frequency"]}]} = manifest(ctx)
    assert_receive {:milkdrop_user_presets, %{updated: ["user/a.milk"]}}
    assert [%{high_frequency: true}] = UserPresets.list(server).presets

    # Unchanged: no write, no broadcast.
    assert :ok = UserPresets.set_high_frequency(server, "user/a.milk", true)
    refute_receive {:milkdrop_user_presets, _}, 50

    assert :ok = UserPresets.set_high_frequency(server, "user/a.milk", false)
    assert %{"presets" => [%{"tags" => ["uploaded"]}]} = manifest(ctx)
    assert UserPresets.set_high_frequency(server, "user/b.milk", true) == {:error, :not_found}
  end

  describe "at start" do
    test "incoming/ is emptied", ctx do
      File.mkdir_p!(Path.join([ctx.incoming, ".staging-1", "presets"]))
      File.write!(Path.join([ctx.incoming, ".staging-1", "presets", "a.milk"]), milk())
      File.write!(Path.join(ctx.incoming, "upload-1"), "stale")

      start_library(ctx)
      assert File.ls!(ctx.incoming) == []
    end

    test "the library is rebuilt from the directories, keeping the manifest's metadata", ctx do
      server = start_library(ctx)
      bin = zip([[name: "a.milk", data: milk()], [name: "t.png", data: png(4, 4)]])
      [_, _] = import!(server, [upload(ctx, "p.zip", bin)])
      :ok = UserPresets.set_high_frequency(server, "user/a.milk", true)
      [%{uploaded_at: uploaded_at}] = UserPresets.list(server).presets

      # Out-of-band changes: a file the manifest doesn't know (an import cut
      # short), and entries that are not valid uploads.
      presets = Path.join(ctx.user, "presets")
      File.write!(Path.join(presets, "b.milk"), milk("z=3"))
      File.write!(Path.join(presets, "A.milk"), milk())
      File.write!(Path.join(presets, "bad?.milk"), milk())
      File.write!(Path.join(presets, "junk.milk"), "not a preset")
      File.write!(Path.join(presets, "notes.txt"), "hi")
      File.mkdir_p!(Path.join(presets, "dir.milk"))
      File.ln_s!("/etc/passwd", Path.join(ctx.user, "textures/link.png"))
      File.write!(Path.join(ctx.user, "textures/main.png"), png(4, 4))

      {server, log} = with_log(fn -> restart_library(ctx) end)
      assert log =~ "not a valid upload"

      # A case twin loses to the name the manifest knows.
      assert File.ls!(presets) |> Enum.sort() == ["a.milk", "b.milk"]
      assert File.ls!(Path.join(ctx.user, "textures")) == ["t.png"]

      assert %{
               "presets" => [
                 %{"file" => "a.milk", "tags" => ["uploaded", "high_frequency"]},
                 %{"file" => "b.milk", "tags" => ["uploaded"]}
               ],
               "textures" => [%{"file" => "t.png"}]
             } = manifest(ctx)

      assert [%{id: "user/a.milk", uploaded_at: ^uploaded_at}, %{id: "user/b.milk"}] =
               UserPresets.list(server).presets

      assert UserPresets.sha256(ctx.table, "user/b.milk") == sha(milk("z=3"))
    end
  end

  describe "failures" do
    # The manifest's temporary file replaced by a directory: writes fail.
    defp block_manifest(ctx), do: File.mkdir_p!(Path.join(ctx.user, ".manifest.json.tmp"))
    defp unblock_manifest(ctx), do: File.rm_rf!(Path.join(ctx.user, ".manifest.json.tmp"))

    # A directory where a file was: deleting it fails.
    defp pin_file(path) do
      File.rm!(path)
      File.mkdir_p!(Path.join(path, "x"))
    end

    defp unpin_file(path), do: File.rm_rf!(path)

    defp wait_until(fun, timeout \\ 2_000) do
      cond do
        fun.() -> :ok
        timeout <= 0 -> flunk("condition not met in time")
        true -> Process.sleep(10) && wait_until(fun, timeout - 10)
      end
    end

    @tag capture_log: true
    test "an unpublished import fails, and the same upload again repairs it", ctx do
      server = start_library(ctx, retry_ms: 600_000)
      block_manifest(ctx)

      assert [%{status: {:rejected, {:manifest, {:io, :eisdir}}}}] =
               import!(server, [upload(ctx, "a.milk", milk())])

      # On disk and in the library, not yet announced.
      assert File.regular?(preset_path(ctx, "a.milk"))
      refute_receive {:milkdrop_user_presets, _}, 50

      unblock_manifest(ctx)
      assert [%{status: :unchanged}] = import!(server, [upload(ctx, "a.milk", milk())])
      assert %{"presets" => [%{"file" => "a.milk"}]} = manifest(ctx)
      assert_receive {:milkdrop_user_presets, %{added: ["user/a.milk"]}}
    end

    @tag capture_log: true
    test "an unpublished delete fails and is published by the retry", ctx do
      server = start_library(ctx, retry_ms: 50)
      [_] = import!(server, [upload(ctx, "a.milk", milk())])
      assert_receive {:milkdrop_user_presets, %{added: _}}
      block_manifest(ctx)

      assert UserPresets.delete(server, "user/a.milk") == {:error, {:manifest, {:io, :eisdir}}}
      refute File.exists?(preset_path(ctx, "a.milk"))
      assert %{"presets" => [_]} = manifest(ctx)
      refute_receive {:milkdrop_user_presets, _}, 100

      unblock_manifest(ctx)
      assert_receive {:milkdrop_user_presets, %{removed: ["user/a.milk"]}}, 2_000
      assert %{"presets" => []} = manifest(ctx)
    end

    @tag capture_log: true
    test "a failed flag write fails and changes nothing", ctx do
      server = start_library(ctx, retry_ms: 600_000)
      [_] = import!(server, [upload(ctx, "a.milk", milk())])
      block_manifest(ctx)

      assert {:error, {:manifest, _}} =
               UserPresets.set_high_frequency(server, "user/a.milk", true)

      assert [%{high_frequency: false}] = UserPresets.list(server).presets
    end

    @tag capture_log: true
    test "a file that can't be deleted stays, with its lock and skips", ctx do
      server = start_library(ctx)
      [_] = import!(server, [upload(ctx, "a.milk", milk())])
      :ok = Store.skip(ctx.store, "v1", "user/a.milk", "draw")
      {:ok, _} = Store.update(ctx.store, %{locked: "user/a.milk"})
      assert_receive {:milkdrop_user_presets, %{added: _}}
      pin_file(preset_path(ctx, "a.milk"))

      assert {:error, {:io, _reason}} = UserPresets.delete(server, "user/a.milk")
      assert [%{id: "user/a.milk"}] = UserPresets.list(server).presets
      assert %{"presets" => [%{"file" => "a.milk"}]} = manifest(ctx)
      assert Store.settings(ctx.store).locked == "user/a.milk"
      refute_receive {:milkdrop_user_presets, _}, 50

      # One already gone counts as deleted.
      unpin_file(preset_path(ctx, "a.milk"))
      assert :ok = UserPresets.delete(server, "user/a.milk")
      assert Store.settings(ctx.store).locked == nil
    end

    @tag capture_log: true
    test "a superseded file that can't be deleted is kept until a retry deletes it", ctx do
      server = start_library(ctx, retry_ms: 50)
      [_] = import!(server, [upload(ctx, "Foo.milk", milk())])
      {:ok, _} = Store.update(ctx.store, %{locked: "user/Foo.milk"})
      assert_receive {:milkdrop_user_presets, %{added: _}}
      pin_file(preset_path(ctx, "Foo.milk"))

      assert [%{status: :replaced, name: "FOO.milk"}] =
               import!(server, [upload(ctx, "FOO.milk", milk("x=1"))])

      assert_receive {:milkdrop_user_presets, %{added: ["user/FOO.milk"], removed: []}}

      assert ["user/FOO.milk", "user/Foo.milk"] =
               Enum.map(UserPresets.list(server).presets, & &1.id)

      assert Store.settings(ctx.store).locked == "user/Foo.milk"

      unpin_file(preset_path(ctx, "Foo.milk"))
      assert_receive {:milkdrop_user_presets, %{removed: ["user/Foo.milk"]}}, 2_000
      assert [%{id: "user/FOO.milk"}] = UserPresets.list(server).presets
      assert %{"presets" => [%{"file" => "FOO.milk"}]} = manifest(ctx)
      wait_until(fn -> Store.settings(ctx.store).locked == nil end)
    end
  end

  describe "recovery" do
    @tag capture_log: true
    test "a queued removal never deletes a file installed under that name later", ctx do
      server = start_library(ctx, retry_ms: 600_000)
      [_] = import!(server, [upload(ctx, "Foo.milk", milk())])
      pin_file(preset_path(ctx, "Foo.milk"))

      # The removal of Foo.milk fails and is queued.
      [%{status: :replaced}] = import!(server, [upload(ctx, "FOO.milk", milk("x=1"))])

      # Gone by other means, then uploaded again under the same name.
      unpin_file(preset_path(ctx, "Foo.milk"))
      new = milk("y=2")

      assert [%{status: :replaced, name: "Foo.milk", replaces: "Foo.milk"}] =
               import!(server, [upload(ctx, "Foo.milk", new)])

      send(server, :retry)
      _ = :sys.get_state(server)
      assert File.read!(preset_path(ctx, "Foo.milk")) == new
      assert "user/Foo.milk" in Enum.map(UserPresets.list(server).presets, & &1.id)
    end

    @tag capture_log: true
    test "Store clean-up the Store refused is retried until it is done", ctx do
      name = :"#{ctx.table}_store"
      path = Path.join(ctx.root, "named.dets")

      named_store = fn ->
        start_supervised!(
          Supervisor.child_spec(
            {Store,
             name: name,
             table: name,
             dets_path: path,
             pack_version: "v1",
             user_sha: &UserPresets.sha256(ctx.table, &1)},
            id: :named_store
          )
        )
      end

      server = start_library(ctx, store: name, retry_ms: 50)
      [_] = import!(server, [upload(ctx, "a.milk", milk())])
      named_store.()
      {:ok, _} = Store.update(name, %{locked: "user/a.milk"})
      :ok = stop_supervised(:named_store)

      # Deleted while the Store is down: its lock must still go.
      assert :ok = UserPresets.delete(server, "user/a.milk")
      Process.sleep(120)
      named_store.()
      wait_until(fn -> Store.settings(name).locked == nil end)
    end

    @tag capture_log: true
    test "a manifest repaired after a failed start-up rewrite is announced", ctx do
      File.mkdir_p!(Path.join(ctx.user, "presets"))
      File.write!(preset_path(ctx, "a.milk"), milk())
      block_manifest(ctx)

      start_library(ctx, retry_ms: 50)
      assert_receive {:milkdrop_user_presets_started, %{presets: 1}}
      refute File.exists?(Path.join(ctx.user, "manifest.json"))

      unblock_manifest(ctx)

      assert_receive {:milkdrop_user_presets,
                      %{added: [], replaced: [], removed: [], updated: [], textures: []}},
                     2_000

      assert %{"presets" => [%{"file" => "a.milk"}]} = manifest(ctx)
    end
  end

  describe "round 3" do
    @tag capture_log: true
    test "an identical re-upload while the manifest stays unwritable is not a success", ctx do
      server = start_library(ctx, retry_ms: 600_000)
      block_manifest(ctx)
      [%{status: {:rejected, {:manifest, _}}}] = import!(server, [upload(ctx, "a.milk", milk())])

      assert [%{status: {:rejected, {:manifest, {:io, :eisdir}}}}] =
               import!(server, [upload(ctx, "a.milk", milk())])
    end

    @tag capture_log: true
    test "a replacement that fails to install doesn't lend its room to later files", ctx do
      small = milk()
      big = milk(String.duplicate("x=1\r\n", 100))
      server = start_library(ctx, quota: %{bytes: byte_size(small) + byte_size(big)})
      [%{status: :added}] = import!(server, [upload(ctx, "a.milk", big)])

      # Staging counts a's shrinking to make room for b; a's rename fails.
      pin_file(preset_path(ctx, "a.milk"))

      results = import!(server, [upload(ctx, "a.milk", small), upload(ctx, "b.milk", big)])

      assert Enum.map(results, & &1.status) == [
               {:rejected, {:io, :install_failed}},
               {:rejected, :quota}
             ]

      refute File.exists?(preset_path(ctx, "b.milk"))
      assert %{presets: 1} = UserPresets.usage(server)
    end

    @tag capture_log: true
    test "after a restart the later of two case twins wins, within the same second", ctx do
      server = start_library(ctx, retry_ms: 600_000)
      [_] = import!(server, [upload(ctx, "FOO.milk", milk())])
      pin_file(preset_path(ctx, "FOO.milk"))
      new = milk("x=1")
      [%{status: :replaced}] = import!(server, [upload(ctx, "Foo.milk", new)])

      # FOO.milk's removal is still queued when the device restarts.
      unpin_file(preset_path(ctx, "FOO.milk"))
      File.write!(preset_path(ctx, "FOO.milk"), milk())
      assert %{"presets" => [%{"seq" => 1}, %{"seq" => 2}]} = manifest(ctx)

      server = restart_library(ctx)
      assert [%{id: "user/Foo.milk"}] = UserPresets.list(server).presets
      assert File.read!(preset_path(ctx, "Foo.milk")) == new
      refute File.exists?(preset_path(ctx, "FOO.milk"))
    end
  end

  describe "restarts" do
    test "each start is announced", ctx do
      start_library(ctx)
      assert_receive {:milkdrop_user_presets_started, %{presets: 0, textures: 0}}
    end

    test "a lookup during a restart's scan hashes the file", ctx do
      user = UserPresets.user_dir(ctx.root)
      File.mkdir_p!(Path.join(user, "presets"))
      File.write!(Path.join([user, "presets", "a.milk"]), milk())

      # What a starting server's table holds before its scan is in.
      table = :ets.new(:"#{ctx.table}_unready", [:named_table, :public])
      :ets.insert(table, {:user_dir, user})
      assert UserPresets.sha256(table, "user/a.milk") == sha(milk())

      :ets.insert(table, {:ready, true})
      assert UserPresets.sha256(table, "user/a.milk") == nil

      start_library(ctx)
      assert :ets.member(ctx.table, :ready)
      assert UserPresets.sha256(ctx.table, "user/a.milk") == sha(milk())
    end
  end

  test "sha256/2 hashes the file itself when the table is gone", ctx do
    user = UserPresets.user_dir(ctx.root)
    File.mkdir_p!(Path.join(user, "presets"))
    File.write!(Path.join([user, "presets", "a.milk"]), milk())

    assert UserPresets.file_sha256(user, "user/a.milk") == sha(milk())
    assert UserPresets.file_sha256(user, "user/b.milk") == nil
    assert UserPresets.file_sha256(user, "user/../presets/a.milk") == nil
    assert UserPresets.file_sha256(user, "a.milk") == nil
    assert UserPresets.sha256(:no_such_user_presets_table, "user/nope.milk") == nil
  end

  test "the public API degrades while the server is not running" do
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, _, _, _}

    assert UserPresets.list(dead) == %{presets: [], textures: []}

    assert UserPresets.usage(dead) == %{
             bytes: 0,
             presets: 0,
             textures: 0,
             quota: UserPresets.quota()
           }

    assert UserPresets.import(dead, []) == {:error, :not_running}
    assert UserPresets.delete(dead, "user/a.milk") == {:error, :not_running}
    assert UserPresets.delete_texture(dead, "a.png") == {:error, :not_running}
    assert UserPresets.set_high_frequency(dead, "user/a.milk", true) == {:error, :not_running}
    assert UserPresets.reserve(dead, 1) == {:error, :not_running}
    assert UserPresets.claim(dead, make_ref()) == {:error, :not_running}
    assert UserPresets.release(dead, make_ref()) == :ok
  end

  describe "upload reservations" do
    # Floor: max(200 MiB, 10% of 1000 MiB); `room` bytes above it.
    defp free_agent(room) do
      agent = start_supervised!({Agent, fn -> 200 * @mib + room end})
      free = fn _ -> {:ok, %{total_bytes: 1000 * @mib, free_bytes: Agent.get(agent, & &1)}} end
      {agent, free}
    end

    # Runs `fun` in a process that waits for :exit, so it owns what it reserves.
    defp owner(fun) do
      test = self()

      pid =
        spawn(fn ->
          send(test, {:owned, fun.()})

          receive do
            :exit -> :ok
          end
        end)

      assert_receive {:owned, result}, 2_000
      {pid, result}
    end

    defp stop_owner(pid) do
      ref = Process.monitor(pid)
      send(pid, :exit)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
    end

    test "a server-chosen path in incoming/, within the upload cap", ctx do
      {_agent, free} = free_agent(10_000)
      server = start_library(ctx, max_upload_bytes: 1000, free_space: free)

      assert {:ok, %{ref: ref, path: path}} = UserPresets.reserve(server, 1000)
      assert is_reference(ref)
      assert Path.dirname(path) == ctx.incoming
      assert Path.basename(path) =~ ~r/\Aup-[0-9a-f]{24}\.part\z/
      refute File.exists?(path)

      assert UserPresets.reserve(server, 1001) == {:error, {:too_large, 1000}}

      server = restart_library(ctx, free_space: fn _ -> {:error, :df_failed} end)
      assert UserPresets.reserve(server, 1) == {:error, {:free_space, :df_failed}}
    end

    test "reservations share the room, each byte counted once", ctx do
      {agent, free} = free_agent(3000)
      server = start_library(ctx, free_space: free)

      {:ok, a} = UserPresets.reserve(server, 1000)
      {:ok, _b} = UserPresets.reserve(server, 1000)
      assert UserPresets.reserve(server, 1001) == {:error, :no_space}

      # `a` written in full: df sees it, and it still counts once.
      File.write!(a.path, :binary.copy("x", 1000))
      Agent.update(agent, &(&1 - 1000))
      assert {:ok, c} = UserPresets.reserve(server, 1000)
      assert UserPresets.reserve(server, 1) == {:error, :no_space}

      :ok = UserPresets.release(server, c.ref)
      assert {:ok, _d} = UserPresets.reserve(server, 1000)
    end

    test "release and the owner's exit delete the file and free the room", ctx do
      {agent, free} = free_agent(1000)
      server = start_library(ctx, free_space: free)

      {:ok, r} = UserPresets.reserve(server, 1000)
      File.write!(r.path, "x")
      :ok = UserPresets.release(server, r.ref)
      _ = UserPresets.list(server)
      refute File.exists?(r.path)

      {pid, {:ok, r}} = owner(fn -> UserPresets.reserve(server, 1000) end)
      File.write!(r.path, "x")
      Agent.update(agent, &(&1 - 1))
      assert UserPresets.reserve(server, 1) == {:error, :no_space}

      stop_owner(pid)
      Agent.update(agent, &(&1 + 1))
      assert {:ok, _} = UserPresets.reserve(server, 1000)
      refute File.exists?(r.path)
    end

    test "a wedged server is a timeout, told apart from a stopped one", ctx do
      server = start_library(ctx)
      :ok = :sys.suspend(server)

      assert UserPresets.reserve(server, 1, 50) == {:error, :timeout}
      assert UserPresets.claim(server, make_ref(), 50) == {:error, :timeout}

      :ok = :sys.resume(server)
    end

    test "a stalled df is bounded and never blocks the server", ctx do
      test = self()

      stalled = fn _ ->
        send(test, :measuring)
        Process.sleep(2_000)
        @roomy
      end

      server = start_library(ctx, free_space: stalled, measure_timeout_ms: 200)
      waiter = Task.async(fn -> UserPresets.reserve(server, 1) end)
      assert_receive :measuring, 1_000

      # Reads are served while the measurement runs.
      {micros, usage} = :timer.tc(fn -> UserPresets.usage(server) end)
      assert usage.presets == 0
      assert micros < 100_000

      assert capture_log(fn ->
               assert Task.await(waiter) == {:error, {:free_space, :timeout}}
             end) =~ "free-space check took over 200 ms"
    end

    test "a timed-out claim is cancelled: its file doesn't outlive it", ctx do
      server = start_library(ctx)
      {:ok, r} = UserPresets.reserve(server, 3)
      File.write!(r.path, "abc")

      :ok = :sys.suspend(server)
      assert UserPresets.claim(server, r.ref, 50) == {:error, :timeout}
      :ok = :sys.resume(server)

      _ = UserPresets.list(server)
      assert incoming_files(ctx) == []
    end

    test "a staging write that fails gives its room back at once", ctx do
      body = milk(String.duplicate("x", 20_000 - byte_size(milk())))
      archive = zip([[name: "Big.milk", data: body], [name: "t.png", data: png(4, 4)]])
      agent = start_supervised!({Agent, fn -> nil end})
      calls = :counters.new(1, [])
      room = du_free(ctx, byte_size(archive) + 20_000)

      # While the big preset's room is reserved, make its staging
      # directory unusable (a file where `presets/` goes).
      free = fn path ->
        :counters.add(calls, 1, 1)

        if :counters.get(calls, 1) == 2 do
          staging = :sys.get_state(Agent.get(agent, & &1)).busy.staging
          File.mkdir_p!(staging)
          File.write!(Path.join(staging, "presets"), "")
        end

        room.(path)
      end

      server = start_library(ctx, free_space: free)
      Agent.update(agent, fn _ -> server end)

      assert [
               %{name: "Big.milk", status: {:rejected, {:io, _}}},
               %{name: "t.png", status: :added}
             ] =
               import!(server, [upload(ctx, "p.zip", archive)])
    end

    test "staging that can't measure the free space says so", ctx do
      calls = :counters.new(1, [])

      # The import's own first measurement works; the staging check doesn't.
      free = fn _ ->
        :counters.add(calls, 1, 1)
        if :counters.get(calls, 1) == 1, do: @roomy, else: {:error, :df_failed}
      end

      server = start_library(ctx, free_space: free)

      assert [%{status: {:rejected, {:free_space, :df_failed}}}] =
               import!(server, [upload(ctx, "a.milk", milk())])
    end

    test "a reserved file written while df runs is never credited", ctx do
      agent = start_supervised!({Agent, fn -> nil end})

      # The df snapshot predates the write it races with.
      free = fn _ ->
        case Agent.get_and_update(agent, &{&1, nil}) do
          nil -> :ok
          path -> File.write!(path, :binary.copy("x", 500))
        end

        {:ok, %{total_bytes: 1000 * @mib, free_bytes: 200 * @mib + 1000}}
      end

      server = start_library(ctx, free_space: free)
      {:ok, r} = UserPresets.reserve(server, 1000)
      Agent.update(agent, fn _ -> r.path end)

      assert UserPresets.reserve(server, 1) == {:error, :no_space}
      assert File.stat!(r.path).size == 500
    end

    test "uploads streaming in hold room an import can't take", ctx do
      body = milk(String.duplicate("x", 20_000))
      # Room for the upload itself (on disk) plus 40,000 bytes.
      server = start_library(ctx, free_space: du_free(ctx, byte_size(body) + 40_000))

      {:ok, _r} = UserPresets.reserve(server, 30_000)

      assert [%{status: {:rejected, :no_space}}] =
               import!(server, [upload(ctx, "Big.milk", body)])

      refute File.exists?(preset_path(ctx, "Big.milk"))
    end

    test "an import's staged files hold room uploads can't take", ctx do
      test = self()
      body = milk(String.duplicate("x", 20_000))
      agent = start_supervised!({Agent, fn -> nil end})
      calls = :counters.new(1, [])
      room = du_free(ctx, byte_size(body) + 40_000)

      # The measurement for the import's staging file waits until an
      # upload's reservation queues behind it: both are decided on it.
      free = fn path ->
        :counters.add(calls, 1, 1)

        if :counters.get(calls, 1) == 2 do
          send(test, :measuring)
          await_waiting(Agent.get(agent, & &1), 2)
        end

        room.(path)
      end

      server = start_library(ctx, free_space: free)
      Agent.update(agent, fn _ -> server end)
      up = upload(ctx, "Big.milk", body)
      importer = Task.async(fn -> UserPresets.import(server, [up]) end)

      assert_receive :measuring, 2_000
      assert UserPresets.reserve(server, 30_000) == {:error, :no_space}
      assert {:ok, [%{status: :added}]} = Task.await(importer)

      # The import's reservation ended with it.
      assert {:ok, _} = UserPresets.reserve(server, 40_000)
    end

    test "a claimed upload is the claimer's until import takes it", ctx do
      server = start_library(ctx)

      claim = fn ->
        {:ok, r} = UserPresets.reserve(server, byte_size(milk()))
        File.write!(r.path, milk())
        {:ok, path} = UserPresets.claim(server, r.ref)
        {r, path}
      end

      # The claimer exits before importing: the server deletes the file.
      {pid, {r, path}} = owner(claim)
      refute File.exists?(r.path)
      assert Path.dirname(path) == ctx.incoming
      assert Path.basename(path) == Path.basename(r.path, ".part")
      assert File.exists?(path)
      assert UserPresets.claim(server, r.ref) == {:error, :unknown}
      stop_owner(pid)
      _ = UserPresets.list(server)
      refute File.exists?(path)

      # Passed to import, it is the import's even if the claimer exits.
      {pid, {_r, _path}} =
        owner(fn ->
          {_r, path} = claim.()
          {:ok, [%{status: :added}]} = UserPresets.import(server, [{"Kept.milk", path}])
          {nil, path}
        end)

      stop_owner(pid)
      assert File.exists?(preset_path(ctx, "Kept.milk"))
      assert incoming_files(ctx) == []
    end
  end

  @tag :contract
  test "the manifest parses in the renderer's own parser with nothing rejected", ctx do
    server = start_library(ctx)

    bin =
      zip([
        [name: "Été (remix) #2.milk", data: milk()],
        [name: "$$$ Royal - Mashup [x].milk", data: milk()],
        [name: "t.png", data: png(4, 4)]
      ])

    [_, _, _, _] = import!(server, [upload(ctx, "p.zip", bin), upload(ctx, "plain.milk", milk())])
    :ok = UserPresets.set_high_frequency(server, "user/plain.milk", true)

    check = manifest_check!(Path.join(ctx.user, "manifest.json"), ctx.user)
    assert check["ok"]
    assert check["version"] == "user"
    assert check["presets"] == 3
    assert check["rejected"] == 0
    assert check["missing"] == 0
    assert check["high_frequency"] == 1
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
end
