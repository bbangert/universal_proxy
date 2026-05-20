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
  """

  use UniversalProxyWeb, :live_view

  require Logger

  import UniversalProxyWeb.Components.UI
  import UniversalProxyWeb.Components.Icons

  alias UniversalProxy.Audio

  # mDNS TXT record total size cap is 255 bytes; we use ~64 chars to
  # leave headroom for the `name=` prefix and any other TXT attrs the
  # binary advertises. Control chars (< 0x20, DEL 0x7F) would break the
  # TXT wire format and also have no business in a user-facing name.
  @friendly_name_max 64

  @impl true
  def mount(_params, _session, socket) do
    outputs = Audio.list_outputs()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "sendspin:output_added")
      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "sendspin:output_removed")
      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "sendspin:state")
    end

    {:ok,
     socket
     |> assign(:page_title, "Audio")
     |> assign(:friendly_name_max, @friendly_name_max)
     |> assign(:outputs, build_outputs_map(outputs))
     # Rename modal state. `rename_target` holds the DOM-encoded key of
     # the card whose name is being edited; `nil` means the modal is
     # closed. `rename_draft` mirrors the input value live so the char
     # counter and the save-disabled check stay in sync without a
     # round-trip per keystroke (we use phx-keyup for that).
     |> assign(:rename_target, nil)
     |> assign(:rename_draft, "")
     # Per-card "more" disclosure (footer chevron expands to show card
     # index + client_id). Tracking as a MapSet keyed on the same
     # encoded ids the cards use.
     |> assign(:more_open, MapSet.new())}
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

  @impl true
  def handle_info({:sendspin_output_added, output}, socket) do
    {:noreply, update(socket, :outputs, &Map.put(&1, encode_key(output.key), build_card(output)))}
  end

  def handle_info({:sendspin_output_removed, %{key: key}}, socket) do
    id = encode_key(key)

    socket =
      socket
      |> update(:outputs, &Map.delete(&1, id))
      |> update(:more_open, &MapSet.delete(&1, id))

    socket =
      if socket.assigns.rename_target == id, do: close_rename(socket), else: socket

    {:noreply, socket}
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

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-[960px] mx-auto">
      <.audio_header count={map_size(@outputs)} />

      <.empty_state :if={map_size(@outputs) == 0} />

      <div
        :if={map_size(@outputs) > 0}
        class="grid grid-cols-1 [grid-template-columns:repeat(auto-fit,minmax(420px,1fr))] gap-4"
      >
        <.output_card
          :for={{id, output} <- sorted_outputs(@outputs)}
          id={id}
          output={output}
          more_open?={MapSet.member?(@more_open, id)}
        />
      </div>
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

  attr(:id, :string, required: true)
  attr(:output, :map, required: true)
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
          <div class={[
            "w-11 h-11 rounded-md flex items-center justify-center flex-none",
            if(@output.enabled, do: "bg-audio-soft text-audio", else: "bg-sunken text-fg-4")
          ]}>
            <.speaker_glyph
              size={24}
              muted={@output.muted}
              level={speaker_level(@output.volume)}
            />
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
      last_error: Map.get(output, :last_error)
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

  defp stream_label(nil), do: "Streaming"

  defp stream_label(%{codec: codec, sample_rate: rate, bit_depth: depth}) do
    parts =
      [
        codec && String.upcase(to_string(codec)),
        rate && "#{div(rate, 1000)} kHz",
        depth && "#{depth}-bit"
      ]
      |> Enum.reject(&is_nil/1)

    case parts do
      [] -> "Streaming"
      _ -> Enum.join(parts, " · ")
    end
  end

  defp stream_label(_), do: "Streaming"

  defp sorted_outputs(outputs) do
    outputs
    |> Map.to_list()
    |> Enum.sort_by(fn {_id, %{friendly_name: name}} -> name end)
  end

  defp fetch_output(socket, id) do
    case Map.fetch(socket.assigns.outputs, id) do
      {:ok, _} = ok -> ok
      :error -> {:error, :not_found}
    end
  end

  # ── Status state machine (mirrors OverviewLive.audio_status/1) ─────
  # See `OverviewLive.audio_status/1` for the rationale on collapsing
  # to a single vocabulary (Streaming / Connected / Searching /
  # Disabled). The two copies are deliberately kept in sync — duplicate
  # this if you find yourself updating one side.
  defp audio_status(out) do
    enabled? = out.enabled
    connection = Map.get(out, :connection, :unknown)
    stream = Map.get(out, :stream)

    cond do
      not enabled? ->
        %{label: "Disabled", variant: :neutral, tint_var: "var(--hs-fg-4)"}

      connection == :connected and not is_nil(stream) ->
        %{label: "Streaming", variant: :success, tint_var: "var(--hs-success)"}

      connection == :connected ->
        %{label: "Connected", variant: :accent, tint_var: "var(--hs-accent)"}

      connection == :disconnected ->
        %{label: "Searching", variant: :warning, tint_var: "var(--hs-warning)"}

      true ->
        %{label: "Searching", variant: :warning, tint_var: "var(--hs-warning)"}
    end
  end

  defp audio_streaming?(out) do
    out.enabled and Map.get(out, :connection) == :connected and not is_nil(Map.get(out, :stream))
  end

  defp audio_connected?(out) do
    out.enabled and Map.get(out, :connection) == :connected
  end

  defp speaker_level(volume) when is_integer(volume) and volume > 60, do: 2
  defp speaker_level(volume) when is_integer(volume) and volume > 0, do: 1
  defp speaker_level(_), do: 0

  attr(:active, :boolean, required: true)

  defp eq_bars(assigns) do
    ~H"""
    <span class={["audio-eq", @active && "audio-eq--active"]}>
      <span class="audio-eq__bar"></span>
      <span class="audio-eq__bar"></span>
      <span class="audio-eq__bar"></span>
      <span class="audio-eq__bar"></span>
      <span class="audio-eq__bar"></span>
    </span>
    """
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
