# SPDX-FileCopyrightText: 2019 Peter C. Marks
# SPDX-FileCopyrightText: 2020 Frank Hunleth
# SPDX-FileCopyrightText: 2021 Mat Trudel
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule MdnsLite do
  @moduledoc """
  MdnsLite is a simple, limited, no frills mDNS implementation

  Advertising hostnames and services is generally done using the application
  config.  See `MdnsLite.Options` for documentation.

  To change the advertised hostnames or services at runtime, see `set_host/1`,
  `add_mdns_service/1` and `remove_mdns_service/1`.

  MdnsLite's mDNS record tables and caches can be inspected using
  `MdnsLite.Info` if you're having trouble.

  Finally, check out the MdnsLite `README.md` for more information.
  """

  import MdnsLite.DNS

  alias MdnsLite.DNS
  alias MdnsLite.Options
  alias MdnsLite.TableServer

  @typedoc """
  A user-specified ID for referring to a service

  Atoms are recommended, but binaries are still supported since they were used
  in the past.
  """
  @type service_id() :: atom() | binary()

  @typedoc """
  A user-visible name for a service advertisement
  """
  @type instance_name() :: String.t() | :unspecified

  @typedoc """
  mDNS service description

  Keys include:

  * `:id` - an atom for referring to this service (only required if you want to
    reference the service at runtime)
  * `:port` - the TCP/UDP port number for the service (required)
  * `:transport` - the transport protocol. E.g., `"tcp"` (specify this and
    `:protocol`, or `:type`) * `:protocol` - the application protocol. E.g.,
    `"ssh"` (specify this and `:transport`, or `:type`)
  * `:type` - the transport/protocol to advertize. E.g., `"_ssh._tcp"` (only
    needed if `:protocol` and `:transport` aren't specified)
  * `:weight` - the service weight. Defaults to `0`. (optional)
  * `:priority` - the service priority. Defaults to `0`. (optional)
  * `:txt_payload` - a map of key/value pairs that will be converted to a
    list "key=value" strings or the raw list of strings to advertise. As
    a convenience, if a bare string is passed, it's wrapped in a list.

  Example:

  ```
  %{id: :my_ssh, port: 22, protocol: "ssh", transport: "tcp"}
  ```
  """
  @type service() :: %{
          :id => service_id(),
          :instance_name => instance_name(),
          :port => 1..65535,
          optional(:txt_payload) => %{atom() => String.t()} | [String.t()] | String.t(),
          optional(:priority) => 0..255,
          optional(:protocol) => String.t(),
          optional(:transport) => String.t(),
          optional(:type) => String.t(),
          optional(:weight) => 0..255
        }

  @local_if_info %MdnsLite.IfInfo{ipv4_address: {127, 0, 0, 1}}
  @default_timeout 500

  @doc """
  Set the list of host names

  This replaces the list of hostnames that MdnsLite will respond to. The first
  hostname in the list is special. Service advertisements will use it. The
  remainder are aliases.

  Hostnames should not have the ".local" extension. MdnsLite will add it.

  To specify the hostname returned by `:inet.gethostname/0`, use `:hostname`.

  To make MdnsLite respond to queries for "<hostname>.local" and
  "nerves.local", run this:

  ```elixir
  iex> MdnsLite.set_hosts([:hostname, "nerves"])
  :ok
  ```
  """
  @spec set_hosts([:hostname | String.t()]) :: :ok
  def set_hosts(hosts) do
    TableServer.update_options(&Options.set_hosts(&1, hosts))
  end

  @doc """
  Updates the advertised instance name for service records

  To specify the first hostname specified in `hosts`, use `:unspecified`
  """
  @spec set_instance_name(instance_name()) :: :ok
  def set_instance_name(instance_name) do
    TableServer.update_options(&Options.set_instance_name(&1, instance_name))
  end

  @doc """
  Start advertising a service

  Services can be added at compile-time via the `:services` key in the `mdns_lite`
  application environment or they can be added at runtime using this function.
  See the `service` type for information on what's needed.

  Example:

  ```elixir
  iex> service = %{
      id: :my_web_server,
      protocol: "http",
      transport: "tcp",
      port: 80
    }
  iex> MdnsLite.add_mdns_service(service)
  :ok
  ```
  """
  @spec add_mdns_service(service()) :: :ok
  def add_mdns_service(service) do
    TableServer.update_options(&Options.add_service(&1, service))
  end

  @doc """
  Stop advertising a service

  Example:

  ```elixir
  iex> MdnsLite.remove_mdns_service(:my_ssh)
  :ok
  ```
  """
  @spec remove_mdns_service(service_id()) :: :ok
  def remove_mdns_service(id) do
    TableServer.update_options(&Options.remove_service_by_id(&1, id))
  end

  @doc """
  Emit unsolicited multicast announces for every registered service.

  RFC 6762 §8.3 says a Multicast DNS responder MUST send at least two
  unsolicited responses, one second apart, when a service is added or
  comes online. The library doesn't currently send any (only replies to
  queries), so newly registered services are invisible to passive peers
  like `python-zeroconf` until the peer's next poll cycle.

  This function fans out to every running per-interface `Responder` and
  asks it to multicast a proper response packet (PTR + SRV + TXT + A)
  for each service type currently in the table. The packet is built and
  sent through the responder's own socket, so the source UDP port is
  5353 — which RFC 6762 §6 requires for responses and which peers like
  `python-zeroconf` filter on.

  Callers typically schedule two or three calls about one second apart
  to satisfy the §8.3 requirement.

  > #### Vendored extension {: .info}
  >
  > This API is a downstream addition while upstream
  > [`mdns_lite#213`](https://github.com/nerves-networking/mdns_lite/pull/213)
  > is in flight. Watch for a more general announce-on-add behavior in
  > a future upstream release.
  """
  @spec announce_all() :: :ok
  def announce_all do
    MdnsLite.Responder.announce_all()
  end

  @doc """
  Emit an mDNS goodbye for a single registered service.

  Sends a multicast response packet with a TTL=0 PTR record naming the
  service's instance. Per RFC 6762 §10.1, peers that see the goodbye
  evict the service from their caches immediately and fire their
  "service removed" callbacks. Without this, a peer like python-zeroconf
  holds onto the records for the full mDNS TTL (default 120 s), and
  later unsolicited announces of the same records are treated as cache
  refreshes — never producing an `Added` event for re-registered
  services.

  This is the natural pair for `announce_all/0`: announce on registration,
  goodbye on removal. Both go through the responder's own socket so the
  source UDP port is 5353 (required by RFC 6762 §6 and enforced by
  peers like python-zeroconf).

  No-op if the service id isn't found in the current table.

  > #### Vendored extension {: .info}
  >
  > Like `announce_all/0`, this API is a downstream addition awaiting
  > a proper upstream fix in `mdns_lite`. See
  > [`nerves-networking/mdns_lite#213`](https://github.com/nerves-networking/mdns_lite/pull/213).
  """
  @spec goodbye_service(service_id()) :: :ok
  def goodbye_service(id) do
    MdnsLite.Responder.goodbye_service(id)
  end

  @doc """
  Emit an mDNS goodbye for a service *type* without requiring the
  service to be present in the responder's table.

  Useful at boot: after an ungraceful shutdown (hard power-cycle,
  crash) we never got a chance to send a goodbye for our services,
  so peer caches like python-zeroconf hold our records for the full
  TTL. Sending a TTL=0 PTR for the type the moment we come back
  clears those stale caches; subsequent announces then produce a
  proper `Added` event on the peer instead of a silent cache
  refresh.

  The instance is derived from the responder's configured host
  (`config.instance_name` or `hd(config.hosts)`) — same logic
  `Table.Builder` uses when building real PTR responses, so the
  goodbye targets the same name peers actually cached.

  No-op if no responder is running yet.

  > #### Vendored extension {: .info}
  >
  > Downstream addition pending an upstream announce/goodbye API in
  > [`nerves-networking/mdns_lite#213`](https://github.com/nerves-networking/mdns_lite/pull/213).
  """
  @spec goodbye_for_type(String.t()) :: :ok
  def goodbye_for_type(type) when is_binary(type) do
    MdnsLite.Responder.goodbye_for_type(type)
  end

  @doc """
  Lookup a hostname using mDNS

  The hostname should be a .local name since the query only goes out via mDNS.
  On success, an IP address is returned.
  """
  @spec gethostbyname(String.t(), non_neg_integer()) ::
          {:ok, :inet.ip_address()} | {:error, any()}
  def gethostbyname(hostname, timeout \\ @default_timeout) do
    q = dns_query(class: :in, type: :a, domain: to_charlist(hostname))

    case query(q, timeout) do
      %{answer: [first | _]} ->
        ip = first |> dns_rr(:data) |> to_addr()
        {:ok, ip}

      %{answer: []} ->
        {:error, :nxdomain}
    end
  end

  defp to_addr(addr) when is_tuple(addr), do: addr
  defp to_addr(<<a, b, c, d>>), do: {a, b, c, d}

  defp to_addr(<<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>),
    do: {a, b, c, d, e, f, g, h}

  @doc false
  @spec query(DNS.dns_query(), non_neg_integer()) :: %{
          answer: [DNS.dns_rr()],
          additional: [DNS.dns_rr()]
        }
  def query(dns_query() = q, timeout \\ @default_timeout) do
    # 1. Try our configured records
    # 2. Try the caches
    # 3. Send the query
    # 4. Wait for response to collect and return the matchers
    with %{answer: []} <- MdnsLite.TableServer.query(q, @local_if_info),
         %{answer: []} <- MdnsLite.Responder.query_all_caches(q) do
      MdnsLite.Responder.multicast_all(q)
      Process.sleep(timeout)
      MdnsLite.Responder.query_all_caches(q)
    end
  end
end
