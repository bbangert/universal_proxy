defmodule UniversalProxy.TuyaMesh do
  @moduledoc """
  Host-side facade for the Tuya Beacon Mesh (`UniversalProxy.TuyaBeaconMesh`):
  inventory upload, status and clear, for the Bluetooth tab.

  Processes (BT targets only):

    * `UniversalProxy.TuyaMesh.Store` — top-level DETS store (inventory,
      sub-device ids, settings);
    * `UniversalProxy.TuyaMesh.Supervisor` — in the Bluez subtree while a
      radio holds the `:tuya_mesh` role; its `Resolver` runs the mesh
      (Radio + Lights) when the start conditions hold.

  ## Upload

  `upload/2` decodes the JSON dump (`Inventory.decode/1`), then stores it.
  Re-uploading the **same mesh** (same mesh `beaconKey`) goes straight
  through and never moves the sequence cursor back. A **different mesh**
  replaces every bulb and its HA entities, so it needs `confirm: true`;
  without it the reply is `{:error, {:confirm_new_mesh, preview}}`, where
  `preview` (also from `preview/1`) lists the bulbs and groups added and
  removed.

  A confirmation is only good for the diff it showed: pass the preview's
  `revision` as `expected_revision:` and the upload is refused, with
  nothing written, as `{:error, {:stale_preview, fresh_preview}}` if the
  stored inventory changed since (another upload, a clear, a group
  change). The Store checks it in the same call as the write; it is also
  checked here first, so a stale confirmation doesn't stop the mesh for
  nothing. The mesh is stopped before the Store changes and restarted
  after, so the Lights controller reads the new inventory (and its `seq`)
  from the Store on start.

  The dump's `seq` is taken only as a small advance on the device's own
  counter (`Store`, "Upload seq"); the preview's `seq` says what happens to
  it. A dump whose counter is ahead beyond that bound (the Tuya app was
  used since the last upload) is adopted only with `adopt_dump_seq: true`,
  which also requires `expected_revision:` (`{:error,
  :adopt_needs_revision}` otherwise), so it lands only on the inventory
  whose counter the user was shown. One behind or equal is refused as
  `{:error, {:seq_not_ahead, %{local:, dump:}}}`.

  Decode errors come back as `{:error, {:invalid_inventory, reason}}`;
  `Inventory.decode/1` reasons carry no key material.

  ## Status

  `status/0` (see `t:UniversalProxy.TuyaMesh.Resolver.status/0`): the role
  MAC, whether the mesh runs (or why it is idle), the radio's readiness and
  last error, then the bulbs (label, MAC, node id, last seen, reachable,
  checking) and groups. No keys. Changes are broadcast on `UniversalProxy.PubSub`
  topic `topic/0` as `{:tuya_mesh_status, status}`.

  ## Groups

  `create_group/3`, `add_member/3`, `remove_member/3`, `delete_group/2`
  and `rename_group/3` edit the mesh's groups through the running
  `Lights` (`TuyaBeaconMesh.Lights`, "Groups"): validated, persisted to
  the Store (which allocates a new group's sub-device id and broadcasts
  `:inventory_changed`, so Home Assistant follows), then sent to the
  bulbs. `group_sync/1` reports each member change as `:pending`,
  `:confirmed` (the bulb's A3 group list agrees) or `:unconfirmed`. They
  need the mesh running: `{:error, :not_running}` otherwise.

  Every function here is safe on any target and while the subsystem is
  down (CLAUDE.md `catch :exit` idiom; a timed-out change is reported as
  `{:error, :timeout}`, since it may still have happened).

  Test seams: `:store`, `:resolver` and `:lights` server names, and `:mesh_processes`
  (the names that must all be unregistered before a change bypasses the
  Resolver), in every `opts`.
  """

  require Logger

  alias UniversalProxy.TuyaBeaconMesh.{Inventory, Lights, Radio}
  alias UniversalProxy.TuyaMesh.{Mesh, Presence, Resolver, Store}

  # Every registered process of the mesh subtree.
  @mesh_processes [
    UniversalProxy.TuyaMesh.Supervisor,
    UniversalProxy.TuyaMesh.MeshSupervisor,
    Mesh,
    Radio,
    Lights,
    Presence
  ]

  @type upload_error ::
          {:invalid_inventory, term()}
          | {:confirm_new_mesh, Store.preview()}
          | {:stale_preview, Store.preview()}
          | {:seq_not_ahead, %{local: non_neg_integer(), dump: non_neg_integer()}}
          | :adopt_needs_revision
          | :unavailable
          | :timeout
          | term()

  @doc "PubSub topic of `{:tuya_mesh_status, status}` broadcasts."
  @spec topic() :: String.t()
  def topic, do: Resolver.topic()

  @doc """
  Stores an uploaded JSON dump (or decoded map) and restarts the mesh on
  it. `opts`: `confirm: true` to replace a different mesh;
  `expected_revision:` (a preview's `revision`) to write only over the
  inventory that preview was computed against; `adopt_dump_seq: true` to
  take a dump's counter that is ahead beyond the bound. See the moduledoc.
  """
  @spec upload(binary() | map(), keyword()) ::
          {:ok, :same_mesh | :new_mesh} | {:error, upload_error()}
  def upload(json, opts \\ []) do
    store = Keyword.get(opts, :store, Store)

    with :ok <- adoption_confirmed(opts),
         {:ok, inv} <- decode(json),
         {:ok, preview} <- Store.preview(inv, store),
         :ok <- current(preview, opts),
         :ok <- confirmed(preview, opts) do
      replace_opts =
        [allow_new_mesh: preview.mesh == :new_mesh] ++
          Keyword.take(opts, [:expected_revision, :adopt_dump_seq])

      case change(opts, &Resolver.replace(inv, replace_opts, &1), fn ->
             Store.replace(inv, replace_opts, store)
           end) do
        {:ok, kind} ->
          Logger.info("TuyaMesh: inventory uploaded (#{kind}, #{length(inv.bulbs)} bulbs)")
          {:ok, kind}

        # Another mesh was stored after the preview: confirm against it.
        {:error, :new_mesh} ->
          with {:ok, preview} <- Store.preview(inv, store),
               do: {:error, {:confirm_new_mesh, preview}}

        {:error, _reason} = error ->
          error
      end
    end
  end

  @doc """
  What `upload/2` would change, without writing: `{:ok, %{mesh: :empty |
  :same_mesh | :new_mesh, bulbs: %{added:, removed:}, groups: %{added:,
  removed:}}}` (entries carry MACs, labels, group ids and names only).
  """
  @spec preview(binary() | map(), keyword()) :: {:ok, Store.preview()} | {:error, term()}
  def preview(json, opts \\ []) do
    with {:ok, inv} <- decode(json), do: Store.preview(inv, Keyword.get(opts, :store, Store))
  end

  @doc "The mesh status (see the moduledoc). An idle, store-backed status when the subtree is down."
  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    Resolver.status(Keyword.get(opts, :resolver, Resolver))
  catch
    :exit, _ -> offline_status(Keyword.get(opts, :store, Store))
  end

  @doc """
  Stops the mesh and removes the stored inventory (bulb sub-device ids and
  settings are kept). A stored inventory that no longer validates and whose
  `seq` can't be recovered is refused with `{:error, :seq_unrecoverable}`;
  `force: true` clears it anyway (see `Store.clear/2`).
  """
  @spec clear(keyword()) :: :ok | {:error, term()}
  def clear(opts \\ []) do
    store = Keyword.get(opts, :store, Store)
    clear_opts = Keyword.take(opts, [:force])
    change(opts, &Resolver.clear(&1, clear_opts), fn -> Store.clear(store, clear_opts) end)
  end

  @doc "Mesh settings (colour-temperature range in mireds, invert flag)."
  @spec settings(keyword()) :: Store.settings()
  def settings(opts \\ []), do: Store.settings(Keyword.get(opts, :store, Store))

  @doc "Updates mesh settings (see `Store.put_settings/2`)."
  @spec put_settings(map(), keyword()) :: :ok | {:error, term()}
  def put_settings(changes, opts \\ []),
    do: Store.put_settings(changes, Keyword.get(opts, :store, Store))

  @doc """
  Creates a group of `members` (MACs or labels) and returns its local id.
  Errors include `{:error, :bad_group_name | :duplicate_group_name |
  :unknown_bulb | :no_free_group_id | {:group_slots_full, mac} |
  :persist_failed | :not_running}`.
  """
  @spec create_group(String.t(), [String.t()], keyword()) :: {:ok, 1..254} | {:error, term()}
  def create_group(name, members, opts \\ []),
    do: Lights.create_group(name, members, lights(opts))

  @doc "Adds a bulb to a group (name or local id); re-sends the join for a member."
  @spec add_member(String.t() | byte(), String.t(), keyword()) :: :ok | {:error, term()}
  def add_member(group, mac_or_label, opts \\ []),
    do: Lights.add_member(group, mac_or_label, lights(opts))

  @doc "Removes a bulb from a group; re-sends a tracked removal."
  @spec remove_member(String.t() | byte(), String.t(), keyword()) :: :ok | {:error, term()}
  def remove_member(group, mac_or_label, opts \\ []),
    do: Lights.remove_member(group, mac_or_label, lights(opts))

  @doc """
  Deletes a group: every bulb that may hold it is sent a removal.
  `dismiss: true` also sends the (hardware-untested) broadcast dismiss.
  """
  @spec delete_group(String.t() | byte(), keyword()) :: :ok | {:error, term()}
  def delete_group(group, opts \\ []),
    do: Lights.delete_group(group, lights(opts) ++ Keyword.take(opts, [:dismiss]))

  @doc "Renames a group (nothing is sent to the bulbs)."
  @spec rename_group(String.t() | byte(), String.t(), keyword()) :: :ok | {:error, term()}
  def rename_group(group, name, opts \\ []), do: Lights.rename_group(group, name, lights(opts))

  @doc """
  HA sub-device ids by `{:bulb, mac}` and `{:group, local_id}`
  (`Store.device_ids/1`; `%{}` while the Store is down). A group's id is
  never reused, so it tells a recreated local id from the group it replaced.
  """
  @spec device_ids(keyword()) :: %{Store.device_key() => pos_integer()}
  def device_ids(opts \\ []), do: Store.device_ids(Keyword.get(opts, :store, Store))

  @doc "Groups, per-member change state and per-bulb slot use (`Lights.groups/1`)."
  @spec group_sync(keyword()) ::
          {:ok, %{groups: [Lights.group_view()], slots: %{String.t() => non_neg_integer()}}}
          | {:error, term()}
  def group_sync(opts \\ []), do: Lights.groups(lights(opts))

  @doc """
  Stops the mesh and keeps it stopped for a while, so its radio goes back
  to `bluetoothd` before a Bluez subtree restart (see the Resolver's
  "Releasing the radio"). `opts`: `:resolver`, `:hold_ms`, `:timeout`.
  `{:error, :not_running}` without a Resolver, `{:error, :timeout}` when it
  didn't finish in time (the mesh may still be stopping).
  """
  @spec release_radio(keyword()) :: :ok | {:error, :not_running | :timeout}
  def release_radio(opts \\ []) do
    Resolver.release(
      Keyword.get(opts, :resolver, Resolver),
      Keyword.take(opts, [:hold_ms, :timeout])
    )
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _reason -> {:error, :not_running}
  end

  # ── Private ──────────────────────────────────────────────────────────

  # Lights' client functions already follow the `catch :exit` idiom
  # (`{:error, :not_running}`, or `{:error, :timeout}` for a change that may
  # have happened).
  defp lights(opts), do: [server: Keyword.get(opts, :lights, Lights)]

  defp decode(input) do
    case Inventory.decode(input) do
      {:ok, inv} ->
        {:ok, inv}

      {:error, reason} ->
        Logger.info("TuyaMesh: inventory upload rejected (#{inspect(reason)})")
        {:error, {:invalid_inventory, reason}}
    end
  end

  defp adoption_confirmed(opts) do
    if Keyword.get(opts, :adopt_dump_seq, false) and
         not Keyword.has_key?(opts, :expected_revision),
       do: {:error, :adopt_needs_revision},
       else: :ok
  end

  defp current(preview, opts) do
    case Keyword.fetch(opts, :expected_revision) do
      {:ok, revision} when revision != preview.revision -> {:error, {:stale_preview, preview}}
      _ -> :ok
    end
  end

  defp confirmed(%{mesh: :new_mesh} = preview, opts) do
    if Keyword.get(opts, :confirm, false), do: :ok, else: {:error, {:confirm_new_mesh, preview}}
  end

  defp confirmed(_preview, _opts), do: :ok

  # Through the Resolver, which stops the mesh around the change. Without
  # one, the Store is written directly only when no part of the mesh
  # subtree is alive: a missing Resolver may just be mid-restart (or
  # killed) with its mesh still running, and writing then would break
  # stop-before-replace. A timeout or a Resolver dying mid-call may have
  # applied the change: not retried.
  defp change(opts, via_resolver, direct) do
    via_resolver.(Keyword.get(opts, :resolver, Resolver))
  catch
    :exit, {:noproc, _} ->
      if mesh_down?(opts) do
        result = direct.()
        broadcast(offline_status(Keyword.get(opts, :store, Store)))
        result
      else
        {:error, :unavailable}
      end

    :exit, {:timeout, _} ->
      {:error, :timeout}

    :exit, _reason ->
      {:error, :unavailable}
  end

  defp mesh_down?(opts) do
    opts
    |> Keyword.get(:mesh_processes, @mesh_processes)
    |> Enum.all?(&(GenServer.whereis(&1) == nil))
  end

  defp offline_status(store) do
    role = UniversalProxy.Bluetooth.roles().tuya_mesh
    reason = if role, do: :not_running, else: :no_role
    Resolver.offline_status(role, reason, Store.load(store))
  end

  # PubSub's registry raises (not exits) when it isn't started.
  defp broadcast(status) do
    Phoenix.PubSub.broadcast(UniversalProxy.PubSub, topic(), {:tuya_mesh_status, status})
  rescue
    ArgumentError -> :ok
  end
end
