defmodule UniversalProxy.Bluetooth.RadioMonitor do
  @moduledoc """
  Maintains the Bluetooth radio list for the web tab: sysfs enumeration
  (`UniversalProxy.Bluetooth.Radios.enumerate/1`) overlaid with live
  `org.bluez.Adapter1` properties (Address, Name) when the daemon is up,
  plus an `in_use?` mark on the radio the BlueZ subtree is driving
  (selected/claimed — independent of the HA-facing `enabled` toggle) and
  each radio's stored `role` (`nil` when unassigned). The `:tuya_mesh` radio
  is excluded from the claim, so it is never `in_use?`; its `role` is what
  marks it as taken by the mesh.

  ## Event-driven, not polled

  The radio set only changes on discrete events, so this re-enumerates on
  those rather than on a timer (an SoC radio is soldered in; USB dongles
  announce themselves). The trigger is
  `Bluez.Client.adapters_topic/0`, on which the Client
  broadcasts `{:bluetooth_adapters_changed}` when it claims an adapter at
  setup (boot, and after a radio-switch restart) and on every adapter
  `InterfacesAdded`/`InterfacesRemoved` (hotplug). Subscribing before the
  first enumeration closes the lost-edge race if a claim lands during init.
  `refresh/1` re-enumerates on demand (the UI's Rescan button), the manual
  escape hatch if an event is ever missed.

  ## Held radios

  A radio the Tuya mesh holds over the HCI user channel is gone from
  `bluetoothd` (the kernel removes its index from MGMT), so the overlay
  has nothing for its hciN. Those come from
  `UniversalProxy.Bluetooth.HeldRadios` instead: the row at the held index
  gets the held MAC as `address`, its stored `role` and `held:
  :tuya_mesh` (`nil` on every other row), never `in_use?`. Its `name` is
  the one `bluetoothd` last reported for that MAC (remembered by MAC,
  for this process's life), and a held index with no sysfs row gets the
  row last seen for the MAC, or a minimal one. A daemon row still naming
  a held MAC under another hciN is stale and loses its address, so the
  MAC is never listed twice. `HeldRadios` broadcasts re-enumerate, and
  so does a holder process exiting (each holder is monitored).

  Broadcasts `{:bluetooth_radios, radios}` on
  `UniversalProxy.Bluetooth.radios_topic/0` whenever the list changes.

  Runs even while Bluetooth is disabled: the tab must list radios to pick
  *before* the stack is enabled. Every external source is read
  defensively, so all of this works with the subtree down (the Adapter1
  overlay just disappears).

  ## Options (host-testability)

  `:name`, `:sysfs_root`, `:pubsub`, plus the `:adapters_info_fun`
  injection point (defaults to
  `Bluez.Client.adapters_info/0`), `:roles_fun` (the stored
  `%{mac => role}` map, defaults to `Settings.get/0`'s, `%{}` while Settings
  is down) and `:held_fun` (defaults to `HeldRadios.list/0`). Role changes reach the list through
  `UniversalProxy.Bluetooth.set_role/2`'s `refresh/1`. Tests drive a
  re-enumeration by broadcasting `{:bluetooth_adapters_changed}` on
  `Bluez.Client.adapters_topic/0`.
  """

  use GenServer

  alias Bluez.{Client, DevicePath}
  alias UniversalProxy.Bluetooth.{HeldRadios, Radios, Settings}

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
         ble?:, bredr?:, in_use?:, role:, held:}]

  `held` is `:tuya_mesh` for a radio the mesh holds (see "Held radios"),
  else `nil`.
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
      adapters_info_fun: Keyword.get(opts, :adapters_info_fun, &Bluez.Client.adapters_info/0),
      roles_fun: Keyword.get(opts, :roles_fun, &stored_roles/0),
      held_fun: Keyword.get(opts, :held_fun, &HeldRadios.list/0),
      radios: [],
      # Last row seen with a daemon address, by MAC (see "Held radios").
      known: %{},
      # Monitors on holder pids: pid => ref.
      holders: %{}
    }

    # Subscribe BEFORE the first enumerate so a claim landing in between
    # still triggers a re-enumerate (no lost-edge race).
    Phoenix.PubSub.subscribe(state.pubsub, Client.adapters_topic())
    Phoenix.PubSub.subscribe(state.pubsub, HeldRadios.topic())

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

  # A radio was taken from bluetoothd or handed back.
  def handle_info({:bluetooth_held_changed}, state), do: {:noreply, poll(state)}

  # A holder exited (a crash sends no HeldRadios broadcast).
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case state.holders do
      %{^pid => ^ref} -> {:noreply, poll(%{state | holders: Map.delete(state.holders, pid)})}
      _other -> {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ── enumeration ──────────────────────────────────────────────────────────

  defp poll(state) do
    held = state.held_fun.()
    {radios, state} = compute(state, held)

    if radios != state.radios do
      Phoenix.PubSub.broadcast(
        state.pubsub,
        UniversalProxy.Bluetooth.radios_topic(),
        {:bluetooth_radios, radios}
      )
    end

    %{state | radios: radios} |> monitor_holders(held)
  end

  defp compute(state, held) do
    sysfs = Radios.enumerate(state.sysfs_root)
    live = by_hci(state.adapters_info_fun.())
    active_path = DevicePath.adapter_path()
    roles = state.roles_fun.()
    held_by_hci = Map.new(held, &{"hci#{&1.index}", &1})
    held_macs = MapSet.new(held, & &1.address)

    rows =
      for radio <- sysfs do
        case Map.fetch(held_by_hci, radio.hci) do
          {:ok, entry} ->
            held_row(radio, entry, roles, state.known)

          :error ->
            adapter = Map.get(live, radio.hci, %{})

            # A daemon row naming a held MAC elsewhere is stale.
            adapter =
              if MapSet.member?(held_macs, adapter[:address]), do: %{}, else: adapter

            live_row(radio, adapter, roles, active_path)
        end
      end

    present = MapSet.new(sysfs, & &1.hci)

    # A held index sysfs doesn't show (yet): still listed, from what was
    # last seen of the MAC.
    extra =
      for entry <- held, not MapSet.member?(present, "hci#{entry.index}") do
        state.known
        |> Map.get(entry.address, unknown_radio())
        |> Map.put(:hci, "hci#{entry.index}")
        |> held_row(entry, roles, state.known)
      end

    radios = Enum.sort_by(rows ++ extra, &Radios.hci_index(&1.hci))
    {radios, %{state | known: remember(state.known, rows)}}
  end

  # Address and Name exist only via the daemon (the kernel exposes no BT MAC
  # in sysfs) — nil while the BlueZ subtree is down. in_use? = the adapter our
  # stack claimed AND the daemon is answering for it; independent of the
  # HA-facing enabled toggle. Never the mesh radio: the client doesn't claim
  # it, so a path match is only the hci0 default or a stale earlier claim.
  defp live_row(radio, adapter, roles, active_path) do
    role = adapter[:address] && Map.get(roles, adapter[:address])

    radio
    |> Map.put(:address, adapter[:address])
    |> Map.put(:name, adapter[:name])
    |> Map.put(
      :in_use?,
      role != :tuya_mesh and adapter != %{} and "/org/bluez/#{radio.hci}" == active_path
    )
    |> Map.put(:role, role)
    |> Map.put(:held, nil)
  end

  defp held_row(radio, entry, roles, known) do
    radio
    |> Map.put(:address, entry.address)
    |> Map.put(:name, get_in(known, [entry.address, :name]))
    |> Map.put(:in_use?, false)
    |> Map.put(:role, Map.get(roles, entry.address))
    |> Map.put(:held, entry.holder)
  end

  defp unknown_radio do
    %{
      bus: :unknown,
      detail: "Unknown",
      port: nil,
      chip: "Unknown",
      bt_version: nil,
      ble?: true,
      bredr?: true
    }
  end

  # Rows the daemon identified, by MAC; held rows add nothing new.
  defp remember(known, rows) do
    Enum.reduce(rows, known, fn
      %{held: nil, address: mac} = row, acc when is_binary(mac) ->
        Map.put(acc, mac, Map.drop(row, [:hci, :in_use?, :role, :held]))

      _row, acc ->
        acc
    end)
  end

  defp monitor_holders(state, held) do
    holders =
      Enum.reduce(held, state.holders, fn %{pid: pid}, acc ->
        Map.put_new_lazy(acc, pid, fn -> Process.monitor(pid) end)
      end)

    %{state | holders: holders}
  end

  # Settings is an earlier sibling under the Bluetooth supervisor, but may be
  # down (restart, host tests): no roles then.
  defp stored_roles do
    Settings.get().roles
  catch
    :exit, _ -> %{}
  end

  # Index live Adapter1 entries by hci name ("/org/bluez/hci1" → "hci1").
  defp by_hci(adapters) when is_list(adapters) do
    Map.new(adapters, fn %{path: path} = adapter -> {Path.basename(path), adapter} end)
  end

  defp by_hci(_), do: %{}
end
