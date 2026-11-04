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

    opts = [
      name: nil,
      pubsub: pubsub,
      list_adapters: fn -> adapters end,
      list_outputs: fn -> outputs end,
      set_volume_external: fn key, external? ->
        send(test, {:external, key, external?})
        :ok
      end,
      # Like Audio.update_config/2: the player echoes each value it is given.
      update_config: fn key, params ->
        send(test, {:update_config, key, params})
        if echo?, do: for({field, value} <- params, do: player_event(pubsub, key, field, value))
        :ok
      end,
      set_volume: &cec(test, {:set_volume, &1, &2}),
      set_muted: &cec(test, {:set_muted, &1, &2}),
      audio_status: &cec(test, {:audio_status, &1}),
      power_status: &cec(test, {:power_status, &1}),
      poll_ms: 60_000,
      probe_ms: 60_000,
      settle_ms: 0,
      fail_unlink: Map.get(context, :fail_unlink, 3),
      default: true
    ]

    pid = start_supervised!({VolumeLink, opts})
    {:ok, pid: pid, pubsub: pubsub}
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

    test "a stopped adapter or an absent receiver unlinks", %{pubsub: pubsub} do
      assert_receive {:external, @key, true}
      adapters(pubsub, [Map.put(adapter(), :running?, false)])
      assert_receive {:external, @key, false}

      adapters(pubsub, [adapter()])
      assert_receive {:external, @key, true}
      adapters(pubsub, [Map.put(adapter(), :receiver_presence, :absent)])
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
      assert_receive {:update_config, @key, %{volume: 20}}
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
    test "an echo arriving after a newer request isn't taken for one", %{pubsub: pubsub} do
      player_event(pubsub, @key, :volume, 60)
      reply(assert_cec({:set_volume, @dev, 60}), {:error, {:no_progress, %{volume: 52}}})
      assert_receive {:update_config, @key, %{volume: 52}}

      player_event(pubsub, @key, :volume, 45)
      player_event(pubsub, @key, :volume, 52)
      reply(assert_cec({:set_volume, @dev, 45}), {:ok, %{volume: 45, muted: false}})
      refute_receive {:cec, _, _}
      refute_receive {:update_config, _, _}
    end

    test "unlinked outputs' volume events are ignored", %{pubsub: pubsub} do
      player_event(pubsub, {"other", nil, nil}, :volume, 70)
      refute_receive {:cec, _, _}
    end
  end

  describe "receiver to output" do
    setup :linked

    @tag output: %{cec_volume_max: 30}
    test "a knob change found by polling is written to the output, uncapped",
         %{pid: pid} do
      send(pid, {:poll, @dev})
      reply(assert_cec({:power_status, @dev}), {:ok, :on})
      reply(assert_cec({:audio_status, @dev}), {:ok, %{volume: 45, muted: false}})
      assert_receive {:update_config, @key, %{volume: 45}}

      # Its echo isn't a request (no step down to the ceiling).
      refute_receive {:cec, _, _}
    end

    test "the next poll skips the power check", %{pid: pid} do
      send(pid, {:poll, @dev})
      reply(assert_cec({:power_status, @dev}), {:ok, :on})
      reply(assert_cec({:audio_status, @dev}), {:ok, %{volume: 20, muted: false}})

      idle(pid)
      send(pid, {:poll, @dev})
      reply(assert_cec({:audio_status, @dev}), {:ok, %{volume: 20, muted: true}})
      assert_receive {:update_config, @key, %{muted: true}}
    end

    test "polls wait while a run is in progress", %{pid: pid, pubsub: pubsub} do
      player_event(pubsub, @key, :volume, 35)
      task = assert_cec({:set_volume, @dev, 35})

      send(pid, {:poll, @dev})
      refute_receive {:cec, _, _}

      reply(task, {:ok, %{volume: 35, muted: false}})
      idle(pid)
      send(pid, {:poll, @dev})
      reply(assert_cec({:power_status, @dev}), {:ok, :on})
      reply(assert_cec({:audio_status, @dev}), {:ok, %{volume: 35, muted: false}})
      refute_receive {:update_config, _, _}
    end

    test "a request made while a poll runs is stepped after it", %{pid: pid, pubsub: pubsub} do
      send(pid, {:poll, @dev})
      reply(assert_cec({:power_status, @dev}), {:ok, :on})
      poll = assert_cec({:audio_status, @dev})

      player_event(pubsub, @key, :volume, 35)
      refute_receive {:cec, _, _}

      reply(poll, {:ok, %{volume: 20, muted: false}})
      reply(assert_cec({:set_volume, @dev, 35}), {:ok, %{volume: 35, muted: false}})
      refute_receive {:update_config, _, _}
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

      send(pid, {:poll, @dev})
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

      send(pid, {:poll, @dev})
      reply(assert_cec({:power_status, @dev}), {:ok, :on})
      reply(assert_cec({:audio_status, @dev}), {:ok, %{volume: 33, muted: false}})
      assert_receive {:external, @key, true}
      assert_receive {:update_config, @key, %{volume: 33, muted: false}}
      assert VolumeLink.links(pid) == %{@dev => @key}
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

  defp player_event(pubsub, key, field, value) do
    event = if field == :muted, do: "mute", else: to_string(field)
    message = {:sendspin_state, key, %{event: event, value: value}}
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

  # A linked receiver's poll that gets no answer. The first one also
  # checks power.
  defp failed_poll(pid, opts \\ []) do
    send(pid, {:poll, @dev})
    if opts[:first], do: reply(assert_cec({:power_status, @dev}), {:error, :timeout})
    reply(assert_cec({:audio_status, @dev}), {:error, :timeout})
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
