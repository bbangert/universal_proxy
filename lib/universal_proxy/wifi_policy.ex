defmodule UniversalProxy.WifiPolicy do
  @moduledoc """
  Boot-locked Ethernet-preferred Wi-Fi policy: the wired-vs-wireless choice is
  made once, shortly after boot, and held until the next reboot.

  At startup every Wi-Fi interface with a persisted config is suspended
  immediately — before WPA association/DHCP can publish an address — and
  Ethernet gets a grace window to show a carrier (`lower_up`) or reach
  `:lan`/`:internet`. If it does, the device is `:wired` for this boot and
  Wi-Fi stays off; unplugging the cable does NOT re-engage Wi-Fi. If the
  grace window expires with no Ethernet, the device is `:wireless` and the
  persisted Wi-Fi config is re-applied from disk. The only later transition
  is one-way: plugging in a cable that reaches `:lan`/`:internet` while
  `:wireless` suspends Wi-Fi and locks `:wired`.

  Why boot-locked: with both `eth0` and `wlan0` joined to the same LAN the
  device answers on two IPs, and clients (HA's ESPHome integration in
  particular) latch onto whichever they saw last. A reactive policy left a
  boot window where `wlan0` briefly held its old address — HA would connect
  to it, the suspension then killed the address, and HA retried the dead IP
  indefinitely (it never re-resolves an IP-configured entry). Suspending
  Wi-Fi before it can acquire an address closes that window; never restoring
  on cable pull keeps the device's address deterministic for a whole boot.
  Deliberate consequence: a wired device whose link dies stays offline until
  reboot — determinism was chosen over availability here.

  Mechanics: suspending calls `VintageNet.deconfigure(ifname, persist:
  false)` — the on-disk config is untouched and is the restore source
  (`VintageNet.Persistence`), so no state a process restart could lose.
  A Wi-Fi interface with **no persisted config** (runtime-only, e.g.
  configured by hand with `persist: false`) is never touched — we couldn't
  restore it. Interfaces are classified by their `"type"` property
  (`VintageNetEthernet` / `VintageNetWiFi`), never by name.

  Improv provisioning is unaffected: it only arms on a no-connectivity boot,
  which resolves to `:wireless` here (nothing to suspend, nothing to
  restore), and it persists the credentials it writes. All VintageNet access
  is guarded (`Code.ensure_loaded?`) and injectable, so the module loads and
  the decision logic is tested on host without a radio.
  """

  use GenServer
  require Logger

  @connection_topic ["interface", :_, "connection"]
  @lower_up_topic ["interface", :_, "lower_up"]
  @up_states [:lan, :internet]

  # Ride out link flaps / DHCP renegotiation before acting on an event.
  @default_settle_ms 1_000

  # How long Ethernet gets to show a carrier or connectivity at boot before
  # the device commits to :wireless. Link negotiation reports lower_up within
  # a few seconds; the margin covers slow PHYs and USB adapters.
  @default_boot_grace_ms 8_000

  @doc false
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "Introspection: `%{mode: mode, ethernet_up?: boolean, suspended: [ifname]}`."
  @spec status(GenServer.server()) :: %{
          mode: :deciding | :wired | :wireless,
          ethernet_up?: boolean(),
          suspended: [String.t()]
        }
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  # ── pure decision (host-tested) ────────────────────────────────────────────

  @doc """
  Next mode and actions for an event-driven evaluation. `ifaces` is
  `[%{ifname: _, type: _, connection: _, lower_up: _, persisted: config | nil}]`.

  - `:deciding` — hold: persisted Wi-Fi-typed interfaces are suspended;
    locks `:wired` as soon as Ethernet is present (carrier or connected).
  - `:wired` — terminal: persisted Wi-Fi-typed interfaces are suspended,
    Ethernet loss is ignored.
  - `:wireless` — Wi-Fi runs; Ethernet reaching `:lan`/`:internet` (carrier
    alone is not enough — a dead cable must not kill working Wi-Fi) suspends
    Wi-Fi and locks `:wired`.

  Never restores; only `decide_boot_expiry/1` does. Pure.
  """
  @spec decide(:deciding | :wired | :wireless, [map()]) :: %{
          mode: :deciding | :wired | :wireless,
          suspend: [String.t()],
          restore: []
        }
  def decide(:deciding, ifaces) do
    mode = if ethernet_present?(ifaces), do: :wired, else: :deciding
    %{mode: mode, suspend: suspendable(ifaces), restore: []}
  end

  def decide(:wired, ifaces), do: %{mode: :wired, suspend: suspendable(ifaces), restore: []}

  def decide(:wireless, ifaces) do
    if ethernet_up?(ifaces),
      do: %{mode: :wired, suspend: suspendable(ifaces), restore: []},
      else: %{mode: :wireless, suspend: [], restore: []}
  end

  @doc """
  The boot-grace verdict: Ethernet present ⇒ `:wired`; otherwise `:wireless`,
  restoring every suspended (Null-typed) interface with a persisted Wi-Fi
  config. Pure.
  """
  @spec decide_boot_expiry([map()]) :: %{mode: :wired | :wireless, restore: [String.t()]}
  def decide_boot_expiry(ifaces) do
    if ethernet_present?(ifaces) do
      %{mode: :wired, restore: []}
    else
      %{
        mode: :wireless,
        restore:
          for(
            i <- ifaces,
            i.type == VintageNet.Technology.Null and persisted_wifi?(i),
            do: i.ifname
          )
      }
    end
  end

  @doc "Whether any Ethernet-typed interface has `:lan`/`:internet`. Pure."
  @spec ethernet_up?([map()]) :: boolean()
  def ethernet_up?(ifaces) do
    Enum.any?(ifaces, &(&1.type == VintageNetEthernet and &1.connection in @up_states))
  end

  @doc "Whether any Ethernet-typed interface has a carrier or is connected. Pure."
  @spec ethernet_present?([map()]) :: boolean()
  def ethernet_present?(ifaces) do
    Enum.any?(
      ifaces,
      &(&1.type == VintageNetEthernet and
          (Map.get(&1, :lower_up) == true or &1.connection in @up_states))
    )
  end

  defp suspendable(ifaces) do
    for i <- ifaces, i.type == VintageNetWiFi and persisted_wifi?(i), do: i.ifname
  end

  defp persisted_wifi?(iface), do: match?(%{type: VintageNetWiFi}, iface.persisted)

  # ── GenServer ───────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    state = %{
      mode: :deciding,
      timer: nil,
      boot_timer: nil,
      settle_ms: Keyword.get(opts, :settle_ms, @default_settle_ms),
      boot_grace_ms: Keyword.get(opts, :boot_grace_ms, @default_boot_grace_ms),
      subscribe?: Keyword.get(opts, :subscribe?, true),
      match_fn: Keyword.get(opts, :match_fn, &vintage_match/1),
      get_fn: Keyword.get(opts, :get_fn, &vintage_get/1),
      load_persisted_fn: Keyword.get(opts, :load_persisted_fn, &vintage_load_persisted/1),
      configure_fn: Keyword.get(opts, :configure_fn, &vintage_configure/3),
      deconfigure_fn: Keyword.get(opts, :deconfigure_fn, &vintage_deconfigure/2)
    }

    # VintageNet is target-only and (being optional) may not be started in
    # order — mirror Audio.MdnsAnnouncer and ensure it's up before first use.
    if Code.ensure_loaded?(VintageNet), do: Application.ensure_all_started(:vintage_net)

    if state.subscribe? do
      vintage_subscribe(@connection_topic)
      vintage_subscribe(@lower_up_topic)
    end

    token = make_ref()
    boot_timer = Process.send_after(self(), {:boot_grace, token}, state.boot_grace_ms)
    {:ok, %{state | boot_timer: {boot_timer, token}}, {:continue, :evaluate}}
  end

  @impl true
  def handle_continue(:evaluate, state), do: {:noreply, evaluate(state)}

  @impl true
  def handle_call(:status, _from, state) do
    ifaces = interfaces(state)

    suspended =
      for i <- ifaces, i.type == VintageNet.Technology.Null and persisted_wifi?(i), do: i.ifname

    {:reply, %{mode: state.mode, ethernet_up?: ethernet_up?(ifaces), suspended: suspended}, state}
  end

  @impl true
  def handle_info({VintageNet, ["interface", _if, prop], _old, _new, _meta}, state)
      when prop in ["connection", "lower_up"] do
    # Tokenized so a cancelled-but-already-delivered :evaluate can't fire
    # early with mid-flap state (cancel_timer doesn't flush the mailbox).
    with {timer, _token} <- state.timer, do: Process.cancel_timer(timer)
    token = make_ref()
    timer = Process.send_after(self(), {:evaluate, token}, state.settle_ms)
    {:noreply, %{state | timer: {timer, token}}}
  end

  def handle_info({:evaluate, token}, %{timer: {_timer, token}} = state),
    do: {:noreply, evaluate(%{state | timer: nil})}

  def handle_info({:evaluate, _stale_token}, state), do: {:noreply, state}

  def handle_info({:boot_grace, token}, %{boot_timer: {_timer, token}} = state),
    do: {:noreply, boot_expiry(%{state | boot_timer: nil})}

  def handle_info({:boot_grace, _stale_token}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # ── evaluation ──────────────────────────────────────────────────────────────

  defp evaluate(state) do
    ifaces = interfaces(state)
    %{mode: mode, suspend: suspend} = decide(state.mode, ifaces)

    Enum.each(suspend, fn ifname ->
      Logger.info("WifiPolicy: suspending #{ifname} (mode #{mode}, config kept on disk)")
      log_result(state.deconfigure_fn.(ifname, persist: false), ifname, "deconfigure")
    end)

    state
    |> transition(mode)
    |> cancel_boot_timer_if_locked()
  end

  # The grace window ended: commit to wired or wireless for this boot.
  defp boot_expiry(%{mode: :deciding} = state) do
    ifaces = interfaces(state)
    %{mode: mode, restore: restore} = decide_boot_expiry(ifaces)
    persisted = Map.new(ifaces, &{&1.ifname, &1.persisted})

    Enum.each(restore, fn ifname ->
      Logger.info("WifiPolicy: no Ethernet at boot — restoring Wi-Fi on #{ifname}")

      state.configure_fn.(ifname, Map.fetch!(persisted, ifname), persist: false)
      |> log_result(ifname, "configure")
    end)

    transition(state, mode)
  end

  defp boot_expiry(state), do: state

  defp transition(%{mode: mode} = state, mode), do: state

  defp transition(state, mode) do
    Logger.info("WifiPolicy: #{state.mode} -> #{mode} (locked until reboot)")
    %{state | mode: mode}
  end

  defp cancel_boot_timer_if_locked(%{mode: :deciding} = state), do: state

  defp cancel_boot_timer_if_locked(%{boot_timer: {timer, _token}} = state) do
    Process.cancel_timer(timer)
    %{state | boot_timer: nil}
  end

  defp cancel_boot_timer_if_locked(state), do: state

  # Every interface that has a "type" property, with its link/connection state
  # and persisted (on-disk) config.
  defp interfaces(state) do
    for {["interface", ifname, "type"], type} <- state.match_fn.(["interface", :_, "type"]) do
      %{
        ifname: ifname,
        type: type,
        connection: state.get_fn.(["interface", ifname, "connection"]),
        lower_up: state.get_fn.(["interface", ifname, "lower_up"]),
        persisted: state.load_persisted_fn.(ifname)
      }
    end
  end

  defp log_result(:ok, _ifname, _op), do: :ok

  defp log_result(other, ifname, op) do
    Logger.warning("WifiPolicy: #{op} #{ifname} failed: #{inspect(other)}")
  end

  # ── VintageNet wrappers (target-only) ───────────────────────────────────────

  defp vintage_subscribe(topic) do
    if Code.ensure_loaded?(VintageNet), do: apply(VintageNet, :subscribe, [topic]), else: :ok
  end

  defp vintage_match(pattern) do
    if Code.ensure_loaded?(VintageNet), do: apply(VintageNet, :match, [pattern]), else: []
  end

  defp vintage_get(path) do
    if Code.ensure_loaded?(VintageNet), do: apply(VintageNet, :get, [path]), else: nil
  end

  # The persisted (on-disk) config, or nil. A corrupt/undecryptable file must
  # degrade to "nothing to restore", never crash a top-level child.
  defp vintage_load_persisted(ifname) do
    if Code.ensure_loaded?(VintageNet.Persistence) do
      case apply(VintageNet.Persistence, :call, [:load, [ifname]]) do
        {:ok, config} -> config
        _ -> nil
      end
    else
      nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp vintage_configure(ifname, config, opts) do
    if Code.ensure_loaded?(VintageNet),
      do: apply(VintageNet, :configure, [ifname, config, opts]),
      else: :ok
  end

  defp vintage_deconfigure(ifname, opts) do
    if Code.ensure_loaded?(VintageNet),
      do: apply(VintageNet, :deconfigure, [ifname, opts]),
      else: :ok
  end
end
