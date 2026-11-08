defmodule UniversalProxyWeb.MilkDropUploadComponentTest do
  @moduledoc """
  The MilkDrop upload component on the Audio tab and in the preset
  browser, against a real Store, Pack (a pre-extracted tmp pack),
  UserPresets (a tmp library) and Index under their global names, as in
  `UniversalProxyWeb.MilkDropPresetsLiveTest`.
  """

  # async: false — global process names, app env and global PubSub topics.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import Phoenix.ConnTest
  import UniversalProxy.MilkDropIndexFixtures
  import UniversalProxy.MilkDropUploadFixtures

  alias UniversalProxy.MilkDrop.{Index, Pack, Store, UserPresets}

  @endpoint UniversalProxyWeb.Endpoint
  @pubsub UniversalProxy.PubSub
  @version "2026.11.1"
  @uploads :milkdrop_upload_component_test_uploads
  @mib 1024 * 1024
  @form "#milkdrop-upload-form"
  @hostile "<img src=x onerror=alert(1)>.milk"

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    Application.put_env(:universal_proxy, :milkdrop_ui_override, true)
    Application.put_env(:universal_proxy, :milkdrop_display, :milkdrop_upload_test_no_display)

    on_exit(fn ->
      for key <- [:milkdrop_ui_override, :milkdrop_display],
          do: Application.delete_env(:universal_proxy, key)
    end)

    root = Path.join(tmp_dir, "milkdrop")
    write_pack!(root, @version, pack_ids(3))
    seed_uploads!(root, ["Mine.milk"])

    store =
      start_supervised!(
        {Store,
         table: :milkdrop_upload_component_test,
         dets_path: Path.join(tmp_dir, "settings.dets"),
         pack_version: @version,
         user_sha: &UserPresets.sha256(@uploads, &1)}
      )

    ctx = %{
      root: root,
      store: store,
      tasks: start_supervised!(Task.Supervisor, id: :upload_tasks)
    }

    start_user_presets(ctx)

    start_supervised!(
      {Pack,
       root: root,
       pin: %{
         version: @version,
         url: "https://example.test/p.tgz",
         sha256: String.duplicate("a", 64)
       },
       task_supervisor: start_supervised!(Task.Supervisor, id: :pack_tasks),
       subscribe?: false}
    )

    Phoenix.PubSub.subscribe(@pubsub, Index.topic())
    start_supervised!({Index, batch_ms: 10})
    assert_receive {:milkdrop_index, %{rebuilt: true}}, 2_000

    {:ok, Map.merge(ctx, %{conn: build_conn(), incoming: UserPresets.incoming_dir(root)})}
  end

  defp start_user_presets(ctx, opts \\ []) do
    free = Keyword.get(opts, :free_bytes, 900 * @mib)

    free_space =
      Keyword.get(opts, :free_space, fn _ ->
        {:ok, %{total_bytes: 1000 * @mib, free_bytes: free}}
      end)

    start_supervised!(
      {UserPresets,
       [
         root: ctx.root,
         table: @uploads,
         store: ctx.store,
         task_supervisor: ctx.tasks,
         free_space: free_space,
         pack_textures: fn -> [] end
       ] ++ Keyword.drop(opts, [:free_bytes, :free_space])}
    )
  end

  defp restart_user_presets(ctx, opts) do
    stop_supervised!(UserPresets)
    start_user_presets(ctx, opts)
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

  defp file(name, content), do: %{name: name, content: content, type: "application/octet-stream"}

  defp incoming_files(ctx),
    do: ctx.incoming |> File.ls!() |> Enum.reject(&String.starts_with?(&1, "."))

  defp import!(view, files) do
    input = file_input(view, @form, :presets, files)
    for %{name: name} <- files, do: assert(render_upload(input, name) =~ "100%")
    view |> form(@form) |> render_submit()
    render_async(view)
  end

  defp results(view), do: view |> element("#milkdrop-upload-results") |> render()

  for path <- ["/audio", "/audio/milkdrop"] do
    describe "on #{path}" do
      @path path

      test "imports a single .milk", %{conn: conn, root: root} = ctx do
        {:ok, view, _html} = live(conn, @path)
        assert has_element?(view, "#milkdrop-upload-submit[disabled]")

        html = import!(view, [file("a.milk", milk())])

        assert html =~ "1 added"
        assert File.read!(Path.join([root, "user", "presets", "a.milk"])) == milk()
        assert incoming_files(ctx) == []

        assert has_element?(
                 view,
                 ~s(#milkdrop-upload-results a[href="/audio/milkdrop?filter=uploaded&q=a"])
               )

        wait_until(fn -> match?({:ok, _}, Index.fetch_id("user/a.milk")) end)

        # The browser inserts the new row in place (Index's `added`).
        if @path == "/audio/milkdrop",
          do: wait_until(fn -> has_element?(view, "#preset-#{Index.key("user/a.milk")}") end)
      end

      test "imports a zip with its texture", %{conn: conn, root: root} do
        {:ok, view, _html} = live(conn, @path)

        zip = zip([[name: "pack/x.milk", data: milk()], [name: "pack/tex.png", data: png(4, 4)]])
        html = import!(view, [file("p.zip", zip)])

        assert html =~ "2 added"
        assert results(view) =~ "pack/tex.png"
        assert results(view) =~ "in p.zip"
        assert File.exists?(Path.join([root, "user", "presets", "x.milk"]))
        assert File.exists?(Path.join([root, "user", "textures", "tex.png"]))
      end

      test "shows the quota usage and the photosensitivity warning", %{conn: conn} do
        {:ok, view, _html} = live(conn, @path)
        assert view |> element("#milkdrop-upload-usage") |> render() =~ "1 of 500 presets"
        assert view |> element("#milkdrop-upload-warning") |> render() =~ "responsible"

        import!(view, [file("b.milk", milk())])
        assert view |> element("#milkdrop-upload-usage") |> render() =~ "2 of 500 presets"
      end
    end
  end

  describe "results" do
    test "a hostile zip is rejected with its reason", %{conn: conn, root: root} do
      {:ok, view, _html} = live(conn, "/audio/milkdrop")

      zip = zip([[name: "../evil.milk", data: milk()]])
      html = import!(view, [file("evil.zip", zip)])

      assert html =~ "1 rejected"
      assert results(view) =~ "Unsafe path in the archive: ../evil.milk"
      refute File.exists?(Path.join(root, "evil.milk"))
      refute File.exists?(Path.join([root, "user", "presets", "evil.milk"]))
    end

    test "content and name rejections, then replaced and unchanged", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/audio/milkdrop")

      import!(view, [file("bad.milk", "no values here"), file("Mine.milk", milk("x=1\r\n"))])
      assert results(view) =~ "Not a MilkDrop preset (no settings found)."
      assert results(view) =~ "Replaced"

      import!(view, [file("Mine.milk", milk("x=1\r\n"))])
      assert results(view) =~ "Unchanged"
      assert results(view) =~ "Already in the library."
    end

    test "hostile names are escaped", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/audio/milkdrop")

      import!(view, [file(@hostile, milk())])
      html = results(view)
      assert html =~ "&lt;img src=x onerror=alert(1)&gt;.milk"
      assert html =~ "characters that aren"
      refute html =~ "<img"
    end

    test "dismiss clears the results", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/audio/milkdrop")
      import!(view, [file("c.milk", milk())])

      view |> element("#milkdrop-upload-results button", "Dismiss") |> render_click()
      refute has_element?(view, "#milkdrop-upload-results")
    end

    test "results are capped at 50 rows", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/audio/milkdrop")

      zip = zip(for i <- 1..60, do: [name: "p#{i}.milk", data: milk()])
      html = import!(view, [file("many.zip", zip)])

      assert html =~ "60 added"
      assert view |> element("#milkdrop-upload-results") |> render() =~ "…and 10 more"

      rows =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#milkdrop-upload-results tbody tr")
        |> Enum.count()

      assert rows == 50
    end

    test "a library stopped before submit is reported", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/audio/milkdrop")
      input = file_input(view, @form, :presets, [file("d.milk", milk())])
      assert render_upload(input, "d.milk") =~ "100%"

      stop_supervised!(UserPresets)
      view |> form(@form) |> render_submit()
      render_async(view)
      assert results(view) =~ "1 rejected"
      assert results(view) =~ "The preset library isn&#39;t running."
    end

    test "a submit with an unfinished entry waits, keeping its error", %{conn: conn} = ctx do
      restart_user_presets(ctx, max_upload_bytes: 500)
      {:ok, view, _html} = live(conn, "/audio/milkdrop")
      big = milk(String.duplicate("x", 600))
      input = file_input(view, @form, :presets, [file("l.milk", milk()), file("big.milk", big)])

      assert render_upload(input, "l.milk") =~ "100%"
      render_upload(input, "big.milk")

      view |> form(@form) |> render_submit()
      html = render(view)
      assert html =~ "Larger than 500 B, the upload limit."
      assert html =~ "l.milk"
      refute has_element?(view, "#milkdrop-upload-results")
      assert [_part] = incoming_files(ctx)

      view
      |> element("#milkdrop-upload-entries button[aria-label='Remove big.milk']")
      |> render_click()

      view |> form(@form) |> render_submit()
      assert render_async(view) =~ "1 added"
      assert incoming_files(ctx) == []
    end
  end

  describe "upload errors" do
    test "a wrong extension isn't accepted", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/audio/milkdrop")
      input = file_input(view, @form, :presets, [file("notes.txt", "hi")])

      assert {:error, [[_ref, :not_accepted]]} = render_upload(input, "notes.txt")
      assert render(view) =~ "Choose .milk presets or .zip archives."
      assert has_element?(view, "#milkdrop-upload-submit[disabled]")
    end

    test "at most 20 files", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/audio/milkdrop")
      files = for i <- 1..21, do: file("p#{i}.milk", milk())
      input = file_input(view, @form, :presets, files)

      assert {:error, [[_ref, :too_many_files]]} = render_upload(input, "p1.milk")
      assert render(view) =~ "Choose at most 20 files at a time."
    end

    test "a file over 32 MiB is refused", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/audio/milkdrop")

      input =
        file_input(view, @form, :presets, [file("big.zip", :binary.copy("a", 32 * @mib + 1))])

      assert {:error, [[_ref, :too_large]]} = render_upload(input, "big.zip")
      assert render(view) =~ "Larger than 32 MiB, the upload limit."
    end

    test "the writer cuts off an upload past the library's cap", %{conn: conn} = ctx do
      restart_user_presets(ctx, max_upload_bytes: 100)
      {:ok, view, _html} = live(conn, "/audio/milkdrop")

      input =
        file_input(view, @form, :presets, [file("e.milk", milk(String.duplicate("x", 200)))])

      render_upload(input, "e.milk")
      assert render(view) =~ "Larger than 100 B, the upload limit."
      wait_until(fn -> incoming_files(ctx) == [] end)
    end

    test "a batch over the library quota is refused", %{conn: conn} = ctx do
      restart_user_presets(ctx, quota: %{bytes: 300})
      {:ok, view, _html} = live(conn, "/audio/milkdrop")
      body = milk(String.duplicate("x", 200))
      input = file_input(view, @form, :presets, [file("f.milk", body), file("g.milk", body)])

      render_upload(input, "f.milk")
      assert render(view) =~ "These files add up to more than 300 B."
      assert has_element?(view, "#milkdrop-upload-batch-over")
      assert has_element?(view, "#milkdrop-upload-submit[disabled]")
      assert incoming_files(ctx) == []
    end

    test "each upload counts once against the free room", %{conn: conn} = ctx do
      # 2,000 bytes above the floor (max(200 MiB, 10% of 1000 MiB)).
      agent = start_supervised!({Agent, fn -> 200 * @mib + 2000 end})

      restart_user_presets(ctx,
        free_space: fn _ ->
          {:ok, %{total_bytes: 1000 * @mib, free_bytes: Agent.get(agent, & &1)}}
        end
      )

      {:ok, view, _html} = live(conn, "/audio/milkdrop")
      body = milk(String.duplicate("x", 1000 - byte_size(milk())))
      files = [file("m.milk", body), file("n.milk", body), file("o.milk", body)]
      input = file_input(view, @form, :presets, files)

      # Each finished file is what df no longer reports free.
      assert render_upload(input, "m.milk") =~ "100%"
      Agent.update(agent, &(&1 - 1000))
      assert render_upload(input, "n.milk") =~ "100%"
      Agent.update(agent, &(&1 - 1000))

      render_upload(input, "o.milk")
      assert render(view) =~ "Not enough free storage on the device."
      assert length(incoming_files(ctx)) == 2
    end

    test "too little free storage refuses the upload", %{conn: conn} = ctx do
      restart_user_presets(ctx, free_bytes: 150 * @mib)
      {:ok, view, _html} = live(conn, "/audio/milkdrop")
      input = file_input(view, @form, :presets, [file("h.milk", milk())])

      render_upload(input, "h.milk")
      assert render(view) =~ "Not enough free storage on the device."
      assert incoming_files(ctx) == []
    end
  end

  describe "cancelling" do
    test "removing a half-sent upload deletes its file", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, "/audio/milkdrop")

      input =
        file_input(view, @form, :presets, [file("i.milk", milk(String.duplicate("x", 4000)))])

      assert render_upload(input, "i.milk", 50) =~ "50%"
      assert [part] = incoming_files(ctx)
      assert part =~ ~r/\Aup-[0-9a-f]{24}\.part\z/

      view
      |> element("#milkdrop-upload-entries button[aria-label='Remove i.milk']")
      |> render_click()

      wait_until(fn -> incoming_files(ctx) == [] end)
      refute has_element?(view, "#milkdrop-upload-entries")
    end

    test "removing a finished upload deletes its file", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, "/audio/milkdrop")
      input = file_input(view, @form, :presets, [file("j.milk", milk())])

      assert render_upload(input, "j.milk") =~ "100%"
      assert [_part] = incoming_files(ctx)

      view
      |> element("#milkdrop-upload-entries button[aria-label='Remove j.milk']")
      |> render_click()

      wait_until(fn -> incoming_files(ctx) == [] end)
    end

    test "a finished upload is deleted when the page goes away", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, "/audio/milkdrop")
      input = file_input(view, @form, :presets, [file("k.milk", milk())])

      assert render_upload(input, "k.milk") =~ "100%"
      assert [_part] = incoming_files(ctx)

      Process.flag(:trap_exit, true)
      ref = Process.monitor(view.pid)

      capture_log(fn ->
        Process.exit(view.pid, :kill)
        assert_receive {:DOWN, ^ref, :process, _pid, :killed}, 2_000
        wait_until(fn -> incoming_files(ctx) == [] end)
      end)
    end
  end
end
