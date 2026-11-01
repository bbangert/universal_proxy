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
  removed. The mesh is stopped before the Store changes and restarted
  after, so the Lights controller reads the new inventory (and its `seq`)
  from the Store on start.

  Decode errors come back as `{:error, {:invalid_inventory, reason}}`;
  `Inventory.decode/1` reasons carry no key material.

  ## Status

  `status/0` (see `t:UniversalProxy.TuyaMesh.Resolver.status/0`): the role
  MAC, whether the mesh runs (or why it is idle), the radio's readiness and
  last error, then the bulbs (label, MAC, node id, last seen, reachable)
  and groups. No keys. Changes are broadcast on `UniversalProxy.PubSub`
  topic `topic/0` as `{:tuya_mesh_status, status}`.

  Every function here is safe on any target and while the subsystem is
  down (CLAUDE.md `catch :exit` idiom; a timed-out change is reported as
  `{:error, :timeout}`, since it may still have happened).

  Test seams: `:store` and `:resolver` server names in every `opts`.
  """

  require Logger

  alias UniversalProxy.TuyaBeaconMesh.Inventory
  alias UniversalProxy.TuyaMesh.{Resolver, Store}

  @type upload_error ::
          {:invalid_inventory, term()}
          | {:confirm_new_mesh, Store.preview()}
          | :unavailable
          | :timeout
          | term()

  @doc "PubSub topic of `{:tuya_mesh_status, status}` broadcasts."
  @spec topic() :: String.t()
  def topic, do: Resolver.topic()

  @doc """
  Stores an uploaded JSON dump (or decoded map) and restarts the mesh on
  it. `opts`: `confirm: true` to replace a different mesh. See the
  moduledoc.
  """
  @spec upload(binary() | map(), keyword()) ::
          {:ok, :same_mesh | :new_mesh} | {:error, upload_error()}
  def upload(json, opts \\ []) do
    store = Keyword.get(opts, :store, Store)

    with {:ok, inv} <- decode(json),
         {:ok, preview} <- Store.preview(inv, store),
         :ok <- confirmed(preview, opts) do
      allow? = preview.mesh == :new_mesh

      case change(opts, &Resolver.replace(inv, [allow_new_mesh: allow?], &1), fn ->
             Store.replace(inv, [allow_new_mesh: allow?], store)
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

  @doc "Stops the mesh and removes the stored inventory (sub-device ids and settings are kept)."
  @spec clear(keyword()) :: :ok | {:error, term()}
  def clear(opts \\ []) do
    store = Keyword.get(opts, :store, Store)
    change(opts, &Resolver.clear/1, fn -> Store.clear(store) end)
  end

  @doc "Mesh settings (colour-temperature range in mireds, invert flag)."
  @spec settings(keyword()) :: Store.settings()
  def settings(opts \\ []), do: Store.settings(Keyword.get(opts, :store, Store))

  @doc "Updates mesh settings (see `Store.put_settings/2`)."
  @spec put_settings(map(), keyword()) :: :ok | {:error, term()}
  def put_settings(changes, opts \\ []),
    do: Store.put_settings(changes, Keyword.get(opts, :store, Store))

  # ── Private ──────────────────────────────────────────────────────────

  defp decode(input) do
    case Inventory.decode(input) do
      {:ok, inv} ->
        {:ok, inv}

      {:error, reason} ->
        Logger.info("TuyaMesh: inventory upload rejected (#{inspect(reason)})")
        {:error, {:invalid_inventory, reason}}
    end
  end

  defp confirmed(%{mesh: :new_mesh} = preview, opts) do
    if Keyword.get(opts, :confirm, false), do: :ok, else: {:error, {:confirm_new_mesh, preview}}
  end

  defp confirmed(_preview, _opts), do: :ok

  # Through the Resolver, which stops the mesh around the change. With no
  # Resolver (no mesh role, subtree down) no mesh runs, so the Store is
  # changed directly and the status broadcast from here. A timeout or a
  # Resolver dying mid-call may have applied the change: not retried.
  defp change(opts, via_resolver, direct) do
    via_resolver.(Keyword.get(opts, :resolver, Resolver))
  catch
    :exit, {:noproc, _} ->
      result = direct.()
      broadcast(offline_status(Keyword.get(opts, :store, Store)))
      result

    :exit, {:timeout, _} ->
      {:error, :timeout}

    :exit, _reason ->
      {:error, :unavailable}
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
