defmodule UniversalProxy.Audio.MdnsAnnouncer do
  @moduledoc """
  Workaround for `mdns_lite` 0.9.1 not implementing RFC 6762 §8.3
  gratuitous service announcements on `add_mdns_service/1`.

  `MdnsLite.add_mdns_service/1` updates the responder's internal record
  table but does NOT broadcast an unsolicited DNS response. New
  services are therefore only discoverable once an mDNS-capable peer
  (Music Assistant, avahi-browse, etc.) issues a PTR query for our
  service type — typically on a 30–60 s poll cycle. Until that poll
  fires, a freshly re-enabled Sendspin output is invisible to peers
  that already cached the previous "I'm gone" signal.

  ## Approach

  We do not construct a DNS response ourselves. Instead we send a
  multicast PTR query for our service type from a transient UDP
  socket. The Pi's own `MdnsLite.Responder` (which joined the mDNS
  multicast group at boot) receives the query alongside every other
  responder on the LAN and emits a multicast response containing the
  full PTR / SRV / TXT record set for every `_sendspin._tcp` service
  currently in its table. That multicast response is exactly the
  gratuitous announce we needed — peers cache it the same way they
  would cache a response to their own poll.

  This routes around the fact that `MdnsLite.Responder.send_response/4`
  is private and that `MdnsLite.query/2` short-circuits on local table
  hits (so it never broadcasts when we're the only one with the
  record).

  ## Caveats

  * The peer-side cache only benefits from this if the peer is
    actively listening on the mDNS multicast group at the moment we
    send. Most mDNS daemons (avahi, mDNSResponder) are always
    listening, so the practical hit rate is high.
  * The local responder responds to ANY query for our service type,
    not just "ours" — so one announce broadcasts every Sendspin output
    we have registered, not the single one that just came up. That's
    a feature, not a bug: a single call covers a batch re-enable.

  ## Tracking upstream

  Watch [`nerves-networking/mdns_lite#213`](https://github.com/nerves-networking/mdns_lite/pull/213).
  That PR adds RFC 6762 §8.3 announces at responder startup; once it
  lands and is extended to the add-service path, this module becomes
  redundant.
  """

  require Logger
  require Record

  # Local extraction of the inet_dns records so we don't depend on
  # `MdnsLite.DNS` (which is internal to the library).
  Record.defrecord(:dns_rec, Record.extract(:dns_rec, from_lib: "kernel/src/inet_dns.hrl"))
  Record.defrecord(:dns_header, Record.extract(:dns_header, from_lib: "kernel/src/inet_dns.hrl"))
  Record.defrecord(:dns_query, Record.extract(:dns_query, from_lib: "kernel/src/inet_dns.hrl"))

  @mdns_addr {224, 0, 0, 251}
  @mdns_port 5353
  @default_service "_sendspin._tcp"

  @doc """
  Send a multicast PTR query for `service_type` to the mDNS multicast
  group. The local `mdns_lite` responder receives the query and emits
  the unsolicited announce we actually want.

  Returns `:ok` on socket-level success, `{:error, reason}` otherwise.
  Callers (typically `Audio.Player.init/1` via `Process.send_after`)
  should not treat failures as fatal — the next periodic peer poll
  will discover the service in the worst case.
  """
  @spec announce(String.t()) :: :ok | {:error, term()}
  def announce(service_type \\ @default_service) when is_binary(service_type) do
    packet = build_ptr_query(service_type)

    case :gen_udp.open(0, [:binary, active: false]) do
      {:ok, socket} ->
        result = :gen_udp.send(socket, @mdns_addr, @mdns_port, packet)
        :gen_udp.close(socket)

        case result do
          :ok ->
            Logger.debug("Audio.MdnsAnnouncer sent PTR query for #{service_type}")
            :ok

          {:error, reason} ->
            Logger.warning(
              "Audio.MdnsAnnouncer send failed for #{service_type}: #{inspect(reason)}"
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("Audio.MdnsAnnouncer socket open failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Encode an mDNS PTR query packet for the given service type. Exposed
  for testing — production callers should use `announce/1`.
  """
  @spec build_ptr_query(String.t()) :: binary()
  def build_ptr_query(service_type) when is_binary(service_type) do
    domain = String.to_charlist("#{service_type}.local")

    # mDNS query: id=0 (per RFC 6762), qr=0 (query), no recursion.
    # qdlist carries the single PTR question.
    msg =
      dns_rec(
        header:
          dns_header(
            id: 0,
            qr: false,
            opcode: :query,
            aa: false,
            tc: false,
            rd: false,
            ra: false,
            rcode: 0
          ),
        qdlist: [dns_query(class: :in, type: :ptr, domain: domain)],
        anlist: [],
        nslist: [],
        arlist: []
      )

    :inet_dns.encode(msg)
  end
end
