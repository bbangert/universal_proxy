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
    Radio,
    Seq
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
  # max_lease of the random-operations runs.
  @random_max_lease 8

  setup do
    FakeBluez.ensure_started()
    FakeBluez.reset()

    start_supervised!(radio_spec())

    persisted = :ets.new(:lights_persist, [:public, :set])
    :ets.insert(persisted, [{:writes, 0}, {:tightens, 0}, {:now, 0}])

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
    # Only a MAC-shaped string is looked up as a MAC: hex inside other text
    # is not pulled out and matched.
    assert {:error, :unknown_bulb} = Lights.status("xx dc23533fcd62")
  end

  test "a nil identifier does not resolve to an unlabelled bulb" do
    dump =
      @fixture
      |> File.read!()
      |> Jason.decode!()
      |> update_in(["bulbs", Access.at(0)], &Map.delete(&1, "label"))

    assert :ok = Lights.reload(dump)
    assert {:ok, %{label: nil}} = Lights.status("DC23530FB34A")
    assert {:error, :unknown_bulb} = Lights.status(nil)
    assert {:error, :unknown_bulb} = Lights.reset(nil)
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

    test "a lease used up within the interval is followed by a max lease", %{
      persisted: persisted
    } do
      sns = for i <- 1..33, do: set_sn("path light 2", brightness: 10 + i)

      assert sns == Enum.to_list(100..132)
      assert writes(persisted) == 2
      assert %{seq: 732} = last_persisted(persisted)
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

      start_supervised!(
        {Lights, inventory: loader(persisted), radio: Radio, on_persist: persist_to(persisted)}
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

      # Radio up but not ready (its lease ended and can't be re-taken):
      # refused before it reaches Mgmt.
      start_supervised!(radio_spec())
      wait_until(&radio_ready?/0)
      holder = start_supervised!({Task, fn -> Process.sleep(:infinity) end})
      FakeBluez.fail(:acquire, {:held_by, holder})
      :ok = FakeBluez.end_lease()
      wait_until(fn -> not radio_ready?() end)

      assert {:error, :not_ready} = Lights.set("path light 2", on: true)
      assert {:error, :not_ready} = Lights.set("path light 2", on: true)
      FakeBluez.succeed(:acquire)

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
    test "an advertise that loses Mgmt or the lease keeps its number used" do
      for {reason, n} <- Enum.with_index([:lease_expired, :not_lease_holder, :not_running]) do
        wait_until(&radio_ready?/0)
        FakeBluez.fail(:advertise, reason)
        assert {:error, {:uncertain, ^reason}} = Lights.set("path light 2", on: true)
        FakeBluez.succeed(:advertise)

        # 100 + 2n may have gone on air: the next command must not reuse it.
        wait_until(&radio_ready?/0)
        assert set_sn("path light 2", on: false) == 100 + 2 * n + 1
      end
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

      # The fixture still says seq 100; 100..131 are leased. The rest of the
      # lease stays usable and the persisted lease end doesn't move back.
      assert :ok = Lights.reload(File.read!(@fixture))
      assert %{seq: 132} = last_persisted(persisted)
      assert writes(persisted) == 2

      assert set_sn("path light 2", on: false) == 101
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

  describe "sequence leases" do
    test "sends within one lease persist once", %{persisted: persisted} do
      restart_lights(persisted, min_lease: 25)

      sns =
        for _ <- 1..25 do
          tick(persisted, 1_000)
          set_sn("path light 2", on: true)
        end

      assert sns == Enum.to_list(100..124)
      assert writes(persisted) == 1
      assert persisted_seq(persisted) == 125
    end

    test "the lease follows the send rate, clamped to min and max", %{persisted: persisted} do
      restart_lights(persisted, min_lease: 2, max_lease: 12)

      # The first lease is min_lease.
      assert send_n(2) == [100, 101]
      assert persisted_seq(persisted) == 102

      # 2 used in 60 s: 2 / 60 s × 60 s × 1.5 = 3.
      tick(persisted, 60_000)
      assert send_n(3) == [102, 103, 104]
      assert persisted_seq(persisted) == 105

      # 3 in 60 s: 4.5, rounded up.
      tick(persisted, 60_000)
      assert send_n(5) == Enum.to_list(105..109)
      assert persisted_seq(persisted) == 110

      # 5 in 30 s: used up before the interval, so max_lease at once.
      tick(persisted, 30_000)
      assert send_n(12) == Enum.to_list(110..121)
      assert persisted_seq(persisted) == 122

      # 12 in 60 s wants 18: clamped to max_lease.
      tick(persisted, 60_000)
      assert send_n(12) == Enum.to_list(122..133)
      assert persisted_seq(persisted) == 134

      # 12 in an hour wants 1: clamped to min_lease.
      tick(persisted, 3_600_000)
      assert send_n(1) == [134]
      assert persisted_seq(persisted) == 136

      assert writes(persisted) == 6
    end

    test "a burst past max_lease persists early and never uses an unpersisted number", %{
      persisted: persisted
    } do
      restart_lights(persisted, min_lease: 2, max_lease: 5)

      # The clock never moves: every lease runs out inside the interval.
      for _ <- 1..17 do
        sn = set_sn("path light 2", on: true)
        assert Seq.ahead?(sn, persisted_seq(persisted))
      end

      # 2 (first), then max_lease each time: 2 + 5 + 5 + 5 covers 17.
      assert writes(persisted) == 4
      assert persisted_seq(persisted) == 117
      assert Enum.map(advertises(), &frame_sn/1) == Enum.to_list(100..116)
    end

    @tag :capture_log
    test "a failed lease persist sends nothing and is retried", %{persisted: persisted} do
      restart_lights(persisted, min_lease: 2, max_lease: 5)
      assert send_n(2) == [100, 101]

      fail_persist(persisted, {:error, :enospc})
      assert {:error, :persist_failed} = Lights.set("path light 2", on: true)
      assert {:error, :persist_failed} = Lights.ping("path light 2")
      assert persisted_seq(persisted) == 102
      assert length(advertises()) == 2

      # The retry leases from where the failed one would have, no gap.
      fail_persist(persisted, nil)
      assert send_n(1) == [102]
      assert persisted_seq(persisted) == 107
      assert writes(persisted) == 2
    end

    @tag :capture_log
    test "a retry after a persist that landed anyway never proposes an end behind it", %{
      persisted: persisted
    } do
      restart_lights(persisted,
        on_persist: store_persist(persisted),
        min_lease: 2,
        max_lease: 12
      )

      assert send_n(2) == [100, 101]
      assert persisted_seq(persisted) == 102

      # Used up inside the interval, so this attempt is a max lease (114).
      # It is written, but the sync fails.
      tick(persisted, 30_000)
      fail_persist(persisted, {:written, {:error, :sync_failed}})
      assert {:error, :persist_failed} = Lights.set("path light 2", on: true)
      assert persisted_seq(persisted) == 114
      fail_persist(persisted, nil)

      # Past the interval the rate wants only min_lease (104), behind what
      # the store holds: the retry still proposes 114.
      tick(persisted, 60_000)
      assert send_n(12) == Enum.to_list(102..113)
      assert persisted_seq(persisted) == 114

      # A reload of the same mesh covers a landed attempt too.
      tick(persisted, 30_000)
      fail_persist(persisted, {:written, {:error, :sync_failed}})
      assert {:error, :persist_failed} = Lights.set("path light 2", on: true)
      fail_persist(persisted, nil)
      attempted = persisted_seq(persisted)
      assert attempted > 114

      assert :ok = Lights.reload(File.read!(@fixture))
      assert persisted_seq(persisted) == attempted
      assert send_n(1) == [114]
    end

    test "a crash after a refused first number jumps at most max_lease + 1", %{
      persisted: persisted
    } do
      restart_lights(persisted, min_lease: 5, max_lease: 5)
      assert send_n(5) == Enum.to_list(100..104)

      # A new lease (105..109, persisted 110) whose first number is refused
      # and given back: 104 is still the last number on air.
      capture_log(fn ->
        FakeBluez.fail(:advertise, :busy)
        assert {:error, {:advertise, :busy}} = Lights.set("path light 2", on: true)
        FakeBluez.succeed(:advertise)
      end)

      assert persisted_seq(persisted) == 110

      old = Process.whereis(Lights)
      Process.exit(old, :kill)
      wait_until(fn -> match?(pid when is_pid(pid) and pid != old, Process.whereis(Lights)) end)

      assert [110] = send_n(1)
      assert distance(104, 110) == 5 + 1
    end

    test "invalid options stop the start" do
      Process.flag(:trap_exit, true)

      for {opts, key} <- [
            {[persist_interval_ms: 0], :persist_interval_ms},
            {[persist_interval_ms: 1.5], :persist_interval_ms},
            {[max_lease: 0], :max_lease},
            {[max_lease: 900], :max_lease},
            {[max_lease: 600.0], :max_lease},
            {[min_lease: 0], :min_lease},
            {[min_lease: 50, max_lease: 40], :min_lease},
            {[on_tighten: fn _inv -> :ok end], :on_tighten},
            {[clock: :wall], :clock}
          ] do
        assert {:error, {:bad_option, ^key}} =
                 Lights.start_link([inventory: File.read!(@fixture), name: :lights_opts] ++ opts)
      end

      assert {:ok, pid} =
               Lights.start_link(
                 inventory: File.read!(@fixture),
                 name: :lights_opts,
                 min_lease: 899,
                 max_lease: 899,
                 persist_interval_ms: 1
               )

      GenServer.stop(pid)
    end

    test "the child spec leaves room for the tighten" do
      assert %{shutdown: 5_000, id: Lights} = Lights.child_spec([])
    end
  end

  describe "tighten on a clean stop" do
    test "persists the exact next number", %{persisted: persisted} do
      restart_lights(persisted, [])
      assert send_n(3) == [100, 101, 102]
      assert persisted_seq(persisted) == 132

      stop_supervised!(Lights)
      assert persisted_seq(persisted) == 103
      assert tightens(persisted) == 1

      start_lights(lights_opts(persisted, []))
      assert send_n(1) == [103]
    end

    @tag :capture_log
    test "a given-back number is the next one; an uncertain one stays used", %{
      persisted: persisted
    } do
      restart_lights(persisted, [])
      assert send_n(2) == [100, 101]

      # Refused before going on air: 102 is handed out again.
      FakeBluez.fail(:advertise, :busy)
      assert {:error, {:advertise, :busy}} = Lights.set("path light 2", on: true)
      FakeBluez.succeed(:advertise)

      stop_supervised!(Lights)
      assert persisted_seq(persisted) == 102

      start_lights(lights_opts(persisted, []))
      wait_until(&radio_ready?/0)

      # May have gone on air: 102 is used, and the tighten stays past it.
      FakeBluez.fail(:advertise, :lease_expired)
      assert {:error, {:uncertain, :lease_expired}} = Lights.set("path light 2", on: true)
      FakeBluez.succeed(:advertise)

      stop_supervised!(Lights)
      assert persisted_seq(persisted) == 103

      start_lights(lights_opts(persisted, []))
      wait_until(&radio_ready?/0)
      assert send_n(1) == [103]
    end

    @tag :capture_log
    test "a failed or refused tighten keeps the lease end", %{persisted: persisted} do
      restart_lights(persisted, [])
      assert send_n(1) == [100]

      :ets.insert(persisted, {:fail_tighten, {:error, :busy}})
      stop_supervised!(Lights)
      assert persisted_seq(persisted) == 132
      :ets.delete(persisted, :fail_tighten)

      # A store that moved on since the last persist refuses it.
      start_lights(lights_opts(persisted, []))
      assert send_n(1) == [132]
      :ets.insert(persisted, {:inv, %{last_persisted(persisted) | seq: 500}})
      stop_supervised!(Lights)
      assert persisted_seq(persisted) == 500

      # Raising is a failure too.
      start_lights(lights_opts(persisted, on_tighten: fn _inv, _leased -> raise "no" end))
      assert send_n(1) == [500]
      stop_supervised!(Lights)
      assert persisted_seq(persisted) == 532
      assert tightens(persisted) == 0
    end

    test "nothing is tightened without on_tighten, or with nothing left", %{
      persisted: persisted
    } do
      restart_lights(persisted, on_tighten: nil)
      assert send_n(1) == [100]
      stop_supervised!(Lights)
      assert persisted_seq(persisted) == 132

      # Started and stopped without sending: the lease end is the cursor.
      start_lights(lights_opts(persisted, []))
      stop_supervised!(Lights)
      assert persisted_seq(persisted) == 132
      assert tightens(persisted) == 0
    end

    @tag :capture_log
    test "a crash doesn't tighten", %{persisted: persisted} do
      restart_lights(persisted, [])
      assert send_n(1) == [100]

      :sys.replace_state(Lights, &%{&1 | seq: :broken})
      old = Process.whereis(Lights)
      assert {:error, :not_running} = Lights.reload(File.read!(@fixture))
      wait_until(fn -> match?(pid when is_pid(pid) and pid != old, Process.whereis(Lights)) end)

      assert tightens(persisted) == 0
      assert persisted_seq(persisted) == 132
      assert send_n(1) == [132]
    end

    @tag :capture_log
    test "a tighten that hangs is cut short inside the shutdown", %{persisted: persisted} do
      restart_lights(persisted, [])
      assert send_n(1) == [100]

      :ets.insert(persisted, {:fail_tighten, :hang})
      {elapsed_us, :ok} = :timer.tc(fn -> stop_supervised!(Lights) end)

      assert elapsed_us < 5_000_000
      assert persisted_seq(persisted) == 132
    end
  end

  describe "reload with a lease" do
    test "persists at once and re-bases the lease", %{persisted: persisted} do
      restart_lights(persisted, min_lease: 2, max_lease: 10)
      assert send_n(3) == [100, 101, 102]
      # 2, then 10 at once (used up inside the interval).
      assert persisted_seq(persisted) == 112

      assert :ok = Lights.reload(File.read!(@fixture))
      assert writes(persisted) == 3
      assert persisted_seq(persisted) == 112

      # The rest of the lease is still used; the next lease starts over at
      # min_lease instead of following the burst before the reload.
      assert send_n(10) == Enum.to_list(103..112)
      assert persisted_seq(persisted) == 114

      # A newer dump moves past the lease: it starts again from there.
      assert :ok = Lights.reload(fixture(%{"seq" => 5_000}))
      assert persisted_seq(persisted) == 5_000
      assert send_n(1) == [5_000]
      assert persisted_seq(persisted) == 5_002
    end
  end

  describe "sequence safety under random operations" do
    @describetag :capture_log

    for seed <- [11, 23] do
      test "seed #{seed}: the persisted cursor stays past every number used", %{
        persisted: persisted
      } do
        random_run(persisted, unquote(seed), 120)
      end
    end
  end

  # Random sends, failures, clock steps, crashes and clean restarts across
  # the 16-bit wrap. `last` is the newest number that may have gone on air
  # (sent or uncertain). After every step the persisted seq must be ahead
  # of it; every new number must be ahead of it, by exactly 1 unless a
  # crash skipped the rest of a lease (at most max_lease numbers).
  defp random_run(persisted, seed, steps) do
    :rand.seed(:exsss, {seed, seed, seed})
    {:ok, inv} = Inventory.decode(fixture(%{"seq" => 65_500}))
    :ets.insert(persisted, {:inv, inv})

    opts =
      lights_opts(persisted,
        on_persist: store_persist(persisted),
        min_lease: 2,
        max_lease: @random_max_lease,
        persist_interval_ms: 10_000
      )

    stop_supervised!(Lights)
    start_lights(opts)

    Enum.reduce(1..steps, %{last: nil, may_skip?: false}, fn step, acc ->
      acc = random_op(:rand.uniform(9), opts, persisted, acc)
      where = "seed #{seed} step #{step}"

      if acc.last,
        do: assert(Seq.ahead?(acc.last, persisted_seq(persisted)), where)

      acc
    end)
  end

  # A persist may fail outright or after its write landed (a failed sync).
  # Without an injected failure the send must go out: a store refusing a
  # retry as :seq_behind would block it.
  defp random_op(n, _opts, persisted, acc) when n <= 4 do
    injected? =
      case :rand.uniform(6) do
        1 -> fail_persist(persisted, {:error, :busy})
        2 -> fail_persist(persisted, {:written, {:error, :sync_failed}})
        _ -> false
      end

    result = attempt(fn -> Lights.set("path light 2", on: true) end)
    fail_persist(persisted, nil)

    case result do
      {:sent, sn} -> used(acc, sn)
      {:error, :persist_failed} when injected? != false -> acc
    end
  end

  defp random_op(5, _opts, _persisted, acc) do
    FakeBluez.fail(:advertise, :busy)
    assert {:error, {:advertise, :busy}} = Lights.set("path light 2", on: true)
    FakeBluez.succeed(:advertise)
    acc
  end

  defp random_op(6, _opts, _persisted, acc) do
    wait_until(&radio_ready?/0)
    sn = Seq.next(:sys.get_state(Lights).seq)
    FakeBluez.fail(:advertise, :lease_expired)
    assert {:error, {:uncertain, :lease_expired}} = Lights.set("path light 2", on: true)
    FakeBluez.succeed(:advertise)
    wait_until(&radio_ready?/0)
    used(acc, sn)
  end

  defp random_op(7, _opts, persisted, acc) do
    tick(persisted, :rand.uniform(15_000))
    acc
  end

  defp random_op(8, _opts, _persisted, acc) do
    old = Process.whereis(Lights)
    Process.exit(old, :kill)
    wait_until(fn -> match?(pid when is_pid(pid) and pid != old, Process.whereis(Lights)) end)
    {:ok, _} = Lights.all()
    %{acc | may_skip?: true}
  end

  # A clean stop tightens to the cursor unless the store refuses it (a
  # failed persist's write landed since); then the restart resumes at the
  # stored lease end like a crash.
  defp random_op(9, opts, persisted, acc) do
    next = Seq.next(:sys.get_state(Lights).seq)
    stop_supervised!(Lights)
    start_lights(opts)
    if persisted_seq(persisted) == next, do: acc, else: %{acc | may_skip?: true}
  end

  defp used(%{last: nil} = acc, sn), do: %{acc | last: sn, may_skip?: false}

  # A restart at a lease end jumps at most max_lease + 1 past the last
  # number that may have gone on air (the lease's first can be given back).
  defp used(%{last: last, may_skip?: may_skip?} = acc, sn) do
    gap = distance(last, sn)

    if may_skip?,
      do: assert(gap in 1..(@random_max_lease + 1), "gap #{gap} after a restart at a lease end"),
      else: assert(gap == 1, "gap #{gap} without a restart at a lease end")

    %{acc | last: sn, may_skip?: false}
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

  # on_persist with the host store's rules: a seq behind the stored one is
  # refused (:seq_behind), and {:written, result} stores the inventory and
  # then returns `result`, like a DETS insert whose sync fails.
  defp store_persist(table) do
    fn inv ->
      stored = with [{:inv, stored}] <- :ets.lookup(table, :inv), do: stored.seq

      cond do
        is_integer(stored) and inv.seq != stored and not Seq.ahead?(stored, inv.seq) ->
          {:error, :seq_behind}

        true ->
          case :ets.lookup(table, :fail) do
            [{:fail, {:written, result}}] ->
              :ets.insert(table, {:inv, inv})
              result

            [{:fail, result}] ->
              result

            [] ->
              :ets.insert(table, {:inv, inv})
              :ets.update_counter(table, :writes, 1)
              :ok
          end
      end
    end
  end

  # on_tighten backed by the same table, with the compare-and-set a host
  # store needs: applied only while the stored seq is still `leased`.
  defp tighten_to(table) do
    fn inv, leased ->
      case {:ets.lookup(table, :fail_tighten), :ets.lookup(table, :inv)} do
        {[{:fail_tighten, :hang}], _} ->
          Process.sleep(:infinity)

        {[{:fail_tighten, result}], _} ->
          result

        {[], [{:inv, %{seq: ^leased}}]} ->
          :ets.insert(table, {:inv, inv})
          :ets.update_counter(table, :tightens, 1)
          :ok

        _moved ->
          {:error, :seq_moved}
      end
    end
  end

  defp loader(table) do
    fn ->
      case :ets.lookup(table, :inv) do
        [{:inv, inv}] -> {:ok, inv}
        [] -> {:ok, File.read!(@fixture)}
      end
    end
  end

  # Lights reading and writing `table`, with its clock in `table` too
  # (`tick/2`).
  defp lights_opts(table, opts) do
    Keyword.merge(
      [
        inventory: loader(table),
        radio: Radio,
        on_persist: persist_to(table),
        on_tighten: tighten_to(table),
        clock: fn -> :ets.lookup_element(table, :now, 2) end
      ],
      opts
    )
  end

  defp restart_lights(table, opts) do
    stop_supervised!(Lights)
    start_lights(lights_opts(table, opts))
  end

  defp start_lights(opts) do
    start_supervised!({Lights, opts})
    {:ok, _} = Lights.all()
  end

  defp tick(table, ms), do: :ets.update_counter(table, :now, ms)
  defp tightens(table), do: :ets.lookup_element(table, :tightens, 2)
  defp persisted_seq(table), do: last_persisted(table).seq

  # Sends while the lease lasts: `n` SNs, all expected in order.
  defp send_n(n), do: for(_ <- 1..n//1, do: set_sn("path light 2", on: true))

  # A command's outcome: {:sent, sn} once its frame is on air, or the error.
  defp attempt(fun) do
    before = length(advertises())

    case fun.() do
      :ok ->
        wait_until(fn -> length(advertises()) > before end)
        :ok = Radio.stop_tx()
        {:sent, advertises() |> List.last() |> frame_sn()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp distance(a, b), do: Integer.mod(b - a, 65_536)

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
