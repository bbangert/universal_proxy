defmodule UniversalProxyWeb.TuyaMeshComponent do
  @moduledoc """
  Tuya mesh card on the Bluetooth tab: upload the mesh's JSON dump, see the
  mesh's status, bulbs and groups, and clear the stored inventory. Rendered
  by `UniversalProxyWeb.BluetoothLive` only while a radio holds the
  `:tuya_mesh` role. Everything goes through `UniversalProxy.TuyaMesh`.

  ## Upload

  One `.json` file of at most 64 KiB (`Inventory`'s own cap), sent when the
  form is submitted rather than on selection (no `auto_upload`): the dump
  holds every key of the mesh, so it only reaches the device once the user
  asks for it, and at that size there is no progress to show. Submit reads
  the temp file inside `consume_uploaded_entries/3`, then calls
  `TuyaMesh.preview/1`:

    * an empty store, or the same mesh without bulbs removed, uploads
      straight away, and the bulbs and groups added and removed are shown
      as the result;
    * a different mesh, or the same mesh with bulbs removed, opens a
      confirmation listing that diff (HA drops the removed bulbs'
      entities and history), and only its confirm button uploads. The
      facade itself requires `confirm: true` for a new mesh only, so it is
      passed only when the confirmed preview was a new mesh: should
      another mesh be stored meanwhile, the unconfirmed upload comes back
      as `{:error, {:confirm_new_mesh, preview}}` and is asked again.

  A dump whose sequence counter is far ahead of the device's (the
  preview's `seq` is `:kept_local` / `:beyond_bound`) also opens the
  confirmation, with a notice: the Tuya or Smart Life app may have moved
  the bulbs on since the last upload. Its main action keeps the device's
  counter. "Adopt the dump's counter…" replaces the dialog with a second
  one (a fresh token) that warns what adopting a stale dump does, and only
  its confirm uploads with `adopt_dump_seq: true`. Cancel in either keeps
  everything as stored.

  Every upload carries the preview's `revision` as `expected_revision:`,
  so it only lands on the inventory that preview diffed against. When
  another tab uploaded, cleared or changed groups in between, the facade
  answers `{:error, {:stale_preview, fresh}}` with nothing written, and the
  confirmation re-opens on the fresh diff, flagged as changed.

  Between the preview and the confirm (or cancel) the dump sits in this
  component's `:pending` assign, sealed in a closure
  (`UniversalProxy.TuyaMesh.Redact.seal/1`) so a crash report or an
  inspected socket prints it as an opaque function. It is never rendered,
  and is dropped on confirm, cancel, success and failure. Each dialog
  carries a fresh token in its confirm button, and only a click with the
  token of the dialog on screen uploads, so a click queued from a dialog
  that went stale can't confirm its replacement unseen.

  Errors are rendered from their reasons, which carry no key material
  (`Inventory.decode/1` names entries by MAC, node id, group id or
  position only). Nothing here logs or inspects the dump.

  ## Colour temperature

  Shown while an inventory is loaded. The warm and cool ends of the range
  are entered in Kelvin (1000 to 10000, warm below cool) and stored as
  mireds (`round(1_000_000 / K)`, `TuyaMesh.put_settings/1`); the stored
  mireds are shown back as Kelvin rounded to 50, so a field left as shown
  keeps its exact stored mired; only an edited field is converted. "Invert" is for bulbs whose
  temperature scale runs the other way. Save is offered only for a valid
  entry that differs from what is stored. A changed range is static info,
  so the proxy re-advertises it and Home Assistant reconnects briefly.

  ## Groups

  Listed from `TuyaMesh.group_sync/0` while the mesh's `Lights` runs (the
  editor), else read-only from the status. Groups are addressed by local
  id, bulbs by MAC.

    * "New group" takes a name and a member checklist and makes one
      `create_group/2` call on save (one Home Assistant reconnect);
    * "Rename" and "Delete" (after a confirmation) each make one call,
      and each also reconnects Home Assistant; the broadcast dismiss is
      never offered (hardware-untested);
    * "Edit members" opens a checklist; its save sends only what the user
      changed against the members shown when it opened, as `add_member/2`
      and `remove_member/2` calls (no reconnect). A bulb whose 8 group
      slots are used (`slots`) can't be ticked unless it may already hold
      the group.

  Each member change shows its state (pending, confirmed, unconfirmed);
  an unconfirmed one offers "Retry", which sends the same change again
  (the documented retry). Groups absent from the inventory that some bulb
  may still hold (`deleted: true`) show as "Leaving" with those bulbs,
  and "Retry removal" re-sends `delete_group/1` for their id. Every retry
  and delete first re-reads `group_sync` and acts only if the group (and
  change) still stands as shown. Rename, member and delete forms are bound
  to the group's local id and its HA sub-device id (`TuyaMesh.device_ids/0`,
  never reused), so one whose group was deleted, or replaced by a new group
  under the same local id, closes on the next refresh and sends nothing.
  After a partial member save, the form's baseline moves only by its own
  changes the group now shows.

  `group_sync` is re-read on every status update and after every action;
  while any change is pending, it is also polled with `send_update_after/3`
  every 2 s (`:tuya_group_poll_ms` app env), one timer at a time, and not
  at all otherwise.

  ## Status

  The parent subscribes to `TuyaMesh.topic/0` (a LiveComponent can't) and
  forwards each `{:tuya_mesh_status, status}` here with
  `send_update(__MODULE__, id: id, status: status)`; `update/2` takes such
  an update as the new status. The first status is read in `mount/1`.

  "Last seen" is relative to the `:now` assign, not the render time: the
  Resolver only publishes changed statuses, so the parent also sends
  `send_update(__MODULE__, id: id, now: now)` on a timer while the card is
  shown. `now` comes from the `:clock` attr (a 0-arity fun returning a
  `DateTime`, the parent's), read on the first update and on each status
  update.
  """

  use UniversalProxyWeb, :live_component

  import UniversalProxyWeb.Components.UI
  import UniversalProxyWeb.Components.Icons

  alias UniversalProxy.TuyaMesh
  alias UniversalProxy.TuyaMesh.Redact

  # Inventory.decode/1 refuses anything larger.
  @max_file_size 65_536

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:status, TuyaMesh.status())
     # `nil`, or `%{inventory: sealed_json, preview: preview, stale: bool,
     # mode: :review | :adopt, token: token}` while an upload awaits
     # confirmation (`stale`: the store changed since the user last saw a
     # diff; `:adopt`: the second, adopt-the-counter dialog).
     |> assign(:pending, nil)
     # `nil`, `:confirm`, or `:force` (the stored record's seq is lost).
     |> assign(:clearing, nil)
     # Result of the last action: `%{title:, preview:}` or `%{title:}`.
     |> assign(:notice, nil)
     |> assign(:error, nil)
     |> assign_settings(TuyaMesh.settings())
     # `nil` while `Lights` doesn't answer, else `TuyaMesh.group_sync/0`'s map.
     |> assign(:group_sync, fetch_group_sync())
     # HA sub-device id by group local id: never reused, so it tells a group
     # from a later one that took its local id.
     |> assign(:group_ids, fetch_group_ids())
     # The one open group form: `nil`, or `%{mode: :create | :rename |
     # :members, ...}` (see `open_group_form/3`).
     |> assign(:group_form, nil)
     # `nil`, or `%{gid:, name:}` while the delete confirmation is open.
     |> assign(:deleting, nil)
     |> assign(group_msg: nil, group_error: nil, poll_scheduled: false)
     |> allow_upload(:inventory,
       accept: ~w(.json),
       max_entries: 1,
       max_file_size: @max_file_size
     )}
  end

  @impl true
  def update(%{status: status}, socket) do
    socket = assign(socket, status: status, now: socket.assigns.clock.())
    {:ok, refresh_groups(socket)}
  end

  def update(%{now: now}, socket), do: {:ok, assign(socket, :now, now)}

  def update(%{poll_groups: true}, socket),
    do: {:ok, socket |> assign(:poll_scheduled, false) |> refresh_groups()}

  def update(assigns, socket) do
    socket = assign(socket, assigns)
    socket = assign_new(socket, :now, fn -> socket.assigns.clock.() end)
    {:ok, maybe_poll(socket)}
  end

  # ── Upload ──────────────────────────────────────────────────────────────

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_entry", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :inventory, ref)}

  # A new submit replaces any pending confirmation first (its dialog and
  # sealed dump), whatever the new file turns out to be: Confirm must never
  # act on an earlier file.
  def handle_event("upload", _params, socket) do
    socket = assign(socket, :pending, nil)

    case uploaded_entries(socket, :inventory) do
      {[_ | _], []} ->
        socket = assign(socket, notice: nil, error: nil)

        case consume_uploaded_entries(socket, :inventory, fn %{path: path}, _entry ->
               {:ok, File.read(path)}
             end) do
          [{:ok, json}] -> {:noreply, preview_upload(socket, json)}
          _ -> {:noreply, assign(socket, :error, "The uploaded file couldn't be read.")}
        end

      {[], []} ->
        {:noreply, assign(socket, :error, "Choose the mesh's JSON dump first.")}

      # Not uploaded (yet), or refused: its error renders beside it.
      _ ->
        {:noreply, socket}
    end
  end

  # Only the dialog on screen can confirm: a click queued from an earlier
  # one (a double-click on a dialog that then went stale) carries its old
  # token and is ignored. Events run one at a time in this process, so the
  # consumed token is also what stops a repeated confirm.
  def handle_event(
        "confirm_upload",
        %{"token" => token},
        %{assigns: %{pending: %{token: token, mode: :review}}} = socket
      ),
      do: {:noreply, confirm_pending(socket, [])}

  # The adopt dialog replaces the review one, with a token of its own.
  def handle_event(
        "ask_adopt",
        %{"token" => token},
        %{assigns: %{pending: %{token: token, mode: :review} = pending}} = socket
      ) do
    if adoptable?(pending.preview),
      do: {:noreply, assign(socket, :pending, %{pending | mode: :adopt, token: new_token()})},
      else: {:noreply, socket}
  end

  def handle_event(
        "confirm_adopt",
        %{"token" => token},
        %{assigns: %{pending: %{token: token, mode: :adopt}}} = socket
      ),
      do: {:noreply, confirm_pending(socket, adopt_dump_seq: true)}

  def handle_event("cancel_upload", _params, socket),
    do: {:noreply, assign(socket, :pending, nil)}

  # ── Clear ───────────────────────────────────────────────────────────────

  def handle_event("ask_clear", _params, socket),
    do: {:noreply, assign(socket, clearing: :confirm, notice: nil, error: nil)}

  def handle_event("cancel_clear", _params, socket),
    do: {:noreply, assign(socket, :clearing, nil)}

  # Each confirm only matches its own dialog's state, so a repeated or
  # queued click (e.g. a second "Clear" after the force dialog replaced the
  # first) falls through to the no-op clause.
  def handle_event("confirm_clear", _params, %{assigns: %{clearing: :confirm}} = socket),
    do: {:noreply, clear(socket, [])}

  def handle_event("confirm_force_clear", _params, %{assigns: %{clearing: :force}} = socket),
    do: {:noreply, clear(socket, force: true)}

  # ── Colour temperature ──────────────────────────────────────────────────

  def handle_event("validate_settings", %{"settings" => params}, socket),
    do: {:noreply, edit_settings(socket, params)}

  def handle_event("toggle_invert", _params, socket) do
    invert = if socket.assigns.settings_params["invert"] == "true", do: "false", else: "true"
    {:noreply, edit_settings(socket, %{"invert" => invert})}
  end

  def handle_event("save_settings", %{"settings" => params}, socket) do
    socket = edit_settings(socket, params)

    case socket.assigns.settings_change do
      {:ok, changes} -> {:noreply, save_settings(socket, changes)}
      _ -> {:noreply, socket}
    end
  end

  # ── Groups ──────────────────────────────────────────────────────────────

  def handle_event("new_group", _params, socket),
    do: {:noreply, open_group_form(socket, :create, nil)}

  def handle_event(event, %{"gid" => gid}, socket) when event in ~w(rename_group edit_members) do
    mode = if event == "rename_group", do: :rename, else: :members

    case live_group(socket.assigns.group_sync, gid) do
      nil -> {:noreply, socket}
      group -> {:noreply, open_group_form(socket, mode, group)}
    end
  end

  def handle_event("cancel_group_form", _params, socket),
    do: {:noreply, assign(socket, :group_form, nil)}

  def handle_event("group_form_change", params, %{assigns: %{group_form: %{}}} = socket),
    do: {:noreply, assign(socket, :group_form, edit_group_form(socket, params))}

  # The refresh closes a form whose group was deleted or replaced since it
  # opened: nothing is sent then.
  def handle_event("save_group_form", params, %{assigns: %{group_form: %{}}} = socket) do
    socket = socket |> assign(:group_form, edit_group_form(socket, params)) |> refresh_groups()

    case socket.assigns.group_form do
      nil -> {:noreply, assign(socket, :group_error, group_error(:stale_group, socket))}
      form -> {:noreply, save_group_form(socket, form)}
    end
  end

  def handle_event("ask_delete_group", %{"gid" => gid}, socket) do
    case live_group(socket.assigns.group_sync, gid) do
      nil ->
        {:noreply, socket}

      group ->
        deleting = %{
          gid: group.local_id,
          device_id: Map.get(socket.assigns.group_ids, group.local_id),
          name: group_title(group),
          members: length(group.members)
        }

        {:noreply, assign(socket, deleting: deleting, group_msg: nil, group_error: nil)}
    end
  end

  def handle_event("cancel_delete_group", _params, socket),
    do: {:noreply, assign(socket, :deleting, nil)}

  def handle_event("confirm_delete_group", _params, %{assigns: %{deleting: %{}}} = socket),
    do: {:noreply, delete_group(socket)}

  def handle_event("retry_member", %{"gid" => gid, "mac" => mac}, socket),
    do: {:noreply, retry_member(refresh_groups(socket), gid, mac)}

  def handle_event("retry_removal", %{"gid" => gid}, socket),
    do: {:noreply, retry_removal(refresh_groups(socket), gid)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # ── Group actions ───────────────────────────────────────────────────────

  @group_slots 8

  defp fetch_group_sync do
    case TuyaMesh.group_sync() do
      {:ok, sync} -> sync
      {:error, _reason} -> nil
    end
  end

  defp fetch_group_ids do
    for {{:group, gid}, id} <- TuyaMesh.device_ids(), into: %{}, do: {gid, id}
  end

  # Re-reads group_sync and the group ids; a form or confirmation for a
  # group that is gone or was replaced (same local id, another sub-device
  # id) closes, and polling resumes while a change is pending.
  defp refresh_groups(socket) do
    sync = fetch_group_sync()

    socket =
      assign(socket, group_sync: sync, group_ids: if(sync, do: fetch_group_ids(), else: %{}))

    form =
      case socket.assigns.group_form do
        %{gid: _} = form -> if same_group?(socket, form), do: form
        form -> form
      end

    deleting =
      case socket.assigns.deleting do
        %{} = d -> if same_group?(socket, d), do: d
        nil -> nil
      end

    socket
    |> assign(group_form: form, deleting: deleting)
    |> maybe_poll()
  end

  # Still the live group the form or dialog was opened on.
  defp same_group?(socket, %{gid: gid, device_id: device_id}) do
    live_group(socket.assigns.group_sync, gid) != nil and
      Map.get(socket.assigns.group_ids, gid) == device_id
  end

  defp maybe_poll(%{assigns: %{poll_scheduled: false, group_sync: sync}} = socket) do
    if connected?(socket) and pending?(sync) do
      send_update_after(socket.assigns.myself, %{poll_groups: true}, poll_ms())
      assign(socket, :poll_scheduled, true)
    else
      socket
    end
  end

  defp maybe_poll(socket), do: socket

  defp poll_ms, do: Application.get_env(:universal_proxy, :tuya_group_poll_ms, 2_000)

  defp pending?(nil), do: false

  defp pending?(%{groups: groups}),
    do: Enum.any?(groups, fn g -> Enum.any?(g.sync, &match?({_, %{state: :pending}}, &1)) end)

  # A group of the inventory (not an absent one), by local id or its
  # string form (event params).
  defp live_group(sync, gid) do
    case find_group(sync, gid) do
      %{deleted: false} = group -> group
      _absent_or_missing -> nil
    end
  end

  defp find_group(nil, _gid), do: nil

  defp find_group(%{groups: groups}, gid) do
    case parse_gid(gid) do
      {:ok, id} -> Enum.find(groups, &(&1.local_id == id))
      :error -> nil
    end
  end

  defp parse_gid(gid) when is_integer(gid), do: {:ok, gid}

  defp parse_gid(gid) when is_binary(gid) do
    case Integer.parse(gid) do
      {id, ""} -> {:ok, id}
      _ -> :error
    end
  end

  defp parse_gid(_gid), do: :error

  defp open_group_form(socket, mode, group) do
    form =
      case mode do
        :create ->
          %{mode: :create, name: "", selected: []}

        :rename ->
          %{mode: :rename, gid: group.local_id, name: group.name || "", shown: group.name}

        :members ->
          %{mode: :members, gid: group.local_id, baseline: group.members}
      end

    form =
      if group,
        do: Map.put(form, :device_id, Map.get(socket.assigns.group_ids, group.local_id)),
        else: form

    form =
      form
      |> Map.put_new(:selected, Map.get(form, :baseline, []))
      |> Map.merge(%{error: nil, name_error: nil})

    assign(socket, group_form: form, group_msg: nil, group_error: nil)
  end

  # Only bulbs of the mesh are kept (a checkbox value is client input).
  defp edit_group_form(socket, params) do
    params = Map.get(params, "group", %{})
    form = socket.assigns.group_form
    known = MapSet.new(socket.assigns.status.bulbs, & &1.mac)

    form =
      case params do
        %{"name" => name} when is_binary(name) and is_map_key(form, :name) -> %{form | name: name}
        _ -> form
      end

    case params do
      %{"members" => members} when is_list(members) ->
        selected = members |> Enum.filter(&MapSet.member?(known, &1)) |> Enum.uniq()
        %{form | selected: selected}

      _ ->
        form
    end
  end

  defp save_group_form(socket, %{mode: :create} = form) do
    case TuyaMesh.create_group(form.name, form.selected) do
      {:ok, _gid} ->
        socket
        |> assign(group_form: nil)
        |> assign(
          :group_msg,
          "Group “#{String.trim(form.name)}” created. Its bulbs are being asked to join, " <>
            "and Home Assistant reconnects briefly to add it."
        )
        |> refresh_groups()

      {:error, reason} ->
        socket |> refresh_groups() |> form_error(form, reason)
    end
  end

  defp save_group_form(socket, %{mode: :rename} = form) do
    current = live_group(socket.assigns.group_sync, form.gid)

    # Unchanged against the name shown when the form opened (another tab
    # may have renamed it since), or already the current name: nothing to do.
    name = trim_name(form.name)

    # Imported names may carry whitespace, so both the raw and the trimmed
    # input are compared.
    if form.name in [form.shown, current.name] or
         name in [trim_name(form.shown), trim_name(current.name)] do
      assign(socket, :group_form, nil)
    else
      case TuyaMesh.rename_group(form.gid, form.name) do
        :ok ->
          socket
          |> assign(group_form: nil)
          |> assign(
            :group_msg,
            "Group renamed to “#{String.trim(form.name)}”. " <>
              "Home Assistant reconnects briefly to pick up the new name."
          )
          |> refresh_groups()

        {:error, reason} ->
          socket |> refresh_groups() |> form_error(form, reason)
      end
    end
  end

  # Only what the user changed against the members shown when the form
  # opened, and only where the group still differs (another tab may have
  # made the same change).
  defp save_group_form(socket, %{mode: :members} = form) do
    group = live_group(socket.assigns.group_sync, form.gid)
    intended_adds = form.selected -- form.baseline
    intended_removes = form.baseline -- form.selected
    adds = Enum.reject(intended_adds, &(&1 in group.members))
    removes = Enum.filter(intended_removes, &(&1 in group.members))

    results =
      Enum.map(adds, &{&1, TuyaMesh.add_member(form.gid, &1)}) ++
        Enum.map(removes, &{&1, TuyaMesh.remove_member(form.gid, &1)})

    socket = refresh_groups(socket)

    case for({mac, {:error, reason}} <- results, do: member_error(socket, mac, reason)) do
      [] when results == [] ->
        assign(socket, :group_form, nil)

      [] ->
        assign(socket,
          group_form: nil,
          group_msg: "Member changes sent. Each bulb's state updates as it confirms."
        )

      errors ->
        # The baseline advances only by this form's own changes that the
        # group now shows, so saving again retries just the rest and
        # leaves other bulbs (another tab's edits) alone.
        members =
          case live_group(socket.assigns.group_sync, form.gid) do
            %{members: members} -> members
            nil -> []
          end

        baseline =
          Enum.uniq(
            (form.baseline -- Enum.reject(intended_removes, &(&1 in members))) ++
              Enum.filter(intended_adds, &(&1 in members))
          )

        text = errors |> Enum.uniq() |> Enum.join(" ")
        show_form_error(socket, %{form | baseline: baseline}, :error, text)
    end
  end

  defp form_error(socket, form, reason) when reason in [:bad_group_name, :duplicate_group_name],
    do: show_form_error(socket, form, :name_error, group_error(reason, socket))

  defp form_error(socket, form, reason),
    do: show_form_error(socket, form, :error, group_error(reason, socket))

  # Called after a refresh. A form that is no longer shown (its group gone,
  # or the editor read-only with Lights down) takes its error to the
  # section instead.
  defp show_form_error(socket, form, field, text) do
    if socket.assigns.group_sync != nil and socket.assigns.group_form != nil do
      form = Map.merge(form, %{error: nil, name_error: nil}) |> Map.put(field, text)
      assign(socket, :group_form, form)
    else
      assign(socket, group_form: nil, group_error: text)
    end
  end

  defp member_error(socket, _mac, {:group_slots_full, _} = reason),
    do: group_error(reason, socket)

  defp member_error(socket, mac, reason),
    do: "#{bulb_label(socket, mac)}: #{group_error(reason, socket)}"

  # The refresh drops the confirmation if its group was deleted or replaced
  # since it opened: then nothing is sent.
  defp delete_group(socket) do
    socket = refresh_groups(socket)

    case socket.assigns.deleting do
      nil ->
        assign(socket, :group_error, group_error(:stale_group, socket))

      deleting ->
        socket = assign(socket, :deleting, nil)

        case TuyaMesh.delete_group(deleting.gid) do
          :ok ->
            socket
            |> assign(
              :group_msg,
              "Group “#{deleting.name}” deleted. Its bulbs are being asked to leave it, " <>
                "and Home Assistant reconnects briefly to remove it."
            )
            |> refresh_groups()

          {:error, reason} ->
            socket |> assign(:group_error, group_error(reason, socket)) |> refresh_groups()
        end
    end
  end

  # Re-sends an unconfirmed change, only while it is still unconfirmed and
  # still the group's intent (a join for a member, a removal otherwise).
  defp retry_member(socket, gid, mac) do
    with %{} = group <- find_group(socket.assigns.group_sync, gid),
         %{op: op, state: :unconfirmed} <- Map.get(group.sync, mac),
         true <- op == :add == mac in group.members do
      result =
        if op == :add,
          do: TuyaMesh.add_member(group.local_id, mac),
          else: TuyaMesh.remove_member(group.local_id, mac)

      case result do
        :ok ->
          socket
          |> assign(group_msg: "Sent again to #{bulb_label(socket, mac)}.", group_error: nil)
          |> refresh_groups()

        {:error, reason} ->
          socket
          |> assign(group_msg: nil, group_error: member_error(socket, mac, reason))
          |> refresh_groups()
      end
    else
      _ -> socket
    end
  end

  defp retry_removal(socket, gid) do
    case find_group(socket.assigns.group_sync, gid) do
      %{deleted: true, local_id: id} -> resend_removal(socket, id)
      _ -> socket
    end
  end

  defp resend_removal(socket, gid) do
    case TuyaMesh.delete_group(gid) do
      :ok ->
        socket
        |> assign(group_msg: "Removal sent again.", group_error: nil)
        |> refresh_groups()

      {:error, reason} ->
        socket
        |> assign(group_msg: nil, group_error: group_error(reason, socket))
        |> refresh_groups()
    end
  end

  defp bulb_label(socket, mac) do
    case Enum.find(socket.assigns.status.bulbs, &(&1.mac == mac)) do
      %{label: label} when is_binary(label) -> label
      _ -> mac
    end
  end

  # ── Actions ─────────────────────────────────────────────────────────────

  defp preview_upload(socket, json) do
    case TuyaMesh.preview(json) do
      {:ok, preview} ->
        if needs_confirm?(preview),
          do: await_confirm(socket, json, preview, false),
          else: upload(socket, json, preview, [])

      {:error, reason} ->
        assign(socket, :error, upload_error(reason))
    end
  end

  defp upload(socket, json, preview, opts) do
    case TuyaMesh.upload(json, [expected_revision: preview.revision] ++ opts) do
      {:ok, _kind} ->
        socket
        |> assign(:notice, %{title: uploaded_title(preview.mesh), preview: preview})
        |> assign(:status, TuyaMesh.status())

      # The store changed since the preview: confirm the fresh diff.
      {:error, {stale, fresh}} when stale in [:stale_preview, :confirm_new_mesh] ->
        await_confirm(socket, json, fresh, true)

      {:error, reason} ->
        assign(socket, :error, upload_error(reason))
    end
  end

  defp confirm_pending(socket, opts) do
    %{inventory: sealed, preview: preview} = socket.assigns.pending
    socket = assign(socket, :pending, nil)
    confirm = if preview.mesh == :new_mesh, do: [confirm: true], else: []
    upload(socket, Redact.unseal(sealed), preview, confirm ++ opts)
  end

  # A dump far ahead asks whether to adopt its counter; a new mesh
  # replaces everything; a removed bulb loses its HA entities.
  defp needs_confirm?(%{seq: %{reason: :beyond_bound}}), do: true
  defp needs_confirm?(%{mesh: :new_mesh}), do: true
  defp needs_confirm?(%{bulbs: %{removed: removed}}), do: removed != []

  # Each dialog gets its own token, even for the same revision.
  defp await_confirm(socket, json, preview, stale?) do
    assign(socket, :pending, %{
      inventory: Redact.seal(json),
      preview: preview,
      stale: stale?,
      mode: :review,
      token: new_token()
    })
  end

  defp new_token, do: Integer.to_string(System.unique_integer([:positive]))

  defp adoptable?(preview), do: match?(%{seq: %{reason: :beyond_bound}}, preview)

  # `stored` is what the Store holds; `settings_params` what the form shows
  # (strings); `settings_change` is `{:ok, changes}` for a valid entry that
  # differs from `stored`, `:unchanged`, or `{:error, errors}`.
  defp assign_settings(socket, stored) do
    socket
    |> assign(stored_settings: stored, settings_msg: nil, settings_error: nil)
    |> put_settings_form(settings_params_for(stored))
  end

  defp settings_params_for(stored) do
    %{
      "warm_k" => Integer.to_string(mireds_to_kelvin(stored.max_mireds)),
      "cool_k" => Integer.to_string(mireds_to_kelvin(stored.min_mireds)),
      "invert" => Atom.to_string(stored.invert)
    }
  end

  defp edit_settings(socket, params) do
    params = Map.merge(socket.assigns.settings_params, Map.take(params, ~w(warm_k cool_k invert)))
    socket |> assign(settings_msg: nil, settings_error: nil) |> put_settings_form(params)
  end

  defp put_settings_form(socket, params) do
    change = settings_change(params, socket.assigns.stored_settings)

    errors =
      case change do
        {:error, errors} -> for {field, msg} <- errors, do: {field, {msg, []}}
        _ -> []
      end

    assign(socket,
      settings_params: params,
      settings_change: change,
      settings_form: to_form(params, as: :settings, errors: errors)
    )
  end

  # Only the keys that differ from this form's baseline are sent, so the
  # Store's merge keeps newer values another tab saved for the rest.
  defp save_settings(socket, changes) do
    stored = socket.assigns.stored_settings
    changed = Map.reject(changes, fn {key, value} -> Map.fetch!(stored, key) == value end)

    case TuyaMesh.put_settings(changed) do
      :ok ->
        socket
        |> assign_settings(TuyaMesh.settings())
        |> assign(
          :settings_msg,
          "Colour temperature saved. Home Assistant reconnects briefly to pick up the new range."
        )

      # A reachable Store refused the merge: it holds newer values.
      {:error, :invalid_settings} ->
        socket
        |> rebase_settings(TuyaMesh.settings())
        |> assign(:settings_error, change_error(:invalid_settings))

      # Store down or slow: its answer for `settings/0` would be the
      # defaults, so baseline and form stay exactly as they were.
      {:error, reason} ->
        assign(socket, :settings_error, change_error(reason))
    end
  end

  # The Store moved on under this form: fields the user hasn't edited (still
  # as displayed for the old baseline) follow the new stored values, edited
  # ones keep their text, and everything is validated against the new
  # baseline, so a retry sends only what was really edited.
  defp rebase_settings(socket, fresh) do
    %{stored_settings: old, settings_params: params} = socket.assigns
    shown = settings_params_for(fresh)

    rebased =
      Map.new(params, fn {key, value} ->
        if value == Map.fetch!(settings_params_for(old), key),
          do: {key, Map.fetch!(shown, key)},
          else: {key, value}
      end)

    socket |> assign(:stored_settings, fresh) |> put_settings_form(rebased)
  end

  defp settings_change(params, stored) do
    with {:ok, changes} <- parse_settings(params, stored) do
      if changes == Map.take(stored, [:min_mireds, :max_mireds, :invert]),
        do: :unchanged,
        else: {:ok, changes}
    end
  end

  @min_kelvin 1_000
  @max_kelvin 10_000

  # Each field resolves to a mired value: its stored one while the text still
  # equals the Kelvin shown for it (the display is rounded to 50 K, so the
  # text can't stand for the exact mired), else the entered Kelvin converted.
  defp parse_settings(params, stored) do
    warm = effective_mireds(params["warm_k"], stored.max_mireds)
    cool = effective_mireds(params["cool_k"], stored.min_mireds)

    errors =
      Enum.flat_map([warm_k: warm, cool_k: cool], fn
        {field, {:error, msg}} -> [{field, msg}]
        _ -> []
      end)

    case {errors, warm, cool} do
      {[], {:ok, max_mireds}, {:ok, min_mireds}} ->
        order_settings(max_mireds, min_mireds, params, params["invert"] == "true")

      _ ->
        {:error, errors}
    end
  end

  defp effective_mireds(text, stored_mireds) do
    text = String.trim(text || "")

    if text == Integer.to_string(mireds_to_kelvin(stored_mireds)),
      do: {:ok, stored_mireds},
      else: with({:ok, kelvin} <- parse_kelvin(text), do: {:ok, kelvin_to_mireds(kelvin)})
  end

  defp order_settings(max_mireds, min_mireds, params, invert) do
    cond do
      max_mireds < min_mireds ->
        {:error, cool_k: "Must be higher than the warm temperature."}

      # Mireds are whole numbers: two close temperatures can round together.
      max_mireds == min_mireds ->
        if String.trim(params["warm_k"]) == String.trim(params["cool_k"]),
          do: {:error, cool_k: "Must be higher than the warm temperature."},
          else: {:error, cool_k: "Too close to the warm temperature."}

      true ->
        {:ok, %{min_mireds: min_mireds, max_mireds: max_mireds, invert: invert}}
    end
  end

  defp parse_kelvin(value) when is_binary(value) do
    case Integer.parse(value) do
      {k, ""} when k in @min_kelvin..@max_kelvin -> {:ok, k}
      {_k, ""} -> {:error, "Must be between #{@min_kelvin} and #{@max_kelvin} K."}
      _ -> {:error, "Enter a whole number of Kelvin."}
    end
  end

  defp kelvin_to_mireds(kelvin), do: round(1_000_000 / kelvin)
  defp mireds_to_kelvin(mireds), do: round(1_000_000 / mireds / 50) * 50

  defp clear(socket, opts) do
    case TuyaMesh.clear(opts) do
      :ok ->
        socket
        |> assign(clearing: nil, notice: %{title: "Inventory cleared."})
        |> assign(:status, TuyaMesh.status())

      {:error, :seq_unrecoverable} ->
        assign(socket, :clearing, :force)

      {:error, reason} ->
        assign(socket, clearing: nil, error: change_error(reason))
    end
  end

  # ── Render ──────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :view, state_view(assigns.status))

    ~H"""
    <div id={@id} class="mt-7">
      <div class="flex items-center gap-3 mb-2.5">
        <.eyebrow class="whitespace-nowrap">
          Tuya mesh{if @status.bulbs != [], do: " · #{length(@status.bulbs)}", else: ""}
        </.eyebrow>
        <div class="flex-1"></div>
        <.button
          :if={clearable?(@status)}
          variant={:ghost}
          size={:sm}
          phx-click="ask_clear"
          phx-target={@myself}
        >
          Clear inventory
        </.button>
      </div>

      <.card padding={:none} class="overflow-hidden">
        <div class="flex items-start gap-4 p-[20px_22px]">
          <div class={[
            "flex-none w-11 h-11 rounded-[10px] flex items-center justify-center",
            if(@status.state == :running, do: "bg-success-soft text-success", else: "bg-sunken text-fg-4")
          ]}>
            <.icon name={:sun} size={24} stroke={1.7} />
          </div>

          <div class="flex-1 min-w-0">
            <div class="flex items-center gap-2.5 flex-wrap">
              <span class="text-md font-semibold">Tuya Beacon Mesh lights</span>
              <.badge variant={@view.variant} dot>{@view.label}</.badge>
            </div>
            <div class="text-xs text-fg-3 mt-1">{@view.hint}</div>
            <div :if={@status.radio} class="text-xs text-fg-3 mt-1">{radio_line(@status.radio)}</div>
            <div :if={@mesh_label} class="text-[11px] text-fg-3 mt-0.5">On {@mesh_label}</div>
          </div>
        </div>

        <form
          id={"#{@id}-upload"}
          phx-submit="upload"
          phx-change="validate"
          phx-target={@myself}
          phx-drop-target={@uploads.inventory.ref}
          inert={@pending != nil}
          class="px-[22px] pb-[18px]"
        >
          <%!-- Inert behind an open confirmation (not focusable or
               clickable); the submit handler drops `:pending` anyway. --%>
          <div class="flex items-center gap-3 flex-wrap">
            <.live_file_input
              upload={@uploads.inventory}
              aria-label="Tuya mesh JSON key dump"
              class="flex-1 min-w-0 text-sm text-fg-2"
            />
            <.button
              type="submit"
              variant={:primary}
              size={:sm}
              disabled={@uploads.inventory.entries == [] or @pending != nil}
              phx-disable-with="Uploading…"
            >
              Upload dump
            </.button>
          </div>

          <div
            :for={entry <- @uploads.inventory.entries}
            :if={upload_errors(@uploads.inventory, entry) != []}
            class="mt-2.5 p-[10px_12px] rounded-md bg-warning-soft text-warning text-xs font-medium flex items-start gap-2"
            role="alert"
          >
            <.icon name={:alert} size={14} stroke={2.0} class="mt-px flex-none" />
            <span class="flex-1">
              <span :for={err <- upload_errors(@uploads.inventory, entry)}>{upload_error(err)}</span>
            </span>
            <button
              type="button"
              phx-click="cancel_entry"
              phx-value-ref={entry.ref}
              phx-target={@myself}
              aria-label="Remove file"
              class="text-warning p-0 flex items-center cursor-pointer bg-transparent border-none"
            >
              <.icon name={:x} size={14} />
            </button>
          </div>

          <div
            :for={err <- upload_errors(@uploads.inventory)}
            class="mt-2.5 p-[10px_12px] rounded-md bg-warning-soft text-warning text-xs font-medium flex items-start gap-2"
            role="alert"
          >
            <.icon name={:alert} size={14} stroke={2.0} class="mt-px flex-none" />
            <span>{upload_error(err)}</span>
          </div>
        </form>

        <div
          :if={@error}
          role="alert"
          class="mx-[22px] mb-[18px] p-[10px_12px] rounded-md bg-warning-soft text-warning text-xs font-medium flex items-start gap-2"
        >
          <.icon name={:alert} size={14} stroke={2.0} class="mt-px flex-none" />
          <span>{@error}</span>
        </div>

        <div
          :if={@notice}
          role="status"
          class="mx-[22px] mb-[18px] p-[10px_12px] rounded-md bg-success-soft text-success text-xs font-medium flex items-start gap-2"
        >
          <.icon name={:check} size={14} stroke={2.0} class="mt-px flex-none" />
          <div class="flex-1 min-w-0">
            <div>{@notice.title}</div>
            <.diff :if={@notice[:preview]} preview={@notice.preview} />
          </div>
        </div>

        <div :if={@status.bulbs != []} class="border-t border-border-2">
          <.bulb_row :for={bulb <- @status.bulbs} bulb={bulb} now={@now} />
        </div>

        <.groups_section
          :if={@group_sync != nil or @status.groups != [] or @group_error != nil or @group_msg != nil}
          groups={group_views(@status, @group_sync)}
          editable={@group_sync != nil}
          bulbs={@status.bulbs}
          slots={if(@group_sync, do: @group_sync.slots, else: %{})}
          form={@group_form}
          message={@group_msg}
          error={@group_error}
          myself={@myself}
        />

        <.settings_section
          :if={@status.bulbs != []}
          form={@settings_form}
          invert={@settings_params["invert"] == "true"}
          can_save={match?({:ok, _}, @settings_change)}
          message={@settings_msg}
          error={@settings_error}
          myself={@myself}
        />
      </.card>

      <.help />

      <.confirm_upload_modal
        :if={@pending && @pending.mode == :review}
        preview={@pending.preview}
        stale={@pending.stale}
        token={@pending.token}
        myself={@myself}
      />
      <.adopt_modal
        :if={@pending && @pending.mode == :adopt}
        preview={@pending.preview}
        token={@pending.token}
        myself={@myself}
      />
      <.clear_modal :if={@clearing} mode={@clearing} myself={@myself} />
      <.delete_group_modal :if={@deleting} group={@deleting} myself={@myself} />
    </div>
    """
  end

  # The editor's groups, or (Lights not answering) the status's, read-only.
  defp group_views(_status, %{groups: groups}), do: groups

  defp group_views(status, nil) do
    for g <- status.groups,
        do: %{
          local_id: g.local_id,
          name: g.name,
          members: g.members,
          holders: g.members,
          deleted: false,
          sync: %{}
        }
  end

  attr(:groups, :list, required: true)
  attr(:editable, :boolean, required: true)
  attr(:bulbs, :list, required: true)
  attr(:slots, :map, required: true)
  attr(:form, :map, default: nil)
  attr(:message, :string, default: nil)
  attr(:error, :string, default: nil)
  attr(:myself, :any, required: true)

  defp groups_section(assigns) do
    assigns =
      assigns
      |> assign(:live, Enum.reject(assigns.groups, & &1.deleted))
      |> assign(:leaving, Enum.filter(assigns.groups, & &1.deleted))
      |> assign(:labels, Map.new(assigns.bulbs, &{&1.mac, &1.label || &1.mac}))

    ~H"""
    <div id="tuya-mesh-groups" class="border-t border-border-2 p-[14px_22px]">
      <div class="flex items-center gap-2.5 mb-1.5">
        <%!-- Focus lands here when a dialog or form whose opener is gone
             closes (a deleted group takes its Delete button with it). --%>
        <div
          id="tuya-mesh-groups-title"
          tabindex="-1"
          class="text-[11px] text-fg-3 font-semibold flex-1 outline-none"
        >
          Groups
        </div>
        <.button
          :if={@editable and not match?(%{mode: :create}, @form)}
          size={:sm}
          phx-click="new_group"
          phx-target={@myself}
        >
          <.icon name={:plus} size={14} /> New group
        </.button>
      </div>
      <div :if={@editable} class="text-xs text-fg-3 mb-2.5">
        Creating, renaming or deleting a group briefly reconnects Home Assistant.
        Changing a group's members doesn't.
      </div>
      <div :if={not @editable} class="text-xs text-fg-3 mb-2.5">
        Groups can be edited while the mesh is running.
      </div>

      <div
        :if={@message}
        role="status"
        class="mb-2.5 p-[10px_12px] rounded-md bg-success-soft text-success text-xs font-medium flex items-start gap-2"
      >
        <.icon name={:check} size={14} stroke={2.0} class="mt-px flex-none" />
        <span class="flex-1">{@message}</span>
      </div>
      <div
        :if={@error}
        role="alert"
        class="mb-2.5 p-[10px_12px] rounded-md bg-warning-soft text-warning text-xs font-medium flex items-start gap-2"
      >
        <.icon name={:alert} size={14} stroke={2.0} class="mt-px flex-none" />
        <span class="flex-1">{@error}</span>
      </div>

      <.group_form
        :if={@editable and match?(%{mode: :create}, @form)}
        form={@form}
        bulbs={@bulbs}
        slots={@slots}
        holders={[]}
        myself={@myself}
      />

      <div class="flex flex-col">
        <div
          :for={group <- @live}
          id={"tuya-group-#{group.local_id}"}
          class="py-2 border-b border-border-2 last:border-b-0"
        >
          <div class="flex items-center gap-2.5 text-sm flex-wrap">
            <span class="font-semibold">{group_title(group)}</span>
            <span class="text-[11px] text-fg-3 font-mono">id {group.local_id}</span>
            <span class="text-xs text-fg-3">
              {length(group.members)} {pluralize(length(group.members), "bulb", "bulbs")}
            </span>
            <div :if={@editable} class="flex-1"></div>
            <div :if={@editable} class="flex items-center gap-2">
              <.button
                variant={:ghost}
                size={:sm}
                phx-click="edit_members"
                phx-value-gid={group.local_id}
                phx-target={@myself}
              >
                Edit members
              </.button>
              <.button
                variant={:ghost}
                size={:sm}
                phx-click="rename_group"
                phx-value-gid={group.local_id}
                phx-target={@myself}
              >
                <.icon name={:pencil} size={14} /> Rename
              </.button>
              <.button
                variant={:ghost}
                size={:sm}
                phx-click="ask_delete_group"
                phx-value-gid={group.local_id}
                phx-target={@myself}
              >
                <.icon name={:x} size={14} /> Delete
              </.button>
            </div>
          </div>
          <.member_states group={group} labels={@labels} editable={@editable} myself={@myself} />
          <.group_form
            :if={@editable and editing_group?(@form, group.local_id)}
            form={@form}
            bulbs={@bulbs}
            slots={@slots}
            holders={group.holders}
            myself={@myself}
          />
        </div>

        <div
          :for={group <- @leaving}
          id={"tuya-group-#{group.local_id}"}
          class="py-2 border-b border-border-2 last:border-b-0 text-fg-3"
        >
          <div class="flex items-center gap-2.5 text-sm flex-wrap">
            <span class="font-semibold">{group_title(group)}</span>
            <span class="text-[11px] font-mono">id {group.local_id}</span>
            <.badge>Leaving</.badge>
            <div class="flex-1"></div>
            <.button
              :if={@editable}
              variant={:ghost}
              size={:sm}
              phx-click="retry_removal"
              phx-value-gid={group.local_id}
              phx-target={@myself}
            >
              <.icon name={:refresh} size={14} /> Retry removal
            </.button>
          </div>
          <div class="text-xs mt-1">
            Not in the inventory any more. Still held by
            {Enum.map_join(group.holders, ", ", &Map.get(@labels, &1, &1))}.
          </div>
          <.member_states group={group} labels={@labels} editable={false} myself={@myself} />
        </div>
      </div>
    </div>
    """
  end

  attr(:group, :map, required: true)
  attr(:labels, :map, required: true)
  attr(:editable, :boolean, required: true)
  attr(:myself, :any, required: true)

  # Members, and bulbs with a change still tracked in the group; a finished
  # removal (confirmed, not a member) is no longer listed.
  defp member_states(assigns) do
    %{members: members, sync: sync} = assigns.group

    rows =
      (members ++ Map.keys(sync))
      |> Enum.uniq()
      |> Enum.reject(&(&1 not in members and match?(%{op: :remove, state: :confirmed}, sync[&1])))
      |> Enum.map(&%{mac: &1, label: Map.get(assigns.labels, &1, &1), sync: sync[&1]})
      |> Enum.sort_by(& &1.label)

    assigns = assign(assigns, :rows, rows)

    ~H"""
    <div :if={@rows != []} class="flex flex-col gap-1 mt-1.5">
      <div :for={row <- @rows} class="flex items-center gap-2 text-xs text-fg-2 flex-wrap">
        <span class="min-w-0 truncate">{row.label}</span>
        <.badge :if={row.sync} variant={sync_variant(row.sync)}>{sync_label(row.sync)}</.badge>
        <.button
          :if={@editable and match?(%{state: :unconfirmed}, row.sync)}
          variant={:ghost}
          size={:sm}
          phx-click="retry_member"
          phx-value-gid={@group.local_id}
          phx-value-mac={row.mac}
          phx-target={@myself}
        >
          <.icon name={:refresh} size={14} /> Retry
        </.button>
      </div>
    </div>
    """
  end

  defp sync_variant(%{state: :pending}), do: :accent
  defp sync_variant(%{state: :confirmed}), do: :success
  defp sync_variant(%{state: :unconfirmed}), do: :warning

  defp sync_label(%{op: :add, state: :pending}), do: "Joining…"
  defp sync_label(%{op: :add, state: :confirmed}), do: "Confirmed"
  defp sync_label(%{op: :add, state: :unconfirmed}), do: "Join unconfirmed"
  defp sync_label(%{op: :remove, state: :pending}), do: "Leaving…"
  defp sync_label(%{op: :remove, state: :confirmed}), do: "Left"
  defp sync_label(%{op: :remove, state: :unconfirmed}), do: "Leave unconfirmed"

  attr(:form, :map, required: true)
  attr(:bulbs, :list, required: true)
  attr(:slots, :map, required: true)
  # Bulbs that may already hold the group: they need no free slot. A ticked
  # bulb stays enabled even once full (a disabled box isn't submitted, so it
  # would drop silently); the backend then refuses it with its slot error.
  attr(:holders, :list, required: true)
  attr(:myself, :any, required: true)

  defp group_form(assigns) do
    assigns =
      assign(assigns,
        title: group_form_title(assigns.form.mode),
        named: assigns.form.mode in [:create, :rename],
        checklist: assigns.form.mode in [:create, :members],
        full: @group_slots
      )

    ~H"""
    <form
      id="tuya-group-form"
      phx-change="group_form_change"
      phx-submit="save_group_form"
      phx-target={@myself}
      class="mt-2.5 mb-2.5 p-[10px_12px] rounded-md bg-sunken"
    >
      <div class="text-sm font-semibold mb-1.5">{@title}</div>
      <.field :if={@named} label="Name" error={@form.name_error}>
        <.text_input
          name="group[name]"
          id="tuya-group-form-name"
          value={@form.name}
          aria-label="Group name"
          autocomplete="off"
          maxlength="64"
        />
      </.field>
      <fieldset :if={@checklist} class="flex flex-col gap-1.5 mt-2.5">
        <legend class="text-sm font-medium text-fg-2 mb-1.5">Bulbs</legend>
        <%!-- Submitted with nothing ticked too, so an empty list means "none". --%>
        <input type="hidden" name="group[members][]" value="" />
        <label
          :for={bulb <- @bulbs}
          class="flex items-center gap-2 text-sm cursor-pointer"
        >
          <input
            type="checkbox"
            name="group[members][]"
            value={bulb.mac}
            checked={bulb.mac in @form.selected}
            disabled={
              bulb.mac not in @form.selected and bulb.mac not in @holders and
                Map.get(@slots, bulb.mac, 0) >= @full
            }
            class="rounded-sm"
          />
          <span class="flex-1 min-w-0 truncate">{bulb.label || bulb.mac}</span>
          <span class="text-[11px] text-fg-3 font-mono">
            {Map.get(@slots, bulb.mac, 0)}/{@full}
          </span>
        </label>
        <div :if={@bulbs == []} class="text-xs text-fg-3">No bulbs in the mesh.</div>
        <div class="text-xs text-fg-3">
          A bulb holds at most {@full} groups; a full one can't be added.
        </div>
      </fieldset>
      <div
        :if={@form.error}
        role="alert"
        class="mt-2.5 p-[10px_12px] rounded-md bg-warning-soft text-warning text-xs font-medium flex items-start gap-2"
      >
        <.icon name={:alert} size={14} stroke={2.0} class="mt-px flex-none" />
        <span class="flex-1">{@form.error}</span>
      </div>
      <div class="flex items-center gap-2 mt-2.5">
        <.button type="submit" variant={:primary} size={:sm} phx-disable-with="Saving…">
          {if @form.mode == :create, do: "Create group", else: "Save"}
        </.button>
        <.button variant={:ghost} size={:sm} phx-click="cancel_group_form" phx-target={@myself}>
          Cancel
        </.button>
      </div>
    </form>
    """
  end

  # Imported groups may have no name (nil).
  defp group_title(group), do: group.name || "Group #{group.local_id}"

  defp trim_name(name) when is_binary(name), do: String.trim(name)
  defp trim_name(_none), do: nil

  defp editing_group?(%{gid: gid}, gid), do: true
  defp editing_group?(_form, _gid), do: false

  defp group_form_title(:create), do: "New group"
  defp group_form_title(:rename), do: "Rename group"
  defp group_form_title(:members), do: "Edit members"

  attr(:group, :map, required: true)
  attr(:myself, :any, required: true)

  defp delete_group_modal(assigns) do
    ~H"""
    <.modal
      open={true}
      on_close="cancel_delete_group"
      target={@myself}
      title={"Delete the group “#{@group.name}”?"}
      return_focus="#tuya-mesh-groups-title"
    >
      <:footer>
        <.button variant={:ghost} size={:sm} phx-click="cancel_delete_group" phx-target={@myself}>
          Cancel
        </.button>
        <.button
          variant={:danger}
          size={:sm}
          phx-click="confirm_delete_group"
          phx-target={@myself}
          phx-disable-with="Deleting…"
        >
          Delete group
        </.button>
      </:footer>
      <p class="text-sm text-fg-2 mt-0 mb-0">
        Its {@group.members} {pluralize(@group.members, "bulb", "bulbs")} are asked to leave it, and
        Home&nbsp;Assistant removes its light. Home&nbsp;Assistant reconnects briefly.
      </p>
    </.modal>
    """
  end

  attr(:form, Phoenix.HTML.Form, required: true)
  attr(:invert, :boolean, required: true)
  attr(:can_save, :boolean, required: true)
  attr(:message, :string, default: nil)
  attr(:error, :string, default: nil)
  attr(:myself, :any, required: true)

  defp settings_section(assigns) do
    ~H"""
    <.form
      for={@form}
      id="tuya-mesh-settings"
      phx-change="validate_settings"
      phx-submit="save_settings"
      phx-target={@myself}
      class="border-t border-border-2 p-[14px_22px]"
    >
      <div class="text-[11px] text-fg-3 font-semibold mb-1.5">Colour temperature</div>
      <div class="flex items-start gap-3 flex-wrap">
        <.field label="Warmest (K)" error={field_error(@form[:warm_k])} class="flex-1 min-w-0">
          <.text_input
            name={@form[:warm_k].name}
            id={@form[:warm_k].id}
            value={@form[:warm_k].value}
            aria-label="Warmest colour temperature in Kelvin"
            inputmode="numeric"
            autocomplete="off"
            maxlength="5"
          />
        </.field>
        <.field label="Coolest (K)" error={field_error(@form[:cool_k])} class="flex-1 min-w-0">
          <.text_input
            name={@form[:cool_k].name}
            id={@form[:cool_k].id}
            value={@form[:cool_k].value}
            aria-label="Coolest colour temperature in Kelvin"
            inputmode="numeric"
            autocomplete="off"
            maxlength="5"
          />
        </.field>
      </div>
      <div class="flex items-center gap-2.5 mt-2.5">
        <input type="hidden" name={@form[:invert].name} value={to_string(@invert)} />
        <.toggle
          checked={@invert}
          phx-click="toggle_invert"
          phx-target={@myself}
          aria-label="Invert the temperature scale"
        />
        <span class="text-sm">Invert</span>
        <span class="text-xs text-fg-3">
          Only for bulbs that show warm as cool. Leave off otherwise.
        </span>
      </div>
      <div class="text-xs text-fg-3 mt-2.5">
        Changing the range briefly reconnects Home Assistant so it re-reads it.
      </div>
      <div
        :if={@message}
        role="status"
        class="mt-2.5 p-[10px_12px] rounded-md bg-success-soft text-success text-xs font-medium flex items-start gap-2"
      >
        <.icon name={:check} size={14} stroke={2.0} class="mt-px flex-none" />
        <span class="flex-1">{@message}</span>
      </div>
      <div
        :if={@error}
        role="alert"
        class="mt-2.5 p-[10px_12px] rounded-md bg-warning-soft text-warning text-xs font-medium flex items-start gap-2"
      >
        <.icon name={:alert} size={14} stroke={2.0} class="mt-px flex-none" />
        <span class="flex-1">{@error}</span>
      </div>
      <div :if={@can_save} class="mt-2.5">
        <.button type="submit" variant={:primary} size={:sm} phx-disable-with="Saving…">
          Save
        </.button>
      </div>
    </.form>
    """
  end

  defp field_error(field) do
    case field.errors do
      [{msg, _opts} | _] -> msg
      [] -> nil
    end
  end

  attr(:bulb, :map, required: true)
  attr(:now, DateTime, required: true)

  defp bulb_row(assigns) do
    ~H"""
    <div class="flex items-center gap-3.5 p-[14px_22px] border-b border-border-2 last:border-b-0 flex-wrap">
      <div class="flex-1 min-w-0">
        <div class="text-sm font-semibold truncate">{@bulb.label || "Unnamed bulb"}</div>
        <div class="text-[11px] text-fg-3 mt-0.5 font-mono">
          {@bulb.mac} · node {@bulb.node_id}
        </div>
      </div>
      <span class="text-xs text-fg-3">{last_seen(@bulb.last_seen, @now)}</span>
      <.badge variant={presence_variant(@bulb)} dot>{presence_label(@bulb)}</.badge>
    </div>
    """
  end

  attr(:preview, :map, required: true)

  defp diff(assigns) do
    ~H"""
    <div class="mt-1.5 flex flex-col gap-1 font-normal">
      <div :if={no_changes?(@preview)}>No bulbs or groups were added or removed.</div>
      <div :for={bulb <- @preview.bulbs.added}>
        Bulb added: <strong>{bulb.label || "Unnamed bulb"}</strong>
        <span class="font-mono">{bulb.mac}</span>
      </div>
      <div :for={bulb <- @preview.bulbs.removed}>
        Bulb removed: <strong>{bulb.label || "Unnamed bulb"}</strong>
        <span class="font-mono">{bulb.mac}</span>
      </div>
      <div :for={group <- @preview.groups.added}>
        Group added: <strong>{group.name || "Group #{group.local_id}"}</strong>
        (id {group.local_id})
      </div>
      <div :for={group <- @preview.groups.removed}>
        Group removed: <strong>{group.name || "Group #{group.local_id}"}</strong>
        (id {group.local_id})
      </div>
    </div>
    """
  end

  defp help(assigns) do
    ~H"""
    <div class="mt-2.5 p-[10px_12px] rounded-md bg-sunken text-fg-2 text-xs flex items-start gap-2">
      <.icon name={:info} size={14} class="mt-px flex-none" />
      <div class="flex flex-col gap-1.5 leading-normal">
        <span>
          The <strong>dump</strong> is the JSON file describing your mesh: its
          <span class="font-mono">beaconKey</span>
          and <span class="font-mono">seq</span>, each bulb's MAC, <span class="font-mono">localKey</span>
          and <span class="font-mono">nodeId</span>, and the groups. It holds
          the mesh's secret keys. They are stored only on this device, in a
          file only the system can read (0600), and are never shown here.
        </span>
        <span>
          Using the Tuya or Smart Life app after uploading can move the bulbs'
          sequence counter past this device's, and they then ignore its
          commands. If control stops working, export and upload a fresh dump.
        </span>
        <span>
          The mesh radio is dedicated: the proxy, audio and Wi-Fi setup run on
          your other radios.
        </span>
      </div>
    </div>
    """
  end

  attr(:preview, :map, required: true)
  attr(:stale, :boolean, required: true)
  attr(:token, :string, required: true)
  attr(:myself, :any, required: true)

  defp confirm_upload_modal(assigns) do
    assigns = assign(assigns, :copy, confirm_copy(assigns.preview))

    ~H"""
    <%!-- On close, focus goes back to the file picker (the submit button
         that opened it is disabled by then). Each dialog's Cancel has its
         token in its id, so a stale re-ask mounts a new one and focus moves
         to it, off the destructive button the user just pressed. --%>
    <.modal
      open={true}
      on_close="cancel_upload"
      target={@myself}
      title={@copy.title}
      return_focus="#tuya-mesh-upload input[type=file]"
    >
      <:footer>
        <.button
          id={"tuya-mesh-upload-cancel-#{@token}"}
          variant={:ghost}
          size={:sm}
          phx-click="cancel_upload"
          phx-target={@myself}
          phx-mounted={JS.focus()}
        >
          Cancel
        </.button>
        <.button
          :if={adoptable?(@preview)}
          variant={:secondary}
          size={:sm}
          phx-click="ask_adopt"
          phx-value-token={@token}
          phx-target={@myself}
        >
          Adopt the dump's counter…
        </.button>
        <.button
          variant={if(destructive?(@preview), do: :danger, else: :primary)}
          size={:sm}
          phx-click="confirm_upload"
          phx-value-token={@token}
          phx-target={@myself}
          phx-disable-with="Uploading…"
        >
          {if adoptable?(@preview), do: "#{@copy.action}, keep the device's counter", else: @copy.action}
        </.button>
      </:footer>
      <div
        :if={@stale}
        role="alert"
        class="mb-3 p-[10px_12px] rounded-md bg-warning-soft text-warning text-xs font-medium flex items-start gap-2"
      >
        <.icon name={:alert} size={14} stroke={2.0} class="mt-px flex-none" />
        <span>
          The stored inventory changed since you chose this file. Review the
          updated changes below.
        </span>
      </div>
      <div
        :if={adoptable?(@preview)}
        role="alert"
        class="mb-3 p-[10px_12px] rounded-md bg-warning-soft text-warning text-xs font-medium flex items-start gap-2"
      >
        <.icon name={:alert} size={14} stroke={2.0} class="mt-px flex-none" />
        <span>
          This dump's sequence counter ({@preview.seq.dump}) is far ahead of the
          device's ({@preview.seq.local}). If you've used the Tuya or Smart Life app
          since the last upload, adopt the dump's counter; otherwise keep the
          device's.
        </span>
      </div>
      <p class="text-sm text-fg-2 mt-0 mb-3">
        {@copy.body}
        <span :if={@preview.bulbs.removed != []}>
          Home&nbsp;Assistant drops the entities of the bulbs removed below, and
          their history with them.
        </span>
      </p>
      <div class="p-[10px_12px] rounded-md bg-sunken text-fg-2 text-xs">
        <.diff preview={@preview} />
      </div>
    </.modal>
    """
  end

  attr(:preview, :map, required: true)
  attr(:token, :string, required: true)
  attr(:myself, :any, required: true)

  defp adopt_modal(assigns) do
    ~H"""
    <%!-- Replaces the review dialog: its Cancel (token in its id) takes
         focus, off the button just pressed. --%>
    <.modal
      open={true}
      on_close="cancel_upload"
      target={@myself}
      title="Adopt the dump's counter?"
      return_focus="#tuya-mesh-upload input[type=file]"
    >
      <:footer>
        <.button
          id={"tuya-mesh-adopt-cancel-#{@token}"}
          variant={:ghost}
          size={:sm}
          phx-click="cancel_upload"
          phx-target={@myself}
          phx-mounted={JS.focus()}
        >
          Cancel
        </.button>
        <.button
          variant={:danger}
          size={:sm}
          phx-click="confirm_adopt"
          phx-value-token={@token}
          phx-target={@myself}
          phx-disable-with="Uploading…"
        >
          Adopt counter and upload
        </.button>
      </:footer>
      <div
        role="alert"
        class="mb-3 p-[10px_12px] rounded-md bg-warning-soft text-warning text-xs font-medium flex items-start gap-2"
      >
        <.icon name={:alert} size={14} stroke={2.0} class="mt-px flex-none" />
        <span>
          Only adopt it if this dump was exported after you last used the Tuya or
          Smart Life app. If it is older than that, the bulbs will ignore this
          device until you upload, and adopt, a fresh dump.
        </span>
      </div>
      <p class="text-sm text-fg-2 mt-0 mb-3">
        This sets the device's sequence counter to {@preview.seq.dump}, the
        dump's, instead of keeping {@preview.seq.local}.
        <span :if={@preview.mesh == :new_mesh}>
          It also replaces every bulb and group of the stored mesh.
        </span>
        <span :if={@preview.bulbs.removed != []}>
          Home&nbsp;Assistant drops the entities of the bulbs removed below, and
          their history with them.
        </span>
      </p>
      <div class="p-[10px_12px] rounded-md bg-sunken text-fg-2 text-xs">
        <.diff preview={@preview} />
      </div>
    </.modal>
    """
  end

  defp destructive?(preview), do: preview.mesh == :new_mesh or preview.bulbs.removed != []

  defp confirm_copy(%{mesh: :new_mesh}) do
    %{
      title: "Replace the stored mesh?",
      action: "Replace mesh",
      body:
        "This dump is for a different mesh than the one stored. " <>
          "Uploading it replaces every bulb and group."
    }
  end

  defp confirm_copy(%{bulbs: %{removed: [_ | _] = removed}}) do
    n = length(removed)
    bulbs = pluralize(n, "bulb", "bulbs")

    %{
      title: "Remove #{n} #{bulbs}?",
      action: "Upload and remove",
      body: "This dump is for the stored mesh but leaves out #{n} #{bulbs}."
    }
  end

  # Only after a stale confirmation: the fresh diff removes nothing.
  defp confirm_copy(%{mesh: :empty}) do
    %{
      title: "Upload this dump?",
      action: "Upload",
      body: "The stored inventory was cleared, so this dump will be stored as a new mesh."
    }
  end

  defp confirm_copy(_preview) do
    %{
      title: "Upload this dump?",
      action: "Upload",
      body: "This dump is for the stored mesh and removes no bulbs."
    }
  end

  attr(:mode, :atom, required: true)
  attr(:myself, :any, required: true)

  defp clear_modal(%{mode: :force} = assigns) do
    ~H"""
    <.modal
      open={true}
      on_close="cancel_clear"
      target={@myself}
      title="The stored inventory can't be read"
    >
      <:footer>
        <%!-- Its own Cancel, focused when this replaces the first dialog
             (focus would otherwise stay on the button just pressed, now
             "Clear anyway"). --%>
        <.button
          id="tuya-mesh-force-clear-cancel"
          variant={:ghost}
          size={:sm}
          phx-click="cancel_clear"
          phx-target={@myself}
          phx-mounted={JS.focus()}
        >
          Cancel
        </.button>
        <.button
          variant={:danger}
          size={:sm}
          phx-click="confirm_force_clear"
          phx-target={@myself}
          phx-disable-with="Clearing…"
        >
          Clear anyway (sequence will be lost)
        </.button>
      </:footer>
      <p class="text-sm text-fg-2 mt-0 mb-0">
        Its sequence counter can't be recovered either. If you clear it anyway and
        later upload a dump of the same mesh, the bulbs may ignore commands until
        you upload a fresh dump exported after this one.
      </p>
    </.modal>
    """
  end

  defp clear_modal(assigns) do
    ~H"""
    <.modal open={true} on_close="cancel_clear" target={@myself} title="Clear the Tuya mesh inventory?">
      <:footer>
        <.button variant={:ghost} size={:sm} phx-click="cancel_clear" phx-target={@myself}>
          Cancel
        </.button>
        <.button
          variant={:danger}
          size={:sm}
          phx-click="confirm_clear"
          phx-target={@myself}
          phx-disable-with="Clearing…"
        >
          Clear inventory
        </.button>
      </:footer>
      <p class="text-sm text-fg-2 mt-0 mb-0">
        This stops the mesh and deletes the stored dump, keys included. The bulbs
        can't be controlled from here until you upload a dump again.
      </p>
    </.modal>
    """
  end

  # ── Display helpers ─────────────────────────────────────────────────────

  defp state_view(%{state: :running} = status) do
    hint = "Running on hci#{status.adapter_index}."

    case status.radio do
      %{ready: true} -> %{label: "Running", variant: :success, hint: hint}
      _ -> %{label: "Radio not ready", variant: :warning, hint: hint}
    end
  end

  defp state_view(%{reason: :no_inventory}),
    do: %{label: "Not set up", variant: :neutral, hint: idle_hint(:no_inventory)}

  defp state_view(%{reason: reason}),
    do: %{label: "Idle", variant: :warning, hint: idle_hint(reason)}

  # Offered whenever a record may be stored, readable or not: offline (no
  # Resolver) an unreadable record lists nothing, and the forced clear is
  # the way out. Clearing an empty store is a no-op.
  defp clearable?(%{bulbs: bulbs, groups: groups, reason: reason}),
    do:
      bulbs != [] or groups != [] or
        reason in [:not_running, :invalid_inventory, :store_unavailable]

  defp idle_hint(:no_role), do: "No radio holds the Tuya mesh role."
  defp idle_hint(:no_inventory), do: "Upload your mesh's JSON dump to start."

  defp idle_hint(:invalid_inventory),
    do: "The stored inventory can't be read. Upload a fresh dump, or clear it."

  defp idle_hint(:store_unavailable), do: "The inventory store isn't available."

  defp idle_hint(:adapter_missing),
    do: "Mesh dongle not found. Plug in the radio assigned to the Tuya mesh."

  defp idle_hint(:lone_radio),
    do: "The mesh radio is the only one present. Plug in a second radio for the proxy."

  defp idle_hint(:start_failed), do: "The mesh failed to start. Retrying."
  defp idle_hint(:mesh_exited), do: "The mesh stopped unexpectedly. Restarting shortly."
  defp idle_hint(:not_running), do: "The mesh service isn't running."
  defp idle_hint(_reason), do: "The mesh isn't running."

  defp radio_line(%{ready: true}), do: "Radio ready."
  defp radio_line(%{last_error: nil}), do: "Radio starting up."
  defp radio_line(%{last_error: reason}), do: "Radio not ready: #{radio_error(reason)}."

  defp radio_error(:timeout), do: "the radio didn't answer"
  defp radio_error(reason) when is_atom(reason), do: humanize(reason)

  defp radio_error(reason) when is_tuple(reason) and is_atom(elem(reason, 0)),
    do: humanize(elem(reason, 0))

  defp radio_error(_reason), do: "unknown error"

  defp humanize(atom), do: atom |> Atom.to_string() |> String.replace("_", " ")

  # "Checking" while the pinger hasn't concluded: a bulb is "Not reachable"
  # only once it missed enough pings in a row (see the Resolver).
  defp presence_variant(%{reachable: true}), do: :success
  defp presence_variant(%{checking: true}), do: :accent
  defp presence_variant(_bulb), do: :neutral

  defp presence_label(%{reachable: true}), do: "Reachable"
  defp presence_label(%{checking: true}), do: "Checking…"
  defp presence_label(_bulb), do: "Not reachable"

  defp last_seen(nil, _now), do: "Never seen"

  defp last_seen(%DateTime{} = at, now) do
    # Clamped: the clock can step back after an NTP sync.
    seconds = max(DateTime.diff(now, at, :second), 0)

    cond do
      seconds < 10 -> "Seen just now"
      seconds < 60 -> "Seen #{seconds} s ago"
      seconds < 3_600 -> "Seen #{div(seconds, 60)} min ago"
      seconds < 86_400 -> "Seen #{div(seconds, 3_600)} h ago"
      true -> "Seen #{div(seconds, 86_400)} d ago"
    end
  end

  defp uploaded_title(:empty), do: "Inventory uploaded."
  defp uploaded_title(:same_mesh), do: "Inventory updated (same mesh)."
  defp uploaded_title(:new_mesh), do: "New mesh uploaded."

  defp no_changes?(%{bulbs: bulbs, groups: groups}),
    do: bulbs.added == [] and bulbs.removed == [] and groups.added == [] and groups.removed == []

  defp pluralize(1, singular, _plural), do: singular
  defp pluralize(_n, _singular, plural), do: plural

  # ── Error text ──────────────────────────────────────────────────────────
  # Every reason here is key-free (see the moduledoc); MACs are validated,
  # normalised values.

  # upload_errors/1,2
  defp upload_error(:too_large), do: "That file is larger than 64 KB, too big for a mesh dump."
  defp upload_error(:not_accepted), do: "Choose a .json file (the mesh's JSON dump)."
  defp upload_error(:too_many_files), do: "Choose one file at a time."
  defp upload_error(:external_client_failure), do: "The upload failed. Try again."

  # TuyaMesh.preview/1 and upload/2
  defp upload_error({:invalid_inventory, reason}),
    do: "That file isn't a usable mesh dump: " <> inventory_error(reason)

  defp upload_error({:seq_not_ahead, %{local: local}}),
    do:
      "The dump's sequence counter is no longer ahead of the device's (#{local}). " <>
        "Nothing was changed."

  defp upload_error(reason), do: change_error(reason)

  defp change_error(:unavailable),
    do: "The Tuya mesh service isn't available right now. Try again shortly."

  defp change_error(:invalid_settings),
    do:
      "That doesn't fit the colour temperature stored now (it may have changed in another tab). " <>
        "Check the values and save again."

  defp change_error(:timeout),
    do:
      "The mesh didn't answer in time. The change may still have been applied: check the status before retrying."

  defp change_error(_reason), do: "That didn't work. Try again."

  # TuyaMesh's group operations.
  defp group_error({:group_slots_full, mac}, socket),
    do:
      "#{bulb_label(socket, mac)} already belongs to #{@group_slots} groups, the most a bulb can hold."

  defp group_error(:bad_group_name, _socket), do: "Enter a name of 1 to 64 characters."
  defp group_error(:duplicate_group_name, _socket), do: "Another group already has that name."

  defp group_error(:no_free_group_id, _socket),
    do: "Every group id is in use. Delete a group first."

  defp group_error(:not_running, _socket),
    do: "The mesh isn't running, so groups can't be changed right now."

  defp group_error(:persist_failed, _socket),
    do: "The change couldn't be saved on this device, so it wasn't made."

  defp group_error(:unknown_group, _socket), do: "That group no longer exists."

  defp group_error(:stale_group, _socket),
    do: "That group was deleted or replaced in the meantime. Nothing was sent."

  defp group_error(:unknown_bulb, _socket), do: "That bulb is no longer in the mesh."
  defp group_error(:not_member, _socket), do: "That bulb isn't in the group any more."
  defp group_error(reason, _socket), do: change_error(reason)

  defp inventory_error(:too_large), do: "it is larger than 64 KB."
  defp inventory_error({:invalid_json, pos}), do: "it isn't valid JSON (error at byte #{pos})."

  defp inventory_error(:not_a_map),
    do: "it must be a JSON object with beaconKey, seq and bulbs."

  defp inventory_error(:missing_beacon_key), do: "it has no mesh beaconKey."

  defp inventory_error(:bad_beacon_key),
    do: "the mesh beaconKey isn't a valid key (32 hex digits or 16 characters)."

  defp inventory_error(:bad_seq), do: "seq must be a whole number from 0 to 65535."
  defp inventory_error(:no_bulbs), do: "it lists no bulbs."
  defp inventory_error(:bad_bulbs), do: "bulbs must be a list."
  defp inventory_error(:bad_bulb), do: "a bulb entry isn't an object."
  defp inventory_error(:bad_mac), do: "a bulb has a missing or invalid MAC address."
  defp inventory_error({:duplicate_mac, mac}), do: "bulb #{mac} is listed twice."

  defp inventory_error({:duplicate_node_id, node_id, mac}),
    do: "node id #{node_id} is used by more than one bulb (again by #{mac})."

  defp inventory_error({:duplicate_label, mac}),
    do: "bulb #{mac} has the same label as another bulb."

  defp inventory_error({:label_is_other_mac, mac}),
    do: "bulb #{mac}'s label is another bulb's MAC address."

  defp inventory_error({:bad_label, mac}), do: "bulb #{mac}'s label isn't text."
  defp inventory_error({:missing_local_key, mac}), do: "bulb #{mac} has no localKey."

  defp inventory_error({:bad_local_key, mac}),
    do: "bulb #{mac}'s localKey isn't a valid key (32 hex digits or 16 characters)."

  defp inventory_error({:bad_bulb_beacon_key, mac}),
    do: "bulb #{mac}'s beaconKey isn't a valid key (32 hex digits or 16 characters)."

  defp inventory_error({:missing_node_id, mac}), do: "bulb #{mac} has no nodeId."

  defp inventory_error({:bad_node_id, mac}),
    do: "bulb #{mac}'s nodeId must be a whole number from 0 to 32767."

  defp inventory_error(:bad_groups), do: "groups must be a list."

  defp inventory_error(:bad_group),
    do: "a group entry is malformed (it needs a localId from 0 to 254 and a members list)."

  defp inventory_error({:bad_group_name, id}), do: "group #{id}'s name isn't text."
  defp inventory_error({:duplicate_group_id, id}), do: "group id #{id} is listed twice."

  defp inventory_error({:duplicate_group_name, id}),
    do: "group #{id} has the same name as another group."

  defp inventory_error({:unknown_group_member, id, mac}),
    do: "group #{id} lists #{mac}, which isn't one of the bulbs."

  defp inventory_error({:bad_group_member, id, index}),
    do: "group #{id}'s member #{index + 1} isn't a MAC address."

  defp inventory_error(_reason), do: "it doesn't match the expected format."
end
