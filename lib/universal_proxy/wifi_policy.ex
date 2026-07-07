defmodule UniversalProxy.WifiPolicy do
  @moduledoc """
  Ethernet-preferred Wi-Fi policy: while any Ethernet interface has
  connectivity, Wi-Fi interfaces are kept deconfigured so the device is
  reachable at exactly one address; when Ethernet loses connectivity the
  stashed Wi-Fi config is re-applied.

  Why: with both `eth0` and `wlan0` joined to the same LAN the device answers
  on two IPs, and mDNS can hand either to HA / Music Assistant. Clients that
  latch onto the `wlan0` address break whenever Wi-Fi changes, and Wi-Fi
  traffic contends with Bluetooth on the 2.4 GHz band (shared antenna on the
  SoC radio). Wired wins; Wi-Fi is the fallback.

  Mechanics: subscribes to `["interface", :_, "connection"]` and re-evaluates
  after a short settle delay. Suspending an interface stashes its runtime
  config and calls `VintageNet.deconfigure(ifname, persist: false)` — the
  persisted config on disk is untouched, so a reboot (or this policy) can
  bring Wi-Fi back. Restoring re-applies the stash with `persist: false`.
  Interfaces are classified by their `"type"` property (`VintageNetEthernet` /
  `VintageNetWiFi`), never by name.

  Improv provisioning is unaffected: it only arms on a no-connectivity boot,
  where this policy leaves Wi-Fi alone. All VintageNet access is guarded
  (`Code.ensure_loaded?`) and injectable, so the module loads and the decision
  logic is tested on host without a radio.
  """

  use GenServer
  require Logger

  @connection_topic ["interface", :_, "connection"]
  @up_states [:lan, :internet]

  # Ride out link flaps / DHCP renegotiation before acting on an event.
  @default_settle_ms 1_000

  @doc false
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "Introspection: `%{ethernet_up?: boolean, suspended: [ifname]}`."
  @spec status(GenServer.server()) :: %{ethernet_up?: boolean(), suspended: [String.t()]}
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  # ── pure decision (host-tested) ────────────────────────────────────────────

  @doc """
  Which interfaces to suspend or restore. `ifaces` is
  `[%{ifname: _, type: _, connection: _}]`; `stashed` the suspended ifnames.

  With Ethernet up every Wi-Fi-typed (i.e. currently configured) interface is
  suspended; with Ethernet down every stashed interface is restored. Pure.
  """
  @spec decide([map()], [String.t()]) :: %{suspend: [String.t()], restore: [String.t()]}
  def decide(ifaces, stashed) do
    ethernet_up? =
      Enum.any?(ifaces, &(&1.type == VintageNetEthernet and &1.connection in @up_states))

    if ethernet_up? do
      %{suspend: for(i <- ifaces, i.type == VintageNetWiFi, do: i.ifname), restore: []}
    else
      %{suspend: [], restore: stashed}
    end
  end

  # ── GenServer ───────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    state = %{
      stash: %{},
      timer: nil,
      settle_ms: Keyword.get(opts, :settle_ms, @default_settle_ms),
      subscribe?: Keyword.get(opts, :subscribe?, true),
      match_fn: Keyword.get(opts, :match_fn, &vintage_match/1),
      get_fn: Keyword.get(opts, :get_fn, &vintage_get/1),
      get_config_fn: Keyword.get(opts, :get_config_fn, &vintage_get_configuration/1),
      configure_fn: Keyword.get(opts, :configure_fn, &vintage_configure/3),
      deconfigure_fn: Keyword.get(opts, :deconfigure_fn, &vintage_deconfigure/2)
    }

    if state.subscribe?, do: vintage_subscribe(@connection_topic)
    {:ok, state, {:continue, :evaluate}}
  end

  @impl true
  def handle_continue(:evaluate, state), do: {:noreply, evaluate(state)}

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, %{ethernet_up?: ethernet_up?(state), suspended: Map.keys(state.stash)}, state}
  end

  @impl true
  def handle_info({VintageNet, ["interface", _if, "connection"], _old, _new, _meta}, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    {:noreply, %{state | timer: Process.send_after(self(), :evaluate, state.settle_ms)}}
  end

  def handle_info(:evaluate, state), do: {:noreply, evaluate(%{state | timer: nil})}
  def handle_info(_msg, state), do: {:noreply, state}

  # ── evaluation ──────────────────────────────────────────────────────────────

  defp evaluate(state) do
    %{suspend: suspend, restore: restore} =
      state |> interfaces() |> decide(Map.keys(state.stash))

    state = Enum.reduce(suspend, state, &suspend_iface/2)
    Enum.reduce(restore, state, &restore_iface/2)
  end

  # Every interface that has a "type" property, with its connection state.
  defp interfaces(state) do
    for {["interface", ifname, "type"], type} <- state.match_fn.(["interface", :_, "type"]) do
      %{
        ifname: ifname,
        type: type,
        connection: state.get_fn.(["interface", ifname, "connection"])
      }
    end
  end

  defp suspend_iface(ifname, state) do
    config = state.get_config_fn.(ifname)

    case config do
      %{type: VintageNetWiFi} ->
        Logger.info("WifiPolicy: Ethernet up — suspending #{ifname} (config kept on disk)")
        state.deconfigure_fn.(ifname, persist: false)
        %{state | stash: Map.put(state.stash, ifname, config)}

      _ ->
        # Already Null (a previous pass suspended it) or unreadable — keep any
        # existing stash entry rather than clobbering it with Null.
        state
    end
  end

  defp restore_iface(ifname, state) do
    {config, stash} = Map.pop(state.stash, ifname)
    Logger.info("WifiPolicy: Ethernet down — restoring Wi-Fi on #{ifname}")
    state.configure_fn.(ifname, config, persist: false)
    %{state | stash: stash}
  end

  defp ethernet_up?(state) do
    state
    |> interfaces()
    |> Enum.any?(&(&1.type == VintageNetEthernet and &1.connection in @up_states))
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

  defp vintage_get_configuration(ifname) do
    if Code.ensure_loaded?(VintageNet),
      do: apply(VintageNet, :get_configuration, [ifname]),
      else: nil
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
