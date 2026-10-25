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

  test "an unplugged adapter is dropped on the next scan", %{server: server, agent: agent} do
    assert_receive {:cec_ctl, [_, _, "-s", "--playback" | _]}
    Agent.update(agent, fn _ -> %{} end)
    :ok = Server.rescan(server)
    assert Server.list_adapters(server) == []
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
