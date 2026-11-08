defmodule UniversalProxy.MilkDrop.IndexTest do
  # Per-test PubSub, ETS and DETS names: nothing shared between tests.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import UniversalProxy.MilkDropIndexFixtures

  alias UniversalProxy.MilkDrop
  alias UniversalProxy.MilkDrop.{Index, Pack, Store, UserPresets}

  @moduletag :tmp_dir
  @version "2026.11.1"
  @mib 1024 * 1024

  setup %{tmp_dir: tmp_dir} do
    n = System.unique_integer([:positive])
    pubsub = :"index_test_pubsub_#{n}"
    uploads = :"index_test_uploads_#{n}"
    start_supervised!({Phoenix.PubSub, name: pubsub})
    Phoenix.PubSub.subscribe(pubsub, Index.topic())

    store =
      start_supervised!(
        {Store,
         name: nil,
         table: :"index_test_store_#{n}",
         dets_path: Path.join(tmp_dir, "settings.dets"),
         pubsub: pubsub,
         pack_version: @version,
         user_sha: &UserPresets.sha256(uploads, &1)}
      )

    {:ok,
     root: Path.join(tmp_dir, "milkdrop"),
     pubsub: pubsub,
     store: store,
     uploads: uploads,
     index: :"index_test_#{n}"}
  end

  defp start_all(ctx, opts \\ []) do
    pack =
      start_supervised!(
        {Pack,
         name: nil,
         root: ctx.root,
         pin: %{
           version: @version,
           url: "https://example.test/p.tgz",
           sha256: String.duplicate("a", 64)
         },
         task_supervisor: start_supervised!(Task.Supervisor, id: :pack_tasks),
         pubsub: ctx.pubsub,
         subscribe?: false}
      )

    library =
      start_supervised!(
        {UserPresets,
         name: nil,
         root: ctx.root,
         table: ctx.uploads,
         store: ctx.store,
         pubsub: ctx.pubsub,
         task_supervisor: start_supervised!(Task.Supervisor, id: :upload_tasks),
         free_space: fn _ -> {:ok, %{total_bytes: 1000 * @mib, free_bytes: 900 * @mib}} end,
         pack_textures: fn -> [] end}
      )

    start_supervised!(
      {Index,
       Keyword.merge(
         [
           name: ctx.index,
           pubsub: ctx.pubsub,
           store: ctx.store,
           pack: pack,
           user_presets: library,
           batch_ms: 20
         ],
         opts
       )}
    )

    # A long :batch_ms holds the first broadcast; flush it at once.
    index = Process.whereis(ctx.index)
    _ = :sys.get_state(index)
    send(index, :flush)
    assert_receive {:milkdrop_index, %{rebuilt: true}}, 2_000
    %{pack: pack, library: library, index_pid: index}
  end

  defp all(index, query \\ Index.query("")) do
    {rows, false} = Index.page(index, query, limit: 10_000)
    rows
  end

  defp ids(rows), do: Enum.map(rows, & &1.id)

  defp row!(index, id) do
    {:ok, row} = Index.fetch_id(index, id)
    row
  end

  describe "building" do
    test "lists the pack and the uploads in name order, with their details", ctx do
      write_pack!(ctx.root, @version, [
        %{"file" => "b/Zeta.milk", "tags" => ["extreme"], "rpi3" => %{"rung" => "640x360"}},
        %{"file" => "high_frequency/Flash.milk", "rpi3" => "skip"},
        %{
          "file" => "alpha.milk",
          "tags" => ["high_frequency"],
          "rpi3" => %{"rung" => "skip", "reason" => "register_allocate"}
        },
        %{"file" => "Mid.milk", "rpi3" => %{"rung" => nil, "frame_ms" => 3}},
        %{"file" => "Odd.milk", "rpi3" => " +0320x0180"}
      ])

      seed_uploads!(ctx.root, ["Mine.milk"])
      start_all(ctx)

      assert ids(all(ctx.index)) == [
               "alpha.milk",
               "high_frequency/Flash.milk",
               "Mid.milk",
               "user/Mine.milk",
               "Odd.milk",
               "b/Zeta.milk"
             ]

      assert %{
               name: "Zeta",
               folder: "b",
               source: :pack,
               tags: ["extreme"],
               high_frequency: false,
               rpi3: {:rung, "640x360"},
               skip: nil,
               favourite: false,
               uploaded_at: nil
             } = row!(ctx.index, "b/Zeta.milk")

      assert %{high_frequency: true, rpi3: {:skip, nil}} =
               row!(ctx.index, "high_frequency/Flash.milk")

      assert %{high_frequency: true, rpi3: {:skip, "register_allocate"}} =
               row!(ctx.index, "alpha.milk")

      assert %{rpi3: nil} = row!(ctx.index, "Mid.milk")
      assert %{rpi3: {:rung, "320x180"}} = row!(ctx.index, "Odd.milk")

      assert %{
               name: "Mine",
               folder: nil,
               source: :user,
               high_frequency: false,
               uploaded_at: %DateTime{}
             } =
               row!(ctx.index, "user/Mine.milk")
    end

    test "drops entries the renderer would drop", ctx do
      write_pack!(ctx.root, @version, [
        "ok.milk",
        "ok.milk",
        "user/sneaky.milk",
        "../up.milk",
        "no-extension",
        %{"file" => "bad-tags.milk", "tags" => [1]},
        %{"nope" => true},
        42,
        %{"file" => "null-tags.milk", "tags" => nil},
        %{"file" => "rpi3-null.milk", "rpi3" => nil},
        %{"file" => "rpi3-bogus.milk", "rpi3" => "bogus"},
        %{"file" => "rpi3-zero.milk", "rpi3" => "0x360"},
        %{"file" => "rpi3-huge.milk", "rpi3" => %{"rung" => "16385x360"}},
        %{"file" => "rpi3-max.milk", "rpi3" => %{"rung" => "16384x16384"}},
        %{"file" => "rpi3-trailing.milk", "rpi3" => "640x360 "},
        %{"file" => "rpi3-rung-number.milk", "rpi3" => %{"rung" => 640}},
        %{"file" => "rpi3-number.milk", "rpi3" => 1},
        %{"file" => "rpi3-list.milk", "rpi3" => ["skip"]},
        %{"file" => "rpi3-no-rung.milk", "rpi3" => %{"reason" => "x"}}
      ])

      start_all(ctx)

      assert ids(all(ctx.index)) ==
               ["ok.milk", "rpi3-max.milk", "rpi3-no-rung.milk", "rpi3-null.milk"]

      assert row!(ctx.index, "rpi3-max.milk").rpi3 == {:rung, "16384x16384"}
    end

    test "a manifest the renderer would refuse lists no pack presets", ctx do
      for {doc, error} <- [
            {%{"format" => 2, "presets" => [%{"file" => "a.milk"}]}, :unsupported_format},
            {%{"format" => "1", "presets" => [%{"file" => "a.milk"}]}, :unsupported_format},
            {%{"format" => 1, "presets" => %{}}, :no_presets},
            {[%{"file" => "a.milk"}], :no_presets}
          ] do
        dir = write_pack!(ctx.root, @version, [])
        File.write!(Path.join(dir, "manifest.json"), Jason.encode!(doc))
        assert capture_log(fn -> start_all(ctx) end) =~ "can't read"
        assert all(ctx.index) == []
        assert Index.manifest_error(ctx.index) == error
        Enum.each([Index, UserPresets, Pack, :pack_tasks, :upload_tasks], &stop_supervised!/1)
      end

      dir = write_pack!(ctx.root, @version, [])

      File.write!(
        Path.join(dir, "manifest.json"),
        ~s({"format": 1.0, "presets": [{"file": "a.milk"}]})
      )

      start_all(ctx)
      assert ids(all(ctx.index)) == ["a.milk"]
      assert Index.manifest_error(ctx.index) == nil
    end

    test "a missing or malformed manifest is no pack rows, logged", ctx do
      dir = write_pack!(ctx.root, @version, [])
      File.write!(Path.join(dir, "manifest.json"), "{not json")
      seed_uploads!(ctx.root, ["Mine.milk"])

      assert capture_log(fn -> start_all(ctx) end) =~ "can't read"
      assert ids(all(ctx.index)) == ["user/Mine.milk"]
    end

    test "folds in the Store's skips, selection and lock", ctx do
      write_pack!(ctx.root, @version, ["a.milk", "b.milk", "c.milk"])
      :ok = Store.skip(ctx.store, @version, "a.milk", "budget")
      {:ok, _} = Store.favourite(ctx.store, "b.milk", true)
      {:ok, _} = Store.hide(ctx.store, "c.milk", true)
      {:ok, _} = Store.playlist_add(ctx.store, "a.milk")
      {:ok, _} = Store.set_playlist_enabled(ctx.store, true)
      {:ok, _} = Store.update(ctx.store, %{locked: "b.milk"})
      start_all(ctx)

      assert %{skip: "budget", playlist: true, favourite: false} = row!(ctx.index, "a.milk")
      assert %{favourite: true, locked: true} = row!(ctx.index, "b.milk")
      assert %{hidden: true, locked: false} = row!(ctx.index, "c.milk")
      assert Index.playlist_enabled?(ctx.index)
    end

    test "keys are short, stable and DOM-safe; unknown or malformed keys don't resolve", ctx do
      write_pack!(ctx.root, @version, ["a.milk"])
      start_all(ctx)

      key = Index.key("a.milk")
      assert key == Index.key("a.milk")
      assert key =~ ~r/\A[a-z2-7]{12}\z/
      assert {:ok, %{id: "a.milk", key: ^key}} = Index.fetch(ctx.index, key)
      assert Index.fetch(ctx.index, Index.key("b.milk")) == :error
      assert Index.fetch(ctx.index, "a.milk") == :error
      assert Index.fetch(ctx.index, nil) == :error
      assert Index.fetch(ctx.index, %{"key" => key}) == :error
    end
  end

  describe "queries" do
    setup ctx do
      write_pack!(
        ctx.root,
        @version,
        pack_ids(120) ++ ["Geiss - Flux.milk", "high_frequency/flux burst.milk"]
      )

      seed_uploads!(ctx.root, ["My Flux.milk", "Other.milk"])
      {:ok, _} = Store.hide(ctx.store, "Preset 002.milk", true)
      {:ok, _} = Store.favourite(ctx.store, "Preset 003.milk", true)
      {:ok, _} = Store.playlist_add(ctx.store, "Preset 004.milk")
      :ok = Store.skip(ctx.store, @version, "Preset 005.milk", "gpu_hang")
      start_all(ctx)
      :ok
    end

    test "pages forward and back by cursor", ctx do
      query = Index.query("preset")
      {page1, true} = Index.page(ctx.index, query, limit: 50)
      assert length(page1) == 50
      assert hd(page1).id == "Preset 001.milk"
      # Hidden presets are left out of "all".
      refute "Preset 002.milk" in ids(page1)

      {page2, true} =
        Index.page(ctx.index, query, after: Index.cursor(List.last(page1)), limit: 50)

      {page3, false} =
        Index.page(ctx.index, query, after: Index.cursor(List.last(page2)), limit: 50)

      assert length(page3) == 119 - 100
      assert List.last(page3).id == "Preset 120.milk"

      assert {^page2, true} =
               Index.page(ctx.index, query, before: Index.cursor(hd(page3)), limit: 50)

      assert {^page1, false} =
               Index.page(ctx.index, query, before: Index.cursor(hd(page2)), limit: 50)

      assert {[], false} =
               Index.page(ctx.index, query, before: Index.cursor(hd(page1)), limit: 50)

      assert {[], false} =
               Index.page(ctx.index, query, after: Index.cursor(List.last(page3)), limit: 50)
    end

    test "searches names, authors and folders, case-insensitively", ctx do
      assert ids(all(ctx.index, Index.query("  FLUX "))) ==
               ["high_frequency/flux burst.milk", "Geiss - Flux.milk", "user/My Flux.milk"]

      assert ids(all(ctx.index, Index.query("geiss"))) == ["Geiss - Flux.milk"]
      assert ids(all(ctx.index, Index.query("high_freq"))) == ["high_frequency/flux burst.milk"]
      assert all(ctx.index, Index.query(".milk")) == []
      assert all(ctx.index, Index.query("no such preset")) == []
    end

    test "filters", ctx do
      by = fn filter -> ids(all(ctx.index, Index.query("", filter))) end

      assert by.(:uploaded) == ["user/My Flux.milk", "user/Other.milk"]
      assert by.(:hidden) == ["Preset 002.milk"]
      assert by.(:favourites) == ["Preset 003.milk"]
      assert by.(:playlist) == ["Preset 004.milk"]
      assert by.(:skipped) == ["Preset 005.milk"]
      assert by.(:fast_flashing) == ["high_frequency/flux burst.milk"]
    end

    test "counts every filter for a search", ctx do
      assert Index.counts(ctx.index, "") == %{
               total: 124,
               pack: 122,
               all: 123,
               uploaded: 2,
               favourites: 1,
               hidden: 1,
               playlist: 1,
               skipped: 1,
               fast_flashing: 1
             }

      assert %{total: 124, pack: 122, all: 3, uploaded: 1, fast_flashing: 1, hidden: 0} =
               Index.counts(ctx.index, "flux")
    end

    test "query and filter parameters are sanitised" do
      assert Index.query(String.duplicate("a", 100)).q == String.duplicate("a", 64)
      assert Index.query(<<0xFF, 0xFE>>).q == ""
      assert Index.query(nil).q == ""
      assert Index.parse_filter("favourites") == :favourites
      assert Index.parse_filter("fast-flashing") == :fast_flashing
      assert Index.parse_filter("nope") == :all
      assert Index.parse_filter(nil) == :all
      assert Index.filter_param(:fast_flashing) == "fast-flashing"
    end
  end

  describe "changes" do
    setup ctx do
      write_pack!(ctx.root, @version, ["a.milk", "b.milk"])
      seed_uploads!(ctx.root, ["Mine.milk"])
      Map.merge(ctx, start_all(ctx, batch_ms: Map.get(ctx, :batch_ms, 20)))
    end

    @tag batch_ms: 60_000
    test "selection changes update the flags, batched into one message", ctx do
      {:ok, _} = Store.favourite(ctx.store, "a.milk", true)
      {:ok, _} = Store.hide(ctx.store, "b.milk", true)
      {:ok, _} = Store.playlist_add(ctx.store, "user/Mine.milk")
      # An id with no row (an upload that may come later) changes nothing here.
      {:ok, _} = Store.favourite(ctx.store, "later.milk", true)
      refute_receive {:milkdrop_index, _}, 50
      _ = :sys.get_state(ctx.index_pid)
      send(ctx.index_pid, :flush)

      assert_receive {:milkdrop_index, %{rebuilt: false, changed: changed}}, 1_000

      assert Enum.sort(changed) ==
               Enum.sort(Enum.map(~w(a.milk b.milk user/Mine.milk), &Index.key/1))

      refute_receive {:milkdrop_index, _}, 100

      assert row!(ctx.index, "a.milk").favourite
      assert row!(ctx.index, "b.milk").hidden
      assert row!(ctx.index, "user/Mine.milk").playlist

      {:ok, _} = Store.playlist_clear(ctx.store)
      _ = :sys.get_state(ctx.index_pid)
      send(ctx.index_pid, :flush)
      assert_receive {:milkdrop_index, %{changed: [key]}}, 1_000
      assert key == Index.key("user/Mine.milk")
      refute row!(ctx.index, "user/Mine.milk").playlist
    end

    test "playlist on/off is a counts-only change", ctx do
      refute Index.playlist_enabled?(ctx.index)
      {:ok, _} = Store.set_playlist_enabled(ctx.store, true)

      assert_receive {:milkdrop_index, %{rebuilt: false, added: [], changed: [], removed: []}},
                     1_000

      assert Index.playlist_enabled?(ctx.index)
    end

    test "skips and the lock update their rows", ctx do
      :ok = Store.skip(ctx.store, @version, "a.milk", "hang")
      assert_receive {:milkdrop_index, %{changed: [key]}}, 1_000
      assert key == Index.key("a.milk")
      assert row!(ctx.index, "a.milk").skip == "hang"

      {:ok, _} = Store.update(ctx.store, %{locked: "b.milk"})
      assert_receive {:milkdrop_index, %{changed: [key]}}, 1_000
      assert key == Index.key("b.milk")
      assert row!(ctx.index, "b.milk").locked

      {:ok, _} = Store.update(ctx.store, %{locked: "a.milk"})
      assert_receive {:milkdrop_index, %{changed: changed}}, 1_000
      assert Enum.sort(changed) == Enum.sort([Index.key("a.milk"), Index.key("b.milk")])
      refute row!(ctx.index, "b.milk").locked

      :ok = Store.clear_skipped(ctx.store)
      assert_receive {:milkdrop_index, %{changed: [_]}}, 1_000
      assert row!(ctx.index, "a.milk").skip == nil
    end

    test "uploads flagged, deleted and added", ctx do
      :ok = UserPresets.set_high_frequency(ctx.library, "user/Mine.milk", true)
      assert_receive {:milkdrop_index, %{changed: [key]}}, 1_000
      assert key == Index.key("user/Mine.milk")
      assert row!(ctx.index, "user/Mine.milk").high_frequency
      assert Index.counts(ctx.index, "").fast_flashing == 1

      :ok = UserPresets.delete(ctx.library, "user/Mine.milk")
      assert_receive {:milkdrop_index, %{removed: [^key]}}, 1_000
      assert Index.fetch(ctx.index, key) == :error
      assert ids(all(ctx.index)) == ["a.milk", "b.milk"]

      incoming = UserPresets.incoming_dir(ctx.root)
      File.mkdir_p!(incoming)
      path = Path.join(incoming, "up-1")
      File.write!(path, UniversalProxy.MilkDropUploadFixtures.milk())
      {:ok, [%{status: :added}]} = UserPresets.import(ctx.library, [{"New.milk", path}])

      assert_receive {:milkdrop_index, %{added: [added]}}, 1_000
      assert added == Index.key("user/New.milk")
      assert ids(all(ctx.index)) == ["a.milk", "b.milk", "user/New.milk"]
    end

    test "a new ready pack rebuilds; leaving ready drops the pack's rows", ctx do
      dir = write_pack!(ctx.root, "2026.12.1", ["c.milk"])

      Phoenix.PubSub.broadcast(
        ctx.pubsub,
        MilkDrop.pack_topic(),
        {:milkdrop_pack, {:ready, "2026.12.1", dir}}
      )

      assert_receive {:milkdrop_index, %{rebuilt: true}}, 1_000
      assert ids(all(ctx.index)) == ["c.milk", "user/Mine.milk"]

      # Progress for the same status changes nothing.
      Phoenix.PubSub.broadcast(
        ctx.pubsub,
        MilkDrop.pack_topic(),
        {:milkdrop_pack, {:ready, "2026.12.1", dir}}
      )

      refute_receive {:milkdrop_index, _}, 100

      Phoenix.PubSub.broadcast(
        ctx.pubsub,
        MilkDrop.pack_topic(),
        {:milkdrop_pack_started, :absent}
      )

      assert_receive {:milkdrop_index, %{rebuilt: true}}, 1_000
      assert ids(all(ctx.index)) == ["user/Mine.milk"]
    end
  end

  test "re-reads the Store when its table opens after serving defaults", ctx do
    # A first store writes the state; the second can't open the same file
    # until its directory is back.
    dir = Path.join(ctx.tmp_dir, "store")
    path = Path.join(dir, "settings.dets")

    {:ok, first} =
      Store.start_link(name: nil, table: :index_test_reopen, dets_path: path, pubsub: ctx.pubsub)

    {:ok, _} = Store.favourite(first, "a.milk", true)
    {:ok, _} = Store.set_playlist_enabled(first, true)
    {:ok, _} = Store.update(first, %{locked: "b.milk"})
    :ok = Store.skip(first, @version, "b.milk", "hang")
    GenServer.stop(first)

    File.rename!(dir, dir <> ".away")
    File.write!(dir, "not a directory")

    store =
      start_supervised!(
        {Store,
         name: nil,
         table: :index_test_reopen,
         dets_path: path,
         pubsub: ctx.pubsub,
         pack_version: @version,
         retry_ms: 50},
        id: :reopening_store
      )

    write_pack!(ctx.root, @version, ["a.milk", "b.milk"])
    start_all(%{ctx | store: store})
    refute row!(ctx.index, "a.milk").favourite
    refute Index.playlist_enabled?(ctx.index)

    File.rm!(dir)
    File.rename!(dir <> ".away", dir)

    assert_receive {:milkdrop_index, %{changed: changed}}, 2_000
    assert Index.key("a.milk") in changed
    assert row!(ctx.index, "a.milk").favourite
    assert %{locked: true, skip: "hang"} = row!(ctx.index, "b.milk")
    assert Index.playlist_enabled?(ctx.index)
  end

  test "reads are empty with no index", ctx do
    assert Index.page(ctx.index, Index.query(""), limit: 50) == {[], false}
    assert Index.fetch(ctx.index, Index.key("a.milk")) == :error
    assert %{total: 0, all: 0} = Index.counts(ctx.index, "")
    refute Index.playlist_enabled?(ctx.index)
  end

  test "builds with every dependency down", ctx do
    start_supervised!(
      {Index,
       name: ctx.index,
       pubsub: ctx.pubsub,
       store: :index_test_no_store,
       pack: :index_test_no_pack,
       user_presets: :index_test_no_library}
    )

    assert_receive {:milkdrop_index, %{rebuilt: true}}, 2_000
    assert Index.counts(ctx.index, "").total == 0
  end
end
