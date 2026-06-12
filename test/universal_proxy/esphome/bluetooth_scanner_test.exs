defmodule UniversalProxy.ESPHome.BluetoothScannerTest do
  # Unit tests for the passive BLE scanner adapter. The adapter is a pure
  # set of functions over a duplicate-key Registry (no GenServer, no
  # BlueHeron dep), so we exercise it on the host by starting that registry
  # in setup and feeding it plain-map "Device" fixtures — the same shape
  # BlueHeron.Observer hands the callback on hardware.
  use ExUnit.Case, async: true

  alias UniversalProxy.ESPHome.BluetoothScanner

  # The Client's :persistent_term key for the HA-configured scanner mode
  # (private @mode_key in UniversalProxy.Bluez.Client).
  @mode_key {UniversalProxy.Bluez.Client, :configured_mode}

  # Stands in for UniversalProxy.Bluez.Client on the host: registers under
  # the real module name (never started outside the rpi3 target) and answers
  # {:set_mode, mode} with a canned reply.
  defmodule FakeClient do
    use GenServer

    def start_link(reply),
      do: GenServer.start_link(__MODULE__, reply, name: UniversalProxy.Bluez.Client)

    @impl GenServer
    def init(reply), do: {:ok, reply}

    @impl GenServer
    def handle_call({:set_mode, _mode}, _from, reply), do: {:reply, reply, reply}
  end

  setup context do
    # Fresh, isolated registry per test (torn down automatically). The name
    # is the same global one the adapter dispatches over. Tag a test
    # `:no_registry` to exercise the defensive path with the registry absent.
    unless context[:no_registry] do
      start_supervised!({Registry, keys: :duplicate, name: BluetoothScanner.registry_name()})
    end

    :ok
  end

  # A Device-shaped map. rss defaults to 200 to exercise the signed-RSSI
  # two's-complement path (200 -> -56 dBm).
  defp device(overrides \\ []) do
    Enum.into(overrides, %{
      event_type: 0,
      address_type: 0,
      address: 0x112233445566,
      rss: 200,
      data: [],
      raw_data: <<0x02, 0x01, 0x06>>
    })
  end

  # Spawn a process that subscribes in its OWN context (mirrors espex
  # calling adapter.subscribe(self()) in the connection-handler process) and
  # relays everything it receives back to the test, tagged.
  defp start_subscriber(test_pid, tag) do
    pid =
      spawn(fn ->
        BluetoothScanner.subscribe(self())
        send(test_pid, {:ready, tag})
        relay(test_pid, tag)
      end)

    # Unsupervised + infinite receive loop — kill it at test end so these
    # don't leak across the suite.
    on_exit(fn -> Process.exit(pid, :kill) end)
    assert_receive {:ready, ^tag}
    pid
  end

  defp relay(test_pid, tag) do
    receive do
      msg ->
        send(test_pid, {tag, msg})
        relay(test_pid, tag)
    end
  end

  defp wait_until(fun, retries \\ 50)
  defp wait_until(_fun, 0), do: flunk("condition not met in time")

  defp wait_until(fun, retries) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, retries - 1)
    end
  end

  describe "on_advertisement/1 mapping (E1)" do
    test "maps a Device to the espex advertisement tuple with signed RSSI" do
      BluetoothScanner.subscribe(self())

      assert :ok = BluetoothScanner.on_advertisement(device(rss: 200, address_type: 0))

      assert_receive {:espex_ble_advertisement, 0x112233445566, -56, 0, <<0x02, 0x01, 0x06>>}
    end

    test "passes address_type through (random = 1) and positive RSSI unchanged" do
      BluetoothScanner.subscribe(self())

      assert :ok = BluetoothScanner.on_advertisement(device(rss: 42, address_type: 1))

      assert_receive {:espex_ble_advertisement, _addr, 42, 1, _data}
    end

    test "forwards raw_data verbatim (length prefixes intact)" do
      BluetoothScanner.subscribe(self())
      raw = <<0x06, 0x16, 0xD2, 0xFC, 0x40, 0x00, 0xC4>>

      BluetoothScanner.on_advertisement(device(raw_data: raw))

      assert_receive {:espex_ble_advertisement, _addr, _rssi, _type, ^raw}
    end

    test "skips advertisements whose raw_data is nil" do
      BluetoothScanner.subscribe(self())

      assert :ok = BluetoothScanner.on_advertisement(device(raw_data: nil))

      refute_receive {:espex_ble_advertisement, _, _, _, _}
    end
  end

  describe "fan-out and auto-cleanup (E2)" do
    test "every subscriber receives each advertisement" do
      start_subscriber(self(), :a)
      start_subscriber(self(), :b)

      BluetoothScanner.on_advertisement(device())

      assert_receive {:a, {:espex_ble_advertisement, _, _, _, _}}
      assert_receive {:b, {:espex_ble_advertisement, _, _, _, _}}
    end

    test "a dead subscriber is auto-removed; survivors keep receiving" do
      registry = BluetoothScanner.registry_name()
      pid_a = start_subscriber(self(), :a)
      start_subscriber(self(), :b)

      assert Registry.count(registry) == 2

      Process.exit(pid_a, :kill)
      # Registry monitors registered pids and removes them asynchronously.
      wait_until(fn -> Registry.count(registry) == 1 end)

      BluetoothScanner.on_advertisement(device())

      assert_receive {:b, {:espex_ble_advertisement, _, _, _, _}}
      refute_receive {:a, {:espex_ble_advertisement, _, _, _, _}}
    end
  end

  describe "subscribe/1 and unsubscribe/1 (E3)" do
    test "subscribe sends the initial running/passive scanner state" do
      assert :ok = BluetoothScanner.subscribe(self())

      assert_receive {:espex_ble_scanner_state, :running, :passive, :passive}
    end

    test "subscribe is idempotent — a re-subscribe never double-delivers" do
      assert :ok = BluetoothScanner.subscribe(self())
      assert :ok = BluetoothScanner.subscribe(self())
      assert_receive {:espex_ble_scanner_state, :running, :passive, :passive}
      assert_receive {:espex_ble_scanner_state, :running, :passive, :passive}

      assert Registry.count(BluetoothScanner.registry_name()) == 1

      BluetoothScanner.on_advertisement(device())
      assert_receive {:espex_ble_advertisement, _, _, _, _}
      refute_receive {:espex_ble_advertisement, _, _, _, _}
    end

    test "unsubscribe is idempotent and stops delivery" do
      BluetoothScanner.subscribe(self())
      assert_receive {:espex_ble_scanner_state, :running, :passive, :passive}

      assert :ok = BluetoothScanner.unsubscribe(self())
      assert :ok = BluetoothScanner.unsubscribe(self())

      BluetoothScanner.on_advertisement(device())
      refute_receive {:espex_ble_advertisement, _, _, _, _}
    end
  end

  describe "scanner mode (E4)" do
    test "set_scanner_mode/1 IS exported so espex advertises STATE_AND_MODE (0x61)" do
      Code.ensure_loaded!(BluetoothScanner)

      assert function_exported?(BluetoothScanner, :set_scanner_mode, 1)
    end

    test "without the BlueZ Client running, both modes are {:error, :unavailable}" do
      # GenServer.call to the absent Client exits (:noproc) — the adapter must
      # catch :exit (NOT rescue ArgumentError, the registry's failure mode).
      assert {:error, :unavailable} = BluetoothScanner.set_scanner_mode(:passive)
      assert {:error, :unavailable} = BluetoothScanner.set_scanner_mode(:active)
    end

    test "delegates to the Client and broadcasts the new mode to every subscriber" do
      start_supervised!({FakeClient, :ok})
      start_subscriber(self(), :a)
      start_subscriber(self(), :b)
      # Initial subscribe states — drain so the broadcast assertion is clean.
      assert_receive {:a, {:espex_ble_scanner_state, :running, _, _}}
      assert_receive {:b, {:espex_ble_scanner_state, :running, _, _}}

      assert :ok = BluetoothScanner.set_scanner_mode(:active)

      assert_receive {:a, {:espex_ble_scanner_state, :running, :active, :active}}
      assert_receive {:b, {:espex_ble_scanner_state, :running, :active, :active}}
    end

    test "a Client error passes through and nothing is broadcast" do
      start_supervised!({FakeClient, {:error, "org.bluez.Error.NotReady"}})
      BluetoothScanner.subscribe(self())
      assert_receive {:espex_ble_scanner_state, :running, _, _}

      assert {:error, "org.bluez.Error.NotReady"} = BluetoothScanner.set_scanner_mode(:active)

      refute_receive {:espex_ble_scanner_state, _, _, _}
    end
  end

  describe "configured-mode reporting (E5)" do
    test "subscribe reports the persisted configured mode, not hardcoded :passive" do
      :persistent_term.put(@mode_key, :active)
      on_exit(fn -> :persistent_term.erase(@mode_key) end)

      BluetoothScanner.subscribe(self())

      assert_receive {:espex_ble_scanner_state, :running, :active, :active}
    end

    test "defaults to :passive when nothing was ever configured" do
      :persistent_term.erase(@mode_key)

      BluetoothScanner.subscribe(self())

      assert_receive {:espex_ble_scanner_state, :running, :passive, :passive}
    end
  end

  # The registry raises ArgumentError ("unknown registry") when absent — not
  # an exit — so the adapter must `rescue ArgumentError`, not `catch :exit`.
  describe "defensive: registry not started" do
    @tag :no_registry
    test "subscribe returns {:error, :unavailable} instead of raising" do
      assert {:error, :unavailable} = BluetoothScanner.subscribe(self())
      refute_receive {:espex_ble_scanner_state, _, _, _}
    end

    @tag :no_registry
    test "unsubscribe returns :ok instead of raising" do
      assert :ok = BluetoothScanner.unsubscribe(self())
    end

    @tag :no_registry
    test "on_advertisement returns :ok instead of raising" do
      assert :ok = BluetoothScanner.on_advertisement(device())
    end
  end
end
