defmodule UniversalProxy.Cec.VolumeLinkTest do
  # Each test runs its own unnamed link on its own PubSub.
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias UniversalProxy.Cec
  alias UniversalProxy.Cec.VolumeLink

  @dev "/dev/cec0"
  @key {"vc4-hdmi", nil, nil}

  setup context do
    pubsub = :"volume_link_test_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})
    test = self()

    adapters = [adapter(Map.get(context, :receiver, %{}))]
    outputs = [output(Map.get(context, :output, %{}))]
    echo? = Map.get(context, :echo, true)
    # The first `update_fails` writes fail, like Audio.update_config/2 with
    # the audio subsystem down.
    update_fails = :counters.new(1, [])
    :counters.put(update_fails, 1, Map.get(context, :update_fails, 0))
    task_sup = start_supervised!(Task.Supervisor)
    # The player process writes reach (nil: none running); tests swap it to
    # model a respawn.
    player = start_supervised!({Agent, fn -> Map.get(context, :player, :p1) end})

    opts = [
      name: nil,
      pubsub: pubsub,
      task_supervisor: task_sup,
      list_adapters: fn -> adapters end,
      list_outputs: fn -> outputs end,
      set_volume_external: fn key, external? ->
        send(test, {:external, key, external?})
        :ok
      end,
      # Like Audio.update_config_forwarded/2: the player a write reaches
      # echoes each value. Echoes go out before the test hears of the write,
      # so they reach the link ahead of anything the test sends in response.
      update_config: fn key, params ->
        current = Agent.get(player, & &1)

        if :counters.get(update_fails, 1) > 0 do
          :counters.sub(update_fails, 1, 1)
          send(test, {:update_config, key, params})
          {:error, :unavailable}
        else
          if echo? and current != nil do
            for {field, value} <- params, do: player_event(pubsub, key, field, value, current)
          end

          send(test, {:update_config, key, params})
          {:ok, current}
        end
      end,
      set_volume: fn dev, target, walk_opts ->
        send(test, {:walk_opts, walk_opts})
        cec(test, {:set_volume, dev, target})
      end,
      set_muted: &cec(test, {:set_muted, &1, &2}),
      audio_status: &cec(test, {:audio_status, &1}),
      power_status: &cec(test, {:power_status, &1}),
      poll_ms: 60_000,
      probe_ms: 60_000,
      settle_ms: 0,
      fail_unlink: Map.get(context, :fail_unlink, 3),
      echo_ttl_ms: Map.get(context, :echo_ttl_ms, 5_000),
      hotplug_grace_ms: Map.get(context, :hotplug_grace_ms, 60_000),
      default: true
    ]

    pid = start_supervised!({VolumeLink, opts})
    {:ok, pid: pid, pubsub: pubsub, player: player}
  end

  describe "linking" do
    test "links at start: external mode on, then the receiver's volume and mute adopted",
         %{pid: pid} do
      assert_receive {:external, @key, true}
      assert_receive {:update_config, @key, %{volume: 20, muted: false}}
      assert VolumeLink.links(pid) == %{@dev => @key}

      # The adoption's echoes never step the receiver.
      refute_receive {:cec, _, {:set_volume, _, _}}
      refute_receive {:cec, _, {:set_muted, _, _}}
    end

    @tag receiver: %{power: :unknown, volume: nil, updated_at: nil}
    test "probes a receiver whose power and volume are unknown, then links on its report",
         %{pid: pid, pubsub: pubsub} do
      reply(assert_cec({:power_status, @dev}), {:ok, :on})
      reply(assert_cec({:audio_status, @dev}), {:ok, %{volume: 30, muted: true}})
      refute_receive {:external, _, _}
      assert VolumeLink.links(pid) == %{}

      adapters(pubsub, [adapter(%{volume: 30, muted: true})])
      assert_receive {:external, @key, true}
      assert_receive {:update_config, @key, %{volume: 30, muted: true}}
    end

    @tag receiver: %{power: :standby, volume: nil, updated_at: nil}
    test "a receiver in standby isn't asked for its volume", %{pid: pid} do
      reply(assert_cec({:power_status, @dev}), {:ok, :standby})
      refute_receive {:cec, _, {:audio_status, _}}
      assert VolumeLink.links(pid) == %{}
    end

    test "standby unlinks", %{pubsub: pubsub} do
      assert_receive {:external, @key, true}
      adapters(pubsub, [adapter(%{power: :standby})])
      assert_receive {:external, @key, false}
    end

    test "a cleared receiver record keeps the link", %{pid: pid, pubsub: pubsub} do
      assert_receive {:external, @key, true}
      adapters(pubsub, [adapter(%{power: :unknown, volume: nil, muted: nil, updated_at: nil})])
      refute_receive {:external, @key, false}
      assert VolumeLink.links(pid) == %{@dev => @key}
    end

    test "a stopped adapter unlinks", %{pubsub: pubsub} do
      assert_receive {:external, @key, true}
      adapters(pubsub, [Map.put(adapter(), :running?, false)])
      assert_receive {:external, @key, false}
    end

    test "an HDMI hotplug's reconfigure doesn't unlink", %{pid: pid, pubsub: pubsub} do
      assert_receive {:external, @key, true}
      cleared = %{power: :unknown, volume: nil, muted: nil, updated_at: nil}

      # The adapter loses its address and the receiver record...
      adapters(pubsub, [
        adapter(cleared) |> Map.put(:configured?, false) |> Map.put(:receiver_presence, :unknown)
      ])

      # ...is asked nothing meanwhile...
      poll_now(pid)
      refute_receive {:cec, _, _}

      # ...reclaims it, polls for the receiver, finds it.
      adapters(pubsub, [Map.put(adapter(cleared), :receiver_presence, :unknown)])
      poll_now(pid)
      refute_receive {:cec, _, _}
      adapters(pubsub, [adapter(cleared)])

      poll_now(pid)
      reply(assert_cec({:power_status, @dev}), {:ok, :on})
      reply(assert_cec({:audio_status, @dev}), {:ok, %{volume: 20, muted: false}})
      idle(pid)

      refute_receive {:external, @key, false}
      assert VolumeLink.links(pid) == %{@dev => @key}
    end

    test "a receiver absent right after a hotplug is waited for, and so are requests",
         %{pid: pid, pubsub: pubsub} do
      assert_receive {:external, @key, true}
      assert_receive {:update_config, @key, _}

      adapters(pubsub, [Map.put(adapter(), :configured?, false)])
      adapters(pubsub, [Map.put(adapter(), :receiver_presence, :unknown)])

      # The adapter's own poll finds the receiver still renegotiating.
      adapters(pubsub, [Map.put(adapter(), :receiver_presence, :absent)])
      player_event(pubsub, @key, :volume, 35)

      for _ <- 1..5, do: poll_now(pid)
      idle(pid)
      refute_receive {:cec, _, _}
      refute_receive {:external, @key, false}
      refute_receive {:update_config, _, _}

      # Found again: the held request runs.
      adapters(pubsub, [adapter()])
      reply(assert_cec({:set_volume, @dev, 35}), {:ok, %{volume: 35, muted: false}})
      idle(pid)
      refute_receive {:external, @key, false}
      assert VolumeLink.links(pid) == %{@dev => @key}
    end

    @tag hotplug_grace_ms: 0
    test "a receiver still absent after the hotplug grace unlinks through the failure count",
         %{pubsub: pubsub, pid: pid} do
      assert_receive {:external, @key, true}

      adapters(pubsub, [Map.put(adapter(), :configured?, false)])
      adapters(pubsub, [Map.put(adapter(), :receiver_presence, :absent)])

      poll_now(pid)
      poll_now(pid)
      refute_receive {:external, @key, false}
      poll_now(pid)
      assert_receive {:external, @key, false}
    end

    test "a receiver that stays absent unlinks through the failure count",
         %{pid: pid, pubsub: pubsub} do
      assert_receive {:external, @key, true}
      assert_receive {:update_config, @key, _}

      # Absent: the record now describes the TV, which isn't followed.
      absent = adapter(%{volume: 70}) |> Map.put(:receiver_presence, :absent)
      adapters(pubsub, [absent])
      refute_receive {:update_config, _, _}

      poll_now(pid)
      poll_now(pid)
      refute_receive {:cec, _, _}
      refute_receive {:external, @key, false}

      poll_now(pid)
      assert_receive {:external, @key, false}
    end

    test "turning the output's cec_volume off unlinks it, on links it again", %{pubsub: pubsub} do
      assert_receive {:external, @key, true}
      assert_receive {:update_config, @key, _}

      state(pubsub, %{cec_volume: false})
      assert_receive {:external, @key, false}

      state(pubsub, %{cec_volume: true})
      assert_receive {:external, @key, true}
      assert_receive {:update_config, @key, %{volume: 20, muted: false}}
    end

    @tag output: %{cec_volume: false}
    test "an output with cec_volume off never links", %{pid: pid} do
      refute_receive {:external, _, _}
      assert VolumeLink.links(pid) == %{}
    end

    @tag output: %{cec_volume: false, volume_external: true}
    test "at start, an output left in external mode that doesn't link is handed back" do
      assert_receive {:external, @key, false}
    end

    test "a removed output unlinks; re-added, it links again", %{pubsub: pubsub} do
      assert_receive {:external, @key, true}

      Phoenix.PubSub.broadcast(pubsub, "sendspin:output_removed", {
        :sendspin_output_removed,
        %{key: @key}
      })

      assert_receive {:external, @key, false}

      Phoenix.PubSub.broadcast(pubsub, "sendspin:output_added", {
        :sendspin_output_added,
        output()
      })

      assert_receive {:external, @key, true}
    end

    test "an output re-added while linked (audio restart) is put back in external mode",
         %{pubsub: pubsub} do
      assert_receive {:external, @key, true}

      Phoenix.PubSub.broadcast(pubsub, "sendspin:output_added", {
        :sendspin_output_added,
        output(%{volume: 20})
      })

      assert_receive {:external, @key, true}
    end

    @tag output: %{card_index: 2}
    test "an output on another card doesn't link", %{pid: pid} do
      refute_receive {:external, _, _}
      assert VolumeLink.links(pid) == %{}
    end
  end

  describe "output to receiver" do
    setup :linked

    test "a player volume steps the receiver; nothing is written back when it lands",
         %{pubsub: pubsub} do
      player_event(pubsub, @key, :volume, 35)
      reply(assert_cec({:set_volume, @dev, 35}), {:ok, %{volume: 35, muted: false}})
      refute_receive {:update_config, _, _}
      refute_receive {:cec, _, _}
    end

    @tag output: %{cec_volume_max: 30}
    test "the ceiling caps the step and the capped value is written back", %{pubsub: pubsub} do
      player_event(pubsub, @key, :volume, 50)
      reply(assert_cec({:set_volume, @dev, 30}), {:ok, %{volume: 30, muted: false}})
      assert_receive {:update_config, @key, %{volume: 30}}
      refute_receive {:cec, _, _}
    end

    @tag output: %{cec_volume_max: 20}
    test "a request above the ceiling with the receiver already there is only written back",
         %{pubsub: pubsub} do
      player_event(pubsub, @key, :volume, 50)
      assert_receive {:update_config, @key, %{volume: 20}}
      refute_receive {:cec, _, _}
    end

    test "values arriving during a run are coalesced, latest wins", %{pubsub: pubsub} do
      player_event(pubsub, @key, :volume, 35)
      task = assert_cec({:set_volume, @dev, 35})

      player_event(pubsub, @key, :volume, 40)
      player_event(pubsub, @key, :volume, 45)
      refute_receive {:cec, _, _}

      reply(task, {:ok, %{volume: 35, muted: false}})
      reply(assert_cec({:set_volume, @dev, 45}), {:ok, %{volume: 45, muted: false}})
      refute_receive {:update_config, _, _}
      refute_receive {:cec, _, _}
    end

    test "returning to the receiver's volume during a run steps back", %{pubsub: pubsub} do
      player_event(pubsub, @key, :volume, 35)
      task = assert_cec({:set_volume, @dev, 35})
      player_event(pubsub, @key, :volume, 20)
      reply(task, {:ok, %{volume: 35, muted: false}})
      reply(assert_cec({:set_volume, @dev, 20}), {:ok, %{volume: 20, muted: false}})
      refute_receive {:update_config, _, _}
    end

    test "a stall is written back as the receiver's volume", %{pubsub: pubsub} do
      player_event(pubsub, @key, :volume, 60)

      reply(
        assert_cec({:set_volume, @dev, 60}),
        {:error, {:no_progress, %{volume: 52, muted: false}}}
      )

      assert_receive {:update_config, @key, %{volume: 52}}
      refute_receive {:cec, _, _}
    end

    test "a failed run writes back the last known receiver volume", %{pubsub: pubsub} do
      player_event(pubsub, @key, :volume, 60)
      reply(assert_cec({:set_volume, @dev, 60}), {:error, :timeout})
      assert_receive {:update_config, @key, %{volume: 20}}
      refute_receive {:cec, _, _}
    end

    test "a crashed run writes back the last known receiver volume", %{pubsub: pubsub} do
      player_event(pubsub, @key, :volume, 60)
      reply(assert_cec({:set_volume, @dev, 60}), :raise)
      # The crash report is logged first, which is slow under a loaded suite.
      assert_receive {:update_config, @key, %{volume: 20}}, 1_000
      refute_receive {:cec, _, _}
    end

    test "mute toggles the receiver", %{pubsub: pubsub} do
      player_event(pubsub, @key, :muted, true)
      reply(assert_cec({:set_muted, @dev, true}), {:ok, %{volume: 20, muted: true}})
      refute_receive {:update_config, _, _}
      refute_receive {:cec, _, _}
    end

    test "a mute that didn't take is written back", %{pubsub: pubsub} do
      player_event(pubsub, @key, :muted, true)
      reply(assert_cec({:set_muted, @dev, true}), {:ok, %{volume: 20, muted: false}})
      assert_receive {:update_config, @key, %{muted: false}}
      refute_receive {:cec, _, _}
    end

    test "mute and volume requested together run mute first, then the walk",
         %{pubsub: pubsub} do
      player_event(pubsub, @key, :volume, 35)
      task = assert_cec({:set_volume, @dev, 35})
      player_event(pubsub, @key, :muted, true)
      player_event(pubsub, @key, :volume, 40)
      reply(task, {:ok, %{volume: 35, muted: false}})

      reply(assert_cec({:set_muted, @dev, true}), {:ok, %{volume: 35, muted: true}})
      reply(assert_cec({:set_volume, @dev, 40}), {:ok, %{volume: 40, muted: true}})
      refute_receive {:update_config, _, _}
    end

    test "repeats of the shown value and the echoes of writes don't step", %{pubsub: pubsub} do
      player_event(pubsub, @key, :volume, 20)
      player_event(pubsub, @key, :muted, false)
      refute_receive {:cec, _, _}

      player_event(pubsub, @key, :volume, 60)
      reply(assert_cec({:set_volume, @dev, 60}), {:error, {:no_progress, %{volume: 52}}})
      assert_receive {:update_config, @key, %{volume: 52}}
      refute_receive {:cec, _, _}
    end

    @tag echo: false
    test "an echo arriving after a newer request isn't taken for one, but is corrected",
         %{pubsub: pubsub} do
      player_event(pubsub, @key, :volume, 60)
      reply(assert_cec({:set_volume, @dev, 60}), {:error, {:no_progress, %{volume: 52}}})
      assert_receive {:update_config, @key, %{volume: 52}}

      # The player took 45 from the server, then our 52: it shows 52 now.
      player_event(pubsub, @key, :volume, 45)
      player_event(pubsub, @key, :volume, 52)
      reply(assert_cec({:set_volume, @dev, 45}), {:ok, %{volume: 45, muted: false}})
      assert_receive {:update_config, @key, %{volume: 45}}
      refute_receive {:cec, _, _}
    end

    @tag echo: false
    test "a late echo while idle is corrected at once", %{pubsub: pubsub} do
      player_event(pubsub, @key, :volume, 60)
      reply(assert_cec({:set_volume, @dev, 60}), {:error, {:no_progress, %{volume: 52}}})
      assert_receive {:update_config, @key, %{volume: 52}}

      player_event(pubsub, @key, :volume, 45)
      reply(assert_cec({:set_volume, @dev, 45}), {:ok, %{volume: 45, muted: false}})
      refute_receive {:update_config, _, _}

      player_event(pubsub, @key, :volume, 52)
      assert_receive {:update_config, @key, %{volume: 45}}
      refute_receive {:cec, _, _}
    end

    test "turning the setting off stops the run; a relink doesn't pick it up",
         %{pubsub: pubsub} do
      player_event(pubsub, @key, :volume, 60)
      task = assert_cec({:set_volume, @dev, 60})
      ref = Process.monitor(task)

      state(pubsub, %{cec_volume: false})
      assert_receive {:external, @key, false}
      assert_receive {:DOWN, ^ref, :process, ^task, _}

      state(pubsub, %{cec_volume: true})
      assert_receive {:external, @key, true}
      assert_receive {:update_config, @key, %{volume: 20, muted: false}}
      refute_receive {:cec, _, _}
      refute_receive {:update_config, _, _}
    end

    test "a request back to the cached volume during a poll still runs against its readback",
         %{pid: pid, pubsub: pubsub} do
      poll_now(pid)
      reply(assert_cec({:power_status, @dev}), {:ok, :on})
      poll = assert_cec({:audio_status, @dev})

      player_event(pubsub, @key, :volume, 35)
      player_event(pubsub, @key, :volume, 20)

      # The knob moved meanwhile: the latest request (20) still wins.
      reply(poll, {:ok, %{volume: 30, muted: false}})
      reply(assert_cec({:set_volume, @dev, 20}), {:ok, %{volume: 20, muted: false}})
      refute_receive {:update_config, _, %{volume: 30}}
      refute_receive {:cec, _, _}
    end

    @tag update_fails: 1
    test "a failed write to the output is retried by the next sync", %{pid: pid} do
      # The adoption write failed (setup :linked saw it): nothing is shown yet.
      poll_now(pid)
      reply(assert_cec({:power_status, @dev}), {:ok, :on})
      reply(assert_cec({:audio_status, @dev}), {:ok, %{volume: 20, muted: false}})
      assert_receive {:update_config, @key, %{volume: 20, muted: false}}
    end

    test "a step-3 receiver settles on the nearest volume, written back; asking again doesn't re-run",
         %{pubsub: pubsub} do
      player_event(pubsub, @key, :volume, 25)
      assert_receive {:walk_opts, []}
      reply(assert_cec({:set_volume, @dev, 25}), {:ok, %{volume: 24, muted: false, step: 3}})
      assert_receive {:update_config, @key, %{volume: 24}}
      refute_receive {:cec, _, _}

      # 24 is as close to 25 as this receiver gets: shown back, not walked.
      player_event(pubsub, @key, :volume, 25)
      assert_receive {:update_config, @key, %{volume: 24}}
      refute_receive {:cec, _, _}
    end

    @tag output: %{cec_volume_max: 30}
    test "the ceiling is passed to the walk", %{pubsub: pubsub} do
      player_event(pubsub, @key, :volume, 50)
      assert_receive {:walk_opts, [max: 30]}
      reply(assert_cec({:set_volume, @dev, 30}), {:ok, %{volume: 30, muted: false, step: 1}})
    end

    test "the learned step is passed to the next walk, and forgotten on relink",
         %{pid: pid, pubsub: pubsub} do
      player_event(pubsub, @key, :volume, 35)
      assert_receive {:walk_opts, []}
      reply(assert_cec({:set_volume, @dev, 35}), {:ok, %{volume: 35, muted: false, step: 3}})
      idle(pid)

      player_event(pubsub, @key, :volume, 50)
      assert_receive {:walk_opts, [step: 3]}

      reply(
        assert_cec({:set_volume, @dev, 50}),
        {:error, {:no_progress, %{volume: 44, muted: false, step: 2}}}
      )

      assert_receive {:update_config, @key, %{volume: 44}}
      idle(pid)

      # A stall's result carries the step too.
      player_event(pubsub, @key, :volume, 30)
      assert_receive {:walk_opts, [step: 2]}
      reply(assert_cec({:set_volume, @dev, 30}), {:ok, %{volume: 30, muted: false, step: 2}})
      idle(pid)

      state(pubsub, %{cec_volume: false})
      assert_receive {:external, @key, false}
      state(pubsub, %{cec_volume: true})
      assert_receive {:external, @key, true}

      player_event(pubsub, @key, :volume, 40)
      assert_receive {:walk_opts, []}
    end

    @tag output: %{cec_volume_max: 26}
    test "a volume within half a step of the target but above the ceiling isn't reached",
         %{pid: pid, pubsub: pubsub} do
      player_event(pubsub, @key, :volume, 26)
      reply(assert_cec({:set_volume, @dev, 26}), {:ok, %{volume: 26, muted: false, step: 3}})
      idle(pid)

      # The knob takes it to 27, above the ceiling.
      poll_now(pid)
      reply(assert_cec({:power_status, @dev}), {:ok, :on})
      reply(assert_cec({:audio_status, @dev}), {:ok, %{volume: 27, muted: false}})
      assert_receive {:update_config, @key, %{volume: 27}}

      player_event(pubsub, @key, :volume, 30)
      assert_receive {:walk_opts, [step: 3, max: 26]}
      reply(assert_cec({:set_volume, @dev, 26}), {:ok, %{volume: 24, muted: false, step: 3}})
      assert_receive {:update_config, @key, %{volume: 24}}
    end

    test "unlinked outputs' volume events are ignored", %{pubsub: pubsub} do
      player_event(pubsub, {"other", nil, nil}, :volume, 70)
      refute_receive {:cec, _, _}
    end
  end

  describe "reaching the target" do
    setup :linked

    test "a press that clips to 0 or 100 isn't skipped as out of reach",
         %{pid: pid, pubsub: pubsub} do
      learn_step_3(pid, pubsub)

      knob(pid, 1)
      player_event(pubsub, @key, :volume, 0)
      reply(assert_cec({:set_volume, @dev, 0}), {:ok, %{volume: 0, muted: false, step: 3}})
      idle(pid)

      knob(pid, 99)
      player_event(pubsub, @key, :volume, 100)
      reply(assert_cec({:set_volume, @dev, 100}), {:ok, %{volume: 100, muted: false, step: 3}})
    end

    test "a target between two reachable volumes is reached at the nearer one",
         %{pid: pid, pubsub: pubsub} do
      learn_step_3(pid, pubsub)

      # 7 -> 6 (one step down: 4) wouldn't get closer.
      knob(pid, 7)
      player_event(pubsub, @key, :volume, 6)
      assert_receive {:update_config, @key, %{volume: 7}}
      refute_receive {:cec, _, _}
    end
  end

  describe "echoes that will never come" do
    setup :linked

    @tag player: nil, echo: false
    test "writes no player received expect no echo", %{pid: pid, pubsub: pubsub} do
      assert :sys.get_state(pid).links[@dev].echoes == []
      knob(pid, 30)
      assert :sys.get_state(pid).links[@dev].echoes == []

      # So a later request for 30 is one, not taken for that write's echo.
      player_event(pubsub, @key, :volume, 40)
      reply(assert_cec({:set_volume, @dev, 40}), {:ok, %{volume: 40, muted: false}})
      idle(pid)
      player_event(pubsub, @key, :volume, 30)
      reply(assert_cec({:set_volume, @dev, 30}), {:ok, %{volume: 30, muted: false}})
    end

    @tag echo: false
    test "a new player's startup snapshot drops the old player's expected echoes",
         %{pid: pid, pubsub: pubsub, player: player} do
      knob(pid, 30)
      assert [_ | _] = :sys.get_state(pid).links[@dev].echoes

      # :p1 died before echoing; :p2 is spawned with the stored 30.
      Agent.update(player, fn _ -> :p2 end)
      startup_event(pubsub, :volume, 30, :p2)
      idle(pid)
      assert :sys.get_state(pid).links[@dev].echoes == []

      player_event(pubsub, @key, :volume, 40, :p2)
      reply(assert_cec({:set_volume, @dev, 40}), {:ok, %{volume: 40, muted: false}})
      idle(pid)
      player_event(pubsub, @key, :volume, 30, :p2)
      reply(assert_cec({:set_volume, @dev, 30}), {:ok, %{volume: 30, muted: false}})
    end

    @tag echo: false
    test "an old player's echo is a request from the new one's point of view",
         %{pid: pid, pubsub: pubsub} do
      knob(pid, 30)

      # A value equal to an expected echo, but from another player.
      player_event(pubsub, @key, :volume, 40, :p1)
      reply(assert_cec({:set_volume, @dev, 40}), {:ok, %{volume: 40, muted: false}})
      idle(pid)
      player_event(pubsub, @key, :volume, 30, :p2)
      reply(assert_cec({:set_volume, @dev, 30}), {:ok, %{volume: 30, muted: false}})
    end

    # Hotplug: the player was spawned (and got the adoption's 20) before
    # the link saw its startup snapshot of 50.
    @tag echo: false
    test "the snapshot keeps the current player's expectations, through a request",
         %{pid: pid, pubsub: pubsub} do
      startup_event(pubsub, :volume, 50)
      assert_receive {:update_config, @key, %{volume: 20}}
      startup_event(pubsub, :muted, false)

      player_event(pubsub, @key, :volume, 35)
      walk = assert_cec({:set_volume, @dev, 35})

      # The adoption's echoes and the correction's arrive mid-walk.
      player_event(pubsub, @key, :volume, 20)
      player_event(pubsub, @key, :muted, false)
      player_event(pubsub, @key, :volume, 20)
      reply(walk, {:ok, %{volume: 35, muted: false}})

      assert_receive {:update_config, @key, %{volume: 35}}
      idle(pid)
      refute_receive {:cec, _, _}
    end

    @tag echo: false
    test "two identical writes expect two echoes", %{pid: pid, pubsub: pubsub} do
      startup_event(pubsub, :volume, 50)
      assert_receive {:update_config, @key, %{volume: 20}}

      player_event(pubsub, @key, :volume, 20)
      knob(pid, 30)
      # The correction's echo, after the knob moved the receiver to 30.
      player_event(pubsub, @key, :volume, 20)
      assert_receive {:update_config, @key, %{volume: 30}}
      idle(pid)
      refute_receive {:cec, _, _}
    end
  end

  describe "the player's startup snapshot" do
    setup :linked

    @tag echo: false
    test "a delayed binary's --initial-volume doesn't move the receiver", %{pubsub: pubsub} do
      # The player was spawned (hotplug) before the link adopted 20; its
      # binary reports the volume it was started with only now.
      startup_event(pubsub, :volume, 50)
      assert_receive {:update_config, @key, %{volume: 20}}

      # Then the adoption's echo (and the write-back's).
      player_event(pubsub, @key, :volume, 20)
      player_event(pubsub, @key, :volume, 20)
      refute_receive {:cec, _, _}
      refute_receive {:update_config, _, _}
    end

    @tag echo: false
    test "a startup mute echo doesn't mute the receiver", %{pubsub: pubsub} do
      startup_event(pubsub, :muted, true)
      assert_receive {:update_config, @key, %{muted: false}}
      player_event(pubsub, @key, :muted, false)
      refute_receive {:cec, _, _}
    end

    test "a startup snapshot matching the receiver writes nothing", %{pubsub: pubsub} do
      startup_event(pubsub, :volume, 20)
      refute_receive {:update_config, _, _}
      refute_receive {:cec, _, _}
    end
  end

  describe "receiver to output" do
    setup :linked

    @tag output: %{cec_volume_max: 30}
    test "a knob change found by polling is written to the output, uncapped",
         %{pid: pid} do
      poll_now(pid)
      reply(assert_cec({:power_status, @dev}), {:ok, :on})
      reply(assert_cec({:audio_status, @dev}), {:ok, %{volume: 45, muted: false}})
      assert_receive {:update_config, @key, %{volume: 45}}

      # Its echo isn't a request (no step down to the ceiling).
      refute_receive {:cec, _, _}
    end

    test "the next poll skips the power check", %{pid: pid} do
      poll_now(pid)
      reply(assert_cec({:power_status, @dev}), {:ok, :on})
      reply(assert_cec({:audio_status, @dev}), {:ok, %{volume: 20, muted: false}})

      idle(pid)
      poll_now(pid)
      reply(assert_cec({:audio_status, @dev}), {:ok, %{volume: 20, muted: true}})
      assert_receive {:update_config, @key, %{muted: true}}
    end

    test "polls wait while a run is in progress", %{pid: pid, pubsub: pubsub} do
      player_event(pubsub, @key, :volume, 35)
      task = assert_cec({:set_volume, @dev, 35})

      poll_now(pid)
      refute_receive {:cec, _, _}

      reply(task, {:ok, %{volume: 35, muted: false}})
      idle(pid)
      poll_now(pid)
      reply(assert_cec({:power_status, @dev}), {:ok, :on})
      reply(assert_cec({:audio_status, @dev}), {:ok, %{volume: 35, muted: false}})
      refute_receive {:update_config, _, _}
    end

    test "a request made while a poll runs is stepped after it", %{pid: pid, pubsub: pubsub} do
      poll_now(pid)
      reply(assert_cec({:power_status, @dev}), {:ok, :on})
      poll = assert_cec({:audio_status, @dev})

      player_event(pubsub, @key, :volume, 35)
      refute_receive {:cec, _, _}

      reply(poll, {:ok, %{volume: 20, muted: false}})
      reply(assert_cec({:set_volume, @dev, 35}), {:ok, %{volume: 35, muted: false}})
      refute_receive {:update_config, _, _}
    end

    test "a poll's result for an earlier link is dropped", %{pid: pid, pubsub: pubsub} do
      poll_now(pid)
      reply(assert_cec({:power_status, @dev}), {:ok, :on})
      poll = assert_cec({:audio_status, @dev})

      state(pubsub, %{cec_volume: false})
      assert_receive {:external, @key, false}
      state(pubsub, %{cec_volume: true})
      assert_receive {:external, @key, true}
      assert_receive {:update_config, @key, %{volume: 20, muted: false}}

      reply(poll, {:ok, %{volume: 45, muted: false}})
      idle(pid)
      refute_receive {:update_config, _, _}
      assert VolumeLink.links(pid) == %{@dev => @key}
    end

    test "a poll message from a timer no longer armed is ignored", %{pid: pid} do
      send(pid, {:poll, @dev, make_ref()})
      refute_receive {:cec, _, _}
    end

    test "Cec.Server's receiver reports count outside a run and are ignored during one",
         %{pubsub: pubsub} do
      adapters(pubsub, [adapter(%{volume: 25})])
      assert_receive {:update_config, @key, %{volume: 25}}

      player_event(pubsub, @key, :volume, 35)
      task = assert_cec({:set_volume, @dev, 35})
      during = adapter(%{volume: 30})
      adapters(pubsub, [during])
      refute_receive {:update_config, _, _}

      reply(task, {:ok, %{volume: 35, muted: false}})
      refute_receive {:update_config, _, _}

      # The same record again isn't a new report.
      adapters(pubsub, [during])
      refute_receive {:update_config, _, _}
    end
  end

  describe "a receiver that stops answering" do
    setup :linked

    test "is unlinked after three failed polls in a row", %{pid: pid} do
      failed_poll(pid, first: true)
      failed_poll(pid)
      refute_receive {:external, @key, false}

      failed_poll(pid)
      assert_receive {:external, @key, false}
      assert VolumeLink.links(pid) == %{}
    end

    test "a successful poll resets the count", %{pid: pid} do
      failed_poll(pid, first: true)
      failed_poll(pid)

      poll_now(pid)
      reply(assert_cec({:audio_status, @dev}), {:ok, %{volume: 20, muted: false}})
      idle(pid)

      failed_poll(pid)
      failed_poll(pid)
      refute_receive {:external, @key, false}
      assert VolumeLink.links(pid) == %{@dev => @key}
    end

    test "a hard run failure counts, a stalled run doesn't", %{pid: pid, pubsub: pubsub} do
      failed_poll(pid, first: true)
      failed_poll(pid)

      player_event(pubsub, @key, :volume, 60)

      reply(
        assert_cec({:set_volume, @dev, 60}),
        {:error, {:no_progress, %{volume: 22, muted: false}}}
      )

      assert_receive {:update_config, @key, %{volume: 22}}
      idle(pid)

      # The stall read the volume back: the receiver answered, count reset.
      failed_poll(pid)
      refute_receive {:external, @key, false}

      player_event(pubsub, @key, :volume, 70)
      reply(assert_cec({:set_volume, @dev, 70}), {:error, :timeout})
      idle(pid)
      refute_receive {:external, @key, false}

      failed_poll(pid)
      assert_receive {:external, @key, false}
    end

    test "relinks once a probe gets an answer, not on Cec.Server's stale record",
         %{pid: pid, pubsub: pubsub} do
      failed_poll(pid, first: true)
      failed_poll(pid)
      failed_poll(pid)
      assert_receive {:external, @key, false}

      adapters(pubsub, [adapter()])
      refute_receive {:external, @key, true}

      poll_now(pid)
      reply(assert_cec({:power_status, @dev}), {:ok, :on})
      reply(assert_cec({:audio_status, @dev}), {:ok, %{volume: 33, muted: false}})
      assert_receive {:external, @key, true}
      assert_receive {:update_config, @key, %{volume: 33, muted: false}}
      assert VolumeLink.links(pid) == %{@dev => @key}
    end

    test "our own adapter's errors (:not_configured after a hotplug) don't count",
         %{pid: pid} do
      failed_poll(pid, first: true, error: :not_configured)

      for _ <- 1..4, do: failed_poll(pid, error: :not_configured)

      refute_receive {:external, @key, false}
      assert VolumeLink.links(pid) == %{@dev => @key}
    end

    test "three NACKs unlink", %{pid: pid} do
      failed_poll(pid, first: true, error: :nack)
      failed_poll(pid, error: :nack)
      refute_receive {:external, @key, false}

      failed_poll(pid, error: :nack)
      assert_receive {:external, @key, false}
    end

    test "in a mix only the receiver's silences count", %{pid: pid} do
      failed_poll(pid, first: true, error: :nack)
      failed_poll(pid, error: :not_configured)
      failed_poll(pid, error: :timeout)
      failed_poll(pid, error: :busy)
      failed_poll(pid, error: :cec_unavailable)
      refute_receive {:external, @key, false}

      failed_poll(pid, error: :nack)
      assert_receive {:external, @key, false}
    end

    test "a run our own adapter couldn't send doesn't count", %{pid: pid, pubsub: pubsub} do
      failed_poll(pid, first: true)
      failed_poll(pid)

      player_event(pubsub, @key, :volume, 60)
      reply(assert_cec({:set_volume, @dev, 60}), {:error, :not_configured})
      idle(pid)
      refute_receive {:external, @key, false}

      failed_poll(pid)
      assert_receive {:external, @key, false}
    end

    test "answers without a volume count as failures", %{pid: pid} do
      poll_now(pid)
      reply(assert_cec({:power_status, @dev}), {:ok, :on})
      reply(assert_cec({:audio_status, @dev}), {:ok, %{volume: nil, muted: false}})
      idle(pid)

      for _ <- 1..2 do
        poll_now(pid)
        reply(assert_cec({:audio_status, @dev}), {:ok, %{volume: nil, muted: false}})
        idle(pid)
      end

      assert_receive {:external, @key, false}
    end

    test "a probe finishing after its adapter went away is ignored",
         %{pid: pid, pubsub: pubsub} do
      failed_poll(pid, first: true, error: :nack)
      failed_poll(pid, error: :nack)
      failed_poll(pid, error: :nack)
      assert_receive {:external, @key, false}

      poll_now(pid)
      reply(assert_cec({:power_status, @dev}), {:ok, :on})
      probe = assert_cec({:audio_status, @dev})

      adapters(pubsub, [])
      reply(probe, {:ok, %{volume: 33, muted: false}})
      idle(pid)

      assert Process.alive?(pid)
      refute_receive {:external, @key, true}
      assert VolumeLink.links(pid) == %{}
    end

    test "a mute-only run reading back no volume counts as a failure",
         %{pid: pid, pubsub: pubsub} do
      failed_poll(pid, first: true)

      player_event(pubsub, @key, :muted, true)
      reply(assert_cec({:set_muted, @dev, true}), {:ok, %{volume: nil, muted: true}})
      idle(pid)
      refute_receive {:external, @key, false}

      player_event(pubsub, @key, :muted, false)
      reply(assert_cec({:set_muted, @dev, false}), {:ok, %{volume: nil, muted: false}})
      assert_receive {:external, @key, false}
    end

    test "a Feature Abort of the audio status counts as a failure", %{pid: pid} do
      poll_now(pid)
      reply(assert_cec({:power_status, @dev}), {:ok, :on})
      reply(assert_cec({:audio_status, @dev}), {:error, :feature_abort})
      idle(pid)

      failed_poll(pid, error: :feature_abort)
      refute_receive {:external, @key, false}

      failed_poll(pid, error: :feature_abort)
      assert_receive {:external, @key, false}
    end

    @tag echo: false, echo_ttl_ms: 0
    test "expected echoes no player answers don't pile up", %{pid: pid} do
      for volume <- [30, 40, 50], do: knob(pid, volume)
      assert [%{field: :volume, value: 50}] = :sys.get_state(pid).links[@dev].echoes
    end

    test "a walk that got somewhere before failing reconciles to where it got",
         %{pid: pid, pubsub: pubsub} do
      player_event(pubsub, @key, :volume, 60)

      reply(
        assert_cec({:set_volume, @dev, 60}),
        {:error, {:timeout, %{volume: 52, muted: false, step: 1}}}
      )

      assert_receive {:update_config, @key, %{volume: 52}}
      idle(pid)

      # ...and it counted as a failure: two more and the link goes, at 52.
      failed_poll(pid, first: true)
      refute_receive {:external, @key, false}
      failed_poll(pid)
      assert_receive {:external, @key, false}
    end

    test "when a walk that got somewhere is the last failure, that is written back",
         %{pid: pid, pubsub: pubsub} do
      failed_poll(pid, first: true)
      failed_poll(pid)

      player_event(pubsub, @key, :volume, 60)

      reply(
        assert_cec({:set_volume, @dev, 60}),
        {:error, {:timeout, %{volume: 52, muted: false, step: 1}}}
      )

      assert_receive {:update_config, @key, %{volume: 52}}
      assert_receive {:external, @key, false}
    end

    test "when a run is the last failure, the receiver's state is written back first",
         %{pid: pid, pubsub: pubsub} do
      failed_poll(pid, first: true)
      failed_poll(pid)

      player_event(pubsub, @key, :volume, 60)
      reply(assert_cec({:set_volume, @dev, 60}), {:error, :timeout})

      # Software volume resumes at 20, where the receiver was, not at 60.
      assert_receive {:update_config, @key, %{volume: 20}}
      assert_receive {:external, @key, false}
    end

    @tag fail_unlink: 1
    test "the threshold is configurable", %{pid: pid} do
      failed_poll(pid, first: true)
      assert_receive {:external, @key, false}
    end
  end

  test "volume_link?/2: the output's setting wins over the default" do
    assert Cec.volume_link?(%{cec_volume: true}, false)
    refute Cec.volume_link?(%{cec_volume: false}, true)
    assert Cec.volume_link?(%{cec_volume: nil}, true)
    refute Cec.volume_link?(%{}, false)
  end

  ## Helpers

  defp linked(_context) do
    assert_receive {:external, @key, true}
    assert_receive {:update_config, @key, %{volume: 20, muted: false}}
    :ok
  end

  defp adapter(receiver \\ %{}) do
    %{
      dev: @dev,
      index: 0,
      card_index: 1,
      running?: true,
      receiver_presence: :present,
      receiver:
        Map.merge(
          %{power: :on, volume: 20, muted: false, updated_at: DateTime.utc_now()},
          receiver
        )
    }
  end

  defp output(extra \\ %{}) do
    Map.merge(
      %{key: @key, card_index: 1, volume: 50, muted: false, volume_external: false},
      extra
    )
  end

  defp adapters(pubsub, adapters),
    do: Phoenix.PubSub.broadcast(pubsub, Cec.topic(), {:cec_adapters, adapters})

  defp state(pubsub, partial),
    do: Phoenix.PubSub.broadcast(pubsub, "sendspin:state", {:sendspin_state, @key, partial})

  defp player_event(pubsub, key, field, value, player \\ :p1) do
    event = if field == :muted, do: "mute", else: to_string(field)
    message = {:sendspin_state, key, %{event: event, value: value, player: player}}
    Phoenix.PubSub.broadcast(pubsub, "sendspin:state", message)
  end

  # Runs in the link's task: hands the request to the test and waits for
  # its answer.
  defp cec(test, request) do
    send(test, {:cec, self(), request})

    receive do
      {:reply, :raise} -> raise "boom"
      {:reply, result} -> result
    after
      5_000 -> {:error, :timeout}
    end
  end

  defp assert_cec(request) do
    assert_receive {:cec, task, ^request}
    task
  end

  defp reply(task, result), do: send(task, {:reply, result})

  # A walk that teaches the link a step of 3.
  defp learn_step_3(pid, pubsub) do
    player_event(pubsub, @key, :volume, 23)
    reply(assert_cec({:set_volume, @dev, 23}), {:ok, %{volume: 23, muted: false, step: 3}})
    idle(pid)
  end

  # The receiver's knob moves to `volume`, found by a poll.
  defp knob(pid, volume) do
    poll_now(pid)
    state = :sys.get_state(pid)

    if not Map.has_key?(state.power_at, @dev),
      do: reply(assert_cec({:power_status, @dev}), {:ok, :on})

    reply(assert_cec({:audio_status, @dev}), {:ok, %{volume: volume, muted: false}})
    assert_receive {:update_config, @key, %{volume: ^volume}}
    idle(pid)
  end

  defp startup_event(pubsub, field, value, player \\ :p1) do
    event = if field == :muted, do: "mute", else: to_string(field)

    message =
      {:sendspin_state, @key, %{event: event, value: value, startup: true, player: player}}

    Phoenix.PubSub.broadcast(pubsub, "sendspin:state", message)
  end

  # Fires the poll timer currently armed for the adapter.
  defp poll_now(pid) do
    case :sys.get_state(pid).timers do
      %{@dev => {token, _timer}} -> send(pid, {:poll, @dev, token})
      _ -> flunk("no poll armed")
    end
  end

  # A linked receiver's poll that gets no answer. The first one also
  # checks power.
  defp failed_poll(pid, opts \\ []) do
    error = {:error, Keyword.get(opts, :error, :timeout)}
    poll_now(pid)
    if opts[:first], do: reply(assert_cec({:power_status, @dev}), error)
    reply(assert_cec({:audio_status, @dev}), error)
    idle(pid)
  end

  # Waits until the link has collected its running task (a run or a poll).
  defp idle(pid, tries \\ 100) do
    cond do
      :sys.get_state(pid).busy == %{} ->
        :ok

      tries == 0 ->
        flunk("the link is still busy")

      true ->
        Process.sleep(5)
        idle(pid, tries - 1)
    end
  end
end
