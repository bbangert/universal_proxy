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
  names (or drops those that no longer match), a match among added rows
  or a rebuild reloads the list; the now-playing preset's row is
  re-rendered when it changes.

  ## Play now

  `UniversalProxy.MilkDrop.play/3` blocks until the TV shows the preset
  (up to 15 s), so it runs in `start_async/3`; its answer becomes a
  flash. A newer play supersedes an older one, whose answer is dropped.
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
              MilkDrop.now_playing_topic()
            ],
            do: Phoenix.PubSub.subscribe(UniversalProxy.PubSub, topic)
      end

      {:ok,
       socket
       |> assign(:page_title, "MilkDrop presets")
       |> assign(:settings, Store.settings())
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
       |> assign(:playing, nil)
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

  # Re-renders the loaded rows of these keys (a no-op for rows not in the
  # DOM), dropping those that no longer match the query.
  defp refresh_rows(socket, keys) do
    Enum.reduce(keys, socket, fn key, socket ->
      case Index.fetch(key) do
        {:ok, row} ->
          if Index.matches?(row, socket.assigns.query) do
            [row] = decorate(socket, [row])
            stream_insert(socket, :presets, row, update_only: true)
          else
            delete_keys(socket, [key])
          end

        :error ->
          delete_keys(socket, [key])
      end
    end)
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

  def handle_event("unlock", _params, socket) do
    case Store.update(%{locked: nil}) do
      {:ok, settings} ->
        {:noreply, assign(socket, :settings, settings)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't unlock (#{error_text(reason)}).")}
    end
  end

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
      ref = make_ref()
      id = row.id
      display = display()

      socket
      |> assign(:playing, %{ref: ref, name: row.name, lock?: lock?})
      |> start_async({:play, ref}, fn -> MilkDrop.play(id, lock?, display: display) end)
    end
  end

  @impl true
  def handle_async({:play, ref}, result, %{assigns: %{playing: %{ref: ref} = playing}} = socket) do
    socket = assign(socket, :playing, nil)

    case result do
      {:ok, :ok} ->
        {:noreply, put_flash(socket, :info, play_text(:ok, playing.name, playing.lock?))}

      {:ok, {:error, :superseded}} ->
        {:noreply, socket}

      {:ok, {:error, reason}} ->
        {:noreply, put_flash(socket, :error, play_text(reason, playing.name, playing.lock?))}

      {:exit, _reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't reach the visualizer.")}
    end
  end

  def handle_async({:play, _stale}, _result, socket), do: {:noreply, socket}

  # ── PubSub ────────────────────────────────────────────────────────────

  @impl true
  def handle_info({:milkdrop_index, %{rebuilt: true}}, socket), do: {:noreply, reset_list(socket)}

  def handle_info({:milkdrop_index, %{} = change}, socket) do
    added = Map.get(change, :added, [])

    if Enum.any?(added, &added_match?(socket, &1)) do
      {:noreply, reset_list(socket)}
    else
      {:noreply,
       socket
       |> delete_keys(Map.get(change, :removed, []))
       |> refresh_rows(Map.get(change, :changed, []))
       |> refresh_counts()}
    end
  end

  def handle_info({:milkdrop_settings, settings}, socket) when is_map(settings),
    do: {:noreply, assign(socket, :settings, settings)}

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

  defp added_match?(socket, key) do
    case Index.fetch(key) do
      {:ok, row} -> Index.matches?(row, socket.assigns.query)
      :error -> false
    end
  end

  defp display, do: Application.get_env(:universal_proxy, :milkdrop_display, Display.State)

  defp browse_path(q, filter) do
    params = %{filter: Index.filter_param(filter)}
    params = if q == "", do: params, else: Map.put(params, :q, q)
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
  defp pack_hint({:ready, _version, _dir}), do: "The preset pack lists no presets."

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
        playing={@playing}
      />

      <.playlist_bar
        enabled={@playlist_enabled}
        count={@totals.playlist}
        now_playing={@now_playing}
      />

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

      <.confirm_modal confirm={@confirm} totals={@totals} />
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
          </div>
        </div>
        <.button
          :if={@count > 0}
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
  attr(:totals, :map, required: true)

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
      subtitle={"Removes #{count_label(@totals.playlist, "preset")} from the playlist."}
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
