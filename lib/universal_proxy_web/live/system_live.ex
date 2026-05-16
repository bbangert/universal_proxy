defmodule UniversalProxyWeb.SystemLive do
  @moduledoc """
  System tab — firmware version, health stats, system log, reboot.

  All data comes from `UniversalProxy.System`, which reads from
  `Nerves.Runtime.KV`, `/proc`, sysfs, `VintageNet`, and `RingLogger`.
  Health stats and the log refresh on a 2 s tick.
  """

  use UniversalProxyWeb, :live_view

  import UniversalProxyWeb.Components.UI
  import UniversalProxyWeb.Components.Icons

  alias UniversalProxy.System, as: Sys
  alias UniversalProxy.FirmwareUpdate

  @refresh_interval 2_000
  @log_window 80

  # Captured at compile time; `Mix.target/0` is a build-time tool and
  # isn't loaded in mix releases on Nerves.
  @target Mix.target()
  @show_fw_actions @target != :host

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@refresh_interval, self(), :refresh)
      Phoenix.PubSub.subscribe(FirmwareUpdate.pubsub(), FirmwareUpdate.topic())
    end

    {entries, since} = Sys.recent_log(count: @log_window)

    {:ok,
     socket
     |> assign(:page_title, "System")
     |> assign(:firmware, Sys.firmware_info())
     |> assign(:health, Sys.health())
     |> assign(:sys_log, entries)
     |> assign(:log_since, since)
     |> assign(:rebooting, false)
     |> assign(:confirm_reboot, false)
     |> assign(:fw_update, FirmwareUpdate.state())
     |> assign(:show_fw_actions, @show_fw_actions)
     |> assign(:show_release_notes, false)}
  end

  @impl true
  def handle_event("reboot_clicked", _params, socket) do
    {:noreply, assign(socket, :confirm_reboot, true)}
  end

  def handle_event("cancel_reboot", _params, socket) do
    {:noreply, assign(socket, :confirm_reboot, false)}
  end

  def handle_event("confirm_reboot", _params, socket) do
    # Schedule the reboot a beat later so the flash + UI state get a
    # chance to render before the BEAM goes down.
    Process.send_after(self(), :do_reboot, 400)

    {:noreply,
     socket
     |> assign(:confirm_reboot, false)
     |> assign(:rebooting, true)
     |> put_flash(:info, "Rebooting — back in about 25 seconds.")}
  end

  def handle_event("fw_check", _params, socket) do
    case FirmwareUpdate.check() do
      :ok ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Check failed: #{inspect(reason)}")}
    end
  end

  def handle_event("fw_install", _params, socket) do
    case FirmwareUpdate.install_latest() do
      :ok ->
        {:noreply, assign(socket, :show_release_notes, false)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:show_release_notes, false)
         |> put_flash(:error, "Install failed: #{inspect(reason)}")}
    end
  end

  def handle_event("show_release_notes", _params, socket) do
    {:noreply, assign(socket, :show_release_notes, true)}
  end

  def handle_event("hide_release_notes", _params, socket) do
    {:noreply, assign(socket, :show_release_notes, false)}
  end

  def handle_event("factory_reset", _params, socket) do
    # No factory-reset path implemented yet; surface that explicitly
    # rather than pretending the button works.
    {:noreply,
     put_flash(
       socket,
       :error,
       "Factory reset isn't wired up yet. SSH in and clear /data manually if you really need it."
     )}
  end

  @impl true
  def handle_info(:refresh, socket) do
    if socket.assigns.rebooting do
      {:noreply, socket}
    else
      {new_entries, next_since} =
        Sys.recent_log(since: socket.assigns.log_since, count: @log_window)

      sys_log =
        (socket.assigns.sys_log ++ new_entries) |> Enum.take(-@log_window)

      {:noreply,
       socket
       |> assign(:health, Sys.health())
       |> assign(:sys_log, sys_log)
       |> assign(:log_since, next_since)}
    end
  end

  def handle_info(:do_reboot, socket) do
    Sys.reboot()
    {:noreply, socket}
  end

  def handle_info({:fw_update_progress, payload}, socket) do
    fw = Map.merge(socket.assigns.fw_update, payload)
    # Refresh the cached last_release / verification_required from the
    # source whenever idle, so the UI sees the freshly-fetched release.
    fw =
      if payload[:phase] == :idle do
        FirmwareUpdate.state()
      else
        fw
      end

    {:noreply, assign(socket, :fw_update, fw)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-[860px] mx-auto space-y-4">
      <%!-- Firmware + Health --%>
      <div class="grid grid-cols-2 gap-4">
        <.card padding={:lg}>
          <.eyebrow class="mb-2.5">Firmware</.eyebrow>
          <div class="flex items-baseline gap-2.5 flex-wrap">
            <div class="text-xl font-semibold tabular-nums">{@firmware.version}</div>
            <.badge :if={@firmware.validated} variant={:success} dot>Validated</.badge>
            <.badge :if={!@firmware.validated} variant={:warning} dot>Pending validation</.badge>
            <.badge
              :if={update_available?(@fw_update, @firmware)}
              variant={:accent}
              dot
            >
              Update available
            </.badge>
            <.badge
              :if={fw_up_to_date?(@fw_update, @firmware)}
              variant={:success}
              dot
            >
              Up to date
            </.badge>
            <.badge
              :if={!@fw_update.verification_required}
              variant={:warning}
              dot
            >
              Signature checks disabled
            </.badge>
          </div>
          <div
            :if={@fw_update.last_release}
            class="text-xs text-fg-3 mt-1"
          >
            Latest: <span class="font-mono">{@fw_update.last_release.tag_name}</span>
            <span :if={@fw_update.last_release.published_at}>
              · {format_date(@fw_update.last_release.published_at)}
            </span>
          </div>
          <div :if={@firmware.uuid} class="text-sm text-fg-3 mt-1">
            UUID <span class="font-mono">{short_uuid(@firmware.uuid)}</span>
            <span :if={@firmware.vcs_identifier}>
              · commit <span class="font-mono">{@firmware.vcs_identifier}</span>
            </span>
          </div>
          <div class="mt-3 pt-3 border-t border-border-2 grid grid-cols-2 gap-y-2 text-sm">
            <div>
              <div class="text-fg-3 uppercase tracking-wide font-semibold text-[10px]">
                Target
              </div>
              <div class="font-mono text-fg-1 mt-0.5">{@firmware.target}</div>
            </div>
            <div>
              <div class="text-fg-3 uppercase tracking-wide font-semibold text-[10px]">
                Architecture
              </div>
              <div class="font-mono text-fg-1 mt-0.5">{@firmware.architecture || "—"}</div>
            </div>
            <div class="col-span-2">
              <div class="text-fg-3 uppercase tracking-wide font-semibold text-[10px]">
                Hardware
              </div>
              <div class="text-fg-1 mt-0.5">{@firmware.hardware}</div>
            </div>
          </div>

          <div
            :if={@fw_update.phase in [:downloading, :verifying, :flashing]}
            class="mt-3"
          >
            <div class="text-xs text-fg-3 mb-1">{@fw_update.message}</div>
            <progress
              class="w-full h-1.5"
              max="100"
              value={@fw_update.pct || 0}
            >
            </progress>
          </div>

          <div
            :if={@fw_update.phase == :error}
            class="mt-3 px-3 py-2 rounded border border-danger/40 bg-danger/5 text-sm text-danger"
          >
            {@fw_update.message}
          </div>

          <div :if={@show_fw_actions} class="mt-4 flex gap-2 flex-wrap">
            <.button
              variant={:secondary}
              size={:sm}
              phx-click="fw_check"
              disabled={
                @fw_update.phase in [:checking, :downloading, :verifying, :flashing]
              }
            >
              <.icon name={:refresh} size={14} class="mr-1.5" />
              {check_button_label(@fw_update.phase)}
            </.button>
            <.button
              :if={update_available?(@fw_update, @firmware)}
              variant={:primary}
              size={:sm}
              phx-click="fw_install"
              disabled={
                @fw_update.phase in [:checking, :downloading, :verifying, :flashing]
              }
            >
              Install update
            </.button>
            <.button
              :if={@fw_update.last_release}
              variant={:ghost}
              size={:sm}
              phx-click="show_release_notes"
            >
              Release notes
            </.button>
          </div>
        </.card>

        <.card padding={:lg}>
          <.eyebrow class="mb-2.5">Health</.eyebrow>
          <div class="grid grid-cols-2 gap-y-3">
            <.stat_line label="Uptime" value={@health.uptime} />
            <.stat_line label="Load avg" value={@health.load_avg} />
            <.stat_line label="Memory" value={@health.memory} />
            <.stat_line label="CPU temperature" value={@health.cpu_temp} />
            <.stat_line label="Storage" value={@health.storage} />
            <.stat_line label="Network" value={@health.network} />
          </div>
        </.card>
      </div>

      <%!-- System log --%>
      <.card padding={:none} class="overflow-hidden">
        <div class="flex items-center gap-2.5 px-4 py-3 border-b border-border-1 text-sm font-semibold">
          <.icon name={:logs} size={16} /> System log
          <div class="flex-1"></div>
          <span class="text-xs text-fg-3 font-normal">{length(@sys_log)} lines</span>
        </div>
        <div class="px-3.5 py-2.5 max-h-[260px] overflow-auto bg-sunken font-mono text-xs leading-[1.55]">
          <div
            :if={@sys_log == []}
            class="text-center text-fg-4 py-8 font-sans text-sm"
          >
            No log entries yet.
          </div>
          <div :for={entry <- @sys_log} class="flex gap-3">
            <span class="text-fg-4 w-[150px] flex-none">{entry.timestamp}</span>
            <span class={[
              "w-14 flex-none font-semibold",
              log_level_class(entry.level)
            ]}>
              {entry.level}
            </span>
            <span class="text-fg-1 break-all">{entry.message}</span>
          </div>
        </div>
      </.card>

      <%!-- Power --%>
      <.card padding={:lg}>
        <.eyebrow class="mb-2.5">Power</.eyebrow>
        <div class="grid grid-cols-2 gap-3">
          <div class="flex items-center gap-3 p-3.5 border border-border-1 rounded-md">
            <div class="flex-1">
              <div class="text-base font-semibold">Reboot</div>
              <div class="text-sm text-fg-3 mt-0.5">
                Takes about 25 seconds. All connected integrations will briefly disconnect.
              </div>
            </div>
            <.button
              variant={:secondary}
              size={:sm}
              phx-click="reboot_clicked"
              disabled={@rebooting}
            >
              {if @rebooting, do: "Rebooting…", else: "Reboot"}
            </.button>
          </div>
          <div class="flex items-center gap-3 p-3.5 border border-border-1 rounded-md">
            <div class="flex-1">
              <div class="text-base font-semibold text-danger">Factory reset</div>
              <div class="text-sm text-fg-3 mt-0.5">
                Wipes settings, keys, and paired Z-Wave network. Can't be undone.
              </div>
            </div>
            <.button variant={:danger} size={:sm} phx-click="factory_reset">Reset…</.button>
          </div>
        </div>
      </.card>
    </div>

    <.modal
      open={@confirm_reboot}
      on_close="cancel_reboot"
      title="Reboot the proxy?"
      subtitle="We'll disconnect Home Assistant briefly. Any active Z-Wave pairings will stop."
    >
      <:footer>
        <.button variant={:ghost} size={:sm} phx-click="cancel_reboot">Cancel</.button>
        <.button variant={:primary} size={:sm} phx-click="confirm_reboot">Reboot now</.button>
      </:footer>
    </.modal>

    <.modal
      :if={@fw_update.last_release}
      open={@show_release_notes}
      on_close="hide_release_notes"
      title={@fw_update.last_release.tag_name}
      subtitle={"Released " <> format_date(@fw_update.last_release.published_at)}
    >
      <div class="max-h-[60vh] overflow-auto whitespace-pre-wrap text-sm font-mono">
        {@fw_update.last_release.body}
      </div>
      <:footer>
        <.button variant={:ghost} size={:sm} phx-click="hide_release_notes">Close</.button>
        <.button
          :if={update_available?(@fw_update, @firmware)}
          variant={:primary}
          size={:sm}
          phx-click="fw_install"
        >
          Install now
        </.button>
      </:footer>
    </.modal>
    """
  end

  defp short_uuid(nil), do: ""
  defp short_uuid(uuid) when is_binary(uuid), do: uuid |> String.slice(0, 8)

  defp log_level_class("WARN"), do: "text-warning"
  defp log_level_class("ERROR"), do: "text-danger"
  defp log_level_class(_), do: "text-fg-3"

  defp check_button_label(:idle), do: "Check for updates"
  defp check_button_label(:checking), do: "Checking…"
  defp check_button_label(:downloading), do: "Downloading…"
  defp check_button_label(:verifying), do: "Verifying…"
  defp check_button_label(:flashing), do: "Installing…"
  defp check_button_label(:error), do: "Check for updates"
  defp check_button_label(_), do: "Check for updates"

  defp update_available?(%{last_release: nil}, _firmware), do: false

  defp update_available?(%{last_release: %{tag_name: tag}}, %{version: current}) do
    normalize(tag) != normalize(current)
  end

  defp fw_up_to_date?(%{last_release: nil}, _), do: false

  defp fw_up_to_date?(%{last_release: %{tag_name: tag}}, %{version: current}) do
    normalize(tag) == normalize(current)
  end

  defp normalize(nil), do: nil
  defp normalize("v" <> rest), do: rest
  defp normalize(s) when is_binary(s), do: s

  defp format_date(nil), do: ""

  defp format_date(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%Y-%m-%d")
      _ -> iso
    end
  end
end
