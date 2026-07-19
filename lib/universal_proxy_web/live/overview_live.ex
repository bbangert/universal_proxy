defmodule UniversalProxyWeb.OverviewLive do
  @moduledoc """
  Overview tab — device summary strip + connected-hardware table.
  Clicking a row opens a right-side detail drawer.
  """

  use UniversalProxyWeb, :live_view

  require Logger

  import UniversalProxyWeb.Components.UI
  import UniversalProxyWeb.Components.Icons
  import UniversalProxyWeb.Components.Audio

  alias UniversalProxy.Audio
  alias UniversalProxy.Bluetooth
  alias UniversalProxy.Bluetooth.AudioManager
  alias UniversalProxy.BTD700
  alias UniversalProxy.FMA120
  alias UniversalProxy.Hardware
  alias UniversalProxy.System, as: Sys
  alias UniversalProxy.UART
  alias UniversalProxy.UART.History
  alias UniversalProxyWeb.Components.PortSparkline
  alias UniversalProxyWeb.MockData

  @refresh_interval 10_000

  @impl true
  def mount(_params, _session, socket) do
    ports = Hardware.list_ports()

    {packet_rate, snapshots} =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "uart:port_opened")
        Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "uart:port_closed")
        Phoenix.PubSub.subscribe(UniversalProxy.PubSub, History.packet_rate_topic())
        Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "sendspin:output_added")
        Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "sendspin:output_removed")
        Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "sendspin:state")
        # FlooGoo FMA120 control-channel state (firmware, codec, mode, devices).
        Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "fma120:state")
        # Sennheiser BTD 700 control-channel state (firmware, mode, codecs,
        # dongle/LE/sink status, Auracast broadcast info).
        Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "btd700:state")
        # USB Bluetooth radios surface in the hardware list too; the radio
        # list (incl. in_use?) is rebroadcast on enumeration change.
        Phoenix.PubSub.subscribe(UniversalProxy.PubSub, Bluetooth.radios_topic())
        # Paired-but-disconnected BT speakers show in the audio summary as
        # Disconnected (their durable surface); refresh on connection events.
        Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "bluetooth:audio")
        :timer.send_interval(@refresh_interval, self(), :refresh)
        {History.packets_per_minute(), reconcile_throughputs(%{}, ports)}
      else
        {0, %{}}
      end

    {:ok,
     socket
     |> assign(:page_title, "Overview")
     |> assign(:target, Sys.device_summary())
     |> assign(:selected_port, nil)
     |> assign(:selected_fma120, nil)
     |> assign(:fma120_states, if(connected?(socket), do: seed_fma120_states(), else: %{}))
     |> assign(:selected_btd700, nil)
     |> assign(:btd700_states, if(connected?(socket), do: seed_btd700_states(), else: %{}))
     |> assign(:throughput_snapshots, snapshots)
     |> assign(:packet_rate, packet_rate)
     |> assign(:pending_kind_change, nil)
     |> assign(:usb_hubs, Hardware.usb_hubs())
     |> assign(:audio_outputs, build_audio_index(Audio.list_outputs()))
     |> assign(:bt_radios, Bluetooth.list_radios())
     |> assign(:bt_headphones, AudioManager.list_headphones())
     |> set_ports(ports)}
  end

  @impl true
  def handle_event("select_port", %{"id" => id}, socket) do
    {:noreply, assign(socket, :selected_port, id)}
  end

  def handle_event("close_drawer", _params, socket) do
    {:noreply, assign(socket, :selected_port, nil)}
  end

  def handle_event("ignore", _params, socket), do: {:noreply, socket}

  # ── FMA120 control drawer ─────────────────────────────────────────────

  def handle_event("select_fma120", %{"key" => b64}, socket) do
    case decode_key(b64) do
      {:ok, key} -> {:noreply, assign(socket, :selected_fma120, key)}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_event("close_fma120_drawer", _params, socket) do
    {:noreply, assign(socket, :selected_fma120, nil)}
  end

  def handle_event("fma120_set_mode", %{"key" => b64, "mode" => mode}, socket) do
    with_fma120(socket, b64, fn key ->
      FMA120.set_audio_mode(key, fma120_mode_atom(mode))
    end)
  end

  def handle_event("fma120_scan", %{"key" => b64}, socket) do
    with_fma120(socket, b64, &FMA120.inquiry/1)
  end

  def handle_event("fma120_connect", %{"key" => b64, "index" => idx}, socket) do
    case parse_index(idx) do
      {:ok, index} -> with_fma120(socket, b64, &FMA120.connect(&1, index))
      :error -> {:noreply, socket}
    end
  end

  def handle_event("fma120_disconnect", %{"key" => b64}, socket) do
    with_fma120(socket, b64, &FMA120.disconnect/1)
  end

  def handle_event("fma120_forget", %{"key" => b64, "index" => idx}, socket) do
    case parse_index(idx) do
      {:ok, index} -> with_fma120(socket, b64, &FMA120.clear_paired(&1, index))
      :error -> {:noreply, socket}
    end
  end

  def handle_event("fma120_set_le_pref", %{"key" => b64, "pref" => pref}, socket) do
    pref_atom = if pref == "lea", do: :lea, else: :a2dp
    with_fma120(socket, b64, fn key -> FMA120.set_le_preference(key, pref_atom) end)
  end

  def handle_event("fma120_set_discoverable", %{"key" => b64} = params, socket) do
    on? = params["on"] in ["true", "on", true]
    with_fma120(socket, b64, fn key -> FMA120.set_discoverable(key, on?) end)
  end

  def handle_event("fma120_toggle_led", %{"key" => b64}, socket) do
    with_fma120(socket, b64, fn key ->
      features = get_in(socket.assigns.fma120_states, [key, :features]) || %{}
      FMA120.set_features(key, toggle_led_bitmask(features))
    end)
  end

  def handle_event("fma120_set_bcast_name", %{"key" => b64, "name" => name}, socket) do
    with_fma120(socket, b64, fn key -> FMA120.set_broadcast_name(key, name) end)
  end

  def handle_event("fma120_set_bcast_enc", %{"key" => b64} = params, socket) do
    with_fma120(socket, b64, fn key ->
      FMA120.set_broadcast_encryption(key, params["pass"] || "")
    end)
  end

  # Flip one broadcast-mode bit (quality / usb-volume) and re-send the byte.
  def handle_event("fma120_toggle_bcast_bit", %{"key" => b64, "bit" => bit}, socket) do
    with_fma120(socket, b64, fn key ->
      current = bcast_mode_byte(socket.assigns.fma120_states[key])
      FMA120.set_broadcast_mode(key, Bitwise.bxor(current, bit_value(bit)))
    end)
  end

  # ── BTD 700 control drawer ────────────────────────────────────────────

  def handle_event("select_btd700", %{"key" => b64}, socket) do
    case decode_btd700_key(b64) do
      {:ok, key} -> {:noreply, assign(socket, :selected_btd700, key)}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_event("close_btd700_drawer", _params, socket) do
    {:noreply, assign(socket, :selected_btd700, nil)}
  end

  def handle_event("btd700_set_mode", %{"key" => b64, "mode" => mode}, socket) do
    with_btd700(socket, b64, fn key -> BTD700.set_audio_mode(key, btd700_mode_atom(mode)) end)
  end

  # Toggle one codec bit against the SAVED/current `codec_in_use` mask and
  # send the full resulting atom list — the wire has no single-codec
  # selector (`BTD700.set_codec_mask/2` always writes the whole mask).
  def handle_event("btd700_toggle_codec", %{"key" => b64, "codec" => codec}, socket) do
    case btd700_codec_atom(codec) do
      nil ->
        {:noreply, socket}

      codec_atom ->
        with_btd700(socket, b64, fn key ->
          current = btd700_codec_list(get_in(socket.assigns.btd700_states, [key, :codec_in_use]))

          updated =
            if codec_atom in current,
              do: List.delete(current, codec_atom),
              else: [codec_atom | current]

          BTD700.set_codec_mask(key, updated)
        end)
    end
  end

  def handle_event("btd700_connect", %{"key" => b64}, socket) do
    with_btd700(socket, b64, &BTD700.connect/1)
  end

  def handle_event("btd700_disconnect", %{"key" => b64}, socket) do
    with_btd700(socket, b64, &BTD700.disconnect/1)
  end

  # Broadcast on/off is a toggle: read the current tri-field broadcast info,
  # flip just `state`, and resend the whole map (the wire command bundles
  # state/encryption/quality in one write).
  def handle_event("btd700_set_bcast_state", %{"key" => b64}, socket) do
    with_btd700(socket, b64, fn key ->
      info = btd700_broadcast_info(btd700_state_for(socket, key))
      new_state = if info.state == :on_public, do: :off_private, else: :on_public
      BTD700.set_broadcast_info(key, %{info | state: new_state})
    end)
  end

  def handle_event("btd700_set_bcast_quality", %{"key" => b64, "quality" => quality}, socket) do
    with_btd700(socket, b64, fn key ->
      info = btd700_broadcast_info(btd700_state_for(socket, key))
      BTD700.set_broadcast_info(key, %{info | quality: btd700_quality_atom(quality)})
    end)
  end

  def handle_event("btd700_set_bcast_enc", %{"key" => b64}, socket) do
    with_btd700(socket, b64, fn key ->
      info = btd700_broadcast_info(btd700_state_for(socket, key))
      BTD700.set_broadcast_info(key, %{info | encryption: not info.encryption})
    end)
  end

  def handle_event("btd700_set_bcast_name", %{"key" => b64, "name" => name}, socket) do
    with_btd700(socket, b64, fn key -> BTD700.set_broadcast_name(key, name) end)
  end

  # The passphrase is fire-and-forget and never assigned to socket state, so
  # it can never be echoed back into the rendered key-form input.
  def handle_event("btd700_set_bcast_key", %{"key" => b64, "secret" => secret}, socket) do
    with_btd700(socket, b64, fn key -> BTD700.set_broadcast_key(key, secret) end)
  end

  def handle_event("btd700_factory_reset", %{"key" => b64}, socket) do
    with_btd700(socket, b64, &BTD700.factory_reset/1)
  end

  # Peripheral rows (USB audio / USB Bluetooth) are claimed automatically
  # by their built-in service, so clicking routes to the managing tab
  # rather than opening the serial-port drawer.
  def handle_event("goto_tab", %{"path" => path}, socket)
      when path in ["/audio", "/bluetooth"] do
    {:noreply, push_navigate(socket, to: path)}
  end

  def handle_event(
        "request_kind_change",
        %{"port" => port_id, "kind" => new_kind},
        socket
      )
      when new_kind in ["ttl", "rs232", "rs485"] do
    port = Enum.find(socket.assigns.ports, &(&1.id == port_id))

    cond do
      is_nil(port) or port.in_use ->
        {:noreply, socket}

      to_string(port.kind) == new_kind ->
        # User picked the kind that's already in effect — nothing to do.
        {:noreply, socket}

      port.configured ->
        {:noreply,
         assign(socket, :pending_kind_change, %{
           port_id: port_id,
           new_kind: new_kind,
           from_label: port.kind_label
         })}

      true ->
        {:noreply, apply_kind_change(socket, port_id, new_kind)}
    end
  end

  def handle_event("confirm_kind_change", _params, socket) do
    case socket.assigns.pending_kind_change do
      %{port_id: id, new_kind: kind} ->
        socket =
          socket
          |> apply_kind_change(id, kind)
          |> assign(:pending_kind_change, nil)
          |> put_flash(:info, "Port reconfigured. Restart the ESPHome client to pick up changes.")

        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_kind_change", _params, socket) do
    {:noreply, assign(socket, :pending_kind_change, nil)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, refresh_ports(socket)}
  end

  def handle_info({:uart_port_opened, _info}, socket) do
    {:noreply, refresh_ports(socket)}
  end

  def handle_info({:uart_port_closed, _info}, socket) do
    {:noreply, refresh_ports(socket)}
  end

  # Per-port throughput updates land here once per second per
  # subscribed port. Storing the samples in socket assigns would dirty
  # the entire table on every tick; instead, we route the update
  # straight to the matching `PortSparkline` LiveComponent(s) so only
  # their assigns are re-rendered. There are up to two instances per
  # port — one in the table row, one in the drawer (when open).
  def handle_info({:uart_throughput, %{name: name, samples: samples}}, socket) do
    port = Enum.find(socket.assigns.ports, &(&1.ha_name == name))

    if port do
      Phoenix.LiveView.send_update(PortSparkline,
        id: table_spark_id(port.id),
        samples: samples
      )

      if socket.assigns.selected_port == port.id do
        Phoenix.LiveView.send_update(PortSparkline,
          id: drawer_spark_id(port.id),
          samples: samples
        )
      end
    end

    {:noreply, socket}
  end

  def handle_info({:uart_packet_rate, count}, socket) do
    {:noreply, assign(socket, :packet_rate, count)}
  end

  def handle_info({:bluetooth_radios, radios}, socket) do
    {:noreply, assign(socket, :bt_radios, radios)}
  end

  # A BT connect/disconnect moves a speaker between the live audio list and
  # the durable Disconnected list — re-read the paired set so the summary
  # surfaces it either way.
  def handle_info({:bt_audio, :connection, _mac, _status}, socket) do
    {:noreply, assign(socket, :bt_headphones, AudioManager.list_headphones())}
  end

  def handle_info({:bt_audio, _kind, _mac, _payload}, socket), do: {:noreply, socket}

  def handle_info({:sendspin_output_added, output}, socket) do
    {:noreply, update(socket, :audio_outputs, &Map.put(&1, output.key, output))}
  end

  def handle_info({:sendspin_output_removed, %{key: key}}, socket) do
    {:noreply, update(socket, :audio_outputs, &Map.delete(&1, key))}
  end

  # Track binary-emitted connection events per key so the "Streaming" /
  # "Connected" / "Stopped" badge on the Overview row can flip without
  # re-fetching the output list. Server-originated `:sendspin_state`
  # partials (enable, rename, etc.) patch other fields on the same map.
  def handle_info({:sendspin_state, key, %{event: "connected"}}, socket) do
    {:noreply, update_audio_output(socket, key, %{connection: :connected})}
  end

  def handle_info({:sendspin_state, key, %{event: event}}, socket)
      when event in ["disconnected", "shutdown"] do
    # Disconnecting must clear the cached stream snapshot — the binary
    # can't be playing audio over a socket it doesn't have. Without
    # this, the row would read "Streaming" right up until the next
    # `stream_end` event, which never arrives because the server is
    # gone.
    {:noreply, update_audio_output(socket, key, %{connection: :disconnected, stream: nil})}
  end

  def handle_info({:sendspin_state, key, %{event: "stream_start"} = payload}, socket) do
    {:noreply, update_audio_output(socket, key, %{stream: stream_summary(payload)})}
  end

  def handle_info({:sendspin_state, key, %{event: "stream_end"}}, socket) do
    {:noreply, update_audio_output(socket, key, %{stream: nil})}
  end

  def handle_info({:sendspin_state, key, %{enabled: enabled?}}, socket)
      when is_boolean(enabled?) do
    {:noreply, update_audio_output(socket, key, %{enabled: enabled?})}
  end

  def handle_info({:sendspin_state, key, %{friendly_name: name}}, socket) when is_binary(name) do
    {:noreply, update_audio_output(socket, key, %{friendly_name: name})}
  end

  # The audio summary row renders a mini volume bar driven by the
  # output's :volume and :muted, so server-originated partials for
  # those fields must patch through to the cached map. (Without this
  # the bar would freeze at the mount-time value until the user
  # navigates away and back.)
  def handle_info({:sendspin_state, key, %{volume: volume}}, socket) when is_integer(volume) do
    {:noreply, update_audio_output(socket, key, %{volume: volume})}
  end

  def handle_info({:sendspin_state, key, %{muted: muted}}, socket) when is_boolean(muted) do
    {:noreply, update_audio_output(socket, key, %{muted: muted})}
  end

  def handle_info({:sendspin_state, _key, _partial}, socket), do: {:noreply, socket}

  # Merge an FMA120 control-state partial into the cached per-device state.
  # The `:devices` map (keyed by MAC) is merged, not replaced, so individual
  # device-row updates accumulate rather than clobber the list.
  def handle_info({:fma120_state, key, partial}, socket) do
    states = socket.assigns.fma120_states
    existing = Map.get(states, key, %{})

    merged =
      case partial do
        %{devices: new_devices} ->
          devices = Map.merge(Map.get(existing, :devices, %{}), new_devices)
          existing |> Map.merge(partial) |> Map.put(:devices, devices)

        _ ->
          Map.merge(existing, partial)
      end

    {:noreply, assign(socket, :fma120_states, Map.put(states, key, merged))}
  end

  # Merge a BTD 700 control-state partial (always `%{one_field => value}`,
  # per `DeviceWorker.cache_and_broadcast/3`) into the cached per-device
  # state. No nested collection to merge here (unlike FMA120's `:devices`
  # map), so a plain shallow merge suffices.
  def handle_info({:btd700_state, key, partial}, socket) do
    states = socket.assigns.btd700_states
    existing = Map.get(states, key, %{})
    merged = Map.merge(existing, scrub_btd700_partial(partial))
    {:noreply, assign(socket, :btd700_states, Map.put(states, key, merged))}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Refresh the port list AND reconcile throughput subscriptions so new
  # hot-plugged adapters get a live sparkline and removed ones stop
  # leaking subscriptions to History. Short-circuits when the port list
  # is unchanged — the 10s `:refresh` tick normally lands here with the
  # same ports, and re-assigning would force a full table re-render.
  defp refresh_ports(socket) do
    ports = Hardware.list_ports()
    hubs = Hardware.usb_hubs()

    socket =
      socket
      |> assign(:target, Sys.device_summary())
      |> maybe_assign(:usb_hubs, hubs)

    if ports == socket.assigns.ports do
      socket
    else
      socket
      |> assign(
        :throughput_snapshots,
        reconcile_throughputs(socket.assigns.throughput_snapshots, ports)
      )
      |> set_ports(ports)
    end
  end

  # Assign only when the value actually changed, so an unchanged sysfs scan
  # on the 10 s refresh tick doesn't churn the assign / re-render.
  defp maybe_assign(socket, key, value) do
    if Map.get(socket.assigns, key) == value, do: socket, else: assign(socket, key, value)
  end

  defp set_ports(socket, ports), do: assign(socket, :ports, ports)

  # Physical-slot summary for the device-summary card. Counts occupancy across
  # ALL device types (serial, USB audio, USB Bluetooth, and hubs) mapped to the
  # board's declared USB-A receptacles — not just serial ports, which made a
  # board full of audio/BT devices read "1/5". A slot is *active* when its
  # device is actually in use (serial proxied, audio streaming, or BT in use);
  # *idle* is occupied-but-not-active.
  defp slot_summary(ports, audio_outputs, bt_radios, hubs),
    do: slot_summary(ports, audio_outputs, bt_radios, hubs, Hardware.physical_slots())

  # Public (arity-5, slots injected) only so it can be unit-tested directly —
  # the host test env has no declared slots, so the slot-mode path is otherwise
  # unreachable via a live mount.
  @doc false
  def slot_summary(ports, audio_outputs, bt_radios, hubs, slots) do
    # {bus_path, active?} for every USB device the Overview knows about.
    # Only the physical bus path maps to a receptacle; an hci name never
    # does, so don't fall back to it (would inflate the dynamic-mode count).
    devices =
      for(p <- ports, p.connected, is_binary(p.slot_sub), do: {p.slot_sub, p.in_use}) ++
        for(
          o <- Map.values(audio_outputs),
          usb_audio?(o),
          is_binary(o.usb_port),
          do: {o.usb_port, not is_nil(o[:stream])}
        ) ++
        for(
          r <- bt_radios,
          r.bus == :usb,
          is_binary(r[:port]),
          do: {r[:port], r.in_use? == true}
        )

    case slots do
      nil ->
        # Dynamic target: no fixed receptacle map — report devices as N/N.
        occupied = devices |> Enum.map(&elem(&1, 0)) |> MapSet.new()
        active = for {p, true} <- devices, into: MapSet.new(), do: p
        n = MapSet.size(occupied)
        a = MapSet.size(active)
        %{in_use: n, total: n, active: a, idle: n - a}

      slots ->
        # A hub occupies its receptacle even though its function devices sit
        # one level below it.
        all = devices ++ for({path, _} <- hubs, do: {path, false})

        slot_of = fn path ->
          Enum.find(slots, &(path == &1 or String.starts_with?(path, &1 <> ".")))
        end

        to_slots = fn list ->
          list |> Enum.map(fn {p, _} -> slot_of.(p) end) |> Enum.reject(&is_nil/1) |> MapSet.new()
        end

        occupied = to_slots.(all)
        active = to_slots.(Enum.filter(all, &elem(&1, 1)))
        in_use = MapSet.size(occupied)
        a = MapSet.size(active)
        %{in_use: in_use, total: length(slots), active: a, idle: in_use - a}
    end
  end

  # Subscribe to History throughput for every port the table will draw
  # a sparkline for (`connected and configured`). Unsubscribe from any
  # name that is no longer in the desired set. The snapshots returned
  # by `throughput_subscribe_and_snapshot/1` are kept so newly mounted
  # `PortSparkline` LiveComponents can be seeded via `:initial_samples`
  # instead of waiting up to a full second for the first tick. Returns
  # a `%{name => samples}` map.
  defp reconcile_throughputs(existing, ports) do
    desired = throughput_target_names(ports)
    current = existing |> Map.keys() |> MapSet.new()

    MapSet.difference(current, desired)
    |> Enum.each(&History.throughput_unsubscribe/1)

    additions =
      desired
      |> MapSet.difference(current)
      |> Map.new(fn name -> {name, History.throughput_subscribe_and_snapshot(name)} end)

    existing
    |> Map.take(MapSet.to_list(desired))
    |> Map.merge(additions)
  end

  defp build_audio_index(outputs) do
    Map.new(outputs, fn output -> {output.key, output} end)
  end

  # Cheap projection of the binary's stream_start payload to a non-nil
  # term — the Overview row's badge only branches on `is_nil(stream)`,
  # so we don't need the full codec/rate/bit-depth breakdown that
  # AudioLive renders.
  defp stream_summary(payload) when is_map(payload) do
    %{codec: Map.get(payload, :codec)}
  end

  defp update_audio_output(socket, key, patch) do
    update(socket, :audio_outputs, fn outputs ->
      case Map.fetch(outputs, key) do
        {:ok, existing} -> Map.put(outputs, key, Map.merge(existing, patch))
        :error -> outputs
      end
    end)
  end

  defp throughput_target_names(ports) do
    for %{connected: true, configured: true, ha_name: name} <- ports,
        is_binary(name),
        into: MapSet.new(),
        do: name
  end

  defp table_spark_id(port_id), do: "spark-#{port_id}"
  defp drawer_spark_id(port_id), do: "drawer-spark-#{port_id}"

  defp apply_kind_change(socket, port_id, kind_str) do
    port = Enum.find(socket.assigns.ports, &(&1.id == port_id))

    if port && port.connected do
      key = {port.slot_sub, port.vendor_id, port.product_id}
      UART.save_config(key, save_params(kind_str, port.serial))
    end

    assign(socket, :ports, Hardware.list_ports())
  end

  # `Hardware.build_port/6` substitutes the em-dash placeholder for a
  # nil/missing serial number at render time. Don't let that placeholder
  # leak into DETS — pass `serial_number` only when the underlying
  # serial is real.
  defp save_params(kind_str, serial) do
    base = %{port_type: kind_str}

    case serial do
      s when is_binary(s) and s not in ["—", "-", ""] -> Map.put(base, :serial_number, s)
      _ -> base
    end
  end

  @impl true
  def render(assigns) do
    rows =
      hardware_rows(
        assigns.ports,
        peripherals(assigns.audio_outputs, assigns.bt_radios),
        assigns.usb_hubs
      )

    summary =
      slot_summary(assigns.ports, assigns.audio_outputs, assigns.bt_radios, assigns.usb_hubs)

    assigns =
      assigns
      |> assign(:hardware_rows, rows)
      |> assign(:slot_summary, summary)
      |> assign(:bt_disconnected, disconnected_bt(assigns.bt_headphones))

    ~H"""
    <div class="max-w-[1120px] mx-auto space-y-4">
      <.device_summary
        target={@target}
        connected={@slot_summary.in_use}
        active={@slot_summary.active}
        idle={@slot_summary.idle}
        total={@slot_summary.total}
        packet_rate={@packet_rate}
      />

      <.hardware_table
        rows={@hardware_rows}
        throughput_snapshots={@throughput_snapshots}
      />

      <.audio_outputs_card
        :if={map_size(@audio_outputs) > 0 or @bt_disconnected != []}
        outputs={@audio_outputs}
        bt_disconnected={@bt_disconnected}
        bt_radios={@bt_radios}
      />
    </div>

    <.maybe_port_drawer
      port={find_port(@ports, @selected_port)}
      throughput_snapshots={@throughput_snapshots}
    />

    <.fma120_drawer
      :if={@selected_fma120}
      key={@selected_fma120}
      encoded_key={encode_key(@selected_fma120)}
      state={Map.get(@fma120_states, @selected_fma120, %{})}
    />

    <.btd700_drawer
      :if={@selected_btd700}
      key={@selected_btd700}
      encoded_key={encode_key(@selected_btd700)}
      state={Map.get(@btd700_states, @selected_btd700, %{})}
    />

    <.modal
      open={@pending_kind_change != nil}
      on_close="cancel_kind_change"
      title="Change port type?"
      subtitle={
        @pending_kind_change &&
          "Reconfiguring this port from #{@pending_kind_change.from_label} to #{kind_label(@pending_kind_change.new_kind)} " <>
            "will drop any in-flight frames and force the ESPHome client to rebind. " <>
            "Existing automations referencing this port will need to be updated."
      }
    >
      <:footer>
        <.button variant={:ghost} size={:sm} phx-click="cancel_kind_change">Cancel</.button>
        <.button variant={:primary} size={:sm} phx-click="confirm_kind_change">
          Change type
        </.button>
      </:footer>
    </.modal>
    """
  end

  defp find_port(_ports, nil), do: nil
  defp find_port(ports, id), do: Enum.find(ports, &(&1.id == id))

  # ── FMA120 helpers ────────────────────────────────────────────────────

  # FlooGoo FMA120 USB BT-audio dongle (Flairmesh / Qualcomm-CSR).
  @fma120_vid 0x0A12
  @fma120_pid 0x4007

  defp fma120_key?({_slot, @fma120_vid, @fma120_pid}), do: true
  defp fma120_key?(_), do: false

  # Sennheiser BTD 700 USB BT-audio dongle (BTD 600, PID 0x3000, is a
  # different unsupported device — never widen this match).
  @btd700_vid 0x3542
  @btd700_pid 0x3001

  defp btd700_key?({_slot, @btd700_vid, @btd700_pid}), do: true
  defp btd700_key?(_), do: false

  # Seed the per-device control-state cache from the running context, so a
  # fresh mount renders current status without waiting for a broadcast.
  defp seed_fma120_states do
    FMA120.list_devices()
    |> Enum.reduce(%{}, fn %{key: key}, acc ->
      case FMA120.get_state(key) do
        {:ok, state} -> Map.put(acc, key, state)
        _ -> acc
      end
    end)
  rescue
    _ -> %{}
  end

  # Run an FMA120 control action by decoded key; result is fire-and-forget
  # (the device echoes state back over "fma120:state").
  defp with_fma120(socket, b64, fun) do
    case decode_key(b64) do
      {:ok, key} ->
        _ = fun.(key)
        {:noreply, socket}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  # ── BTD700 helpers ────────────────────────────────────────────────────

  # Seed the per-device control-state cache from the running context, so a
  # fresh mount renders current status without waiting for a broadcast.
  defp seed_btd700_states do
    BTD700.list_devices()
    |> Enum.reduce(%{}, fn %{key: key}, acc ->
      case BTD700.get_state(key) do
        {:ok, state} -> Map.put(acc, key, scrub_btd700_partial(state))
        _ -> acc
      end
    end)
  rescue
    _ -> %{}
  end

  # Protocol.decode/1 hands the broadcast name back as raw wire bytes
  # (deliberately never UTF-8-validated at the protocol layer). Rendered
  # HTML would survive invalid bytes, but the connected render's diff is
  # JSON-encoded and Jason raises on invalid UTF-8 — a buggy dongle name
  # would crash the LiveView. Scrub at the assign boundary; nil renders as
  # the usual empty/placeholder value.
  defp scrub_btd700_partial(%{broadcast_name: name} = partial) when is_binary(name) do
    if String.valid?(name), do: partial, else: %{partial | broadcast_name: nil}
  end

  defp scrub_btd700_partial(partial), do: partial

  # Run a BTD700 control action by decoded key; result is fire-and-forget
  # (the device echoes state back over "btd700:state").
  defp with_btd700(socket, b64, fun) do
    case decode_btd700_key(b64) do
      {:ok, key} ->
        _ = fun.(key)
        {:noreply, socket}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  defp btd700_state_for(socket, key), do: Map.get(socket.assigns.btd700_states, key, %{})

  defp btd700_mode_atom("gaming"), do: :gaming
  defp btd700_mode_atom("broadcast"), do: :broadcast
  defp btd700_mode_atom(_), do: :high_quality

  defp btd700_quality_atom("standard_24k"), do: :standard_24k
  defp btd700_quality_atom("high"), do: :high
  defp btd700_quality_atom(_), do: :standard_16k

  defp btd700_codec_atom("sbc"), do: :sbc
  defp btd700_codec_atom("aptx"), do: :aptx
  defp btd700_codec_atom("aptx_adaptive"), do: :aptx_adaptive
  defp btd700_codec_atom("aptx_lossless"), do: :aptx_lossless
  defp btd700_codec_atom("aptx_lite"), do: :aptx_lite
  defp btd700_codec_atom("lc3"), do: :lc3
  defp btd700_codec_atom(_), do: nil

  defp btd700_codec_list(list) when is_list(list), do: list
  defp btd700_codec_list(_), do: []

  # `broadcast_info` decodes to `%{state, encryption, quality}` with
  # `encryption` as the wire atom `:on`/`:off` — normalized here to a
  # boolean so callers (both the drawer render and the event handlers that
  # resend the full tri-field map) share one shape. Any other cache value
  # (nil before the handshake completes, or a length-guarded `%{raw: _}`)
  # falls back to the device's power-on defaults rather than crashing.
  defp btd700_broadcast_info(state) do
    case Map.get(state, :broadcast_info) do
      %{state: s, encryption: e, quality: q} = info
      when s in [:off_private, :on_public] and q in [:standard_16k, :standard_24k, :high] ->
        %{info | encryption: e == :on}

      _ ->
        %{state: :off_private, encryption: false, quality: :standard_16k}
    end
  end

  defp fma120_mode_atom("gaming"), do: :gaming
  defp fma120_mode_atom("broadcast"), do: :broadcast
  defp fma120_mode_atom(_), do: :high_quality

  # Returns `{:ok, index}` only for a clean 0..255 value; `:error` otherwise so
  # callers no-op rather than acting on device 0 for malformed/tampered input.
  defp parse_index(idx) when is_integer(idx) and idx in 0..255, do: {:ok, idx}

  defp parse_index(idx) when is_binary(idx) do
    case Integer.parse(idx) do
      {n, ""} when n in 0..255 -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_index(_), do: :error

  defp toggle_led_bitmask(features) do
    base = features_to_bitmask(features)
    Bitwise.bxor(base, 0x01)
  end

  defp features_to_bitmask(features) when is_map(features) do
    [{:led, 0x01}, {:aptx_lossless, 0x02}, {:gatt_client, 0x04}, {:usb_audio_source, 0x08}]
    |> Enum.reduce(0, fn {flag, bit}, acc ->
      if Map.get(features, flag), do: Bitwise.bor(acc, bit), else: acc
    end)
  end

  defp features_to_bitmask(_), do: 0

  # Re-pack the cached decoded broadcast-mode map into its byte so a single
  # bit can be flipped (inverse of Protocol's BM decode).
  defp bcast_mode_byte(%{broadcast_mode: bm}) when is_map(bm), do: pack_bm(bm)
  defp bcast_mode_byte(_), do: 0

  defp pack_bm(bm) do
    0
    |> Bitwise.bor(profile_enc_bits(bm))
    |> set_bit(0x04, bm[:quality] == :high)
    |> set_bit(0x08, bm[:usb_playback] == :stop_immediately)
    |> Bitwise.bor(latency_bits(bm[:latency]))
    |> set_bit(0x40, bm[:quality_range] == :both)
    |> set_bit(0x80, bm[:usb_volume] == :follow)
  end

  defp profile_enc_bits(%{profile: :tmap, encryption: :unencrypted}), do: 0
  defp profile_enc_bits(%{profile: :tmap, encryption: :encrypted}), do: 1
  defp profile_enc_bits(%{profile: :pbp, encryption: :unencrypted}), do: 2
  defp profile_enc_bits(%{profile: :pbp, encryption: :encrypted}), do: 3
  defp profile_enc_bits(_), do: 0

  defp latency_bits(:lowest), do: 0x10
  defp latency_bits(:lower), do: 0x20
  defp latency_bits(:default), do: 0x30
  defp latency_bits(_), do: 0x00

  defp set_bit(byte, mask, true), do: Bitwise.bor(byte, mask)
  defp set_bit(byte, _mask, _), do: byte

  defp bit_value("quality"), do: 0x04
  defp bit_value("usb_volume"), do: 0x80
  defp bit_value(_), do: 0x00

  # URL-safe base64 of `:erlang.term_to_binary/1`, matching AudioLive's
  # opaque-key encoding. Decoded with `[:safe]` + a shape assertion so a
  # tampered param can't inject arbitrary atoms.
  defp encode_key(key), do: key |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)

  defp decode_key(b64) when is_binary(b64) do
    with {:ok, bin} <- Base.url_decode64(b64, padding: false),
         true <- byte_size(bin) <= 256,
         {:ok, term} <- safe_binary_to_term(bin),
         true <- fma120_key?(term) do
      {:ok, term}
    else
      _ -> {:error, :invalid_key}
    end
  end

  defp decode_key(_), do: {:error, :invalid_key}

  defp decode_btd700_key(b64) when is_binary(b64) do
    with {:ok, bin} <- Base.url_decode64(b64, padding: false),
         true <- byte_size(bin) <= 256,
         {:ok, term} <- safe_binary_to_term(bin),
         true <- btd700_key?(term) do
      {:ok, term}
    else
      _ -> {:error, :invalid_key}
    end
  end

  defp decode_btd700_key(_), do: {:error, :invalid_key}

  defp safe_binary_to_term(bin) do
    {:ok, :erlang.binary_to_term(bin, [:safe])}
  rescue
    _ -> :error
  end

  attr(:port, :map, default: nil)
  attr(:throughput_snapshots, :map, required: true)

  defp maybe_port_drawer(assigns) do
    ~H"""
    <.port_drawer
      :if={@port}
      port={@port}
      initial_samples={@throughput_snapshots[@port.ha_name]}
    />
    """
  end

  defp kind_label("ttl"), do: "TTL"
  defp kind_label("rs232"), do: "RS-232"
  defp kind_label("rs485"), do: "RS-485"
  defp kind_label(_), do: ""

  # ── Device summary card ───────────────────────────────────────────────
  attr(:target, :map, required: true)
  attr(:connected, :integer, required: true)
  attr(:active, :integer, required: true)
  attr(:idle, :integer, required: true)
  attr(:total, :integer, required: true)
  attr(:packet_rate, :integer, required: true)

  defp device_summary(assigns) do
    ~H"""
    <.card padding={:none} class="!p-[18px_22px] grid grid-cols-[auto_1fr] gap-5 items-center">
      <div class="flex items-center gap-3.5">
        <div class="w-11 h-11 rounded-md bg-accent-soft text-accent flex items-center justify-center">
          <.icon name={:plug} size={22} />
        </div>
        <div>
          <div class="text-md font-semibold tracking-tight">{@target.hostname}</div>
          <div class="text-sm text-fg-3 mt-0.5">
            {@target.hardware} · <span class="font-mono">{@target.ip}</span> · firmware {@target.firmware}
          </div>
        </div>
      </div>
      <div class="flex gap-7 justify-end pr-2">
        <.summary_stat label="Slots in use" value={@connected} total={@total} tint="text-accent" />
        <.summary_stat label="Active" value={@active} tint="text-success" />
        <.summary_stat label="Idle" value={@idle} tint="text-warning" />
        <.summary_stat label="Packets/min" value={@packet_rate} tint="text-fg-1" />
      </div>
    </.card>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :integer, required: true)
  attr(:total, :integer, default: nil)
  attr(:tint, :string, default: "text-fg-1")

  defp summary_stat(assigns) do
    ~H"""
    <div class="text-center">
      <div class={["text-xl font-semibold tabular-nums leading-tight", @tint]}>
        {@value}<span :if={@total} class="text-fg-3 text-base font-normal">/{@total}</span>
      </div>
      <div class="text-[11px] text-fg-3 uppercase tracking-caps font-semibold mt-0.5">
        {@label}
      </div>
    </div>
    """
  end

  # ── Connected hardware table ──────────────────────────────────────────
  # `rows` is the ordered, tagged list from `hardware_rows/2`: `{:port, _}`
  # for a physical USB slot, `{:peripheral, _}` for a service-claimed device
  # (a promoted slot or a trailing audio/BT row).
  attr(:rows, :list, required: true)
  attr(:throughput_snapshots, :map, required: true)

  defp hardware_table(assigns) do
    ~H"""
    <.card padding={:none} class="overflow-hidden">
      <div class="flex items-center px-4 py-3.5 border-b border-border-1">
        <div class="text-base font-semibold">Connected hardware</div>
      </div>
      <table class="w-full table-fixed border-collapse">
        <colgroup>
          <col class="w-[88px]" />
          <col />
          <col class="w-[132px]" />
          <col class="w-[200px]" />
          <col class="w-[110px]" />
          <col class="w-[130px]" />
        </colgroup>
        <thead>
          <tr class="bg-sunken">
            <th class="text-left text-xs font-bold uppercase tracking-wide text-fg-1 px-4 py-2.5 border-b border-border-1">
              Slot
            </th>
            <th class="text-left text-xs font-bold uppercase tracking-wide text-fg-1 px-4 py-2.5 border-b border-border-1">
              Adapter
            </th>
            <th class="text-left text-xs font-bold uppercase tracking-wide text-fg-1 px-4 py-2.5 border-b border-border-1">
              Type
            </th>
            <th class="text-left text-xs font-bold uppercase tracking-wide text-fg-1 px-4 py-2.5 border-b border-border-1">
              In use by
            </th>
            <th class="text-left text-xs font-bold uppercase tracking-wide text-fg-1 px-4 py-2.5 border-b border-border-1">
              Throughput
            </th>
            <th class="text-left text-xs font-bold uppercase tracking-wide text-fg-1 px-4 py-2.5 border-b border-border-1">
              Status
            </th>
          </tr>
        </thead>
        <tbody>
          <%!-- Slots render in declared hardware order. A {:peripheral, _}
               is a USB audio card or Bluetooth radio: claimed automatically
               by its built-in service, so it routes to the managing tab on
               click instead of the port drawer. --%>
          <.hardware_row
            :for={row <- @rows}
            row={row}
            throughput_snapshots={@throughput_snapshots}
          />
        </tbody>
      </table>
    </.card>
    """
  end

  # ── Row dispatcher ────────────────────────────────────────────────────
  # Renders a port row or a peripheral row from a tagged tuple, keeping the
  # ordering decided by `hardware_rows/2` (which carries no row-type info
  # into the template otherwise).
  attr(:row, :any, required: true)
  attr(:throughput_snapshots, :map, required: true)

  defp hardware_row(%{row: {:port, port}} = assigns) do
    assigns = assign(assigns, :port, port)

    ~H"""
    <.port_row port={@port} throughput_snapshots={@throughput_snapshots} />
    """
  end

  defp hardware_row(%{row: {:peripheral, p}} = assigns) do
    assigns = assign(assigns, :p, p)

    ~H"""
    <.peripheral_row p={@p} />
    """
  end

  defp hardware_row(%{row: {:hub, hub}} = assigns) do
    assigns = assign(assigns, :hub, hub)

    ~H"""
    <.hub_row hub={@hub} />
    """
  end

  # Defensive: `hardware_rows/3` only ever emits the tags above, so an
  # unknown shape means that contract changed — drop the row rather than
  # crash the whole table render.
  defp hardware_row(assigns) do
    Logger.warning("hardware_row/1: unexpected row shape, skipping: #{inspect(assigns.row)}")
    ~H""
  end

  # ── Single row in the hardware table ──────────────────────────────────
  attr(:port, :map, required: true)
  attr(:throughput_snapshots, :map, required: true)

  defp port_row(assigns) do
    assigns =
      assigns
      |> assign(:status, MockData.port_status(assigns.port))
      |> assign(:depth, Map.get(assigns.port, :depth, 0))

    ~H"""
    <tr
      class="cursor-pointer hover:bg-sunken last:[&_td]:border-b-0"
      phx-click="select_port"
      phx-value-id={@port.id}
    >
      <td class={["px-4 py-4 text-sm text-fg-1 border-b border-border-2 align-middle", @depth > 0 && "pl-10"]}>
        <div class="text-xs font-semibold text-fg-2 tracking-wide">
          <span :if={@depth > 0} class="text-fg-4 mr-1">└</span>{@port.slot}
        </div>
        <div class="font-mono text-[11px] text-fg-3 mt-0.5">{@port.slot_sub}</div>
      </td>
      <td class="px-4 py-4 text-sm text-fg-1 border-b border-border-2 align-middle">
        <.adapter_cell port={@port} />
      </td>
      <td class="px-4 py-4 text-sm text-fg-1 border-b border-border-2 align-middle">
        <.type_cell port={@port} />
      </td>
      <td class="px-4 py-4 text-sm text-fg-1 border-b border-border-2 align-middle">
        <a
          :if={@port.user}
          href={@port.user_href}
          phx-click="ignore"
          onclick="event.stopPropagation()"
          class="text-accent text-base no-underline"
        >
          {@port.user}
        </a>
        <span :if={!@port.user} class="text-fg-3 text-base">
          {if @port.connected, do: "Not claimed", else: "—"}
        </span>
      </td>
      <td class="px-4 py-4 text-sm text-fg-1 border-b border-border-2 align-middle">
        <.live_component
          :if={@port.connected and @port.configured}
          module={PortSparkline}
          id={"spark-#{@port.id}"}
          port_kind={@port.kind}
          variant={:compact}
          initial_samples={@throughput_snapshots[@port.ha_name]}
        />
        <span :if={!(@port.connected and @port.configured)} class="text-fg-4 text-base">
          —
        </span>
      </td>
      <td class="px-4 py-4 text-sm text-fg-1 border-b border-border-2 align-middle">
        <.badge variant={@status.variant} dot>{@status.label}</.badge>
      </td>
    </tr>
    """
  end

  # ── Peripheral row (USB sound card / USB Bluetooth radio) ─────────────
  # Same six-column shape as a port row, but the whole row navigates to
  # the managing tab (these devices are claimed by a built-in service, not
  # configured here). No throughput sparkline — neither service exposes a
  # per-device byte rate.
  attr(:p, :map, required: true)

  # FMA120 rows open the control drawer (select_fma120); every other
  # peripheral routes to its managing tab (goto_tab). Same six-column body.
  defp peripheral_row(%{p: %{fma120?: true}} = assigns) do
    ~H"""
    <tr
      class="cursor-pointer hover:bg-sunken last:[&_td]:border-b-0"
      phx-click="select_fma120"
      phx-value-key={@p.fma120_key}
    >
      <.peripheral_cells p={@p} />
    </tr>
    """
  end

  # BTD 700 rows open their own control drawer (select_btd700). Distinct
  # VID:PID from FMA120, so this clause can never shadow (or be shadowed
  # by) the fma120? clause above.
  defp peripheral_row(%{p: %{btd700?: true}} = assigns) do
    ~H"""
    <tr
      class="cursor-pointer hover:bg-sunken last:[&_td]:border-b-0"
      phx-click="select_btd700"
      phx-value-key={@p.btd700_key}
    >
      <.peripheral_cells p={@p} />
    </tr>
    """
  end

  defp peripheral_row(assigns) do
    ~H"""
    <tr
      class="cursor-pointer hover:bg-sunken last:[&_td]:border-b-0"
      phx-click="goto_tab"
      phx-value-path={@p.tab}
    >
      <.peripheral_cells p={@p} />
    </tr>
    """
  end

  attr(:p, :map, required: true)

  defp peripheral_cells(assigns) do
    assigns = assign(assigns, :depth, Map.get(assigns.p, :depth, 0))

    ~H"""
    <td class={["px-4 py-4 text-sm text-fg-1 border-b border-border-2 align-middle", @depth > 0 && "pl-10"]}>
      <div class="text-xs font-semibold text-fg-2 tracking-wide">
        <span :if={@depth > 0} class="text-fg-4 mr-1">└</span>{@p.slot}
      </div>
      <div class="font-mono text-[11px] text-fg-3 mt-0.5">{@p.sub}</div>
    </td>
    <td class="px-4 py-4 text-sm text-fg-1 border-b border-border-2 align-middle">
      <div class="flex items-center gap-3">
        <div class={["w-8 h-8 rounded-sm flex items-center justify-center flex-none", @p.soft_class]}>
          <.port_glyph kind={@p.kind} size={18} />
        </div>
        <div class="min-w-0">
          <div class="text-base font-medium text-fg-1 truncate">{@p.name}</div>
          <div class="text-sm text-fg-3 mt-px">{@p.detail}</div>
        </div>
      </div>
    </td>
    <td class="px-4 py-4 text-sm text-fg-1 border-b border-border-2 align-middle">
      <div class="flex items-center gap-2">
        <span class={["w-1.5 h-1.5 rounded-full flex-none", @p.dot_class]}></span>
        <span class="text-sm text-fg-1">{@p.type_label}</span>
      </div>
    </td>
    <td class="px-4 py-4 text-sm text-fg-1 border-b border-border-2 align-middle">
      <.link
        navigate={@p.tab}
        phx-click="ignore"
        onclick="event.stopPropagation()"
        class="text-accent text-base no-underline"
      >
        {@p.managed_by}
      </.link>
    </td>
    <td class="px-4 py-4 text-sm text-fg-1 border-b border-border-2 align-middle">
      <span class="text-fg-4 text-base">—</span>
    </td>
    <td class="px-4 py-4 text-sm text-fg-1 border-b border-border-2 align-middle">
      <.badge variant={@p.status.variant} dot>{@p.status.label}</.badge>
    </td>
    """
  end

  # ── USB hub row (a hub occupying a physical slot; children indent below) ──
  attr(:hub, :map, required: true)

  defp hub_row(assigns) do
    ~H"""
    <tr class="last:[&_td]:border-b-0 bg-sunken/30">
      <td class="px-4 py-4 text-sm text-fg-1 border-b border-border-2 align-middle">
        <div class="text-xs font-semibold text-fg-2 tracking-wide">{@hub.slot}</div>
        <div class="font-mono text-[11px] text-fg-3 mt-0.5">{@hub.slot_sub}</div>
      </td>
      <td class="px-4 py-4 text-sm text-fg-1 border-b border-border-2 align-middle">
        <div class="flex items-center gap-3">
          <div class="w-8 h-8 rounded-sm bg-sunken flex items-center justify-center flex-none text-fg-3">
            <.icon name={:plug} size={18} />
          </div>
          <div class="min-w-0">
            <div class="text-base font-medium text-fg-1 truncate">{@hub.name}</div>
            <div class="text-sm text-fg-3 mt-px font-mono">{@hub.vidpid}</div>
          </div>
        </div>
      </td>
      <td class="px-4 py-4 text-sm text-fg-1 border-b border-border-2 align-middle">
        <span class="text-sm text-fg-1">USB hub</span>
      </td>
      <td class="px-4 py-4 text-sm text-fg-1 border-b border-border-2 align-middle">
        <span class="text-fg-3 text-base">—</span>
      </td>
      <td class="px-4 py-4 text-sm text-fg-1 border-b border-border-2 align-middle">
        <span class="text-fg-4 text-base">—</span>
      </td>
      <td class="px-4 py-4 text-sm text-fg-1 border-b border-border-2 align-middle">
        <.badge variant={:neutral} dot>Hub</.badge>
      </td>
    </tr>
    """
  end

  # ── FMA120 control drawer ─────────────────────────────────────────────
  # Mode-driven: the AM audio-mode is the 1:1-vs-Auracast switch, so the
  # drawer renders ONE body at a time (high-quality/gaming → unicast,
  # broadcast → Auracast).
  attr(:key, :any, required: true)
  attr(:encoded_key, :string, required: true)
  attr(:state, :map, required: true)

  defp fma120_drawer(assigns) do
    mode = get_in(assigns.state, [:audio_mode, :quality]) || :high_quality
    # Keyed by MAC; sort by index (nil-safe) then MAC for a stable order.
    devices =
      assigns.state
      |> Map.get(:devices, %{})
      |> Map.values()
      |> Enum.sort_by(&{&1[:index] || 0, &1[:mac]})

    assigns = assigns |> assign(:mode, mode) |> assign(:devices, devices)

    ~H"""
    <div class="fixed inset-0 z-[90] flex justify-end animate-fade">
      <div phx-click="close_fma120_drawer" class="absolute inset-0 bg-overlay"></div>
      <div class="relative w-[440px] bg-raised h-full shadow-lg overflow-auto animate-slide-in flex flex-col">
        <%!-- Header --%>
        <div class="px-6 py-5 border-b border-border-1 flex items-start gap-3">
          <div class="w-10 h-10 rounded-md bg-audio-soft text-audio flex items-center justify-center">
            <.speaker_glyph size={20} />
          </div>
          <div class="flex-1 min-w-0">
            <div class="text-xs font-bold text-fg-3 tracking-caps">FlooGoo FMA120</div>
            <div class="text-lg font-semibold tracking-tight mt-0.5">
              {@state[:version] && "Firmware #{@state[:version]}" || "Bluetooth audio dongle"}
            </div>
            <div class="mt-2 text-sm text-fg-2">{fma120_status_line(@mode, @state)}</div>
          </div>
          <.button variant={:ghost} size={:sm} phx-click="close_fma120_drawer">
            <.icon name={:x} size={16} />
          </.button>
        </div>

        <%!-- Mode selector (segmented) --%>
        <div class="px-6 py-4 border-b border-border-1">
          <div class="text-xs font-semibold text-fg-3 uppercase tracking-caps mb-2">Audio mode</div>
          <div class="flex gap-1.5">
            <.fma120_mode_button key={@encoded_key} mode="high_quality" current={@mode} label="High Quality" />
            <.fma120_mode_button key={@encoded_key} mode="gaming" current={@mode} label="Gaming" />
            <.fma120_mode_button key={@encoded_key} mode="broadcast" current={@mode} label="Broadcast" />
          </div>
        </div>

        <%!-- Mode-driven body --%>
        <.fma120_broadcast_body :if={@mode == :broadcast} key={@encoded_key} state={@state} />
        <.fma120_unicast_body :if={@mode != :broadcast} key={@encoded_key} state={@state} devices={@devices} />

        <%!-- Footer --%>
        <div class="mt-auto px-6 py-4 border-t border-border-1 flex items-center gap-2 flex-wrap">
          <.button variant={:secondary} size={:sm} phx-click="fma120_toggle_led" phx-value-key={@encoded_key}>
            <.icon name={:plug} size={14} /> LED {if get_in(@state, [:features, :led]), do: "on", else: "off"}
          </.button>
          <div class="flex-1"></div>
          <.link navigate="/audio" class="text-sm text-accent font-medium hover:underline">
            Audio settings →
          </.link>
        </div>
      </div>
    </div>
    """
  end

  attr(:key, :string, required: true)
  attr(:mode, :string, required: true)
  attr(:current, :atom, required: true)
  attr(:label, :string, required: true)

  defp fma120_mode_button(assigns) do
    ~H"""
    <.button
      variant={if to_string(@current) == @mode, do: :primary, else: :secondary}
      size={:sm}
      phx-click="fma120_set_mode"
      phx-value-key={@key}
      phx-value-mode={@mode}
    >
      {@label}
    </.button>
    """
  end

  # 1:1 (unicast) body: LE-audio preference, scan, paired list, codec status.
  attr(:key, :string, required: true)
  attr(:state, :map, required: true)
  attr(:devices, :list, required: true)

  defp fma120_unicast_body(assigns) do
    ~H"""
    <div class="px-6 py-4 space-y-4">
      <%!-- Active codec --%>
      <div class="flex items-center gap-2">
        <span class="text-xs font-semibold text-fg-3 uppercase tracking-caps">Codec</span>
        <.badge variant={:neutral}>{fma120_codec_label(get_in(@state, [:active_codec, :codec]))}</.badge>
        <span :if={get_in(@state, [:active_codec, :rssi])} class="text-sm text-fg-3">
          {get_in(@state, [:active_codec, :rssi])} dBm
        </span>
      </div>

      <%!-- LE-audio preference --%>
      <div>
        <div class="text-xs font-semibold text-fg-3 uppercase tracking-caps mb-2">Profile preference</div>
        <div class="flex gap-1.5">
          <.button
            variant={if @state[:le_preference] == :a2dp, do: :primary, else: :secondary}
            size={:sm}
            phx-click="fma120_set_le_pref"
            phx-value-key={@key}
            phx-value-pref="a2dp"
          >
            A2DP
          </.button>
          <.button
            variant={if @state[:le_preference] == :lea, do: :primary, else: :secondary}
            size={:sm}
            phx-click="fma120_set_le_pref"
            phx-value-key={@key}
            phx-value-pref="lea"
          >
            LE Audio
          </.button>
        </div>
      </div>

      <%!-- Discover / scan --%>
      <div class="flex gap-2">
        <.button variant={:secondary} size={:sm} phx-click="fma120_scan" phx-value-key={@key}>
          <.icon name={:refresh} size={14} /> Scan
        </.button>
        <.button variant={:secondary} size={:sm} phx-click="fma120_set_discoverable" phx-value-key={@key} phx-value-on="true">
          Make discoverable
        </.button>
      </div>

      <%!-- Paired / recent devices --%>
      <div>
        <div class="text-xs font-semibold text-fg-3 uppercase tracking-caps mb-2">Devices</div>
        <div :if={@devices == []} class="text-sm text-fg-3">No paired devices yet.</div>
        <ul class="m-0 p-0 list-none space-y-2">
          <li :for={dev <- @devices} class="flex items-center gap-2">
            <div class="min-w-0 flex-1">
              <div class="text-base text-fg-1 truncate">{dev[:name] || dev[:mac]}</div>
              <div class="text-[11px] text-fg-3">{fma120_device_state(dev[:connection_state])}</div>
            </div>
            <.button variant={:secondary} size={:sm} phx-click="fma120_connect" phx-value-key={@key} phx-value-index={dev.index}>
              {if dev[:connection_state] == :connected, do: "Disconnect", else: "Connect"}
            </.button>
            <.button variant={:ghost} size={:sm} phx-click="fma120_forget" phx-value-key={@key} phx-value-index={dev.index}>
              Forget
            </.button>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  # Broadcast (Auracast) body: name, encryption, quality / usb-volume.
  attr(:key, :string, required: true)
  attr(:state, :map, required: true)

  defp fma120_broadcast_body(assigns) do
    ~H"""
    <div class="px-6 py-4 space-y-4">
      <form phx-submit="fma120_set_bcast_name">
        <input type="hidden" name="key" value={@key} />
        <label class="text-xs font-semibold text-fg-3 uppercase tracking-caps">Broadcast name</label>
        <div class="flex gap-2 mt-1">
          <input
            type="text"
            name="name"
            value={@state[:broadcast_name]}
            class="flex-1 bg-sunken border border-border-2 rounded-sm px-2 py-1 text-base text-fg-1"
            placeholder="Auracast name"
          />
          <.button variant={:primary} size={:sm} type="submit">Save</.button>
        </div>
      </form>

      <form phx-submit="fma120_set_bcast_enc">
        <input type="hidden" name="key" value={@key} />
        <label class="text-xs font-semibold text-fg-3 uppercase tracking-caps">
          Encryption {if @state[:broadcast_encryption] == :set, do: "(on)", else: "(off)"}
        </label>
        <div class="flex gap-2 mt-1">
          <input
            type="password"
            name="pass"
            maxlength="16"
            class="flex-1 bg-sunken border border-border-2 rounded-sm px-2 py-1 text-base text-fg-1"
            placeholder="Passphrase (blank = off)"
          />
          <.button variant={:primary} size={:sm} type="submit">Set</.button>
        </div>
      </form>

      <div>
        <div class="text-xs font-semibold text-fg-3 uppercase tracking-caps mb-2">Quality &amp; volume</div>
        <div class="flex gap-1.5 flex-wrap">
          <.button
            variant={if get_in(@state, [:broadcast_mode, :quality]) == :high, do: :primary, else: :secondary}
            size={:sm}
            phx-click="fma120_toggle_bcast_bit"
            phx-value-key={@key}
            phx-value-bit="quality"
          >
            High quality
          </.button>
          <.button
            variant={if get_in(@state, [:broadcast_mode, :usb_volume]) == :follow, do: :primary, else: :secondary}
            size={:sm}
            phx-click="fma120_toggle_bcast_bit"
            phx-value-key={@key}
            phx-value-bit="usb_volume"
          >
            Follow USB volume
          </.button>
        </div>
        <div class="text-[11px] text-fg-3 mt-2">
          Latency: {get_in(@state, [:broadcast_mode, :latency]) || "default"}
        </div>
      </div>
    </div>
    """
  end

  defp fma120_status_line(:broadcast, state) do
    case state[:le_audio_state] do
      s when s in [:broadcast_streaming, :broadcast_stream_starting] ->
        "Broadcasting '#{state[:broadcast_name] || "Auracast"}'"

      _ ->
        "Auracast idle"
    end
  end

  defp fma120_status_line(_mode, state) do
    case connected_device(state) do
      nil ->
        "Not connected"

      dev ->
        "Connected to #{dev[:name] || dev[:mac]} · #{fma120_codec_label(get_in(state, [:active_codec, :codec]))}"
    end
  end

  defp connected_device(state) do
    state
    |> Map.get(:devices, %{})
    |> Map.values()
    |> Enum.find(&(&1[:connection_state] == :connected))
  end

  defp fma120_device_state(:connected), do: "Connected"
  defp fma120_device_state(:disconnected), do: "Disconnected"
  defp fma120_device_state(:idle), do: "Paired"
  defp fma120_device_state(_), do: "Unknown"

  defp fma120_codec_label(nil), do: "—"

  defp fma120_codec_label(codec) do
    codec |> to_string() |> String.upcase() |> String.replace("_", " ")
  end

  # ── BTD 700 control drawer ─────────────────────────────────────────────
  # Mode-driven, same shape as the FMA120 drawer above: the `audio_mode` is
  # the 1:1-vs-Auracast switch, so exactly one body renders at a time.
  attr(:key, :any, required: true)
  attr(:encoded_key, :string, required: true)
  attr(:state, :map, required: true)

  defp btd700_drawer(assigns) do
    mode = get_in(assigns.state, [:audio_mode, :mode]) || :high_quality
    assigns = assign(assigns, :mode, mode)

    ~H"""
    <div class="fixed inset-0 z-[90] flex justify-end animate-fade">
      <div phx-click="close_btd700_drawer" class="absolute inset-0 bg-overlay"></div>
      <div class="relative w-[440px] bg-raised h-full shadow-lg overflow-auto animate-slide-in flex flex-col">
        <%!-- Header --%>
        <div class="px-6 py-5 border-b border-border-1 flex items-start gap-3">
          <div class="w-10 h-10 rounded-md bg-accent-soft text-accent flex items-center justify-center">
            <.icon name={:bluetooth} size={20} />
          </div>
          <div class="flex-1 min-w-0">
            <div class="text-xs font-bold text-fg-3 tracking-caps">Sennheiser BTD 700</div>
            <div class="text-lg font-semibold tracking-tight mt-0.5">
              {btd700_fw_label(@state)}
            </div>
            <div class="mt-2 text-sm text-fg-2">{btd700_status_line(@state)}</div>
          </div>
          <.button variant={:ghost} size={:sm} phx-click="close_btd700_drawer">
            <.icon name={:x} size={16} />
          </.button>
        </div>

        <%!-- Mode selector (segmented) --%>
        <div class="px-6 py-4 border-b border-border-1">
          <div class="text-xs font-semibold text-fg-3 uppercase tracking-caps mb-2">Audio mode</div>
          <div class="flex gap-1.5">
            <.btd700_mode_button key={@encoded_key} mode="high_quality" current={@mode} label="High Quality" />
            <.btd700_mode_button key={@encoded_key} mode="gaming" current={@mode} label="Gaming" />
            <.btd700_mode_button key={@encoded_key} mode="broadcast" current={@mode} label="Broadcast" />
          </div>
        </div>

        <%!-- Mode-driven body --%>
        <.btd700_broadcast_body :if={@mode == :broadcast} key={@encoded_key} state={@state} />
        <.btd700_unicast_body :if={@mode != :broadcast} key={@encoded_key} state={@state} />

        <%!-- Footer --%>
        <div class="mt-auto px-6 py-4 border-t border-border-1 flex items-center gap-2 flex-wrap">
          <.button
            variant={:danger}
            size={:sm}
            phx-click="btd700_factory_reset"
            phx-value-key={@encoded_key}
            data-confirm="Factory reset this BTD 700? This clears all paired devices and Auracast settings."
          >
            <.icon name={:alert} size={14} /> Factory reset
          </.button>
          <div class="flex-1"></div>
          <.link navigate="/audio" class="text-sm text-accent font-medium hover:underline">
            Audio settings →
          </.link>
        </div>
      </div>
    </div>
    """
  end

  attr(:key, :string, required: true)
  attr(:mode, :string, required: true)
  attr(:current, :atom, required: true)
  attr(:label, :string, required: true)

  defp btd700_mode_button(assigns) do
    ~H"""
    <.button
      variant={if to_string(@current) == @mode, do: :primary, else: :secondary}
      size={:sm}
      phx-click="btd700_set_mode"
      phx-value-key={@key}
      phx-value-mode={@mode}
    >
      {@label}
    </.button>
    """
  end

  # Unicast body (mode != broadcast): dongle/LE/sink status, audio-quality
  # readout (read-only), codec-in-use + supported-codec toggle chips,
  # connect/disconnect triggers.
  attr(:key, :string, required: true)
  attr(:state, :map, required: true)

  defp btd700_unicast_body(assigns) do
    supported = btd700_codec_list(assigns.state[:supported_codecs])
    in_use = btd700_codec_list(assigns.state[:codec_in_use])

    assigns =
      assigns
      |> assign(:supported, supported)
      |> assign(:in_use, in_use)

    ~H"""
    <div class="px-6 py-4 space-y-4">
      <div class="grid grid-cols-2 gap-3 text-sm">
        <div>
          <div class="text-xs font-semibold text-fg-3 uppercase tracking-caps">Dongle</div>
          <div class="text-fg-1 mt-0.5">{btd700_enum_label(@state[:dongle_state])}</div>
        </div>
        <div>
          <div class="text-xs font-semibold text-fg-3 uppercase tracking-caps">LE audio</div>
          <div class="text-fg-1 mt-0.5">{btd700_enum_label(@state[:le_audio_state])}</div>
        </div>
        <div>
          <div class="text-xs font-semibold text-fg-3 uppercase tracking-caps">Sink transport</div>
          <div class="text-fg-1 mt-0.5">{btd700_enum_label(@state[:sink_transport])}</div>
        </div>
        <div>
          <div class="text-xs font-semibold text-fg-3 uppercase tracking-caps">Audio quality</div>
          <div class="text-fg-1 mt-0.5">{btd700_quality_label(@state[:audio_quality])}</div>
        </div>
      </div>

      <div class="flex items-center gap-2">
        <span class="text-xs font-semibold text-fg-3 uppercase tracking-caps">In use</span>
        <.badge variant={:neutral}>{btd700_codec_join_label(@in_use)}</.badge>
      </div>

      <div>
        <div class="text-xs font-semibold text-fg-3 uppercase tracking-caps mb-2">Codecs</div>
        <div :if={@supported == []} class="text-sm text-fg-3">—</div>
        <div class="flex gap-1.5 flex-wrap">
          <.button
            :for={codec <- @supported}
            variant={if codec in @in_use, do: :primary, else: :secondary}
            size={:sm}
            phx-click="btd700_toggle_codec"
            phx-value-key={@key}
            phx-value-codec={codec}
          >
            {btd700_codec_label(codec)}
          </.button>
        </div>
      </div>

      <div class="flex gap-2">
        <.button variant={:secondary} size={:sm} phx-click="btd700_connect" phx-value-key={@key}>
          Connect
        </.button>
        <.button variant={:secondary} size={:sm} phx-click="btd700_disconnect" phx-value-key={@key}>
          Disconnect
        </.button>
      </div>
    </div>
    """
  end

  # Broadcast (Auracast) body (mode == broadcast): on/off, name, quality,
  # encryption toggle + key form.
  attr(:key, :string, required: true)
  attr(:state, :map, required: true)

  defp btd700_broadcast_body(assigns) do
    info = btd700_broadcast_info(assigns.state)
    assigns = assign(assigns, :info, info)

    ~H"""
    <div class="px-6 py-4 space-y-4">
      <div class="flex items-center justify-between">
        <div>
          <div class="text-xs font-semibold text-fg-3 uppercase tracking-caps">Broadcast</div>
          <div class="text-sm text-fg-2 mt-0.5">
            {if @info.state == :on_public, do: "On (public)", else: "Off"}
          </div>
        </div>
        <.button
          variant={if @info.state == :on_public, do: :primary, else: :secondary}
          size={:sm}
          phx-click="btd700_set_bcast_state"
          phx-value-key={@key}
        >
          {if @info.state == :on_public, do: "Turn off", else: "Turn on"}
        </.button>
      </div>

      <form phx-submit="btd700_set_bcast_name">
        <input type="hidden" name="key" value={@key} />
        <label class="text-xs font-semibold text-fg-3 uppercase tracking-caps">Broadcast name</label>
        <div class="flex gap-2 mt-1">
          <input
            type="text"
            name="name"
            value={@state[:broadcast_name]}
            class="flex-1 bg-sunken border border-border-2 rounded-sm px-2 py-1 text-base text-fg-1"
            placeholder="Auracast name"
          />
          <.button variant={:primary} size={:sm} type="submit">Save</.button>
        </div>
      </form>

      <div>
        <div class="text-xs font-semibold text-fg-3 uppercase tracking-caps mb-2">Quality</div>
        <div class="flex gap-1.5 flex-wrap">
          <.button
            variant={if @info.quality == :standard_16k, do: :primary, else: :secondary}
            size={:sm}
            phx-click="btd700_set_bcast_quality"
            phx-value-key={@key}
            phx-value-quality="standard_16k"
          >
            16k
          </.button>
          <.button
            variant={if @info.quality == :standard_24k, do: :primary, else: :secondary}
            size={:sm}
            phx-click="btd700_set_bcast_quality"
            phx-value-key={@key}
            phx-value-quality="standard_24k"
          >
            24k
          </.button>
          <.button
            variant={if @info.quality == :high, do: :primary, else: :secondary}
            size={:sm}
            phx-click="btd700_set_bcast_quality"
            phx-value-key={@key}
            phx-value-quality="high"
          >
            High
          </.button>
        </div>
      </div>

      <div class="flex items-center justify-between">
        <div>
          <div class="text-xs font-semibold text-fg-3 uppercase tracking-caps">Encryption</div>
          <div class="text-sm text-fg-2 mt-0.5">{if @info.encryption, do: "On", else: "Off"}</div>
        </div>
        <.button
          variant={if @info.encryption, do: :primary, else: :secondary}
          size={:sm}
          phx-click="btd700_set_bcast_enc"
          phx-value-key={@key}
        >
          {if @info.encryption, do: "Turn off", else: "Turn on"}
        </.button>
      </div>

      <%!-- Key input is intentionally never bound to any assign/cached
           state — the passphrase is send-only (never persisted, never
           echoed back from the device or the LiveView). --%>
      <form phx-submit="btd700_set_bcast_key">
        <input type="hidden" name="key" value={@key} />
        <label class="text-xs font-semibold text-fg-3 uppercase tracking-caps">Broadcast key</label>
        <div class="flex gap-2 mt-1">
          <input
            type="password"
            name="secret"
            class="flex-1 bg-sunken border border-border-2 rounded-sm px-2 py-1 text-base text-fg-1"
            placeholder="Passphrase"
          />
          <.button variant={:primary} size={:sm} type="submit">Set</.button>
        </div>
      </form>
    </div>
    """
  end

  defp btd700_fw_label(%{firmware_version: %{version: v}}) when is_binary(v), do: "Firmware #{v}"
  defp btd700_fw_label(_), do: "Bluetooth audio dongle"

  defp btd700_status_line(state) do
    case Map.get(state, :dongle_state) do
      :connected -> "Connected"
      s when s in [:streaming_audio, :streaming_voice] -> "Connected · #{btd700_enum_label(s)}"
      :disconnected -> "Not connected"
      _ -> "Status unknown"
    end
  end

  # Generic label for the plain-atom enums (`dongle_state`, `le_audio_state`,
  # `sink_transport`, …) — `:unknown`/nil/a length-guarded `%{raw: _}` all
  # render as an em-dash placeholder rather than crashing the drawer.
  defp btd700_enum_label(nil), do: "—"
  defp btd700_enum_label(:unknown), do: "—"
  defp btd700_enum_label(%{raw: _}), do: "—"

  defp btd700_enum_label(atom) when is_atom(atom) do
    atom |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp btd700_enum_label(_), do: "—"

  defp btd700_quality_label(%{resolution: res, frequency: freq}) do
    "#{btd700_resolution_label(res)} / #{btd700_frequency_label(freq)}"
  end

  defp btd700_quality_label(_), do: "—"

  defp btd700_resolution_label(:res_16bit), do: "16-bit"
  defp btd700_resolution_label(:res_24bit), do: "24-bit"
  defp btd700_resolution_label(_), do: "—"

  defp btd700_frequency_label(:freq_44100), do: "44.1 kHz"
  defp btd700_frequency_label(:freq_48000), do: "48 kHz"
  defp btd700_frequency_label(:freq_96000), do: "96 kHz"
  defp btd700_frequency_label(_), do: "—"

  defp btd700_codec_join_label([]), do: "—"
  defp btd700_codec_join_label(codecs), do: Enum.map_join(codecs, ", ", &btd700_codec_label/1)

  defp btd700_codec_label(:aptx_adaptive), do: "aptX Adaptive"
  defp btd700_codec_label(:aptx_lossless), do: "aptX Lossless"
  defp btd700_codec_label(:aptx_lite), do: "aptX Lite"
  defp btd700_codec_label(:aptx), do: "aptX"
  defp btd700_codec_label(:sbc), do: "SBC"
  defp btd700_codec_label(:lc3), do: "LC3"
  defp btd700_codec_label(codec), do: codec |> to_string() |> String.upcase()

  # ── Adapter cell (icon tile + name + sub-line + HA picker hint) ───────
  attr(:port, :map, required: true)

  defp adapter_cell(assigns) do
    ~H"""
    <div :if={@port.connected} class="flex items-center gap-3">
      <div class="w-8 h-8 rounded-sm bg-sunken flex items-center justify-center flex-none">
        <span class={MockData.kind_meta(@port.kind).tint_class}>
          <.port_glyph kind={@port.kind || :unknown} size={18} />
        </span>
      </div>
      <div class="min-w-0">
        <div class="flex items-center gap-2">
          <span class="text-base font-medium text-fg-1">{@port.name}</span>
          <.detection_badge port={@port} />
        </div>
        <div class="text-sm text-fg-3 mt-px">{@port.vendor} · {@port.chip}</div>
        <div
          class="font-mono text-[11px] text-fg-1 mt-1 inline-flex items-center gap-1.5 px-1.5 py-0.5 rounded-xs bg-surface border border-border-1"
          title="This is how the adapter appears in Home Assistant's serial port picker."
        >
          <span class="font-sans text-fg-2 uppercase tracking-wide text-[9px] font-bold">HA</span>
          <span class="text-fg-1">{@port.ha_name}</span>
        </div>
      </div>
    </div>
    <div :if={!@port.connected} class="flex items-center gap-3 text-fg-4">
      <div class="w-8 h-8 rounded-sm border border-dashed border-border-strong flex-none"></div>
      <div class="text-sm italic">No adapter</div>
    </div>
    """
  end

  attr(:port, :map, required: true)

  defp detection_badge(assigns) do
    ~H"""
    <.badge :if={@port.detection == :auto} variant={:accent} class="!text-[10px] !px-1.5 !py-0">
      Auto-detected
    </.badge>
    <.badge :if={@port.detection == :manual} variant={:neutral} class="!text-[10px] !px-1.5 !py-0">
      Manual
    </.badge>
    <.badge
      :if={@port.detection == :unknown or @port.configured == false}
      variant={:warning}
      class="!text-[10px] !px-1.5 !py-0"
    >
      Needs setup
    </.badge>
    """
  end

  # ── Type cell (kind dot + name OR pickable select) ────────────────────
  attr(:port, :map, required: true)

  defp type_cell(assigns) do
    ~H"""
    <span :if={!@port.connected} class="text-fg-4">—</span>
    <div
      :if={@port.connected and @port.locked}
      class="flex items-center gap-2"
    >
      <span
        class="w-1.5 h-1.5 rounded-full flex-none"
        style={"background: #{MockData.kind_meta(@port.kind).tint};"}
      >
      </span>
      <span class="text-sm text-fg-1">{@port.kind_label}</span>
    </div>
    <div
      :if={@port.connected and !@port.locked}
      class="flex items-center gap-1.5"
    >
      <span
        :if={@port.kind}
        class="w-1.5 h-1.5 rounded-full flex-none"
        style={"background: #{MockData.kind_meta(@port.kind).tint};"}
      >
      </span>
      <%!--
      The select sits in a tiny form. `phx-change` on a form sends every
      named field — so the hidden `id` field plus the select's value
      both reach the handler. (`phx-value-*` only ships with `phx-click`,
      not `phx-change`, which is why the bare select didn't carry the
      port id.)
      --%>
      <form phx-change="request_kind_change">
        <input type="hidden" name="port" value={@port.id} />
        <select
          name="kind"
          disabled={@port.in_use}
          onclick="event.stopPropagation()"
          title={
            if @port.in_use,
              do: "Disconnect the ESPHome client to change this port's type.",
              else: "Pick the kind of serial adapter."
          }
          class={[
            "text-base font-normal text-fg-1 px-1.5 py-0.5 rounded-sm",
            if(@port.configured,
              do: "bg-canvas border border-solid border-border-1",
              else: "bg-surface border border-dashed border-border-strong"
            ),
            "cursor-pointer disabled:cursor-not-allowed"
          ]}
        >
          <option :if={!@port.configured} value="" disabled selected>Pick type…</option>
          <option value="ttl" selected={@port.kind == :ttl}>TTL</option>
          <option value="rs232" selected={@port.kind == :rs232}>RS-232</option>
          <option value="rs485" selected={@port.kind == :rs485}>RS-485</option>
        </select>
      </form>
    </div>
    """
  end

  # ── Right-side detail drawer ──────────────────────────────────────────
  attr(:port, :map, required: true)
  attr(:initial_samples, :any, default: nil)

  defp port_drawer(assigns) do
    assigns = assign(assigns, :status, MockData.port_status(assigns.port))

    ~H"""
    <div class="fixed inset-0 z-[90] flex justify-end animate-fade">
      <%!--
      Backdrop and content are siblings so clicks on the drawer body
      don't bubble to the backdrop's phx-click. Stopping propagation on
      the content (the previous approach) blocks LiveView's click
      delegation from reaching phx-click handlers on inner buttons —
      including the X close button.
      --%>
      <div phx-click="close_drawer" class="absolute inset-0 bg-overlay"></div>
      <div class="relative w-[440px] bg-raised h-full shadow-lg overflow-auto animate-slide-in flex flex-col">
        <%!-- Header --%>
        <div class="px-6 py-5 border-b border-border-1 flex items-start gap-3">
          <div class={[
            "w-10 h-10 rounded-md flex items-center justify-center",
            if(@port.connected,
              do: "bg-sunken",
              else: "border border-dashed border-border-strong"
            )
          ]}>
            <span :if={@port.connected} class={MockData.kind_meta(@port.kind).tint_class}>
              <.port_glyph kind={@port.kind || :unknown} size={22} />
            </span>
          </div>
          <div class="flex-1 min-w-0">
            <div class="text-xs font-bold text-fg-3 tracking-caps">{@port.slot}</div>
            <div class="text-lg font-semibold tracking-tight mt-0.5">
              {if @port.connected, do: @port.name, else: "No adapter"}
            </div>
            <div class="mt-2"><.badge variant={@status.variant} dot>{@status.label}</.badge></div>
          </div>
          <.button variant={:ghost} size={:sm} phx-click="close_drawer">
            <.icon name={:x} size={16} />
          </.button>
        </div>

        <%!-- Facts --%>
        <dl class="px-6 py-4 m-0 grid grid-cols-[120px_1fr] gap-x-4 gap-y-2.5 text-base">
          <.fact :for={{k, v, mono?} <- fact_rows(@port)} label={k} value={v} mono={mono?} />
        </dl>

        <%!-- Live throughput --%>
        <.live_component
          :if={@port.connected and @port.in_use}
          module={PortSparkline}
          id={"drawer-spark-#{@port.id}"}
          port_kind={@port.kind}
          variant={:full}
          initial_samples={@initial_samples}
        />

        <%!-- Footer actions --%>
        <div class="mt-auto px-6 py-4 border-t border-border-1 flex gap-2 flex-wrap">
          <.button :if={@port.connected} variant={:secondary} size={:sm}>
            <.icon name={:logs} size={14} /> View traffic
          </.button>
          <.button :if={@port.connected} variant={:secondary} size={:sm}>
            <.icon name={:refresh} size={14} /> Reset link
          </.button>
          <div :if={@port.connected} class="flex-1"></div>
          <.button :if={@port.connected} variant={:ghost} size={:sm}>Forget</.button>
          <.button :if={!@port.connected} variant={:secondary} size={:sm}>
            <.icon name={:refresh} size={14} /> Rescan
          </.button>
        </div>
      </div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:mono, :boolean, default: false)

  defp fact(assigns) do
    ~H"""
    <dt class="text-fg-3">{@label}</dt>
    <dd class={["m-0 text-fg-1", @mono && "font-mono"]}>{@value}</dd>
    """
  end

  defp fact_rows(%{connected: false} = port) do
    [
      {"Slot", "#{port.slot} — #{port.slot_sub}", false},
      {"Status", "No adapter detected", false},
      {"Tip", "Plug in any supported USB adapter to get started.", false}
    ]
  end

  defp fact_rows(port) do
    base = [
      {"Slot", "#{port.slot} — #{port.slot_sub}", false},
      {"Adapter", "#{port.vendor} #{port.name}", false},
      {"Chipset", port.chip, false},
      {"Serial", port.serial, true},
      {"Device node", port.device, true},
      {"HA serial picker", port.ha_name, true}
    ]

    serial =
      if port.kind in [:rs232, :rs485, :ttl] and port.baud do
        parity = port |> Map.get(:parity, "none") |> String.first() |> String.upcase()
        data = Map.get(port, :data_bits, 8)
        stop = Map.get(port, :stop_bits, 1)
        [{"Serial settings", "#{port.baud} · #{data}-#{parity}-#{stop}", false}]
      else
        []
      end

    tail =
      [
        {"Claimed by", port.user || "Not claimed", false},
        {"Connected", port.since || "—", false},
        {"Errors (24h)", to_string(port.errors), false}
      ] ++ if port.notes, do: [{"Notes", port.notes, false}], else: []

    base ++ serial ++ tail
  end

  # ── Peripheral rows: USB audio cards + USB Bluetooth radios ───────────
  # Only USB-attached devices belong in the physical hardware list —
  # onboard SoC audio (nil vid/pid) and the onboard UART Bluetooth radio
  # live in their own tabs, not on a USB slot. Audio first, then
  # Bluetooth, each alphabetised, so ordering is stable across renders.
  defp peripherals(audio_outputs, bt_radios) do
    usb_audio_peripherals(audio_outputs) ++ usb_bt_peripherals(bt_radios)
  end

  # Build the ordered hardware-table row list, tagging each as `{:port, _}`
  # or `{:peripheral, _}`.
  #
  # A USB peripheral (today: a Bluetooth dongle) physically occupies one of
  # the board's declared USB-A slots. Left alone that slot renders as an
  # empty port row while the device shows as a separate peripheral keyed by
  # its hci name — the receptacle reads as empty and the dongle reads as
  # placeless. Fold them together: a peripheral whose `slot_sub` matches an
  # empty declared slot takes that slot's position *in declared order*
  # (`list_ports/0` already returns slots ordered), inheriting its "USB N"
  # label, so the USB rows stay in fixed hardware order regardless of which
  # device fills them. Peripherals matching no declared empty slot (USB
  # audio, or a dongle on a dynamic-enumeration target) trail at the end.
  #
  # `hubs` (optional) is `%{bus_path => hub_info}` from `Hardware.usb_hubs/0`.
  # When a hub occupies a declared slot, that slot renders as a `{:hub, _}`
  # row and the devices behind it (bus paths `<slot>.<n>`) render **indented**
  # beneath it (depth 1) as a tree, rather than as placeless trailing rows. A
  # child that has both a port and a peripheral at the same bus path (e.g. the
  # FMA120's serial control port + its sound card) collapses to its peripheral
  # row, so it shows once and opens the control drawer. With no hubs the output
  # is identical to the prior slot-promotion behavior.
  #
  # Public only so it can be unit-tested directly (the host test env has no
  # declared slots, so the promotion path is unreachable via a live mount).
  @doc false
  def hardware_rows(ports, peripherals, hubs \\ %{}) do
    # Only hubs that actually occupy a slot we render are tree-roots. This
    # excludes the board's internal infrastructure hubs (ancestors of the
    # declared receptacle slots) — `usb_hubs/0` reports every class-09 device,
    # and without this filter those ancestors would swallow every declared
    # slot as a "child" and collapse the USB 1–4 ordering.
    port_slots = MapSet.new(ports, & &1.slot_sub)
    hub_paths = hubs |> Map.keys() |> Enum.filter(&MapSet.member?(port_slots, &1))

    promotable =
      for p <- peripherals, is_binary(p.slot_sub), into: %{}, do: {p.slot_sub, p}

    {rows, claimed, consumed} =
      Enum.reduce(ports, {[], MapSet.new(), MapSet.new()}, fn port, {acc, claimed, consumed} ->
        cond do
          # A hub sits at this declared slot: emit the hub row + its children.
          Map.has_key?(hubs, port.slot_sub) ->
            {child_rows, child_paths} = hub_children(port, ports, peripherals)
            row = {:hub, hub_row_map(port, Map.fetch!(hubs, port.slot_sub))}
            {acc ++ [row | child_rows], claimed, MapSet.union(consumed, child_paths)}

          # A device behind a hub: already emitted (or collapsed) under it.
          under_hub?(port.slot_sub, hub_paths) ->
            {acc, claimed, consumed}

          # Connected non-hub port: render as-is (never claimed by a peripheral).
          port.connected ->
            {acc ++ [{:port, port}], claimed, consumed}

          # Empty declared slot: a peripheral may be promoted into it.
          true ->
            case Map.get(promotable, port.slot_sub) do
              nil ->
                {acc ++ [{:port, port}], claimed, consumed}

              peripheral ->
                {acc ++ [{:peripheral, %{peripheral | slot: port.slot}}],
                 MapSet.put(claimed, port.slot_sub), consumed}
            end
        end
      end)

    trailing =
      for p <- peripherals,
          not (is_binary(p.slot_sub) and
                 (MapSet.member?(claimed, p.slot_sub) or MapSet.member?(consumed, p.slot_sub))),
          do: {:peripheral, p}

    rows ++ trailing
  end

  defp under_hub?(slot_sub, hub_paths) when is_binary(slot_sub) do
    Enum.any?(hub_paths, &String.starts_with?(slot_sub, &1 <> "."))
  end

  defp under_hub?(_slot_sub, _hub_paths), do: false

  # Devices enumerated behind the hub at `hub_port.slot_sub`, as indented
  # (depth-1) rows. A child bus path covered by a peripheral renders only its
  # peripheral row (collapsing a co-located serial port into it).
  defp hub_children(hub_port, ports, peripherals) do
    prefix = hub_port.slot_sub <> "."

    child_peripherals =
      Enum.filter(
        peripherals,
        &(is_binary(&1.slot_sub) and String.starts_with?(&1.slot_sub, prefix))
      )

    peripheral_paths = MapSet.new(child_peripherals, & &1.slot_sub)

    child_ports =
      Enum.filter(ports, fn pt ->
        is_binary(pt.slot_sub) and String.starts_with?(pt.slot_sub, prefix) and
          not MapSet.member?(peripheral_paths, pt.slot_sub)
      end)

    # Order all children by bus path together (not peripherals-then-ports), so
    # a hub with devices on multiple downstream ports reads in physical order.
    rows =
      (Enum.map(child_peripherals, &{&1.slot_sub, {:peripheral, Map.put(&1, :depth, 1)}}) ++
         Enum.map(child_ports, &{&1.slot_sub, {:port, Map.put(&1, :depth, 1)}}))
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    paths = MapSet.union(peripheral_paths, MapSet.new(child_ports, & &1.slot_sub))
    {rows, paths}
  end

  defp hub_row_map(hub_port, hub_info) do
    %{
      slot: hub_port.slot,
      slot_sub: hub_port.slot_sub,
      name: hub_info.name,
      vidpid: format_vidpid_pair(hub_info.vendor_id, hub_info.product_id)
    }
  end

  defp format_vidpid_pair(vid, pid) when is_integer(vid) and is_integer(pid) do
    hex = fn v -> v |> Integer.to_string(16) |> String.upcase() |> String.pad_leading(4, "0") end
    "#{hex.(vid)}:#{hex.(pid)}"
  end

  defp format_vidpid_pair(_, _), do: "—"

  defp usb_audio_peripherals(audio_outputs) do
    audio_outputs
    |> Map.values()
    |> Enum.filter(&usb_audio?/1)
    |> Enum.sort_by(& &1.friendly_name)
    |> Enum.map(fn out ->
      status = audio_status(out)

      %{
        kind: :audio,
        type_label: "Sound card",
        # `slot`/`slot_sub` default to the type + USB bus path; reconcile in
        # hardware_rows/2 promotes a USB card into the declared "USB N" slot it
        # occupies (SoC cards carry usb_port: nil → no slot_sub → they trail).
        slot: "Sound card",
        slot_sub: out.usb_port,
        name: out.friendly_name,
        detail: out.card_name,
        sub: out.usb_port || out.alsa_device,
        managed_by: "Sendspin",
        tab: "/audio",
        status: status,
        soft_class: "bg-audio-soft text-audio",
        dot_class: "bg-audio",
        # FlooGoo FMA120 and Sennheiser BTD 700 rows open their control
        # drawer instead of routing to the Audio tab; other sound cards
        # keep their goto_tab behavior.
        fma120?: fma120_key?(out.key),
        fma120_key: encode_key(out.key),
        btd700?: btd700_key?(out.key),
        btd700_key: encode_key(out.key)
      }
    end)
  end

  # USB audio outputs carry a real {vid, pid} in their key; onboard SoC
  # cards key as {card_name, nil, nil}.
  defp usb_audio?(%{key: {_slot_sub, vid, pid}}) when is_integer(vid) and is_integer(pid),
    do: true

  defp usb_audio?(_), do: false

  defp usb_bt_peripherals(bt_radios) do
    bt_radios
    |> Enum.filter(&(&1.bus == :usb))
    |> Enum.sort_by(& &1.hci)
    |> Enum.map(fn radio ->
      %{
        kind: :bluetooth,
        type_label: "Bluetooth",
        # `slot`/`slot_sub` default to the type + hci name; reconcile_slots/2
        # promotes them to the physical "USB N" / bus-path of the declared
        # slot the dongle occupies when its port matches one.
        slot: "Bluetooth",
        slot_sub: radio[:port] || radio.hci,
        name: bt_radio_name(radio),
        detail: bt_radio_detail(radio),
        sub: radio[:port] || radio.hci,
        managed_by: "Bluetooth proxy",
        tab: "/bluetooth",
        status:
          if(radio.in_use?,
            do: %{label: "In use", variant: :success},
            else: %{label: "Idle", variant: :warning}
          ),
        soft_class: "bg-accent-soft text-accent",
        dot_class: "bg-accent",
        fma120?: false,
        fma120_key: nil,
        btd700?: false,
        btd700_key: nil
      }
    end)
  end

  defp bt_radio_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp bt_radio_name(_), do: "USB Bluetooth adapter"

  # "Realtek RTL8761B · USB 2.0 · port 1-1.2" — chip + bus detail, each
  # dropped when unknown so the line never reads "Unknown · …".
  defp bt_radio_detail(radio) do
    [radio[:chip], radio[:detail]]
    |> Enum.reject(&(&1 in [nil, "", "Unknown"]))
    |> Enum.join(" · ")
  end

  # ── Audio outputs summary (links to /audio) ───────────────────────────
  attr(:outputs, :map, required: true)
  attr(:bt_disconnected, :list, default: [])
  attr(:bt_radios, :list, default: [])

  defp audio_outputs_card(assigns) do
    sorted =
      assigns.outputs
      |> Map.values()
      |> Enum.sort_by(& &1.friendly_name)

    assigns =
      assigns
      |> assign(:sorted, sorted)
      |> assign(:total, length(sorted) + length(assigns.bt_disconnected))

    ~H"""
    <.card padding={:none} class="overflow-hidden">
      <div class="flex items-center gap-2.5 px-4.5 py-3.5 border-b border-border-1">
        <div class="w-[26px] h-[26px] rounded-md bg-audio-soft text-audio flex items-center justify-center flex-none">
          <.speaker_glyph size={15} />
        </div>
        <div class="text-sm font-semibold text-fg-1">Audio outputs</div>
        <.badge variant={:neutral}>{@total}</.badge>
        <div class="flex-1"></div>
        <.link
          navigate="/audio"
          class="text-sm text-accent font-medium flex items-center gap-1 px-2 py-1 rounded-sm hover:underline"
        >
          Manage <.icon name={:chevron} size={13} />
        </.link>
      </div>
      <ul class="m-0 p-0 list-none">
        <.audio_summary_row
          :for={{out, last?} <- with_last(@sorted)}
          out={out}
          last?={last? and @bt_disconnected == []}
        />
        <.bt_disconnected_row
          :for={{device, last?} <- with_last(@bt_disconnected)}
          device={device}
          hci={bt_hci_for(@bt_radios, device.adapter)}
          last?={last?}
        />
      </ul>
    </.card>
    """
  end

  # A paired-but-offline Bluetooth speaker. Distinct from a Disabled ALSA
  # output: Disconnected (warning) means "should be here but isn't
  # reachable", not "turned off" (neutral). No live volume/stream — the
  # device isn't streaming.
  attr(:device, :map, required: true)
  attr(:hci, :string, default: nil)
  attr(:last?, :boolean, required: true)

  defp bt_disconnected_row(assigns) do
    ~H"""
    <li class={[
      "grid grid-cols-[4px_36px_1fr_220px_110px] items-center min-h-[64px]",
      not @last? && "border-b border-border-2"
    ]}>
      <div class="self-stretch opacity-40" style="background: var(--hs-warning);"></div>

      <div class="pl-3 pr-1 flex justify-center">
        <div class="w-[30px] h-[30px] rounded-md bg-sunken text-fg-4 flex items-center justify-center">
          <.icon name={:headphones} size={16} />
        </div>
      </div>

      <div class="px-3 py-2.5 min-w-0">
        <div class="text-sm font-medium text-fg-1 truncate">{@device.name}</div>
        <div class="text-[11px] text-fg-3 mt-0.5">
          <span class="font-mono">{@device.mac}</span>
          <span :if={@hci}> · <span class="font-mono">{@hci}</span></span>
        </div>
      </div>

      <div class="px-4 text-[11px] text-fg-3">Not connected</div>

      <div class="px-4">
        <.badge variant={:warning} dot>Disconnected</.badge>
      </div>
    </li>
    """
  end

  attr(:out, :map, required: true)
  attr(:last?, :boolean, required: true)

  # Five-column grid: tint spine | speaker tile | name + alsa path |
  # mini volume bar | status badge. The tint spine inherits the badge
  # color so the row reads at a glance: same hue end-to-end means a
  # healthy stream.
  defp audio_summary_row(assigns) do
    assigns =
      assign(assigns, :status, audio_status(assigns.out))
      |> assign(:streaming?, audio_streaming?(assigns.out))
      |> assign(:connected?, audio_connected?(assigns.out))
      |> assign(:volume, Map.get(assigns.out, :volume, 0))
      |> assign(:muted, Map.get(assigns.out, :muted, false))

    ~H"""
    <li class={[
      "grid grid-cols-[4px_36px_1fr_220px_110px] items-center min-h-[64px]",
      not @last? && "border-b border-border-2"
    ]}>
      <div
        class={["self-stretch", @out.enabled || "opacity-40"]}
        style={"background: #{@status.tint_var};"}
      >
      </div>

      <div class="pl-3 pr-1 flex justify-center">
        <div class={[
          "w-[30px] h-[30px] rounded-md flex items-center justify-center",
          if(@out.enabled, do: "bg-audio-soft text-audio", else: "bg-sunken text-fg-4")
        ]}>
          <.icon :if={bt_output?(@out)} name={:headphones} size={16} />
          <.speaker_glyph :if={not bt_output?(@out)} size={17} muted={@muted} level={speaker_level(@volume)} />
        </div>
      </div>

      <div class="px-3 py-2.5 min-w-0">
        <div class="flex items-center gap-2">
          <span class="text-sm font-medium text-fg-1 truncate">{@out.friendly_name}</span>
          <span
            :if={@streaming?}
            class="inline-flex items-center gap-1 text-[11px] font-semibold text-audio"
          >
            <.eq_bars active={true} />
            {stream_label(Map.get(@out, :stream))}
          </span>
          <span
            :if={not @streaming? and @connected?}
            class="inline-flex items-center gap-1 text-[11px] font-semibold text-accent"
          >
            <.icon name={:pause} size={10} stroke={2.4} /> Paused
          </span>
        </div>
        <div class="text-[11px] text-fg-3 mt-0.5">
          <span class="font-mono">{@out.alsa_device}</span> · <span>{@out.card_name}</span>
        </div>
      </div>

      <div class="px-4 flex items-center gap-2.5">
        <div class="flex-1 h-1 rounded-[2px] bg-sunken relative overflow-hidden">
          <div
            class={[
              "absolute inset-y-0 left-0 rounded-[2px]",
              if(@out.enabled, do: "bg-audio", else: "bg-fg-4"),
              @muted && "opacity-30"
            ]}
            style={"width: #{volume_bar_width(@out.enabled, @muted, @volume)}%;"}
          >
          </div>
        </div>
        <div class="text-xs font-mono tabular-nums text-fg-2 min-w-[28px] text-right">
          {if @muted, do: "MUTE", else: @volume}
        </div>
      </div>

      <div class="px-4">
        <.badge variant={@status.variant} dot>{@status.label}</.badge>
      </div>
    </li>
    """
  end

  # Pair each element in `xs` with a boolean indicating "is last?".
  # Used to skip the bottom border on the final row.
  defp with_last([]), do: []

  defp with_last(xs) do
    n = length(xs)
    Enum.with_index(xs) |> Enum.map(fn {x, i} -> {x, i == n - 1} end)
  end

  defp volume_bar_width(false, _muted, _vol), do: 0
  defp volume_bar_width(true, true, _vol), do: 0
  defp volume_bar_width(true, false, vol) when is_integer(vol), do: vol
  defp volume_bar_width(_, _, _), do: 0

  # Paired-but-disconnected A2DP speakers for the audio summary's durable
  # Disconnected rows. A connected device is a live output instead, so we
  # take only `paired and not connected` to avoid double-listing.
  defp disconnected_bt(headphones) do
    headphones
    |> Enum.filter(&(&1.paired and not &1.connected))
    |> Enum.sort_by(& &1.name)
  end

  # "hciN" for a device's bound-radio MAC, or nil if that radio isn't
  # currently present.
  defp bt_hci_for(radios, adapter_mac) do
    case Enum.find(radios, &(&1.address == adapter_mac)) do
      %{hci: hci} when is_binary(hci) -> hci
      _ -> nil
    end
  end
end
