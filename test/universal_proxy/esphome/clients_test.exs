defmodule UniversalProxy.ESPHome.ClientsTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.ESPHome.Clients

  defp client(attrs) do
    struct!(%Espex.ClientInfo{id: self(), peer: "10.0.1.9:40000"}, attrs)
  end

  describe "build/2" do
    test "parses Home Assistant name + version and marks it HA" do
      now = 1_000_000

      [vm] =
        Clients.build(
          [
            client(
              client_info: "Home Assistant 2026.1.0",
              connected_at: now,
              last_activity_at: now
            )
          ],
          now
        )

      assert vm.name == "Home Assistant"
      assert vm.kind == "Home Assistant"
      assert vm.version == "2026.1.0"
      assert vm.home_assistant?
    end

    test "falls back gracefully when client_info is nil" do
      now = 1_000_000
      [vm] = Clients.build([client(client_info: nil)], now)

      assert vm.name == "Native API client"
      assert vm.version == nil
      refute vm.home_assistant?
    end

    test "formats connected-since and last-packet durations" do
      now = 1_000_000

      [vm] =
        Clients.build(
          [client(connected_at: now - 90_000, last_activity_at: now - 5)],
          now
        )

      # 90_000s = 1d 1h
      assert vm.since == "1d 1h"
      assert vm.last_seen == "5s ago"
    end

    test "surfaces encryption state" do
      now = 1_000_000
      [enc] = Clients.build([client(encrypted?: true, connected_at: now)], now)
      [plain] = Clients.build([client(encrypted?: false, connected_at: now)], now)

      assert enc.encrypted?
      refute plain.encrypted?
    end

    test "sorts Home Assistant first, then oldest connection" do
      now = 1_000_000

      vms =
        Clients.build(
          [
            client(client_info: "esphome-cli", connected_at: now - 10),
            client(client_info: "Home Assistant 2026.1.0", connected_at: now - 5),
            client(client_info: "ESPHome dashboard", connected_at: now - 100)
          ],
          now
        )

      assert Enum.map(vms, & &1.kind) == ["Home Assistant", "ESPHome", "ESPHome"]
      # within non-HA, oldest (smaller connected_at) first
      assert [_, second, third] = vms
      assert second.connected_at_raw <= third.connected_at_raw
    end

    test "empty list yields no view models" do
      assert Clients.build([], 1_000_000) == []
    end

    test "clamps bogus pre-boot-clock-step ages to device uptime (cap)" do
      now = 1_000_000
      # connected_at ~95 days in the past (a Nerves boot clock step), but the
      # device has only been up 115s — cap must win.
      [vm] =
        Clients.build(
          [client(connected_at: now - 8_200_000, last_activity_at: now - 8_200_000)],
          now,
          115
        )

      assert vm.since == "1m 55s"
      assert vm.last_seen == "1m ago"
    end

    test "does not clamp when the age equals uptime exactly (boundary)" do
      now = 1_000_000
      # connected_at exactly one uptime ago: min(100, 100) == 100, untouched.
      [vm] =
        Clients.build([client(connected_at: now - 100, last_activity_at: now - 100)], now, 100)

      assert vm.since == "1m 40s"
      assert vm.last_seen == "1m ago"
    end
  end

  test "topic/0 is stable" do
    assert Clients.topic() == "esphome:clients"
  end
end
