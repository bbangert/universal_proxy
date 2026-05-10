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

  @refresh_interval 2_000
  @log_window 80

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@refresh_interval, self(), :refresh)
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
     |> assign(:confirm_reboot, false)}
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
    """
  end

  defp short_uuid(nil), do: ""
  defp short_uuid(uuid) when is_binary(uuid), do: uuid |> String.slice(0, 8)

  defp log_level_class("WARN"), do: "text-warning"
  defp log_level_class("ERROR"), do: "text-danger"
  defp log_level_class(_), do: "text-fg-3"
end
