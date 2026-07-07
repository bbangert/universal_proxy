defmodule UniversalProxy.WifiPolicyTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.WifiPolicy

  @wifi_config %{
    type: VintageNetWiFi,
    vintage_net_wifi: %{networks: [%{key_mgmt: :wpa_psk, ssid: "Net", psk: "pw"}]},
    ipv4: %{method: :dhcp}
  }

  @eth %{ifname: "eth0", type: VintageNetEthernet, connection: :internet, persisted: nil}
  @eth_down %{@eth | connection: :disconnected}
  @wifi %{ifname: "wlan0", type: VintageNetWiFi, connection: :internet, persisted: @wifi_config}
  @wifi_null %{@wifi | type: VintageNet.Technology.Null, connection: :disconnected}
  @wifi_unpersisted %{@wifi | persisted: nil}

  describe "decide/1 (pure)" do
    test "ethernet up suspends every persisted wifi-typed interface" do
      assert %{suspend: ["wlan0"], restore: []} = WifiPolicy.decide([@eth, @wifi])
    end

    test "ethernet up leaves a runtime-only (unpersisted) wifi alone" do
      assert %{suspend: [], restore: []} = WifiPolicy.decide([@eth, @wifi_unpersisted])
    end

    test "ethernet up with wifi already suspended does nothing" do
      assert %{suspend: [], restore: []} = WifiPolicy.decide([@eth, @wifi_null])
    end

    test "ethernet down restores a suspended interface with a persisted config" do
      assert %{suspend: [], restore: ["wlan0"]} = WifiPolicy.decide([@eth_down, @wifi_null])
    end

    test "ethernet down does not restore a Null interface with no persisted config" do
      null_unpersisted = %{@wifi_null | persisted: nil}
      assert %{suspend: [], restore: []} = WifiPolicy.decide([@eth_down, null_unpersisted])
    end

    test "ethernet :lan counts as up" do
      assert %{suspend: ["wlan0"]} = WifiPolicy.decide([%{@eth | connection: :lan}, @wifi])
    end

    test "no ethernet interface at all leaves wifi alone" do
      assert %{suspend: [], restore: []} = WifiPolicy.decide([@wifi])
    end

    test "a wifi-only connection never suspends itself" do
      assert %{suspend: [], restore: []} = WifiPolicy.decide([@eth_down, @wifi])
    end

    test "multiple wifi interfaces are all suspended and all restored" do
      wifi1 = %{@wifi | ifname: "wlan1"}
      assert %{suspend: ["wlan0", "wlan1"]} = WifiPolicy.decide([@eth, @wifi, wifi1])

      null1 = %{@wifi_null | ifname: "wlan1"}

      assert %{restore: ["wlan0", "wlan1"]} =
               WifiPolicy.decide([@eth_down, @wifi_null, null1])
    end
  end

  # ── GenServer flow with injected VintageNet fns ─────────────────────────────

  describe "GenServer flow" do
    # The fns forward to the test pid; the interface table lives in an Agent so
    # a test can flip interface state between events. `persisted:` in the table
    # doubles as the on-disk config served by load_persisted_fn.
    defp start_policy(ifaces, opts \\ []) do
      table = start_supervised!({Agent, fn -> ifaces end})
      test = self()

      policy =
        start_supervised!(
          {WifiPolicy,
           name: nil,
           subscribe?: false,
           settle_ms: Keyword.get(opts, :settle_ms, 0),
           match_fn: fn ["interface", :_, "type"] ->
             Agent.get(table, & &1) |> Enum.map(&{["interface", &1.ifname, "type"], &1.type})
           end,
           get_fn: fn ["interface", ifname, "connection"] ->
             Agent.get(table, & &1) |> Enum.find_value(&(&1.ifname == ifname && &1.connection))
           end,
           load_persisted_fn: fn ifname ->
             Agent.get(table, & &1) |> Enum.find_value(&(&1.ifname == ifname && &1.persisted))
           end,
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

    test "never suspends a wifi with no persisted config (nothing to restore from)" do
      start_policy([@eth, @wifi_unpersisted])
      refute_receive {:deconfigure, _, _}, 100
    end

    test "suspend on cable plug, restore the persisted config on cable pull" do
      ctx = start_policy([@eth_down, @wifi])
      refute_receive {:deconfigure, _, _}, 100

      set_ifaces(ctx, [@eth, @wifi])
      assert_receive {:deconfigure, "wlan0", persist: false}

      set_ifaces(ctx, [@eth_down, @wifi_null])
      assert_receive {:configure, "wlan0", @wifi_config, persist: false}
    end

    test "restores after a policy restart while suspended (stateless recovery)" do
      # Fresh process, wifi already Null (suspended by a previous incarnation):
      # a cable pull must still restore from the persisted config.
      ctx = start_policy([@eth, @wifi_null])
      refute_receive {:deconfigure, _, _}, 100

      set_ifaces(ctx, [@eth_down, @wifi_null])
      assert_receive {:configure, "wlan0", @wifi_config, persist: false}
    end

    test "repeated ethernet-up events do not re-deconfigure a suspended wifi" do
      ctx = start_policy([@eth, @wifi])
      assert_receive {:deconfigure, "wlan0", persist: false}

      set_ifaces(ctx, [@eth, @wifi_null])
      refute_receive {:deconfigure, _, _}, 100
    end

    test "unrecognized messages are ignored" do
      ctx = start_policy([@eth_down, @wifi])
      send(ctx.policy, :garbage)
      send(ctx.policy, {:unexpected, "tuple"})
      assert %{ethernet_up?: false} = WifiPolicy.status(ctx.policy)
    end

    test "status/1 reports idle and suspended states" do
      ctx = start_policy([@eth_down, @wifi])
      assert %{ethernet_up?: false, suspended: []} = WifiPolicy.status(ctx.policy)

      set_ifaces(ctx, [@eth, @wifi_null])
      assert %{ethernet_up?: true, suspended: ["wlan0"]} = WifiPolicy.status(ctx.policy)
    end

    test "connection events defer evaluation to the settle timer" do
      # Timer parked far out so CI scheduling jitter can't fire it mid-test:
      # a flap that settles back never evaluates with the mid-flap state.
      ctx = start_policy([@eth_down, @wifi], settle_ms: 60_000)

      set_ifaces(ctx, [@eth, @wifi])
      set_ifaces(ctx, [@eth_down, @wifi])

      refute_receive {:deconfigure, _, _}, 150
    end

    test "a stale :evaluate from a cancelled timer is ignored" do
      ctx = start_policy([@eth_down, @wifi])

      # cancel_timer/1 doesn't flush an already-delivered message — simulate
      # one whose token is no longer current while the table says eth-up.
      Agent.update(ctx.table, fn _ -> [@eth, @wifi] end)
      send(ctx.policy, {:evaluate, make_ref()})
      refute_receive {:deconfigure, _, _}, 100

      # The real event path still evaluates.
      set_ifaces(ctx, [@eth, @wifi])
      assert_receive {:deconfigure, "wlan0", persist: false}, 500
    end
  end
end
