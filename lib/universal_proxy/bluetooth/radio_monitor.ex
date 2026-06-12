defmodule UniversalProxy.Bluetooth.RadioMonitor do
  @moduledoc """
  Maintains the Bluetooth radio list for the web tab: sysfs enumeration
  (`UniversalProxy.Bluetooth.Radios.enumerate/1`) overlaid with live
  `org.bluez.Adapter1` properties (Name) when the daemon is up, plus an
  `in_use?` mark on the radio the running BlueZ subtree is driving.

  Polls every 5 s — the same hotplug strategy as the Audio subsystem's
  output enumeration — and broadcasts `{:bluetooth_radios, radios}` on
  `UniversalProxy.Bluetooth.radios_topic()` whenever the list changes.
  `refresh/1` re-enumerates immediately (the UI's Rescan button and the
  radio-selection flow).

  Runs even while Bluetooth is disabled: the tab must list radios to pick
  *before* the stack is enabled. Every external source is read
  defensively, so all of this works with the subtree down (the Adapter1
  overlay just disappears).

  ## Options (host-testability)

  `:name`, `:sysfs_root`, `:pubsub`, `:poll_ms`, plus two injection
  points: `:adapters_info_fun` (defaults to
  `UniversalProxy.Bluez.Client.adapters_info/0`) and `:proxying_fun`
  (defaults to reading `UniversalProxy.Bluetooth.status/0`, which never
  raises).
  """

  use GenServer

  alias UniversalProxy.Bluetooth.Radios
  alias UniversalProxy.Bluez.DevicePath

  @poll_ms 5_000

  def start_link(opts \\ []) do
    gen_opts =
      case Keyword.get(opts, :name, __MODULE__) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  The current radio list (cached from the last poll/refresh):

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
      poll_ms: Keyword.get(opts, :poll_ms, @poll_ms),
      adapters_info_fun:
        Keyword.get(opts, :adapters_info_fun, &UniversalProxy.Bluez.Client.adapters_info/0),
      proxying_fun: Keyword.get(opts, :proxying_fun, &default_proxying?/0),
      radios: []
    }

    {:ok, state, {:continue, :first_poll}}
  end

  @impl GenServer
  def handle_continue(:first_poll, state) do
    state = poll(state)
    schedule(state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:list, _from, state), do: {:reply, state.radios, state}

  def handle_call(:refresh, _from, state) do
    state = poll(state)
    {:reply, state.radios, state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    state = poll(state)
    schedule(state)
    {:noreply, state}
  end

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
    proxying? = state.proxying_fun.()
    active_path = DevicePath.adapter_path()

    for radio <- sysfs do
      adapter = Map.get(live, radio.hci, %{})

      # Address and Name exist only via the daemon (the kernel exposes no
      # BT MAC in sysfs) — nil while the BlueZ subtree is down.
      radio
      |> Map.put(:address, adapter[:address])
      |> Map.put(:name, adapter[:name])
      |> Map.put(:in_use?, proxying? and "/org/bluez/#{radio.hci}" == active_path)
    end
  end

  # Index live Adapter1 entries by hci name ("/org/bluez/hci1" → "hci1").
  defp by_hci(adapters) when is_list(adapters) do
    Map.new(adapters, fn %{path: path} = adapter -> {Path.basename(path), adapter} end)
  end

  defp by_hci(_), do: %{}

  defp schedule(state), do: Process.send_after(self(), :poll, state.poll_ms)

  # The public status/0 is exit-safe on every target, so this never raises.
  defp default_proxying?, do: UniversalProxy.Bluetooth.status().proxying?
end
