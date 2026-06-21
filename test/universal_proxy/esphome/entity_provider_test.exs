defmodule UniversalProxy.ESPHome.EntityProviderTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.ESPHome.EntityProvider, as: EP
  alias Espex.Proto

  # All BT-gated object_ids, for asserting the gating boundary.
  @bt_object_ids ~w(ble_devices_15m ble_ads_per_sec gatt_connections bluetooth_powered)

  defp sample_sources(overrides \\ %{}) do
    Map.merge(
      %{
        metrics: fn ->
          %{
            cpu_temp_c: 47.2,
            mem_used_pct: 31,
            load1: 0.42,
            data_used_pct: 12,
            boot_time_unix: 1_700_000_000
          }
        end,
        wifi: fn -> nil end,
        network_type: fn -> :ethernet end,
        firmware: fn -> %{version: "1.2.3", target: "rpi3"} end,
        ip: fn -> "192.168.1.50" end,
        clients_count: fn -> 2 end,
        audio: fn -> [] end,
        bt_stats: fn -> %{devices_15min: 7, ads_per_s: 5, connections: %{used: 1, limit: 4}} end,
        adapters: fn -> [%{powered: true}] end
      },
      overrides
    )
  end

  describe "advertisements/2 (BT gating)" do
    test "includes BT entities when supported" do
      ads = EP.advertisements(all_specs(), true)
      object_ids = Enum.map(ads, & &1.object_id)
      assert Enum.all?(@bt_object_ids, &(&1 in object_ids))
      assert length(ads) == 20
    end

    test "excludes BT entities when unsupported" do
      ads = EP.advertisements(all_specs(), false)
      object_ids = Enum.map(ads, & &1.object_id)
      refute Enum.any?(@bt_object_ids, &(&1 in object_ids))
      assert length(ads) == 16
    end
  end

  describe "advertisements/2 (struct + flags)" do
    test "factory_reset is a config button, disabled by default" do
      ad = find_ad("factory_reset")
      assert %Proto.ListEntitiesButtonResponse{} = ad
      assert ad.entity_category == :ENTITY_CATEGORY_CONFIG
      assert ad.disabled_by_default == true
      assert ad.key == EP.key_for("factory_reset")
    end

    test "reboot is a config button, enabled" do
      ad = find_ad("reboot")
      assert %Proto.ListEntitiesButtonResponse{} = ad
      assert ad.entity_category == :ENTITY_CATEGORY_CONFIG
      assert ad.disabled_by_default == false
    end

    test "cpu_temperature is a diagnostic measurement sensor" do
      ad = find_ad("cpu_temperature")
      assert %Proto.ListEntitiesSensorResponse{} = ad
      assert ad.device_class == "temperature"
      assert ad.unit_of_measurement == "°C"
      assert ad.accuracy_decimals == 1
      assert ad.state_class == :STATE_CLASS_MEASUREMENT
      assert ad.entity_category == :ENTITY_CATEGORY_DIAGNOSTIC
    end

    test "uptime is a timestamp sensor with no measurement state class" do
      ad = find_ad("uptime")
      assert ad.device_class == "timestamp"
      assert ad.state_class == :STATE_CLASS_NONE
    end

    test "firmware_version is a text sensor" do
      assert %Proto.ListEntitiesTextSensorResponse{} = find_ad("firmware_version")
    end

    test "audio_streaming is a binary sensor" do
      ad = find_ad("audio_streaming")
      assert %Proto.ListEntitiesBinarySensorResponse{} = ad
      assert ad.device_class == "running"
    end
  end

  describe "read_values/2" do
    test "maps metrics, firmware, network, and counts" do
      v = EP.read_values(sample_sources(), false)
      assert v["cpu_temperature"] == 47.2
      assert v["memory_used"] == 31
      assert v["load_1min"] == 0.42
      assert v["uptime"] == 1_700_000_000
      assert v["api_clients"] == 2
      assert v["firmware_version"] == "1.2.3"
      assert v["board_target"] == "rpi3"
      assert v["network_type"] == "Ethernet"
      assert v["ip_address"] == "192.168.1.50"
    end

    test "wifi values are nil when not associated" do
      v = EP.read_values(sample_sources(), false)
      assert v["wifi_signal"] == nil
      assert v["wifi_ssid"] == nil
    end

    test "wifi values populated when associated" do
      sources = sample_sources(%{wifi: fn -> %{ssid: "HomeNet", rssi_dbm: -57} end})
      v = EP.read_values(sources, false)
      assert v["wifi_signal"] == -57
      assert v["wifi_ssid"] == "HomeNet"
    end

    test "BT values present only when supported" do
      assert Map.has_key?(EP.read_values(sample_sources(), true), "ble_devices_15m")
      refute Map.has_key?(EP.read_values(sample_sources(), false), "ble_devices_15m")
    end

    test "BT values read from stats and adapters when supported" do
      v = EP.read_values(sample_sources(), true)
      assert v["ble_devices_15m"] == 7
      assert v["ble_ads_per_sec"] == 5
      assert v["gatt_connections"] == 1
      assert v["bluetooth_powered"] == true
    end

    test "audio counts active outputs and streaming flag" do
      audio = fn ->
        [
          %{connection: :connected, stream: %{codec: "flac"}},
          %{connection: :disconnected, stream: nil},
          %{connection: :connected, stream: nil}
        ]
      end

      v = EP.read_values(sample_sources(%{audio: audio}), false)
      assert v["audio_outputs_active"] == 2
      assert v["audio_streaming"] == true
    end

    test "a crashing source degrades to a fallback, not a crash" do
      sources = sample_sources(%{metrics: fn -> raise "boom" end, ip: fn -> exit(:dead) end})
      v = EP.read_values(sources, false)
      assert v["cpu_temperature"] == nil
      assert v["ip_address"] == nil
      # other sources still read
      assert v["firmware_version"] == "1.2.3"
    end
  end

  describe "state_responses/3 (missing_state)" do
    test "nil numeric/text values are flagged missing" do
      responses = EP.state_responses(all_specs(), EP.read_values(sample_sources(), false), false)
      wifi_signal = find_state(responses, "wifi_signal")
      assert %Proto.SensorStateResponse{} = wifi_signal
      assert wifi_signal.missing_state == true

      wifi_ssid = find_state(responses, "wifi_ssid")
      assert %Proto.TextSensorStateResponse{} = wifi_ssid
      assert wifi_ssid.missing_state == true
    end

    test "present values are not missing and coerce ints to float" do
      responses = EP.state_responses(all_specs(), EP.read_values(sample_sources(), false), false)
      mem = find_state(responses, "memory_used")
      assert mem.state == 31.0
      assert mem.missing_state == false
    end

    test "buttons produce no state response" do
      responses = EP.state_responses(all_specs(), EP.read_values(sample_sources(), false), false)
      refute Enum.any?(responses, &(&1.key == EP.key_for("factory_reset")))
      refute Enum.any?(responses, &(&1.key == EP.key_for("reboot")))
    end
  end

  describe "changed/2 (diff)" do
    test "returns only keys whose value differs" do
      last = %{"a" => 1, "b" => 2, "c" => nil}
      current = %{"a" => 1, "b" => 3, "c" => 5}
      assert Enum.sort(EP.changed(last, current)) == [{"b", 3}, {"c", 5}]
    end

    test "a value first seen counts as changed" do
      assert EP.changed(%{}, %{"a" => 1}) == [{"a", 1}]
    end

    test "no change yields an empty list" do
      assert EP.changed(%{"a" => 1}, %{"a" => 1}) == []
    end
  end

  describe "handle_command routing" do
    test "known button keys route without crashing (host no-ops)" do
      state = %{keys: key_lookup(), server: nil}

      for object_id <- ~w(factory_reset reboot) do
        cmd = %Proto.ButtonCommandRequest{key: EP.key_for(object_id)}
        assert {:noreply, ^state} = EP.handle_cast({:command, cmd}, state)
      end
    end

    test "unknown button key is ignored" do
      state = %{keys: key_lookup(), server: nil}
      cmd = %Proto.ButtonCommandRequest{key: 999_999}
      assert {:noreply, ^state} = EP.handle_cast({:command, cmd}, state)
    end

    test "non-button commands are ignored" do
      state = %{keys: key_lookup(), server: nil}
      assert {:noreply, ^state} = EP.handle_cast({:command, %{some: :thing}}, state)
    end
  end

  describe "poll loop diff-push (integration)" do
    test "first poll pushes every stateful value; an unchanged second poll pushes nothing" do
      server = :"ep_test_#{System.unique_integer([:positive])}"
      registry = Module.concat(server, "Registry")
      start_supervised!({Registry, keys: :duplicate, name: registry})
      {:ok, _} = Registry.register(registry, :subscribers, nil)

      name = :"ep_proc_#{System.unique_integer([:positive])}"

      pid =
        start_supervised!(
          {EP,
           name: name,
           server: server,
           poll: false,
           supported?: false,
           sources: Map.to_list(sample_sources())}
        )

      # First poll: empty `last` → every stateful (non-button) value pushed.
      GenServer.call(pid, :poll_now)
      assert drain_pushes() == 14

      # Identical second poll: nothing changed → no pushes.
      GenServer.call(pid, :poll_now)
      assert drain_pushes() == 0
    end

    test "startup seed populates last WITHOUT pushing (no Espex registry → no crash)" do
      # poll: true triggers handle_continue. Deliberately do NOT start the
      # Espex registry: if the seed pushed, push_state would raise and crash
      # the provider. It must seed `last` quietly instead. Regression for the
      # boot-time `unknown registry: Espex.Server.Registry` crash.
      name = :"ep_seed_#{System.unique_integer([:positive])}"

      pid =
        start_supervised!(
          {EP,
           name: name,
           server: :"ep_seed_noreg_#{System.unique_integer([:positive])}",
           poll: true,
           tick_ms: 60_000,
           supported?: false,
           sources: Map.to_list(sample_sources())}
        )

      # Give handle_continue a moment to run, then prove it's alive + seeded.
      _ = :sys.get_state(pid)
      assert Process.alive?(pid)
      assert :sys.get_state(pid).last["cpu_temperature"] == 47.2
    end

    test "the :poll timer reschedules itself (poll: true)" do
      server = :"ep_sched_#{System.unique_integer([:positive])}"
      registry = Module.concat(server, "Registry")
      start_supervised!({Registry, keys: :duplicate, name: registry})
      {:ok, _} = Registry.register(registry, :subscribers, nil)

      # A source whose value changes every read, so every tick produces a push.
      {:ok, counter} = start_supervised({Agent, fn -> 0 end})

      metrics = fn ->
        n = Agent.get_and_update(counter, &{&1, &1 + 1})

        %{
          cpu_temp_c: n * 1.0,
          mem_used_pct: nil,
          load1: nil,
          data_used_pct: nil,
          boot_time_unix: 1
        }
      end

      sources = sample_sources(%{metrics: metrics})
      name = :"ep_sched_proc_#{System.unique_integer([:positive])}"

      start_supervised!(
        {EP,
         name: name,
         server: server,
         poll: true,
         tick_ms: 30,
         supported?: false,
         sources: Map.to_list(sources)}
      )

      # Startup seed (handle_continue) produces the first batch of pushes.
      assert_receive {:espex_state_update, _}, 300

      # Clear the mailbox, then confirm a *later* push arrives — only
      # possible if the :poll timer rescheduled itself after the tick.
      flush_mailbox()
      assert_receive {:espex_state_update, _}, 300
    end
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  # Counting pushes is safe with a 50 ms timeout because GenServer.call(:poll_now)
  # is synchronous: it returns only after do_poll/1 has sent every push_state
  # message, so the mailbox is already populated by the time we drain.
  defp drain_pushes(count \\ 0) do
    receive do
      {:espex_state_update, _struct} -> drain_pushes(count + 1)
    after
      50 -> count
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────

  defp all_specs, do: EP.specs()

  defp key_lookup, do: Map.new(all_specs(), &{EP.key_for(&1.object_id), &1.object_id})

  defp find_ad(object_id) do
    all_specs() |> EP.advertisements(true) |> Enum.find(&(&1.object_id == object_id))
  end

  defp find_state(responses, object_id) do
    Enum.find(responses, &(&1.key == EP.key_for(object_id)))
  end
end
