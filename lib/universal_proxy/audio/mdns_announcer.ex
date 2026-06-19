defmodule UniversalProxy.Audio.MdnsAnnouncer do
  @moduledoc """
  Re-emits unsolicited mDNS announcements whenever a network interface
  comes up.

  ## Why this exists

  `Audio.Player` announces its `_sendspin._tcp` service only at startup
  (a short `[500, 1500, 3500]ms` burst — see `Audio.Player`). On a fresh
  boot the BEAM and players start before `eth0` has finished DHCP, so
  those announcements multicast into a not-yet-ready interface and are
  lost. After that, `mdns_lite 0.9.1` only *replies to queries* — it never
  re-announces — so passive peers like Music Assistant's python-zeroconf
  never receive the "Added" event and the players stay undiscovered until
  something forces a fresh announce.

  This GenServer subscribes to VintageNet interface-address changes and
  calls `MdnsLite.announce_all/0` (twice, ~1s apart, per RFC 6762 §8.3)
  each time an interface gains an IPv4 address — i.e. once the network is
  actually ready to carry the multicast. `announce_all/0` fans out a PTR +
  SRV + TXT + A response for every registered service, so all players
  (and the static ssh/http/etc. services) re-announce together.

  ## Host / test

  VintageNet is a target-only dependency. On the host it's absent, so this
  process starts, subscribes to nothing, and idles — harmless. Tests drive
  it by sending `{VintageNet, ...}` messages directly and injecting a mock
  `:mdns_module`.
  """

  use GenServer

  require Logger

  @addresses_topic ["interface", :_, "addresses"]

  # RFC 6762 §8.3: at least two unsolicited responses ~1s apart.
  @reannounce_delays_ms [500, 1_500]

  def start_link(opts \\ []) do
    # `name: nil` → start unnamed (omit the option), matching the sibling
    # Audio.Store/FMA120.Store convention.
    gen_opts =
      case Keyword.get(opts, :name, __MODULE__) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @impl true
  def init(opts) do
    state = %{
      mdns_module: Keyword.get(opts, :mdns_module, MdnsLite),
      delays_ms: Keyword.get(opts, :reannounce_delays_ms, @reannounce_delays_ms),
      # interfaces currently holding an IPv4 address
      up_ifaces: MapSet.new()
    }

    {:ok, state, {:continue, :subscribe}}
  end

  @impl true
  def handle_continue(:subscribe, state) do
    # VintageNet is target-only and (being optional) may not be started in
    # order — mirror MdnsLite.VintageNetMonitor and ensure it's up first.
    if Code.ensure_loaded?(VintageNet) do
      _ = Application.ensure_all_started(:vintage_net)
      apply(VintageNet, :subscribe, [@addresses_topic])

      # Seed already-up interfaces and announce once for them, covering the
      # case where the network was ready before we started.
      up =
        apply(VintageNet, :match, [@addresses_topic])
        |> Enum.filter(fn {_topic, addrs} -> has_ipv4?(addrs) end)
        |> Enum.map(fn {["interface", ifname, "addresses"], _addrs} -> ifname end)
        |> MapSet.new()

      if MapSet.size(up) > 0 do
        Logger.info(
          "Audio.MdnsAnnouncer: #{Enum.join(up, ", ")} already up at boot — announcing mDNS"
        )

        schedule_announces(state.delays_ms)
      end

      {:noreply, %{state | up_ifaces: up}}
    else
      Logger.debug("Audio.MdnsAnnouncer: VintageNet unavailable (host) — idle")
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({VintageNet, ["interface", ifname, "addresses"], _old, new, _meta}, state) do
    had? = MapSet.member?(state.up_ifaces, ifname)
    has? = has_ipv4?(new)

    cond do
      has? and not had? ->
        Logger.info("Audio.MdnsAnnouncer: #{ifname} gained an IPv4 address — re-announcing mDNS")
        schedule_announces(state.delays_ms)
        {:noreply, %{state | up_ifaces: MapSet.put(state.up_ifaces, ifname)}}

      not has? and had? ->
        {:noreply, %{state | up_ifaces: MapSet.delete(state.up_ifaces, ifname)}}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(:announce, state) do
    _ =
      try do
        state.mdns_module.announce_all()
      rescue
        e -> Logger.warning("Audio.MdnsAnnouncer: announce_all failed: #{inspect(e)}")
      catch
        :exit, reason ->
          Logger.debug("Audio.MdnsAnnouncer: mdns_lite not ready: #{inspect(reason)}")
      end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private --

  defp schedule_announces(delays_ms) do
    Enum.each(delays_ms, fn ms when is_integer(ms) and ms >= 0 ->
      Process.send_after(self(), :announce, ms)
    end)
  end

  # VintageNet reports addresses as `[%{address: ip_tuple, ...}]`; `nil` when
  # the interface goes away. A usable IPv4 is a 4-tuple that isn't loopback.
  defp has_ipv4?(nil), do: false

  defp has_ipv4?(addresses) when is_list(addresses) do
    Enum.any?(addresses, fn
      %{address: {127, _, _, _}} -> false
      %{address: {_, _, _, _}} -> true
      _ -> false
    end)
  end

  defp has_ipv4?(_), do: false
end
