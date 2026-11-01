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

  Between the preview and the confirm (or cancel) the dump sits in this
  component's `:pending` assign, sealed in a closure
  (`UniversalProxy.TuyaMesh.Redact.seal/1`) so a crash report or an
  inspected socket prints it as an opaque function. It is never rendered,
  and is dropped on confirm, cancel, success and failure.

  Errors are rendered from their reasons, which carry no key material
  (`Inventory.decode/1` names entries by MAC, node id, group id or
  position only). Nothing here logs or inspects the dump.

  ## Status

  The parent subscribes to `TuyaMesh.topic/0` (a LiveComponent can't) and
  forwards each `{:tuya_mesh_status, status}` here with
  `send_update(__MODULE__, id: id, status: status)`; `update/2` takes such
  an update as the new status. The first status is read in `mount/1`.
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
     # `nil`, or `%{inventory: sealed_json, preview: preview}` while a new
     # mesh awaits confirmation.
     |> assign(:pending, nil)
     # `nil`, `:confirm`, or `:force` (the stored record's seq is lost).
     |> assign(:clearing, nil)
     # Result of the last action: `%{title:, preview:}` or `%{title:}`.
     |> assign(:notice, nil)
     |> assign(:error, nil)
     |> allow_upload(:inventory,
       accept: ~w(.json),
       max_entries: 1,
       max_file_size: @max_file_size
     )}
  end

  @impl true
  def update(%{status: status}, socket), do: {:ok, assign(socket, :status, status)}
  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  # ── Upload ──────────────────────────────────────────────────────────────

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_entry", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :inventory, ref)}

  def handle_event("upload", _params, socket) do
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

  def handle_event("confirm_upload", _params, %{assigns: %{pending: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("confirm_upload", _params, socket) do
    %{inventory: sealed, preview: preview} = socket.assigns.pending
    socket = assign(socket, :pending, nil)
    opts = if preview.mesh == :new_mesh, do: [confirm: true], else: []
    {:noreply, upload(socket, Redact.unseal(sealed), preview, opts)}
  end

  def handle_event("cancel_upload", _params, socket),
    do: {:noreply, assign(socket, :pending, nil)}

  # ── Clear ───────────────────────────────────────────────────────────────

  def handle_event("ask_clear", _params, socket),
    do: {:noreply, assign(socket, clearing: :confirm, notice: nil, error: nil)}

  def handle_event("cancel_clear", _params, socket),
    do: {:noreply, assign(socket, :clearing, nil)}

  def handle_event("confirm_clear", _params, %{assigns: %{clearing: :confirm}} = socket),
    do: {:noreply, clear(socket, [])}

  def handle_event("confirm_force_clear", _params, %{assigns: %{clearing: :force}} = socket),
    do: {:noreply, clear(socket, force: true)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # ── Actions ─────────────────────────────────────────────────────────────

  defp preview_upload(socket, json) do
    case TuyaMesh.preview(json) do
      {:ok, preview} ->
        if needs_confirm?(preview),
          do: await_confirm(socket, json, preview),
          else: upload(socket, json, preview, [])

      {:error, reason} ->
        assign(socket, :error, upload_error(reason))
    end
  end

  defp upload(socket, json, preview, opts) do
    case TuyaMesh.upload(json, opts) do
      {:ok, _kind} ->
        socket
        |> assign(:notice, %{title: uploaded_title(preview.mesh), preview: preview})
        |> assign(:status, TuyaMesh.status())

      # Another mesh was stored since the preview: confirm against it.
      {:error, {:confirm_new_mesh, preview}} ->
        await_confirm(socket, json, preview)

      {:error, reason} ->
        assign(socket, :error, upload_error(reason))
    end
  end

  # A new mesh replaces everything; a removed bulb loses its HA entities.
  defp needs_confirm?(%{mesh: :new_mesh}), do: true
  defp needs_confirm?(%{bulbs: %{removed: removed}}), do: removed != []

  defp await_confirm(socket, json, preview),
    do: assign(socket, :pending, %{inventory: Redact.seal(json), preview: preview})

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
    assigns =
      assigns
      |> assign(:view, state_view(assigns.status))
      |> assign(:now, DateTime.utc_now())

    ~H"""
    <div id={@id} class="mt-7">
      <div class="flex items-center gap-3 mb-2.5">
        <.eyebrow class="whitespace-nowrap">
          Tuya mesh{if @status.bulbs != [], do: " · #{length(@status.bulbs)}", else: ""}
        </.eyebrow>
        <div class="flex-1"></div>
        <.button
          :if={@status.bulbs != [] or @status.reason == :invalid_inventory}
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
          class="px-[22px] pb-[18px]"
        >
          <div class="flex items-center gap-3 flex-wrap">
            <.live_file_input upload={@uploads.inventory} class="flex-1 min-w-0 text-sm text-fg-2" />
            <.button
              type="submit"
              variant={:primary}
              size={:sm}
              disabled={@uploads.inventory.entries == []}
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

        <div :if={@status.groups != []} class="border-t border-border-2 p-[14px_22px]">
          <div class="text-[11px] text-fg-3 font-semibold mb-1.5">Groups</div>
          <div class="flex flex-col gap-1.5">
            <div :for={group <- @status.groups} class="flex items-center gap-2.5 text-sm flex-wrap">
              <span class="font-semibold">{group.name || "Group #{group.local_id}"}</span>
              <span class="text-[11px] text-fg-3 font-mono">id {group.local_id}</span>
              <span class="text-xs text-fg-3">
                {length(group.members)} {pluralize(length(group.members), "bulb", "bulbs")}
              </span>
            </div>
          </div>
        </div>
      </.card>

      <.help />

      <.confirm_upload_modal :if={@pending} preview={@pending.preview} myself={@myself} />
      <.clear_modal :if={@clearing} mode={@clearing} myself={@myself} />
    </div>
    """
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
      <.badge variant={if(@bulb.reachable, do: :success, else: :neutral)} dot>
        {if @bulb.reachable, do: "Reachable", else: "Not reachable"}
      </.badge>
    </div>
    """
  end

  attr(:preview, :map, required: true)

  defp diff(assigns) do
    ~H"""
    <div class="mt-1.5 flex flex-col gap-1 font-normal">
      <div :if={no_changes?(@preview)}>No bulbs or groups changed.</div>
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
  attr(:myself, :any, required: true)

  defp confirm_upload_modal(%{preview: %{mesh: :new_mesh}} = assigns) do
    ~H"""
    <.modal open={true} on_close="cancel_upload" target={@myself} title="Replace the stored mesh?">
      <:footer>
        <.button variant={:ghost} size={:sm} phx-click="cancel_upload" phx-target={@myself}>
          Cancel
        </.button>
        <.button variant={:danger} size={:sm} phx-click="confirm_upload" phx-target={@myself}>
          Replace mesh
        </.button>
      </:footer>
      <p class="text-sm text-fg-2 mt-0 mb-3">
        This dump is for a <strong>different mesh</strong> than the one stored.
        Uploading it replaces every bulb and group. Home&nbsp;Assistant drops the
        entities of the bulbs removed below, and their history with them.
      </p>
      <div class="p-[10px_12px] rounded-md bg-sunken text-fg-2 text-xs">
        <.diff preview={@preview} />
      </div>
    </.modal>
    """
  end

  defp confirm_upload_modal(assigns) do
    assigns = assign(assigns, :removed, length(assigns.preview.bulbs.removed))

    ~H"""
    <.modal
      open={true}
      on_close="cancel_upload"
      target={@myself}
      title={"Remove #{@removed} #{pluralize(@removed, "bulb", "bulbs")}?"}
    >
      <:footer>
        <.button variant={:ghost} size={:sm} phx-click="cancel_upload" phx-target={@myself}>
          Cancel
        </.button>
        <.button variant={:danger} size={:sm} phx-click="confirm_upload" phx-target={@myself}>
          Upload and remove
        </.button>
      </:footer>
      <p class="text-sm text-fg-2 mt-0 mb-3">
        This dump is for the stored mesh but leaves out
        <strong>{@removed} {pluralize(@removed, "bulb", "bulbs")}</strong>.
        Home&nbsp;Assistant drops the entities of the bulbs removed below, and
        their history with them.
      </p>
      <div class="p-[10px_12px] rounded-md bg-sunken text-fg-2 text-xs">
        <.diff preview={@preview} />
      </div>
    </.modal>
    """
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
        <.button variant={:ghost} size={:sm} phx-click="cancel_clear" phx-target={@myself}>
          Cancel
        </.button>
        <.button variant={:danger} size={:sm} phx-click="confirm_force_clear" phx-target={@myself}>
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
        <.button variant={:danger} size={:sm} phx-click="confirm_clear" phx-target={@myself}>
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

  defp upload_error(reason), do: change_error(reason)

  defp change_error(:unavailable),
    do: "The Tuya mesh service isn't available right now. Try again shortly."

  defp change_error(:timeout),
    do:
      "The mesh didn't answer in time. The change may still have been applied: check the status before retrying."

  defp change_error(_reason), do: "That didn't work. Try again."

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
