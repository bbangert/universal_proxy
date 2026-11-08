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

      # New content in another case: the old file and id go.
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

  describe "free space" do
    test "an import must leave max(200 MiB, 10%) free", ctx do
      data = milk()
      free = 200 * @mib + byte_size(data)

      server =
        start_library(ctx,
          free_space: fn _path -> {:ok, %{total_bytes: 1000 * @mib, free_bytes: free}} end
        )

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

      assert :ok = UserPresets.delete(server, "user/a.milk")

      refute File.exists?(preset_path(ctx, "a.milk"))
      assert %{"presets" => [%{"file" => "b.milk"}]} = manifest(ctx)
      assert_receive {:milkdrop_user_presets, %{removed: ["user/a.milk"], added: []}}
      assert UserPresets.sha256(ctx.table, "user/a.milk") == nil
      assert Store.settings(ctx.store).locked == nil
      assert Store.skipped(ctx.store, "v1") == %{"user/b.milk" => "draw", "pack.milk" => "draw"}
      assert [%{id: "user/b.milk"}] = UserPresets.list(server).presets
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
