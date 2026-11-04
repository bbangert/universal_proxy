defmodule UniversalProxy.TuyaBeaconMesh.Radio.Transport.UserChannel do
  @moduledoc """
  `UniversalProxy.TuyaBeaconMesh.Radio.Transport` over an exclusive
  `HCI_CHANNEL_USER` socket (`Bluez.HciUser`): the Radio drives the
  controller with plain HCI commands, with neither `bluetoothd` nor the
  kernel's advertising bookkeeping in between.

  While bound the controller is gone from `bluetoothd` and MGMT (Index
  Removed); closing the socket hands it back, and `bluetoothd` powers it
  on again by itself.

  Needs `:adapter_address` (the role MAC): `init/1` refuses without one.
  The index is never trusted: every bind resolves the MAC through MGMT
  (`Bluez.HciUser` powers the controller off and retries a busy bind).

  Setup, every command waited for:

   1. bind by MAC, unless the channel from an earlier setup is still open;
   2. HCI Reset (always: it clears whatever the controller was doing);
   3. Read BD_ADDR, which must be the MAC (`{:wrong_adapter, address}`
      otherwise, and the channel is closed at once);
   4. Read Local Version (kept for `status/1` as `:controller`) and LE
      Read Local Supported Features;
   5. Set Event Mask `0x20001FFFFFFFFFFF`, LE Set Event Mask `0x1F`;
   6. LE scan parameters (passive, 30/30 ms), legacy advertising
      parameters (`ADV_IND`, 20–30 ms, all channels, public address) and
      LE Set Scan Enable without duplicate filtering.

  No extended advertising command is ever sent: a controller refuses
  legacy commands after one, until the next Reset.

  With a reset asked for (after a wedge) the Reset in step 2 is the
  recovery, reported as `{:controller_reset, :hci_reset}`, or
  `{:controller_reset, :rebind}` when the channel had to be bound again
  first. `teardown/1` stops scanning and advertising but keeps the
  channel, so the next setup resets the controller in place.

  A frame is LE Set Advertising Data then LE Set Advertising Enable;
  stopping it is Enable false. A non-zero HCI status or a timeout (also
  while stopping a frame) is a controller fault; a closed channel is uncertain (the frame may have
  aired) and its `{:closed, reason}` notice is reported as a loss.

  Events from `Bluez.HciUser`: advertising reports become `{:report, ...}`
  through `UniversalProxy.TuyaBeaconMesh.Carrier.frames/1` (as for the
  Bluez transport's receiver), Hardware Error and a command stall become
  faults, and `{:closed, reason}` (an unplug is `:epipe`) or the process
  going down a loss; the next setup binds again by MAC. Messages from an
  earlier channel's process are ignored.

  Options: `:hci_user` (default `Bluez.HciUser`, a test seam) and
  `:hci_user_opts` (merged into its start options).
  """

  @behaviour UniversalProxy.TuyaBeaconMesh.Radio.Transport

  require Logger

  alias UniversalProxy.TuyaBeaconMesh.{Carrier, Radio}

  @event_mask 0x20001FFFFFFFFFFF
  @le_event_mask 0x1F
  @scan_parameters [type: :passive, interval_ms: 30, window_ms: 30]
  @advertising_parameters [type: :adv_ind, min_interval_ms: 20, max_interval_ms: 30]
  # Teardown and terminate run with the controller possibly failing.
  @quick_ms 1_000
  @health_ms 2_000
  @drop_log_ms 60_000

  @impl true
  def init(opts) do
    with {:ok, address} <- parse_address(Keyword.get(opts, :adapter_address)) do
      {:ok,
       %{
         address: address,
         hci_user: Keyword.get(opts, :hci_user, Bluez.HciUser),
         hci_user_opts: Keyword.get(opts, :hci_user_opts, []),
         server: nil,
         mon: nil,
         index: nil,
         controller: nil,
         scanning: false,
         advertising: false,
         # Reports Bluez.HciUser dropped and not logged yet, and when the
         # last such warning went out (monotonic ms).
         dropped: 0,
         dropped_logged_at: nil
       }}
    end
  end

  defp parse_address(nil), do: {:error, :no_adapter_address}

  defp parse_address(mac) when is_binary(mac) do
    hex = String.replace(mac, ~r/[^0-9A-Fa-f]/, "")

    if byte_size(hex) == 12,
      do: {:ok, String.to_integer(hex, 16)},
      else: {:error, {:invalid_adapter_address, mac}}
  end

  defp parse_address(other), do: {:error, {:invalid_adapter_address, other}}

  @impl true
  def setup(t, reset?) do
    {t, how} = if bound?(t), do: {t, :hci_reset}, else: {forget(t), :rebind}

    case bind(t) do
      {:ok, t} -> reset_and_init(t, if(reset?, do: [{:controller_reset, how}], else: []))
      {:error, reason, t} -> {:error, reason, t, []}
    end
  end

  # The reset is reported (`events`) once it went through.
  defp reset_and_init(t, events) do
    case t.hci_user.reset(t.server) do
      :ok ->
        case init_controller(t) do
          {:ok, t} -> {:ok, t, events}
          {:error, reason, t} -> {:error, reason, t, events}
        end

      {:error, reason} ->
        {:error, {:init, :reset, reason}, dead?(t, reason), []}
    end
  end

  # A controller bluetoothd is still configuring (just added, e.g. at boot
  # or after a replug or another holder's release) answers MGMT Busy or
  # refuses the bind for a while: worth retrying before giving the
  # channel up. A control socket that can't be opened never gets better.
  @impl true
  def fallback?({:resolve, :not_found}), do: false
  def fallback?({:wrong_adapter, _address}), do: false
  def fallback?({:resolve, {:control_socket, _reason}}), do: true
  def fallback?({:resolve, _reason}), do: :transient
  def fallback?({:power_off, _reason}), do: :transient
  def fallback?({:bind, :ebusy}), do: :transient
  def fallback?(_reason), do: true

  # Keeps the channel: the next setup resets the controller on it.
  @impl true
  def teardown(%{server: nil} = t), do: %{t | scanning: false, advertising: false}

  def teardown(t) do
    t =
      if t.advertising,
        do: quietly(t, &t.hci_user.le_set_advertising_enable(&1, false, @quick_ms)),
        else: t

    t =
      if t.scanning and t.server != nil,
        do: quietly(t, &t.hci_user.le_set_scan_enable(&1, false, false, @quick_ms)),
        else: t

    %{t | scanning: false, advertising: false}
  end

  # A reset before closing leaves nothing on air for the moment until
  # bluetoothd takes the controller back.
  @impl true
  def terminate(_reason, %{server: nil}), do: :ok

  def terminate(_reason, t) do
    _ = t.hci_user.reset(t.server, @quick_ms)
    _ = forget(t)
    :ok
  end

  @impl true
  def transmit(%{server: nil} = t, _ad_bytes), do: {:error, {:uncertain, :not_bound}, t}

  def transmit(t, ad_bytes) do
    with :ok <- t.hci_user.le_set_advertising_data(t.server, ad_bytes),
         :ok <- t.hci_user.le_set_advertising_enable(t.server, true) do
      {:ok, 0, %{t | advertising: true}}
    else
      {:error, :closed} -> {:error, {:uncertain, :closed}, t}
      {:error, reason} -> {:error, {:fault, reason}, t}
    end
  end

  # Without a channel nothing of ours is on air.
  @impl true
  def stop_transmit(%{server: nil} = t, _instance), do: {:ok, %{t | advertising: false}}

  def stop_transmit(t, _instance) do
    case t.hci_user.le_set_advertising_enable(t.server, false) do
      :ok -> {:ok, %{t | advertising: false}}
      {:error, :closed} -> {:ok, %{t | advertising: false}}
      {:error, reason} -> {:error, {:fault, reason}, t}
    end
  end

  @impl true
  def health_check(%{server: nil}), do: {:error, :not_bound}

  def health_check(t) do
    case t.hci_user.read_bd_addr(t.server, @health_ms) do
      {:ok, address} when address == t.address -> :ok
      {:ok, address} -> {:error, {:wrong_adapter, mac(address)}}
      {:error, reason} -> {:error, {:read_bd_addr, reason}}
    end
  end

  @impl true
  def status(t) do
    %{
      lease_held: t.server != nil,
      discovering: t.scanning,
      listening: t.server != nil,
      transport: :user_channel,
      hci_index: t.index,
      controller: t.controller
    }
  end

  @impl true
  def handle_info({:bluez_hci_user, server, event}, %{server: server} = t) when server != nil,
    do: hci_event(event, t)

  # From the process of a channel already given up.
  def handle_info({:bluez_hci_user, _server, _event}, t), do: {:ok, [], t}

  def handle_info({:DOWN, mon, :process, _pid, reason}, %{mon: mon} = t) when mon != nil,
    do: {:ok, [{:lost, {:hci_user_down, reason}}], gone(t)}

  def handle_info(_msg, _t), do: :unhandled

  defp hci_event({:adv_report, report}, %{scanning: true} = t) do
    reports =
      for frame <- Carrier.frames(report.data), do: {:report, report.address, frame, report.rssi}

    {:ok, reports, t}
  end

  defp hci_event({:hardware_error, code}, t), do: {:ok, [{:fault, {:hardware_error, code}}], t}
  defp hci_event(:command_stall, t), do: {:ok, [{:fault, :command_stall}], t}
  defp hci_event({:closed, reason}, t), do: {:ok, [{:lost, {:closed, reason}}], gone(t)}
  defp hci_event({:reports_dropped, count}, t), do: {:ok, [], log_dropped(t, count)}
  # Reports while not scanning (teardown just stopped it) and other events.
  defp hci_event(_event, t), do: {:ok, [], t}

  # ── Setup steps ──────────────────────────────────────────────────────

  defp bound?(%{server: nil}), do: false
  defp bound?(%{server: server}), do: Process.alive?(server)

  defp bind(%{server: server} = t) when server != nil, do: {:ok, t}

  defp bind(t) do
    opts = Keyword.merge(t.hci_user_opts, address: t.address, owner: self())

    case t.hci_user.start(opts) do
      {:ok, server} ->
        t = %{t | server: server, mon: Process.monitor(server)}

        case t.hci_user.index(server) do
          {:ok, index} -> {:ok, %{t | index: index}}
          {:error, reason} -> {:error, {:init, :index, reason}, forget(t)}
        end

      {:error, reason} ->
        {:error, reason, t}

      :ignore ->
        {:error, {:start, :ignore}, t}
    end
  end

  defp init_controller(t) do
    with {:ok, t} <- check_address(t),
         {:ok, version} <- step(t, :read_local_version, &t.hci_user.read_local_version(&1)),
         t = %{t | controller: version},
         {:ok, _features} <-
           step(t, :le_features, &t.hci_user.le_read_local_supported_features(&1)),
         :ok <- step(t, :event_mask, &t.hci_user.set_event_mask(&1, @event_mask)),
         :ok <- step(t, :le_event_mask, &t.hci_user.le_set_event_mask(&1, @le_event_mask)),
         :ok <-
           step(t, :scan_parameters, &t.hci_user.le_set_scan_parameters(&1, @scan_parameters)),
         :ok <-
           step(
             t,
             :advertising_parameters,
             &t.hci_user.le_set_advertising_parameters(&1, @advertising_parameters)
           ),
         :ok <- step(t, :scan_enable, &t.hci_user.le_set_scan_enable(&1, true, false)) do
      {:ok, %{t | scanning: true}}
    else
      {:error, reason, t} -> {:error, reason, t}
      {:step_error, name, reason} -> {:error, {:init, name, reason}, dead?(t, reason)}
    end
  end

  # Another controller under the resolved index: let go of it at once.
  defp check_address(t) do
    case t.hci_user.read_bd_addr(t.server) do
      {:ok, address} when address == t.address ->
        {:ok, t}

      {:ok, address} ->
        {:error, {:wrong_adapter, mac(address)}, forget(t)}

      {:error, reason} ->
        {:error, {:init, :read_bd_addr, reason}, dead?(t, reason)}
    end
  end

  defp step(t, name, fun) do
    case fun.(t.server) do
      {:error, reason} -> {:step_error, name, reason}
      ok -> ok
    end
  end

  # A command that timed out in flight closed the channel; :closed means
  # it is gone already. Either way the next setup binds again.
  defp dead?(t, reason) when reason in [:closed, :timeout], do: forget(t)
  defp dead?(t, _reason), do: t

  defp quietly(t, fun) do
    case fun.(t.server) do
      {:error, reason} -> dead?(t, reason)
      _ok -> t
    end
  end

  # Closes the channel (handing the controller back) and forgets it.
  defp forget(%{server: nil} = t), do: gone(t)

  defp forget(t) do
    :ok = t.hci_user.close(t.server)
    gone(t)
  end

  # The channel's process is gone or going: nothing of it is kept.
  defp gone(t) do
    if t.mon, do: Process.demonitor(t.mon, [:flush])
    %{t | server: nil, mon: nil, index: nil, scanning: false, advertising: false}
  end

  defp log_dropped(t, count) do
    now = System.monotonic_time(:millisecond)
    dropped = t.dropped + count

    if t.dropped_logged_at == nil or now - t.dropped_logged_at >= @drop_log_ms do
      Logger.warning(
        "#{inspect(Radio)}: the HCI user channel dropped #{dropped} advertising " <>
          "reports (the radio fell behind)"
      )

      %{t | dropped: 0, dropped_logged_at: now}
    else
      %{t | dropped: dropped}
    end
  end

  defp mac(address) do
    address
    |> Integer.to_string(16)
    |> String.pad_leading(12, "0")
    |> String.graphemes()
    |> Enum.chunk_every(2)
    |> Enum.map_join(":", &Enum.join/1)
  end
end
