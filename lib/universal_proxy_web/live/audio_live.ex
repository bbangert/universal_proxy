defmodule UniversalProxyWeb.AudioLive do
  @moduledoc """
  Audio tab — per-output Sendspin player cards.

  Lists every ALSA output currently surfaced by
  `UniversalProxy.Audio.list_outputs/0` and exposes per-output controls
  for friendly name, volume, mute, and enable/disable. Connection /
  stream / error state from the supervised C++ binary lands here via
  the `"sendspin:state"` PubSub topic and patches the card in place
  without a full re-fetch.

  Subscribes to three topics in `mount/3` so the page stays current:

    * `"sendspin:output_added"`   — new hardware appeared (hotplug)
    * `"sendspin:output_removed"` — hardware went away
    * `"sendspin:state"`          — config change OR binary-emitted event

  The `{slot_sub, vid, pid}` tuple key is opaque in the DOM: encoded as
  URL-safe base64 of `:erlang.term_to_binary/1` and decoded with
  `[:safe]` on the way back in. The shape is asserted post-decode so a
  malformed param surfaces as an ignored event, never as a crash.

  Renames open a confirm modal because every save re-advertises over
  mDNS, which momentarily disconnects any paired Sendspin server. The
  earlier inline-blur rename pattern made accidental clicks user-
  hostile; the modal forces an explicit commit step.

  ## Audio inputs

  Below the outputs grid, a read-only "Audio inputs" section lists
  every USB capture card surfaced by `UniversalProxy.Audio.Input.list_inputs/0`
  (the `source@v1` mirror of the outputs above). It subscribes to the
  three `"sendspin:input_*"` topics `Audio.Input.Server` owns, keyed by
  the same `{slot_sub, vid, pid}` tuple and the same base64 encode/decode
  helpers as the outputs above.

  Pairing requires an explicit local consent gesture: an "Allow pairing"
  button opens a time-boxed window on the source (`Audio.Input.allow_pairing/1`)
  before it will answer Music Assistant's pairing offer. Once pairing runs, the
  device DISPLAYS the derived PIN and the operator types it into Music
  Assistant — never the other way around. `:pairing` status therefore renders
  one of: the "Allow pairing" button (offer pending, no window), an active
  "waiting" state (window open), or the PIN (once derived).
  """

  use UniversalProxyWeb, :live_view

  require Logger

  import UniversalProxyWeb.Components.UI
  import UniversalProxyWeb.Components.Icons
  import UniversalProxyWeb.Components.Audio

  alias UniversalProxy.Audio
  alias UniversalProxy.Audio.Input
  alias UniversalProxy.Bluetooth
  alias UniversalProxy.Bluetooth.AudioManager

  # How long a Bluetooth output keeps a "Reconnecting" placeholder card
  # after its PCM vanishes (a BT disconnect removes the ALSA PCM, like a
  # USB unplug). If the headset reconnects within this window the real
  # card replaces the placeholder; otherwise the card disappears and the
  # device lives on as Disconnected on the Bluetooth tab (its durable
  # home — see the plan's Open decision #1).
  @bt_reconnect_grace_ms 20_000

  # mDNS TXT record total size cap is 255 bytes; we use ~64 chars to
  # leave headroom for the `name=` prefix and any other TXT attrs the
  # binary advertises. Control chars (< 0x20, DEL 0x7F) would break the
  # TXT wire format and also have no business in a user-facing name.
  @friendly_name_max 64

  @impl true
  def mount(_params, _session, socket) do
    outputs = Audio.list_outputs()
    # Synchronous GenServer read, same reasoning as `Audio.list_outputs/0`
    # above: this is a cheap in-memory lookup, not a DB query, so it needs
    # no `assign_async` — and `Audio.Input.list_inputs/0` already degrades
    # to `[]` (via `catch :exit`) when the input subtree is down.
    inputs = Input.list_inputs()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "sendspin:output_added")
      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "sendspin:output_removed")
      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "sendspin:state")
      # Bluetooth connection events drive the brief "Reconnecting" card.
      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "bluetooth:audio")
      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "sendspin:input_added")
      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "sendspin:input_removed")
      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "sendspin:input_state")
    end

    {:ok,
     socket
     |> assign(:page_title, "Audio")
     |> assign(:friendly_name_max, @friendly_name_max)
     |> assign(:outputs, build_outputs_map(outputs))
     # mac → "hciN" for Bluetooth outputs (the bound-radio pill). Built by
     # joining AudioManager.list_headphones (mac→adapter) with the radio
     # list (adapter→hci); refreshed on output/BT-connection changes.
     |> assign(:bt_meta, build_bt_meta())
     # mac → %{name} placeholders shown while a dropped BT device is
     # reconnecting (keyed by device MAC). Empty on non-BT targets.
     |> assign(:reconnecting, %{})
     # Rename modal state. `rename_target` holds the DOM-encoded key of
     # the card whose name is being edited; `nil` means the modal is
     # closed. `rename_draft` mirrors the input value live (the modal
     # form uses `phx-change="rename_draft"` so every keystroke
     # updates the server-side draft; this drives the live char
     # counter and the save-disabled guard). Cheap enough for a
     # rename surface that isn't a high-throughput input.
     |> assign(:rename_target, nil)
     |> assign(:rename_draft, "")
     # Per-card "more" disclosure (footer chevron expands to show card
     # index + client_id). Tracking as a MapSet keyed on the same
     # encoded ids the cards use.
     |> assign(:more_open, MapSet.new())
     # Audio inputs (capture cards), keyed by the same base64-encoded
     # `{slot_sub, vid, pid}` id the outputs map above uses.
     |> assign(:inputs, build_inputs_map(inputs))}
  end

  @impl true
  def handle_event("open_rename", %{"id" => id}, socket) do
    case fetch_output(socket, id) do
      {:ok, output} ->
        {:noreply,
         socket
         |> assign(:rename_target, id)
         |> assign(:rename_draft, output.friendly_name)}

      {:error, :not_found} ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_rename", _params, socket) do
    {:noreply, close_rename(socket)}
  end

  def handle_event("rename_draft", %{"value" => raw}, socket) do
    {:noreply, assign(socket, :rename_draft, clean_friendly_name(raw))}
  end

  def handle_event("confirm_rename", _params, socket) do
    with id when is_binary(id) <- socket.assigns.rename_target,
         {:ok, key} <- decode_key(id),
         {:ok, output} <- fetch_output(socket, id),
         {:ok, name} <- sanitize_friendly_name(socket.assigns.rename_draft),
         true <- name != output.friendly_name do
      case Audio.update_config(key, %{friendly_name: name}) do
        :ok ->
          {:noreply, close_rename(socket)}

        {:error, reason} ->
          Logger.warning("Audio rename failed for #{inspect(key)}: #{inspect(reason)}")

          {:noreply,
           socket
           |> close_rename()
           |> put_flash(:error, "Rename failed: #{inspect(reason)}")}
      end
    else
      # `name == current name` returns `false` from the guard above —
      # treat as a soft cancel so the user isn't stuck.
      false ->
        {:noreply, close_rename(socket)}

      _ ->
        {:noreply, close_rename(socket)}
    end
  end

  def handle_event("set_volume", %{"key" => id, "value" => value}, socket) do
    with {:ok, key} <- decode_key(id),
         {volume, ""} <- Integer.parse(to_string(value)) do
      # Server-side `Store.clamp_volume/1` re-clamps anyway; this guard
      # just keeps the form from flooding the GenServer with values that
      # will always be clamped to 0 or 100.
      volume = volume |> max(0) |> min(100)

      case Audio.update_config(key, %{volume: volume}) do
        :ok ->
          {:noreply, socket}

        {:error, reason} ->
          Logger.warning("Audio set_volume failed for #{inspect(key)}: #{inspect(reason)}")
          {:noreply, socket}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("toggle_mute", %{"id" => id}, socket) do
    with {:ok, key} <- decode_key(id),
         {:ok, output} <- fetch_output(socket, id) do
      case Audio.update_config(key, %{muted: not output.muted}) do
        :ok -> {:noreply, socket}
        {:error, _} -> {:noreply, socket}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    with {:ok, key} <- decode_key(id),
         {:ok, output} <- fetch_output(socket, id) do
      case Audio.set_enabled(key, not output.enabled) do
        :ok -> {:noreply, socket}
        {:error, _} -> {:noreply, socket}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("toggle_more", %{"id" => id}, socket) do
    {:noreply,
     update(socket, :more_open, fn open ->
       if MapSet.member?(open, id) do
         MapSet.delete(open, id)
       else
         MapSet.put(open, id)
       end
     end)}
  end

  # Operator consent gesture for pairing a capture card. Opens the source's
  # time-boxed "allow pairing" window; the source stays authoritative over what
  # happens next (it still requires MA to type the derived PIN).
  def handle_event("allow_pairing", %{"id" => id}, socket) do
    case decode_key(id) do
      {:ok, key} -> Input.allow_pairing(key)
      {:error, _} -> :ok
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:sendspin_output_added, output}, socket) do
    card = build_card(output)

    socket =
      socket
      |> update(:outputs, &Map.put(&1, encode_key(output.key), card))
      |> assign(:bt_meta, build_bt_meta())

    # A reconnected headset replaces its placeholder (and cancels its timer).
    socket =
      case card.bt_mac do
        nil -> socket
        mac -> drop_reconnecting(socket, mac)
      end

    {:noreply, socket}
  end

  def handle_info({:sendspin_output_removed, %{key: key}}, socket) do
    id = encode_key(key)
    removed = Map.get(socket.assigns.outputs, id)

    socket =
      socket
      |> update(:outputs, &Map.delete(&1, id))
      |> update(:more_open, &MapSet.delete(&1, id))
      |> maybe_start_reconnecting(key, removed)
      |> assign(:bt_meta, build_bt_meta())

    socket =
      if socket.assigns.rename_target == id, do: close_rename(socket), else: socket

    {:noreply, socket}
  end

  # A BT connection change can move a device in/out of the reconnecting
  # set and re-binds the hci map. The actual card add/remove arrives via
  # the sendspin output topics; here we just keep the hci pills fresh.
  def handle_info({:bt_audio, :connection, _mac, _status}, socket) do
    {:noreply, assign(socket, :bt_meta, build_bt_meta())}
  end

  def handle_info({:bt_audio, _kind, _mac, _payload}, socket), do: {:noreply, socket}

  def handle_info({:drop_reconnecting, mac, token}, socket) do
    # Ignore a stale timer: only prune when this is still the current grace
    # timer for that MAC (a drop→return→drop may have superseded it).
    case socket.assigns.reconnecting do
      %{^mac => %{token: ^token}} -> {:noreply, drop_reconnecting(socket, mac)}
      _ -> {:noreply, socket}
    end
  end

  def handle_info({:sendspin_state, key, partial}, socket) do
    id = encode_key(key)

    case Map.fetch(socket.assigns.outputs, id) do
      {:ok, card} ->
        {:noreply,
         assign(socket, :outputs, Map.put(socket.assigns.outputs, id, merge_card(card, partial)))}

      :error ->
        # State for a key we don't know about — ignore. The next
        # `:sendspin_output_added` (if any) will repopulate.
        {:noreply, socket}
    end
  end

  def handle_info({:sendspin_input_added, input}, socket) do
    {:noreply,
     update(socket, :inputs, &Map.put(&1, encode_key(input.key), build_input_card(input)))}
  end

  def handle_info({:sendspin_input_removed, %{key: key}}, socket) do
    {:noreply, update(socket, :inputs, &Map.delete(&1, encode_key(key)))}
  end

  # `state_map` from `Audio.Input.Server` is always the FULL derived live
  # state (`status`/`connection`/`pin`/`port`/`last_error`), not a partial
  # patch — a straight `Map.merge/2` is correct here, unlike `merge_card/2`
  # above which has to interpret an `:event`-tagged partial.
  def handle_info({:input_state, key, state_map}, socket) do
    id = encode_key(key)

    case Map.fetch(socket.assigns.inputs, id) do
      {:ok, input} ->
        merged = Map.merge(input, state_map)
        {:noreply, assign(socket, :inputs, Map.put(socket.assigns.inputs, id, merged))}

      :error ->
        # State for a key we don't know about — ignore, same posture as
        # the output-side `:sendspin_state` handler.
        {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-[960px] mx-auto">
      <.audio_header count={map_size(@outputs)} />

      <.empty_state :if={map_size(@outputs) == 0 and map_size(@reconnecting) == 0} />

      <div
        :if={map_size(@outputs) > 0 or map_size(@reconnecting) > 0}
        class="grid grid-cols-1 [grid-template-columns:repeat(auto-fit,minmax(420px,1fr))] gap-4"
      >
        <.output_card
          :for={{id, output} <- sorted_outputs(@outputs)}
          id={id}
          output={output}
          hci={get_in(@bt_meta, [output.bt_mac, :hci])}
          battery={get_in(@bt_meta, [output.bt_mac, :battery])}
          more_open?={MapSet.member?(@more_open, id)}
        />
        <.reconnecting_card :for={{mac, info} <- active_reconnecting(@reconnecting, @outputs)} name={info.name} mac={mac} />
      </div>

      <section aria-label="Audio inputs" class="mt-10">
        <.input_header count={map_size(@inputs)} />

        <.input_empty_state :if={map_size(@inputs) == 0} />

        <div
          :if={map_size(@inputs) > 0}
          class="grid grid-cols-1 [grid-template-columns:repeat(auto-fit,minmax(360px,1fr))] gap-4"
        >
          <.input_card :for={{id, input} <- sorted_inputs(@inputs)} id={id} input={input} />
        </div>
      </section>
    </div>

    <.rename_modal
      :if={@rename_target}
      target={@rename_target}
      draft={@rename_draft}
      current={current_name(@outputs, @rename_target)}
      max={@friendly_name_max}
    />
    """
  end

  attr(:count, :integer, required: true)

  defp audio_header(assigns) do
    ~H"""
    <div class="mb-5">
      <.eyebrow>Audio</.eyebrow>
      <h2 class="text-xl font-semibold mt-1 mb-1.5 text-fg-1 flex items-center gap-2.5">
        Sendspin players
        <span :if={@count > 0} class="text-sm font-medium text-fg-3">
          · {@count} {if @count == 1, do: "output", else: "outputs"}
        </span>
      </h2>
      <p class="text-base text-fg-2 m-0 max-w-[640px]">
        Each ALSA output is advertised as an independent Sendspin player on the LAN.
        Music Assistant (or any Sendspin server) can group them with players on other devices.
      </p>
    </div>
    """
  end

  defp empty_state(assigns) do
    ~H"""
    <.card padding={:lg} class="text-center !p-9">
      <div class="w-12 h-12 rounded-md bg-audio-soft text-audio mx-auto mb-3 flex items-center justify-center">
        <.speaker_glyph size={26} />
      </div>
      <div class="text-md font-semibold text-fg-1">No audio outputs detected</div>
      <p class="text-sm text-fg-2 mt-1.5 m-0">
        Connect a supported audio device, or check that <span class="font-mono">dtparam=audio=on</span>
        is set in the boot config. The list refreshes automatically.
      </p>
    </.card>
    """
  end

  attr(:count, :integer, required: true)

  defp input_header(assigns) do
    ~H"""
    <div class="mb-5">
      <.eyebrow>Inputs</.eyebrow>
      <h2 class="text-xl font-semibold mt-1 mb-1.5 text-fg-1 flex items-center gap-2.5">
        Audio inputs
        <span :if={@count > 0} class="text-sm font-medium text-fg-3">
          · {@count} {if @count == 1, do: "input", else: "inputs"}
        </span>
      </h2>
      <p class="text-base text-fg-2 m-0 max-w-[640px]">
        Each USB capture card is advertised as a Sendspin source. Add it as a
        Live Input in Music Assistant, then pair it using the PIN shown here.
      </p>
    </div>
    """
  end

  defp input_empty_state(assigns) do
    ~H"""
    <.card padding={:lg} class="text-center !p-9">
      <div class="w-12 h-12 rounded-md bg-audio-soft text-audio mx-auto mb-3 flex items-center justify-center">
        <.icon name={:mic} size={26} />
      </div>
      <div class="text-md font-semibold text-fg-1">No audio inputs detected</div>
      <p class="text-sm text-fg-2 mt-1.5 m-0">
        Connect a USB capture card to advertise it as a Sendspin source for Music Assistant.
      </p>
    </.card>
    """
  end

  attr(:id, :string, required: true)
  attr(:input, :map, required: true)

  # Single input row/card. Read-only: no volume, mute, or enable control —
  # unlike an output, a present capture card always gets a source (see
  # `Audio.Input.Server`'s moduledoc). The only interactive-looking content
  # is the PIN block, and even that isn't a form: the device DISPLAYS the
  # PIN, the operator types it into Music Assistant.
  defp input_card(assigns) do
    assigns =
      assigns
      |> assign(:status, input_status(assigns.input.status))
      |> assign(:pairing_window_active?, pairing_window_active?(assigns.input))
      |> assign(:error_message, input_error_message(assigns.input))

    ~H"""
    <.card id={"input-#{@id}"} padding={:none} class="relative flex flex-col overflow-hidden">
      <div
        class="absolute inset-y-0 left-0 w-[3px]"
        style={"background: #{@status.tint_var};"}
      >
      </div>

      <div class="pt-[18px] pr-5 pb-[18px] pl-[22px]">
        <div class="flex items-start gap-3.5">
          <div class="flex-none w-11 h-11 rounded-md bg-audio-soft text-audio flex items-center justify-center">
            <.icon name={:mic} size={22} />
          </div>
          <div class="flex-1 min-w-0">
            <div class="text-md font-semibold text-fg-1">
              {@input.friendly_name || @input.name}
            </div>
            <div class="text-xs text-fg-3 mt-1">
              <span class="font-mono">{@input.alsa_device}</span>
              <span class="mx-1.5">·</span>
              <span>{@input.name}</span>
            </div>
          </div>
          <.badge variant={@status.variant} dot>{@status.label}</.badge>
        </div>

        <div
          :if={@input.status == :pairing and @input.pin}
          class="mt-4 px-3.5 py-3 rounded-md bg-accent-soft text-accent"
        >
          <div class="text-xs font-semibold mb-2">Enter this PIN in Music Assistant</div>
          <.pin_display pin={@input.pin} />
        </div>

        <%!-- Consent gesture: no PIN yet and no open window → offer the button;
             window open → show the active waiting state. --%>
        <button
          :if={@input.status == :pairing and is_nil(@input.pin) and not @pairing_window_active?}
          type="button"
          phx-click="allow_pairing"
          phx-value-id={@id}
          class="mt-4 w-full px-3.5 py-2.5 rounded-md bg-accent text-white text-sm font-semibold
                 cursor-pointer border-none hover:opacity-90 transition-opacity"
        >
          Allow pairing
        </button>

        <div
          :if={@input.status == :pairing and is_nil(@input.pin) and @pairing_window_active?}
          class="mt-4 px-3.5 py-3 rounded-md bg-accent-soft text-accent flex items-center gap-2.5"
        >
          <span class="w-3.5 h-3.5 rounded-full border-2 border-accent border-t-transparent bt-spin">
          </span>
          <div class="text-xs font-semibold">
            Pairing allowed — waiting for Music Assistant…
          </div>
        </div>
      </div>

      <div
        :if={@error_message}
        class="px-[22px] py-2 border-t border-border-2 bg-danger-soft text-danger text-xs"
      >
        {@error_message}
      </div>
    </.card>
    """
  end

  # An open "allow pairing" window (Unix-second expiry still in the future).
  defp pairing_window_active?(%{pairing_window: expires}) when is_integer(expires),
    do: expires > System.system_time(:second)

  defp pairing_window_active?(_input), do: false

  # Map an input's error state to a FIXED display string. `last_error` can carry
  # peer-influenced text; HEEx escapes it (no XSS) but echoing it verbatim in a
  # trusted-looking banner is a social-engineering surface, so the UI shows a
  # curated message instead.
  defp input_error_message(%{status: :degraded}),
    do: "No capture device available (arecord missing)."

  defp input_error_message(%{last_error: err}) when is_binary(err),
    do: "The last connection attempt failed. Music Assistant will retry."

  defp input_error_message(_input), do: nil

  attr(:pin, :string, required: true)

  # Large, segmented digit display — the whole pairing UX on our side is
  # showing this clearly enough to type into another device's UI.
  defp pin_display(assigns) do
    ~H"""
    <div class="flex items-center gap-1.5" role="text" aria-label={"Pairing PIN #{@pin}"}>
      <span
        :for={digit <- String.graphemes(@pin)}
        class="w-8 h-10 rounded-md bg-surface border border-border-1 flex items-center
               justify-center text-xl font-mono font-semibold tabular-nums text-fg-1"
      >
        {digit}
      </span>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:output, :map, required: true)
  attr(:hci, :string, default: nil)
  attr(:battery, :integer, default: nil)
  attr(:more_open?, :boolean, required: true)

  # Single player card. Layout is a vertical flex with three logical
  # blocks:
  #
  #   1. Header (variable height — wraps when the ALSA path is long)
  #   2. Anchored middle block (stream banner + volume row) — pushes
  #      itself to the bottom via `mt-auto` so volume sliders stay
  #      horizontally aligned across a row of cards whose headers
  #      wrap to different heights.
  #   3. Footer (enable toggle + more disclosure) — stuck under the
  #      anchored block.
  #
  # A 3px left status spine runs the full card height for at-a-glance
  # state. The whole card fades to 70% opacity when the output is
  # disabled.
  defp output_card(assigns) do
    assigns =
      assigns
      |> assign(:status, audio_status(assigns.output))
      |> assign(:streaming?, audio_streaming?(assigns.output))
      |> assign(:connected?, audio_connected?(assigns.output))

    ~H"""
    <.card
      padding={:none}
      class={"relative flex flex-col overflow-hidden transition-opacity duration-200 #{if @output.enabled, do: "", else: "opacity-70"}"}
    >
      <%!-- Left status spine --%>
      <div
        class="absolute inset-y-0 left-0 w-[3px]"
        style={"background: #{@status.tint_var}; opacity: #{if @output.enabled, do: 1, else: 0.4};"}
      >
      </div>

      <%!-- Header --%>
      <div class="pt-[18px] pr-5 pb-0 pl-[22px]">
        <div class="flex items-start gap-3.5">
          <div class="relative flex-none w-11 h-11">
            <div class={[
              "w-11 h-11 rounded-md flex items-center justify-center",
              if(@output.enabled, do: "bg-audio-soft text-audio", else: "bg-sunken text-fg-4")
            ]}>
              <.speaker_glyph
                size={24}
                muted={@output.muted}
                level={speaker_level(@output.volume)}
              />
            </div>
            <.bt_corner_glyph :if={@output.bt?} class="absolute -right-1 -bottom-1" />
          </div>
          <div class="flex-1 min-w-0">
            <button
              type="button"
              phx-click="open_rename"
              phx-value-id={@id}
              aria-label={"Rename #{@output.friendly_name}"}
              class="group inline-flex items-center gap-1.5 -mx-2 -my-1 px-2 py-1 rounded-sm
                     border border-transparent hover:border-border-1
                     bg-transparent cursor-pointer transition-colors text-left"
            >
              <span class="text-md font-semibold text-fg-1">{@output.friendly_name}</span>
              <span class="text-fg-3 opacity-45 group-hover:opacity-100 transition-opacity inline-flex">
                <.icon name={:pencil} size={13} />
              </span>
            </button>
            <div class="text-xs text-fg-3 mt-1">
              <span class="font-mono">{@output.alsa_device}</span>
              <span class="mx-1.5">·</span>
              <span>{@output.card_name}</span>
            </div>
            <%!-- Bluetooth pills: codec (when streaming) + bound radio --%>
            <div :if={@output.bt?} class="flex items-center gap-1.5 mt-2 flex-wrap">
              <.badge :if={codec_label(@output)} variant={:neutral} class="!text-[10px] !px-1.5 !py-px">
                {codec_label(@output)}
              </.badge>
              <.badge :if={@hci} variant={:neutral} class="!text-[10px] !px-1.5 !py-px !font-mono">
                {@hci}
              </.badge>
              <.battery_pill :if={is_integer(@battery)} level={@battery} />
            </div>
          </div>
          <.badge variant={@status.variant} dot>{@status.label}</.badge>
        </div>
      </div>

      <%!-- Anchored middle block: stream banner + volume row.
           `mt-auto` makes the block stick to the card's bottom edge
           above the footer, so volume sliders align across rows. --%>
      <div class="mt-auto pt-3.5 px-5 pb-3 pl-[22px]">
        <.stream_banner output={@output} streaming?={@streaming?} connected?={@connected?} />

        <div class="mt-4 flex items-center gap-3">
          <button
            type="button"
            phx-click="toggle_mute"
            phx-value-id={@id}
            disabled={not @output.enabled}
            title={if @output.muted, do: "Unmute", else: "Mute"}
            class={[
              "w-9 h-9 rounded-md border border-border-1 flex items-center justify-center flex-none",
              if(@output.muted,
                do: "bg-warning-soft text-warning",
                else: "bg-surface text-fg-2"
              ),
              if(@output.enabled, do: "cursor-pointer", else: "cursor-not-allowed")
            ]}
          >
            <.speaker_glyph
              size={18}
              muted={@output.muted}
              level={speaker_level(@output.volume)}
            />
          </button>
          <form phx-change="set_volume" class="flex-1 min-w-0">
            <input type="hidden" name="key" value={@id} />
            <input
              type="range"
              name="value"
              min="0"
              max="100"
              value={@output.volume}
              phx-debounce="200"
              disabled={not @output.enabled or @output.muted}
              class="audio-volume"
              style={"--vol: #{@output.volume};"}
              aria-label={"Volume for #{@output.friendly_name}"}
            />
          </form>
          <div class="text-md font-semibold font-mono tabular-nums text-fg-1 min-w-9 text-right">
            {@output.volume}
          </div>
        </div>
      </div>

      <%!-- Footer --%>
      <div class="flex items-center gap-3 pt-3 pr-5 pb-3 pl-[22px] border-t border-border-2 bg-sunken">
        <.toggle checked={@output.enabled} phx-click="toggle_enabled" phx-value-id={@id} />
        <span class="text-sm text-fg-2">
          {if @output.enabled, do: "Output enabled", else: "Output disabled"}
        </span>
        <div class="flex-1"></div>
        <button
          type="button"
          phx-click="toggle_more"
          phx-value-id={@id}
          aria-label="Show details"
          aria-expanded={@more_open?}
          class="text-fg-3 hover:text-fg-2 p-1.5 rounded-sm flex items-center cursor-pointer bg-transparent border-none"
        >
          <.icon name={:more} size={16} />
        </button>
      </div>

      <%!-- Disclosure: card index + client id (mono) + copy --%>
      <div
        :if={@more_open?}
        class="px-[22px] pt-2.5 pb-3.5 border-t border-border-2 bg-sunken
               grid grid-cols-[auto_1fr_auto] gap-x-3 gap-y-1 items-center text-[11px] text-fg-3"
      >
        <span>Card</span>
        <span class="font-mono text-fg-2">{@output.card_index}</span>
        <span></span>
        <span>Client ID</span>
        <span class="font-mono text-fg-2 truncate">{@output.client_id}</span>
        <button
          type="button"
          phx-hook="CopyToClipboard"
          data-clipboard={@output.client_id}
          id={"copy-client-#{@id}"}
          class="text-accent text-[11px] cursor-pointer bg-transparent border-none p-0"
        >
          Copy
        </button>
      </div>

      <%!-- Last-error footnote (only when present) --%>
      <div
        :if={@output.last_error}
        class="px-[22px] py-2 border-t border-border-2 bg-danger-soft text-danger text-xs"
      >
        {@output.last_error}
      </div>
    </.card>
    """
  end

  # Transient placeholder shown while a dropped Bluetooth device tries to
  # reconnect. After the grace window it disappears (the device's durable
  # surface is the Bluetooth tab). Structurally a slim player card so it
  # sits in the grid without jarring the layout.
  attr(:name, :string, required: true)
  attr(:mac, :string, required: true)

  defp reconnecting_card(assigns) do
    ~H"""
    <.card padding={:none} class="relative flex flex-col overflow-hidden opacity-90">
      <div class="absolute inset-y-0 left-0 w-[3px] bg-accent"></div>
      <div class="pt-[18px] pr-5 pb-[18px] pl-[22px]">
        <div class="flex items-start gap-3.5">
          <div class="relative flex-none w-11 h-11">
            <div class="w-11 h-11 rounded-md bg-sunken text-fg-4 flex items-center justify-center">
              <.speaker_glyph size={24} level={0} />
            </div>
            <.bt_corner_glyph class="absolute -right-1 -bottom-1" />
          </div>
          <div class="flex-1 min-w-0">
            <div class="text-md font-semibold text-fg-1 truncate">{@name}</div>
            <div class="text-xs text-fg-3 mt-1 font-mono">{@mac}</div>
          </div>
          <.badge variant={:accent} dot>Reconnecting</.badge>
        </div>
        <div class="mt-3.5 px-3 py-2.5 rounded-md bg-sunken flex items-center gap-2.5">
          <span class="w-3.5 h-3.5 rounded-full border-2 border-warning border-t-transparent bt-spin text-warning"></span>
          <div class="text-xs text-fg-2 font-medium">Reconnecting to {@name}…</div>
        </div>
      </div>
    </.card>
    """
  end

  # Stream banner: colored block under the header that summarizes the
  # player's connection state in plain language. Four states:
  #
  #   * Streaming (audio-tint-soft + animated EQ + codec/rate label)
  #   * Connected (accent-soft + pause icon + "paused on server")
  #   * Searching (sunken + static low EQ + "waiting for a server")
  #   * Disabled  (sunken + static low EQ + "won't advertise")
  attr(:output, :map, required: true)
  attr(:streaming?, :boolean, required: true)
  attr(:connected?, :boolean, required: true)

  defp stream_banner(assigns) do
    ~H"""
    <div class={[
      "px-3 py-2.5 rounded-md flex items-center gap-2.5",
      cond do
        @streaming? -> "bg-audio-soft text-audio"
        @connected? -> "bg-accent-soft text-accent"
        true -> "bg-sunken text-fg-2"
      end
    ]}>
      <%= cond do %>
        <% @streaming? -> %>
          <.eq_bars active={true} />
        <% @connected? -> %>
          <.icon name={:pause} size={14} stroke={2.0} />
        <% true -> %>
          <.eq_bars active={false} />
      <% end %>

      <div class={["text-xs flex-1", (@streaming? or @connected?) && "font-semibold"]}>
        <%= cond do %>
          <% @streaming? -> %>
            {stream_label(@output.stream)}
          <% @connected? -> %>
            Connected — paused on server
          <% @output.enabled -> %>
            Waiting for a Sendspin server on the LAN…
          <% true -> %>
            Output disabled — won't advertise on the network.
        <% end %>
      </div>

      <div
        :if={@output.group}
        class="text-[11px] text-fg-3 flex items-center gap-1.5 font-normal"
      >
        <span class="w-1.5 h-1.5 rounded-full bg-fg-3"></span>
        Group: <span class="text-fg-2 font-medium">{@output.group}</span>
      </div>
    </div>
    """
  end

  # Rename confirm modal. The form is owned by the LiveView — keystrokes
  # flow through `rename_draft` and the actual commit is `confirm_rename`.
  # Escape and the backdrop click both cancel via the existing modal
  # component's `on_close` behavior.
  attr(:target, :string, required: true)
  attr(:draft, :string, required: true)
  attr(:current, :string, required: true)
  attr(:max, :integer, required: true)

  defp rename_modal(assigns) do
    assigns =
      assigns
      |> assign(:cleaned, clean_friendly_name(assigns.draft))

    assigns =
      assign(
        assigns,
        :can_save?,
        String.length(assigns.cleaned) > 0 and assigns.cleaned != assigns.current
      )

    ~H"""
    <.modal open={true} on_close="cancel_rename" title="Rename player">
      <:footer>
        <.button variant={:ghost} size={:sm} phx-click="cancel_rename">Cancel</.button>
        <.button
          variant={:primary}
          size={:sm}
          phx-click="confirm_rename"
          disabled={not @can_save?}
        >
          Save & re-advertise
        </.button>
      </:footer>
      <p class="text-sm text-fg-2 mb-2 mt-0">
        Saving re-advertises the player over mDNS, which will momentarily disconnect
        any paired Sendspin server. Music Assistant will reconnect automatically.
      </p>
      <p class="text-xs text-fg-3 mb-4 mt-0">
        Music Assistant remembers the name it first paired this player under and won't
        update its display from this rename. To change the name there too, rename the
        player from inside Music Assistant's settings.
      </p>
      <form phx-submit="confirm_rename" phx-change="rename_draft" class="space-y-2">
        <div class="flex items-center justify-between text-xs">
          <label for="rename-input" class="font-medium text-fg-2">Friendly name</label>
          <span class="text-fg-3 font-mono tabular-nums">
            {String.length(@cleaned)} / {@max}
          </span>
        </div>
        <input
          id="rename-input"
          type="text"
          name="value"
          value={@draft}
          maxlength={@max}
          autocomplete="off"
          phx-hook="AutofocusSelect"
          class="w-full px-3 py-2 text-base text-fg-1 bg-surface border border-border-1 rounded-sm
                 focus:border-accent focus:outline-none transition-colors"
        />
      </form>
    </.modal>
    """
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  defp close_rename(socket) do
    socket
    |> assign(:rename_target, nil)
    |> assign(:rename_draft, "")
  end

  defp current_name(outputs, id) do
    case Map.fetch(outputs, id) do
      {:ok, %{friendly_name: name}} -> name
      _ -> ""
    end
  end

  defp build_outputs_map(outputs) do
    Map.new(outputs, fn output -> {encode_key(output.key), build_card(output)} end)
  end

  defp build_inputs_map(inputs) do
    Map.new(inputs, fn input -> {encode_key(input.key), build_input_card(input)} end)
  end

  # The card map is the LiveView's per-input view — see `build_card/1`
  # above for the output-side counterpart. `Audio.Input.list_inputs/0`
  # always carries the live-state fields (merged in server-side), but the
  # `:sendspin_input_added` broadcast payload does NOT (see
  # `Audio.Input.Server.refresh_inputs/1`'s `merged_adds`) — so every
  # live-state field defaults here to the same "just detected" values
  # `Audio.Input.Server`'s `@default_input_state` uses.
  defp build_input_card(input) do
    %{
      key: input.key,
      name: Map.get(input, :name),
      alsa_device: Map.get(input, :alsa_device),
      friendly_name: Map.get(input, :friendly_name) || Map.get(input, :name),
      status: Map.get(input, :status, :detected),
      connection: Map.get(input, :connection, :disconnected),
      pin: Map.get(input, :pin),
      pairing_window: Map.get(input, :pairing_window),
      last_error: Map.get(input, :last_error)
    }
  end

  # A Bluetooth output keys by `{mac, nil, nil}`; pull the MAC out. Only
  # call once the output is known to be Bluetooth (`bt_output?/1`) — the
  # key shape isn't unique to BT (onboard ALSA cards share it).
  defp bt_key_mac({mac, nil, nil}) when is_binary(mac), do: mac
  defp bt_key_mac(_), do: nil

  # mac → "hciN": join the paired-headset list (mac → bound adapter MAC)
  # with the radio list (adapter MAC → hci). Exit-safe via the public API.
  defp build_bt_meta do
    radios = Bluetooth.list_radios()
    hci_by_mac = Map.new(radios, fn r -> {r.address, Map.get(r, :hci)} end)

    AudioManager.list_headphones()
    |> Map.new(fn hp ->
      {hp.mac, %{hci: Map.get(hci_by_mac, hp.adapter), battery: Map.get(hp, :battery)}}
    end)
  end

  # When a connected, enabled BT output's PCM vanishes, hold a brief
  # "Reconnecting" placeholder so a quick drop/return doesn't flicker the
  # card away. Ignores ALSA removals and BT outputs that were disabled.
  #
  # Each grace timer carries a unique `token` stored on the entry: cancelling
  # the prior timer reduces mailbox churn, but `cancel_timer/1` can't unsend a
  # message that already fired, so the handler also drops only when the
  # message's token still matches the current entry — otherwise a rapid
  # drop→return→drop could let a stale timer prune the *fresh* placeholder.
  defp maybe_start_reconnecting(socket, _key, %{bt?: true, bt_mac: mac, enabled: true} = removed)
       when is_binary(mac) do
    cancel_reconnect_timer(socket, mac)
    token = make_ref()
    ref = Process.send_after(self(), {:drop_reconnecting, mac, token}, @bt_reconnect_grace_ms)

    update(
      socket,
      :reconnecting,
      &Map.put(&1, mac, %{name: removed.friendly_name, timer: ref, token: token})
    )
  end

  defp maybe_start_reconnecting(socket, _key, _removed), do: socket

  # Remove a reconnecting placeholder, cancelling its grace timer first.
  defp drop_reconnecting(socket, mac) do
    cancel_reconnect_timer(socket, mac)
    update(socket, :reconnecting, &Map.delete(&1, mac))
  end

  defp cancel_reconnect_timer(socket, mac) do
    case socket.assigns.reconnecting do
      %{^mac => %{timer: ref}} when is_reference(ref) -> Process.cancel_timer(ref)
      _ -> :ok
    end
  end

  # The card map is the LiveView's per-output view. It merges the
  # persisted/enumerated fields from `Audio.list_outputs/0` with
  # binary-emitted lifecycle data that arrives over PubSub. Connection
  # / stream / last_error are read from the output map when present so
  # late LiveView mounts (after the binary already emitted `connected`
  # / `stream_start`) immediately render the correct state instead of
  # waiting for the next event.
  defp build_card(output) do
    %{
      key: output.key,
      card_index: output.card_index,
      alsa_device: output.alsa_device,
      card_name: output.card_name,
      friendly_name: output.friendly_name,
      enabled: output.enabled,
      volume: output.volume,
      muted: output.muted,
      client_id: output.client_id,
      connection: Map.get(output, :connection, :unknown),
      stream: Map.get(output, :stream),
      group: nil,
      last_error: Map.get(output, :last_error),
      # Bluetooth (A2DP) outputs render with extra chrome (BT glyph,
      # codec/radio pills); detected by the `bluealsa:` device prefix
      # (the `{name, nil, nil}` key shape alone is NOT unique — onboard
      # ALSA cards key that way too).
      bt?: bt_output?(output),
      bt_mac: if(bt_output?(output), do: bt_key_mac(output.key), else: nil)
    }
  end

  # PubSub partial messages come in two flavors:
  #   1. Server-originated: keys are :friendly_name | :volume | :muted | :enabled
  #   2. Binary-originated: has an :event key plus event-specific payload
  # Both flow through this single merge function. Unknown keys fall
  # through untouched so a future binary event field doesn't crash the
  # LiveView.
  defp merge_card(card, partial) when is_map(partial) do
    Enum.reduce(partial, card, fn
      {:friendly_name, name}, acc when is_binary(name) ->
        %{acc | friendly_name: name}

      {:volume, v}, acc when is_integer(v) ->
        %{acc | volume: v}

      {:muted, m}, acc when is_boolean(m) ->
        %{acc | muted: m}

      {:enabled, e}, acc when is_boolean(e) ->
        %{acc | enabled: e}

      {:event, "connected"}, acc ->
        %{acc | connection: :connected, last_error: nil}

      {:event, "disconnected"}, acc ->
        %{acc | connection: :disconnected, stream: nil}

      {:event, "stream_start"}, acc ->
        %{acc | stream: stream_params_from(partial)}

      {:event, "stream_end"}, acc ->
        %{acc | stream: nil}

      {:event, "error"}, acc ->
        %{acc | last_error: as_binary(Map.get(partial, :msg)) || "error"}

      {:event, "shutdown"}, acc ->
        %{acc | connection: :disconnected, stream: nil}

      _other, acc ->
        acc
    end)
  end

  # Boundary coercion: the binary's JSON keys are statically defined in
  # `c_src/sendspin_player/src/main.cpp`, but a hypothetical bug there
  # could emit a float (e.g. `48000.0`) or a non-binary codec. `div/2`
  # below in `stream_label/1` raises on non-integers; type-guarding at
  # the boundary keeps a binary regression from crashing the LiveView
  # render.
  defp stream_params_from(partial) do
    %{
      codec: as_binary(Map.get(partial, :codec)),
      sample_rate: as_integer(Map.get(partial, :sample_rate)),
      channels: as_integer(Map.get(partial, :channels)),
      bit_depth: as_integer(Map.get(partial, :bit_depth))
    }
  end

  defp as_integer(v) when is_integer(v), do: v
  defp as_integer(_), do: nil

  defp as_binary(v) when is_binary(v), do: v
  defp as_binary(_), do: nil

  defp sorted_outputs(outputs) do
    outputs
    |> Map.to_list()
    |> Enum.sort_by(fn {_id, %{friendly_name: name}} -> name end)
  end

  defp sorted_inputs(inputs) do
    inputs
    |> Map.to_list()
    |> Enum.sort_by(fn {_id, %{friendly_name: name}} -> name end)
  end

  # Badge copy + tint for an input's `:status`. Mirrors `audio_status/1`
  # in `Components.Audio` (same badge/tint-var contract) but keyed off the
  # input state machine's richer status set — `:detected` through
  # `:degraded` — rather than the output side's enabled/connection/stream
  # trio.
  @spec input_status(atom()) :: %{label: String.t(), variant: atom(), tint_var: String.t()}
  defp input_status(:detected),
    do: %{label: "Detected", variant: :neutral, tint_var: "var(--hs-fg-4)"}

  defp input_status(:waiting),
    do: %{label: "Waiting for Music Assistant", variant: :warning, tint_var: "var(--hs-warning)"}

  defp input_status(:pairing),
    do: %{label: "Pairing", variant: :accent, tint_var: "var(--hs-accent)"}

  defp input_status(:paired),
    do: %{label: "Paired", variant: :accent, tint_var: "var(--hs-accent)"}

  defp input_status(:streaming),
    do: %{label: "Streaming", variant: :success, tint_var: "var(--hs-success)"}

  defp input_status(:degraded),
    do: %{
      label: "No capture (arecord missing)",
      variant: :danger,
      tint_var: "var(--hs-danger)"
    }

  # Reconnecting placeholders for MACs that don't currently have a live
  # output card (a reconnected device's real card supersedes its
  # placeholder until the drop timer prunes the stale entry).
  defp active_reconnecting(reconnecting, outputs) do
    live_macs = for {_id, %{bt_mac: mac}} <- outputs, is_binary(mac), into: MapSet.new(), do: mac

    reconnecting
    |> Enum.reject(fn {mac, _info} -> MapSet.member?(live_macs, mac) end)
    |> Enum.sort_by(fn {_mac, %{name: name}} -> name end)
  end

  defp fetch_output(socket, id) do
    case Map.fetch(socket.assigns.outputs, id) do
      {:ok, _} = ok -> ok
      :error -> {:error, :not_found}
    end
  end

  # The form passes `id` as a string; reconstitute the tuple via
  # `binary_to_term/2` with `[:safe]` so a tampered param can't inject
  # arbitrary atoms. Post-decode we assert the shape — only
  # `{binary, nil | integer, nil | integer}` is accepted.
  defp decode_key(id) when is_binary(id) do
    with {:ok, bin} <- Base.url_decode64(id, padding: false),
         {:ok, term} <- safe_binary_to_term(bin),
         true <- valid_key_shape?(term) do
      {:ok, term}
    else
      _ -> {:error, :invalid_key}
    end
  end

  defp decode_key(_), do: {:error, :invalid_key}

  defp safe_binary_to_term(bin) do
    {:ok, :erlang.binary_to_term(bin, [:safe])}
  rescue
    _ -> :error
  end

  defp valid_key_shape?({slot_sub, vid, pid})
       when is_binary(slot_sub) and (is_nil(vid) or is_integer(vid)) and
              (is_nil(pid) or is_integer(pid)),
       do: true

  defp valid_key_shape?(_), do: false

  defp encode_key(key) do
    key |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)
  end

  # Strip control chars + trim + cap length. Used both in the modal's
  # live char counter and in the final commit path. Returns the raw
  # cleaned string (not wrapped in {:ok, _}) for use in templates.
  defp clean_friendly_name(raw) when is_binary(raw) do
    raw
    |> String.replace(~r/[[:cntrl:]]/u, "")
    |> String.trim()
    |> String.slice(0, @friendly_name_max)
  end

  defp clean_friendly_name(_), do: ""

  defp sanitize_friendly_name(raw) when is_binary(raw) do
    cleaned = clean_friendly_name(raw)
    if cleaned == "", do: {:error, :empty_name}, else: {:ok, cleaned}
  end

  defp sanitize_friendly_name(_), do: {:error, :empty_name}
end
