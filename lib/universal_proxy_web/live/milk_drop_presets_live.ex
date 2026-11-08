defmodule UniversalProxyWeb.MilkDropPresetsLive do
  @moduledoc """
  The MilkDrop preset browser at `/audio/milkdrop`: every pack preset and
  upload, searchable and filtered (`?q=&filter=`, see
  `UniversalProxy.MilkDrop.Index.parse_filter/1`), with play now, lock,
  favourite, hide, the playlist and, for uploads, the fast-flashing flag
  and delete. Shown only while `UniversalProxyWeb.Components.MilkDropUI.enabled?/0`
  (else it navigates to `/audio`).

  ## List

  Rows come from `UniversalProxy.MilkDrop.Index` (ETS, read in this
  process) into a stream, #{50} per page, at most #{150} in the DOM: a
  page loaded past that drops the page at the far end. `@pages` keeps
  each loaded page's cursors and keys (no rows live in assigns). The
  dead render skips the query. The browser only ever sends a row's key,
  which `Index.fetch/2` resolves; an unknown key is ignored.

  ## Updates

  Subscribes (when connected) to the index, settings, pack and
  now-playing topics. An index change re-renders the loaded rows it
  names, drops those that no longer match, and inserts in place a row
  that now matches and falls inside the loaded range (one beyond it
  arrives by paging); a rebuild reloads the list. The now-playing
  preset's row is re-rendered when it changes. Index changes also
  refresh the upload component's quota line
  (`UniversalProxyWeb.MilkDropUploadComponent`, above the search form).
  Unlock goes through `UniversalProxy.MilkDrop.unlock/1`, so a running
  session resumes rotation too.

  ## Play now

  `UniversalProxy.MilkDrop.play/3` blocks until the TV shows the preset
  (up to 15 s), so it runs in `start_async/3`; its answer becomes a
  flash. Play, lock and unlock run one at a time in click order; a click
  made meanwhile waits, the latest replacing an earlier waiting one.
  Fast-flashing presets aren't played while they are filtered out (the
  renderer would refuse). A test seam, `:milkdrop_display` app env, names
  the `UniversalProxy.Display.State` server.
  """

  use UniversalProxyWeb, :live_view

  import UniversalProxyWeb.Components.UI
  import UniversalProxyWeb.Components.Icons
  import UniversalProxyWeb.Components.MilkDropUI

  alias UniversalProxy.Display
  alias UniversalProxy.MilkDrop
  alias UniversalProxy.MilkDrop.{Index, Pack, Store, UserPresets}
  alias UniversalProxyWeb.Components.MilkDropUI
  alias UniversalProxyWeb.MilkDropUploadComponent

  @page 50
  @max_rows 150

  @impl true
  def mount(_params, _session, socket) do
    if MilkDropUI.enabled?() do
      if connected?(socket) do
        for topic <- [
              Index.topic(),
              MilkDrop.settings_topic(),
              MilkDrop.pack_topic(),
              MilkDrop.now_playing_topic(),
              MilkDrop.selection_topic()
            ],
            do: Phoenix.PubSub.subscribe(UniversalProxy.PubSub, topic)
      end

      {:ok,
       socket
       |> assign(:page_title, "MilkDrop presets")
       |> assign(:settings, Store.settings())
       |> assign(:stored_playlist, length(Store.selection().playlist))
       |> assign(:pack, Pack.status())
       |> assign(:now_playing, read_now_playing(socket))
       |> assign(:rpi3_hints, MilkDrop.rpi3_hints?())
       |> assign(:q, "")
       |> assign(:query, Index.query(""))
       |> assign(:loaded, false)
       |> assign(:pages, [])
       |> assign(:at_start, true)
       |> assign(:at_end, true)
       |> assign_totals()
       |> assign(:confirm, nil)
       |> assign(:command, nil)
       |> assign(:queued, nil)
       |> stream_configure(:presets, dom_id: &"preset-#{&1.key}")
       |> stream(:presets, [])}
    else
      {:ok, push_navigate(socket, to: ~p"/audio")}
    end
  end

  defp assign_totals(socket) do
    totals = Index.counts("")

    socket
    |> assign(:counts, totals)
    |> assign(:totals, totals)
    |> assign(:playlist_enabled, Index.playlist_enabled?())
  end

  defp read_now_playing(socket) do
    if connected?(socket),
      do: MilkDrop.now_playing(display: display()),
      else: Display.State.idle_now_playing()
  end

  @impl true
  def handle_params(params, _uri, socket) do
    q = clean_q(params["q"])
    query = Index.query(q, Index.parse_filter(params["filter"]))
    socket = socket |> assign(:q, q) |> assign(:query, query)

    if connected?(socket), do: {:noreply, reset_list(socket)}, else: {:noreply, socket}
  end

  defp clean_q(q) when is_binary(q) do
    if String.valid?(q), do: q |> String.trim() |> String.slice(0, 64), else: ""
  end

  defp clean_q(_q), do: ""

  # ── List ──────────────────────────────────────────────────────────────

  defp reset_list(socket) do
    {rows, more?} = Index.page(socket.assigns.query, limit: @page)

    socket
    |> stream(:presets, decorate(socket, rows), reset: true)
    |> assign(:pages, page_of(rows))
    |> assign(:at_start, true)
    |> assign(:at_end, not more?)
    |> assign(:loaded, true)
    |> refresh_counts()
  end

  defp refresh_counts(socket) do
    counts = Index.counts(socket.assigns.query.q)

    socket
    |> assign(:counts, counts)
    |> assign(:totals, if(socket.assigns.query.q == "", do: counts, else: Index.counts("")))
    |> assign(:playlist_enabled, Index.playlist_enabled?())
  end

  defp page_of([]), do: []

  defp page_of(rows) do
    [
      %{
        first: Index.cursor(hd(rows)),
        last: Index.cursor(List.last(rows)),
        keys: Enum.map(rows, & &1.key)
      }
    ]
  end

  defp next_page(%{assigns: %{at_end: true}} = socket), do: socket
  defp next_page(%{assigns: %{pages: []}} = socket), do: reset_list(socket)

  defp next_page(socket) do
    last = List.last(socket.assigns.pages).last
    {rows, more?} = Index.page(socket.assigns.query, after: last, limit: @page)
    {pages, dropped} = trim(socket.assigns.pages ++ page_of(rows), :front)

    socket
    |> delete_keys(dropped)
    |> stream(:presets, decorate(socket, rows), at: -1, limit: -@max_rows)
    |> assign(:pages, pages)
    |> assign(:at_end, not more?)
    |> assign(:at_start, socket.assigns.at_start and dropped == [])
  end

  defp prev_page(%{assigns: %{at_start: true}} = socket), do: socket
  defp prev_page(%{assigns: %{pages: []}} = socket), do: reset_list(socket)

  defp prev_page(socket) do
    first = hd(socket.assigns.pages).first
    {rows, more?} = Index.page(socket.assigns.query, before: first, limit: @page)
    {pages, dropped} = trim(page_of(rows) ++ socket.assigns.pages, :back)

    socket
    |> delete_keys(dropped)
    |> stream(:presets, socket |> decorate(rows) |> Enum.reverse(), at: 0, limit: @max_rows)
    |> assign(:pages, pages)
    |> assign(:at_start, not more?)
    |> assign(:at_end, socket.assigns.at_end and dropped == [])
  end

  # Drops whole pages from one end until at most @max_rows keys remain.
  defp trim(pages, side, dropped \\ []) do
    if pages |> Enum.map(&length(&1.keys)) |> Enum.sum() > @max_rows do
      case side do
        :front -> trim(tl(pages), side, dropped ++ hd(pages).keys)
        :back -> trim(Enum.drop(pages, -1), side, dropped ++ List.last(pages).keys)
      end
    else
      {pages, dropped}
    end
  end

  defp delete_keys(socket, keys) do
    socket =
      Enum.reduce(keys, socket, &stream_delete_by_dom_id(&2, :presets, "preset-#{&1}"))

    drop = MapSet.new(keys)

    pages =
      Enum.map(socket.assigns.pages, &%{&1 | keys: Enum.reject(&1.keys, fn k -> k in drop end)})

    assign(socket, :pages, pages)
  end

  defp decorate(socket, rows) do
    playing = socket.assigns.now_playing.preset
    Enum.map(rows, &Map.put(&1, :playing, &1.id == playing))
  end

  # Brings the loaded rows of these keys up to date: a matching row is
  # re-rendered where it is; one that no longer matches (or is gone) is
  # dropped. Rows that now match and fall inside the loaded range (rows
  # beyond it arrive by paging) are merged into the window, which is then
  # re-streamed whole: its final pages are worked out first, so the DOM
  # gets exactly them (a stream delete doesn't cancel an insert made in
  # the same render).
  defp refresh_rows(socket, keys) do
    {gone, loaded, new} =
      keys
      |> Enum.uniq()
      |> Enum.reduce({[], [], []}, fn key, {gone, loaded, new} ->
        with {:ok, row} <- Index.fetch(key),
             true <- Index.matches?(row, socket.assigns.query) do
          cond do
            loaded?(socket, key) -> {gone, [row | loaded], new}
            in_range?(socket, Index.cursor(row)) -> {gone, loaded, [row | new]}
            true -> {gone, loaded, new}
          end
        else
          _ -> {[key | gone], loaded, new}
        end
      end)

    socket = delete_keys(socket, gone)

    if new == [] do
      Enum.reduce(decorate(socket, loaded), socket, fn row, socket ->
        stream_insert(socket, :presets, row, update_only: true)
      end)
    else
      merge_rows(socket, new)
    end
  end

  defp loaded?(socket, key), do: Enum.any?(socket.assigns.pages, &(key in &1.keys))

  defp in_range?(%{assigns: %{pages: []}} = socket, _cursor),
    do: socket.assigns.at_start and socket.assigns.at_end

  # Inclusive: a page keeps its edge cursors when their rows leave, and a
  # row coming back at one is neither loaded nor reached by paging.
  defp in_range?(socket, cursor) do
    %{pages: pages, at_start: at_start, at_end: at_end} = socket.assigns
    (at_start or cursor >= hd(pages).first) and (at_end or cursor <= List.last(pages).last)
  end

  # The window's rows plus `new`, in name order, cut into pages anew (the
  # outer cursors kept) and trimmed from the end to @max_rows.
  defp merge_rows(socket, new) do
    old = socket.assigns.pages

    rows =
      old
      |> Enum.flat_map(& &1.keys)
      |> Enum.flat_map(fn key ->
        case Index.fetch(key) do
          {:ok, row} -> [row]
          :error -> []
        end
      end)
      |> Enum.concat(new)
      |> Enum.uniq_by(& &1.key)
      |> Enum.sort_by(&Index.cursor/1)

    pages = rows |> Enum.chunk_every(@page) |> Enum.flat_map(&page_of/1) |> keep_bounds(old)
    {pages, dropped} = trim(pages, :back)
    kept = MapSet.new(Enum.flat_map(pages, & &1.keys))
    rows = Enum.filter(rows, &MapSet.member?(kept, &1.key))

    socket
    |> stream(:presets, decorate(socket, rows), reset: true)
    |> assign(:pages, pages)
    |> assign(:at_end, socket.assigns.at_end and dropped == [])
  end

  defp keep_bounds(pages, []), do: pages

  defp keep_bounds(pages, old) do
    [first | rest] = pages
    pages = [%{first | first: min(first.first, hd(old).first)} | rest]
    last = List.last(pages)
    List.replace_at(pages, -1, %{last | last: max(last.last, List.last(old).last)})
  end

  # ── Events ────────────────────────────────────────────────────────────

  @impl true
  def handle_event("search", params, socket) do
    q = clean_q(params["q"])
    filter = Index.parse_filter(params["filter"])
    replace = filter == socket.assigns.query.filter
    {:noreply, push_patch(socket, to: browse_path(q, filter), replace: replace)}
  end

  def handle_event("clear_search", _params, socket),
    do: {:noreply, push_patch(socket, to: browse_path("", socket.assigns.query.filter))}

  def handle_event("next_page", _params, socket), do: {:noreply, next_page(socket)}
  def handle_event("prev_page", _params, socket), do: {:noreply, prev_page(socket)}

  def handle_event("play", %{"key" => key}, socket),
    do: {:noreply, with_row(socket, key, &play(&1, &2, false))}

  def handle_event("lock", %{"key" => key}, socket),
    do: {:noreply, with_row(socket, key, &play(&1, &2, true))}

  def handle_event("unlock", _params, socket), do: {:noreply, submit(socket, %{kind: :unlock})}

  def handle_event(event, %{"key" => key, "value" => value}, socket)
      when event in ["favourite", "hide", "playlist"] and value in ["true", "false"] do
    flag = value == "true"
    {:noreply, with_row(socket, key, &select(&1, &2, event, flag))}
  end

  def handle_event("set_hf", %{"key" => key, "value" => value}, socket)
      when value in ["true", "false"] do
    {:noreply,
     with_row(socket, key, fn
       socket, %{source: :user} = row when value == "true" -> set_hf(socket, row, true)
       socket, %{source: :user} = row -> assign(socket, :confirm, {:clear_hf, row})
       socket, _pack_row -> socket
     end)}
  end

  def handle_event("ask_delete", %{"key" => key}, socket) do
    {:noreply,
     with_row(socket, key, fn
       socket, %{source: :user} = row -> assign(socket, :confirm, {:delete, row})
       socket, _pack_row -> socket
     end)}
  end

  def handle_event("ask_clear_playlist", _params, socket),
    do: {:noreply, assign(socket, :confirm, :clear_playlist)}

  def handle_event("cancel_confirm", _params, socket),
    do: {:noreply, assign(socket, :confirm, nil)}

  # Acts on the dialog's own state, never on client params.
  def handle_event("confirm", _params, socket) do
    case socket.assigns.confirm do
      nil -> {:noreply, socket}
      confirm -> {:noreply, socket |> assign(:confirm, nil) |> confirmed(confirm)}
    end
  end

  def handle_event("toggle_playlist", _params, socket) do
    case Store.set_playlist_enabled(not socket.assigns.playlist_enabled) do
      {:ok, selection} ->
        {:noreply, assign(socket, :playlist_enabled, selection.playlist_enabled)}

      {:error, reason} ->
        {:noreply, selection_error(socket, reason)}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp confirmed(socket, {:delete, row}) do
    # The row may have changed (or gone) since the dialog opened.
    case Index.fetch(row.key) do
      {:ok, %{source: :user, id: id}} ->
        case UserPresets.delete(id) do
          :ok ->
            put_flash(socket, :info, "Deleted #{row.name}.")

          {:error, reason} ->
            put_flash(socket, :error, "Couldn't delete #{row.name} (#{library_error(reason)}).")
        end

      _gone ->
        socket
    end
  end

  defp confirmed(socket, {:clear_hf, row}) do
    case Index.fetch(row.key) do
      {:ok, %{source: :user} = row} -> set_hf(socket, row, false)
      _gone -> socket
    end
  end

  defp confirmed(socket, :clear_playlist) do
    case Store.playlist_clear() do
      {:ok, _selection} -> put_flash(socket, :info, "Cleared the playlist.")
      {:error, reason} -> selection_error(socket, reason)
    end
  end

  defp with_row(socket, key, fun) do
    case Index.fetch(key) do
      {:ok, row} -> fun.(socket, row)
      :error -> socket
    end
  end

  defp select(socket, row, "favourite", flag),
    do: selection_result(socket, Store.favourite(row.id, flag))

  defp select(socket, row, "hide", flag), do: selection_result(socket, Store.hide(row.id, flag))

  defp select(socket, row, "playlist", true),
    do: selection_result(socket, Store.playlist_add(row.id))

  defp select(socket, row, "playlist", false),
    do: selection_result(socket, Store.playlist_remove(row.id))

  defp selection_result(socket, {:ok, _selection}), do: socket
  defp selection_result(socket, {:error, reason}), do: selection_error(socket, reason)

  defp selection_error(socket, reason),
    do: put_flash(socket, :error, "Couldn't save the selection (#{selection_text(reason)}).")

  defp set_hf(socket, row, flag) do
    case UserPresets.set_high_frequency(row.id, flag) do
      :ok when flag ->
        put_flash(
          socket,
          :info,
          "Marked #{row.name} as fast-flashing: it only plays while fast-flashing presets are included."
        )

      :ok ->
        put_flash(socket, :info, "#{row.name} is no longer marked as fast-flashing.")

      {:error, reason} ->
        put_flash(socket, :error, "Couldn't change #{row.name} (#{library_error(reason)}).")
    end
  end

  defp play(socket, row, lock?) do
    if row.high_frequency and not socket.assigns.settings.include_high_frequency do
      put_flash(socket, :error, play_text({:refused, :high_frequency}, row.name, lock?))
    else
      submit(socket, %{kind: :play, id: row.id, name: row.name, lock?: lock?})
    end
  end

  # Play, lock and unlock go out one at a time, in the order they were
  # clicked: separate tasks could reach Display.State out of order (a
  # delayed lock landing after an unlock). One command runs, and the
  # latest click waits behind it, replacing any earlier waiting one.
  defp submit(%{assigns: %{command: nil}} = socket, command), do: run(socket, command)
  defp submit(socket, command), do: assign(socket, :queued, command)

  defp run(socket, command) do
    display = display()

    fun =
      case command do
        %{kind: :play, id: id, lock?: lock?} ->
          fn -> MilkDrop.play(id, lock?, display: display) end

        %{kind: :unlock} ->
          fn -> MilkDrop.unlock(display: display) end
      end

    socket
    |> assign(:command, command)
    |> assign(:queued, nil)
    |> start_async(:command, fun)
  end

  @impl true
  def handle_async(:command, result, socket) do
    socket = socket |> report(socket.assigns.command, result) |> assign(:command, nil)

    case socket.assigns.queued do
      nil -> {:noreply, socket}
      queued -> {:noreply, run(socket, queued)}
    end
  end

  defp report(socket, _command, {:exit, _reason}),
    do: put_flash(socket, :error, "Couldn't reach the visualizer.")

  # The Store's broadcast (from the session's owner, or the fenced write
  # with no session) brings the new `locked`.
  defp report(socket, %{kind: :unlock}, {:ok, :ok}), do: socket

  defp report(socket, %{kind: :unlock}, {:ok, {:error, reason}}),
    do: put_flash(socket, :error, "Couldn't unlock (#{error_text(reason)}).")

  defp report(socket, %{kind: :play} = play, {:ok, :ok}),
    do: put_flash(socket, :info, play_text(:ok, play.name, play.lock?))

  defp report(socket, %{kind: :play}, {:ok, {:error, :superseded}}), do: socket

  defp report(socket, %{kind: :play} = play, {:ok, {:error, reason}}),
    do: put_flash(socket, :error, play_text(reason, play.name, play.lock?))

  # ── PubSub ────────────────────────────────────────────────────────────

  @impl true
  def handle_info({:milkdrop_index, %{rebuilt: true}}, socket) do
    refresh_upload()
    {:noreply, reset_list(socket)}
  end

  def handle_info({:milkdrop_index, %{} = change}, socket) do
    refresh_upload()

    {:noreply,
     socket
     |> delete_keys(Map.get(change, :removed, []))
     |> refresh_rows(Map.get(change, :added, []) ++ Map.get(change, :changed, []))
     |> refresh_counts()}
  end

  def handle_info({:milkdrop_settings, settings}, socket) when is_map(settings),
    do: {:noreply, assign(socket, :settings, settings)}

  # The Store served defaults until its table opened: read it again.
  def handle_info({:milkdrop_store, :opened}, socket) do
    {:noreply,
     socket
     |> assign(:settings, Store.settings())
     |> assign(:stored_playlist, length(Store.selection().playlist))}
  end

  def handle_info({:milkdrop_selection, %{playlist: playlist}}, socket) when is_list(playlist),
    do: {:noreply, assign(socket, :stored_playlist, length(playlist))}

  def handle_info({kind, status}, socket) when kind in [:milkdrop_pack, :milkdrop_pack_started],
    do: {:noreply, assign(socket, :pack, status)}

  def handle_info({:milkdrop_now_playing, now_playing}, socket) when is_map(now_playing) do
    old = socket.assigns.now_playing.preset
    socket = assign(socket, :now_playing, now_playing)

    if now_playing.preset == old do
      {:noreply, socket}
    else
      keys = for id <- [old, now_playing.preset], is_binary(id), do: Index.key(id)
      {:noreply, refresh_rows(socket, keys)}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp refresh_upload,
    do: send_update(MilkDropUploadComponent, id: "milkdrop-upload", refresh: true)

  defp playing(%{kind: :play} = play), do: play
  defp playing(_command), do: nil

  defp display, do: Application.get_env(:universal_proxy, :milkdrop_display, Display.State)

  defp browse_path(q, filter) do
    # A keyword list: a map's key order (and so the URL's) isn't stable.
    params = [filter: Index.filter_param(filter)] ++ if(q == "", do: [], else: [q: q])
    ~p"/audio/milkdrop?#{params}"
  end

  # ── Text ──────────────────────────────────────────────────────────────

  defp play_text(:ok, name, false), do: "Showing #{name} on the TV."
  defp play_text(:ok, name, true), do: "Locked on #{name}."

  defp play_text(:not_presenting, name, true),
    do: "MilkDrop isn't on screen; it will start on #{name}."

  defp play_text(:not_presenting, _name, false),
    do: "MilkDrop isn't on screen. Pick it as the TV display mode in Home Assistant first."

  defp play_text(:timeout, name, _lock?), do: "The TV didn't show #{name} in time."
  defp play_text(:invalid_id, name, _lock?), do: "#{name} can't be played."

  defp play_text({:refused, :unknown}, name, _lock?),
    do: "The visualizer doesn't have #{name} (yet). Try again in a moment."

  defp play_text({:refused, :skipped}, name, _lock?),
    do:
      "#{name} is skipped on this device. Clear skipped presets on the Audio tab to try it again."

  defp play_text({:refused, :high_frequency}, name, _lock?),
    do: "#{name} is fast-flashing. Include fast-flashing presets on the Audio tab to play it."

  defp play_text({:refused, :rpi3_skip}, name, _lock?), do: "#{name} can't play on this board."
  defp play_text({:refused, :load_failed}, name, _lock?), do: "#{name} failed to load."
  defp play_text({:refused, _reason}, name, _lock?), do: "The visualizer refused #{name}."
  defp play_text(_reason, name, _lock?), do: "Couldn't play #{name}."

  defp selection_text(:too_many), do: "that list is full"
  defp selection_text(:too_large), do: "the selection is too large"
  defp selection_text(:invalid_id), do: "that preset can't be selected"
  defp selection_text(reason), do: error_text(reason)

  defp library_error(:busy), do: "an import is running; try again when it's done"
  defp library_error(:not_found), do: "it's no longer in the library"
  defp library_error(:not_running), do: "the preset library isn't running"
  defp library_error({:io, posix}), do: "storage error: #{inspect(posix)}"
  defp library_error({:manifest, _reason}), do: "couldn't update the library's manifest"
  defp library_error(reason), do: inspect(reason)

  defp error_text(:not_running), do: "the settings store isn't running"
  defp error_text(reason), do: inspect(reason)

  defp missing_label(1), do: "1 saved preset isn't available."
  defp missing_label(n), do: "#{delimit(n)} saved presets aren't available."

  defp filter_label(:all), do: "All"
  defp filter_label(:favourites), do: "Favourites"
  defp filter_label(:playlist), do: "Playlist"
  defp filter_label(:uploaded), do: "Uploaded"
  defp filter_label(:hidden), do: "Hidden"
  defp filter_label(:skipped), do: "Skipped"
  defp filter_label(:fast_flashing), do: "Fast-flashing"

  defp name_of(id) when is_binary(id), do: Path.basename(id, ".milk")

  defp match_text(counts, query) do
    n = Map.fetch!(counts, query.filter)
    base = count_label(n, "preset")

    if query.q == "", do: base, else: "#{base} match “#{query.q}”"
  end

  defp empty_text(%{total: 0}, pack, _query), do: pack_hint(pack)
  defp empty_text(_totals, _pack, %{q: q}) when q != "", do: "No presets match your search."
  defp empty_text(_totals, _pack, %{filter: filter}), do: filter_empty(filter)

  defp filter_empty(:favourites), do: "No favourites yet. Star a preset to add it."
  defp filter_empty(:playlist), do: "The playlist is empty. Add presets with the playlist button."
  defp filter_empty(:uploaded), do: "No uploaded presets."
  defp filter_empty(:hidden), do: "No hidden presets."
  defp filter_empty(:skipped), do: "No skipped presets."
  defp filter_empty(:fast_flashing), do: "No fast-flashing presets."
  defp filter_empty(_all), do: "No presets."

  defp pack_hint({:downloading, pct}), do: "The preset pack is downloading (#{pct}%)."

  defp pack_hint({:ready, _version, _dir}) do
    if Index.manifest_error(),
      do: "The preset pack's manifest can't be read.",
      else: "The preset pack lists no presets."
  end

  defp pack_hint(_status),
    do: "The preset pack isn't downloaded yet. Download it on the Audio tab."

  # ── Render ────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-[960px] mx-auto">
      <div class="mb-5">
        <.link navigate={~p"/audio"} class="text-sm text-accent hover:underline inline-flex items-center gap-1">
          <.icon name={:chevron} size={12} stroke={2.2} class="rotate-90" /> Audio
        </.link>
        <h1 id="presets-heading" tabindex="-1" class="text-xl font-semibold mt-2 mb-1.5 text-fg-1">
          MilkDrop presets
        </h1>
        <p class="text-base text-fg-2 m-0 max-w-[640px]">
          Play a preset on the TV now, lock the visualizer to one, or pick favourites, a playlist and
          presets to hide from the rotation.
        </p>
      </div>

      <.now_playing_bar
        now_playing={@now_playing}
        settings={@settings}
        playing={playing(@command)}
      />

      <.playlist_bar
        enabled={@playlist_enabled}
        count={@totals.playlist}
        stored={@stored_playlist}
        now_playing={@now_playing}
      />

      <.live_component module={MilkDropUploadComponent} id="milkdrop-upload" class="block mt-5" />

      <form
        id="preset-search"
        role="search"
        phx-change="search"
        phx-submit="search"
        class="mt-5 flex flex-col gap-3"
      >
        <div class="relative">
          <label for="preset-q" class="sr-only">Search presets</label>
          <span class="absolute left-3 top-1/2 -translate-y-1/2 text-fg-3 pointer-events-none" aria-hidden="true">
            <.icon name={:search} size={16} />
          </span>
          <input
            type="search"
            id="preset-q"
            name="q"
            value={@q}
            placeholder="Search by name or author"
            maxlength="64"
            autocomplete="off"
            enterkeyhint="search"
            phx-debounce="300"
            class="h-10 pl-9 pr-10 w-full rounded-md text-base outline-none border border-border-strong
                   bg-surface text-fg-1 focus:border-accent focus:shadow-focus placeholder:text-fg-4"
          />
          <button
            :if={@q != ""}
            type="button"
            id="preset-q-clear"
            phx-click="clear_search"
            aria-label="Clear search"
            class="absolute right-1 top-1/2 -translate-y-1/2 w-8 h-8 inline-flex items-center justify-center
                   rounded-md text-fg-3 hover:bg-sunken"
          >
            <.icon name={:x} size={14} />
          </button>
        </div>

        <fieldset class="m-0 p-0 border-0 min-w-0">
          <legend class="sr-only">Filter presets</legend>
          <div class="flex gap-1.5 overflow-x-auto whitespace-nowrap pb-1">
            <label :for={filter <- Index.filters()} class="flex-none cursor-pointer">
              <input
                type="radio"
                name="filter"
                id={"preset-filter-#{Index.filter_param(filter)}"}
                value={Index.filter_param(filter)}
                checked={@query.filter == filter}
                class="sr-only peer"
              />
              <span class="inline-flex items-center gap-1.5 h-8 px-3 rounded-full text-sm border border-border-1
                           bg-surface text-fg-2 peer-checked:bg-accent-soft peer-checked:text-accent
                           peer-checked:border-accent-soft-border peer-focus-visible:shadow-focus">
                {filter_label(filter)}
                <span :if={@loaded} class="tabular-nums text-fg-3 text-xs">{delimit(Map.fetch!(@counts, filter))}</span>
              </span>
            </label>
          </div>
        </fieldset>
      </form>

      <.photosensitivity_warning :if={@query.filter == :fast_flashing} id="presets-hf-warning" class="mt-3">
        They play only while "Include fast-flashing presets" is on (Audio tab).
      </.photosensitivity_warning>

      <.photosensitivity_warning
        :if={@query.filter == :uploaded}
        id="presets-upload-warning"
        class="mt-3"
        lead="Rapidly flashing presets may trigger seizures in people with photosensitive epilepsy."
      >
        Uploads aren't screened for flashing: mark any that flash rapidly as fast-flashing (the
        lightning button) to keep them out of the rotation while fast-flashing presets are off.
      </.photosensitivity_warning>

      <p id="presets-count" aria-live="polite" class="text-sm text-fg-3 mt-4 mb-2">
        <%= if @loaded do %>
          {match_text(@counts, @query)}
        <% else %>
          Loading presets…
        <% end %>
      </p>

      <.card padding={:none} class="overflow-hidden">
        <button
          :if={!@at_start}
          type="button"
          id="presets-prev"
          phx-click="prev_page"
          class="w-full h-10 text-sm text-accent hover:bg-sunken border-b border-border-2"
        >
          Show earlier presets
        </button>

        <ul
          id="presets"
          role="list"
          aria-label="Presets"
          phx-update="stream"
          phx-viewport-top={!@at_start && "prev_page"}
          phx-viewport-bottom={!@at_end && "next_page"}
          class={[
            "m-0 p-0 list-none",
            if(@at_start, do: "", else: "pt-[200vh]"),
            if(@at_end, do: "", else: "pb-[200vh]")
          ]}
        >
          <li
            :for={{dom_id, row} <- @streams.presets}
            id={dom_id}
            class="flex flex-col sm:flex-row sm:items-center gap-2 px-4 py-3 border-t border-border-2 first:border-t-0"
          >
            <.preset_info row={row} rpi3_hints={@rpi3_hints} />
            <.preset_actions row={row} />
          </li>
        </ul>

        <div
          :if={@loaded and Map.fetch!(@counts, @query.filter) == 0}
          id="presets-empty"
          class="px-4 py-8 text-center text-sm text-fg-3"
        >
          {empty_text(@totals, @pack, @query)}
        </div>

        <button
          :if={!@at_end}
          type="button"
          id="presets-more"
          phx-click="next_page"
          class="w-full h-10 text-sm text-accent hover:bg-sunken border-t border-border-2"
        >
          Load more presets
        </button>
      </.card>

      <.confirm_modal confirm={@confirm} stored_playlist={@stored_playlist} />
    </div>
    """
  end

  attr(:row, :map, required: true)
  attr(:rpi3_hints, :boolean, required: true)

  defp preset_info(assigns) do
    ~H"""
    <div class="flex-1 min-w-0">
      <div class="flex items-center gap-1.5 flex-wrap">
        <span class="text-sm font-medium text-fg-1 truncate min-w-0 max-w-full" title={@row.id}>{@row.name}</span>
        <.badge :if={@row.playing} variant={:success} dot>On the TV</.badge>
        <.badge :if={@row.locked} variant={:accent}>Locked</.badge>
        <.badge :if={@row.source == :user} variant={:accent}>Uploaded</.badge>
        <.badge :if={@row.high_frequency} variant={:warning}>Fast-flashing</.badge>
        <.badge :if={@row.skip} variant={:danger}>Skipped: {reason_label(@row.skip)}</.badge>
        <.badge :if={@row.hidden} variant={:neutral}>Hidden</.badge>
        <%= if @rpi3_hints do %>
          <.badge :if={match?({:rung, _}, @row.rpi3)} variant={:neutral}>
            {rung_label(@row.rpi3)}
          </.badge>
          <.badge :if={match?({:skip, _}, @row.rpi3)} variant={:warning}>
            Not on this board{rpi3_reason(@row.rpi3)}
          </.badge>
        <% end %>
      </div>
      <div :if={@row.folder} class="text-xs text-fg-3 font-mono truncate mt-0.5">{@row.folder}</div>
    </div>
    """
  end

  defp rung_label({:rung, rung}), do: String.replace(rung, "x", "×")

  defp rpi3_reason({:skip, nil}), do: ""
  defp rpi3_reason({:skip, reason}), do: ": #{reason_label(reason)}"

  attr(:row, :map, required: true)

  defp preset_actions(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-1 flex-none">
      <.row_button
        id={"play-#{@row.key}"}
        event="play"
        key={@row.key}
        icon={:play}
        label={"Play #{@row.name} on the TV now"}
      />
      <.row_button
        :if={!@row.locked}
        id={"lock-#{@row.key}"}
        event="lock"
        key={@row.key}
        icon={:lock}
        pressed={false}
        label={"Lock the visualizer on #{@row.name}"}
      />
      <.row_button
        :if={@row.locked}
        id={"lock-#{@row.key}"}
        event="unlock"
        key={@row.key}
        icon={:lock}
        pressed={true}
        label={"Unlock #{@row.name}"}
      />
      <.row_button
        id={"favourite-#{@row.key}"}
        event="favourite"
        key={@row.key}
        value={"#{!@row.favourite}"}
        icon={:star}
        pressed={@row.favourite}
        label={"Favourite #{@row.name}"}
      />
      <.row_button
        id={"playlist-#{@row.key}"}
        event="playlist"
        key={@row.key}
        value={"#{!@row.playlist}"}
        icon={:list}
        pressed={@row.playlist}
        label={"#{@row.name} on the playlist"}
      />
      <.row_button
        id={"hide-#{@row.key}"}
        event="hide"
        key={@row.key}
        value={"#{!@row.hidden}"}
        icon={:eye_off}
        pressed={@row.hidden}
        label={"Hide #{@row.name} from the rotation"}
      />
      <.row_button
        :if={@row.source == :user}
        id={"hf-#{@row.key}"}
        event="set_hf"
        key={@row.key}
        value={"#{!@row.high_frequency}"}
        icon={:zap}
        pressed={@row.high_frequency}
        label={"#{@row.name} is fast-flashing"}
      />
      <.row_button
        :if={@row.source == :user}
        id={"delete-#{@row.key}"}
        event="ask_delete"
        key={@row.key}
        icon={:trash}
        danger
        label={"Delete #{@row.name}"}
      />
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:event, :string, required: true)
  attr(:key, :string, required: true)
  attr(:value, :string, default: nil)
  attr(:icon, :atom, required: true)
  attr(:label, :string, required: true)
  attr(:pressed, :any, default: nil)
  attr(:danger, :boolean, default: false)

  defp row_button(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      phx-click={@event}
      phx-value-key={@key}
      phx-value-value={@value}
      aria-label={@label}
      title={@label}
      aria-pressed={if is_boolean(@pressed), do: "#{@pressed}"}
      class={[
        "w-10 h-10 inline-flex items-center justify-center rounded-md border transition-colors",
        cond do
          @danger -> "border-transparent text-danger hover:bg-danger-soft"
          @pressed == true -> "border-accent-soft-border bg-accent-soft text-accent"
          true -> "border-transparent text-fg-2 hover:bg-sunken"
        end
      ]}
    >
      <.icon name={@icon} size={18} class={if(@pressed == true and @icon == :star, do: "fill-current")} />
    </button>
    """
  end

  attr(:now_playing, :map, required: true)
  attr(:settings, :map, required: true)
  attr(:playing, :any, required: true)

  defp now_playing_bar(assigns) do
    assigns = assign(assigns, :locked_id, assigns.settings.locked)

    ~H"""
    <.card id="now-playing" padding={:none} class="overflow-hidden">
      <div class="flex items-center gap-3 px-4 py-3">
        <div
          aria-hidden="true"
          class={[
            "flex-none w-9 h-9 rounded-[10px] flex items-center justify-center",
            if(@now_playing.preset, do: "bg-success-soft text-success", else: "bg-sunken text-fg-3")
          ]}
        >
          <.icon name={:play} size={16} stroke={1.8} />
        </div>
        <div class="flex-1 min-w-0">
          <%= if @now_playing.preset do %>
            <div class="text-xs text-fg-3">On the TV now</div>
            <div class="flex items-center gap-2 flex-wrap">
              <span id="now-playing-name" class="text-sm font-semibold text-fg-1 truncate" title={@now_playing.preset}>
                {name_of(@now_playing.preset)}
              </span>
              <.badge :if={@now_playing.locked} variant={:accent}>Locked</.badge>
            </div>
          <% else %>
            <div class="text-sm text-fg-2">MilkDrop isn't on the TV right now.</div>
            <div :if={@locked_id} id="now-playing-locked" class="text-xs text-fg-3 mt-0.5 truncate">
              It will start locked on {name_of(@locked_id)}.
            </div>
          <% end %>
          <div :if={@playing} id="now-playing-pending" role="status" class="text-xs text-fg-3 mt-0.5">
            Starting {@playing.name}…
          </div>
        </div>
        <.button
          :if={@locked_id || @now_playing.locked}
          id="unlock"
          variant={:secondary}
          size={:sm}
          phx-click="unlock"
        >
          <.icon name={:unlock} size={14} /> Unlock
        </.button>
      </div>
    </.card>
    """
  end

  attr(:enabled, :boolean, required: true)
  attr(:count, :integer, required: true)
  # The Store's playlist, ids no longer in the pack or library included.
  attr(:stored, :integer, required: true)
  attr(:now_playing, :map, required: true)

  defp playlist_bar(assigns) do
    selection = assigns.now_playing.selection || %{}

    assigns =
      assigns
      |> assign(:playlist_fallback, Map.get(selection, :playlist_fallback, false))
      |> assign(:hidden_fallback, Map.get(selection, :hidden_fallback, false))

    ~H"""
    <.card id="playlist-bar" padding={:none} class="overflow-hidden mt-3">
      <div class="flex items-center gap-3 px-4 py-3">
        <.toggle
          id="playlist-toggle"
          checked={@enabled}
          phx-click="toggle_playlist"
          aria-label="Rotate through the playlist only"
        />
        <div class="flex-1 min-w-0">
          <div class="text-sm text-fg-2">Rotate through the playlist only</div>
          <div id="playlist-count" class="text-xs text-fg-3 mt-0.5">
            {if @count == 0, do: "The playlist is empty.", else: count_label(@count, "preset") <> " on the playlist."}
            <span :if={@stored > @count} id="playlist-missing">
              {missing_label(@stored - @count)}
            </span>
          </div>
        </div>
        <.button
          :if={@stored > 0}
          id="playlist-clear"
          variant={:ghost}
          size={:sm}
          phx-click="ask_clear_playlist"
        >
          Clear
        </.button>
      </div>
      <div
        :if={(@enabled and @count == 0) or @playlist_fallback}
        id="playlist-fallback"
        role="status"
        class="px-4 py-2 border-t border-border-2 bg-warning-soft text-warning text-xs"
      >
        Nothing on the playlist can play, so every preset rotates.
      </div>
      <div
        :if={@hidden_fallback}
        id="hidden-fallback"
        role="status"
        class="px-4 py-2 border-t border-border-2 bg-warning-soft text-warning text-xs"
      >
        Every playable preset is hidden, so hidden presets rotate too.
      </div>
    </.card>
    """
  end

  attr(:confirm, :any, required: true)
  attr(:stored_playlist, :integer, required: true)

  defp confirm_modal(%{confirm: {:delete, row}} = assigns) do
    assigns = assign(assigns, :row, row)

    ~H"""
    <.modal
      open
      id="confirm-delete"
      on_close="cancel_confirm"
      return_focus="#presets-heading"
      title={"Delete #{@row.name}?"}
      subtitle="The uploaded file is removed from the device. This can't be undone."
    >
      <:footer>
        <.button variant={:ghost} size={:sm} phx-click="cancel_confirm">Cancel</.button>
        <.button id="confirm-delete-button" variant={:danger} size={:sm} phx-click="confirm">
          Delete
        </.button>
      </:footer>
    </.modal>
    """
  end

  defp confirm_modal(%{confirm: {:clear_hf, row}} = assigns) do
    assigns = assign(assigns, :row, row)

    ~H"""
    <.modal
      open
      id="confirm-clear-hf"
      on_close="cancel_confirm"
      title={"Unmark #{@row.name} as fast-flashing?"}
      subtitle="Photosensitivity warning"
    >
      <.photosensitivity_warning />
      <p class="text-sm text-fg-2 mt-3 mb-0">
        Unmarked, it plays even while fast-flashing presets are left out. Only do this if you're sure it
        doesn't flash rapidly.
      </p>
      <:footer>
        <.button variant={:ghost} size={:sm} phx-click="cancel_confirm">Cancel</.button>
        <.button id="confirm-clear-hf-button" variant={:danger} size={:sm} phx-click="confirm">
          Unmark it
        </.button>
      </:footer>
    </.modal>
    """
  end

  defp confirm_modal(%{confirm: :clear_playlist} = assigns) do
    ~H"""
    <.modal
      open
      id="confirm-clear-playlist"
      on_close="cancel_confirm"
      title="Clear the playlist?"
      subtitle={"Removes #{count_label(@stored_playlist, "preset")} from the playlist."}
    >
      <:footer>
        <.button variant={:ghost} size={:sm} phx-click="cancel_confirm">Cancel</.button>
        <.button id="confirm-clear-playlist-button" variant={:danger} size={:sm} phx-click="confirm">
          Clear playlist
        </.button>
      </:footer>
    </.modal>
    """
  end

  defp confirm_modal(assigns), do: ~H""
end
