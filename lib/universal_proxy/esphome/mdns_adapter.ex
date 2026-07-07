defmodule UniversalProxy.ESPHome.MdnsAdapter do
  @moduledoc """
  `Espex.Mdns` adapter that advertises the `_esphomelib._tcp` service under
  the device's ESPHome **node name** as the mDNS service instance, matching
  stock ESPHome behaviour.

  Espex's built-in adapter (`Espex.Mdns.MdnsLite`) leaves the service
  instance name `:unspecified`, so `mdns_lite` falls back to the Nerves
  hostname (e.g. `nerves-099b._esphomelib._tcp.local`). Stock ESPHome
  instead advertises `<node-name>._esphomelib._tcp.local` (e.g.
  `universal-proxy-45099b`). This adapter rewrites the service's
  `:instance_name` to the node name read from `ConfigStore` before
  delegating to the stock adapter; port resolution, TXT payload, and
  withdraw-on-shutdown are unchanged.

  Falls back to `:unspecified` (stock hostname-based behaviour) if the node
  name is unavailable or blank, so mDNS advertising is never lost.

  `advertise/1` also syncs a **unique host alias**: the node name (which
  carries the per-device MAC suffix) is advertised as `<name>.local` via
  `MdnsLite.set_hosts/1`, so every proxy has a hostname of its own instead
  of only the shared `universal_proxy.local`. See `host_alias/1`.
  """

  @behaviour Espex.Mdns

  alias UniversalProxy.ESPHome.ConfigStore

  require Logger

  @impl Espex.Mdns
  def advertise(service) do
    name = safe_name()
    sync_host_alias(name)

    service
    |> Map.put(:instance_name, instance_name(name))
    |> Espex.Mdns.MdnsLite.advertise()
  end

  @impl Espex.Mdns
  def withdraw(service_id), do: Espex.Mdns.MdnsLite.withdraw(service_id)

  @doc """
  Resolve the unique mDNS host alias from the ESPHome node name.

  Every device advertising the same static `universal_proxy.local` alias
  means the hostname is useless for telling proxies apart (and any of them
  may answer the query). The node name already carries the per-device MAC
  suffix (`universal-proxy-07507f`), so it doubles as a unique hostname —
  IF it is hostname-safe. DNS host labels are stricter than service
  instance names (RFC 1123: letters/digits/hyphens, no leading/trailing
  hyphen, ≤ 63 bytes), so a user-set name that doesn't qualify returns
  `nil` and no alias is advertised rather than emitting an invalid record.
  """
  @spec host_alias(term()) :: String.t() | nil
  def host_alias(name) when is_binary(name) do
    if name =~ ~r/^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$/ and byte_size(name) <= 63 do
      name
    end
  end

  def host_alias(_), do: nil

  # Advertise `<node-name>.local` alongside the Nerves hostname and the
  # legacy shared alias. Runs on every `advertise/1` (Espex mDNS start =
  # boot + every ESPHome config restart), so a rename via the Discovery
  # tab re-syncs the alias. `:hostname` stays FIRST — mdns_lite targets
  # all service SRV records at the first entry, and changing that would
  # repoint every advertised service. `"universal_proxy"` is kept for the
  # documented single-device convenience URL; with several devices on one
  # LAN any of them may answer it — the unique alias is the reliable one.
  defp sync_host_alias(name) do
    case host_alias(name) do
      nil -> :ok
      alias_name -> MdnsLite.set_hosts([:hostname, alias_name, "universal_proxy"])
    end
  rescue
    # MdnsLite may not be running on host/dev — advertising still works
    # if Espex's adapter copes; the alias is best-effort.
    e ->
      Logger.warning("mDNS host alias sync failed: #{Exception.message(e)}")
      :ok
  catch
    # MdnsLite.set_hosts/1 is a GenServer.call into the TableServer —
    # a stopped/restarting responder exits (:noproc/:timeout) rather
    # than raising.
    :exit, reason ->
      Logger.warning("mDNS host alias sync exited: #{inspect(reason)}")
      :ok
  end

  @doc """
  Resolve the mDNS service instance name from the ESPHome node name.

  The node name (`ConfigStore` accepts any binary for `:name`) becomes the
  leftmost DNS label, so it is stripped of control chars, trimmed, and
  clamped to the 63-byte label limit (RFC 1035 §2.3.4). A binary that
  survives sanitizing advertises as `<name>._esphomelib._tcp.local`;
  anything that cleans to empty — blank, whitespace/control-only, or
  unreadable — falls back to `:unspecified`, which makes `mdns_lite` use
  the Nerves hostname so mDNS advertising is never lost.
  """
  @spec instance_name(term()) :: String.t() | :unspecified
  def instance_name(name) when is_binary(name) do
    case sanitize(name) do
      "" -> :unspecified
      cleaned -> cleaned
    end
  end

  def instance_name(_), do: :unspecified

  # Strip control chars, trim, and clamp to the 63-byte DNS label limit at
  # codepoint boundaries so the result is always valid UTF-8 and never a
  # malformed mDNS RR.
  defp sanitize(name) do
    name
    |> String.replace(~r/[[:cntrl:]]/u, "")
    |> String.trim()
    |> truncate_to_byte_limit(63)
  end

  defp truncate_to_byte_limit(s, max) when byte_size(s) <= max, do: s

  defp truncate_to_byte_limit(s, max) do
    s
    |> String.codepoints()
    |> Enum.reduce_while({"", 0}, fn cp, {acc, sz} ->
      new_sz = sz + byte_size(cp)
      if new_sz > max, do: {:halt, {acc, sz}}, else: {:cont, {acc <> cp, new_sz}}
    end)
    |> elem(0)
  end

  # ConfigStore is started before the ESPHome supervisor, but stay
  # defensive so a lookup failure degrades to hostname-based advertising.
  defp safe_name do
    ConfigStore.current().name
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end
end
