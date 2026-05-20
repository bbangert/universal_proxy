defmodule UniversalProxy.Audio.MdnsAnnouncerTest do
  use ExUnit.Case, async: true

  require Record

  alias UniversalProxy.Audio.MdnsAnnouncer

  # Same record extraction the production module uses — gives us
  # `dns_rec(...)`, `dns_header(...)`, `dns_query(...)` accessors so
  # the assertions read by field name instead of tuple position.
  Record.defrecord(:dns_rec, Record.extract(:dns_rec, from_lib: "kernel/src/inet_dns.hrl"))
  Record.defrecord(:dns_header, Record.extract(:dns_header, from_lib: "kernel/src/inet_dns.hrl"))
  Record.defrecord(:dns_query, Record.extract(:dns_query, from_lib: "kernel/src/inet_dns.hrl"))

  describe "build_ptr_query/1" do
    test "encodes a valid mDNS PTR query for the default service type" do
      packet = MdnsAnnouncer.build_ptr_query("_sendspin._tcp")

      assert {:ok, decoded} = :inet_dns.decode(packet)

      # mDNS header invariants (RFC 6762 §18): id=0, opcode=query,
      # qr=false (this is a question, not a response).
      header = dns_rec(decoded, :header)
      assert dns_header(header, :id) == 0
      assert dns_header(header, :qr) == false
      assert dns_header(header, :opcode) == :query

      # Exactly one question; PTR for the requested service type.
      assert [question] = dns_rec(decoded, :qdlist)
      assert dns_query(question, :class) == :in
      assert dns_query(question, :type) == :ptr
      assert dns_query(question, :domain) == ~c"_sendspin._tcp.local"

      # No answers / authority / additional — this is a pure question.
      assert dns_rec(decoded, :anlist) == []
      assert dns_rec(decoded, :nslist) == []
      assert dns_rec(decoded, :arlist) == []
    end

    test "honors a custom service type" do
      packet = MdnsAnnouncer.build_ptr_query("_workstation._tcp")
      assert {:ok, decoded} = :inet_dns.decode(packet)
      assert [question] = dns_rec(decoded, :qdlist)
      assert dns_query(question, :domain) == ~c"_workstation._tcp.local"
    end
  end
end
