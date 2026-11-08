defmodule UniversalProxy.MilkDrop.Index do
  @moduledoc """
  A searchable index of every preset — the ready pack's manifest plus the
  upload library — for the web UI's preset browser, with each preset's
  skip reason, selection flags and lock folded in.

  One server owns two protected ETS tables that callers read directly,
  so a query never waits on the server:

    * rows (`:set`): `key => row` (plus a `:meta` entry);
    * order (`:ordered_set`): `{sort, key}`, the name order queries walk.

  A row:

      %{key:, id:, name:, folder:, sort:, search:, source: :pack | :user,
        tags: [String.t()], high_frequency: boolean(),
        skip: reason | nil, rpi3: nil | {:rung, "WxH"} | {:skip, reason},
        favourite: boolean(), hidden: boolean(), playlist: boolean(),
        locked: boolean(), uploaded_at: DateTime.t() | nil}

  `key` (`key/1`) is a short hash of the id: stable across rebuilds and
  safe as a DOM id, it is all the browser ever sends back, and `fetch/2`
  resolves it (an unknown key is `:error`).

  ## Sources

    * the pack: `<dir>/manifest.json` (read once per `{:ready, version,
      dir}` from `UniversalProxy.MilkDrop.Pack`; any other status means
      no pack rows). Entries the renderer would drop (an invalid id, a
      `user/` id, a duplicate) are dropped here too;
    * the uploads: `UniversalProxy.MilkDrop.UserPresets.list/1`, re-read
      on every library change and restart, with the skips (an upload's
      skip counts only for the content it was recorded against);
    * `UniversalProxy.MilkDrop.Store`: the skips (the ready version's and
      the uploads'), the selection and the `locked` setting, each kept
      current by its broadcast.

  The server subscribes before it reads, so nothing is missed in between.

  ## Changes

  Broadcast on `topic/0` (`"milkdrop:index"`) as
  `{:milkdrop_index, %{rebuilt: boolean(), added: [key], changed: [key],
  removed: [key]}}`, batched (at most one per `:batch_ms`, 100 ms by
  default) so a zip import or a playlist clear is one message. `rebuilt`
  means re-query everything; a message with empty lists is a change to
  the counts only (`playlist_enabled`).

  ## Queries

  `page/3` walks the order table from a `{sort, key}` cursor (keyset
  paging: inserts and deletes elsewhere never shift a page), `counts/2`
  scans it once. Both run in the caller. While the server is not running
  (no tables) they read as empty.

  Tests override via `:name` (the tables are named after it), `:pubsub`,
  `:store`, `:pack`, `:user_presets` and `:batch_ms`.
  """

  use GenServer

  require Logger

  alias UniversalProxy.MilkDrop
  alias UniversalProxy.MilkDrop.{Pack, Store, UserPresets}

  @topic "milkdrop:index"
  @batch_ms 100
  @max_manifest_bytes 16 * 1024 * 1024
  @max_query 64
  @key_chars 12

  @filters %{
    "all" => :all,
    "uploaded" => :uploaded,
    "favourites" => :favourites,
    "hidden" => :hidden,
    "playlist" => :playlist,
    "skipped" => :skipped,
    "fast-flashing" => :fast_flashing
  }

  @type key :: String.t()
  @type filter :: :all | :uploaded | :favourites | :hidden | :playlist | :skipped | :fast_flashing
  @type query :: %{q: String.t(), filter: filter()}
  @type cursor :: {String.t(), key()}

  @type row :: %{
          key: key(),
          id: String.t(),
          name: String.t(),
          folder: String.t() | nil,
          sort: String.t(),
          search: String.t(),
          source: :pack | :user,
          tags: [String.t()],
          high_frequency: boolean(),
          skip: String.t() | nil,
          rpi3: nil | {:rung, String.t()} | {:skip, String.t()},
          favourite: boolean(),
          hidden: boolean(),
          playlist: boolean(),
          locked: boolean(),
          uploaded_at: DateTime.t() | nil
        }

  @type counts :: %{
          total: non_neg_integer(),
          pack: non_neg_integer(),
          all: non_neg_integer(),
          uploaded: non_neg_integer(),
          favourites: non_neg_integer(),
          hidden: non_neg_integer(),
          playlist: non_neg_integer(),
          skipped: non_neg_integer(),
          fast_flashing: non_neg_integer()
        }

  @empty_counts %{
    total: 0,
    pack: 0,
    all: 0,
    uploaded: 0,
    favourites: 0,
    hidden: 0,
    playlist: 0,
    skipped: 0,
    fast_flashing: 0
  }

  # -- Client API --

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc "PubSub topic for index changes (see the moduledoc)."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "The browser's stable key for preset `id`."
  @spec key(String.t()) :: key()
  def key(id) when is_binary(id) do
    :sha256
    |> :crypto.hash(id)
    |> Base.encode32(case: :lower, padding: false)
    |> binary_part(0, @key_chars)
  end

  @doc "The filter a URL parameter names (`:all` for anything else)."
  @spec parse_filter(term()) :: filter()
  def parse_filter(param), do: Map.get(@filters, param, :all)

  @doc "The URL parameter for `filter`."
  @spec filter_param(filter()) :: String.t()
  def filter_param(filter) do
    Enum.find_value(@filters, "all", fn {param, f} -> if f == filter, do: param end)
  end

  @doc "Every filter, in display order."
  @spec filters() :: [filter()]
  def filters,
    do: [:all, :favourites, :playlist, :uploaded, :hidden, :skipped, :fast_flashing]

  @doc """
  A query: `q` trimmed, lowercased and cut to #{@max_query} characters
  (anything but a string reads as `""`), and the filter.
  """
  @spec query(term(), filter()) :: query()
  def query(q, filter \\ :all)

  def query(q, filter) when is_binary(q) do
    q = if String.valid?(q), do: q |> String.trim() |> String.slice(0, @max_query), else: ""
    %{q: String.downcase(q), filter: filter}
  end

  def query(_q, filter), do: %{q: "", filter: filter}

  @doc "The row `key` names, or `:error` (an unknown key, or no index)."
  @spec fetch(atom(), term()) :: {:ok, row()} | :error
  def fetch(server \\ __MODULE__, key)

  def fetch(server, key) when is_binary(key) and byte_size(key) == @key_chars do
    case :ets.lookup(server, key) do
      [{^key, row}] -> {:ok, row}
      [] -> :error
    end
  rescue
    ArgumentError -> :error
  end

  def fetch(_server, _key), do: :error

  @doc "The row of preset `id`, or `:error`."
  @spec fetch_id(atom(), String.t()) :: {:ok, row()} | :error
  def fetch_id(server \\ __MODULE__, id) when is_binary(id) do
    with {:ok, %{id: ^id} = row} <- fetch(server, key(id)), do: {:ok, row}
  end

  @doc "Whether `row` is listed under `query`."
  @spec matches?(row(), query()) :: boolean()
  def matches?(row, %{q: q, filter: filter}),
    do: filter?(row, filter) and (q == "" or String.contains?(row.search, q))

  @doc "A row's paging cursor."
  @spec cursor(row()) :: cursor()
  def cursor(%{sort: sort, key: key}), do: {sort, key}

  @doc """
  Up to `:limit` (default 50) rows matching `query`, in name order: the
  first ones after cursor `:after` (`nil`, the default, for the start),
  or with `:before`, the last ones before that cursor. Returns the rows
  and whether more match beyond them (after the last, or before the
  first).
  """
  @spec page(atom(), query(), keyword()) :: {[row()], boolean()}
  def page(server \\ __MODULE__, query, opts) do
    limit = Keyword.get(opts, :limit, 50)
    order = order_table(server)

    case Keyword.fetch(opts, :before) do
      {:ok, cursor} ->
        {rows, more?} = walk(server, order, query, :ets.prev(order, cursor), &:ets.prev/2, limit)
        {Enum.reverse(rows), more?}

      :error ->
        first =
          case Keyword.get(opts, :after) do
            nil -> :ets.first(order)
            cursor -> :ets.next(order, cursor)
          end

        walk(server, order, query, first, &:ets.next/2, limit)
    end
  rescue
    ArgumentError -> {[], false}
  end

  defp walk(server, order, query, key, step, limit, acc \\ [], n \\ 0)

  defp walk(_server, _order, _query, :"$end_of_table", _step, _limit, acc, _n),
    do: {Enum.reverse(acc), false}

  defp walk(server, order, query, {_sort, key} = cursor, step, limit, acc, n) do
    case :ets.lookup(server, key) do
      [{^key, row}] ->
        cond do
          not matches?(row, query) ->
            walk(server, order, query, step.(order, cursor), step, limit, acc, n)

          n == limit ->
            {Enum.reverse(acc), true}

          true ->
            walk(server, order, query, step.(order, cursor), step, limit, [row | acc], n + 1)
        end

      [] ->
        walk(server, order, query, step.(order, cursor), step, limit, acc, n)
    end
  end

  @doc """
  How many rows match search `q` (a `query/2`'s `q`) under each filter,
  plus `total` (every row) and `pack` (the pack's rows), whatever `q`.
  """
  @spec counts(atom(), String.t()) :: counts()
  def counts(server \\ __MODULE__, q) when is_binary(q) do
    :ets.foldl(
      fn
        {key, row}, acc when is_binary(key) -> count_row(acc, row, q)
        _meta, acc -> acc
      end,
      @empty_counts,
      server
    )
  rescue
    ArgumentError -> @empty_counts
  end

  defp count_row(acc, row, q) do
    acc = %{acc | total: acc.total + 1, pack: acc.pack + if(row.source == :pack, do: 1, else: 0)}

    if q == "" or String.contains?(row.search, q) do
      Enum.reduce(filters(), acc, fn filter, acc ->
        if filter?(row, filter), do: Map.update!(acc, filter, &(&1 + 1)), else: acc
      end)
    else
      acc
    end
  end

  @doc "Whether rotation is limited to the playlist (`false` with no index)."
  @spec playlist_enabled?(atom()) :: boolean()
  def playlist_enabled?(server \\ __MODULE__) do
    case :ets.lookup(server, :meta) do
      [{:meta, %{playlist_enabled: enabled}}] -> enabled
      [] -> false
    end
  rescue
    ArgumentError -> false
  end

  @doc """
  Why the ready pack's manifest lists nothing (`:unsupported_format`,
  `:no_presets`, `:invalid_json`, `:unreadable`), or `nil`.
  """
  @spec manifest_error(atom()) :: atom() | nil
  def manifest_error(server \\ __MODULE__) do
    case :ets.lookup(server, :meta) do
      [{:meta, %{manifest_error: error}}] -> error
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp filter?(row, :all), do: not row.hidden
  defp filter?(row, :uploaded), do: row.source == :user
  defp filter?(row, :favourites), do: row.favourite
  defp filter?(row, :hidden), do: row.hidden
  defp filter?(row, :playlist), do: row.playlist
  defp filter?(row, :skipped), do: row.skip != nil
  defp filter?(row, :fast_flashing), do: row.high_frequency

  defp order_table(server), do: Module.concat(server, Order)

  # -- Server callbacks --

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    pubsub = Keyword.get(opts, :pubsub, UniversalProxy.PubSub)

    rows = :ets.new(name, [:set, :protected, :named_table, read_concurrency: true])

    order =
      :ets.new(order_table(name), [:ordered_set, :protected, :named_table, read_concurrency: true])

    for topic <- [
          MilkDrop.pack_topic(),
          MilkDrop.settings_topic(),
          MilkDrop.selection_topic(),
          MilkDrop.user_presets_topic()
        ],
        do: Phoenix.PubSub.subscribe(pubsub, topic)

    state = %{
      rows: rows,
      order: order,
      pubsub: pubsub,
      store: Keyword.get(opts, :store, Store),
      pack: Keyword.get(opts, :pack, Pack),
      user_presets: Keyword.get(opts, :user_presets, UserPresets),
      batch_ms: Keyword.get(opts, :batch_ms, @batch_ms),
      pack_status: nil,
      pack_ids: [],
      manifest_error: nil,
      user: %{},
      skips: %{},
      selection: %{favourites: MapSet.new(), hidden: MapSet.new(), playlist: MapSet.new()},
      playlist_enabled: false,
      locked: nil,
      pending: nil,
      timer: nil
    }

    {:ok, state, {:continue, :build}}
  end

  @impl true
  def handle_continue(:build, state) do
    pack_status = Pack.status(state.pack)
    settings = Store.settings(state.store)

    state =
      %{state | pack_status: pack_status, locked: settings.locked}
      |> put_selection(Store.selection(state.store))
      |> Map.put(:skips, Store.skipped(state.store, pack_version(pack_status) || ""))
      |> Map.put(:user, read_user(state))
      |> put_pack(pack_status)
      |> rebuild()

    {:noreply, state}
  end

  @impl true
  def handle_info({kind, status}, state) when kind in [:milkdrop_pack, :milkdrop_pack_started] do
    if pack_dir(status) == pack_dir(state.pack_status) do
      {:noreply, %{state | pack_status: status}}
    else
      skips = Store.skipped(state.store, pack_version(status) || "")
      {:noreply, %{state | pack_status: status, skips: skips} |> put_pack(status) |> rebuild()}
    end
  end

  def handle_info({:milkdrop_skipped, version, entries}, state) when is_map(entries),
    do: {:noreply, apply_skips(state, version, entries)}

  def handle_info({:milkdrop_settings, %{locked: locked}}, state),
    do: {:noreply, apply_locked(state, locked)}

  def handle_info({:milkdrop_selection, selection}, state) when is_map(selection),
    do: {:noreply, apply_selection(state, selection)}

  # The Store served defaults until now (or restarted): read it all again.
  def handle_info({:milkdrop_store, :opened}, state) do
    skips = Store.skipped(state.store, pack_version(state.pack_status) || "")

    {:noreply,
     state
     |> apply_locked(Store.settings(state.store).locked)
     |> apply_selection(Store.selection(state.store))
     |> apply_skips(nil, skips)}
  end

  def handle_info({kind, _change}, state)
      when kind in [:milkdrop_user_presets, :milkdrop_user_presets_started] do
    # Upload skips count only for the content they were recorded against,
    # which a library change or restart (a repaired replacement) may change
    # without the Store announcing anything.
    skips = Store.skipped(state.store, pack_version(state.pack_status) || "")
    {:noreply, state |> sync_user(read_user(state)) |> apply_skips(nil, skips)}
  end

  def handle_info(:flush, %{pending: pending} = state) do
    if pending, do: Phoenix.PubSub.broadcast(state.pubsub, @topic, {:milkdrop_index, pending})
    {:noreply, %{state | pending: nil, timer: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp apply_skips(state, version, entries) do
    skips =
      if version == nil or version == pack_version(state.pack_status),
        do: entries,
        else: Map.filter(entries, fn {id, _reason} -> user_id?(id) end)

    changed = changed_ids(state.skips, skips)
    %{state | skips: skips} |> refresh_ids(changed)
  end

  defp apply_locked(%{locked: locked} = state, locked), do: state

  defp apply_locked(state, locked) do
    changed = Enum.reject([state.locked, locked], &is_nil/1)
    %{state | locked: locked} |> refresh_ids(changed)
  end

  defp apply_selection(state, selection) do
    old = state
    state = put_selection(state, selection)

    changed =
      Enum.flat_map([:favourites, :hidden, :playlist], fn list ->
        old.selection |> Map.fetch!(list) |> sym_diff(Map.fetch!(state.selection, list))
      end)

    state = refresh_ids(state, changed)

    if state.playlist_enabled == old.playlist_enabled,
      do: state,
      else: state |> put_meta() |> queue(%{})
  end

  # -- Building --

  defp rebuild(state) do
    rows =
      Enum.map(state.pack_ids, &pack_row(state, &1)) ++ Enum.map(state.user, &user_row(state, &1))

    :ets.delete_all_objects(state.rows)
    :ets.delete_all_objects(state.order)
    :ets.insert(state.rows, Enum.map(rows, &{&1.key, &1}))
    :ets.insert(state.order, Enum.map(rows, &{cursor(&1)}))

    state |> put_meta() |> queue(%{rebuilt: true})
  end

  defp put_meta(state) do
    meta = %{playlist_enabled: state.playlist_enabled, manifest_error: state.manifest_error}
    :ets.insert(state.rows, {:meta, meta})
    state
  end

  defp put_pack(state, status) do
    case read_pack(status) do
      {:ok, entries} -> %{state | pack_ids: entries, manifest_error: nil}
      {:error, reason} -> %{state | pack_ids: [], manifest_error: reason}
    end
  end

  defp sync_user(state, user) do
    old = state.user
    removed = for {id, _} <- old, not Map.has_key?(user, id), do: id
    added = for {id, _} <- user, not Map.has_key?(old, id), do: id
    changed = for {id, p} <- user, Map.has_key?(old, id), old[id] != p, do: id

    state = %{state | user: user}

    for id <- removed do
      key = key(id)

      with [{^key, row}] <- :ets.lookup(state.rows, key) do
        :ets.delete(state.rows, key)
        :ets.delete(state.order, cursor(row))
      end
    end

    rows = Enum.map(added ++ changed, &user_row(state, {&1, Map.fetch!(user, &1)}))
    :ets.insert(state.rows, Enum.map(rows, &{&1.key, &1}))
    :ets.insert(state.order, Enum.map(rows, &{cursor(&1)}))

    queue(state, %{
      added: Enum.map(added, &key/1),
      changed: Enum.map(changed, &key/1),
      removed: Enum.map(removed, &key/1)
    })
  end

  # Re-derives the flags of the rows these ids name (ids without a row
  # are ignored: the selection may name an upload that comes later).
  defp refresh_ids(state, ids) do
    keys =
      for id <- Enum.uniq(ids),
          key = key(id),
          [{^key, %{id: ^id} = row}] <- [:ets.lookup(state.rows, key)] do
        :ets.insert(state.rows, {key, flags(state, row)})
        key
      end

    if keys == [], do: state, else: queue(state, %{changed: keys})
  end

  defp queue(state, change) do
    pending =
      Map.merge(
        state.pending || %{rebuilt: false, added: [], changed: [], removed: []},
        change,
        fn
          :rebuilt, a, b -> a or b
          _list, a, b -> Enum.uniq(a ++ b)
        end
      )

    timer = state.timer || Process.send_after(self(), :flush, state.batch_ms)
    %{state | pending: pending, timer: timer}
  end

  defp pack_row(state, %{id: id} = entry) do
    {folder, name} = split_name(id)

    flags(state, %{
      key: key(id),
      id: id,
      name: name,
      folder: folder,
      sort: String.downcase(name),
      search: search_text(id),
      source: :pack,
      tags: entry.tags,
      high_frequency:
        "high_frequency" in entry.tags or String.starts_with?(id, "high_frequency/"),
      rpi3: entry.rpi3,
      uploaded_at: nil
    })
  end

  defp user_row(state, {id, preset}) do
    name = Path.basename(preset.name, ".milk")

    flags(state, %{
      key: key(id),
      id: id,
      name: name,
      folder: nil,
      sort: String.downcase(name),
      search: search_text(preset.name),
      source: :user,
      tags: if(preset.high_frequency, do: ["uploaded", "high_frequency"], else: ["uploaded"]),
      high_frequency: preset.high_frequency,
      rpi3: nil,
      uploaded_at: preset.uploaded_at
    })
  end

  defp flags(state, %{id: id} = row) do
    Map.merge(row, %{
      skip: Map.get(state.skips, id),
      favourite: MapSet.member?(state.selection.favourites, id),
      hidden: MapSet.member?(state.selection.hidden, id),
      playlist: MapSet.member?(state.selection.playlist, id),
      locked: state.locked == id
    })
  end

  defp split_name(id) do
    name = Path.basename(id, ".milk")

    case Path.dirname(id) do
      "." -> {nil, name}
      folder -> {folder, name}
    end
  end

  defp search_text(path), do: path |> String.replace_suffix(".milk", "") |> String.downcase()

  defp put_selection(state, selection) do
    %{
      state
      | selection: %{
          favourites: MapSet.new(Map.get(selection, :favourites, [])),
          hidden: MapSet.new(Map.get(selection, :hidden, [])),
          playlist: MapSet.new(Map.get(selection, :playlist, []))
        },
        playlist_enabled: Map.get(selection, :playlist_enabled, false) == true
    }
  end

  defp sym_diff(a, b),
    do: MapSet.to_list(MapSet.difference(a, b)) ++ MapSet.to_list(MapSet.difference(b, a))

  defp changed_ids(old, new) do
    keys = Enum.uniq(Map.keys(old) ++ Map.keys(new))
    Enum.filter(keys, &(Map.get(old, &1) != Map.get(new, &1)))
  end

  defp read_user(state) do
    state.user_presets
    |> UserPresets.list()
    |> Map.get(:presets, [])
    |> Map.new(fn p -> {p.id, Map.take(p, [:name, :high_frequency, :uploaded_at, :sha256])} end)
  end

  defp pack_version({:ready, version, _dir}), do: version
  defp pack_version(_status), do: nil

  defp pack_dir({:ready, _version, dir}), do: dir
  defp pack_dir(_status), do: nil

  defp read_pack({:ready, _version, dir}) when is_binary(dir) do
    path = Path.join(dir, "manifest.json")

    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_manifest_bytes <-
           File.stat(path),
         {:ok, text} <- File.read(path),
         {:ok, doc} <- Jason.decode(text),
         {:ok, presets} <- manifest_presets(doc) do
      {:ok, presets |> Enum.flat_map(&pack_entry/1) |> Enum.uniq_by(& &1.id)}
    else
      other ->
        Logger.warning("MilkDrop.Index: can't read #{path}: #{inspect(other, limit: 5)}")
        {:error, manifest_reason(other)}
    end
  end

  defp read_pack(_status), do: {:ok, []}

  # The renderer's document rules (manifest.cpp `parse_manifest`): an
  # object, `format` absent or the number 1, a `presets` array.
  defp manifest_presets(%{"presets" => presets} = doc) when is_list(presets) do
    case Map.fetch(doc, "format") do
      :error -> {:ok, presets}
      {:ok, format} when is_number(format) and format == 1 -> {:ok, presets}
      {:ok, _other} -> {:error, :unsupported_format}
    end
  end

  defp manifest_presets(_doc), do: {:error, :no_presets}

  defp manifest_reason({:error, reason}) when reason in [:unsupported_format, :no_presets],
    do: reason

  defp manifest_reason({:error, %Jason.DecodeError{}}), do: :invalid_json
  defp manifest_reason(_other), do: :unreadable

  # The renderer's entry rules (manifest.cpp `parse_entry`): an entry it
  # would drop is dropped here.
  defp pack_entry(%{"file" => id} = entry) do
    tags = Map.get(entry, "tags", [])

    with true <- Store.valid_id?(id) and not user_id?(id),
         true <- is_list(tags) and Enum.all?(tags, &is_binary/1),
         {:ok, rpi3} <- rpi3(Map.get(entry, "rpi3")) do
      [%{id: id, tags: tags, rpi3: rpi3}]
    else
      _ -> []
    end
  end

  defp pack_entry(_entry), do: []

  defp rpi3(nil), do: {:ok, nil}
  defp rpi3("skip"), do: {:ok, {:skip, nil}}
  defp rpi3(rung) when is_binary(rung), do: rung(rung)

  defp rpi3(%{} = rpi3) do
    case Map.get(rpi3, "rung") do
      nil -> {:ok, nil}
      "skip" -> {:ok, {:skip, reason(Map.get(rpi3, "reason"))}}
      rung when is_binary(rung) -> rung(rung)
      _other -> :error
    end
  end

  defp rpi3(_other), do: :error

  # options.cpp `parse_resolution`: "WxH", each 1..16384 as strtoll reads it
  # (leading whitespace and a sign allowed, nothing after the digits).
  defp rung(rung) do
    with [w, h] <- :binary.split(rung, "x"),
         {:ok, w} <- dimension(w),
         {:ok, h} <- dimension(h) do
      {:ok, {:rung, "#{w}x#{h}"}}
    else
      _ -> :error
    end
  end

  defp dimension(text) when byte_size(text) in 1..19 do
    with [_, sign, digits] <- Regex.run(~r/\A[ \t\n\v\f\r]*([+-]?)([0-9]+)\z/, text),
         n when n in 1..16_384 <- String.to_integer(sign <> digits) do
      {:ok, n}
    else
      _ -> :error
    end
  end

  defp dimension(_text), do: :error

  defp reason(reason) when is_binary(reason) and byte_size(reason) <= 64, do: reason
  defp reason(_reason), do: nil

  defp user_id?("user/" <> _), do: true
  defp user_id?(_id), do: false
end
