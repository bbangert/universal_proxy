defmodule UniversalProxy.TuyaMesh.Store do
  @moduledoc """
  DETS-backed store for the Tuya Beacon Mesh: the uploaded inventory (keys
  included), the HA sub-device ids allocated to its bulbs and groups, and
  the mesh settings (colour-temperature range).

  The DETS file lives at `/data/tuya_mesh.dets` on Nerves (`_build/` on the
  host). The inventory holds every key of the mesh, so the file is
  restricted to 0600 at open and a `chmod` that fails stops `init/1` with
  `{:chmod_failed, reason}` (same fail-closed guard as
  `UniversalProxy.Storage.Settings`). Every write is synced before `:ok` is
  returned. Keys are never logged; `format_status/1` keeps them out of
  `:sys.get_status/1` and crash reports, and errors carry only atoms and
  validated values.

  ## Inventory and sequence safety

  The inventory is stored in its JSON-friendly form (`Inventory.to_map/1`)
  and re-validated by `Inventory.decode/1` on every `load/1`, so nothing that
  reaches the radio has skipped validation. A mesh is identified by the
  bytes of its mesh `beaconKey` (the rule `Lights.reload/2` uses).

    * `persist/2` is `Lights`' `on_persist`. It may move the stored `seq`
      forward and change the groups. The mesh key and the bulbs come only
      from `replace/3`, and a `seq` behind the stored one is refused, so a
      `Lights` still running on a replaced or cleared inventory can't
      write it back.
    * `tighten/3` is `Lights`' `on_tighten`: on a clean stop, Lights moves
      the stored cursor back from the end of its lease to the exact next
      sequence number. It is a compare-and-set: applied only while the same
      mesh is stored with exactly that lease end (`leased`) and the same
      bulbs and groups, and it changes only the `seq`. Anything else
      (`{:error, :stale_tighten | :mesh_changed | :inventory_changed}`)
      leaves the lease end stored, which is safe; without the check, a
      `replace/3` that moved the cursor forward (a newer dump) could be
      pulled back to a stale Lights cursor.
    * `replace/3` stores an upload. A different mesh needs `allow_new_mesh:
      true`. For a mesh with a local cursor (the stored `seq` of the same
      mesh, or its floor, below), the local cursor is authoritative: the
      dump's `seq` is taken only when it is 1 to `:max_dump_advance`
      (299) ahead of it. Equal, behind, or further ahead than that, the
      local cursor is kept, unless the upload says `adopt_dump_seq: true`
      for a dump that is ahead (see "Upload seq" below). A mesh with no
      local cursor takes the dump's `seq`.
    * When a mesh leaves the store (`clear/2`, or `replace/3` with another
      mesh), its last `seq` is kept as a floor under a SHA-256 fingerprint of
      its key. A later upload of that mesh starts no lower than the floor.
      A floor exists only while its mesh is out of the store (storing a mesh
      deletes its floor), so a tighten, which needs the mesh stored, never
      meets one. The tightened `seq` is the next unused number, at or above
      every number sent, so the floor recorded from it when the mesh later
      leaves (the later of any floor and the stored `seq`) is still a valid
      lower bound.

  A stored record that no longer validates (a schema change, a corrupted
  file) is never served, but it still holds the last `seq` of its mesh.
  `clear/2` and `replace/3` salvage that floor from the raw record when its
  key and `seq` are still usable. When they are not, `clear/2` refuses with
  `{:error, :seq_unrecoverable}` instead of silently dropping the floor;
  `clear(server, force: true)` drops it anyway, and is the caller's explicit
  acknowledgement that the next upload of that mesh may reuse sequence
  numbers. `replace/3` goes ahead (the upload brings its own `seq`) and logs
  the loss.

  ## Upload seq

  Sequence numbers are 16-bit and compared as serial numbers (half the
  range ahead counts as ahead), and our own traffic keeps moving the
  cursor: background pinging alone uses up to 60 an hour
  (`UniversalProxy.TuyaMesh.Presence`), plus every command. A dump keeps
  the value it was exported with, so after 32_768 numbers (about 23 days
  of pinging alone) an old dump of the same mesh would read as *ahead* of
  the stored cursor, and taking it would move the bulbs' tracker back
  onto numbers they already heard, which they drop.

  So a dump moves the cursor on its own only forward, and only by at most
  `:max_dump_advance`. The bound is derived from what the bulbs are known
  to accept: they took jumps of about `Seq.max_jump/0` (900), and nothing
  larger was ever tested. Take the worst case, a stale dump that reads as
  a small advance (after a near-full wrap, 65_536 - B numbers past it):
  the cursor moves B past what the bulbs last heard. The Lights started
  on it knows nothing of what aired before (its baseline is the number
  before its cursor), so its first lease can end up to its `:max_lease`
  past the cursor, and a crash before any frame airs resumes there. The
  bulbs then see a jump of B + lease + 1. Keeping that within `max_jump`
  gives B = `max_jump - max_lease - 1` = 900 - 600 - 1 = **299**, with the
  mesh's Lights run at `lights_max_lease/0` (600, passed by
  `UniversalProxy.TuyaMesh.Mesh`). The option may only lower it. Every
  other move of the local cursor is small and forward too (Lights persists
  at most a lease ahead; a tighten goes back only to the next unused
  number), so the 16-bit cursor stays unambiguous relative to itself and
  no unwrapped (64-bit) copy is kept: the dump only carries 16 bits, so a
  longer local history couldn't place it any better.

  299 is small next to what the Tuya app can legitimately advance the
  bulbs by (one number per app command) between our last write and an
  export. A genuinely newer dump further ahead is adopted only when asked:
  `replace/3` with `adopt_dump_seq: true` takes the dump's `seq` whenever
  it is ahead of the local cursor in serial terms (1..32_767), however
  far, and refuses one behind or equal with `{:error, {:seq_not_ahead,
  %{local:, dump:}}}`. That is safe when the dump really is newer: the
  app moved the bulbs' trackers to (about) its `seq` already, so the
  bulbs see no forward jump at all, and until it is adopted they drop
  everything this device sends as stale. The risk is a dump that only
  looks newer (an old export after the counter wrapped): adopting it jumps
  the bulbs past their acceptance window and they ignore this device until
  a fresh dump is uploaded and adopted. Hence the confirmation in the UI.

  `preview/2` reports the outcome as `seq: %{outcome:, reason:, local:,
  dump:}`: `:taken` (no local cursor, or the dump is within the bound
  ahead), `:same`, or `:kept_local`, with `reason` `:beyond_bound` (ahead,
  but further than the bound: adoptable) or `:behind` (`reason` is nil for
  the others). `replace/3` logs a `:kept_local` and an adoption.

  ## Revision

  A persisted counter, bumped in the same insert as every write that
  changes what `preview/2` diffs against: an upload, a clear, a persist
  that changed the groups. Seq-only writes (persist, tighten) leave it, so
  the Lights lease never invalidates a pending confirmation. `preview/2`
  returns it as `revision` (an integer, key-free; 0 for a store never
  written), and `replace/3` with `expected_revision:` refuses to write
  unless it still matches, checked in the same call as the write, with
  `{:error, {:stale_preview, preview}}` (a fresh preview). So a confirmed
  upload only applies the diff the user was shown.

  ## Sub-device ids

  `device_ids/1` maps `{:bulb, mac}` and `{:group, local_id}` to HA
  sub-device ids. Ids come from a persisted counter: they start at 1 (0 is
  the parent device), only go up, and survive `clear/1`, so an id never
  names two objects. Every inventory write allocates ids for its bulbs and
  groups. A bulb's entry is kept when the bulb leaves the inventory (a MAC
  is a physical bulb, so a returning bulb gets its old sub-device back). A
  group's entry is dropped when the group leaves, because group ids are
  reused for unrelated groups, and every group entry is dropped whenever
  the stored mesh changes (a new mesh, a clear, an invalid record replaced):
  local group ids of one mesh say nothing about another's. Every write over
  the same stored mesh (persist, tighten, a same-mesh replace) keeps them.
  Mappings are written in the same DETS insert as the inventory they belong
  to.

  After every write that changes what the inventory summary shows (an
  upload, a clear, a persist that changed the groups), `{:tuya_mesh_store,
  :inventory_changed}` is broadcast on `topic/0` (`:pubsub`, default
  `UniversalProxy.PubSub`). It carries nothing; subscribers re-read with
  `load/1`. Seq-only writes (persist, tighten) stay silent.

  `:max_dump_advance` (default and maximum 299, see above) sets the bound.

  Tests can override `:pubsub`, `:dets_path`, `:table`, `:name`, `:chmod_fun`
  (`(path, mode -> :ok | {:error, term()})`), `:write_fun` (`(table,
  records -> :ok | {:error, term()})`, one atomic insert) and `:enabled` (default:
  `UniversalProxy.Bluetooth.supported?/0`; when false, `start_link/1`
  returns `:ignore`).
  """

  use GenServer

  require Logger

  alias UniversalProxy.TuyaBeaconMesh.{Crypto, Inventory, Seq}
  alias UniversalProxy.TuyaMesh.Redact

  @topic "tuya_mesh:store"

  @default_table :tuya_mesh
  @default_settings %{min_mireds: 154, max_mireds: 370, invert: false}
  @seq_space 65_536
  # The :max_lease the mesh's Lights runs with; the upload bound is
  # derived from it (moduledoc, "Upload seq").
  @lights_max_lease 600
  @max_dump_advance Seq.max_jump() - @lights_max_lease - 1

  @type device_key :: {:bulb, String.t()} | {:group, 0..254}
  @type classification :: :empty | :same_mesh | :new_mesh
  @type settings :: %{min_mireds: pos_integer(), max_mireds: pos_integer(), invert: boolean()}
  @type summary :: %{mac: String.t(), label: String.t() | nil}
  @type preview :: %{
          mesh: classification(),
          bulbs: %{added: [summary()], removed: [summary()]},
          groups: %{
            added: [%{local_id: 0..254, name: String.t() | nil}],
            removed: [%{local_id: 0..254, name: String.t() | nil}]
          },
          revision: non_neg_integer(),
          seq: seq_outcome()
        }

  @type seq_outcome :: %{
          outcome: :taken | :same | :kept_local,
          reason: :beyond_bound | :behind | nil,
          local: 0..65_535 | nil,
          dump: 0..65_535
        }

  # ── Client API ─────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    if Keyword.get(opts, :enabled, UniversalProxy.Bluetooth.supported?()) do
      gen_opts =
        case Keyword.get(opts, :name, __MODULE__) do
          nil -> []
          name -> [name: name]
        end

      GenServer.start_link(__MODULE__, opts, gen_opts)
    else
      :ignore
    end
  end

  def child_spec(opts) do
    %{id: Keyword.get(opts, :id, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "PubSub topic of `{:tuya_mesh_store, :inventory_changed}` broadcasts."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  The stored inventory, re-validated: `{:ok, inventory}`, or
  `{:error, :no_inventory | :unavailable | {:invalid, reason}}`. Shaped as
  a `Lights` `:inventory` loader.
  """
  @spec load(GenServer.server()) ::
          {:ok, Inventory.t()} | {:error, :no_inventory | :unavailable | {:invalid, term()}}
  def load(server \\ __MODULE__) do
    # Replies cross the mailbox and the raw sys debug log as well: sealed.
    case call(server, :load, {:error, :unavailable}) do
      {:ok, sealed} -> {:ok, Redact.unseal(sealed)}
      error -> error
    end
  end

  @doc """
  `Lights`' `on_persist`: writes `inventory` (same mesh and bulbs as the
  stored one, `seq` not behind it). `:ok` only once synced.
  """
  @spec persist(Inventory.t(), GenServer.server()) :: :ok | {:error, atom()}
  def persist(inventory, server \\ __MODULE__),
    do: send_inventory(server, inventory, &{:persist, &1, :advance})

  @doc """
  `Lights`' `on_tighten`: writes `inventory`'s `seq` (the exact next number,
  possibly behind the stored one) only when the stored inventory is the
  same mesh, with the same bulbs and groups, and its `seq` is still
  `leased`. See the moduledoc. `:ok` only once synced.
  """
  @spec tighten(Inventory.t(), non_neg_integer(), GenServer.server()) :: :ok | {:error, atom()}
  def tighten(inventory, leased, server \\ __MODULE__)

  def tighten(inventory, leased, server)
      when is_integer(leased) and leased >= 0 and leased <= 65_535,
      do: send_inventory(server, inventory, &{:persist, &1, {:tighten, leased}})

  def tighten(_inventory, _leased, _server), do: {:error, :bad_lease}

  @doc """
  How `inventory` relates to the stored one: `:empty` (nothing stored),
  `:same_mesh` or `:new_mesh`.
  """
  @spec classify(Inventory.t(), GenServer.server()) :: classification() | {:error, :unavailable}
  def classify(inventory, server \\ __MODULE__),
    do: send_inventory(server, inventory, &{:classify, &1})

  @doc """
  What `replace/3` with `inventory` would change: the mesh classification
  and the bulbs (by MAC) and groups (by local id) added and removed, plus
  the stored `revision` it was computed against (see the moduledoc). No
  keys.
  """
  @spec preview(Inventory.t(), GenServer.server()) :: {:ok, preview()} | {:error, term()}
  def preview(inventory, server \\ __MODULE__),
    do: send_inventory(server, inventory, &{:preview, &1})

  @doc """
  Stores an uploaded inventory (see the moduledoc for the `seq` rule).
  `opts`: `allow_new_mesh:` (default `false`), without which a different
  mesh is refused with `{:error, :new_mesh}`; `expected_revision:`, the
  `revision` of a preview, without a match for which nothing is written
  and the reply is `{:error, {:stale_preview, preview}}`, the preview fresh;
  `adopt_dump_seq:` (default `false`) to take a dump's `seq` that is ahead
  beyond the bound (see "Upload seq"). Returns how it was stored:
  `:same_mesh` when a stored or earlier `seq` of this mesh was honoured,
  else `:new_mesh`.
  """
  @spec replace(Inventory.t(), keyword(), GenServer.server()) ::
          {:ok, :same_mesh | :new_mesh} | {:error, term()}
  def replace(inventory, opts \\ [], server \\ __MODULE__),
    do: send_inventory(server, inventory, &{:replace, &1, opts})

  @doc """
  Removes the inventory, keeping its `seq` floor. Bulb device ids, the id
  counter and settings are kept; group ids are dropped. For an invalid
  record whose floor can't be recovered: `{:error, :seq_unrecoverable}`,
  unless `force: true` (see the moduledoc).
  """
  @spec clear(GenServer.server(), keyword()) :: :ok | {:error, term()}
  def clear(server \\ __MODULE__, opts \\ []),
    do: call(server, {:clear, opts}, {:error, :unavailable})

  @doc "Every allocated sub-device id (see the moduledoc). `%{}` when unavailable."
  @spec device_ids(GenServer.server()) :: %{device_key() => pos_integer()}
  def device_ids(server \\ __MODULE__), do: call(server, :device_ids, %{})

  @doc """
  Allocates ids for those of `keys` that have none, and returns the ids of
  all of `keys`. Inventory writes allocate for their own bulbs and groups
  already; a group id allocated here for a group that is not in the stored
  inventory is dropped by the next inventory write.
  """
  @spec allocate_device_ids([device_key()], GenServer.server()) ::
          {:ok, %{device_key() => pos_integer()}} | {:error, term()}
  def allocate_device_ids(keys, server \\ __MODULE__) when is_list(keys) do
    if Enum.all?(keys, &device_key?/1),
      do: call(server, {:allocate, keys}, {:error, :unavailable}),
      else: {:error, :bad_device_key}
  end

  @doc "Mesh settings; the defaults (#{inspect(@default_settings)}) when unavailable."
  @spec settings(GenServer.server()) :: settings()
  def settings(server \\ __MODULE__), do: call(server, :settings, @default_settings)

  @doc """
  Merges `changes` into the settings. `min_mireds < max_mireds`, both
  positive integers; `invert` a boolean. `{:error, :invalid_settings}`
  otherwise.
  """
  @spec put_settings(map(), GenServer.server()) :: :ok | {:error, term()}
  def put_settings(changes, server \\ __MODULE__) when is_map(changes),
    do: call(server, {:put_settings, changes}, {:error, :unavailable})

  @doc "Default mesh settings."
  @spec default_settings() :: settings()
  def default_settings, do: @default_settings

  @doc """
  A key-free identity of the mesh an inventory belongs to: the SHA-256 of
  its `beaconKey` bytes, the fingerprint seq floors are kept under. Not
  reversible to the key.
  """
  @spec mesh_fingerprint(Inventory.t()) :: binary()
  def mesh_fingerprint(%Inventory{beacon_key: key}), do: fingerprint(key)

  # `catch :exit` idiom (CLAUDE.md). A timed-out write may still land; its
  # caller sees an error and retries, which every write here tolerates.
  defp call(server, request, default) do
    GenServer.call(server, request)
  catch
    :exit, _reason -> default
  end

  # Validated here, in the caller, and sent sealed (`Redact.seal/1`), so
  # no JSON, map or struct with keys ever sits in this process's mailbox,
  # its sys debug log or a crash report, whatever the caller passed.
  defp send_inventory(server, input, request) do
    case validate(input) do
      {:ok, inv} -> call(server, request.(Redact.seal(inv)), {:error, :unavailable})
      error -> error
    end
  end

  defp device_key?({:bulb, mac}) when is_binary(mac), do: true
  defp device_key?({:group, id}) when is_integer(id) and id in 0..254, do: true
  defp device_key?(_key), do: false

  # ── Server ───────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    # Trap exits so terminate/2 closes the table on a supervisor shutdown.
    Process.flag(:trap_exit, true)

    table_name = Keyword.get(opts, :table, @default_table)
    path = Keyword.get(opts, :dets_path) || dets_path()
    chmod_fun = Keyword.get(opts, :chmod_fun, &File.chmod/2)
    File.mkdir_p!(Path.dirname(path))

    case :dets.open_file(table_name, file: to_charlist(path), type: :set) do
      {:ok, table} ->
        case chmod_fun.(path, 0o600) do
          :ok ->
            Logger.info("TuyaMesh.Store opened at #{path}")

            {:ok,
             %{
               table: table,
               write_fun: Keyword.get(opts, :write_fun, &default_write/2),
               pubsub: Keyword.get(opts, :pubsub, UniversalProxy.PubSub),
               max_dump_advance: max_dump_advance(opts)
             }}

          {:error, reason} ->
            Logger.error(
              "TuyaMesh.Store could not be restricted to 0600 (#{path}): #{inspect(reason)}; " <>
                "refusing to serve mesh keys from it"
            )

            :dets.close(table)
            {:stop, {:chmod_failed, reason}}
        end

      {:error, reason} ->
        Logger.error("TuyaMesh.Store failed to open #{path}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl GenServer
  def terminate(_reason, %{table: table}), do: :dets.close(table)

  # Requests carry inventories and the table holds them: anything raised
  # in here leaves as a key-free Redact.Error (see Redact.guard/2).
  @impl GenServer
  def handle_call(request, from, state),
    do: Redact.guard("TuyaMesh.Store", fn -> do_call(request, from, state) end)

  defp do_call(:load, _from, state) do
    reply =
      case load_stored(state.table) do
        {:ok, inv} -> {:ok, Redact.seal(inv)}
        error -> error
      end

    {:reply, reply, state}
  end

  defp do_call({:persist, input, mode}, _from, state) do
    with {:ok, inv} <- validate(input),
         {:ok, stored} <- fetch_stored(state.table),
         :ok <- check_persistable(stored, inv, mode),
         groups_changed? = inv.groups != stored.groups,
         extra = if(groups_changed?, do: [bump(state.table)], else: []),
         :ok <- write_inventory(state, inv, extra, :same_mesh) do
      if groups_changed?, do: notify(state)
      {:reply, :ok, state}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  defp do_call({:classify, input}, _from, state) do
    reply =
      case validate(input) do
        {:ok, inv} -> classify_against(valid_or_nil(state.table), inv)
        error -> error
      end

    {:reply, reply, state}
  end

  defp do_call({:preview, input}, _from, state) do
    reply =
      case validate(input) do
        {:ok, inv} -> {:ok, preview_of(state, inv)}
        error -> error
      end

    {:reply, reply, state}
  end

  # The revision is checked in the same call as the write: nothing can land
  # between them.
  defp do_call({:replace, input, opts}, _from, state) do
    reply =
      case validate(input) do
        {:ok, inv} ->
          if stale?(state.table, opts),
            do: {:error, {:stale_preview, preview_of(state, inv)}},
            else: do_replace(state, inv, opts)

        error ->
          error
      end

    {:reply, reply, state}
  end

  defp do_call({:clear, opts}, _from, state) do
    reply =
      case stored(state.table) do
        :absent ->
          :ok

        {:valid, inv} ->
          write_clear(state, put_floor(floors(state.table), inv_floor(inv)))

        {:invalid, raw} ->
          case raw_floor(raw) do
            {:ok, floor} ->
              write_clear(state, put_floor(floors(state.table), floor))

            :error ->
              if Keyword.get(opts, :force, false) do
                Logger.warning("TuyaMesh.Store: invalid inventory cleared; its seq is lost")
                write_clear(state, floors(state.table))
              else
                {:error, :seq_unrecoverable}
              end
          end
      end

    {:reply, reply, state}
  end

  defp do_call(:device_ids, _from, state) do
    {:reply, lookup(state.table, :device_ids, %{}), state}
  end

  defp do_call({:allocate, keys}, _from, state) do
    {ids, next} = allocate(lookup(state.table, :device_ids, %{}), state.table, keys)

    reply =
      case write(state, [{:device_ids, ids}, {:next_device_id, next}]) do
        :ok -> {:ok, Map.take(ids, keys)}
        error -> error
      end

    {:reply, reply, state}
  end

  defp do_call(:settings, _from, state) do
    {:reply, current_settings(state.table), state}
  end

  defp do_call({:put_settings, changes}, _from, state) do
    merged =
      Map.merge(current_settings(state.table), Map.take(changes, Map.keys(@default_settings)))

    reply =
      if valid_settings?(merged),
        do: write(state, [{:settings, merged}]),
        else: {:error, :invalid_settings}

    {:reply, reply, state}
  end

  @doc "The `:max_lease` the mesh's Lights runs with (see \"Upload seq\")."
  @spec lights_max_lease() :: pos_integer()
  def lights_max_lease, do: @lights_max_lease

  @impl GenServer
  def format_status(status), do: Redact.format_status(status)

  # ── Replace ──────────────────────────────────────────────────────────

  defp do_replace(state, inv, opts) do
    case stored(state.table) do
      {:valid, stored} ->
        replace_stored(state, stored, inv, opts)

      :absent ->
        floors = floors(state.table)

        with {:ok, seq} <- upload_seq(state, inv, opts),
             do: store_replacement(state, inv, seq, floors, :other_mesh)

      {:invalid, raw} ->
        floors =
          case raw_floor(raw) do
            {:ok, floor} ->
              put_floor(floors(state.table), floor)

            :error ->
              Logger.warning("TuyaMesh.Store: replacing an invalid inventory; its seq is lost")
              floors(state.table)
          end

        with {:ok, seq} <- upload_seq(state, inv, opts),
             do: store_replacement(state, inv, seq, floors, :other_mesh)
    end
  end

  defp replace_stored(state, stored, inv, opts) do
    floors = floors(state.table)

    cond do
      same_mesh?(stored, inv) ->
        with {:ok, seq} <- upload_seq(state, inv, opts),
             do: store_replacement(state, inv, seq, floors, :same_mesh)

      Keyword.get(opts, :allow_new_mesh, false) ->
        # The displaced mesh leaves its seq behind as a floor.
        floors = put_floor(floors, inv_floor(stored))

        with {:ok, seq} <- upload_seq(state, inv, opts),
             do: store_replacement(state, inv, seq, floors, :other_mesh)

      true ->
        {:error, :new_mesh}
    end
  end

  # The seq an upload is stored with (see "Upload seq"), and whether a
  # local cursor of its mesh was honoured.
  defp upload_seq(state, inv, opts) do
    local = local_seq(state.table, inv)
    seq = seq_outcome(local, inv.seq, state.max_dump_advance)
    kind = if local, do: :same_mesh, else: :new_mesh

    cond do
      seq.outcome == :taken ->
        {:ok, {kind, inv.seq}}

      Keyword.get(opts, :adopt_dump_seq, false) ->
        adopt(kind, seq)

      seq.outcome == :kept_local ->
        Logger.warning(
          "TuyaMesh.Store: the upload's seq (#{inv.seq}) is not a plausible advance on " <>
            "the device's (#{local}); keeping the device's"
        )

        {:ok, {kind, local}}

      true ->
        {:ok, {kind, local}}
    end
  end

  defp adopt(kind, %{reason: :beyond_bound, local: local, dump: dump}) do
    Logger.warning(
      "TuyaMesh.Store: adopting the upload's seq (#{dump}) over the device's (#{local})"
    )

    {:ok, {kind, dump}}
  end

  defp adopt(_kind, %{local: local, dump: dump}),
    do: {:error, {:seq_not_ahead, %{local: local, dump: dump}}}

  # This mesh's local cursor: the stored seq when it is the stored mesh,
  # else its floor (an invalid stored record's salvaged one included).
  defp local_seq(table, inv) do
    fp = fingerprint(inv.beacon_key)
    floors = floors(table)

    case stored(table) do
      {:valid, stored} ->
        if same_mesh?(stored, inv), do: stored.seq, else: Map.get(floors, fp)

      {:invalid, raw} ->
        floors =
          case raw_floor(raw) do
            {:ok, floor} -> put_floor(floors, floor)
            :error -> floors
          end

        Map.get(floors, fp)

      :absent ->
        Map.get(floors, fp)
    end
  end

  defp seq_outcome(nil, dump, _bound),
    do: %{outcome: :taken, reason: nil, local: nil, dump: dump}

  defp seq_outcome(local, dump, bound) do
    {outcome, reason} =
      case Integer.mod(dump - local, @seq_space) do
        0 -> {:same, nil}
        ahead when ahead <= bound -> {:taken, nil}
        ahead when ahead < div(@seq_space, 2) -> {:kept_local, :beyond_bound}
        _behind -> {:kept_local, :behind}
      end

    %{outcome: outcome, reason: reason, local: local, dump: dump}
  end

  defp max_dump_advance(opts) do
    case Keyword.get(opts, :max_dump_advance, @max_dump_advance) do
      n when is_integer(n) and n >= 0 and n <= @max_dump_advance -> n
      _other -> raise ArgumentError, "max_dump_advance must be 0..#{@max_dump_advance}"
    end
  end

  defp store_replacement(state, inv, {kind, seq}, floors, over) do
    inv = %{inv | seq: seq}
    floors = Map.delete(floors, fingerprint(inv.beacon_key))

    case write_inventory(state, inv, [{:seq_floors, floors}, bump(state.table)], over) do
      :ok ->
        notify(state)
        {:ok, kind}

      error ->
        error
    end
  end

  # Of two local cursors of one mesh (a floor and a salvaged record).
  defp later_seq(a, b), do: a |> Seq.new() |> Seq.advance_to(b) |> Seq.value()

  # ── Persist checks ───────────────────────────────────────────────────

  defp check_persistable(stored, inv, mode) do
    if same_mesh?(stored, inv), do: check_seq(mode, stored, inv), else: {:error, :mesh_changed}
  end

  # Per persist mode: what may change besides the seq, and how the stored
  # cursor may move. :advance may change groups and only moves forward;
  # {:tighten, leased} changes nothing but the seq, which may move back,
  # and only from exactly `leased`.
  defp check_seq(:advance, stored, inv) do
    cond do
      stored.bulbs != inv.bulbs -> {:error, :bulbs_changed}
      inv.seq == stored.seq or Seq.ahead?(stored.seq, inv.seq) -> :ok
      true -> {:error, :seq_behind}
    end
  end

  defp check_seq({:tighten, leased}, stored, inv) do
    cond do
      stored.seq != leased -> {:error, :stale_tighten}
      stored.bulbs != inv.bulbs or stored.groups != inv.groups -> {:error, :inventory_changed}
      true -> :ok
    end
  end

  defp classify_against(nil, _inv), do: :empty

  defp classify_against(stored, inv),
    do: if(same_mesh?(stored, inv), do: :same_mesh, else: :new_mesh)

  defp same_mesh?(a, b), do: Crypto.key_bytes(a.beacon_key) == Crypto.key_bytes(b.beacon_key)

  # ── Seq floors ───────────────────────────────────────────────────────

  # Not reversible to the key (SHA-256 of a 128-bit key), and never shown.
  defp fingerprint(beacon_key), do: :crypto.hash(:sha256, Crypto.key_bytes(beacon_key))

  defp floors(table), do: lookup(table, :seq_floors, %{})

  defp inv_floor(inv), do: {fingerprint(inv.beacon_key), inv.seq}

  # An invalid record's floor, when its mesh key and seq are still usable
  # whatever else broke.
  defp raw_floor(%{"beaconKey" => key, "seq" => seq})
       when is_integer(seq) and seq >= 0 and seq <= 65_535 do
    if Inventory.valid_key?(key), do: {:ok, {fingerprint(key), seq}}, else: :error
  end

  defp raw_floor(_raw), do: :error

  # Never lowers a floor already recorded for that mesh.
  defp put_floor(floors, {fp, seq}), do: Map.update(floors, fp, seq, &later_seq(&1, seq))

  # ── Preview ──────────────────────────────────────────────────────────

  # Bulbs are matched by MAC whatever the mesh (they keep their ids). A new
  # mesh's groups are all new and the old ones all go, even where local ids
  # coincide, since every group gets a fresh sub-device id.
  defp build_preview(stored, inv) do
    {old_bulbs, old_groups} = if stored, do: {stored.bulbs, stored.groups}, else: {[], []}
    mesh = classify_against(stored, inv)
    group = &%{local_id: &1.local_id, name: &1.name}

    groups =
      if mesh == :same_mesh,
        do: diff(old_groups, inv.groups, & &1.local_id, group),
        else: %{added: Enum.map(inv.groups, group), removed: Enum.map(old_groups, group)}

    %{
      mesh: mesh,
      bulbs: diff(old_bulbs, inv.bulbs, & &1.mac, &%{mac: &1.mac, label: &1.label}),
      groups: groups
    }
  end

  defp preview_of(state, inv) do
    state.table
    |> valid_or_nil()
    |> build_preview(inv)
    |> Map.merge(%{
      revision: revision(state.table),
      seq: seq_outcome(local_seq(state.table, inv), inv.seq, state.max_dump_advance)
    })
  end

  defp diff(old, new, key_fun, summary_fun) do
    old_keys = MapSet.new(old, key_fun)
    new_keys = MapSet.new(new, key_fun)

    %{
      added: for(x <- new, not MapSet.member?(old_keys, key_fun.(x)), do: summary_fun.(x)),
      removed: for(x <- old, not MapSet.member?(new_keys, key_fun.(x)), do: summary_fun.(x))
    }
  end

  # ── Revision ─────────────────────────────────────────────────────────

  defp revision(table), do: lookup(table, :revision, 0)

  # The record to insert with an inventory-changing write.
  defp bump(table), do: {:revision, revision(table) + 1}

  defp stale?(table, opts) do
    case Keyword.fetch(opts, :expected_revision) do
      {:ok, expected} -> expected != revision(table)
      :error -> false
    end
  end

  # ── Device ids ───────────────────────────────────────────────────────

  defp allocate(ids, table, keys) do
    next = lookup(table, :next_device_id, 1)

    Enum.reduce(keys, {ids, next}, fn key, {ids, next} ->
      if Map.has_key?(ids, key), do: {ids, next}, else: {Map.put(ids, key, next), next + 1}
    end)
  end

  defp inventory_keys(inv) do
    Enum.map(inv.bulbs, &{:bulb, &1.mac}) ++ Enum.map(inv.groups, &{:group, &1.local_id})
  end

  # `group_ids` is a handful of local ids (0..254), so a list is enough.
  defp prune_groups(ids, group_ids) do
    Map.reject(ids, fn
      {{:group, gid}, _id} -> gid not in group_ids
      _bulb -> false
    end)
  end

  # ── Storage ──────────────────────────────────────────────────────────

  # One insert: the inventory, its device ids (allocated for every bulb and
  # group, departed groups dropped) and the counter, plus `extra` records.
  # `over` says what the write replaces: the :same_mesh (its group ids are
  # kept) or an :other_mesh, absent or invalid record (all group ids drop).
  defp write_inventory(state, inv, extra, over) when over in [:same_mesh, :other_mesh] do
    ids = lookup(state.table, :device_ids, %{})
    ids = if over == :same_mesh, do: ids, else: prune_groups(ids, [])
    {ids, next} = allocate(ids, state.table, inventory_keys(inv))
    ids = prune_groups(ids, Enum.map(inv.groups, & &1.local_id))

    inserts =
      [{:inventory, Inventory.to_map(inv)}, {:device_ids, ids}, {:next_device_id, next}] ++
        extra

    write(state, inserts)
  end

  # A cleared inventory is stored as `nil`, so the clear is one insert too.
  defp write_clear(state, floors) do
    ids = state.table |> lookup(:device_ids, %{}) |> prune_groups([])

    inserts = [{:inventory, nil}, {:device_ids, ids}, {:seq_floors, floors}, bump(state.table)]

    with :ok <- write(state, inserts) do
      notify(state)
    end
  end

  # PubSub's registry raises (not exits) when it isn't started.
  defp notify(state) do
    Phoenix.PubSub.broadcast(state.pubsub, @topic, {:tuya_mesh_store, :inventory_changed})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp write(state, inserts) do
    case state.write_fun.(state.table, inserts) do
      :ok ->
        :ok

      {:error, reason} ->
        # DETS errors name the file and the failure, never the records.
        Logger.error("TuyaMesh.Store write failed: #{inspect(reason)}")
        {:error, :write_failed}
    end
  end

  defp default_write(table, inserts) do
    with :ok <- :dets.insert(table, inserts), do: :dets.sync(table)
  end

  defp lookup(table, key, default) do
    case :dets.lookup(table, key) do
      [{^key, value}] -> value
      _ -> default
    end
  end

  # :absent, {:valid, inventory} or {:invalid, raw}. The raw form never
  # leaves this module.
  defp stored(table) do
    case :dets.lookup(table, :inventory) do
      [{:inventory, raw}] when raw != nil ->
        case Inventory.decode(raw) do
          {:ok, inv} -> {:valid, inv}
          {:error, _reason} -> {:invalid, raw}
        end

      _ ->
        :absent
    end
  end

  defp load_stored(table) do
    with [{:inventory, raw}] when raw != nil <- :dets.lookup(table, :inventory),
         {:error, reason} <- Inventory.decode(raw) do
      # Inventory errors carry no key material.
      Logger.warning("TuyaMesh.Store: stored inventory is invalid (#{inspect(reason)})")
      {:error, {:invalid, reason}}
    else
      {:ok, inv} -> {:ok, inv}
      _absent -> {:error, :no_inventory}
    end
  end

  defp fetch_stored(table) do
    case stored(table) do
      {:valid, inv} -> {:ok, inv}
      :absent -> {:error, :no_inventory}
      {:invalid, _raw} -> {:error, :invalid_stored}
    end
  end

  defp valid_or_nil(table) do
    case stored(table) do
      {:valid, inv} -> inv
      _ -> nil
    end
  end

  # Server side, a request arrives sealed from the client API, or raw from a
  # direct call: validated either way.
  defp validate(input) do
    case input |> Redact.unseal() |> Inventory.decode() do
      {:ok, inv} -> {:ok, inv}
      {:error, reason} -> {:error, {:invalid, reason}}
    end
  end

  defp current_settings(table) do
    case lookup(table, :settings, nil) do
      settings when is_map(settings) -> Map.merge(@default_settings, settings)
      _ -> @default_settings
    end
  end

  defp valid_settings?(%{min_mireds: min, max_mireds: max, invert: invert}),
    do: is_integer(min) and is_integer(max) and min > 0 and min < max and is_boolean(invert)

  defp dets_path do
    if File.dir?("/data"),
      do: "/data/tuya_mesh.dets",
      else: Path.join([File.cwd!(), "_build", "tuya_mesh.dets"])
  end
end
