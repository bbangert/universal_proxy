defmodule UniversalProxy.TuyaBeaconMesh.LightsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias UniversalProxy.TuyaBeaconMesh.{
    Carrier,
    Crypto,
    Dp,
    FakeBluez,
    Inventory,
    Lights,
    P2,
    Radio
  }

  @fixture Path.join([
             __DIR__,
             "..",
             "..",
             "fixtures",
             "tuya_beacon_mesh",
             "example_inventory.json"
           ])

  @beacon_key "00112233445566778899aabbccddeeff"
  @other_key "ffeeddccbbaa99887766554433221100"
  # "path light 2" is node 2, "post spot 1" node 3.
  @mac2 0xDC23530FB34A
  @mac3 0xDC23533FCD62

  setup do
    FakeBluez.ensure_started()
    FakeBluez.reset()

    start_supervised!(radio_spec())

    persisted = :ets.new(:lights_persist, [:public, :set])
    :ets.insert(persisted, {:writes, 0})

    start_supervised!(
      {Lights, inventory: File.read!(@fixture), radio: Radio, on_persist: persist_to(persisted)}
    )

    # Both servers finish setup in handle_continue; these calls only return
    # once the receiver is registered and Lights has subscribed.
    {:ok, _} = Radio.status()
    {:ok, _} = Lights.all()

    {:ok, persisted: persisted}
  end

  test "loads inventory and resolves by label" do
    assert {:ok, bulbs} = Lights.all()
    assert Enum.any?(bulbs, &(&1.label == "path light 2" and &1.node_id == 2))
    assert {:ok, %{label: "post spot 1", node_id: 3}} = Lights.status("post spot 1")
    assert {:ok, %{label: "post spot 1"}} = Lights.status("dc:23:53:3f:cd:62")
    assert {:error, :unknown_bulb} = Lights.status("nobody")
  end

  describe "commands" do
    test "set enqueues a phone-sourced frame and persists advanced seq", %{persisted: persisted} do
      assert :ok = Lights.set("path light 2", [on: true], ack: true)
      wait_until(fn -> advertises() != [] end)

      assert [frame] = advertises() |> List.last() |> Carrier.frames()
      <<_hdr, src::binary-2, dst::binary-2, sn::16-big, sub_cmd, _::binary>> = frame
      assert src == <<0x80, 0x01>>
      assert dst == <<0x00, 0x02>>
      assert sn == 100
      assert sub_cmd == 0x06

      assert %{seq: 132} = last_persisted(persisted)
    end

    test "ping, reset and group_set reach the radio with their classes" do
      assert sent_sn(fn -> Lights.ping("path light 2") end) == 100

      assert sent_sn(fn -> Lights.reset("post spot 1") end) == 101
      assert sent_sn(fn -> Lights.group_set("path and post", on: false) end) == 102
      assert sent_sn(fn -> Lights.group_set(1, brightness: 500) end) == 103

      [ping, reset, g1, g2] = Enum.map(advertises(), &hd(Carrier.frames(&1)))
      assert <<0x13, 0x80, 0x01, 0x00, 0x02, _::binary>> = ping
      assert <<0x0B, 0x80, 0x01, 0x00, 0x03, _::binary-2, 0x01, _::binary>> = reset
      assert <<_, 0x80, 0x01, 0xFF, 0x01, _::binary>> = g1
      assert <<_, 0x80, 0x01, 0xFF, 0x01, _::binary>> = g2

      assert {:error, :unknown_group} = Lights.group_set("nope", on: true)
      assert {:error, :unknown_group} = Lights.group_set(9, on: true)
      assert {:error, :unknown_bulb} = Lights.ping("nobody")
      assert {:error, :unknown_bulb} = Lights.reset("nobody")
    end

    test "unicast frames are masked with the bulb's own beaconKey, group frames with the mesh key" do
      inv = fixture(%{}) |> put_in(["bulbs", Access.at(1), "beaconKey"], @other_key)
      assert :ok = Lights.reload(inv)
      local3 = "ponmlkjihgfedcba"

      sent_sn(fn -> Lights.set("post spot 1", on: true) end)
      sent_sn(fn -> Lights.ping("post spot 1") end)
      sent_sn(fn -> Lights.reset("post spot 1") end)
      sent_sn(fn -> Lights.set("path light 2", on: true) end)
      sent_sn(fn -> Lights.group_set(1, on: true) end)

      [set3, ping3, reset3, set2, group] = Enum.map(advertises(), &hd(Carrier.frames(&1)))

      for frame <- [set3, ping3, reset3] do
        assert masked_with?(frame, @other_key, local3)
        refute masked_with?(frame, @beacon_key, local3)
      end

      assert masked_with?(set2, @beacon_key, "abcdefghijklmnop")
      assert masked_with?(group, @beacon_key, @beacon_key)
      refute masked_with?(group, @other_key, @beacon_key)
    end

    test "a command that can't be built gives its sequence number back", %{
      persisted: persisted
    } do
      assert {:error, {:bad_mode, :disco}} = Lights.set("path light 2", mode: :disco)
      assert {:error, :no_dps} = Lights.group_set(1, [])
      assert {:error, :too_long} = Lights.set("path light 2", too_long_dps())
      assert advertises() == []

      assert set_sn("path light 2", on: true) == 100
      assert writes(persisted) == 1
    end

    test "a second block is reserved and persisted after 32 sends", %{persisted: persisted} do
      sns = for i <- 1..33, do: set_sn("path light 2", brightness: 10 + i)

      assert sns == Enum.to_list(100..132)
      assert writes(persisted) == 2
      assert %{seq: 164} = last_persisted(persisted)
    end

    test "the sequence wraps from 65535 to 0 through Lights" do
      assert :ok = Lights.reload(fixture(%{"beaconKey" => @other_key, "seq" => 65_530}))

      sns = for i <- 1..8, do: set_sn("path light 2", brightness: 10 + i)
      assert sns == [65_530, 65_531, 65_532, 65_533, 65_534, 65_535, 0, 1]
    end
  end

  describe "persistence safety" do
    test "a persist failure sends nothing and reuses no number", %{persisted: persisted} do
      fail_persist(persisted, {:error, :enospc})

      log =
        capture_log(fn ->
          assert {:error, :persist_failed} = Lights.set("path light 2", on: true)
        end)

      assert log =~ "on_persist failed (error :enospc)"
      refute log =~ @beacon_key
      assert advertises() == []

      # Raises and odd return values are failures too, and Lights survives.
      pid = Process.whereis(Lights)
      fail_persist(persisted, :raise)

      capture_log(fn ->
        assert {:error, :persist_failed} = Lights.ping("path light 2")
      end)

      fail_persist(persisted, true)

      capture_log(fn ->
        assert {:error, :persist_failed} = Lights.ping("path light 2")
      end)

      assert Process.whereis(Lights) == pid
      assert advertises() == []

      fail_persist(persisted, nil)
      first = for i <- 1..32, do: set_sn("path light 2", brightness: 10 + i)
      assert first == Enum.to_list(100..131)

      # The next block can't be persisted: nothing goes out until it is.
      fail_persist(persisted, {:error, :busy})

      capture_log(fn ->
        assert {:error, :persist_failed} = Lights.set("path light 2", on: false)
      end)

      fail_persist(persisted, nil)
      assert set_sn("path light 2", on: false) == 132

      sent = Enum.map(advertises(), &frame_sn/1)
      assert sent == Enum.uniq(sent)
      assert sent == Enum.sort(sent)
    end

    test "a persisted seq survives a Lights crash when it starts from a loader", %{
      persisted: persisted
    } do
      stop_supervised!(Lights)

      loader = fn ->
        case :ets.lookup(persisted, :inv) do
          [{:inv, inv}] -> {:ok, inv}
          [] -> {:ok, File.read!(@fixture)}
        end
      end

      start_supervised!(
        {Lights, inventory: loader, radio: Radio, on_persist: persist_to(persisted)}
      )

      assert set_sn("path light 2", on: true) == 100
      assert set_sn("path light 2", on: false) == 101

      old = Process.whereis(Lights)
      Process.exit(old, :kill)
      wait_until(fn -> match?(pid when is_pid(pid) and pid != old, Process.whereis(Lights)) end)

      # 102..131 were reserved but never sent; skipping them is harmless,
      # reusing 100/101 would not be.
      assert set_sn("path light 2", on: true) == 132
    end

    @tag :capture_log
    test "a refused frame gives its number back instead of burning it", %{persisted: persisted} do
      # Radio process gone: nothing reached it.
      stop_supervised!({Radio, 1})
      assert {:error, :not_running} = Lights.set("path light 2", on: true)

      # Radio up but the lease turns out to be gone: refused before air.
      start_supervised!(radio_spec())
      wait_until(&radio_ready?/0)
      FakeBluez.fail(:advertise, :lease_expired)

      capture_log(fn ->
        assert {:error, :not_ready} = Lights.set("path light 2", on: true)
        assert {:error, :not_ready} = Lights.set("path light 2", on: true)
      end)

      # The adapter refusing just this one frame.
      FakeBluez.succeed(:advertise)
      wait_until(&radio_ready?/0)
      FakeBluez.fail(:advertise, :busy)

      capture_log(fn ->
        assert {:error, {:advertise, :busy}} = Lights.set("path light 2", on: true)
      end)

      FakeBluez.succeed(:advertise)
      assert set_sn("path light 2", on: true) == 100
      assert writes(persisted) == 1
    end

    @tag :capture_log
    test "queued sets coalesce per bulb and DPs; a full queue gives the number back" do
      stop_supervised!({Radio, 1})
      start_supervised!(radio_spec(max_queue: 1))
      wait_until(&radio_ready?/0)

      assert :ok = Lights.set("path light 2", on: true)
      wait_until(fn -> length(advertises()) == 1 end)

      # Queued: brightness 100, then 200 replaces it (same bulb, same DPs).
      assert :ok = Lights.set("path light 2", brightness: 100)
      assert :ok = Lights.set("path light 2", brightness: 200)
      assert {:ok, %{queued: 1}} = Radio.status()

      # Other DPs don't coalesce, and the queue is full.
      assert {:error, :queue_full} = Lights.set("path light 2", temp: 10)

      # The on-air frame's time runs out: the latest brightness goes next.
      finish_tx()
      assert :ok = Lights.set("path light 2", temp: 10)
      finish_tx()

      assert Enum.map(advertises(), &frame_sn/1) == [100, 102, 103]
    end

    test "reload validates first and rolls back when it can't persist", %{persisted: persisted} do
      assert {:error, {:duplicate_node_id, 2, _}} =
               Lights.reload(
                 update_in(fixture(%{}), ["bulbs", Access.at(1)], &Map.put(&1, "nodeId", 2))
               )

      assert {:error, :bad_beacon_key} =
               Lights.reload(%{beacon_key: "zz", bulbs: [%{mac: "AABBCCDDEEFF"}]})

      fail_persist(persisted, {:error, :busy})

      capture_log(fn ->
        assert {:error, :persist_failed} = Lights.reload(fixture(%{"seq" => 5_000}))
      end)

      assert {:ok, %{seq: 100}} = Lights.inventory()
      fail_persist(persisted, nil)
      assert set_sn("path light 2", on: true) == 100
    end
  end

  describe "start-up" do
    test "an unusable inventory makes init :ignore without logging keys" do
      bad_json = ~s({"beaconKey": "#{@beacon_key}", "bulbs": [)

      for inventory <- [
            bad_json,
            fixture(%{"beaconKey" => "not-a-key"}),
            fn -> {:error, :settings_missing} end,
            fn -> raise "boom" end,
            fn -> :nope end,
            # Loader errors that carry the dump itself.
            fn -> Jason.decode(bad_json) end,
            fn -> {:error, {:bad_json, bad_json}} end,
            fn -> {:error, bad_json} end,
            fn -> {:error, [bad_json]} end
          ] do
        log =
          capture_log(fn ->
            assert :ignore = Lights.start_link(inventory: inventory, name: :lights_bad)
          end)

        assert log =~ "inventory unusable"
        refute log =~ @beacon_key
      end
    end

    test "a loader can be an MFA, and a custom name is addressed with server:" do
      start_supervised!(
        {Lights, inventory: {File, :read, [@fixture]}, name: :other_lights, radio: Radio}
      )

      assert {:ok, %{node_id: 3}} = Lights.status("post spot 1", server: :other_lights)
      assert {:ok, [_, _]} = Lights.all(server: :other_lights)
      assert {:error, :not_running} = Lights.all(server: :no_such_lights)
    end
  end

  describe "redaction" do
    test ":sys.get_status shows no key material" do
      text = inspect(:sys.get_status(Lights))

      refute text =~ @beacon_key
      refute text =~ "abcdefghijklmnop"
      refute text =~ "ponmlkjihgfedcba"
      assert text =~ "path light 2"
    end

    test "a crash while reloading doesn't log the dump" do
      :sys.replace_state(Lights, &%{&1 | seq: :broken})

      log =
        capture_log(fn ->
          assert {:error, :not_running} = Lights.reload(File.read!(@fixture))
          wait_until(fn -> is_pid(Process.whereis(Lights)) end)
        end)

      assert log =~ "{:reload, :redacted}"
      refute log =~ @beacon_key
      refute log =~ "abcdefghijklmnop"
    end

    test "a pending or last {:reload, dump} message is redacted" do
      dump = File.read!(@fixture)
      call = {:"$gen_call", {self(), make_ref()}, {:reload, dump}}

      status =
        Lights.format_status(%{
          state: %{bulbs: %{}, inventory: :x, beacon_key: @beacon_key},
          message: call,
          queue: [call, {:reload, dump}],
          reason: {:badarg, [{Crypto, :key_bytes, [@beacon_key], []}]}
        })

      refute inspect(status) =~ @beacon_key
      assert {:"$gen_call", _, {:reload, :redacted}} = status.message
      assert {:badarg, [{Crypto, :key_bytes, 1, []}]} = status.reason
    end
  end

  describe "reports" do
    test "are attributed by node id, not by the relaying advertiser" do
      # Node 2's report relayed by node 3's bulb.
      inject_report(2, 5, [{1, :bool, true}], address: @mac3)

      wait_until(fn -> match?({:ok, %{dps: %{1 => true}}}, Lights.status("path light 2")) end)
      assert {:ok, %{dps: dps, last_event: nil}} = Lights.status("post spot 1")
      assert dps == %{}
    end

    test "only fresh sequence numbers are applied" do
      inject_report(2, 5, [{3, :value, 1}])
      assert_dp(2, 3, 1)

      # Replay (from another advertiser, past the radio's dedupe) and stale.
      inject_report(2, 5, [{3, :value, 2}], address: @mac3)
      inject_report(2, 4, [{3, :value, 3}])
      sentinel()
      assert_dp(2, 3, 1)

      inject_report(2, 6, [{3, :value, 4}])
      assert_dp(2, 3, 4)

      # More than 9 999 ahead is outside the window too.
      inject_report(2, 6 + 10_000, [{3, :value, 5}])
      sentinel()
      assert_dp(2, 3, 4)
    end

    test "freshness wraps at 65535" do
      inject_report(2, 65_530, [{3, :value, 1}])
      assert_dp(2, 3, 1)
      inject_report(2, 3, [{3, :value, 2}])
      assert_dp(2, 3, 2)
      inject_report(2, 65_535, [{3, :value, 3}])
      sentinel()
      assert_dp(2, 3, 2)
    end

    test "a bulb whose counter restarted is re-anchored after 3 in-order reports" do
      inject_report(2, 30_000, [{3, :value, 1}])
      assert_dp(2, 3, 1)

      inject_report(2, 10, [{3, :value, 2}])
      inject_report(2, 11, [{3, :value, 3}])
      # A repeat doesn't count.
      inject_report(2, 11, [{3, :value, 4}], address: @mac3)
      sentinel()
      assert_dp(2, 3, 1)

      inject_report(2, 12, [{3, :value, 5}])
      assert_dp(2, 3, 5)

      inject_report(2, 13, [{3, :value, 6}])
      assert_dp(2, 3, 6)
    end

    test "wrong keys, unknown nodes and junk are ignored" do
      inject_report(2, 5, [{3, :value, 1}], key: @other_key)
      inject_report(9, 5, [{3, :value, 1}])
      FakeBluez.inject(%{address: @mac2, data: Carrier.ad_bytes(<<0::208>>), rssi: -40})
      sentinel()

      assert {:ok, %{dps: dps}} = Lights.status("path light 2")
      assert dps == %{}
    end

    test "a bulb's own beaconKey decrypts its reports" do
      inv = fixture(%{}) |> put_in(["bulbs", Access.at(1), "beaconKey"], @other_key)
      assert :ok = Lights.reload(inv)

      inject_report(3, 5, [{1, :bool, true}], key: @other_key)
      wait_until(fn -> match?({:ok, %{dps: %{1 => true}}}, Lights.status("post spot 1")) end)
    end

    test "a group list is exactly 8 slots; empty ones are skipped, not a terminator" do
      inject_report(2, 5, <<0xA3, 1, 0, 4, 0, 0, 0, 0, 0, 9, 9>>, sub_cmd: 2)
      assert_groups(2, [1, 4])

      inject_report(2, 6, <<0xA3, 0, 0, 0, 0, 0, 0, 0, 7, 9, 9>>, sub_cmd: 2)
      assert_groups(2, [7])

      inject_report(2, 7, <<0xA3, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10>>, sub_cmd: 2)
      assert_groups(2, [1, 2, 3, 4, 5, 6, 7, 8])
    end

    test "ping replies, reset acks and group lists" do
      inject_report(2, 5, <<0x01>>, sub_cmd: 2)

      wait_until(fn ->
        match?({:ok, %{last_event: :ping_reply}}, Lights.status("path light 2"))
      end)

      inject_report(2, 6, <<0x02>>, sub_cmd: 2)

      wait_until(fn ->
        match?({:ok, %{last_event: :reset_ack}}, Lights.status("path light 2"))
      end)

      inject_report(2, 7, <<0xA3, 1, 4, 0>>, sub_cmd: 2)

      wait_until(fn ->
        match?(
          {:ok, %{groups: [1, 4], last_event: {:group_list, [1, 4]}}},
          Lights.status("path light 2")
        )
      end)
    end
  end

  describe "radio restarts" do
    @tag :capture_log
    test "resubscribes after the Radio restarts and applies reports again" do
      stop_supervised!(Lights)
      start_supervised!({Lights, inventory: File.read!(@fixture), resubscribe_ms: 20})
      {:ok, _} = Lights.all()
      assert {:ok, %{subscribers: 1}} = Radio.status()

      old = Process.whereis(Radio)
      Process.exit(old, :kill)
      wait_until(fn -> match?(pid when is_pid(pid) and pid != old, Process.whereis(Radio)) end)
      wait_until(fn -> match?({:ok, %{subscribers: 1}}, Radio.status()) end)

      inject_report(2, 5, [{1, :bool, true}])
      wait_until(fn -> match?({:ok, %{dps: %{1 => true}}}, Lights.status("path light 2")) end)
    end

    test "starts without a Radio and subscribes once one appears" do
      stop_supervised!(Lights)
      stop_supervised!({Radio, 1})

      log =
        capture_log(fn ->
          start_supervised!({Lights, inventory: File.read!(@fixture), resubscribe_ms: 20})
          {:ok, _} = Lights.all()
          Process.sleep(100)
        end)

      # One line for the outage, not one per retry.
      assert length(String.split(log, "radio unavailable")) == 2

      start_supervised!(radio_spec())
      wait_until(fn -> match?({:ok, %{subscribers: 1}}, Radio.status()) end)
    end
  end

  describe "reload" do
    test "an older dump of the same mesh never pulls seq back", %{persisted: persisted} do
      assert set_sn("path light 2", on: true) == 100

      # The fixture still says seq 100; 100..131 are already reserved.
      assert :ok = Lights.reload(File.read!(@fixture))
      assert %{seq: 132} = last_persisted(persisted)

      assert set_sn("path light 2", on: false) == 132
    end

    test "a newer dump of the same mesh moves seq forward", %{persisted: persisted} do
      assert :ok = Lights.reload(fixture(%{"seq" => 5_000}))
      assert %{seq: 5_000} = last_persisted(persisted)

      assert set_sn("path light 2", on: true) == 5_000
    end

    test "the in-memory cursor wins across the 16-bit wrap" do
      # 65_530 is *behind* 100 in serial order: no change.
      assert :ok = Lights.reload(fixture(%{"seq" => 65_530}))
      assert {:ok, %{seq: 100}} = Lights.inventory()

      # A different mesh can start there; its cursor then wraps.
      mesh = %{"beaconKey" => @other_key}
      assert :ok = Lights.reload(fixture(Map.put(mesh, "seq", 65_530)))
      assert set_sn("path light 2", on: true) == 65_530

      # Cursor is now 26 (65_530 + 32, wrapped); 65_000 is behind it.
      assert :ok = Lights.reload(fixture(Map.put(mesh, "seq", 65_000)))
      assert {:ok, %{seq: 26}} = Lights.inventory()
    end

    test "a different mesh takes the dump's seq as-is", %{persisted: persisted} do
      assert set_sn("path light 2", on: true) == 100

      assert :ok = Lights.reload(fixture(%{"beaconKey" => @other_key, "seq" => 10}))
      assert %{seq: 10} = last_persisted(persisted)

      assert set_sn("path light 2", on: true) == 10
    end

    test "the same key spelled in another case is the same mesh" do
      assert set_sn("path light 2", on: true) == 100
      assert :ok = Lights.reload(fixture(%{"beaconKey" => String.upcase(@beacon_key)}))
      assert {:ok, %Inventory{seq: 132}} = Lights.inventory()
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────

  defp radio_spec(opts \\ []) do
    {Radio,
     [
       adapter_index: 1,
       retry_ms: 20,
       bluez_radio: FakeBluez.Radio,
       mgmt: FakeBluez.Mgmt,
       rebus: FakeBluez.Rebus,
       dbus: FakeBluez.DBus,
       receiver: FakeBluez.Receiver
     ] ++ opts}
  end

  defp radio_ready?, do: match?({:ok, %{ready: true}}, Radio.status())

  # on_persist backed by ETS; `fail_persist/2` makes it return (or raise)
  # something other than :ok.
  defp persist_to(table) do
    fn inv ->
      case :ets.lookup(table, :fail) do
        [{:fail, :raise}] ->
          raise "disk on fire"

        [{:fail, result}] ->
          result

        [] ->
          :ets.insert(table, {:inv, inv})
          :ets.update_counter(table, :writes, 1)
          :ok
      end
    end
  end

  defp fail_persist(table, nil), do: :ets.delete(table, :fail)
  defp fail_persist(table, result), do: :ets.insert(table, {:fail, result})

  defp writes(table), do: :ets.lookup_element(table, :writes, 2)
  defp last_persisted(table), do: :ets.lookup_element(table, :inv, 2)

  defp too_long_dps, do: [on: true, mode: :colour, colour: {1, 2, 3}, brightness: 500, temp: 1]

  # A device→phone report from `node` with sequence number `sn`.
  defp inject_report(node, sn, payload, opts \\ []) do
    payload =
      case payload do
        bin when is_binary(bin) ->
          bin

        dps ->
          {:ok, tlv} = Dp.encode(dps)
          tlv
      end

    key = Keyword.get(opts, :key, @beacon_key)
    sub_cmd = Keyword.get(opts, :sub_cmd, 7)
    frame = P2.build(1, sub_cmd, node, 0x8001, sn, payload, key, key)

    FakeBluez.inject(%{
      address: Keyword.get(opts, :address, @mac2),
      data: Carrier.ad_bytes(frame),
      rssi: -40
    })
  end

  # Reports reach Lights in injection order, so once a later report for
  # node 3 has been applied, every earlier one has been handled.
  defp sentinel do
    n = Process.get(:sentinel_sn, 0) + 1
    Process.put(:sentinel_sn, n)
    inject_report(3, n, [{4, :value, n}], address: @mac3)
    wait_until(fn -> match?({:ok, %{dps: %{4 => ^n}}}, Lights.status("post spot 1")) end)
  end

  defp assert_groups(2, ids) do
    wait_until(fn ->
      match?(
        {:ok, %{groups: ^ids, last_event: {:group_list, ^ids}}},
        Lights.status("path light 2")
      )
    end)
  end

  defp assert_dp(2, dp, value) do
    wait_until(fn -> match?({:ok, %{dps: %{^dp => ^value}}}, Lights.status("path light 2")) end)
  end

  defp fixture(overrides) do
    @fixture |> File.read!() |> Jason.decode!() |> Map.merge(overrides)
  end

  # Runs a command that should advertise, returns the SN on air and clears
  # the radio so the next send goes on air at once.
  defp sent_sn(fun) do
    before = length(advertises())
    assert :ok = fun.()
    wait_until(fn -> length(advertises()) > before end)
    :ok = Radio.stop_tx()
    advertises() |> List.last() |> frame_sn()
  end

  defp set_sn(who, dps), do: sent_sn(fn -> Lights.set(who, dps) end)

  # Ends the advert on air as its timer would, and waits for the next one.
  defp finish_tx do
    before = length(advertises())
    %{tx_current: %{token: token}} = :sys.get_state(Radio)
    send(Process.whereis(Radio), {:tx_done, token})
    wait_until(fn -> length(advertises()) > before end)
  end

  # Whether `frame` unmasks with `mask` (the frame CRC holds) and its
  # payload then decrypts with `key` (the payload CRC holds).
  defp masked_with?(frame, mask, key) do
    <<hdr, head::binary-7, payload_crc, masked::binary-16, crc>> = frame
    cipher = :crypto.exor(masked, Crypto.key_bytes(mask))
    payload = Crypto.xxtea_decrypt(cipher, Crypto.key_bytes(key))

    Crypto.crc8(<<Bitwise.band(hdr, 0xFC)>> <> head <> <<payload_crc>> <> cipher) == crc and
      Crypto.crc8(payload) == payload_crc
  end

  defp frame_sn(ad) do
    [<<_hdr, _src::binary-2, _dst::binary-2, sn::16-big, _::binary>>] = Carrier.frames(ad)
    sn
  end

  defp advertises, do: for({:advertise, data, _opts} <- FakeBluez.calls(), do: data)

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) > deadline -> flunk("condition not met in time")
      true -> Process.sleep(10) && do_wait(fun, deadline)
    end
  end
end
