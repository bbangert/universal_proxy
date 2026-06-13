defmodule UniversalProxy.Bluetooth.RadioMonitor do
  @moduledoc """
  Maintains the Bluetooth radio list for the web tab: sysfs enumeration
  (`UniversalProxy.Bluetooth.Radios.enumerate/1`) overlaid with live
  `org.bluez.Adapter1` properties (Address, Name) when the daemon is up,
  plus an `in_use?` mark on the radio the BlueZ subtree is driving
  (selected/claimed — independent of the HA-facing `enabled` toggle).

  ## Event-driven, not polled

  The radio set only changes on discrete events, so this re-enumerates on
  those rather than on a timer (an SoC radio is soldered in; USB dongles
  announce themselves). The trigger is
  `UniversalProxy.Bluez.Client.adapters_topic/0`, on which the Client
  broadcasts `{:bluetooth_adapters_changed}` when it claims an adapter at
  setup (boot, and after a radio-switch restart) and on every adapter
  `InterfacesAdded`/`InterfacesRemoved` (hotplug). Subscribing before the
  first enumeration closes the lost-edge race if a claim lands during init.
  `refresh/1` re-enumerates on demand (the UI's Rescan button), the manual
  escape hatch if an event is ever missed.

  Broadcasts `{:bluetooth_radios, radios}` on
  `UniversalProxy.Bluetooth.radios_topic/0` whenever the list changes.

  Runs even while Bluetooth is disabled: the tab must list radios to pick
  *before* the stack is enabled. Every external source is read
  defensively, so all of this works with the subtree down (the Adapter1
  overlay just disappears).

  ## Options (host-testability)

  `:name`, `:sysfs_root`, `:pubsub`, plus the `:adapters_info_fun`
  injection point (defaults to
  `UniversalProxy.Bluez.Client.adapters_info/0`). Tests drive a
  re-enumeration by broadcasting `{:bluetooth_adapters_changed}` on
  `UniversalProxy.Bluez.Client.adapters_topic/0`.
  """

  use GenServer

  alias UniversalProxy.Bluetooth.Radios
  alias UniversalProxy.Bluez.{Client, DevicePath}

  def start_link(opts \\ []) do
    gen_opts =
      case Keyword.get(opts, :name, __MODULE__) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  The current radio list (cached from the last enumeration):

      [%{hci:, address:, name:, chip:, bus:, detail:, bt_version:,
         ble?:, bredr?:, in_use?:}]
  """
  @spec list(GenServer.server()) :: [map()]
  def list(server \\ __MODULE__) do
    GenServer.call(server, :list)
  end

  @doc "Re-enumerate immediately, broadcast on change, return the fresh list."
  @spec refresh(GenServer.server()) :: [map()]
  def refresh(server \\ __MODULE__) do
    GenServer.call(server, :refresh)
  end

  @impl GenServer
  def init(opts) do
    state = %{
      sysfs_root: Keyword.get(opts, :sysfs_root, "/sys/class/bluetooth"),
      pubsub: Keyword.get(opts, :pubsub, UniversalProxy.PubSub),
      adapters_info_fun:
        Keyword.get(opts, :adapters_info_fun, &UniversalProxy.Bluez.Client.adapters_info/0),
      radios: []
    }

    # Subscribe BEFORE the first enumerate so a claim landing in between
    # still triggers a re-enumerate (no lost-edge race).
    Phoenix.PubSub.subscribe(state.pubsub, Client.adapters_topic())

    {:ok, state, {:continue, :enumerate}}
  end

  @impl GenServer
  def handle_continue(:enumerate, state), do: {:noreply, poll(state)}

  @impl GenServer
  def handle_call(:list, _from, state), do: {:reply, state.radios, state}

  def handle_call(:refresh, _from, state) do
    state = poll(state)
    {:reply, state.radios, state}
  end

  @impl GenServer
  # The adapter set changed (claim at setup, hotplug add/remove) — the only
  # thing that moves the radio list. Re-enumerate.
  def handle_info({:bluetooth_adapters_changed}, state), do: {:noreply, poll(state)}

  def handle_info(_other, state), do: {:noreply, state}

  # ── enumeration ──────────────────────────────────────────────────────────

  defp poll(state) do
    radios = compute(state)

    if radios != state.radios do
      Phoenix.PubSub.broadcast(
        state.pubsub,
        UniversalProxy.Bluetooth.radios_topic(),
        {:bluetooth_radios, radios}
      )
    end

    %{state | radios: radios}
  end

  defp compute(state) do
    sysfs = Radios.enumerate(state.sysfs_root)
    live = by_hci(state.adapters_info_fun.())
    active_path = DevicePath.adapter_path()

    for radio <- sysfs do
      adapter = Map.get(live, radio.hci, %{})

      # Address and Name exist only via the daemon (the kernel exposes no
      # BT MAC in sysfs) — nil while the BlueZ subtree is down. in_use? =
      # the adapter our stack claimed AND the daemon is answering for it;
      # independent of the HA-facing enabled toggle.
      radio
      |> Map.put(:address, adapter[:address])
      |> Map.put(:name, adapter[:name])
      |> Map.put(:in_use?, adapter != %{} and "/org/bluez/#{radio.hci}" == active_path)
    end
  end

  # Index live Adapter1 entries by hci name ("/org/bluez/hci1" → "hci1").
  defp by_hci(adapters) when is_list(adapters) do
    Map.new(adapters, fn %{path: path} = adapter -> {Path.basename(path), adapter} end)
  end

  defp by_hci(_), do: %{}
end
