defmodule UniversalProxyWeb.SecurityLive do
  @moduledoc """
  Security tab — ESPHome Native API encryption and SSH access.

  Encryption is connection-driven, not a manual toggle. The native API
  starts in **plaintext**; the first time Home Assistant connects it
  provisions a 32-byte Noise pre-shared key, which `ESPHome.PskStore`
  persists. From then on the session is encrypted and the key is retained
  (it survives reboots via DETS). The page reads the current key from
  `PskStore` and subscribes to its PubSub topic, so it flips to "Enforced"
  live the moment HA provisions.

  The only manual control is **Reset**: it clears the persisted key and
  restarts the ESPHome subtree, returning the proxy to plaintext so the next
  client re-negotiates a fresh encrypted session. The device never mints a
  key; encrypted ⇔ a key is present.

  The SSH access card (private-key download + fingerprint) is independent.
  """

  use UniversalProxyWeb, :live_view

  require Logger

  # Filename suggested to the browser for the downloaded private key, and the
  # `-i` identity referenced in the login command shown on the card.
  @private_key_filename "universal_proxy"

  import UniversalProxyWeb.Components.UI
  import UniversalProxyWeb.Components.Icons

  alias UniversalProxy.ESPHome.PskStore
  alias UniversalProxy.SSHAccess

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket),
      do: Phoenix.PubSub.subscribe(UniversalProxy.PubSub, PskStore.topic())

    {:ok,
     socket
     |> assign(:page_title, "Security")
     |> assign(:psk, current_psk())
     |> assign(:show_key, false)
     |> assign(:copied, nil)
     |> assign(:pending_reset, false)
     |> assign(:ssh_fingerprint, ssh_fingerprint())
     |> assign(:ssh_key_type, SSHAccess.key_type())
     |> assign(:ssh_command, ssh_command())
     |> assign(:ssh_copied, false)}
  end

  # Tolerate the PSK store being momentarily down (e.g. restarting after a
  # Reset) so the page renders as plaintext instead of crashing the LiveView.
  defp current_psk do
    PskStore.load_psk()
  catch
    :exit, _ -> nil
  end

  # The login command an operator runs after downloading the private key.
  # `:inet.gethostname/0` is spec'd to always return `{:ok, hostname}`.
  defp ssh_command do
    {:ok, hostname} = :inet.gethostname()
    "ssh -i #{@private_key_filename} root@#{hostname}.local"
  end

  # Tolerate the SSHAccess server being momentarily down (e.g. restarting) so
  # the page renders instead of crashing the LiveView.
  defp ssh_fingerprint do
    SSHAccess.fingerprint()
  catch
    :exit, _ -> "unavailable — key service restarting"
  end

  @impl true
  def handle_event("toggle_show_key", _params, socket) do
    {:noreply, assign(socket, :show_key, !socket.assigns.show_key)}
  end

  # Guard against a stale client event arriving after the key was cleared
  # server-side: Base.encode64(nil) would crash the LiveView.
  def handle_event("copy_key", _params, %{assigns: %{psk: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("copy_key", _params, socket) do
    Process.send_after(self(), :reset_copied, 2_000)

    {:noreply,
     socket
     |> assign(:copied, true)
     |> push_event("copy", %{text: Base.encode64(socket.assigns.psk)})}
  end

  def handle_event("reset_request", _params, socket) do
    {:noreply, assign(socket, :pending_reset, true)}
  end

  def handle_event("cancel_reset", _params, socket) do
    {:noreply, assign(socket, :pending_reset, false)}
  end

  def handle_event("confirm_reset", _params, socket) do
    # Clear the persisted key, then restart the ESPHome subtree so it
    # re-reads device_config with no PSK (plaintext, awaiting a fresh
    # provision). A tagged {:error, _} from either step (e.g. a DETS write
    # failure or a failed child restart) must surface as an error flash, not
    # the success path.
    with :ok <- PskStore.clear(),
         {:ok, _pid} <- UniversalProxy.ESPHome.Supervisor.restart() do
      {:noreply,
       socket
       |> assign(:pending_reset, false)
       |> assign(:psk, nil)
       |> assign(:show_key, false)
       |> put_flash(
         :info,
         "Encryption reset. The next client to connect starts a fresh encrypted session."
       )}
    else
      other ->
        Logger.error("ESPHome encryption reset failed: #{inspect(other)}")
        {:noreply, reset_failed(socket)}
    end
  catch
    :exit, _ -> {:noreply, reset_failed(socket)}
  end

  def handle_event("copy_fingerprint", _params, socket) do
    # Recompute on click: the mount-time value may have been the
    # "unavailable" placeholder if SSHAccess was momentarily down. Refresh
    # the assign too so the on-screen readout self-corrects.
    fingerprint = ssh_fingerprint()
    Process.send_after(self(), :reset_ssh_copied, 1_600)

    {:noreply,
     socket
     |> assign(:ssh_fingerprint, fingerprint)
     |> assign(:ssh_copied, true)
     |> push_event("copy", %{text: fingerprint})}
  end

  def handle_event("download_ssh_key", _params, socket) do
    {:noreply,
     push_event(socket, "download", %{
       content: SSHAccess.private_key(),
       filename: @private_key_filename
     })}
  catch
    :exit, _ ->
      {:noreply,
       put_flash(socket, :error, "SSH key service is unavailable — try again in a moment.")}
  end

  defp reset_failed(socket) do
    socket
    |> assign(:pending_reset, false)
    |> put_flash(:error, "Couldn't reset encryption — try again in a moment.")
  end

  @impl true
  def handle_info({:esphome_psk, psk}, socket) do
    {:noreply, assign(socket, :psk, psk)}
  end

  def handle_info(:reset_copied, socket) do
    {:noreply, assign(socket, :copied, false)}
  end

  def handle_info(:reset_ssh_copied, socket) do
    {:noreply, assign(socket, :ssh_copied, false)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :encrypted, assigns.psk != nil)

    ~H"""
    <div class="max-w-[720px] mx-auto">
      <div class="mb-6">
        <.eyebrow>Security</.eyebrow>
        <h2 class="text-xl font-semibold mt-1 mb-1.5 text-fg-1">Keep the proxy locked down</h2>
        <p class="text-base text-fg-2 m-0">
          The native API encrypts itself automatically once Home Assistant connects. Below you can
          copy the active key or reset back to plaintext for a fresh negotiation.
        </p>
      </div>

      <.card padding={:lg}>
        <div class="flex items-start gap-4">
          <div class={[
            "w-9 h-9 rounded-sm flex items-center justify-center flex-none",
            if(@encrypted, do: "bg-accent-soft text-accent", else: "bg-sunken text-fg-3")
          ]}>
            <.icon name={:lock} size={18} />
          </div>
          <div class="flex-1">
            <div class="text-base font-semibold">API encryption</div>
            <div class="text-sm text-fg-3 mt-0.5">
              {if @encrypted,
                do: "Native API traffic is encrypted with a 32-byte pre-shared key.",
                else: "Off by default. Native API traffic is sent in the clear on your LAN."}
            </div>
          </div>
          <.badge :if={@encrypted} variant={:success} dot>Enforced</.badge>
          <.badge :if={!@encrypted} variant={:neutral} dot>Off</.badge>
        </div>

        <div :if={@encrypted}>
          <div class="mt-4 text-sm font-semibold text-fg-2">Pre-shared key</div>
          <div class="text-sm text-fg-3 mt-0.5 mb-2">
            Paste into <span class="font-mono">api: encryption: key:</span>
            in your Home Assistant config.
          </div>
          <div class="flex gap-2">
            <input
              type={if @show_key, do: "text", else: "password"}
              readonly
              value={Base.encode64(@psk)}
              class="flex-1 h-9 px-3 rounded-md text-xs font-mono outline-none bg-sunken text-fg-2 border border-border-strong"
            />
            <.button variant={:secondary} size={:sm} phx-click="toggle_show_key">
              {if @show_key, do: "Hide", else: "Show"}
            </.button>
            <.button variant={:secondary} size={:sm} phx-click="copy_key">
              <.icon name={:check} size={14} /> {if @copied, do: "Copied", else: "Copy"}
            </.button>
          </div>

          <div class="mt-4 pt-4 border-t border-border-2 flex items-start gap-3">
            <div class="flex-1">
              <div class="text-[13px] font-semibold text-fg-1">Reset encryption</div>
              <div class="text-sm text-fg-3 mt-0.5">
                Clears the key and returns the proxy to plaintext, ready for a fresh connection.
              </div>
            </div>
            <.button variant={:danger} size={:sm} phx-click="reset_request">
              <.icon name={:refresh} size={14} /> Reset
            </.button>
          </div>
        </div>

        <div
          :if={!@encrypted}
          class="mt-4 px-3 py-2.5 bg-sunken rounded-sm text-sm flex gap-2 items-start text-fg-2"
        >
          <.icon name={:info} size={14} stroke={2.0} />
          <span>
            Native API traffic is in the clear on your LAN until the first client connects.
            Encryption turns on automatically as soon as Home Assistant connects — no key to paste.
          </span>
        </div>
      </.card>

      <.card padding={:lg} class="mt-4">
        <div class="flex items-start gap-4">
          <div class="w-9 h-9 rounded-sm flex items-center justify-center flex-none bg-sunken text-fg-2">
            <.icon name={:lock} size={18} />
          </div>
          <div class="flex-1">
            <div class="text-base font-semibold">SSH access</div>
            <div class="text-sm text-fg-3 mt-0.5">
              Download the proxy's private key, add it to your SSH client, and open a shell on the
              device.
            </div>
          </div>
          <.badge variant={:neutral} dot>{@ssh_key_type}</.badge>
        </div>

        <div class="mt-3.5 text-sm font-semibold text-fg-2">Access key fingerprint</div>
        <div class="text-sm text-fg-3 mt-0.5 mb-2">
          Verify this matches the key you download before you trust the connection.
        </div>
        <div class="flex gap-2">
          <input
            type="text"
            readonly
            value={@ssh_fingerprint}
            class="flex-1 h-9 px-3 rounded-md text-xs font-mono outline-none bg-sunken text-fg-2 border border-border-strong"
          />
          <.button variant={:secondary} size={:sm} phx-click="copy_fingerprint">
            <.icon name={:check} size={14} /> {if @ssh_copied, do: "Copied", else: "Copy"}
          </.button>
          <.button variant={:primary} size={:sm} phx-click="download_ssh_key">
            <.icon name={:download} size={14} /> Download key
          </.button>
        </div>
        <div class="mt-3 px-3 py-2.5 bg-sunken rounded-sm font-mono text-sm text-fg-2 overflow-x-auto">
          {@ssh_command}
        </div>
      </.card>

      <.modal
        open={@pending_reset}
        on_close="cancel_reset"
        title="Reset API encryption?"
        subtitle="Home Assistant will disconnect, then re-negotiate."
      >
        <p class="text-sm text-fg-2 m-0">
          This deletes the current pre-shared key and drops the native API back to plaintext. Home
          Assistant will disconnect, then re-negotiate a brand-new encrypted session the next time
          it connects.
        </p>
        <:footer>
          <.button variant={:ghost} size={:sm} phx-click="cancel_reset">Cancel</.button>
          <.button variant={:danger} size={:sm} phx-click="confirm_reset">
            Reset encryption
          </.button>
        </:footer>
      </.modal>
    </div>
    """
  end
end
