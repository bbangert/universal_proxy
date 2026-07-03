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

  A non-blank binary is used verbatim (so the service advertises as
  `<name>._esphomelib._tcp.local`); anything else falls back to
  `:unspecified`, which makes `mdns_lite` use the Nerves hostname — mDNS is
  never lost just because the name couldn't be read.
  """
  @spec instance_name(term()) :: String.t() | :unspecified
  def instance_name(name) when is_binary(name) and name != "", do: name
  def instance_name(_), do: :unspecified

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
