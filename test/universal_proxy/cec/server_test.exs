defmodule UniversalProxy.Cec.ServerTest do
  # async: false — FakeCtl reports to a pid held in application env.
  use ExUnit.Case, async: false

  alias UniversalProxy.Cec
  alias UniversalProxy.Cec.{FakeCtl, Monitor, Server}

  @pubsub UniversalProxy.PubSub
  @dev "/dev/cec0"
  @output_key {"vc4-hdmi", nil, nil}

  setup do
    Application.put_env(:universal_proxy, :cec_fake_ctl_pid, self())
    on_exit(fn -> Application.delete_env(:universal_proxy, :cec_fake_ctl_pid) end)

    {:ok, agent} =
      Agent.start_link(fn ->
        %{@dev => %{dev: @dev, index: 0, hdmi_device: "fef00700.hdmi", card_index: 1}}
      end)

    {:ok, task_sup} = Task.Supervisor.start_link()

    server =
      start_supervised!(
        {Server,
         name: nil,
         ctl_module: FakeCtl,
         enumerate: fn -> Agent.get(agent, & &1) end,
         output_lookup: fn
           @output_key -> {:ok, %{card_index: 1}}
           _ -> :error
         end,
         monitor?: false,
         scan_interval_ms: 60_000,
         task_supervisor: task_sup}
      )

    {:ok, server: server, agent: agent}
  end

  test "claims a playback address and reads the physical address on discovery", %{server: server} do
    assert_receive {:cec_ctl, ["-d", @dev, "-s", "--playback", "--osd-name", "Universal Proxy"]}
    assert_receive {:cec_ctl, ["-d", @dev]}

    assert [%{dev: @dev, card_index: 1, phys_addr: "1.0.0.0", logical_address: 4, claimed?: true}] =
             Server.list_adapters(server)

    assert {:ok, %{dev: @dev}} = Server.adapter_for_card(server, 1)
    assert :error = Server.adapter_for_card(server, 0)
  end

  test "a Sendspin stream_start on the paired output fires One Touch Play", %{server: server} do
    assert_receive {:cec_ctl, [_, _, "-s", "--playback" | _]}

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:state",
      {:sendspin_state, @output_key, %{event: "stream_start"}}
    )

    assert_receive {:cec_ctl, ["-d", @dev, "-s", "--to", "0", "--image-view-on"]}
    assert_receive {:cec_ctl, ["-d", @dev, "-s", "--active-source", "phys-addr=1.0.0.0"]}

    # Unrelated outputs (a USB DAC) don't touch CEC.
    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:state",
      {:sendspin_state, {"1-1.3", 1, 2}, %{event: "stream_start"}}
    )

    refute_receive {:cec_ctl, [_, _, "-s", "--to", "0", "--image-view-on"]}, 100
    assert Process.alive?(server)
  end

  test "monitor records update what is known about the receiver", %{server: server} do
    assert_receive {:cec_ctl, [_, _, "-s", "--playback" | _]}

    Phoenix.PubSub.broadcast(
      @pubsub,
      Monitor.topic(),
      {:cec_event, @dev,
       %{
         type: :message,
         direction: :received,
         from: 5,
         to: 4,
         opcode: "REPORT_AUDIO_STATUS",
         code: 0x7A,
         args: %{
           "aud-mute-status" => %{text: "Off", value: 0},
           "aud-vol-status" => %{text: "33", value: 33}
         }
       }}
    )

    Phoenix.PubSub.broadcast(
      @pubsub,
      Monitor.topic(),
      {:cec_event, @dev,
       %{
         type: :message,
         direction: :received,
         from: 0,
         to: :all,
         opcode: "STANDBY",
         code: 0x36,
         args: %{}
       }}
    )

    Phoenix.PubSub.broadcast(
      @pubsub,
      Monitor.topic(),
      {:cec_event, @dev, %{type: :event, kind: :state_change, phys_addr: "f.f.f.f", la_mask: 0}}
    )

    assert {:ok,
            %{
              phys_addr: "f.f.f.f",
              receiver: %{power: :standby, volume: 33, muted: false, updated_at: %DateTime{}}
            }} =
             Server.get_adapter(server, @dev)
  end

  test "status reports from devices other than the receiver are ignored", %{server: server} do
    assert_receive {:cec_ctl, [_, _, "-s", "--playback" | _]}

    report = fn from, opcode, args ->
      Phoenix.PubSub.broadcast(
        @pubsub,
        Monitor.topic(),
        {:cec_event, @dev,
         %{type: :message, direction: :received, from: from, to: 4, opcode: opcode, args: args}}
      )
    end

    report.(5, "REPORT_POWER_STATUS", %{"pwr-state" => %{text: "On", value: 0}})
    # The TV (0) answering its own power query, and a directed Standby from it.
    report.(0, "REPORT_POWER_STATUS", %{"pwr-state" => %{text: "Standby", value: 1}})

    report.(0, "REPORT_AUDIO_STATUS", %{
      "aud-mute-status" => %{text: "On", value: 1},
      "aud-vol-status" => %{text: "80", value: 80}
    })

    report.(0, "STANDBY", %{})

    assert {:ok, %{receiver: %{power: :on, volume: nil, muted: nil}}} =
             Server.get_adapter(server, @dev)

    report.(5, "STANDBY", %{})
    assert {:ok, %{receiver: %{power: :standby}}} = Server.get_adapter(server, @dev)
  end

  test "an unplugged adapter is dropped on the next scan", %{server: server, agent: agent} do
    assert_receive {:cec_ctl, [_, _, "-s", "--playback" | _]}
    Agent.update(agent, fn _ -> %{} end)
    :ok = Server.rescan(server)
    assert Server.list_adapters(server) == []
  end

  describe "adapter monitors" do
    setup %{agent: agent} do
      start_supervised!({Registry, keys: :unique, name: UniversalProxy.Cec.MonitorRegistry})

      start_supervised!(
        {DynamicSupervisor, name: UniversalProxy.Cec.MonitorSupervisor, strategy: :one_for_one}
      )

      # Stand-in for `cec-ctl -m`: runs until the port closes its stdin.
      dir = Path.join(System.tmp_dir!(), "cec_mon_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      binary = Path.join(dir, "cec-ctl")
      File.write!(binary, "#!/bin/sh\nexec cat >/dev/null\n")
      File.chmod!(binary, 0o755)
      on_exit(fn -> File.rm_rf!(dir) end)

      server =
        start_supervised!(
          {Server,
           name: nil,
           ctl_module: FakeCtl,
           enumerate: fn -> Agent.get(agent, & &1) end,
           output_lookup: fn _ -> :error end,
           monitor_binary: binary,
           scan_interval_ms: 60_000},
          id: :monitored_server
        )

      :ok = Server.rescan(server)
      {:ok, server: server}
    end

    test "a restarted monitor is still stopped on unplug, and replug starts exactly one", %{
      server: server,
      agent: agent
    } do
      [{original, _}] = Registry.lookup(UniversalProxy.Cec.MonitorRegistry, @dev)
      ref = Process.monitor(original)
      Process.exit(original, :kill)
      assert_receive {:DOWN, ^ref, :process, ^original, :killed}

      replacement = wait_for_monitor(original)
      assert replacement != original

      unplugged = Agent.get(agent, & &1)
      Agent.update(agent, fn _ -> %{} end)
      :ok = Server.rescan(server)

      assert DynamicSupervisor.which_children(UniversalProxy.Cec.MonitorSupervisor) == []
      refute Process.alive?(replacement)

      Agent.update(agent, fn _ -> unplugged end)
      :ok = Server.rescan(server)

      assert [{:undefined, pid, :worker, _}] =
               DynamicSupervisor.which_children(UniversalProxy.Cec.MonitorSupervisor)

      assert [{^pid, _}] = Registry.lookup(UniversalProxy.Cec.MonitorRegistry, @dev)
    end
  end

  defp wait_for_monitor(old, attempts \\ 50) do
    case Registry.lookup(UniversalProxy.Cec.MonitorRegistry, @dev) do
      [{pid, _}] when pid != old ->
        pid

      _ when attempts > 0 ->
        Process.sleep(10)
        wait_for_monitor(old, attempts - 1)

      other ->
        flunk("monitor for #{@dev} not restarted: #{inspect(other)}")
    end
  end

  describe "facade commands against an explicit adapter" do
    setup %{server: server} do
      assert_receive {:cec_ctl, [_, _, "-s", "--playback" | _]}
      {:ok, adapter} = Server.get_adapter(server, @dev)
      {:ok, adapter: adapter}
    end

    test "one_touch_play skips Active Source without a valid physical address", %{
      adapter: adapter
    } do
      assert :ok = Cec.one_touch_play(%{adapter | phys_addr: "f.f.f.f"}, ctl: FakeCtl)
      assert_receive {:cec_ctl, [_, _, "-s", "--to", "0", "--image-view-on"]}
      refute_receive {:cec_ctl, [_, _, "-s", "--active-source" | _]}, 50
    end

    test "user controls send press and release to the receiver address", %{adapter: adapter} do
      assert :ok = Cec.user_control(adapter, :volume_up, ctl: FakeCtl, receiver_la: 5)

      assert_receive {:cec_ctl,
                      [
                        "-d",
                        @dev,
                        "-s",
                        "--to",
                        "5",
                        "--user-control-pressed",
                        "ui-cmd=0x41",
                        "--user-control-released"
                      ]}
    end
  end

  test "facade degrades when the server is not running" do
    assert Cec.list_adapters() == []
    assert Cec.get_adapter(@dev) == :error
    assert {:error, :cec_unavailable} = Cec.power_status(@dev, ctl: FakeCtl)
  end
end
