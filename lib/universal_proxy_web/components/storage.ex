defmodule UniversalProxyWeb.Components.Storage do
  @moduledoc """
  USB backup-drive rendering for the Overview tab: the hardware-table
  peripheral row, the drive drawer (identity, filesystem/capacity, the SMB
  share section and the confirm-gated danger zone), and the folder-chooser
  modal.

  Everything here is a pure function of the state map broadcast on
  `UniversalProxy.Storage.topic/0` — no component calls the subsystem.
  `OverviewLive` owns the `UniversalProxy.Storage` façade calls (and the
  assigns they produce), which keeps the password out of this module
  entirely except as an already-revealed string it is handed to render.
  """

  use Phoenix.Component

  import UniversalProxyWeb.Components.Icons
  import UniversalProxyWeb.Components.UI

  # The share name `Storage.Smbd` writes into smb.conf. Mirrored here for
  # the UNC readout only; the daemon remains the source of truth.
  @share_name "usb_backup"

  @root_folder "/"

  # Decimal GB, as drive vendors (and the design) label capacity.
  @gb 1_000_000_000

  # ── Row maps ──────────────────────────────────────────────────────────

  @doc """
  Peripheral-row maps for the attached drives, in the order the state map
  lists them.

  Only the first drive is ever mounted or shared, and `Storage.Server`
  guarantees that position holds the *active* drive — the mounted one for
  as long as a mount lasts, so a drive attached later cannot take over the
  primary row (see that module's "The active drive is position 0"). Drives
  past the first render as plain unmounted rows and their drawer controls
  are disabled.

  `ejected_device` is the device path the user safely ejected, which the
  state map cannot express on its own (an ejected drive and a drive whose
  filesystem could not be mounted are both simply "attached, not mounted").
  """
  @spec drive_peripherals(map(), String.t() | nil) :: [map()]
  def drive_peripherals(%{drives: drives} = storage, ejected_device) when is_list(drives) do
    drives
    |> Enum.with_index()
    |> Enum.map(fn {drive, index} ->
      drive_row(drive, storage, drive.dev_path == ejected_device, index == 0)
    end)
  end

  def drive_peripherals(_storage, _ejected_device), do: []

  defp drive_row(drive, storage, ejected?, first?) do
    shared? = first? and not ejected? and storage.share == :running

    %{
      kind: :drive,
      type_label: "USB storage",
      # Reconcile in `OverviewLive.hardware_rows/3` promotes the drive into
      # the declared "USB N" slot its bus path occupies; a drive with no
      # derivable bus path keeps this label and trails.
      slot: "USB storage",
      slot_sub: drive.slot_sub,
      name: drive_display_name(drive),
      detail: drive_detail(drive),
      sub: drive.slot_sub || drive.dev_path,
      managed_by: if(shared?, do: "Home Assistant backups", else: "Not shared"),
      managed_accent?: shared?,
      # Storage rows open the drive drawer rather than routing to a tab.
      tab: nil,
      status: drive_status(drive, storage, ejected?, first?),
      soft_class: "bg-sunken text-fg-2",
      dot_class: "bg-fg-3",
      fma120?: false,
      fma120_key: nil,
      btd700?: false,
      btd700_key: nil,
      storage?: true,
      device: drive.dev_path
    }
  end

  @doc """
  The row/drawer status badge for a drive.

  `Stale` (a mount the kernel is still detaching) outranks everything: the
  mount point cannot be trusted while it is set. A share error is next,
  since it is the one state a user has to act on.
  """
  @spec drive_status(map(), map(), boolean(), boolean()) :: %{label: String.t(), variant: atom()}
  def drive_status(drive, storage, ejected?, first?) do
    mount = if first?, do: mount_for(storage, drive), else: nil

    cond do
      match?(%{stale?: true}, mount) -> %{label: "Stale", variant: :danger}
      is_nil(mount) or ejected? -> %{label: "Unmounted", variant: :neutral}
      storage.share == :error -> %{label: "Share error", variant: :danger}
      storage.share == :running -> %{label: "Shared", variant: :success}
      mount.mode == :read_only -> %{label: "Read-only", variant: :warning}
      true -> %{label: "Mounted", variant: :neutral}
    end
  end

  @doc """
  The mount belonging to `drive`, or `nil`.

  `mount.device` is the mounted *partition* (`/dev/sda1`), or the whole
  disk when it carries the filesystem directly. Matching on a bare prefix
  would make `/dev/sda`'s mount look like `/dev/sdaa`'s, so the suffix has
  to be a partition number.
  """
  @spec mount_for(map(), map()) :: map() | nil
  def mount_for(%{mount: %{device: device} = mount}, %{dev_path: dev_path}) do
    if device == dev_path or Regex.match?(~r/^#{Regex.escape(dev_path)}p?\d+$/, device),
      do: mount
  end

  def mount_for(_storage, _drive), do: nil

  # `Storage.Probe` reads capacity and identity out of sysfs block
  # attributes, which carry no vendor/model strings — so the row is named
  # generically and identified by its USB ids and bus path.
  @doc false
  def drive_display_name(_drive), do: "USB drive"

  defp drive_detail(drive) do
    [vidpid(drive), size_label(drive)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  @doc "`VID:PID` of the drive's USB bridge, uppercase hex, or `nil`."
  @spec vidpid(map()) :: String.t() | nil
  def vidpid(%{vendor_id: vid, product_id: pid}) when is_integer(vid) and is_integer(pid) do
    "#{hex4(vid)}:#{hex4(pid)}"
  end

  def vidpid(_drive), do: nil

  defp hex4(id), do: id |> Integer.to_string(16) |> String.upcase() |> String.pad_leading(4, "0")

  @doc "Decimal-GB size label (`\"931 GB\"`), or `nil` when unknown."
  @spec size_label(map()) :: String.t() | nil
  def size_label(%{size_bytes: bytes}) when is_integer(bytes) and bytes > 0,
    do: "#{gb(bytes)} GB"

  def size_label(_drive), do: nil

  # One decimal below 100 GB, whole numbers above — the design's fmtGB.
  defp gb(bytes) do
    value = bytes / @gb

    if value >= 100,
      do: Float.round(value) |> trunc() |> Integer.to_string(),
      else: :erlang.float_to_binary(value, decimals: 1)
  end

  @doc """
  Filesystem badge label + variant.

  A non-journalled filesystem is a `warning`: it works, but a backup
  target that can be left inconsistent by a power cut is worth flagging.
  `nil` is "not sniffed" (drives past the first), distinct from `:unknown`.
  """
  @spec fs_badge(atom()) :: %{label: String.t(), variant: atom(), journalled?: boolean()}
  def fs_badge(:ext4), do: %{label: "ext4", variant: :success, journalled?: true}
  def fs_badge(:exfat), do: %{label: "exFAT", variant: :warning, journalled?: false}
  def fs_badge(:ntfs3), do: %{label: "NTFS", variant: :warning, journalled?: false}
  def fs_badge(:vfat), do: %{label: "FAT", variant: :warning, journalled?: false}
  def fs_badge(:unknown), do: %{label: "Unrecognised", variant: :neutral, journalled?: true}
  def fs_badge(_not_sniffed), do: %{label: "Not checked", variant: :neutral, journalled?: true}

  @doc "The UNC path Home Assistant points at, from the advertised hostname."
  @spec unc_path(String.t() | nil) :: String.t()
  def unc_path(host) when is_binary(host) and host != "", do: "\\\\#{host}\\#{@share_name}"
  def unc_path(_host), do: "\\\\universal-proxy\\#{@share_name}"

  @doc "The folder mapping as shown to the user (`\"/\"` reads as the drive root)."
  @spec folder_label(String.t() | nil) :: String.t()
  def folder_label(folder) when folder in [nil, "", @root_folder], do: "/ (drive root)"
  def folder_label(folder), do: folder

  # ── Drive drawer ──────────────────────────────────────────────────────

  attr(:drive, :map, required: true)
  attr(:storage, :map, required: true)
  attr(:slot, :string, required: true)
  attr(:host, :string, default: nil)
  attr(:supported?, :boolean, default: false)
  attr(:username, :string, default: nil)
  attr(:credentials?, :boolean, default: true)
  attr(:password, :string, default: nil)
  attr(:copied?, :boolean, default: false)
  attr(:armed, :atom, default: nil)
  attr(:formatting?, :boolean, default: false)
  attr(:ejected?, :boolean, default: false)
  attr(:first?, :boolean, default: true)
  attr(:chooser, :map, default: nil)

  def storage_drawer(assigns) do
    mount = if assigns.first?, do: mount_for(assigns.storage, assigns.drive), else: nil

    assigns =
      assigns
      |> assign(:mount, mount)
      |> assign(:name, drive_display_name(assigns.drive))
      |> assign(
        :status,
        drive_status(assigns.drive, assigns.storage, assigns.ejected?, assigns.first?)
      )
      |> assign(:fs, fs_badge((mount && mount.fs_type) || assigns.drive[:fs_type]))
      |> assign(:shared?, assigns.first? and assigns.storage.share == :running)

    ~H"""
    <div class="fixed inset-0 z-[90] flex justify-end animate-fade">
      <div phx-click="close_drive_drawer" class="absolute inset-0 bg-overlay"></div>
      <div class="relative w-[440px] bg-raised h-full shadow-lg overflow-auto animate-slide-in flex flex-col">
        <%!-- Header --%>
        <div class="px-6 py-5 border-b border-border-1 flex items-start gap-3">
          <div class="w-10 h-10 rounded-md bg-sunken text-fg-2 flex items-center justify-center flex-none">
            <.icon name={:drive} size={22} />
          </div>
          <div class="flex-1 min-w-0">
            <div class="text-xs font-bold text-fg-3 tracking-caps">{@slot}</div>
            <div class="text-lg font-semibold tracking-tight mt-0.5">{@name}</div>
            <div class="mt-2">
              <.badge variant={@status.variant} dot>{@status.label}</.badge>
            </div>
          </div>
          <.button variant={:ghost} size={:sm} phx-click="close_drive_drawer">
            <.icon name={:x} size={16} />
          </.button>
        </div>

        <%!-- Identity --%>
        <dl class="px-6 py-4 m-0 grid grid-cols-[120px_1fr] gap-x-4 gap-y-2.5 text-sm">
          <dt class="text-fg-3">Model</dt>
          <dd class="m-0 text-fg-1">{vidpid(@drive) || "USB mass storage"}</dd>
          <dt class="text-fg-3">Slot</dt>
          <dd class="m-0 text-fg-1">{slot_line(@slot, @drive)}</dd>
          <dt class="text-fg-3">Device</dt>
          <dd class="m-0 text-fg-1 font-mono">{@drive.dev_path}</dd>
          <dt class="text-fg-3">Size</dt>
          <dd class="m-0 text-fg-1 tabular-nums">{size_label(@drive) || "—"}</dd>
        </dl>

        <div :if={not @first?} class="px-6 py-4 border-t border-border-1">
          <div class="flex items-start gap-2.5 px-3.5 py-3 rounded-md bg-sunken text-sm text-fg-2">
            <.icon name={:info} size={16} stroke={2.0} />
            <span>Only the first drive is used. Unplug the other drive to back up to this one.</span>
          </div>
        </div>

        <div :if={@first? and @ejected?} class="px-6 py-4 border-t border-border-1">
          <div class="flex items-start gap-2.5 px-3.5 py-3 rounded-md bg-sunken text-sm text-fg-2">
            <.icon name={:info} size={16} stroke={2.0} />
            <span>
              Drive ejected — it's safe to unplug now. Re-plug the drive to mount it again.
            </span>
          </div>
        </div>

        <%!-- Filesystem + capacity --%>
        <div :if={@first? and not @ejected?} class="px-6 py-4 border-t border-border-1">
          <.eyebrow>Filesystem</.eyebrow>
          <div class="flex items-center gap-2 flex-wrap mt-2">
            <.badge variant={@fs.variant} dot>{@fs.label}</.badge>
            <span class="text-sm text-fg-3">{mount_line(@mount)}</span>
            <.badge :if={@formatting?} variant={:neutral}>Formatting…</.badge>
          </div>
          <div :if={not @fs.journalled? and not @formatting?} class="text-sm text-fg-2 mt-2">
            Not journalled — format to ext4 recommended for backups.
          </div>
          <div :if={@storage.share == :error} class="text-sm text-danger mt-2">
            Share failed to start — retrying.
          </div>
          <.capacity_bar :if={@mount && @storage.capacity} capacity={@storage.capacity} />
        </div>

        <%!-- Backups (SMB share) --%>
        <div :if={@first? and not @ejected?} class="px-6 py-4 border-t border-border-1">
          <.eyebrow>Backups</.eyebrow>
          <div
            :if={not @supported?}
            class="mt-2 px-3.5 py-3 rounded-md bg-sunken text-sm text-fg-2"
          >
            Network sharing isn't available on this firmware.
          </div>
          <div
            :if={@supported?}
            class="mt-2 flex items-center gap-3 px-3.5 py-3 border border-border-1 rounded-md"
          >
            <.toggle
              checked={@shared?}
              phx-click="drive_toggle_share"
              disabled={@formatting? or is_nil(@mount) or is_nil(@drive[:key])}
            />
            <div class="flex-1 min-w-0">
              <div class="text-sm font-semibold">Share as HA backup target</div>
              <div class="text-sm text-fg-3 mt-0.5">
                {if @shared?,
                  do: "Home Assistant can use this drive as a network backup location.",
                  else: "Starts an SMB share Home Assistant can back up to."}
              </div>
            </div>
          </div>

          <div :if={@supported? and @shared?} class="mt-3 flex flex-col gap-2">
            <div class="grid grid-cols-[84px_1fr_auto] gap-2 items-center">
              <div class="text-sm text-fg-3">Folder</div>
              <.text_input
                name="storage_folder"
                value={folder_label(@storage.share_folder)}
                readonly
                mono
                class="!h-7 !text-sm min-w-0"
              />
              <.button variant={:secondary} size={:sm} phx-click="drive_open_chooser">
                Choose…
              </.button>
            </div>

            <.copy_row id="storage-unc" label="Path" value={unc_path(@host)} />

            <%!-- No credentials to show: either the settings store can't be
                 reached or a generated password could not be persisted. The
                 default account name is deliberately NOT rendered here — it
                 would read as "these work". --%>
            <div
              :if={not @credentials?}
              class="px-3.5 py-3 rounded-md bg-sunken text-sm text-fg-2"
            >
              Share credentials are unavailable — they couldn't be read or saved on this device.
            </div>

            <div :if={@credentials?} class="flex flex-col gap-2">
              <.copy_row id="storage-user" label="Username" value={@username || "backup"} />

              <%!-- The password is never rendered until Reveal: it only reaches
                   this component once the LiveView has read it in response to
                   an explicit click, so a pre-reveal DOM has no copy of it. --%>
              <div class="grid grid-cols-[84px_1fr_auto] gap-2 items-center">
                <div class="text-sm text-fg-3">Password</div>
                <.text_input
                  name="storage_password"
                  value={@password || "••••••••••••••••"}
                  readonly
                  mono
                  class="!h-7 !text-sm min-w-0"
                />
                <div class="flex gap-1.5">
                  <.button variant={:secondary} size={:sm} phx-click="drive_reveal_password">
                    {if @password, do: "Hide", else: "Reveal"}
                  </.button>
                  <.button variant={:secondary} size={:sm} phx-click="drive_copy_password">
                    {if @copied?, do: "Copied", else: "Copy"}
                  </.button>
                </div>
              </div>

              <div class="flex items-center gap-2.5 mt-1">
                <div class={[
                  "flex-1 text-sm",
                  if(@armed == :regen, do: "text-danger", else: "text-fg-3")
                ]}>
                  {if @armed == :regen,
                    do: "Regenerating invalidates the old credential in Home Assistant immediately.",
                    else: "Lost the password? You can mint a new one."}
                </div>
                <div :if={@armed == :regen} class="flex gap-1.5 flex-none">
                  <.button variant={:ghost} size={:sm} phx-click="drive_disarm">Cancel</.button>
                  <.button variant={:danger} size={:sm} phx-click="drive_regenerate_password">
                    Regenerate
                  </.button>
                </div>
                <.button
                  :if={@armed != :regen}
                  variant={:secondary}
                  size={:sm}
                  phx-click="drive_arm"
                  phx-value-action="regen"
                >
                  <.icon name={:refresh} size={14} /> Regenerate password
                </.button>
              </div>
            </div>
          </div>
        </div>

        <%!-- Danger zone (pinned to the bottom of the drawer) --%>
        <div class="mt-auto px-6 py-4 border-t border-border-1 flex flex-col gap-4">
          <div class="text-xs font-bold text-danger uppercase tracking-caps">Danger zone</div>
          <.armed_action
            title="Format as ext4"
            help="Erases the drive and formats it with a journalled filesystem."
            confirm={"Erase everything on #{@name} (#{@drive.dev_path}) and format it as ext4? The share will be stopped."}
            label="Format…"
            busy_label="Formatting…"
            armed?={@armed == :format}
            busy?={@formatting?}
            disabled?={not @first?}
            action="format"
            confirm_event="drive_format"
          />
          <.armed_action
            title="Safe eject"
            help="Stops the share and unmounts, so the drive can be unplugged."
            confirm={"Eject #{@name} (#{@drive.dev_path})? Home Assistant backups to this drive will stop."}
            label="Eject…"
            busy_label="Ejecting…"
            armed?={@armed == :eject}
            busy?={false}
            disabled?={not @first? or @formatting? or @ejected? or is_nil(@mount)}
            action="eject"
            confirm_event="drive_eject"
          />
        </div>

        <.folder_chooser :if={@chooser} chooser={@chooser} />
      </div>
    </div>
    """
  end

  defp slot_line(slot, drive) do
    case drive.slot_sub do
      sub when is_binary(sub) -> "#{slot} — #{sub}"
      _ -> slot
    end
  end

  defp mount_line(nil), do: "not mounted"
  defp mount_line(%{stale?: true}), do: "unmounting — busy"
  defp mount_line(%{mode: :read_only}), do: "mounted read-only"
  defp mount_line(_mount), do: "mounted read-write"

  attr(:capacity, :map, required: true)

  defp capacity_bar(assigns) do
    ~H"""
    <div class="mt-3.5">
      <div class="h-2 rounded-full bg-sunken overflow-hidden">
        <div
          class={[
            "h-full rounded-full transition-[width] duration-300 ease-standard",
            if(@capacity.used_pct > 90, do: "bg-danger", else: "bg-accent")
          ]}
          style={"width: #{@capacity.used_pct}%"}
        >
        </div>
      </div>
      <div class="flex justify-between text-sm text-fg-3 mt-1.5">
        <span>
          <span class="text-fg-1 tabular-nums">{bytes_gb(@capacity.used_bytes)} GB</span>
          used · {@capacity.used_pct}%
        </span>
        <span>
          <span class="text-fg-1 tabular-nums">{bytes_gb(@capacity.free_bytes)} GB</span> free
        </span>
      </div>
    </div>
    """
  end

  defp bytes_gb(bytes) when is_integer(bytes) and bytes >= 0, do: gb(bytes)
  defp bytes_gb(_bytes), do: "—"

  # Non-secret value with a client-side copy (the hook does the "Copied"
  # cue without a round trip). Never used for the password, which must not
  # be in the DOM at all before Reveal.
  attr(:id, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :string, required: true)

  defp copy_row(assigns) do
    ~H"""
    <div class="grid grid-cols-[84px_1fr_auto] gap-2 items-center">
      <div class="text-sm text-fg-3">{@label}</div>
      <.text_input name={@id} value={@value} readonly mono class="!h-7 !text-sm min-w-0" />
      <button
        type="button"
        id={@id}
        phx-hook="CopyToClipboard"
        data-clipboard={@value}
        class="inline-flex items-center justify-center h-7 px-2.5 text-sm font-medium rounded-md
               border border-border-strong bg-surface text-fg-1 hover:bg-sunken whitespace-nowrap"
      >
        Copy
      </button>
    </div>
    """
  end

  # Two-step destructive action: the first click arms (help line becomes the
  # red confirm sentence naming the drive), the second fires.
  attr(:title, :string, required: true)
  attr(:help, :string, required: true)
  attr(:confirm, :string, required: true)
  attr(:label, :string, required: true)
  attr(:busy_label, :string, required: true)
  attr(:armed?, :boolean, required: true)
  attr(:busy?, :boolean, required: true)
  attr(:disabled?, :boolean, required: true)
  attr(:action, :string, required: true)
  attr(:confirm_event, :string, required: true)

  defp armed_action(assigns) do
    ~H"""
    <div class="flex items-center gap-3">
      <div class="flex-1 min-w-0">
        <div class="text-sm font-semibold">{@title}</div>
        <div class={["text-sm mt-0.5", if(@armed?, do: "text-danger", else: "text-fg-3")]}>
          {if @armed?, do: @confirm, else: @help}
        </div>
      </div>
      <div :if={@armed?} class="flex gap-1.5 flex-none">
        <.button variant={:ghost} size={:sm} phx-click="drive_disarm">Cancel</.button>
        <.button variant={:danger} size={:sm} phx-click={@confirm_event}>Confirm</.button>
      </div>
      <.button
        :if={not @armed?}
        variant={:danger}
        size={:sm}
        phx-click="drive_arm"
        phx-value-action={@action}
        disabled={@disabled? or @busy?}
      >
        {if @busy?, do: @busy_label, else: @label}
      </.button>
    </div>
    """
  end

  # ── Folder chooser ────────────────────────────────────────────────────

  # Windows' reserved filename characters, which the design adopts as the
  # new-folder rule. Mirrors `Storage.Server`'s server-side rule so the
  # Create button and the façade agree on what is valid — the backend stays
  # the authority (its `{:error, :invalid_name}` surfaces inline).
  @forbidden_name_chars ~w(\\ / : * ? " < > |)

  @doc "Whether `name` is a creatable folder name given its siblings."
  @spec valid_folder_name?(String.t(), [String.t()]) :: boolean()
  def valid_folder_name?(name, siblings) do
    trimmed = String.trim(name)

    trimmed != "" and
      trimmed not in [".", ".."] and
      not Enum.any?(@forbidden_name_chars, &String.contains?(trimmed, &1)) and
      trimmed not in siblings
  end

  @doc """
  Breadcrumb segments for `path` as `{label, path}` pairs, root first.
  """
  @spec crumbs(String.t()) :: [{String.t(), String.t()}]
  def crumbs(path) do
    segments =
      path
      |> String.split("/", trim: true)
      |> Enum.scan([], fn segment, acc -> acc ++ [segment] end)
      |> Enum.map(fn parts -> {List.last(parts), Enum.join(parts, "/")} end)

    [{"drive", @root_folder} | segments]
  end

  @doc "Append `name` to drive-relative `path`."
  @spec join_folder(String.t(), String.t()) :: String.t()
  def join_folder(path, name) when path in [@root_folder, ""], do: name
  def join_folder(path, name), do: "#{path}/#{name}"

  attr(:chooser, :map, required: true)

  defp folder_chooser(assigns) do
    assigns =
      assign(
        assigns,
        :name_ok?,
        valid_folder_name?(assigns.chooser.name, assigns.chooser.dirs)
      )

    ~H"""
    <div class="fixed inset-0 z-[210] flex items-center justify-center p-5 animate-fade">
      <div phx-click="drive_chooser_close" class="absolute inset-0 bg-overlay"></div>
      <div class="relative bg-raised rounded-lg shadow-lg w-full max-w-[420px] animate-pop">
        <div class="px-6 pt-5 pb-3">
          <h3 class="text-lg font-semibold m-0 text-fg-1">Choose backup folder</h3>
          <p class="text-sm text-fg-2 mt-1">
            Home Assistant backups will be written inside this folder on the drive.
          </p>
        </div>

        <div class="px-5">
          <%!-- Breadcrumb: every ancestor jumps back, the current crumb is inert. --%>
          <div class="flex items-center gap-1 flex-wrap font-mono text-sm mb-2.5">
            <%= for {{label, path}, index} <- Enum.with_index(crumbs(@chooser.path)) do %>
              <span :if={index > 0} class="text-fg-3">/</span>
              <button
                :if={path != @chooser.path}
                type="button"
                phx-click="drive_chooser_cd"
                phx-value-path={path}
                class="px-1 py-0.5 rounded-xs bg-transparent border-none font-mono text-sm text-accent cursor-pointer"
              >
                {label}
              </button>
              <span :if={path == @chooser.path} class="px-1 py-0.5 font-semibold text-fg-1">
                {label}
              </span>
            <% end %>
          </div>

          <div class="border border-border-1 rounded-sm overflow-hidden min-h-[148px] max-h-[200px] overflow-y-auto">
            <div
              :if={@chooser.dirs == [] and not @chooser.creating?}
              class="px-3.5 py-4 text-sm text-fg-3 italic"
            >
              No subfolders
            </div>
            <button
              :for={dir <- @chooser.dirs}
              type="button"
              phx-click="drive_chooser_cd"
              phx-value-path={join_folder(@chooser.path, dir)}
              class="flex items-center gap-2.5 w-full bg-transparent border-0 border-t
                     border-border-2 first:border-t-0 px-3.5 py-2 text-sm text-fg-1 text-left
                     cursor-pointer hover:bg-sunken"
            >
              <span class="text-fg-3 flex-none"><.icon name={:folder} size={15} /></span>
              <span class="flex-1 truncate">{dir}</span>
              <span class="text-fg-4 flex-none"><.icon name={:chevron} size={12} /></span>
            </button>

            <form
              :if={@chooser.creating?}
              phx-submit="drive_chooser_create"
              phx-change="drive_chooser_name"
              class="flex items-center gap-2.5 border-t border-border-2 px-3.5 py-1.5"
            >
              <span class="text-fg-3 flex-none"><.icon name={:folder_plus} size={15} /></span>
              <.text_input
                name="name"
                value={@chooser.name}
                placeholder="Folder name"
                id="storage-new-folder"
                phx-hook="AutofocusSelect"
                phx-key="Escape"
                phx-keydown="drive_chooser_cancel_new"
                class="!h-7 !text-sm min-w-0 flex-1"
              />
              <.button variant={:ghost} size={:sm} type="button" phx-click="drive_chooser_cancel_new">
                Cancel
              </.button>
              <.button variant={:primary} size={:sm} type="submit" disabled={not @name_ok?}>
                Create
              </.button>
            </form>
          </div>

          <div :if={@chooser.error} class="text-sm text-danger mt-2">{@chooser.error}</div>

          <div class="text-sm text-fg-3 mt-2.5">
            Share will map to
            <span class="font-mono text-fg-1">{folder_label(@chooser.path)}</span>
          </div>
        </div>

        <div class="flex items-center gap-2 px-6 py-4 mt-2 border-t border-border-2">
          <.button
            variant={:secondary}
            size={:sm}
            phx-click="drive_chooser_new"
            disabled={@chooser.creating?}
          >
            New folder
          </.button>
          <div class="flex-1"></div>
          <.button variant={:ghost} size={:sm} phx-click="drive_chooser_close">Cancel</.button>
          <.button variant={:primary} size={:sm} phx-click="drive_chooser_pick">
            Use this folder
          </.button>
        </div>
      </div>
    </div>
    """
  end
end
