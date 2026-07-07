defmodule UniversalProxy.WifiPolicy do
  @moduledoc """
  Ethernet-preferred Wi-Fi policy: while any Ethernet interface has
  connectivity, Wi-Fi interfaces are kept deconfigured so the device is
  reachable at exactly one address; when Ethernet loses connectivity the
  persisted Wi-Fi config is re-applied from disk.

  Why: with both `eth0` and `wlan0` joined to the same LAN the device answers
  on two IPs, and mDNS can hand either to HA / Music Assistant. Clients that
  latch onto the `wlan0` address break whenever Wi-Fi changes, and Wi-Fi
  traffic contends with Bluetooth on the 2.4 GHz band (shared antenna on the
  SoC radio). Wired wins; Wi-Fi is the fallback.

  Mechanics: subscribes to `["interface", :_, "connection"]` and re-evaluates
  after a short settle delay. Suspending an interface calls
  `VintageNet.deconfigure(ifname, persist: false)` — the persisted config on
  disk is untouched and is the restore source (`VintageNet.Persistence`), so
  the policy holds no state that a process restart could lose. Restoring
  re-applies the persisted config with `persist: false`. Interfaces are
  classified by their `"type"` property (`VintageNetEthernet` /
  `VintageNetWiFi`), never by name.

  Deliberate limits: a Wi-Fi interface with **no persisted config** (runtime-
  only, e.g. configured by hand with `persist: false`) is never suspended —
  we couldn't restore it, and availability beats strictness. And because the
  policy is reactive (VintageNet applies persisted configs before this app
  starts), `wlan0` may associate for a few seconds at boot before the first
  evaluation suspends it.

  Improv provisioning is unaffected: it only arms on a no-connectivity boot,
  where this policy leaves Wi-Fi alone, and it persists the credentials it
  writes. All VintageNet access is guarded (`Code.ensure_loaded?`) and
  injectable, so the module loads and the decision logic is tested on host
  without a radio.
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
  `[%{ifname: _, type: _, connection: _, persisted: config | nil}]`.

  With Ethernet up, every Wi-Fi-typed interface whose config is persisted is
  suspended (no persisted copy ⇒ nothing to restore from ⇒ left alone). With
  Ethernet down, every Null-typed interface with a persisted Wi-Fi config is
  restored — stateless, so a policy restart while suspended changes nothing.
  Pure.
  """
  @spec decide([map()]) :: %{suspend: [String.t()], restore: [String.t()]}
  def decide(ifaces) do
    if ethernet_up?(ifaces) do
      %{
        suspend: for(i <- ifaces, i.type == VintageNetWiFi and persisted_wifi?(i), do: i.ifname),
        restore: []
      }
    else
      %{
        suspend: [],
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

  defp persisted_wifi?(iface), do: match?(%{type: VintageNetWiFi}, iface.persisted)

  # ── GenServer ───────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    state = %{
      timer: nil,
      settle_ms: Keyword.get(opts, :settle_ms, @default_settle_ms),
      subscribe?: Keyword.get(opts, :subscribe?, true),
      match_fn: Keyword.get(opts, :match_fn, &vintage_match/1),
      get_fn: Keyword.get(opts, :get_fn, &vintage_get/1),
      load_persisted_fn: Keyword.get(opts, :load_persisted_fn, &vintage_load_persisted/1),
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
    ifaces = interfaces(state)

    suspended =
      for i <- ifaces, i.type == VintageNet.Technology.Null and persisted_wifi?(i), do: i.ifname

    {:reply, %{ethernet_up?: ethernet_up?(ifaces), suspended: suspended}, state}
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
    ifaces = interfaces(state)
    %{suspend: suspend, restore: restore} = decide(ifaces)
    persisted = Map.new(ifaces, &{&1.ifname, &1.persisted})

    Enum.each(suspend, fn ifname ->
      Logger.info("WifiPolicy: Ethernet up — suspending #{ifname} (config kept on disk)")
      log_result(state.deconfigure_fn.(ifname, persist: false), ifname, "deconfigure")
    end)

    Enum.each(restore, fn ifname ->
      Logger.info("WifiPolicy: Ethernet down — restoring Wi-Fi on #{ifname}")

      state.configure_fn.(ifname, Map.fetch!(persisted, ifname), persist: false)
      |> log_result(ifname, "configure")
    end)

    state
  end

  # Every interface that has a "type" property, with its connection state and
  # persisted (on-disk) config.
  defp interfaces(state) do
    for {["interface", ifname, "type"], type} <- state.match_fn.(["interface", :_, "type"]) do
      %{
        ifname: ifname,
        type: type,
        connection: state.get_fn.(["interface", ifname, "connection"]),
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
