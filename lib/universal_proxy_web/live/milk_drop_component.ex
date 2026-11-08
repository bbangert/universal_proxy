defmodule UniversalProxyWeb.MilkDropComponent do
  @moduledoc """
  MilkDrop visualizer settings on the Audio tab, beside the HDMI output
  whose TV shows it. Rendered by `UniversalProxyWeb.AudioLive` only while
  MilkDrop is enabled. Everything goes through `UniversalProxy.MilkDrop.Store`
  and `UniversalProxy.MilkDrop.Pack` (both follow the `catch :exit` idiom,
  so a stopped subsystem reads as defaults / `{:error, :not_running}`).

    * **Preset pack** — absent, downloading (progress bar), ready (its
      version), retrying ("Waiting for network…" or "Retrying in N s",
      with Retry to try now) or failed (the reason). Download / Retry calls
      `Pack.ensure/0` in `start_async/3`, so a slow Pack never blocks the
      LiveView; the button is disabled while that call runs. Status changes
      arrive over PubSub, which is authoritative: the call's own answer is
      only applied when it is a failure or `:ready` (a `{:downloading, _}`
      answer could overtake later progress broadcasts). Answers made of a
      Pack that has since restarted are dropped.
    * **Rotation interval** — 10..120 s (`rotate_s`); anything else is
      refused inline without a write.
    * **Minimum frame rate** (`min_fps`) — a select of
      `Store.min_fps_options/0` (20 fps up to the board's maximum, in steps
      of 5); anything else is refused inline without a write.
    * **Include fast-flashing presets** (`include_high_frequency`, off by
      default) — turning it on first opens a confirmation carrying a
      photosensitivity warning; only its confirm writes `true`. Turning it
      off writes straight away.
    * **Skipped presets** — the presets the renderer could not draw with
      the ready pack's version, with their reasons, in a disclosure;
      "Clear" calls `Store.clear_skipped/0`; a running renderer keeps its
      own skip set, so cleared presets return from the next session. A
      preset that was showing when the device went down (`device_reset`,
      possibly a power cut rather than a GPU hang) comes back the same way.

  A write the Store refuses (`{:error, reason}`, e.g. its DETS table is
  unavailable) shows an inline error until the next successful write.

  ## Updates

  The parent subscribes to `UniversalProxy.MilkDrop.settings_topic/0` and
  `UniversalProxy.MilkDrop.pack_topic/0` (a LiveComponent can't) and
  forwards each message as `send_update(__MODULE__, id: id, event: message)`.
  Initial state is read in `mount/1`.

  This component only writes the Store: `UniversalProxy.Display.State`
  forwards its broadcasts to a running renderer.
  """

  use UniversalProxyWeb, :live_component

  import UniversalProxyWeb.Components.UI
  import UniversalProxyWeb.Components.Icons

  alias UniversalProxy.MilkDrop.Pack
  alias UniversalProxy.MilkDrop.Store

  @rotate_min 10
  @rotate_max 120

  @impl true
  def mount(socket) do
    pack = Pack.status()

    {:ok,
     socket
     |> assign(:settings, Store.settings())
     |> assign(:pack, pack)
     |> assign(:skipped, read_skipped(pack))
     |> assign(:ensuring, false)
     |> assign(:pack_gen, 0)
     |> assign(:confirm_hf, false)
     |> assign(:skipped_open, false)
     |> assign(:error, nil)}
  end

  @impl true
  def update(%{event: event}, socket), do: {:ok, apply_event(socket, event)}
  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  defp apply_event(socket, {:milkdrop_settings, settings}) when is_map(settings),
    do: assign(socket, :settings, settings)

  # The Store keeps one version's list: a broadcast for any other version
  # (or `nil`, a clear) means the ready version has none.
  defp apply_event(socket, {:milkdrop_skipped, version, entries}) when is_map(entries) do
    case socket.assigns.pack do
      {:ready, ^version, _dir} -> assign(socket, :skipped, entries)
      _ -> assign(socket, :skipped, %{})
    end
  end

  # A restarted Pack outdates every `ensure/0` call made of the previous
  # one (see `handle_async/3`), so nothing is being waited on any more.
  defp apply_event(socket, {:milkdrop_pack_started, status}) do
    socket
    |> update(:pack_gen, &(&1 + 1))
    |> assign(:ensuring, false)
    |> put_pack(status)
  end

  defp apply_event(socket, {:milkdrop_pack, status}), do: put_pack(socket, status)

  defp apply_event(socket, _event), do: socket

  # A new ready version brings its own skip list; leaving ready keeps the
  # list read for the last ready version out of sight (see render).
  defp put_pack(socket, status) do
    socket = assign(socket, :pack, status)

    case status do
      {:ready, _version, _dir} -> assign(socket, :skipped, read_skipped(status))
      _ -> socket
    end
  end

  defp read_skipped({:ready, version, _dir}) when is_binary(version), do: Store.skipped(version)
  defp read_skipped(_status), do: %{}

  # ── Events ────────────────────────────────────────────────────────────

  @impl true
  def handle_event("ensure_pack", _params, %{assigns: %{ensuring: true}} = socket),
    do: {:noreply, socket}

  def handle_event("ensure_pack", _params, socket) do
    {:noreply,
     socket
     |> assign(:ensuring, true)
     |> start_async({:ensure_pack, socket.assigns.pack_gen}, fn -> Pack.ensure() end)}
  end

  def handle_event("set_rotate", params, socket) do
    case parse_rotate(params["rotate_s"]) do
      {:ok, seconds} ->
        {:noreply, write(socket, %{rotate_s: seconds})}

      :error ->
        {:noreply,
         assign(
           socket,
           :error,
           "Rotation interval must be a whole number of seconds from #{@rotate_min} to #{@rotate_max}."
         )}
    end
  end

  def handle_event("set_min_fps", params, socket) do
    with raw when is_binary(raw) <- params["min_fps"],
         {fps, ""} <- Integer.parse(raw),
         true <- fps in Store.min_fps_options() do
      {:noreply, write(socket, %{min_fps: fps})}
    else
      _ -> {:noreply, assign(socket, :error, "Pick a minimum frame rate from the list.")}
    end
  end

  def handle_event("toggle_high_frequency", _params, socket) do
    if socket.assigns.settings.include_high_frequency do
      {:noreply, write(socket, %{include_high_frequency: false})}
    else
      {:noreply, assign(socket, :confirm_hf, true)}
    end
  end

  def handle_event("cancel_high_frequency", _params, socket),
    do: {:noreply, assign(socket, :confirm_hf, false)}

  def handle_event("confirm_high_frequency", _params, socket) do
    {:noreply,
     socket
     |> assign(:confirm_hf, false)
     |> write(%{include_high_frequency: true})}
  end

  def handle_event("toggle_skipped", _params, socket),
    do: {:noreply, update(socket, :skipped_open, &(not &1))}

  def handle_event("clear_skipped", _params, socket) do
    case Store.clear_skipped() do
      :ok ->
        {:noreply, socket |> assign(:skipped, %{}) |> assign(:error, nil)}

      {:error, reason} ->
        {:noreply,
         assign(socket, :error, "Couldn't clear skipped presets (#{store_error(reason)}).")}
    end
  end

  # Results of an `ensure/0` made before the Pack last restarted are
  # dropped: they could overwrite the replacement's newer status.
  @impl true
  def handle_async({:ensure_pack, gen}, result, %{assigns: %{pack_gen: gen}} = socket) do
    socket = assign(socket, :ensuring, false)

    case result do
      {:ok, {:error, _} = status} -> {:noreply, assign(socket, :pack, status)}
      {:ok, {:ready, _, _} = status} -> {:noreply, put_pack(socket, status)}
      {:ok, _downloading} -> {:noreply, socket}
      {:exit, reason} -> {:noreply, assign(socket, :pack, {:error, {:crashed, reason}})}
    end
  end

  def handle_async({:ensure_pack, _stale_gen}, _result, socket), do: {:noreply, socket}

  defp write(socket, params) do
    case Store.update(params) do
      {:ok, settings} ->
        socket |> assign(:settings, settings) |> assign(:error, nil)

      {:error, reason} ->
        assign(socket, :error, "Couldn't save the visualizer settings (#{store_error(reason)}).")
    end
  end

  defp parse_rotate(raw) when is_binary(raw) do
    case Integer.parse(String.trim(raw)) do
      {n, ""} when n >= @rotate_min and n <= @rotate_max -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_rotate(_raw), do: :error

  # ── Render ────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:view, pack_view(assigns.pack))
      |> assign(:rotate_min, @rotate_min)
      |> assign(:rotate_max, @rotate_max)
      |> assign(:min_fps_options, Store.min_fps_options())
      |> assign(:skipped_list, skipped_list(assigns.pack, assigns.skipped))

    ~H"""
    <section id={@id} aria-label="MilkDrop visualizer" class="mt-10">
      <div class="mb-5">
        <.eyebrow>TV</.eyebrow>
        <h2 class="text-xl font-semibold mt-1 mb-1.5 text-fg-1">MilkDrop visualizer</h2>
        <p class="text-base text-fg-2 m-0 max-w-[640px]">
          Full-screen MilkDrop presets on the HDMI output's TV, picked with the
          "TV display mode" select in Home Assistant. These settings apply to every session.
        </p>
      </div>

      <.card padding={:none} class="overflow-hidden">
        <%!-- Preset pack --%>
        <div class="flex items-start gap-4 p-[20px_22px]">
          <div
            id={"#{@id}-pack-icon"}
            data-icon={@view.icon}
            aria-hidden="true"
            class={[
              "flex-none w-11 h-11 rounded-[10px] flex items-center justify-center select-none",
              tile_classes(@view.variant)
            ]}
          >
            <.icon name={@view.icon} size={22} stroke={1.7} />
          </div>

          <div class="flex-1 min-w-0">
            <div class="flex items-center gap-2.5 flex-wrap">
              <span class="text-md font-semibold">Preset pack</span>
              <.badge variant={@view.variant} dot>{@view.label}</.badge>
            </div>
            <div id={"#{@id}-pack-hint"} class="text-xs text-fg-3 mt-1">{@view.hint}</div>

            <div :if={@view.pct} class="mt-3">
              <div
                id={"#{@id}-pack-progress"}
                role="progressbar"
                aria-label="Preset pack download"
                aria-valuemin="0"
                aria-valuemax="100"
                aria-valuenow={@view.pct}
                class="h-2 rounded-full bg-sunken overflow-hidden"
              >
                <div
                  class="h-full rounded-full bg-accent transition-[width] duration-300 ease-standard"
                  style={"width: #{@view.pct}%"}
                >
                </div>
              </div>
              <div class="text-sm text-fg-3 mt-1.5 tabular-nums">{@view.pct}%</div>
            </div>
          </div>

          <.button
            :if={@view.action}
            id={"#{@id}-ensure"}
            variant={:primary}
            size={:sm}
            phx-click="ensure_pack"
            phx-target={@myself}
            disabled={@ensuring}
          >
            <.icon name={if @view.action == "Retry", do: :refresh, else: :download} size={14} />
            {@view.action}
          </.button>
        </div>

        <%!-- Rotation interval: on the surface, like the volume row, so the
             slider's unfilled (sunken) track stays visible --%>
        <div class="flex items-center gap-3 pt-1 pr-5 pb-4 pl-[22px]">
          <label for={"#{@id}-rotate"} class="text-sm text-fg-2 flex-none">Change preset every</label>
          <form
            id={"#{@id}-rotate-form"}
            phx-change="set_rotate"
            phx-submit="set_rotate"
            phx-target={@myself}
            class="flex-1 min-w-0"
          >
            <input
              type="range"
              id={"#{@id}-rotate"}
              name="rotate_s"
              min={@rotate_min}
              max={@rotate_max}
              step="5"
              value={@settings.rotate_s}
              phx-debounce="300"
              class="audio-volume"
              style={"--vol: #{rotate_pct(@settings.rotate_s)};"}
              aria-valuetext={"#{@settings.rotate_s} seconds"}
            />
          </form>
          <div class="text-md font-semibold font-mono tabular-nums text-fg-1 min-w-12 text-right">
            {@settings.rotate_s} s
          </div>
        </div>

        <%!-- Minimum frame rate --%>
        <form
          id={"#{@id}-min-fps-form"}
          phx-change="set_min_fps"
          phx-target={@myself}
          class="flex items-center gap-3 pt-3 pr-5 pb-3 pl-[22px] border-t border-border-2"
        >
          <div class="flex-1 min-w-0">
            <label for={"#{@id}-min-fps"} class="text-sm text-fg-2">Minimum frame rate</label>
            <div class="text-xs text-fg-3 mt-0.5">Presets that can't hold this rate are skipped.</div>
          </div>
          <select
            id={"#{@id}-min-fps"}
            name="min_fps"
            class="h-9 px-3 rounded-md text-sm border border-border-strong bg-surface text-fg-1 outline-none focus:border-accent focus:shadow-focus"
          >
            <option :for={fps <- @min_fps_options} value={fps} selected={fps == @settings.min_fps}>
              {fps} fps
            </option>
          </select>
        </form>

        <%!-- Fast-flashing presets --%>
        <div class="flex items-center gap-3 pt-3 pr-5 pb-3 pl-[22px] border-t border-border-2 bg-sunken">
          <.toggle
            checked={@settings.include_high_frequency}
            phx-click="toggle_high_frequency"
            phx-target={@myself}
            id={"#{@id}-high-frequency"}
            aria-label="Include fast-flashing presets"
          />
          <div class="flex-1 min-w-0">
            <div class="text-sm text-fg-2">Include fast-flashing presets</div>
            <div class="text-xs text-fg-3 mt-0.5">
              Off by default. These presets flash rapidly and can be uncomfortable or unsafe to watch.
            </div>
          </div>
        </div>

        <%!-- Skipped presets --%>
        <div class="border-t border-border-2 bg-sunken">
          <div class="flex items-center gap-3 pt-3 pr-5 pb-3 pl-[22px]">
            <button
              type="button"
              id={"#{@id}-skipped-toggle"}
              phx-click="toggle_skipped"
              phx-target={@myself}
              aria-expanded={"#{@skipped_open}"}
              aria-controls={"#{@id}-skipped-list"}
              disabled={@skipped_list == []}
              class="flex items-center gap-2 text-sm text-fg-2 bg-transparent border-none p-0 cursor-pointer
                     disabled:cursor-default"
            >
              <.icon
                :if={@skipped_list != []}
                name={:chevron}
                size={12}
                stroke={2.2}
                class={"transition-transform #{if @skipped_open, do: "rotate-180", else: ""}"}
              />
              <span id={"#{@id}-skipped-count"} class="whitespace-nowrap">{skipped_label(length(@skipped_list))}</span>
            </button>
            <div class="flex-1"></div>
            <.button
              :if={@skipped_list != []}
              id={"#{@id}-clear-skipped"}
              variant={:ghost}
              size={:sm}
              phx-click="clear_skipped"
              phx-target={@myself}
            >
              Clear skipped presets
            </.button>
          </div>

          <div
            :if={@skipped_open and @skipped_list != []}
            id={"#{@id}-skipped-list"}
            class="px-[22px] pb-3.5 grid grid-cols-[1fr_auto] gap-x-3 gap-y-1 text-[11px]"
          >
            <%= for {preset, reason} <- @skipped_list do %>
              <span class="font-mono text-fg-2 truncate" title={preset}>{preset}</span>
              <span class="text-fg-3" title={reason}>{reason_label(reason)}</span>
            <% end %>
            <span class="col-span-2 text-fg-4 mt-1">
              Skipped presets are left out of the rotation. Cleared presets return from the next visualizer session. A new pack version clears the list.
            </span>
          </div>
        </div>

        <div
          :if={@error}
          id={"#{@id}-error"}
          role="alert"
          class="px-[22px] py-2 border-t border-border-2 bg-danger-soft text-danger text-xs"
        >
          {@error}
        </div>
      </.card>

      <.modal
        open={@confirm_hf}
        id={"#{@id}-confirm-high-frequency"}
        on_close="cancel_high_frequency"
        target={@myself}
        title="Include fast-flashing presets?"
        subtitle="Photosensitivity warning"
      >
        <div class="p-[10px_12px] rounded-md bg-warning-soft text-warning text-sm font-medium flex items-start gap-2">
          <.icon name={:alert} size={16} stroke={2.0} class="mt-0.5 flex-none" />
          <span>
            These presets flash rapidly and may trigger seizures in people with photosensitive epilepsy.
          </span>
        </div>
        <p class="text-sm text-fg-2 mt-3 mb-0">
          Leave them off if anyone who may see the TV is sensitive to flashing lights.
        </p>
        <:footer>
          <.button variant={:ghost} size={:sm} phx-click="cancel_high_frequency" phx-target={@myself}>
            Cancel
          </.button>
          <.button
            id={"#{@id}-confirm-high-frequency-button"}
            variant={:danger}
            size={:sm}
            phx-click="confirm_high_frequency"
            phx-target={@myself}
          >
            Include them
          </.button>
        </:footer>
      </.modal>
    </section>
    """
  end

  defp rotate_pct(seconds), do: round((seconds - @rotate_min) * 100 / (@rotate_max - @rotate_min))

  defp skipped_list({:ready, _version, _dir}, skipped),
    do: Enum.sort_by(skipped, fn {preset, _reason} -> preset end)

  defp skipped_list(_pack, _skipped), do: []

  defp skipped_label(0), do: "No skipped presets"
  defp skipped_label(1), do: "1 skipped preset"
  defp skipped_label(n), do: "#{n} skipped presets"

  defp pack_view(:absent) do
    %{
      label: "Not downloaded",
      variant: :neutral,
      hint: "The preset pack downloads on first use, or now with Download.",
      action: "Download",
      icon: :package,
      pct: nil
    }
  end

  defp pack_view({:downloading, pct}) do
    %{
      label: "Downloading",
      variant: :accent,
      hint: "Downloading and verifying the preset pack.",
      action: nil,
      icon: :clock,
      pct: pct
    }
  end

  defp pack_view({:ready, version, _dir}) do
    %{
      label: "Ready",
      variant: :success,
      hint: "Version #{version}",
      action: nil,
      icon: :check,
      pct: nil
    }
  end

  defp pack_view({:retrying, reason, next_in_ms}) do
    %{
      label: "Retrying",
      variant: :warning,
      hint: retry_hint(reason, next_in_ms),
      action: "Retry",
      icon: :clock,
      pct: nil
    }
  end

  defp pack_view({:error, reason}) do
    %{
      label: "Failed",
      variant: :danger,
      hint: pack_error(reason),
      action: "Retry",
      icon: :alert,
      pct: nil
    }
  end

  defp pack_view(_other), do: pack_view({:error, :unknown})

  # The status tile is decoration (no hover, aria-hidden); the only action
  # is the Download/Retry button.
  defp tile_classes(:success), do: "bg-success-soft text-success"
  defp tile_classes(:accent), do: "bg-accent-soft text-accent"
  defp tile_classes(:warning), do: "bg-warning-soft text-warning"
  defp tile_classes(:danger), do: "bg-danger-soft text-danger"
  defp tile_classes(_neutral), do: "bg-sunken text-fg-3"

  defp retry_hint(:network_down, _ms), do: "Waiting for network…"

  defp retry_hint({:transport, _reason}, ms),
    do: "Waiting for network… retrying in #{retry_seconds(ms)} s."

  defp retry_hint(reason, ms),
    do: "#{pack_error(reason)} Retrying in #{retry_seconds(ms)} s."

  defp retry_seconds(ms) when is_integer(ms), do: max(div(ms + 999, 1000), 1)
  defp retry_seconds(_ms), do: 1

  defp pack_error(:not_running), do: "The visualizer service isn't running."
  defp pack_error(:no_pack_pinned), do: "This firmware doesn't pin a preset pack."
  defp pack_error(:invalid_pin), do: "This firmware's preset pack pin is invalid."
  defp pack_error(:checksum_mismatch), do: "The download didn't match its checksum."
  defp pack_error(:bad_range), do: "The server sent the wrong part of the file."
  defp pack_error(:missing_manifest), do: "The pack has no manifest."
  defp pack_error({:unsafe_entry, name}), do: "The pack holds an unsafe entry: #{name}"
  defp pack_error({:http_status, status}), do: "The server answered HTTP #{status}."
  defp pack_error({:transport, reason}), do: "Network error: #{inspect(reason)}"
  defp pack_error({:io, posix}), do: "Storage error: #{inspect(posix)}"
  defp pack_error({:crashed, _reason}), do: "The download stopped unexpectedly."
  defp pack_error(reason), do: "Download failed: #{inspect(reason)}"

  defp store_error(:not_running), do: "the settings store isn't running"
  defp store_error(reason), do: inspect(reason)

  defp reason_label("too_bright"), do: "Too bright"
  defp reason_label("budget"), do: "Too slow for this device"
  defp reason_label("compile_error"), do: "Shader failed to compile"
  defp reason_label("shader_error"), do: "Shader failed to compile"
  defp reason_label("register_allocate"), do: "Too complex for the GPU"
  defp reason_label("load_failed"), do: "Failed to load"
  defp reason_label("draw_dropped"), do: "Failed to draw"
  defp reason_label("device_reset"), do: "Reset the device"
  defp reason_label("gpu_hang"), do: "Hung the GPU"
  defp reason_label("hang"), do: "Froze the renderer"
  defp reason_label("crashed"), do: "Crashed the renderer"
  defp reason_label(reason), do: reason
end
