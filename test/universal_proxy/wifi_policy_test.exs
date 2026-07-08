defmodule UniversalProxy.WifiPolicyTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.WifiPolicy

  @wifi_config %{
    type: VintageNetWiFi,
    vintage_net_wifi: %{networks: [%{key_mgmt: :wpa_psk, ssid: "Net", psk: "pw"}]},
    ipv4: %{method: :dhcp}
  }

  @eth %{
    ifname: "eth0",
    type: VintageNetEthernet,
    connection: :internet,
    lower_up: true,
    persisted: nil
  }
  @eth_carrier %{@eth | connection: :disconnected, lower_up: true}
  @eth_down %{@eth | connection: :disconnected, lower_up: false}
  @wifi %{
    ifname: "wlan0",
    type: VintageNetWiFi,
    connection: :internet,
    lower_up: true,
    persisted: @wifi_config
  }
  @wifi_null %{@wifi | type: VintageNet.Technology.Null, connection: :disconnected}
  @wifi_unpersisted %{@wifi | persisted: nil}

  describe "decide/2 (pure)" do
    test ":deciding suspends every persisted wifi-typed interface (hold)" do
      assert %{mode: :deciding, suspend: ["wlan0"]} =
               WifiPolicy.decide(:deciding, [@eth_down, @wifi])
    end

    test ":deciding locks :wired on ethernet carrier alone" do
      assert %{mode: :wired, suspend: ["wlan0"]} =
               WifiPolicy.decide(:deciding, [@eth_carrier, @wifi])
    end

    test ":deciding locks :wired on connected ethernet" do
      assert %{mode: :wired} = WifiPolicy.decide(:deciding, [@eth, @wifi_null])
    end

    test ":deciding leaves a runtime-only (unpersisted) wifi alone" do
      assert %{suspend: []} = WifiPolicy.decide(:deciding, [@eth, @wifi_unpersisted])
    end

    test ":wired never restores, even with ethernet gone" do
      assert %{mode: :wired, suspend: [], restore: []} =
               WifiPolicy.decide(:wired, [@eth_down, @wifi_null])
    end

    test ":wired re-suspends a persisted wifi that reappears" do
      assert %{mode: :wired, suspend: ["wlan0"]} = WifiPolicy.decide(:wired, [@eth_down, @wifi])
    end

    test ":wireless with ethernet down changes nothing" do
      assert %{mode: :wireless, suspend: [], restore: []} =
               WifiPolicy.decide(:wireless, [@eth_down, @wifi])
    end

    test ":wireless ignores a mere carrier (dead cable must not kill working wifi)" do
      assert %{mode: :wireless, suspend: []} = WifiPolicy.decide(:wireless, [@eth_carrier, @wifi])
    end

    test ":wireless locks :wired when ethernet reaches connectivity" do
      assert %{mode: :wired, suspend: ["wlan0"]} = WifiPolicy.decide(:wireless, [@eth, @wifi])
    end

    test "multiple wifi interfaces are all suspended" do
      wifi1 = %{@wifi | ifname: "wlan1"}
      assert %{suspend: ["wlan0", "wlan1"]} = WifiPolicy.decide(:deciding, [@eth, @wifi, wifi1])
    end
  end

  describe "decide_boot_expiry/1 (pure)" do
    test "no ethernet: :wireless, restoring suspended persisted wifi" do
      assert %{mode: :wireless, restore: ["wlan0"]} =
               WifiPolicy.decide_boot_expiry([@eth_down, @wifi_null])
    end

    test "no ethernet interface at all: :wireless" do
      assert %{mode: :wireless, restore: ["wlan0"]} = WifiPolicy.decide_boot_expiry([@wifi_null])
    end

    test "ethernet carrier at expiry: :wired, no restore" do
      assert %{mode: :wired, restore: []} =
               WifiPolicy.decide_boot_expiry([@eth_carrier, @wifi_null])
    end

    test "a Null interface with no persisted config is not restored" do
      null_unpersisted = %{@wifi_null | persisted: nil}

      assert %{mode: :wireless, restore: []} =
               WifiPolicy.decide_boot_expiry([@eth_down, null_unpersisted])
    end

    test "an active (never-suspended) wifi is not re-configured" do
      assert %{mode: :wireless, restore: []} = WifiPolicy.decide_boot_expiry([@eth_down, @wifi])
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
        start_supervised!({WifiPolicy,
         name: nil,
         subscribe?: false,
         settle_ms: Keyword.get(opts, :settle_ms, 0),
         boot_grace_ms: Keyword.get(opts, :boot_grace_ms, 60_000),
         match_fn: fn ["interface", :_, "type"] ->
           Agent.get(table, & &1) |> Enum.map(&{["interface", &1.ifname, "type"], &1.type})
         end,
         get_fn: fn ["interface", ifname, prop] when prop in ["connection", "lower_up"] ->
           # Enum.find + Map.get so a stored `false` (lower_up) survives —
           # find_value would swallow it and misreport the iface as absent.
           key = %{"connection" => :connection, "lower_up" => :lower_up}[prop]

           case Enum.find(Agent.get(table, & &1), &(&1.ifname == ifname)) do
             nil -> nil
             iface -> Map.get(iface, key)
           end
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
         end})

      %{policy: policy, table: table}
    end

    defp set_ifaces(%{table: table, policy: policy}, ifaces) do
      Agent.update(table, fn _ -> ifaces end)
      send(policy, {VintageNet, ["interface", "eth0", "connection"], nil, nil, %{}})
    end

    test "suspends wifi immediately at boot, before ethernet is up" do
      ctx = start_policy([@eth_down, @wifi])
      assert_receive {:deconfigure, "wlan0", persist: false}
      assert %{mode: :deciding} = WifiPolicy.status(ctx.policy)
    end

    test "locks :wired when ethernet shows a carrier during the grace window" do
      ctx = start_policy([@eth_down, @wifi])
      assert_receive {:deconfigure, "wlan0", persist: false}

      set_ifaces(ctx, [@eth_carrier, @wifi_null])
      refute_receive {:configure, _, _, _}, 100
      assert %{mode: :wired} = WifiPolicy.status(ctx.policy)
    end

    test "restores wifi when the grace window expires with no ethernet" do
      ctx = start_policy([@eth_down, @wifi], boot_grace_ms: 50)
      assert_receive {:deconfigure, "wlan0", persist: false}

      # The table must reflect the suspension for the stateless restore read.
      Agent.update(ctx.table, fn _ -> [@eth_down, @wifi_null] end)

      assert_receive {:configure, "wlan0", @wifi_config, persist: false}, 1_000
      assert %{mode: :wireless} = WifiPolicy.status(ctx.policy)
    end

    test "no persisted wifi: nothing suspended, nothing restored, still decides" do
      ctx = start_policy([@eth_down, @wifi_unpersisted], boot_grace_ms: 50)
      refute_receive {:deconfigure, _, _}, 200
      refute_receive {:configure, _, _, _}, 100
      assert %{mode: :wireless} = WifiPolicy.status(ctx.policy)
    end

    test "cable pull while :wired does NOT restore wifi (locked until reboot)" do
      ctx = start_policy([@eth, @wifi])
      assert_receive {:deconfigure, "wlan0", persist: false}
      assert %{mode: :wired} = WifiPolicy.status(ctx.policy)

      set_ifaces(ctx, [@eth_down, @wifi_null])
      refute_receive {:configure, _, _, _}, 200
      assert %{mode: :wired} = WifiPolicy.status(ctx.policy)
    end

    test "ethernet connecting while :wireless suspends wifi one-way" do
      ctx = start_policy([@eth_down, @wifi], boot_grace_ms: 50)
      assert_receive {:deconfigure, "wlan0", persist: false}
      Agent.update(ctx.table, fn _ -> [@eth_down, @wifi_null] end)
      assert_receive {:configure, "wlan0", @wifi_config, persist: false}, 1_000

      set_ifaces(ctx, [@eth, @wifi])
      assert_receive {:deconfigure, "wlan0", persist: false}
      assert %{mode: :wired} = WifiPolicy.status(ctx.policy)

      # ...and the lock holds on a subsequent cable pull.
      set_ifaces(ctx, [@eth_down, @wifi_null])
      refute_receive {:configure, _, _, _}, 200
    end

    test "policy restart while suspended re-decides from scratch (stateless)" do
      # Fresh process, wifi already Null (suspended by a previous incarnation),
      # no ethernet: the grace expiry restores from the persisted config.
      ctx = start_policy([@eth_down, @wifi_null], boot_grace_ms: 50)
      assert_receive {:configure, "wlan0", @wifi_config, persist: false}, 1_000
      assert %{mode: :wireless} = WifiPolicy.status(ctx.policy)
    end

    test "repeated ethernet-up events do not re-deconfigure a suspended wifi" do
      ctx = start_policy([@eth, @wifi])
      assert_receive {:deconfigure, "wlan0", persist: false}

      set_ifaces(ctx, [@eth, @wifi_null])
      refute_receive {:deconfigure, _, _}, 100
    end

    test "a late boot-grace message after locking :wired is ignored" do
      ctx = start_policy([@eth, @wifi], boot_grace_ms: 50)
      assert_receive {:deconfigure, "wlan0", persist: false}
      assert %{mode: :wired} = WifiPolicy.status(ctx.policy)

      Agent.update(ctx.table, fn _ -> [@eth, @wifi_null] end)
      refute_receive {:configure, _, _, _}, 200
      assert %{mode: :wired} = WifiPolicy.status(ctx.policy)
    end

    test "unrecognized messages are ignored" do
      ctx = start_policy([@eth_down, @wifi])
      send(ctx.policy, :garbage)
      send(ctx.policy, {:unexpected, "tuple"})
      assert %{ethernet_up?: false} = WifiPolicy.status(ctx.policy)
    end

    test "status/1 reports mode and suspended interfaces" do
      ctx = start_policy([@eth, @wifi])
      assert_receive {:deconfigure, "wlan0", persist: false}

      set_ifaces(ctx, [@eth, @wifi_null])

      assert %{mode: :wired, ethernet_up?: true, suspended: ["wlan0"]} =
               WifiPolicy.status(ctx.policy)
    end

    test "connection events defer evaluation to the settle timer" do
      # Timer parked far out so CI scheduling jitter can't fire it mid-test:
      # a flap that settles back never evaluates with the mid-flap state.
      ctx = start_policy([@eth_down, @wifi], settle_ms: 60_000, boot_grace_ms: 60_000)
      assert_receive {:deconfigure, "wlan0", persist: false}

      # Wifi restored by hand mid-flap; the parked timer must not act on it.
      set_ifaces(ctx, [@eth_carrier, @wifi])
      set_ifaces(ctx, [@eth_down, @wifi])

      refute_receive {:deconfigure, _, _}, 150
      assert %{mode: :deciding} = WifiPolicy.status(ctx.policy)
    end

    test "a stale :evaluate from a cancelled timer is ignored" do
      ctx = start_policy([@eth_down, @wifi])
      assert_receive {:deconfigure, "wlan0", persist: false}

      # cancel_timer/1 doesn't flush an already-delivered message — simulate
      # one whose token is no longer current while the table says eth-up.
      Agent.update(ctx.table, fn _ -> [@eth, @wifi] end)
      send(ctx.policy, {:evaluate, make_ref()})
      refute_receive {:deconfigure, _, _}, 100
      assert %{mode: :deciding} = WifiPolicy.status(ctx.policy)

      # The real event path still evaluates and locks.
      set_ifaces(ctx, [@eth, @wifi])
      assert_receive {:deconfigure, "wlan0", persist: false}, 500
      assert %{mode: :wired} = WifiPolicy.status(ctx.policy)
    end
  end
end
