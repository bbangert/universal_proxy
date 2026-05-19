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
  """

  use UniversalProxyWeb, :live_view

  require Logger

  import UniversalProxyWeb.Components.UI

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
     |> assign(:outputs, build_outputs_map(outputs))}
  end

  @impl true
  def handle_event("rename", %{"key" => id, "name" => raw_name}, socket) do
    with {:ok, key} <- decode_key(id),
         {:ok, name} <- sanitize_friendly_name(raw_name) do
      case Audio.update_config(key, %{friendly_name: name}) do
        :ok ->
          {:noreply, socket}

        {:error, reason} ->
          Logger.warning("Audio rename failed for #{inspect(key)}: #{inspect(reason)}")
          {:noreply, put_flash(socket, :error, "Rename failed: #{inspect(reason)}")}
      end
    else
      {:error, :invalid_key} ->
        {:noreply, socket}

      {:error, :empty_name} ->
        # Empty / whitespace-only — silently ignore, leave the existing
        # name as-is. The current value is still in assigns and the
        # PubSub broadcast we'd otherwise echo never happens.
        {:noreply, socket}
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

  @impl true
  def handle_info({:sendspin_output_added, output}, socket) do
    {:noreply, update(socket, :outputs, &Map.put(&1, encode_key(output.key), build_card(output)))}
  end

  def handle_info({:sendspin_output_removed, %{key: key}}, socket) do
    {:noreply, update(socket, :outputs, &Map.delete(&1, encode_key(key)))}
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
    <div class="max-w-[960px] mx-auto space-y-4">
      <div>
        <.eyebrow>Audio</.eyebrow>
        <h2 class="text-xl font-semibold mt-1 mb-1.5 text-fg-1">
          Sendspin players
        </h2>
        <p class="text-base text-fg-2 m-0">
          Each ALSA output is advertised as an independent Sendspin player on the LAN.
          Music Assistant (or any Sendspin server) can group them with players on other devices.
        </p>
      </div>

      <.empty_state :if={map_size(@outputs) == 0} />

      <div :if={map_size(@outputs) > 0} class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <.output_card
          :for={{id, output} <- sorted_outputs(@outputs)}
          id={id}
          output={output}
          name_max={@friendly_name_max}
        />
      </div>
    </div>
    """
  end

  defp empty_state(assigns) do
    ~H"""
    <.card padding={:lg} class="text-center">
      <div class="text-base font-semibold text-fg-1">No audio outputs detected</div>
      <p class="text-sm text-fg-2 mt-1 m-0">
        Connect a supported audio device, or check that <span class="font-mono">dtparam=audio=on</span>
        is set in the boot config. The list refreshes automatically.
      </p>
    </.card>
    """
  end

  attr(:id, :string, required: true)
  attr(:output, :map, required: true)
  attr(:name_max, :integer, required: true)

  defp output_card(assigns) do
    ~H"""
    <.card padding={:lg} class="space-y-4">
      <div class="flex items-start gap-3">
        <div class="flex-1 min-w-0">
          <form phx-submit="rename" class="flex items-center gap-2">
            <input type="hidden" name="key" value={@id} />
            <input
              type="text"
              name="name"
              value={@output.friendly_name}
              phx-blur="rename"
              maxlength={@name_max}
              class="flex-1 min-w-0 px-2 py-1 -mx-2 -my-1 text-md font-semibold tracking-tight
                     bg-transparent text-fg-1 rounded-sm
                     border border-transparent hover:border-border-1 focus:border-accent
                     focus:bg-surface focus:shadow-focus outline-none transition-colors"
            />
          </form>
          <div class="text-sm text-fg-3 mt-1">
            <span class="font-mono">{@output.alsa_device}</span> · {@output.card_name}
          </div>
        </div>
        <.status_badge
          connection={@output.connection}
          stream={@output.stream}
          enabled={@output.enabled}
        />
      </div>

      <dl class="m-0 grid grid-cols-[110px_1fr] gap-x-3 gap-y-1.5 text-sm">
        <dt class="text-fg-3">Stream</dt>
        <dd class="m-0 text-fg-1">{stream_label(@output.stream)}</dd>
        <dt class="text-fg-3">Group</dt>
        <dd class="m-0 text-fg-2">{@output.group || "—"}</dd>
        <dt class="text-fg-3">Client id</dt>
        <dd class="m-0 text-fg-2 font-mono text-[11px] truncate">{@output.client_id}</dd>
      </dl>

      <div class="space-y-2">
        <div class="flex items-center justify-between">
          <label class="text-sm font-medium text-fg-2" for={"vol-#{@id}"}>Volume</label>
          <span class="text-sm tabular-nums text-fg-1">{@output.volume}</span>
        </div>
        <form phx-change="set_volume">
          <input type="hidden" name="key" value={@id} />
          <input
            type="range"
            id={"vol-#{@id}"}
            name="value"
            min="0"
            max="100"
            value={@output.volume}
            phx-debounce="200"
            disabled={not @output.enabled}
            class="w-full"
          />
        </form>
      </div>

      <div class="flex items-center justify-between pt-1">
        <div class="flex items-center gap-3">
          <.toggle
            checked={@output.muted}
            phx-click="toggle_mute"
            phx-value-id={@id}
            disabled={not @output.enabled}
          />
          <span class="text-sm text-fg-2">{if @output.muted, do: "Muted", else: "Unmuted"}</span>
        </div>
        <div class="flex items-center gap-3">
          <.toggle checked={@output.enabled} phx-click="toggle_enabled" phx-value-id={@id} />
          <span class="text-sm text-fg-2">{if @output.enabled, do: "Enabled", else: "Disabled"}</span>
        </div>
      </div>

      <div :if={@output.last_error} class="text-xs text-danger">{@output.last_error}</div>
    </.card>
    """
  end

  attr(:connection, :atom, required: true)
  attr(:stream, :any, required: true)
  attr(:enabled, :boolean, required: true)

  # The Sendspin client keeps its WebSocket open to the server between
  # songs, so `:connection == :connected` stays true even when no audio
  # is flowing. "Streaming" requires the additional signal that a
  # `stream_start` event landed without a subsequent `stream_end` —
  # tracked as `:stream` in `Audio.Server`'s `connection_state` map.
  #
  # `:unknown` connection (enabled, no event yet) renders as "Idle" on
  # this page — the nuance matters here because the user is on a screen
  # dedicated to audio playback, where "could stream if a server
  # appears" is the meaningful state. OverviewLive renders the same
  # state as "Stopped" to match the existing UART-row vocabulary
  # ("Active / Idle / Stopped"); the two phrasings are deliberate.
  defp status_badge(assigns) do
    cond do
      not assigns.enabled ->
        ~H"<.badge variant={:neutral} dot>Disabled</.badge>"

      assigns.connection == :connected and not is_nil(assigns.stream) ->
        ~H"<.badge variant={:success} dot>Streaming</.badge>"

      assigns.connection == :connected ->
        ~H"<.badge variant={:accent} dot>Connected</.badge>"

      assigns.connection == :disconnected ->
        ~H"<.badge variant={:warning} dot>Searching</.badge>"

      true ->
        ~H"<.badge variant={:neutral} dot>Idle</.badge>"
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────

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

  defp stream_label(nil), do: "—"

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

  # Length cap matches the mDNS TXT budget. Control chars are stripped
  # rather than rejected so a user paste that happens to include a tab
  # or zero-width character doesn't get bounced. Empty-after-strip is
  # treated as a no-op in the caller.
  defp sanitize_friendly_name(raw) when is_binary(raw) do
    cleaned =
      raw
      |> String.replace(~r/[[:cntrl:]]/u, "")
      |> String.trim()
      |> String.slice(0, @friendly_name_max)

    if cleaned == "", do: {:error, :empty_name}, else: {:ok, cleaned}
  end

  defp sanitize_friendly_name(_), do: {:error, :empty_name}
end
