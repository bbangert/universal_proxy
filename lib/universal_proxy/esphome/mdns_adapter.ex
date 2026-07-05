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
  """

  @behaviour Espex.Mdns

  alias UniversalProxy.ESPHome.ConfigStore

  @impl Espex.Mdns
  def advertise(service) do
    service
    |> Map.put(:instance_name, instance_name(safe_name()))
    |> Espex.Mdns.MdnsLite.advertise()
  end

  @impl Espex.Mdns
  def withdraw(service_id), do: Espex.Mdns.MdnsLite.withdraw(service_id)

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
