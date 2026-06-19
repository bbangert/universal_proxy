defmodule UniversalProxy.Audio.MdnsAnnouncerTest do
  use ExUnit.Case, async: false

  alias UniversalProxy.Audio.MdnsAnnouncer

  # Stands in for `MdnsLite`; signals the (registered) test process each
  # time the announcer fans out an announce.
  defmodule MockMdns do
    def announce_all do
      send(:mdns_announcer_test, :announced)
      :ok
    end
  end

  setup do
    Process.register(self(), :mdns_announcer_test)
    # Tiny delays so the two RFC 6762 §8.3 announces land fast in tests.
    pid =
      start_supervised!(
        {MdnsAnnouncer, name: nil, mdns_module: MockMdns, reannounce_delays_ms: [0, 5]}
      )

    {:ok, pid: pid}
  end

  defp addr_event(ifname, addresses) do
    {VintageNet, ["interface", ifname, "addresses"], [], addresses, %{}}
  end

  test "re-announces twice when an interface gains an IPv4 address", %{pid: pid} do
    send(pid, addr_event("eth0", [%{address: {192, 168, 2, 50}}]))

    assert_receive :announced, 200
    assert_receive :announced, 200
    refute_receive :announced, 50
  end

  test "does not announce when the change carries no usable IPv4", %{pid: pid} do
    # IPv6-only and loopback don't count as the network being ready.
    send(pid, addr_event("eth0", [%{address: {0xFE80, 0, 0, 0, 0, 0, 0, 1}}]))
    send(pid, addr_event("lo", [%{address: {127, 0, 0, 1}}]))

    refute_receive :announced, 100
  end

  test "does not re-announce while the interface already has an IPv4", %{pid: pid} do
    send(pid, addr_event("eth0", [%{address: {192, 168, 2, 50}}]))
    assert_receive :announced, 200
    assert_receive :announced, 200

    # A second event for the still-up interface is a no-op.
    send(pid, addr_event("eth0", [%{address: {192, 168, 2, 50}}]))
    refute_receive :announced, 100
  end

  test "re-announces again after the interface drops then regains an address", %{pid: pid} do
    send(pid, addr_event("eth0", [%{address: {192, 168, 2, 50}}]))
    assert_receive :announced, 200
    assert_receive :announced, 200

    # Interface goes away (nil) ...
    send(pid, addr_event("eth0", nil))
    refute_receive :announced, 50

    # ... then comes back — should announce again.
    send(pid, addr_event("eth0", [%{address: {192, 168, 2, 51}}]))
    assert_receive :announced, 200
    assert_receive :announced, 200
  end
end
