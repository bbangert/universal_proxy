defmodule UniversalProxyWeb.MilkDropPresetsLiveTest do
  @moduledoc """
  The preset browser at `/audio/milkdrop`, against a real Store (tmp
  DETS), Pack (a pre-extracted tmp pack), UserPresets (a tmp library) and
  Index under their global names, which the host leaves free
  (`MilkDrop.Supervisor` is `:ignore` here), and a fake
  `UniversalProxy.Display.State` named by the `:milkdrop_display` app env.
  """

  # async: false — global process names, app env and global PubSub topics.
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest
  import Phoenix.ConnTest
  import UniversalProxy.MilkDropIndexFixtures

  alias UniversalProxy.MilkDrop
  alias UniversalProxy.MilkDrop.{Index, Pack, Store, UserPresets}

  @endpoint UniversalProxyWeb.Endpoint
  @pubsub UniversalProxy.PubSub
  @version "2026.11.1"
  @display :milkdrop_presets_live_test_display
  @uploads :milkdrop_presets_live_test_uploads
  @mib 1024 * 1024
  @hostile "<img src=x onerror=alert(1)>.milk"

  @moduletag :tmp_dir

  defmodule FakeDisplay do
    @moduledoc false
    use GenServer

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

    def set_reply(server, reply), do: GenServer.call(server, {:set_reply, reply})

    @impl true
    def init(opts), do: {:ok, %{test: Keyword.fetch!(opts, :test), reply: :ok}}

    @impl true
    def handle_call({:set_reply, reply}, _from, state), do: {:reply, :ok, %{state | reply: reply}}

    def handle_call({:milkdrop_play, id, lock?}, _from, state) do
      send(state.test, {:play, id, lock?})

      case state.reply do
        {:delay, ms, reply} ->
          Process.sleep(ms)
          {:reply, reply, state}

        reply ->
          {:reply, reply, state}
      end
    end

    def handle_call(:milkdrop_now_playing, _from, state),
      do: {:reply, UniversalProxy.Display.State.idle_now_playing(), state}
  end

  setup %{tmp_dir: tmp_dir} do
    Application.put_env(:universal_proxy, :milkdrop_ui_override, true)
    Application.put_env(:universal_proxy, :milkdrop_display, @display)

    on_exit(fn ->
      for key <- [:milkdrop_ui_override, :milkdrop_display, :milkdrop_rpi3_hints],
          do: Application.delete_env(:universal_proxy, key)
    end)

    root = Path.join(tmp_dir, "milkdrop")

    write_pack!(
      root,
      @version,
      [
        @hostile,
        %{"file" => "high_frequency/Flash.milk", "rpi3" => %{"rung" => "640x360"}},
        %{
          "file" => "Geiss - Flux.milk",
          "rpi3" => %{"rung" => "skip", "reason" => "register_allocate"}
        }
      ] ++ pack_ids(200)
    )

    seed_uploads!(root, ["Mine.milk"])

    store =
      start_supervised!(
        {Store,
         table: :milkdrop_presets_live_test,
         dets_path: Path.join(tmp_dir, "settings.dets"),
         pack_version: @version,
         user_sha: &UserPresets.sha256(@uploads, &1)}
      )

    start_supervised!(
      {UserPresets,
       root: root,
       table: @uploads,
       store: store,
       task_supervisor: start_supervised!(Task.Supervisor, id: :upload_tasks),
       free_space: fn _ -> {:ok, %{total_bytes: 1000 * @mib, free_bytes: 900 * @mib}} end,
       pack_textures: fn -> [] end}
    )

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

    display = start_supervised!({FakeDisplay, name: @display, test: self()})

    {:ok, conn: build_conn(), root: root, display: display}
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

  defp doc(view), do: view |> render() |> LazyHTML.from_fragment()

  defp rows(view), do: doc(view) |> LazyHTML.query("#presets > li") |> Enum.count()

  defp row_sel(id), do: "#preset-#{Index.key(id)}"

  defp has_row?(view, id), do: has_element?(view, row_sel(id))

  defp key(id), do: Index.key(id)

  defp pressed?(view, button, id),
    do: view |> element("##{button}-#{key(id)}") |> render() =~ ~s(aria-pressed="true")

  defp row_html(view, id), do: view |> element(row_sel(id)) |> render()

  describe "gating and the dead render" do
    test "navigates to /audio while MilkDrop is disabled", %{conn: conn} do
      Application.put_env(:universal_proxy, :milkdrop_ui_override, false)
      assert {:error, {:live_redirect, %{to: "/audio"}}} = live(conn, "/audio/milkdrop")
    end

    test "the dead render shows a loading state and no rows", %{conn: conn} do
      html = conn |> get("/audio/milkdrop") |> html_response(200)
      assert html =~ "Loading presets…"
      assert html |> LazyHTML.from_document() |> LazyHTML.query("#presets > li") |> Enum.empty?()
    end

    test "the Audio tab stays highlighted", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/audio/milkdrop")
      assert has_element?(view, ~s(nav a[href="/audio"].text-accent))
      refute has_element?(view, ~s(nav a[href="/"].text-accent))
    end
  end

  describe "list and paging" do
    test "connects with the first page and the filter counts", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/audio/milkdrop")

      assert rows(view) == 50
      assert has_row?(view, @hostile)
      assert has_element?(view, "#presets[phx-viewport-bottom=next_page]")
      refute has_element?(view, "#presets[phx-viewport-top]")
      assert has_element?(view, "#presets-more")
      assert view |> element("#presets-count") |> render() =~ "204 presets"
      assert view |> element("label", "Uploaded") |> render() =~ ">1<"
    end

    test "pages forward and back with at most 150 rows in the DOM", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/audio/milkdrop")

      render_hook(view, "next_page", %{})
      render_hook(view, "next_page", %{})
      assert rows(view) == 150
      assert has_row?(view, @hostile)

      render_hook(view, "next_page", %{})
      assert rows(view) == 150
      refute has_row?(view, @hostile)
      assert has_element?(view, "#presets[phx-viewport-top=prev_page]")
      assert has_element?(view, "#presets-prev")

      # The last page (4 rows): the top page goes, the list ends.
      view |> element("#presets-more") |> render_click()
      assert rows(view) == 104
      assert has_row?(view, "Preset 200.milk")
      refute has_element?(view, "#presets[phx-viewport-bottom]")
      refute has_element?(view, "#presets-more")

      render_hook(view, "prev_page", %{})
      assert rows(view) == 150
      refute has_row?(view, "Preset 200.milk")
      assert has_element?(view, "#presets-more")

      view |> element("#presets-prev") |> render_click()
      assert rows(view) == 150
      assert has_row?(view, @hostile)
      refute has_element?(view, "#presets[phx-viewport-top]")
    end

    test "an index rebuild reloads the first page", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/audio/milkdrop")
      render_hook(view, "next_page", %{})
      render_hook(view, "next_page", %{})
      render_hook(view, "next_page", %{})
      refute has_row?(view, @hostile)

      send(view.pid, {:milkdrop_index, %{rebuilt: true, added: [], changed: [], removed: []}})
      assert rows(view) == 50
      assert has_row?(view, @hostile)
    end

    test "a change to an unloaded row doesn't add it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/audio/milkdrop")
      far = "Preset 150.milk"
      {:ok, _} = Store.favourite(far, true)
      assert_receive {:milkdrop_index, %{changed: [_]}}, 1_000

      send(
        view.pid,
        {:milkdrop_index, %{rebuilt: false, added: [], changed: [key(far)], removed: []}}
      )

      assert rows(view) == 50
      refute has_row?(view, far)
      assert view |> element("label", "Favourites") |> render() =~ ">1<"
    end

    test "with no index the page renders empty", %{conn: conn} do
      stop_supervised!(Index)
      {:ok, view, _html} = live(conn, "/audio/milkdrop")
      assert rows(view) == 0
      assert render(view) =~ "The preset pack lists no presets."
    end
  end

  describe "search and filters" do
    test "search patches the URL and lists only matches", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/audio/milkdrop")

      view |> form("#preset-search", %{q: "FLUX", filter: "all"}) |> render_change()
      assert_patch(view, "/audio/milkdrop?filter=all&q=FLUX")
      assert rows(view) == 1
      assert has_row?(view, "Geiss - Flux.milk")
      assert view |> element("#presets-count") |> render() =~ "1 preset match"

      view |> form("#preset-search", %{q: "nothing like this", filter: "all"}) |> render_change()
      assert rows(view) == 0
      assert has_element?(view, "#presets-empty", "No presets match your search.")

      view |> element("#preset-q-clear") |> render_click()
      assert_patch(view, "/audio/milkdrop?filter=all")
      assert rows(view) == 50
    end

    test "a filter chip patches the URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/audio/milkdrop")
      view |> form("#preset-search", %{q: "", filter: "uploaded"}) |> render_change()
      assert_patch(view, "/audio/milkdrop?filter=uploaded")
      assert rows(view) == 1
      assert row_html(view, "user/Mine.milk") =~ "Uploaded"
      assert view |> element("#presets-upload-warning") |> render() =~ "photosensitive epilepsy"
    end

    test "skipped, hidden and fast-flashing filters, with their badges", %{conn: conn} do
      :ok = Store.skip(@version, "Preset 007.milk", "gpu_hang")
      {:ok, _} = Store.hide("Preset 008.milk", true)
      assert_receive {:milkdrop_index, _}, 1_000

      {:ok, view, _html} = live(conn, "/audio/milkdrop?filter=skipped")
      assert rows(view) == 1
      assert row_html(view, "Preset 007.milk") =~ "Skipped: Hung the GPU"

      {:ok, view, _html} = live(conn, "/audio/milkdrop?filter=hidden")
      assert rows(view) == 1
      assert row_html(view, "Preset 008.milk") =~ "Hidden"

      {:ok, view, _html} = live(conn, "/audio/milkdrop")
      refute has_row?(view, "Preset 008.milk")

      {:ok, view, _html} = live(conn, "/audio/milkdrop?filter=fast-flashing")
      assert rows(view) == 1
      assert row_html(view, "high_frequency/Flash.milk") =~ "Fast-flashing"
      assert view |> element("#presets-hf-warning") |> render() =~ "photosensitive epilepsy"
    end

    test "an unknown filter falls back to all", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/audio/milkdrop?filter=bogus&q=")
      assert has_element?(view, "#preset-filter-all[checked]")
      assert rows(view) == 50
    end

    test "rpi3 hints show only on rpi3", %{conn: conn} do
      Application.put_env(:universal_proxy, :milkdrop_rpi3_hints, true)
      {:ok, view, _html} = live(conn, "/audio/milkdrop?q=l")
      assert row_html(view, "high_frequency/Flash.milk") =~ "640×360"
      assert row_html(view, "Geiss - Flux.milk") =~ "Not on this board: Too complex for the GPU"

      Application.put_env(:universal_proxy, :milkdrop_rpi3_hints, false)
      {:ok, view, _html} = live(conn, "/audio/milkdrop?q=l")
      refute row_html(view, "high_frequency/Flash.milk") =~ "640×360"
      refute row_html(view, "Geiss - Flux.milk") =~ "Not on this board"
    end
  end

  describe "selection actions" do
    test "favourite writes the Store and re-renders the row; repeats are idempotent", %{
      conn: conn
    } do
      id = "Preset 001.milk"
      {:ok, view, _html} = live(conn, "/audio/milkdrop")
      refute pressed?(view, "favourite", id)

      view |> element("#favourite-#{key(id)}") |> render_click()
      assert id in Store.selection().favourites
      wait_until(fn -> pressed?(view, "favourite", id) end)

      render_click(view, "favourite", %{"key" => key(id), "value" => "true"})
      assert id in Store.selection().favourites
    end

    test "un-starring under the favourites filter removes the row", %{conn: conn} do
      id = "Preset 002.milk"
      {:ok, _} = Store.favourite(id, true)
      assert_receive {:milkdrop_index, _}, 1_000

      {:ok, view, _html} = live(conn, "/audio/milkdrop?filter=favourites")
      assert rows(view) == 1
      view |> element("#favourite-#{key(id)}") |> render_click()
      wait_until(fn -> rows(view) == 0 end)
      refute id in Store.selection().favourites
    end

    test "hide and playlist toggle the Store", %{conn: conn} do
      id = "Preset 003.milk"
      {:ok, view, _html} = live(conn, "/audio/milkdrop")

      view |> element("#playlist-#{key(id)}") |> render_click()
      assert Store.selection().playlist == [id]
      wait_until(fn -> pressed?(view, "playlist", id) end)
      assert view |> element("#playlist-count") |> render() =~ "1 preset on the playlist"

      view |> element("#playlist-#{key(id)}") |> render_click()
      assert Store.selection().playlist == []

      view |> element("#hide-#{key(id)}") |> render_click()
      assert Store.selection().hidden == [id]
      # Hidden rows leave the "all" list.
      wait_until(fn -> not has_row?(view, id) end)
    end

    test "unknown keys are ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/audio/milkdrop")

      for key <- ["zzzzzzzzzzzz", "Preset 001.milk", "../../etc/passwd", ""] do
        render_click(view, "favourite", %{"key" => key, "value" => "true"})
        render_click(view, "play", %{"key" => key})
        render_click(view, "ask_delete", %{"key" => key})
      end

      render_click(view, "favourite", %{"key" => key("Preset 001.milk"), "value" => "yes"})
      assert Store.selection().favourites == []
      refute_received {:play, _, _}
      refute has_element?(view, "#confirm-delete")
    end

    test "playlist on/off and clear with confirmation", %{conn: conn} do
      {:ok, _} = Store.playlist_add("Preset 001.milk")
      {:ok, _} = Store.playlist_add("Preset 002.milk")
      assert_receive {:milkdrop_index, _}, 1_000
      {:ok, view, _html} = live(conn, "/audio/milkdrop")

      view |> element("#playlist-toggle") |> render_click()
      assert Store.selection().playlist_enabled

      wait_until(fn ->
        view |> element("#playlist-toggle") |> render() =~ ~s(aria-checked="true")
      end)

      view |> element("#playlist-clear") |> render_click()
      assert view |> element("#confirm-clear-playlist") |> render() =~ "Removes 2 presets"
      view |> element("#confirm-clear-playlist-button") |> render_click()
      assert Store.selection().playlist == []
      assert Store.selection().playlist_enabled
      wait_until(fn -> not pressed?(view, "playlist", "Preset 001.milk") end)
      # On, with nothing on it: every preset rotates.
      assert has_element?(view, "#playlist-fallback")
    end
  end

  describe "play and lock" do
    test "play calls the display and flashes the result", %{conn: conn, display: display} do
      FakeDisplay.set_reply(display, {:delay, 300, :ok})
      {:ok, view, _html} = live(conn, "/audio/milkdrop")
      view |> element("#play-#{key("Preset 001.milk")}") |> render_click()
      assert has_element?(view, "#now-playing-pending", "Starting Preset 001…")
      assert_receive {:play, "Preset 001.milk", false}
      render_async(view, 2_000)
      assert render(view) =~ "Showing Preset 001 on the TV."
      refute has_element?(view, "#now-playing-pending")
    end

    test "a refusal is explained", %{conn: conn, display: display} do
      FakeDisplay.set_reply(display, {:error, {:refused, :skipped}})
      {:ok, view, _html} = live(conn, "/audio/milkdrop")
      view |> element("#play-#{key("Preset 001.milk")}") |> render_click()
      render_async(view)
      assert render(view) =~ "Preset 001 is skipped on this device."
    end

    test "lock while not presenting saves the lock for the next session", %{conn: conn} do
      Application.put_env(:universal_proxy, :milkdrop_display, :milkdrop_presets_live_no_display)
      id = "Preset 004.milk"
      {:ok, view, _html} = live(conn, "/audio/milkdrop")

      view |> element("#lock-#{key(id)}") |> render_click()
      render_async(view)
      assert render(view) =~ "MilkDrop isn&#39;t on screen; it will start on Preset 004."
      assert Store.settings().locked == id
      wait_until(fn -> row_html(view, id) =~ "Locked" end)

      assert view |> element("#now-playing-locked") |> render() =~
               "It will start locked on Preset 004."

      assert pressed?(view, "lock", id)

      view |> element("#unlock") |> render_click()
      assert Store.settings().locked == nil
      wait_until(fn -> not (row_html(view, id) =~ "Locked") end)
      refute has_element?(view, "#unlock")
    end

    test "play without a visualizer session says so", %{conn: conn} do
      Application.put_env(:universal_proxy, :milkdrop_display, :milkdrop_presets_live_no_display)
      {:ok, view, _html} = live(conn, "/audio/milkdrop")
      view |> element("#play-#{key("Preset 001.milk")}") |> render_click()
      render_async(view)
      assert render(view) =~ "MilkDrop isn&#39;t on screen. Pick it as the TV display mode"
      assert Store.settings().locked == nil
    end

    test "a fast-flashing preset isn't played while those are off", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/audio/milkdrop")
      view |> element("#play-#{key("high_frequency/Flash.milk")}") |> render_click()
      assert render(view) =~ "Flash is fast-flashing. Include fast-flashing presets"
      refute_received {:play, _, _}

      {:ok, _} = Store.update(%{include_high_frequency: true})
      view |> element("#play-#{key("high_frequency/Flash.milk")}") |> render_click()
      assert_receive {:play, "high_frequency/Flash.milk", false}
    end

    test "now playing marks the header and the row", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/audio/milkdrop")
      a = "Preset 001.milk"
      b = "Preset 002.milk"

      Phoenix.PubSub.broadcast(
        @pubsub,
        MilkDrop.now_playing_topic(),
        {:milkdrop_now_playing, %{preset: a, locked: true, selection: nil}}
      )

      wait_until(fn -> row_html(view, a) =~ "On the TV" end)
      assert view |> element("#now-playing") |> render() =~ "Locked"
      assert view |> element("#now-playing-name") |> render() =~ "Preset 001"

      Phoenix.PubSub.broadcast(
        @pubsub,
        MilkDrop.now_playing_topic(),
        {:milkdrop_now_playing,
         %{
           preset: b,
           locked: false,
           selection: %{gen: 1, eligible: 3, playlist_fallback: false, hidden_fallback: true}
         }}
      )

      wait_until(fn -> row_html(view, b) =~ "On the TV" end)
      refute row_html(view, a) =~ "On the TV"
      assert has_element?(view, "#hidden-fallback")
    end
  end

  describe "uploads" do
    test "only uploads can be deleted, after confirmation", %{conn: conn, root: root} do
      id = "user/Mine.milk"
      {:ok, view, _html} = live(conn, "/audio/milkdrop")
      refute has_element?(view, "#delete-#{key("Preset 001.milk")}")
      render_click(view, "ask_delete", %{"key" => key("Preset 001.milk")})
      refute has_element?(view, "#confirm-delete")

      view |> element("#delete-#{key(id)}") |> render_click()
      assert has_element?(view, "#confirm-delete", "Delete Mine?")
      view |> element("#confirm-delete button", "Cancel") |> render_click()
      refute has_element?(view, "#confirm-delete")
      assert File.exists?(Path.join([root, "user", "presets", "Mine.milk"]))

      view |> element("#delete-#{key(id)}") |> render_click()
      view |> element("#confirm-delete-button") |> render_click()
      refute File.exists?(Path.join([root, "user", "presets", "Mine.milk"]))
      assert render(view) =~ "Deleted Mine."
      wait_until(fn -> not has_row?(view, id) end)

      # A confirm with nothing pending does nothing.
      render_click(view, "confirm", %{})
    end

    test "marking an upload fast-flashing, and unmarking it after a warning", %{conn: conn} do
      id = "user/Mine.milk"
      {:ok, view, _html} = live(conn, "/audio/milkdrop")
      refute has_element?(view, "#hf-#{key("Preset 001.milk")}")

      view |> element("#hf-#{key(id)}") |> render_click()
      assert [%{high_frequency: true}] = UserPresets.list().presets
      assert render(view) =~ "Marked Mine as fast-flashing"
      wait_until(fn -> pressed?(view, "hf", id) end)
      assert row_html(view, id) =~ "Fast-flashing"

      view |> element("#hf-#{key(id)}") |> render_click()
      assert view |> element("#confirm-clear-hf") |> render() =~ "photosensitive epilepsy"
      assert [%{high_frequency: true}] = UserPresets.list().presets
      view |> element("#confirm-clear-hf-button") |> render_click()
      assert [%{high_frequency: false}] = UserPresets.list().presets
    end
  end

  test "preset names are HTML-escaped", %{conn: conn} do
    {:ok, view, html} = live(conn, "/audio/milkdrop")
    html = html <> render(view)
    refute html =~ "<img src=x"
    assert html =~ "&lt;img src=x onerror=alert(1)&gt;"
    assert doc(view) |> LazyHTML.query("#presets img") |> Enum.count() == 0
  end
end
