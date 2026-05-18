defmodule UniversalProxy.Audio.PlayerTest do
  # async: false — Player processes subscribe to global PubSub and
  # share a named MdnsStub Agent across the suite. Two concurrent
  # tests would tangle each other's mDNS calls and broadcasts.
  use ExUnit.Case, async: false

  alias UniversalProxy.Audio.Player

  @pubsub UniversalProxy.PubSub
  @fake_binary Path.expand("../../support/fake_sendspin_player.py", __DIR__)
  @key {"bcm2835 Headphones", nil, nil}

  defmodule MdnsStub do
    @moduledoc false
    use Agent

    def start_link(_initial \\ []) do
      Agent.start_link(fn -> %{calls: []} end, name: __MODULE__)
    end

    def add_mdns_service(service) do
      Agent.update(__MODULE__, fn s ->
        %{s | calls: [{:add, service} | s.calls]}
      end)

      :ok
    end

    def remove_mdns_service(id) do
      Agent.update(__MODULE__, fn s ->
        %{s | calls: [{:remove, id} | s.calls]}
      end)

      :ok
    end

    def calls, do: Agent.get(__MODULE__, & &1.calls) |> Enum.reverse()
  end

  setup do
    start_supervised!(MdnsStub)
    :ok = Phoenix.PubSub.subscribe(@pubsub, "sendspin:state")
    :ok
  end

  defp config do
    %{
      friendly_name: "Headphones",
      enabled: true,
      client_id: "deadbeef",
      volume: 60,
      muted: false,
      alsa_device: "plughw:0,0",
      card_index: 0,
      card_name: "bcm2835 Headphones"
    }
  end

  defp start_player!(overrides \\ []) do
    opts =
      Keyword.merge(
        [
          key: @key,
          config: config(),
          mdns_port: 18_928,
          binary_path: @fake_binary,
          mdns_module: MdnsStub
        ],
        overrides
      )

    start_supervised!({Player, opts})
  end

  describe "startup" do
    test "spawns the binary and forwards CLI args via the `started` event" do
      pid = start_player!()

      assert_receive {:sendspin_state, @key, event}, 2_000
      assert event.event == "started"
      assert event.name == "Headphones"
      assert event.client_id == "deadbeef"
      assert event.mdns_port == 18_928
      assert event.alsa_device == "plughw:0,0"
      assert event.initial_volume == 60

      assert Process.alive?(pid)
    end

    test "registers an mDNS service on launch" do
      _pid = start_player!()
      assert_receive {:sendspin_state, @key, _started}, 2_000

      # `register_mdns/1` runs synchronously inside `init/1` before
      # `start_supervised!` returns, so the Agent has already recorded
      # the add by the time the started event arrives. No sleep needed.
      [{kind, service}] = MdnsStub.calls()
      assert kind == :add
      assert service.id == {:sendspin_player, "bcm2835 Headphones", nil, nil}
      assert service.protocol == "sendspin"
      assert service.transport == "tcp"
      assert service.port == 18_928
      assert "name=Headphones" in service.txt_payload
      assert "client_id=deadbeef" in service.txt_payload
    end

    test "refuses to start when the binary is missing" do
      # `trap_exit` would otherwise leak into the next test in this
      # async: false suite — ExUnit doesn't reset process flags between
      # tests. Restore via on_exit.
      Process.flag(:trap_exit, true)
      on_exit(fn -> Process.flag(:trap_exit, false) end)

      assert {:error, {:binary_missing, "/tmp/nope"}} =
               Player.start_link(
                 key: @key,
                 config: config(),
                 mdns_port: 18_999,
                 binary_path: "/tmp/nope",
                 mdns_module: MdnsStub
               )
    end
  end

  describe "set_volume/2" do
    test "writes JSON to stdin and the fake echoes back via PubSub" do
      pid = start_player!()
      assert_receive {:sendspin_state, @key, %{event: "started"}}, 2_000

      :ok = Player.set_volume(pid, 80)
      assert_receive {:sendspin_state, @key, %{event: "volume", value: 80}}, 1_000

      :ok = Player.set_volume(pid, 5)
      assert_receive {:sendspin_state, @key, %{event: "volume", value: 5}}, 1_000
    end

    # The C++ binary's stdin parser is a strict left-to-right scanner —
    # `Jason.encode!/1` on a map iterates in unstable hash order, so
    # naively encoding `%{cmd: ..., value: ...}` emits `value` first
    # roughly half the time, and the binary silently drops the command.
    # Lock the literal wire bytes so a regression here is caught
    # without needing a real-binary integration test.
    test "produces deterministic field order `{\"cmd\":...,\"value\":...}`" do
      # Spawn a recording fake whose only job is to capture the raw
      # bytes received on stdin, then assert the exact sequence.
      tmp_dir = System.tmp_dir!()
      uniq = System.unique_integer([:positive])
      tmp = Path.join(tmp_dir, "player_test_stdin_#{uniq}.log")
      recorder = Path.join(tmp_dir, "player_test_stdin_recorder_#{uniq}.sh")

      on_exit(fn ->
        File.rm(tmp)
        File.rm(recorder)
      end)

      File.write!(recorder, """
      #!/bin/sh
      echo '{"event":"started","name":"x","client_id":"x","mdns_port":0,"alsa_device":"x","server":"","initial_volume":0}'
      cat > "#{tmp}"
      """)

      File.chmod!(recorder, 0o755)

      pid = start_player!(binary_path: recorder, mdns_port: 19_001)
      assert_receive {:sendspin_state, @key, %{event: "started"}}, 2_000

      :ok = Player.set_volume(pid, 80)
      :ok = Player.set_muted(pid, true)

      # GenServer.stop sends shutdown JSON then closes the port,
      # which flushes our recorder's `cat` to disk.
      :ok = GenServer.stop(pid, :normal, 2_000)

      lines = tmp |> File.read!() |> String.split("\n", trim: true)

      assert ~s({"cmd":"set_volume","value":80}) in lines
      assert ~s({"cmd":"set_muted","value":true}) in lines
      assert ~s({"cmd":"shutdown"}) in lines
    end
  end

  describe "set_muted/2" do
    test "writes JSON to stdin and the fake echoes back via PubSub" do
      pid = start_player!()
      assert_receive {:sendspin_state, @key, %{event: "started"}}, 2_000

      :ok = Player.set_muted(pid, true)
      assert_receive {:sendspin_state, @key, %{event: "mute", value: true}}, 1_000

      :ok = Player.set_muted(pid, false)
      assert_receive {:sendspin_state, @key, %{event: "mute", value: false}}, 1_000
    end
  end

  describe "termination" do
    test "sends shutdown command and removes the mDNS service" do
      pid = start_player!()
      assert_receive {:sendspin_state, @key, %{event: "started"}}, 2_000

      :ok = GenServer.stop(pid, :normal, 2_000)
      refute Process.alive?(pid)

      calls = MdnsStub.calls()
      assert {:remove, {:sendspin_player, "bcm2835 Headphones", nil, nil}} in calls
    end
  end

  describe "binary unexpected exit" do
    test "Player stops with {:binary_exited, status} when the binary exits abnormally" do
      # `trap_exit` so we can observe the Player's exit reason instead
      # of having the EXIT signal kill the test process. Restored at
      # end of test to avoid leaking into the next test.
      Process.flag(:trap_exit, true)
      on_exit(fn -> Process.flag(:trap_exit, false) end)

      pid = start_player!()
      assert_receive {:sendspin_state, @key, %{event: "started"}}, 2_000

      ref = Process.monitor(pid)
      :ok = Player.__send_command__(pid, %{cmd: "force_exit"})

      # The fake exits with status 7 → Player's handle_info({:exit_status, 7})
      # returns {:stop, {:binary_exited, 7}, state} → DOWN delivers.
      assert_receive {:DOWN, ^ref, :process, ^pid, {:binary_exited, 7}}, 2_000

      # MdnsLite remove must still run from terminate/2 — supervised
      # cleanup must not skip on abnormal exit.
      assert {:remove, {:sendspin_player, "bcm2835 Headphones", nil, nil}} in MdnsStub.calls()
    end
  end

  describe "JSON atom contract" do
    test "stream_start events round-trip through Jason.decode" do
      # The binary emits `stream_start` with `sample_rate`/`channels`/
      # `bit_depth`/`codec` — keys that may not exist as atoms at the
      # time decode runs. We use `keys: :atoms` (NOT `:atoms!`) so
      # Jason interns them on the fly. The binary's emit_json call
      # sites in main.cpp define a closed key set, so unbounded atom
      # growth is not a concern. Caught when an earlier attempt with
      # `:atoms!` + a module-attribute "interning" trick failed at
      # runtime because dead-code elimination dropped the literal.
      tmp_dir = System.tmp_dir!()

      stream_fake =
        Path.join(tmp_dir, "player_stream_start_fake_#{System.unique_integer([:positive])}.sh")

      on_exit(fn -> File.rm(stream_fake) end)

      File.write!(stream_fake, """
      #!/bin/sh
      echo '{"event":"started","name":"x","client_id":"x","mdns_port":0,"alsa_device":"x","server":"","initial_volume":0}'
      echo '{"event":"stream_start","sample_rate":44100,"channels":2,"bit_depth":16,"codec":"flac"}'
      # Keep the process alive so terminate/2 runs the shutdown handshake.
      exec cat
      """)

      File.chmod!(stream_fake, 0o755)

      pid = start_player!(binary_path: stream_fake, mdns_port: 19_100)

      # Drain the `started` event, then wait for `stream_start`.
      assert_receive {:sendspin_state, @key, %{event: "started"}}, 2_000

      assert_receive {:sendspin_state, @key,
                      %{
                        event: "stream_start",
                        sample_rate: 44_100,
                        channels: 2,
                        bit_depth: 16,
                        codec: "flac"
                      }},
                     1_000

      # And the cache must hold the latest parsed event.
      assert %{event: "stream_start", codec: "flac"} = Player.last_event(pid)
    end
  end

  describe "last_event/1" do
    test "caches the most recent event for late subscribers" do
      pid = start_player!()
      assert_receive {:sendspin_state, @key, _started}, 1_000

      :ok = Player.set_volume(pid, 33)
      assert_receive {:sendspin_state, @key, %{event: "volume", value: 33}}, 1_000

      assert %{event: "volume", value: 33} = Player.last_event(pid)
    end
  end
end
