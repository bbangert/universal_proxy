defmodule UniversalProxy.Cec.ServerTest do
  # async: false - the subtree runs under its fixed registered names.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import ExUnit.CaptureLog
  import UniversalProxy.CecBus

  alias Circuits.CEC.{Message, Struct}
  alias Circuits.CEC.Transport.Fake
  alias UniversalProxy.Cec
  alias UniversalProxy.Cec.{Server, Supervisor}

  @pubsub UniversalProxy.PubSub
  @dev "/dev/cec0"
  @output_key {"vc4-hdmi", nil, nil}
  @pa 0x1000
  # Logical address 4 (Playback 1).
  @mask 0x10

  @adapter_info %{dev: @dev, index: 0, hdmi_device: "fef00700.hdmi", card_index: 1}

  setup context do
    fake = start_supervised!({Fake, []})
    agent = start_supervised!({Agent, fn -> %{@dev => @adapter_info} end})

    start_supervised!(
      {Supervisor,
       enabled: true,
       transport: Fake,
       transport_opts: [fake: fake],
       enumerate: fn -> Agent.get(agent, & &1) end,
       output_lookup: fn
         @output_key -> {:ok, Map.merge(%{card_index: 1}, Map.get(context, :output, %{}))}
         _ -> :error
       end,
       auto_wake: Map.get(context, :auto_wake, true),
       receiver_la: Map.get(context, :receiver_la, 5),
       scan_interval_ms: 60_000,
       restart_ms: Map.get(context, :restart_ms, 10),
       restart_max_ms: Map.get(context, :restart_max_ms, 40),
       stable_ms: Map.get(context, :stable_ms, 60_000)}
    )

    {:ok, fake: fake, agent: agent}
  end

  describe "discovery" do
    test "starts an adapter that claims a playback address", %{fake: fake} do
      configure(fake)

      assert {:s_mode, 0x21} in requests(fake)
      assert [{:s_log, claim}] = Enum.filter(requests(fake), &match?({:s_log, _}, &1))

      assert %{osd_name: "UniversalProxy", log_addr_type: [3 | _]} =
               Struct.decode_log_addrs(claim)

      assert [
               %{
                 dev: @dev,
                 card_index: 1,
                 running?: true,
                 configured?: true,
                 phys_addr: "1.0.0.0",
                 logical_address: 4,
                 receiver_presence: :absent
               }
             ] = Server.list_adapters()

      assert {:ok, %{dev: @dev}} = Server.adapter_for_card(1)
      assert :error = Server.adapter_for_card(0)
      assert {:ok, %{follower: :exclusive, power_status: :on}} = Cec.info(@dev)
    end

    test "the record names the receiver's address, or the TV's without one", %{fake: fake} do
      configure(fake, :present)
      assert {:ok, %{receiver_target: 5}} = Server.get_adapter(@dev)
    end

    test "with no receiver on the bus the target is the TV", %{fake: fake} do
      configure(fake, :absent)
      assert {:ok, %{receiver_target: 0}} = Server.get_adapter(@dev)
    end

    @tag receiver_la: nil
    test "with receiver_la: nil the target is the TV before any poll" do
      wait_until(fn ->
        match?({:ok, %{running?: true, receiver_presence: :unknown}}, Server.get_adapter(@dev))
      end)

      assert {:ok, %{receiver_target: 0}} = Server.get_adapter(@dev)
    end

    test "re-broadcasts adapter events on the CEC topic", %{fake: fake} do
      Phoenix.PubSub.subscribe(@pubsub, Server.topic())
      configure(fake)
      assert_receive {:cec_event, @dev, {:state, %{configured?: true, phys_addr: @pa}}}
    end

    test "broadcasts the adapter list when a record changes", %{fake: fake} do
      Phoenix.PubSub.subscribe(@pubsub, Cec.topic())
      configure(fake, :present)

      assert_receive {:cec_adapters,
                      [%{dev: @dev, configured?: true, receiver_presence: :present}]}

      receive_msg(fake, <<0x54, 0x90, 0x01>>)
      assert_receive {:cec_adapters, [%{receiver: %{power: :standby}}]}

      # An event that changes no record broadcasts no list.
      flush_adapters()
      receive_msg(fake, <<0x04, 0x90, 0x01>>)
      assert_receive {:cec_event, @dev, {:message, %Message{from: 0}}}
      refute_receive {:cec_adapters, _}, 50
    end

    test "a crashed adapter's backoff is broadcast", %{fake: fake} do
      configure(fake)
      Phoenix.PubSub.subscribe(@pubsub, Cec.topic())
      :ok = Fake.inject(fake, {:exit, 1})

      assert_receive {:cec_adapters, [%{running?: false, backoff: %{crashes: 1}}]}
    end
  end

  describe "auto-wake" do
    test "a Sendspin stream_start on the paired output runs One Touch Play", %{fake: fake} do
      configure(fake)
      stream_start(@output_key)

      {seq, %Message{to: 0, body: :image_view_on}} = nth_tx(fake, 2)
      ack(fake, seq)
      {seq, %Message{to: 15, body: {:active_source, @pa}}} = nth_tx(fake, 3)
      ack(fake, seq)

      wait_until(fn -> match?({:ok, %{active_source?: true}}, Server.get_adapter(@dev)) end)

      # Unrelated outputs (a USB DAC) don't touch CEC.
      stream_start({"1-1.3", 1, 2})
      Process.sleep(100)
      assert length(transmits(fake)) == 3
    end

    @tag auto_wake: false
    test "is off with auto_wake: false", %{fake: fake} do
      configure(fake)
      stream_start(@output_key)
      Process.sleep(100)
      assert length(transmits(fake)) == 1
    end

    @tag output: %{cec_auto_wake: false}
    test "is off for an output whose cec_auto_wake is false", %{fake: fake} do
      configure(fake)
      stream_start(@output_key)
      Process.sleep(100)
      assert length(transmits(fake)) == 1
    end

    @tag auto_wake: false, output: %{cec_auto_wake: true}
    test "an output's cec_auto_wake: true overrides auto_wake: false", %{fake: fake} do
      configure(fake)
      stream_start(@output_key)
      assert {_seq, %Message{to: 0, body: :image_view_on}} = nth_tx(fake, 2)
    end
  end

  describe "the receiver" do
    test "status counts only when the receiver sent it", %{fake: fake} do
      configure(fake, :present)

      Phoenix.PubSub.subscribe(@pubsub, Server.topic())

      # From the TV (0): its own power, audio and a directed Standby.
      receive_msg(fake, <<0x04, 0x90, 0x01>>)
      receive_msg(fake, <<0x04, 0x7A, 0xD0>>)
      receive_msg(fake, <<0x04, 0x36>>)

      # The Server re-broadcasts each event after applying it.
      assert_receive {:cec_event, @dev, {:message, %Message{from: 0, body: :standby}}}
      assert %{power: :unknown, volume: nil, muted: nil, updated_at: nil} = receiver()

      # From the receiver (5): power on, volume 33 unmuted.
      receive_msg(fake, <<0x54, 0x90, 0x00>>)
      receive_msg(fake, <<0x54, 0x7A, 0x21>>)

      wait_until(fn -> receiver().volume == 33 end)
      assert %{power: :on, volume: 33, muted: false} = receiver()

      receive_msg(fake, <<0x54, 0x36>>)
      wait_until(fn -> receiver().power == :standby end)
    end

    test "a broadcast Standby puts the receiver in standby", %{fake: fake} do
      configure(fake, :present)
      receive_msg(fake, <<0x54, 0x90, 0x00>>)
      wait_until(fn -> receiver().power == :on end)

      receive_msg(fake, <<0x0F, 0x36>>)
      wait_until(fn -> receiver().power == :standby end)
    end

    test "without a receiver, the TV is the receiver", %{fake: fake} do
      configure(fake, :absent)

      task = Task.async(fn -> Cec.power_status(@dev) end)
      {seq, %Message{to: 0, body: :give_device_power_status}} = nth_tx(fake, 2)
      reply(fake, seq, <<0x04, 0x90, 0x01>>)

      assert Task.await(task) == {:ok, :standby}
      wait_until(fn -> receiver().power == :standby end)
    end

    test "power and audio status queries go to the receiver", %{fake: fake} do
      configure(fake, :present)

      task = Task.async(fn -> Cec.audio_status(@dev) end)
      {seq, %Message{to: 5, body: :give_audio_status}} = nth_tx(fake, 2)
      reply(fake, seq, <<0x54, 0x7A, 0x85>>)
      assert Task.await(task) == {:ok, %{volume: 5, muted: true}}

      task = Task.async(fn -> Cec.power_status(@dev) end)
      {seq, %Message{to: 5, body: :give_device_power_status}} = nth_tx(fake, 3)
      reply(fake, seq, <<0x54, 0x90, 0x02>>)
      assert Task.await(task) == {:ok, :to_on}

      wait_until(fn -> receiver().power == :to_on end)
      assert %{power: :to_on, volume: 5, muted: true} = receiver()
    end

    test "status queried from another device leaves the receiver's alone", %{fake: fake} do
      configure(fake, :present)
      Phoenix.PubSub.subscribe(@pubsub, Server.topic())

      task = Task.async(fn -> Cec.power_status(@dev, to: :tv) end)
      {seq, %Message{to: 0, body: :give_device_power_status}} = nth_tx(fake, 2)
      reply(fake, seq, <<0x04, 0x90, 0x01>>)
      assert Task.await(task) == {:ok, :standby}

      task = Task.async(fn -> Cec.audio_status(@dev, to: :tv) end)
      {seq, %Message{to: 0, body: :give_audio_status}} = nth_tx(fake, 3)
      reply(fake, seq, <<0x04, 0x7A, 0xD0>>)
      assert Task.await(task) == {:ok, %{volume: 80, muted: true}}

      assert_receive {:cec_event, @dev,
                      {:message, %Message{from: 0, body: {:report_audio_status, _, _}}}}

      assert %{power: :unknown, volume: nil, muted: nil, updated_at: nil} = receiver()
    end

    test "receiver_la is a per-call destination override", %{fake: fake} do
      configure(fake, :present)

      task = Task.async(fn -> Cec.standby(@dev, receiver_la: 0) end)
      {seq, %Message{to: 0, body: :standby}} = nth_tx(fake, 2)
      ack(fake, seq)
      assert Task.await(task) == :ok
    end

    test "the cache is cleared when commands move from the receiver to the TV", %{fake: fake} do
      configure(fake, :present)
      receive_msg(fake, <<0x54, 0x7A, 0x21>>)
      wait_until(fn -> receiver().volume == 33 end)

      # The receiver NACKs a key press, so the adapter retries at the TV.
      task = Task.async(fn -> Cec.volume_up(@dev) end)
      {seq, %Message{to: 5, body: {:user_control_pressed, :volume_up}}} = nth_tx(fake, 2)
      nack(fake, seq)
      {seq, %Message{to: 0, body: {:user_control_pressed, :volume_up}}} = nth_tx(fake, 3)
      ack(fake, seq)
      {seq, %Message{to: 0, body: :user_control_released}} = nth_tx(fake, 4)
      ack(fake, seq)
      assert Task.await(task) == :ok

      wait_until(fn -> match?({:ok, %{receiver_presence: :absent}}, Server.get_adapter(@dev)) end)
      assert %{volume: nil, muted: nil} = receiver()

      receive_msg(fake, <<0x04, 0x90, 0x01>>)
      wait_until(fn -> receiver().power == :standby end)
      assert %{power: :standby, volume: nil, muted: nil} = receiver()
    end

    test "a key press is pressed and released at the receiver", %{fake: fake} do
      configure(fake, :present)

      task = Task.async(fn -> Cec.volume_up(@dev) end)
      {seq, %Message{to: 5, body: {:user_control_pressed, :volume_up}}} = nth_tx(fake, 2)
      ack(fake, seq)
      {seq, %Message{to: 5, body: :user_control_released}} = nth_tx(fake, 3)
      ack(fake, seq)
      assert Task.await(task) == :ok
    end

    test "a delivered Standby marks the receiver as going to standby", %{fake: fake} do
      configure(fake, :present)

      task = Task.async(fn -> Cec.standby(@dev) end)
      {seq, %Message{to: 5, body: :standby}} = nth_tx(fake, 2)
      ack(fake, seq)

      assert Task.await(task) == :ok
      wait_until(fn -> receiver().power == :to_standby end)
    end

    test "a Standby to another device leaves the receiver's power alone", %{fake: fake} do
      configure(fake, :present)

      task = Task.async(fn -> Cec.standby(@dev, to: :tv) end)
      {seq, %Message{to: 0, body: :standby}} = nth_tx(fake, 2)
      ack(fake, seq)
      assert Task.await(task) == :ok
      assert %{power: :unknown, updated_at: nil} = receiver()

      # A broadcast reaches the receiver too.
      task = Task.async(fn -> Cec.standby(@dev, to: :broadcast) end)
      {seq, %Message{to: 15, body: :standby}} = nth_tx(fake, 3)
      ack(fake, seq)
      assert Task.await(task) == :ok

      wait_until(fn -> receiver().power == :to_standby end)
    end

    test "a power report that beats the Standby result is not overwritten", %{fake: fake} do
      configure(fake, :present)

      task = Task.async(fn -> Cec.standby(@dev) end)
      {seq, %Message{to: 5, body: :standby}} = nth_tx(fake, 2)

      # The caller resumes only after the receiver's own report is recorded.
      :erlang.suspend_process(task.pid)
      ack(fake, seq)
      receive_msg(fake, <<0x54, 0x90, 0x01>>)
      wait_until(fn -> receiver().power == :standby end)
      :erlang.resume_process(task.pid)

      assert Task.await(task) == :ok
      assert receiver().power == :standby
    end

    test "an audio report during a Standby doesn't cancel the Standby's power", %{fake: fake} do
      configure(fake, :present)

      task = Task.async(fn -> Cec.standby(@dev) end)
      {seq, %Message{to: 5, body: :standby}} = nth_tx(fake, 2)

      :erlang.suspend_process(task.pid)
      ack(fake, seq)
      receive_msg(fake, <<0x54, 0x7A, 0x21>>)
      wait_until(fn -> receiver().volume == 33 end)
      :erlang.resume_process(task.pid)

      assert Task.await(task) == :ok
      wait_until(fn -> receiver().power == :to_standby end)
    end

    test "a NACKed Standby is an error and leaves the receiver cache alone", %{fake: fake} do
      configure(fake, :present)

      task = Task.async(fn -> Cec.standby(@dev) end)
      {seq, %Message{to: 5, body: :standby}} = nth_tx(fake, 2)
      nack(fake, seq)
      # The receiver went away: the adapter retries at the TV.
      {seq, %Message{to: 0, body: :standby}} = nth_tx(fake, 3)
      nack(fake, seq)

      assert Task.await(task) == {:error, :nack}
      assert %{power: :unknown, updated_at: nil} = receiver()
      assert {:ok, %{receiver_presence: :absent}} = Server.get_adapter(@dev)
    end
  end

  describe "crash backoff" do
    test "a crashing adapter is restarted with growing, capped delays", %{fake: fake} do
      log =
        capture_log(fn ->
          for delay <- [10, 20, 40, 40] do
            pid = attached_adapter(fake)
            :ok = Fake.inject(fake, {:exit, 1})
            wait_until(fn -> adapter_pid() != pid end)
            assert {:ok, %{backoff: %{retry_in_ms: ^delay}}} = Server.get_adapter(@dev)
          end
        end)

      assert {:ok, %{backoff: %{crashes: 4, reason: {:port_exit, 1}}}} =
               Server.get_adapter(@dev)

      # Logged on the first crash and again only at the cap.
      assert length(Regex.scan(~r/adapter \/dev\/cec0 crashed/, log)) == 1
      assert log =~ "still crashing"
      wait_until(&adapter_pid/0)
    end

    @tag stable_ms: 100
    test "an adapter that stays up resets the backoff", %{fake: fake} do
      for _ <- 1..2 do
        pid = attached_adapter(fake)
        :ok = Fake.inject(fake, {:exit, 1})
        wait_until(fn -> adapter_pid() not in [nil, pid] end)
      end

      assert {:ok, %{backoff: %{crashes: 2}}} = Server.get_adapter(@dev)
      wait_until(fn -> match?({:ok, %{backoff: nil}}, Server.get_adapter(@dev)) end)

      pid = attached_adapter(fake)
      :ok = Fake.inject(fake, {:exit, 1})
      wait_until(fn -> adapter_pid() not in [nil, pid] end)
      assert {:ok, %{backoff: %{crashes: 1, retry_in_ms: 10}}} = Server.get_adapter(@dev)
    end

    @tag restart_ms: 60_000
    test "a scan doesn't cut a backoff short", %{fake: fake} do
      pid = attached_adapter(fake)
      ref = Process.monitor(pid)
      :ok = Fake.inject(fake, {:exit, 1})
      assert_receive {:DOWN, ^ref, :process, ^pid, {:port_exit, 1}}
      wait_until(fn -> match?({:ok, %{running?: false}}, Server.get_adapter(@dev)) end)

      :ok = Server.rescan()
      assert adapter_pid() == nil
    end

    test "a device that went away is no crash", %{fake: fake} do
      pid = attached_adapter(fake)
      :ok = Fake.inject(fake, :gone)
      wait_until(fn -> match?({:ok, %{running?: false}}, Server.get_adapter(@dev)) end)
      :ok = Server.rescan()
      assert adapter_pid() not in [nil, pid]
      assert {:ok, %{backoff: nil}} = Server.get_adapter(@dev)
    end
  end

  describe "hotplug" do
    test "a replug forgets the previous receiver's status", %{fake: fake} do
      configure(fake, :present)
      receive_msg(fake, <<0x54, 0x7A, 0x21>>)
      wait_until(fn -> receiver().volume == 33 end)

      state_change(fake, 0xFFFF, 0)
      wait_until(fn -> match?({:ok, %{configured?: false}}, Server.get_adapter(@dev)) end)
      assert %{volume: nil, muted: nil} = receiver()

      state_change(fake, @pa, @mask)
      {seq, %Message{to: 5, body: :poll}} = nth_tx(fake, 2)
      ack(fake, seq)
      wait_until(fn -> match?({:ok, %{configured?: true}}, Server.get_adapter(@dev)) end)

      receive_msg(fake, <<0x54, 0x90, 0x00>>)
      wait_until(fn -> receiver().power == :on end)
      assert %{power: :on, volume: nil, muted: nil} = receiver()
    end

    test "an unplugged adapter is stopped on the next scan, and replug starts exactly one", %{
      fake: fake,
      agent: agent
    } do
      configure(fake)
      original = adapter_pid()

      # A crashed adapter is restarted (and still found on unplug).
      ref = Process.monitor(original)
      Process.exit(original, :kill)
      assert_receive {:DOWN, ^ref, :process, ^original, :killed}
      replacement = wait_until(fn -> (pid = adapter_pid()) != original && pid end)
      wait_until(fn -> match?({:ok, %{running?: true}}, Server.get_adapter(@dev)) end)

      Agent.update(agent, fn _ -> %{} end)
      :ok = Server.rescan()

      assert Server.list_adapters() == []
      assert DynamicSupervisor.which_children(Supervisor.adapter_supervisor()) == []
      refute Process.alive?(replacement)

      Agent.update(agent, fn _ -> %{@dev => @adapter_info} end)
      :ok = Server.rescan()
      :ok = Server.rescan()

      assert [{:undefined, pid, :worker, _}] =
               DynamicSupervisor.which_children(Supervisor.adapter_supervisor())

      assert [{^pid, _}] = Registry.lookup(Supervisor.registry(), @dev)
    end

    test "an adapter whose device went away is started again by the next scan that lists it",
         %{fake: fake} do
      configure(fake)
      original = adapter_pid()
      ref = Process.monitor(original)

      :ok = Fake.inject(fake, :gone)
      assert_receive {:DOWN, ^ref, :process, ^original, :normal}
      wait_until(fn -> match?({:ok, %{running?: false}}, Server.get_adapter(@dev)) end)
      assert {:ok, %{configured?: false, logical_address: nil}} = Server.get_adapter(@dev)

      :ok = Server.rescan()
      assert adapter_pid() != original
      assert {:ok, %{running?: true}} = Server.get_adapter(@dev)
    end
  end

  test "a failed open leaves the record and retries on the next scan" do
    failing = start_supervised!({Fake, [ready: {:open_error, :eacces}]}, id: :failing)
    stop_supervised!(Supervisor)

    start_supervised!(
      {Supervisor,
       enabled: true,
       transport: Fake,
       transport_opts: [fake: failing],
       enumerate: fn -> %{@dev => @adapter_info} end,
       output_lookup: fn _ -> :error end,
       scan_interval_ms: 60_000}
    )

    wait_until(fn -> Fake.owner(failing) != nil end)
    wait_until(fn -> DynamicSupervisor.which_children(Supervisor.adapter_supervisor()) == [] end)
    assert {:ok, %{running?: false}} = Server.get_adapter(@dev)

    # The next scan tries again.
    owner = Fake.owner(failing)
    :ok = Server.rescan()
    wait_until(fn -> Fake.owner(failing) != owner end)
  end

  test "with no CEC devices nothing starts and nothing crashes" do
    stop_supervised!(Supervisor)

    start_supervised!(
      {Supervisor, enabled: true, enumerate: fn -> %{} end, output_lookup: fn _ -> :error end}
    )

    :ok = Server.rescan()
    assert Cec.list_adapters() == []
    assert DynamicSupervisor.which_children(Supervisor.adapter_supervisor()) == []

    stream_start(@output_key)
    assert {:error, :no_such_adapter} = Cec.one_touch_play(@dev)
    assert Process.alive?(Process.whereis(Server))
  end

  test "the subtree runs the volume link unless told not to" do
    link = Process.whereis(UniversalProxy.Cec.VolumeLink)
    assert is_pid(link)

    # Its jobs run under the subtree's own Task.Supervisor, so a subtree
    # restart ends them.
    task_sup = Process.whereis(Supervisor.task_supervisor())
    assert :sys.get_state(link).task_sup == Supervisor.task_supervisor()

    assert Enum.any?(
             Elixir.Supervisor.which_children(Supervisor),
             &match?({_id, ^task_sup, :supervisor, [Task.Supervisor]}, &1)
           )

    stop_supervised!(Supervisor)
    refute Process.alive?(task_sup)

    start_supervised!(
      {Supervisor,
       enabled: true,
       volume_link: false,
       enumerate: fn -> %{} end,
       output_lookup: fn _ -> :error end}
    )

    assert Process.whereis(UniversalProxy.Cec.VolumeLink) == nil
  end

  test "the subtree is ignored unless enabled" do
    assert Supervisor.start_link() == :ignore
  end

  ## Helpers

  defp flush_adapters do
    receive do
      {:cec_adapters, _} -> flush_adapters()
    after
      50 -> :ok
    end
  end

  defp receiver do
    {:ok, %{receiver: receiver}} = Server.get_adapter(@dev)
    receiver
  end

  # The adapter registers its name before `init/1` opens the transport, and
  # the fake drops events until it has an owner. Inject only once it has.
  defp attached_adapter(fake) do
    wait_until(fn -> (pid = adapter_pid()) && Fake.owner(fake) == pid && pid end)
  end

  defp adapter_pid do
    case Registry.lookup(Supervisor.registry(), @dev) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp stream_start(key) do
    Phoenix.PubSub.broadcast(@pubsub, "sendspin:state", {
      :sendspin_state,
      key,
      %{event: "stream_start"}
    })
  end
end
