# SPDX-FileCopyrightText: 2019 Frank Hunleth
# SPDX-FileCopyrightText: 2019 Jon Carstens
# SPDX-FileCopyrightText: 2019 Peter C. Marks
# SPDX-FileCopyrightText: 2020 Eduardo Cunha
# SPDX-FileCopyrightText: 2021 Connor Rigby
# SPDX-FileCopyrightText: 2021 Peter Madsen-mygdal
# SPDX-FileCopyrightText: 2023 Ben Youngblood
# SPDX-FileCopyrightText: 2024 Michael Neumann
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule MdnsLite.Responder do
  @moduledoc false

  # A GenServer that is responsible for responding to a limited number of mDNS
  # requests (queries). A UDP port is opened on the mDNS reserved IP/port. Any
  # UDP packets will be caught by handle_info() but only a subset of them are
  # of interest. The module `MdnsLite.Query does the actual query parsing.
  #
  # This module is started and stopped dynamically by MdnsLite.ResponderSupervisor
  #
  # There is one of these servers for every network interface managed by
  # MdnsLite.

  use GenServer, restart: :transient

  import MdnsLite.DNS

  alias MdnsLite.Cache
  alias MdnsLite.DNS
  alias MdnsLite.IfInfo
  alias MdnsLite.TableServer
  alias MdnsLite.Utilities

  require Logger

  # Reserved IANA ip address and port for mDNS
  @mdns_ipv4 {224, 0, 0, 251}
  @mdns_ipv6 {0xFF02, 0, 0, 0, 0, 0, 0, 0xFB}
  @mdns_port 5353

  @type state() :: %{
          ifname: String.t(),
          ip: :inet.ip_address(),
          cache: Cache.t(),
          udp: :socket.socket(),
          select_handle: :socket.select_handle(),
          skip_udp: boolean()
        }

  ##############################################################################
  #   Public interface
  ##############################################################################
  @spec start_link({String.t(), :inet.ip_address()}) :: GenServer.on_start()
  def start_link(ifname_address) do
    GenServer.start_link(__MODULE__, ifname_address, name: via_name(ifname_address))
  end

  defp via_name(ifname_address) do
    {:via, Registry, {MdnsLite.ResponderRegistry, ifname_address}}
  end

  @spec get_all_caches() :: [%{ifname: String.t(), ip: :inet.ip_address(), cache: Cache.t()}]
  def get_all_caches() do
    Registry.lookup(MdnsLite.Responders, __MODULE__)
    |> Enum.map(fn {pid, {ifname, ip_address}} ->
      %{ifname: ifname, ip: ip_address, cache: get_cache(pid)}
    end)
  end

  @spec get_cache(GenServer.server()) :: Cache.t()
  def get_cache(server) do
    GenServer.call(server, :get_cache)
  end

  @spec query_all_caches(DNS.dns_query()) :: %{answer: [DNS.dns_rr()], additional: [DNS.dns_rr()]}
  def query_all_caches(q) do
    Registry.lookup(MdnsLite.Responders, __MODULE__)
    |> Enum.reduce(%{answer: [], additional: []}, fn {pid, _}, acc ->
      MdnsLite.Table.merge_results(acc, query_cache(pid, q))
    end)
  end

  @spec query_cache(GenServer.server(), DNS.dns_query()) :: %{
          answer: [DNS.dns_rr()],
          additional: [DNS.dns_rr()]
        }
  def query_cache(server, q) do
    GenServer.call(server, {:query_cache, q})
  end

  @spec multicast_all(DNS.dns_query()) :: :ok
  def multicast_all(q) do
    Registry.lookup(MdnsLite.Responders, __MODULE__)
    |> Enum.each(fn {pid, _} -> multicast(pid, q) end)
  end

  @spec multicast(GenServer.server(), DNS.dns_query()) :: :ok
  def multicast(server, q) do
    GenServer.cast(server, {:multicast, q})
  end

  @doc """
  Ask every running per-interface responder to emit an RFC 6762 §8.3
  unsolicited multicast announce — one response packet per service
  type currently in the table, sent from each responder's own socket
  so the source UDP port is 5353 (required for response packets per
  RFC 6762 §6, which is what peers like `python-zeroconf` filter on).
  """
  @spec announce_all() :: :ok
  def announce_all do
    Registry.lookup(MdnsLite.Responders, __MODULE__)
    |> Enum.each(fn {pid, _} -> GenServer.cast(pid, :announce_all) end)
  end

  @doc """
  Broadcast a TTL=0 PTR goodbye for the service with the given id.

  This is a synchronous call (not a cast) on purpose: callers
  typically follow it immediately with `MdnsLite.remove_mdns_service/1`,
  which strips the service from the table. If the goodbye were
  async, the remove could win the race and the responder would
  look up an already-gone service, sending nothing.

  Returns `:ok` regardless of whether a goodbye actually fired — the
  service may not exist yet, may already be gone, or the responder
  may be in an IPv6-only / pre-init state. None of those are fatal
  for the typical use case of "fire and forget on player shutdown".
  """
  @spec goodbye_service(MdnsLite.service_id()) :: :ok
  def goodbye_service(id) do
    each_responder(fn pid ->
      try do
        GenServer.call(pid, {:goodbye_service, id}, 1_000)
      catch
        :exit, _ -> :ok
      end
    end)
  end

  @doc """
  Broadcast a TTL=0 PTR goodbye for a service *type* (e.g.
  `"_sendspin._tcp"`) using the current host config to derive the
  instance domain. Does not require the service to be in the table.

  Synchronous call; safe to follow immediately with announces.
  """
  @spec goodbye_for_type(String.t()) :: :ok
  def goodbye_for_type(type) when is_binary(type) do
    each_responder(fn pid ->
      try do
        GenServer.call(pid, {:goodbye_for_type, type}, 1_000)
      catch
        :exit, _ -> :ok
      end
    end)
  end

  # Run `fun` for every registered Responder. Returns `:ok` without
  # raising if `:mdns_lite` isn't started yet — `Registry.lookup/2`
  # raises `ArgumentError` for an unknown registry, which would crash
  # callers that documented this function as a no-op when the app
  # isn't running.
  defp each_responder(fun) do
    if Process.whereis(MdnsLite.Responders) do
      Registry.lookup(MdnsLite.Responders, __MODULE__)
      |> Enum.each(fn {pid, _} -> fun.(pid) end)
    end

    :ok
  end

  @doc """
  Leave the mDNS group - close the UDP port. Stop this GenServer.
  """
  @spec stop_server(String.t(), :inet.ip_address()) :: :ok
  def stop_server(ifname, address) do
    GenServer.stop(via_name({ifname, address}))
  catch
    :exit, {:noproc, _} ->
      # Ignore if the server already stopped. It already exited due to the
      # network going down.
      :ok
  end

  ##############################################################################
  #   GenServer callbacks
  ##############################################################################
  @impl GenServer
  def init({ifname, address}) do
    # Join the mDNS multicast group
    state = %{
      ifname: ifname,
      ip: address,
      family: Utilities.ip_family(address),
      cache: Cache.new(),
      udp: nil,
      select_handle: nil,
      skip_udp: Application.get_env(:mdns_lite, :skip_udp)
    }

    {:ok, _} = Registry.register(MdnsLite.Responders, __MODULE__, {ifname, address})

    {:ok, state, {:continue, :initialization}}
  end

  @impl GenServer
  def handle_continue(:initialization, %{skip_udp: true} = state) do
    # Used only for testing.
    {:noreply, state}
  end

  def handle_continue(:initialization, %{family: family} = state) do
    Logger.info("mdns_lite #{state.ifname}/#{inspect(state.ip)}")

    option_level =
      case family do
        :inet -> :ip
        :inet6 -> :ipv6
      end

    with {:ok, udp} <- :socket.open(family, :dgram, :udp),
         :ok <- bindtodevice(udp, state.ifname),
         :ok <- :socket.setopt(udp, :socket, :reuseport, true),
         :ok <- :socket.setopt(udp, :socket, :reuseaddr, true),
         :ok <- :socket.setopt(udp, option_level, :multicast_loop, false),
         :ok <- set_multicast_ttl(udp, state),
         {:ok, interface} <- get_interface_opt(state),
         :ok <- :socket.setopt(udp, option_level, :multicast_if, interface),
         :ok <- :socket.bind(udp, %{family: family, port: @mdns_port}),
         :ok <- add_membership(udp, interface, family) do
      new_state = %{state | udp: udp} |> process_receives()
      {:noreply, new_state, {:continue, :announce_services}}
    else
      {:error, reason} ->
        Logger.error("mdns_lite #{state.ifname}/#{inspect(state.ip)} failed: #{inspect(reason)}")

        # Not being able to setup the socket is fatal since it means that the
        # interface went away or its IP address changed.
        {:stop, :normal, state}
    end
  end

  def handle_continue(:announce_services, state) do
    # TODO: The wait here is not necessary and needs to be removed
    Process.send_after(self(), {:announce_services, 0}, 15000)

    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:get_cache, _from, state) do
    new_state = gc_cache(state)
    {:reply, new_state.cache, new_state}
  end

  def handle_call({:query_cache, q}, _from, state) do
    new_state = gc_cache(state)
    {:reply, Cache.query(new_state.cache, q), new_state}
  end

  @impl GenServer
  def handle_cast({:multicast, q}, state) do
    message = dns_rec(header: dns_header(id: 0, qr: false, aa: false), qdlist: [q])
    data = DNS.encode(message)
    dest = %{family: state.family, port: @mdns_port, addr: multicast_ip(state.family)}

    if state.udp do
      case :socket.sendto(state.udp, data, dest) do
        {:error, reason} ->
          Logger.warning("mdns_lite multicast send failed: #{inspect(reason)}")

        :ok ->
          :ok
      end
    end

    {:noreply, state}
  end

  def handle_cast(:announce_all, %{family: :inet6} = state) do
    # IPv6 announce path not yet implemented (matches the rest of the
    # IPv6 surface area — see `run_query/4` clause below).
    {:noreply, state}
  end

  def handle_cast(:announce_all, %{udp: nil} = state) do
    # No socket yet (init still in flight). Nothing to send.
    {:noreply, state}
  end

  def handle_cast(:announce_all, state) do
    # Build a synthetic PTR query per *unique* service type and route
    # it through the existing `run_query` path. That path looks up
    # matching records in TableServer and calls `send_response`, which
    # builds the wire response and sends it via THIS responder's socket
    # (source port 5353, correct interface). The packet shape matches
    # what mdns_lite already produces in reply to peers' queries, so
    # downstream cache logic on peers (python-zeroconf, avahi-daemon)
    # treats it identically.
    services = state |> services_for_announce()

    fake_source = %{family: state.family, port: @mdns_port, addr: state.ip}

    Enum.each(services, fn service_type ->
      qd =
        dns_query(
          class: :in,
          type: :ptr,
          domain: to_charlist("#{service_type}.local")
        )

      run_query(qd, dns_rec(header: dns_header()), fake_source, state)
    end)

    {:noreply, state}
  end

  def handle_call({:goodbye_service, _id}, _from, %{family: :inet6} = state) do
    # IPv6 goodbye path not yet implemented (matches the rest of the
    # IPv6 surface area).
    {:reply, :ok, state}
  end

  def handle_call({:goodbye_service, _id}, _from, %{udp: nil} = state) do
    {:reply, :ok, state}
  end

  def handle_call({:goodbye_service, id}, _from, state) do
    # Find the service by id. No-op if it doesn't exist.
    case service_by_id(id) do
      nil -> :ok
      service -> send_goodbye_for(service, state)
    end

    {:reply, :ok, state}
  end

  def handle_call({:goodbye_for_type, _type}, _from, %{family: :inet6} = state) do
    {:reply, :ok, state}
  end

  def handle_call({:goodbye_for_type, _type}, _from, %{udp: nil} = state) do
    {:reply, :ok, state}
  end

  def handle_call({:goodbye_for_type, type}, _from, state) do
    # Build the instance domain from the configured host, mirroring
    # what Table.Builder produces when the service is normally
    # registered. We don't require the service to be in the table —
    # this is specifically for boot-time pre-emptive goodbyes.
    config = TableServer.options()
    send_goodbye_for_type(type, config, state)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(
        {:"$socket", udp, :select, select_handle},
        %{udp: udp, select_handle: select_handle} = state
      ) do
    {:noreply, process_receives(state)}
  end

  def handle_info({:announce_services, 3}, state) do
    Logger.info("Services have been announced")
    {:noreply, state}
  end

  def handle_info({:announce_services, count}, state) do
    # For all services defined run a query to force sending unsolicidted announcement
    TableServer.options()
    |> Map.get(:services)
    |> Enum.each(fn service ->
      run_query(
        dns_query(class: :in, domain: ~c"#{service.type}.local", type: :ptr),
        dns_rec(header: dns_header()),
        %{port: @mdns_port, addr: state.ip, family: :inet},
        state
      )
    end)

    Process.send_after(self(), {:announce_services, count + 1}, 1000)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.error("mdns_lite responder ignoring #{inspect(msg)}, #{inspect(state)}")
    {:noreply, state}
  end

  ##############################################################################
  #   Private functions
  ##############################################################################
  defp process_receives(state) do
    case :socket.recvfrom(state.udp, [], :nowait) do
      {:ok, {source, data}} ->
        state
        |> process_packet(source, data)
        |> process_receives()

      {:select, {:select_info, _tag, select_handle}} ->
        %{state | select_handle: select_handle}
    end
  end

  defp process_packet(state, source, data) do
    case DNS.decode(data) do
      {:ok, msg} -> process_dns(state, source, msg)
      _ -> state
    end
  end

  defp process_dns(
         state,
         source,
         dns_rec(header: dns_header(qr: false), qdlist: qdlist) = msg
       ) do
    # mDNS request message
    Enum.each(qdlist, &run_query(&1, msg, source, state))

    # If the request had any entries, cache them
    update_cache(msg, state)
  end

  defp process_dns(state, _source, dns_rec(header: dns_header(qr: true)) = msg) do
    # A response message or update so cache whatever it contains
    update_cache(msg, state)
  end

  defp update_cache(dns_rec(anlist: anlist, arlist: arlist), state) do
    now = System.monotonic_time(:second)
    new_cache = state.cache |> Cache.insert_many(now, anlist) |> Cache.insert_many(now, arlist)
    %{state | cache: new_cache}
  end

  # TODO: Responding to queries over IPv6 is not supported yet
  defp run_query(_qd, _msg, _source, %{family: :inet6}), do: :ok

  defp run_query(dns_query(unicast_response: unicast) = qd, msg, source, state) do
    result = TableServer.query(qd, %IfInfo{ipv4_address: state.ip})

    if unicast do
      send_response(result, msg, source, state)
    else
      send_response(result, msg, mdns_destination(source), state)
    end
  end

  defp send_response(%{answer: []}, _dns_record, _dest, _state), do: :ok

  defp send_response(
         result,
         dns_rec(header: dns_header(id: id)),
         dest,
         state
       ) do
    # Construct an mDNS response from the query plus answers (resource records)
    packet = response_packet(id, result)

    # Logger.debug("Sending DNS response to #{inspect(dest_address)}/#{inspect(dest_port)}")
    # Logger.debug("#{inspect(packet)}")

    data = DNS.encode(packet)
    _ = :socket.sendto(state.udp, data, dest)
    :ok
  end

  # A standard mDNS response packet
  defp response_packet(id, result),
    do:
      dns_rec(
        # AA (Authoritative Answer) bit MUST be true - RFC 6762 18.4
        header: dns_header(id: id, qr: true, aa: true),
        # Query list. Must be empty according to RFC 6762 Section 6.
        qdlist: [],
        # A list of answer entries. Can be empty.
        anlist: result.answer,
        # nslist Can be empty.
        nslist: [],
        # arlist A list of resource entries. Can be empty.
        arlist: result.additional
      )

  defp services_for_announce(_state) do
    # `TableServer.options/0` returns an `MdnsLite.Options` struct. Pull
    # the user-configured services (which is what `Options.get_services/1`
    # exposes) and dedupe by type — multiple services of the same type
    # share PTR records, so one announce per type covers them all.
    TableServer.options()
    |> MdnsLite.Options.get_services()
    |> Enum.map(& &1.type)
    |> Enum.uniq()
  end

  defp service_by_id(id) do
    TableServer.options()
    |> MdnsLite.Options.get_services()
    |> Enum.find(&(&1.id == id))
  end

  defp send_goodbye_for(service, state) do
    # Build a TTL=0 PTR record for the service's instance name. Per
    # RFC 6762 §10.1, this signals goodbye to peers — they evict the
    # binding immediately and fire "service removed" callbacks. We
    # send the PTR specifically (not SRV/TXT) because python-zeroconf
    # keys its ServiceBrowser cache on the PTR; clearing it triggers
    # the right downstream behavior.
    config = TableServer.options()

    type_domain = to_charlist("#{service.type}.local")
    instance_domain = instance_domain_for(service, config)

    rr =
      dns_rr(
        domain: type_domain,
        class: :in,
        type: :ptr,
        ttl: 0,
        data: instance_domain
      )

    response =
      dns_rec(
        header:
          dns_header(
            id: 0,
            qr: true,
            opcode: :query,
            aa: true,
            tc: false,
            rd: false,
            ra: false,
            rcode: 0
          ),
        qdlist: [],
        anlist: [rr],
        nslist: [],
        arlist: []
      )

    data = DNS.encode(response)
    dest = %{family: state.family, port: @mdns_port, addr: multicast_ip(state.family)}
    _ = :socket.sendto(state.udp, data, dest)
    :ok
  end

  # Mirrors the instance-name selection in `MdnsLite.Table.Builder.service_resources/3`.
  defp instance_domain_for(service, config) do
    case service.instance_name do
      :unspecified ->
        case config.instance_name do
          :unspecified ->
            host = hd(config.hosts)
            to_charlist("#{host}.#{service.type}.local")

          host_instance_name ->
            to_charlist("#{host_instance_name}.#{service.type}.local")
        end

      service_instance_name ->
        to_charlist("#{service_instance_name}.#{service.type}.local")
    end
  end

  defp send_goodbye_for_type(type, config, state) do
    # No per-service instance name available, so we use the host-level
    # instance (`config.instance_name` or `hd(config.hosts)`). That's
    # the same instance name `Table.Builder` would have used when our
    # services were originally advertised — so the TTL=0 PTR will
    # match what peers actually cached.
    type_domain = to_charlist("#{type}.local")
    instance_domain = instance_domain_for_type(type, config)

    rr =
      dns_rr(
        domain: type_domain,
        class: :in,
        type: :ptr,
        ttl: 0,
        data: instance_domain
      )

    response =
      dns_rec(
        header:
          dns_header(
            id: 0,
            qr: true,
            opcode: :query,
            aa: true,
            tc: false,
            rd: false,
            ra: false,
            rcode: 0
          ),
        qdlist: [],
        anlist: [rr],
        nslist: [],
        arlist: []
      )

    data = DNS.encode(response)
    dest = %{family: state.family, port: @mdns_port, addr: multicast_ip(state.family)}
    _ = :socket.sendto(state.udp, data, dest)
    :ok
  end

  defp instance_domain_for_type(type, config) do
    case config.instance_name do
      :unspecified ->
        host = hd(config.hosts)
        to_charlist("#{host}.#{type}.local")

      host_instance_name ->
        to_charlist("#{host_instance_name}.#{type}.local")
    end
  end

  defp mdns_destination(%{family: :inet, port: @mdns_port}),
    do: %{family: :inet, port: @mdns_port, addr: @mdns_ipv4}

  defp mdns_destination(%{family: :inet6, port: @mdns_port}),
    do: %{family: :inet6, port: @mdns_port, addr: @mdns_ipv6}

  defp mdns_destination(%{family: family} = source) when family in [:inet, :inet6] do
    # Legacy Unicast Response
    # See RFC 6762 6.7
    source
  end

  defp gc_cache(state) do
    %{state | cache: Cache.gc(state.cache, System.monotonic_time(:second))}
  end

  defp bindtodevice(socket, ifname) do
    case :os.type() do
      {:unix, :linux} ->
        :socket.setopt(socket, :socket, :bindtodevice, String.to_charlist(ifname))

      {:unix, :darwin} ->
        # TODO!
        :ok

      {:unix, _} ->
        # TODO!
        :ok
    end
  end

  # No difference between Linux and macOS for IPv6
  defp add_membership(udp, interface, :inet) do
    :socket.setopt(udp, :ip, :add_membership, %{
      multiaddr: multicast_ip(:inet),
      interface: interface
    })
  end

  @ipv6_option_join_group 12
  defp add_membership(udp, interface, :inet6) do
    case :os.type() do
      {:unix, :linux} ->
        :socket.setopt(udp, :ipv6, :add_membership, %{
          multiaddr: multicast_ip(:inet6),
          interface: interface
        })

      {:unix, :darwin} ->
        addr_bin =
          for int <- Tuple.to_list(@mdns_ipv6), into: <<>> do
            <<int::16>>
          end

        # This is a bit of a hack. See https://stackoverflow.com/a/38386150
        :socket.setopt_native(
          udp,
          {:ipv6, @ipv6_option_join_group},
          addr_bin <> <<interface::64>>
        )

      {:unix, _} ->
        # TODO!
        :ok
    end
  end

  # setopt uses the interface address for IPv4 and the interface index for IPv6
  defp get_interface_opt(%{family: :inet, ip: ip}), do: {:ok, ip}

  defp get_interface_opt(%{family: :inet6, ifname: ifname}) do
    ifname |> String.to_charlist() |> :net.if_name2index()
  end

  # IP TTL should be 255. See https://tools.ietf.org/html/rfc6762#section-11
  defp set_multicast_ttl(sock, %{family: :inet}),
    do: :socket.setopt(sock, :ip, :multicast_ttl, 255)

  defp set_multicast_ttl(sock, %{family: :inet6}),
    do: :socket.setopt(sock, :ipv6, :multicast_hops, 255)

  defp multicast_ip(:inet), do: @mdns_ipv4
  defp multicast_ip(:inet6), do: @mdns_ipv6
end
