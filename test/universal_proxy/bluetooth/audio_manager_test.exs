defmodule UniversalProxy.Bluetooth.AudioManagerTest do
  # async: false — the mock Ops is a single globally-named Agent (MockOps), so
  # concurrent tests would clash on the registered name; tests also share the
  # bluetooth:audio/scan PubSub topics.
  use ExUnit.Case, async: false

  alias UniversalProxy.Bluetooth.{AudioManager, Settings}

  @pubsub UniversalProxy.PubSub
  @sink_uuid "0000110b-0000-1000-8000-00805f9b34fb"
  @audio_mac "AA:BB:CC:DD:EE:FF"
  @adapter "/org/bluez/hci0"
  @hs "11:22:33:44:55:66"
  @hs_path "/org/bluez/hci0/dev_11_22_33_44_55_66"
  @table :audio_manager_settings_test

  # Agent-backed mock of the Ops behaviour: returns configured results and
  # forwards each call to the test pid so we can assert the D-Bus sequence
  # without a controller. Ignores `conn`.
  defmodule MockOps do
    @behaviour UniversalProxy.Bluetooth.AudioManager.Ops
    use Agent

    def start_link(opts), do: Agent.start_link(fn -> Map.new(opts) end, name: __MODULE__)
    def configure(map), do: Agent.update(__MODULE__, &Map.merge(&1, map))
    defp cfg(key, default), do: Agent.get(__MODULE__, &Map.get(&1, key, default))

    defp record(call) do
      case cfg(:test_pid, nil) do
        pid when is_pid(pid) -> send(pid, {:ops, call})
        _ -> :ok
      end
    end

    @impl true
    def adapters_info(_c), do: cfg(:adapters, [])
    @impl true
    def managed_devices(_c), do: cfg(:devices, [])
    @impl true
    def start_discovery(_c, a), do: record({:start_discovery, a}) && cfg(:start_discovery, :ok)
    @impl true
    def stop_discovery(_c, a), do: record({:stop_discovery, a}) && :ok
    @impl true
    def pair(_c, p), do: record({:pair, p}) && cfg(:pair, :ok)
    @impl true
    def set_trusted(_c, p, v), do: record({:set_trusted, p, v}) && cfg(:set_trusted, :ok)
    @impl true
    def connect(_c, p), do: record({:connect, p}) && cfg(:connect, :ok)
    @impl true
    def disconnect(_c, p), do: record({:disconnect, p}) && :ok
    @impl true
    def remove(_c, a, p), do: record({:remove, a, p}) && :ok
  end

  setup do
    path = Path.join(System.tmp_dir!(), "am_settings_#{System.unique_integer([:positive])}.dets")
    on_exit(fn -> File.rm(path) end)

    settings = start_supervised!({Settings, name: nil, table: @table, dets_path: path})
    start_supervised!({MockOps, [test_pid: self(), adapters: []]})
    start_supervised!({Task.Supervisor, name: __MODULE__.TaskSup})

    :ok = Phoenix.PubSub.subscribe(@pubsub, "bluetooth:audio")
    :ok = Phoenix.PubSub.subscribe(@pubsub, "bluetooth:scan")

    {:ok, settings: settings, dets: path}
  end

  defp start_manager(settings, opts \\ []) do
    base = [
      name: nil,
      conn: nil,
      ops: MockOps,
      settings: settings,
      task_supervisor: __MODULE__.TaskSup,
      reconnect_on_boot: false
    ]

    start_supervised!({AudioManager, Keyword.merge(base, opts)})
  end

  # Configure MockOps so an :audio adapter resolves to @adapter.
  defp with_audio_adapter(settings) do
    :ok = Settings.set_role(settings, @audio_mac, :audio)
    MockOps.configure(%{adapters: [%{path: @adapter, address: @audio_mac}]})
  end

  describe "pure helpers" do
    test "audio_sink?/1 matches the A2DP sink UUID, case-insensitively" do
      assert AudioManager.audio_sink?([@sink_uuid])
      assert AudioManager.audio_sink?(["0000110B-0000-1000-8000-00805F9B34FB"])
      refute AudioManager.audio_sink?(["0000111e-0000-1000-8000-00805f9b34fb"])
      refute AudioManager.audio_sink?([])
      refute AudioManager.audio_sink?(nil)
    end

    test "reconnect_targets/2 selects only trusted, disconnected, sink, on-adapter" do
      devices = [
        # eligible
        dev(@hs_path, @hs, %{"Trusted" => true, "Connected" => false, "UUIDs" => [@sink_uuid]}),
        # already connected → skip
        dev("#{@adapter}/dev_A", "A", %{
          "Trusted" => true,
          "Connected" => true,
          "UUIDs" => [@sink_uuid]
        }),
        # not trusted → skip
        dev("#{@adapter}/dev_B", "B", %{
          "Trusted" => false,
          "Connected" => false,
          "UUIDs" => [@sink_uuid]
        }),
        # not a sink → skip
        dev("#{@adapter}/dev_C", "C", %{"Trusted" => true, "Connected" => false, "UUIDs" => []}),
        # different adapter → skip
        dev("/org/bluez/hci9/dev_D", "D", %{
          "Trusted" => true,
          "Connected" => false,
          "UUIDs" => [@sink_uuid]
        })
      ]

      assert AudioManager.reconnect_targets(devices, [@adapter]) == [@hs]
    end
  end

  describe "role enforcement (no :audio adapter)" do
    test "pair/connect/start_scan refuse without an audio adapter", %{settings: settings} do
      mgr = start_manager(settings)
      assert {:error, :no_audio_adapter} = AudioManager.pair(mgr, @hs)
      assert {:error, :no_audio_adapter} = AudioManager.connect(mgr, @hs)
      assert {:error, :no_audio_adapter} = AudioManager.start_scan(mgr)
    end

    test "an adapter with a non-:audio role does not count", %{settings: settings} do
      :ok = Settings.set_role(settings, @audio_mac, :proxy)
      MockOps.configure(%{adapters: [%{path: @adapter, address: @audio_mac}]})
      mgr = start_manager(settings)
      assert {:error, :no_audio_adapter} = AudioManager.pair(mgr, @hs)
    end
  end

  describe "pairing flow" do
    test "pair → trust → connect on success, with step + connected events", %{settings: settings} do
      with_audio_adapter(settings)
      mgr = start_manager(settings)

      assert :ok = AudioManager.pair(mgr, @hs)

      # D-Bus sequence on the resolved device path.
      assert_receive {:ops, {:pair, @hs_path}}
      assert_receive {:ops, {:set_trusted, @hs_path, true}}
      assert_receive {:ops, {:connect, @hs_path}}

      # PubSub step progression then connected.
      assert_receive {:bt_audio, :pairing, @hs, :pairing}
      assert_receive {:bt_audio, :pairing, @hs, :trusting}
      assert_receive {:bt_audio, :pairing, @hs, :connecting}
      assert_receive {:bt_audio, :pairing, @hs, :connected}
    end

    test "a rejected Pair maps to :rejected and stops the flow", %{settings: settings} do
      with_audio_adapter(settings)
      MockOps.configure(%{pair: {:error, "org.bluez.Error.AuthenticationRejected"}})
      mgr = start_manager(settings)

      # Accepted synchronously; the failure surfaces over PubSub.
      assert :ok = AudioManager.pair(mgr, @hs)
      assert_receive {:bt_audio, :pairing, @hs, {:error, :rejected}}
      # Never advanced to trust/connect.
      refute_receive {:ops, {:set_trusted, _, _}}, 250
    end

    test "a ConnectionAttemptFailed at connect maps to :out_of_range", %{settings: settings} do
      with_audio_adapter(settings)
      MockOps.configure(%{connect: {:error, "org.bluez.Error.ConnectionAttemptFailed"}})
      mgr = start_manager(settings)

      assert :ok = AudioManager.pair(mgr, @hs)
      assert_receive {:ops, {:set_trusted, @hs_path, true}}
      assert_receive {:bt_audio, :pairing, @hs, {:error, :out_of_range}}
    end

    test "a GenServer.call timeout (exit tuple) maps to :timeout", %{settings: settings} do
      with_audio_adapter(settings)
      MockOps.configure(%{pair: {:error, {:exit, :timeout}}})
      mgr = start_manager(settings)

      assert :ok = AudioManager.pair(mgr, @hs)
      assert_receive {:bt_audio, :pairing, @hs, {:error, :timeout}}
    end
  end

  describe "connect/1 (async via Task.Supervisor)" do
    test "issues Connect and broadcasts :connected on success", %{settings: settings} do
      with_audio_adapter(settings)
      mgr = start_manager(settings)

      assert :ok = AudioManager.connect(mgr, @hs)
      assert_receive {:ops, {:connect, @hs_path}}
      assert_receive {:bt_audio, :connection, @hs, :connected}
    end
  end

  describe "reconnect on boot" do
    test "issues Connect for each trusted audio headset", %{settings: settings} do
      with_audio_adapter(settings)

      MockOps.configure(%{
        devices: [
          dev(@hs_path, @hs, %{"Trusted" => true, "Connected" => false, "UUIDs" => [@sink_uuid]})
        ]
      })

      # reconnect_on_boot: true triggers the {:continue, :reconnect}.
      _mgr = start_manager(settings, reconnect_on_boot: true)

      assert_receive {:ops, {:connect, @hs_path}}
      assert_receive {:bt_audio, :connection, @hs, :connected}
    end

    test "does nothing when there is no audio adapter", %{settings: settings} do
      MockOps.configure(%{
        devices: [
          dev(@hs_path, @hs, %{"Trusted" => true, "Connected" => false, "UUIDs" => [@sink_uuid]})
        ]
      })

      _mgr = start_manager(settings, reconnect_on_boot: true)
      refute_receive {:ops, {:connect, _}}, 150
    end
  end

  describe "scan lifecycle" do
    test "start_scan issues SetDiscoveryFilter+StartDiscovery; auto-stop broadcasts stopped", %{
      settings: settings
    } do
      with_audio_adapter(settings)
      mgr = start_manager(settings, scan_ms: 30)

      assert :ok = AudioManager.start_scan(mgr)
      assert_receive {:ops, {:start_discovery, @adapter}}

      # Auto-stop after scan_ms.
      assert_receive {:bt_scan, :stopped}, 500
      assert_receive {:ops, {:stop_discovery, @adapter}}
    end
  end

  defp dev(path, mac, props), do: %{path: path, mac: mac, props: props}
end
