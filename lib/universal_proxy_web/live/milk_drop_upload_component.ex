defmodule UniversalProxyWeb.MilkDropUploadComponent do
  @moduledoc """
  Upload MilkDrop presets: `.milk` files, or `.zip` archives of presets
  and their `.png`/`.jpg` textures, imported into
  `UniversalProxy.MilkDrop.UserPresets`. Rendered on the Audio tab (inside
  `UniversalProxyWeb.MilkDropComponent`) and in the preset browser
  (`UniversalProxyWeb.MilkDropPresetsLive`), both as `id="milkdrop-upload"`.

  ## Upload

  Up to #{20} files of at most `UserPresets.max_upload_bytes/0` each, sent
  when the form is submitted (no `auto_upload`), so one batch is one
  import and one results table. Each entry streams through
  `UniversalProxyWeb.MilkDropUploadWriter` into the library's
  `incoming/` directory on `/data`. As each entry starts, the batch (the
  declared sizes of every valid entry; the upload channel never accepts
  more than an entry declared) must be at most the library's byte quota,
  and the writer reserves the entry's own size with
  `UserPresets.reserve/2`, which admits it only within the room above the
  free-space floor left by every other live upload, on any page; else
  the entry fails with `{:writer_failure, reason}`.

  ## Import

  Submit imports only once every entry has finished: one still
  uploading, failed or refused keeps its error on screen until it is
  removed. The finished entries are then claimed (`UserPresets.claim/2`:
  the server deletes them should this LiveView exit before the import
  takes them) and handed to `UserPresets.import/2` in `start_async/3`; a
  second submit while it runs is ignored. An import that fails as a whole
  deletes the claimed files.
  `UniversalProxy.MilkDrop.Index` broadcasts the new presets itself, so
  nothing else is refreshed here. The results show one row per file (#{50}
  at most) through HEEx escaping only, with `UploadCheck.printable/1`
  names; added presets link to their browser rows.

  The parent forwards Index changes as `send_update(__MODULE__, id: id,
  refresh: true)`, which re-reads the quota usage (`UserPresets.usage/1`).
  """

  use UniversalProxyWeb, :live_component

  import UniversalProxyWeb.Components.UI
  import UniversalProxyWeb.Components.Icons
  import UniversalProxyWeb.Components.MilkDropUI

  alias UniversalProxy.MilkDrop.{UploadCheck, UserPresets}
  alias UniversalProxyWeb.MilkDropUploadWriter

  @max_entries 20
  @max_rows 50
  @mib 1024 * 1024

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:class, nil)
     |> assign(:usage, UserPresets.usage())
     |> assign(:importing, nil)
     |> assign(:results, nil)
     |> assign(:import_error, nil)
     |> allow_upload(:presets,
       accept: :any,
       validator: &validate_entry/1,
       max_entries: @max_entries,
       max_file_size: UserPresets.max_upload_bytes(),
       auto_upload: false,
       writer: &writer/3
     )}
  end

  @impl true
  def update(%{refresh: true}, socket), do: {:ok, assign(socket, :usage, UserPresets.usage())}
  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  # `accept: :any` plus this, because `.milk` has no MIME type (`accept`
  # takes only known extensions); the input still gets `accept=".milk,.zip"`.
  defp validate_entry(entry) do
    if extension(entry.client_name) in ~w(.milk .zip), do: :ok, else: {:error, :not_accepted}
  end

  defp extension(name), do: name |> Path.extname() |> String.downcase()

  # Runs in the LiveView process as each entry's upload starts.
  defp writer(_name, entry, socket) do
    batch = batch_bytes(socket.assigns.uploads.presets.entries)
    max = socket.assigns.usage.quota.bytes

    if batch > max,
      do: {MilkDropUploadWriter, refuse: {:batch_too_large, max}},
      else: {MilkDropUploadWriter, bytes: entry.client_size}
  end

  defp batch_bytes(entries),
    do: entries |> Enum.filter(& &1.valid?) |> Enum.map(& &1.client_size) |> Enum.sum()

  # ── Events ────────────────────────────────────────────────────────────

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_entry", %{"ref" => ref}, socket) when is_binary(ref),
    do: {:noreply, cancel_upload(socket, :presets, ref)}

  def handle_event("dismiss_results", _params, socket),
    do: {:noreply, assign(socket, results: nil, import_error: nil)}

  def handle_event("import", _params, %{assigns: %{importing: %{}}} = socket),
    do: {:noreply, socket}

  def handle_event("import", _params, socket) do
    # consume_uploaded_entries/3 raises while any entry is unfinished.
    case uploaded_entries(socket, :presets) do
      {[_ | _], []} ->
        claimed =
          consume_uploaded_entries(socket, :presets, fn %{ref: ref}, entry ->
            {:ok, {entry.client_name, UserPresets.claim(ref)}}
          end)

        {:noreply, start_import(socket, claimed)}

      _none_or_unfinished ->
        {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp start_import(socket, claimed) do
    uploads = for {name, {:ok, path}} <- claimed, do: {name, path}
    lost = for {name, {:error, reason}} <- claimed, do: lost_result(name, reason)

    socket
    |> assign(:importing, %{paths: Enum.map(uploads, &elem(&1, 1)), lost: lost})
    |> assign(results: nil, import_error: nil)
    |> start_async(:import, fn -> run_import(uploads) end)
  end

  defp run_import([]), do: {:ok, []}

  defp run_import(uploads) do
    case UserPresets.import(uploads) do
      {:ok, _results} = ok ->
        ok

      {:error, _reason} = error ->
        remove(uploads)
        error
    end
  end

  defp remove(uploads), do: Enum.each(uploads, fn {_name, path} -> File.rm(path) end)

  defp lost_result(client_name, reason) do
    %{
      upload: UploadCheck.printable(client_name),
      entry: nil,
      kind: :other,
      name: nil,
      id: nil,
      status: {:rejected, if(reason == :not_running, do: :not_running, else: :upload_lost)},
      replaces: nil,
      sha256: nil,
      size: nil,
      warnings: []
    }
  end

  @impl true
  def handle_async(:import, result, socket) do
    %{paths: paths, lost: lost} = socket.assigns.importing

    socket =
      socket
      |> assign(:importing, nil)
      |> assign(:usage, UserPresets.usage())

    case result do
      {:ok, {:ok, results}} ->
        {:noreply, assign(socket, :results, results_view(lost ++ results))}

      {:ok, {:error, reason}} ->
        {:noreply, assign(socket, import_error: import_error(reason), results: lost_view(lost))}

      {:exit, _reason} ->
        Enum.each(paths, &File.rm/1)

        {:noreply,
         assign(socket,
           import_error: "The import stopped unexpectedly.",
           results: lost_view(lost)
         )}
    end
  end

  defp lost_view([]), do: nil
  defp lost_view(lost), do: results_view(lost)

  defp results_view(results) do
    %{
      rows: Enum.take(results, @max_rows),
      more: max(length(results) - @max_rows, 0),
      summary: summary(results)
    }
  end

  defp summary([]), do: "Nothing to import."

  defp summary(results) do
    counts = Enum.frequencies_by(results, &status_group(&1.status))

    [added: "added", replaced: "replaced", unchanged: "unchanged", ignored: "ignored"]
    |> Enum.concat(rejected: "rejected")
    |> Enum.flat_map(fn {group, word} ->
      case Map.get(counts, group, 0) do
        0 -> []
        n -> ["#{delimit(n)} #{word}"]
      end
    end)
    |> Enum.join(" · ")
  end

  defp status_group({:rejected, _reason}), do: :rejected
  defp status_group(status), do: status

  # ── Render ────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    entries = assigns.uploads.presets.entries
    batch = batch_bytes(entries)
    quota_bytes = assigns.usage.quota.bytes

    assigns =
      assigns
      |> assign(:batch_over, batch > quota_bytes)
      |> assign(:batch, batch)
      |> assign(
        :blocked,
        entries == [] or assigns.importing != nil or batch > quota_bytes or
          Enum.any?(entries, &(upload_errors(assigns.uploads.presets, &1) != []))
      )

    ~H"""
    <section id={@id} aria-label="Upload presets" class={@class}>
      <.card padding={:none} class="overflow-hidden">
        <form
          id={"#{@id}-form"}
          phx-submit="import"
          phx-change="validate"
          phx-target={@myself}
          class="p-[18px_22px]"
        >
          <div class="flex items-start gap-3 flex-wrap">
            <div class="flex-1 min-w-0">
              <div class="text-md font-semibold text-fg-1">Upload presets</div>
              <div class="text-xs text-fg-3 mt-1">
                .milk presets, or .zip archives of presets and their .png or .jpg textures.
                Up to {@uploads.presets.max_entries} files, {mib(@uploads.presets.max_file_size)} each.
              </div>
              <div id={"#{@id}-usage"} class="text-xs text-fg-3 mt-0.5 tabular-nums">
                {usage_line(@usage)}
              </div>
            </div>
          </div>

          <div
            id={"#{@id}-drop"}
            phx-drop-target={@uploads.presets.ref}
            class="mt-3 p-3 rounded-md border border-dashed border-border-strong bg-sunken
                   flex flex-col sm:flex-row sm:items-center gap-2"
          >
            <span class="text-sm text-fg-2 flex-1 min-w-0">Drop files here, or choose them:</span>
            <.live_file_input
              upload={@uploads.presets}
              accept=".milk,.zip"
              aria-label="MilkDrop presets or zip archives to upload"
              class="min-w-0 max-w-full text-sm text-fg-2"
            />
          </div>

          <ul
            :if={@uploads.presets.entries != []}
            id={"#{@id}-entries"}
            role="list"
            aria-label="Files to upload"
            class="mt-3 mb-0 p-0 list-none flex flex-col gap-2.5"
          >
            <li :for={entry <- @uploads.presets.entries} id={"#{@id}-entry-#{entry.ref}"}>
              <div class="flex items-center gap-2">
                <span class="text-sm text-fg-1 truncate flex-1 min-w-0" title={UploadCheck.printable(entry.client_name)}>
                  {UploadCheck.printable(entry.client_name)}
                </span>
                <span class="text-xs text-fg-3 tabular-nums flex-none">{mib(entry.client_size)}</span>
                <span class="text-xs text-fg-3 tabular-nums flex-none w-9 text-right">{entry.progress}%</span>
                <button
                  type="button"
                  phx-click="cancel_entry"
                  phx-value-ref={entry.ref}
                  phx-target={@myself}
                  disabled={@importing != nil}
                  aria-label={"Remove #{UploadCheck.printable(entry.client_name)}"}
                  class="flex-none w-8 h-8 inline-flex items-center justify-center rounded-md text-fg-3
                         hover:bg-sunken disabled:opacity-40"
                >
                  <.icon name={:x} size={14} />
                </button>
              </div>
              <div
                role="progressbar"
                aria-label={"Upload of #{UploadCheck.printable(entry.client_name)}"}
                aria-valuemin="0"
                aria-valuemax="100"
                aria-valuenow={entry.progress}
                class="mt-1 h-1.5 rounded-full bg-sunken overflow-hidden"
              >
                <div
                  class="h-full rounded-full bg-accent transition-[width] duration-300 ease-standard"
                  style={"width: #{entry.progress}%"}
                >
                </div>
              </div>
              <p
                :for={err <- upload_errors(@uploads.presets, entry)}
                role="alert"
                class="text-xs text-danger mt-1 mb-0"
              >
                {upload_error(err)}
              </p>
            </li>
          </ul>

          <p
            :for={err <- upload_errors(@uploads.presets)}
            role="alert"
            class="mt-2.5 mb-0 text-xs text-danger"
          >
            {upload_error(err)}
          </p>

          <p :if={@batch_over} id={"#{@id}-batch-over"} role="alert" class="mt-2.5 mb-0 text-xs text-danger">
            These files add up to {mib(@batch)}; upload at most {mib(@usage.quota.bytes)} at once.
          </p>

          <.photosensitivity_warning
            id={"#{@id}-warning"}
            class="mt-3"
            lead="Rapidly flashing presets may trigger seizures in people with photosensitive epilepsy."
          >
            Uploads aren't screened for flashing or brightness and join the rotation even while
            fast-flashing presets are off. You're responsible for what you upload: mark any that flash
            rapidly as fast-flashing (the lightning button in the preset browser).
          </.photosensitivity_warning>

          <div class="mt-3 flex items-center gap-3 flex-wrap">
            <.button
              id={"#{@id}-submit"}
              type="submit"
              variant={:primary}
              size={:sm}
              disabled={@blocked}
              phx-disable-with="Uploading…"
            >
              {if @importing, do: "Importing…", else: "Upload and import"}
            </.button>
            <span :if={@importing} class="text-xs text-fg-3" role="status">
              Checking and installing the uploads…
            </span>
          </div>
        </form>

        <div
          :if={@import_error}
          id={"#{@id}-error"}
          role="alert"
          class="px-[22px] py-2 border-t border-border-2 bg-danger-soft text-danger text-xs"
        >
          {@import_error}
        </div>

        <div :if={@results} id={"#{@id}-results"} class="border-t border-border-2">
          <div class="flex items-center gap-3 px-[22px] py-2.5">
            <p id={"#{@id}-summary"} role="status" class="flex-1 min-w-0 text-sm text-fg-1 m-0">
              {@results.summary}
            </p>
            <.button variant={:ghost} size={:sm} phx-click="dismiss_results" phx-target={@myself}>
              Dismiss
            </.button>
          </div>
          <table :if={@results.rows != []} class="w-full table-fixed text-xs border-collapse">
            <thead class="sr-only">
              <tr>
                <th scope="col">File</th>
                <th scope="col">Result</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @results.rows} class="border-t border-border-2 align-top">
                <td class="pl-[22px] pr-2 py-2 w-1/2">
                  <.result_name row={row} />
                </td>
                <td class="pr-[22px] py-2">
                  <.badge variant={status_variant(row.status)}>{status_label(row.status)}</.badge>
                  <div :if={status_reason(row.status)} class="text-fg-3 mt-1">{status_reason(row.status)}</div>
                  <div :if={:texture_shadowed in row.warnings} class="text-warning mt-1">
                    A pack texture with the same name is used instead.
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
          <p :if={@results.more > 0} class="px-[22px] py-2 m-0 text-xs text-fg-3 border-t border-border-2">
            …and {delimit(@results.more)} more
          </p>
        </div>
      </.card>
    </section>
    """
  end

  attr(:row, :map, required: true)

  defp result_name(assigns) do
    assigns = assign(assigns, :label, row_label(assigns.row))

    ~H"""
    <%= if @row.kind == :preset and @row.status in [:added, :replaced, :unchanged] and @row.name do %>
      <.link
        navigate={browse_path(@row.name)}
        class="block text-accent hover:underline truncate"
        title={@label}
      >
        {@label}
      </.link>
    <% else %>
      <span class="block text-fg-1 truncate" title={@label}>{@label}</span>
    <% end %>
    <span :if={@row.entry} class="block text-fg-3 truncate" title={@row.upload}>in {@row.upload}</span>
    """
  end

  defp row_label(%{entry: entry}) when is_binary(entry), do: UploadCheck.printable(entry)
  defp row_label(%{upload: upload}), do: upload

  defp browse_path(name),
    do: ~p"/audio/milkdrop?#{[filter: "uploaded", q: Path.basename(name, ".milk")]}"

  defp usage_line(%{quota: quota} = usage) do
    "Uploads use #{mib(usage.bytes)} of #{mib(quota.bytes)} · " <>
      "#{delimit(usage.presets)} of #{delimit(quota.presets)} presets · " <>
      "#{delimit(usage.textures)} of #{delimit(quota.textures)} textures"
  end

  defp mib(bytes) when bytes >= @mib, do: one_decimal(bytes / @mib) <> " MiB"
  defp mib(bytes) when bytes >= 1024, do: one_decimal(bytes / 1024) <> " KiB"
  defp mib(bytes), do: "#{bytes} B"

  defp one_decimal(value) do
    rounded = Float.round(value, 1)
    if rounded == trunc(rounded), do: "#{trunc(rounded)}", else: "#{rounded}"
  end

  # ── Text ──────────────────────────────────────────────────────────────

  defp status_variant(:added), do: :success
  defp status_variant(:replaced), do: :accent
  defp status_variant({:rejected, _reason}), do: :danger
  defp status_variant(_unchanged_or_ignored), do: :neutral

  defp status_label(:added), do: "Added"
  defp status_label(:replaced), do: "Replaced"
  defp status_label(:unchanged), do: "Unchanged"
  defp status_label(:ignored), do: "Ignored"
  defp status_label({:rejected, _reason}), do: "Rejected"

  defp status_reason(:unchanged), do: "Already in the library."
  defp status_reason(:ignored), do: "Not a preset or texture."
  defp status_reason({:rejected, reason}), do: reject_reason(reason)
  defp status_reason(_status), do: nil

  # UploadCheck, Zip, ImportPlan and UserPresets reasons.
  defp reject_reason(:unsupported_file), do: "Not a .milk preset or .zip archive."
  defp reject_reason(:invalid_name), do: "Its name has characters that aren't allowed."
  defp reject_reason(:duplicate_name), do: "Another file in this upload has the same name."
  defp reject_reason(:reserved_name), do: "MilkDrop reserves this texture name."
  defp reject_reason(:too_many_textures), do: "Too many textures in one archive (at most 64)."
  defp reject_reason(:too_large), do: "Too large."
  defp reject_reason(:quota), do: "The upload library is full."
  defp reject_reason(:no_space), do: "Not enough free storage on the device."
  defp reject_reason(:bad_source), do: "The upload went missing. Try again."
  defp reject_reason(:upload_lost), do: "The upload went missing. Try again."
  defp reject_reason(:not_running), do: "The preset library isn't running."
  defp reject_reason(:not_regular_file), do: "Not a regular file."
  defp reject_reason({:io, :install_failed}), do: "Couldn't be installed (storage error)."
  defp reject_reason({:io, _posix}), do: "Storage error."
  defp reject_reason({:manifest, _reason}), do: "Couldn't update the library's manifest."
  defp reject_reason(:nul_byte), do: "Not a text preset."
  defp reject_reason(:control_char), do: "Not a text preset."
  defp reject_reason(:too_many_lines), do: "Too many lines for a preset."
  defp reject_reason(:line_too_long), do: "A line is too long for a preset."
  defp reject_reason(:no_values), do: "Not a MilkDrop preset (no settings found)."
  defp reject_reason(:bad_magic), do: "Its content doesn't match its extension."
  defp reject_reason(:bad_header), do: "A damaged or unsupported image."
  defp reject_reason({:dimensions, w, h}), do: "#{w}×#{h} is too big (at most 2048×2048)."
  defp reject_reason(:interlaced), do: "Interlaced PNGs aren't supported."
  defp reject_reason(:unsupported_jpeg), do: "Progressive JPEGs aren't supported."
  defp reject_reason(:not_a_zip), do: "Not a zip archive."
  defp reject_reason(:multi_disk), do: "Split archives aren't supported."
  defp reject_reason(:zip64), do: "ZIP64 archives aren't supported."
  defp reject_reason(:too_many_entries), do: "Too many files in the archive (at most 256)."
  defp reject_reason(:truncated), do: "The archive is incomplete."

  defp reject_reason(reason) when reason in [:bad_central_directory, :leading_data],
    do: "A damaged archive."

  defp reject_reason({:encrypted, _name}), do: "Encrypted archives aren't supported."

  defp reject_reason({:unsupported_method, name}),
    do: "#{name} uses an unsupported compression method."

  defp reject_reason({:unsafe_path, name}), do: "Unsafe path in the archive: #{name}"
  defp reject_reason({:not_regular_file, name}), do: "A link or special file: #{name}"
  defp reject_reason({:ratio, name}), do: "#{name} is compressed suspiciously well."
  defp reject_reason({:name_encoding, _name}), do: "The archive's file names aren't UTF-8."
  defp reject_reason({:duplicate, name}), do: "The archive holds #{name} twice."

  defp reject_reason({reason, name})
       when reason in [
              :bad_sizes,
              :overlap,
              :bad_local_header,
              :header_mismatch,
              :size_mismatch,
              :crc_mismatch,
              :corrupt
            ],
       do: "The archive is damaged at #{name}."

  defp reject_reason(_reason), do: "Rejected."

  defp import_error(:busy), do: "Another import is running. Try again when it's done."
  defp import_error(:not_running), do: "The preset library isn't running."

  defp import_error(:timeout),
    do: "The import took too long and was stopped; nothing was installed."

  defp import_error({:free_space, _reason}), do: "Couldn't measure the device's free storage."
  defp import_error({:crashed, _reason}), do: "The import stopped unexpectedly."
  defp import_error(_reason), do: "The import failed."

  # upload_errors/1,2
  defp upload_error(:too_large),
    do: "Larger than #{mib(UserPresets.max_upload_bytes())}, the upload limit."

  defp upload_error(:not_accepted), do: "Choose .milk presets or .zip archives."
  defp upload_error(:too_many_files), do: "Choose at most #{@max_entries} files at a time."
  defp upload_error(:external_client_failure), do: "The upload failed. Try again."
  defp upload_error({:writer_failure, reason}), do: writer_error(reason)
  defp upload_error(_reason), do: "The upload failed. Try again."

  defp writer_error(:too_large), do: "The file sent more data than its declared size."
  defp writer_error({:too_large, max}), do: "Larger than #{mib(max)}, the upload limit."

  defp writer_error({:batch_too_large, max}),
    do: "These files add up to more than #{mib(max)}. Upload fewer at once."

  defp writer_error(:no_space), do: "Not enough free storage on the device."
  defp writer_error(:not_running), do: "The preset library isn't running."
  defp writer_error({:free_space, _reason}), do: "Couldn't measure the device's free storage."
  defp writer_error(_reason), do: "The upload failed. Try again."
end
