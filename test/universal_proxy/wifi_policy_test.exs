defmodule UniversalProxy.WifiPolicyTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.WifiPolicy

  @eth %{ifname: "eth0", type: VintageNetEthernet, connection: :internet}
  @eth_down %{ifname: "eth0", type: VintageNetEthernet, connection: :disconnected}
  @wifi %{ifname: "wlan0", type: VintageNetWiFi, connection: :internet}
  @wifi_null %{ifname: "wlan0", type: VintageNet.Technology.Null, connection: :disconnected}

  @wifi_config %{
    type: VintageNetWiFi,
    vintage_net_wifi: %{networks: [%{key_mgmt: :wpa_psk, ssid: "Net", psk: "pw"}]},
    ipv4: %{method: :dhcp}
  }

  describe "decide/2 (pure)" do
    test "ethernet up suspends every wifi-typed interface" do
      assert %{suspend: ["wlan0"], restore: []} = WifiPolicy.decide([@eth, @wifi], [])
    end

    test "ethernet up with wifi already suspended does nothing" do
      assert %{suspend: [], restore: []} = WifiPolicy.decide([@eth, @wifi_null], ["wlan0"])
    end

    test "ethernet down restores the stashed interfaces" do
      assert %{suspend: [], restore: ["wlan0"]} =
               WifiPolicy.decide([@eth_down, @wifi_null], ["wlan0"])
    end

    test "ethernet :lan counts as up" do
      eth_lan = %{@eth | connection: :lan}
      assert %{suspend: ["wlan0"]} = WifiPolicy.decide([eth_lan, @wifi], [])
    end

    test "no ethernet interface at all leaves wifi alone" do
      assert %{suspend: [], restore: []} = WifiPolicy.decide([@wifi], [])
    end

    test "a wifi-only connection never suspends itself" do
      assert %{suspend: [], restore: []} = WifiPolicy.decide([@eth_down, @wifi], [])
    end
  end

  # ── GenServer flow with injected VintageNet fns ─────────────────────────────

  # The fns forward to the test pid; the interface table lives in an Agent so a
  # test can flip eth0's state between events.
  defp start_policy(ifaces) do
    table = start_supervised!({Agent, fn -> ifaces end})
    test = self()

    policy =
      start_supervised!(
        {WifiPolicy,
         name: nil,
         subscribe?: false,
         settle_ms: 0,
         match_fn: fn ["interface", :_, "type"] ->
           Agent.get(table, & &1) |> Enum.map(&{["interface", &1.ifname, "type"], &1.type})
         end,
         get_fn: fn ["interface", ifname, "connection"] ->
           Agent.get(table, & &1) |> Enum.find_value(&(&1.ifname == ifname && &1.connection))
         end,
         get_config_fn: fn "wlan0" -> @wifi_config end,
         configure_fn: fn ifname, config, opts ->
           send(test, {:configure, ifname, config, opts})
           :ok
         end,
         deconfigure_fn: fn ifname, opts ->
           send(test, {:deconfigure, ifname, opts})
           :ok
         end}
      )

    %{policy: policy, table: table}
  end

  defp set_ifaces(%{table: table, policy: policy}, ifaces) do
    Agent.update(table, fn _ -> ifaces end)
    send(policy, {VintageNet, ["interface", "eth0", "connection"], nil, nil, %{}})
  end

  test "suspends wifi at boot when ethernet is already up" do
    start_policy([@eth, @wifi])
    assert_receive {:deconfigure, "wlan0", persist: false}
  end

  test "leaves wifi alone on a wifi-only boot" do
    start_policy([@eth_down, @wifi])
    refute_receive {:deconfigure, "wlan0", _}, 100
  end

  test "suspend on cable plug, restore the same config on cable pull" do
    ctx = start_policy([@eth_down, @wifi])
    refute_receive {:deconfigure, _, _}, 100

    set_ifaces(ctx, [@eth, @wifi])
    assert_receive {:deconfigure, "wlan0", persist: false}

    set_ifaces(ctx, [@eth_down, @wifi_null])
    assert_receive {:configure, "wlan0", @wifi_config, persist: false}

    # Stash is consumed: a second eth-down event must not re-configure.
    set_ifaces(ctx, [@eth_down, @wifi_null])
    refute_receive {:configure, _, _, _}, 100
  end

  test "repeated ethernet-up events do not re-deconfigure a suspended wifi" do
    ctx = start_policy([@eth, @wifi])
    assert_receive {:deconfigure, "wlan0", persist: false}

    set_ifaces(ctx, [@eth, @wifi_null])
    refute_receive {:deconfigure, _, _}, 100
  end

  test "status/1 reports suspension" do
    ctx = start_policy([@eth, @wifi])
    assert_receive {:deconfigure, "wlan0", _}

    set_ifaces(ctx, [@eth, @wifi_null])
    assert %{ethernet_up?: true, suspended: ["wlan0"]} = WifiPolicy.status(ctx.policy)
  end

  test "connection events are debounced through the settle timer" do
    ctx = start_policy([@eth_down, @wifi])
    # A flap that settles back to eth-down must not suspend.
    send(ctx.policy, {VintageNet, ["interface", "eth0", "connection"], :internet, :lan, %{}})
    send(ctx.policy, {VintageNet, ["interface", "eth0", "connection"], :lan, :disconnected, %{}})
    refute_receive {:deconfigure, _, _}, 100
  end
end
