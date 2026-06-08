# SPDX-FileCopyrightText: 2026 Ben Bangert
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule BlueHeron.Observer do
  @moduledoc """
  Drives LE passive (or active) scanning. Subscribes to `BlueHeron.Registry`,
  waits for the HCI stack to reach `:HCI_STATE_WORKING`, then issues
  `LE Set Scan Parameters` + `LE Set Scan Enable`. Incoming
  `BlueHeron.HCI.Event.LEMeta.AdvertisingReport` events are fanned out to
  the configured callback, one call per device entry in the report.

  Add as a child to your application supervisor:

      {BlueHeron.Observer, callback: &MyApp.handle_advert/1}

  Mirrors the supervision shape of `BlueHeron.Peripheral`. A GenServer
  (not a `Task`) because the process owns scan-enable state and needs an
  orderly disable on shutdown so the controller doesn't keep scanning
  after a supervisor restart.

  Options:

    * `:callback` (required) — `(BlueHeron.HCI.Event.LEMeta.AdvertisingReport.Device.t() -> any())`
    * `:scan_params` (optional) — keyword list to override
      `BlueHeron.HCI.Command.LEController.SetScanParameters` defaults
      (`le_scan_type`, `le_scan_interval`, `le_scan_window`,
      `own_address_type`, `scanning_filter_policy`). Defaults =
      passive scan, 0x0010/0x0010 interval/window (10 ms), public
      address, accept all.
    * `:filter_duplicates` (optional, default `false`) — controller-side
      duplicate filter for advertisements. Off by default so the host
      sees every report.
  """

  use GenServer
  require Logger

  alias BlueHeron.HCI.Command.LEController.{SetScanEnable, SetScanParameters}
  alias BlueHeron.HCI.Event.LEMeta.AdvertisingReport

  @default_scan_params [
    le_scan_type: 0x00,
    le_scan_interval: 0x0010,
    le_scan_window: 0x0010,
    own_address_type: 0x00,
    scanning_filter_policy: 0x00
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    callback = Keyword.fetch!(opts, :callback)

    state = %{
      ready?: false,
      scanning?: false,
      callback: callback,
      scan_params: Keyword.merge(@default_scan_params, Keyword.get(opts, :scan_params, [])),
      filter_duplicates: Keyword.get(opts, :filter_duplicates, false)
    }

    :ok = BlueHeron.Registry.subscribe()
    {:ok, state}
  end

  @impl GenServer
  def handle_info({:BLUETOOTH_EVENT_STATE, :HCI_STATE_WORKING}, state) do
    Logger.info("BlueHeron.Observer: HCI ready; enabling LE scan")
    {:noreply, enable_scanning(%{state | ready?: true})}
  end

  def handle_info({:HCI_EVENT_PACKET, %AdvertisingReport{devices: devices}}, state) do
    Enum.each(devices, fn device ->
      try do
        state.callback.(device)
      rescue
        e ->
          Logger.error(
            "BlueHeron.Observer: callback raised on #{inspect(device)}: " <>
              Exception.format(:error, e, __STACKTRACE__)
          )
      end
    end)

    {:noreply, state}
  end

  def handle_info({:HCI_EVENT_PACKET, _other}, state), do: {:noreply, state}
  def handle_info({:HCI_ACL_DATA_PACKET, _acl}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.debug("BlueHeron.Observer: ignoring #{inspect(msg)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, %{scanning?: true}) do
    _ =
      BlueHeron.HCI.Transport.send_hci(
        SetScanEnable.new(le_scan_enable: false, filter_duplicates: false)
      )

    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp enable_scanning(state) do
    with {:ok, _} <-
           BlueHeron.HCI.Transport.send_hci(SetScanParameters.new(state.scan_params)),
         {:ok, _} <-
           BlueHeron.HCI.Transport.send_hci(
             SetScanEnable.new(
               le_scan_enable: true,
               filter_duplicates: state.filter_duplicates
             )
           ) do
      Logger.info("BlueHeron.Observer: scan enabled (params=#{inspect(state.scan_params)})")
      %{state | scanning?: true}
    else
      err ->
        Logger.error("BlueHeron.Observer: failed to enable scan: #{inspect(err)}")
        state
    end
  end
end
