defmodule UniversalProxy.FMA120.ResilienceTest do
  @moduledoc "Phase 9: wedge watchdog, USB re-authorize recovery, FD state decode."
  use ExUnit.Case, async: false

  alias UniversalProxy.FMA120.{DeviceWorker, Protocol}

  @key {"1-1.3", 0x0A12, 0x4007}

  defmodule FakeUART do
    def start_link, do: Agent.start_link(fn -> %{} end)
    def open(_pid, _port, _opts), do: :ok
    def write(_pid, _data), do: :ok
    def close(_pid), do: :ok
    def stop(pid), do: Agent.stop(pid)
  end

  describe "FD state-byte decode" do
    test "fd_connection_state/1 empirical map" do
      assert Protocol.fd_connection_state(0xCC) == :connected
      assert Protocol.fd_connection_state(0xCB) == :disconnected
      assert Protocol.fd_connection_state(0xC3) == :idle
      assert Protocol.fd_connection_state(0xC5) == :idle
      # 0xC6 observed live on rpi3 for a paired-but-disconnected device.
      assert Protocol.fd_connection_state(0xC6) == :idle
      assert Protocol.fd_connection_state(0x00) == :unknown
      assert Protocol.fd_connection_state(nil) == :unknown
    end

    test "FD decode carries both the raw byte and the mapped state" do
      assert {:found_device, fd} = Protocol.decode("FD=00,905682D5F226,CC,00240404,Office BT")
      assert fd.state_byte == 0xCC
      assert fd.connection_state == :connected
    end
  end

  describe "wedge watchdog → USB re-authorize recovery" do
    test "stops with :wedged_recovered and toggles the authorized node after N VR timeouts" do
      root = Path.join(System.tmp_dir!(), "fma_sysfs_#{System.unique_integer([:positive])}")
      authorized = Path.join([root, "1-1.3", "authorized"])
      File.mkdir_p!(Path.dirname(authorized))
      File.write!(authorized, "1")
      on_exit(fn -> File.rm_rf(root) end)

      pid =
        start_supervised!(
          {DeviceWorker,
           port_path: "x",
           key: @key,
           usb_port: "1-1.3",
           uart_module: FakeUART,
           skip_handshake: true,
           watchdog_interval: nil,
           cmd_timeout: 40,
           allow_reauthorize: true,
           sysfs_root: root,
           reauthorize_pause: 5},
          restart: :temporary
        )

      ref = Process.monitor(pid)

      # Three VR queries with no reply → three consecutive VR timeouts → wedge.
      for _ <- 1..3, do: Task.start(fn -> DeviceWorker.query(pid, "VR") end)

      assert_receive {:DOWN, ^ref, :process, ^pid, :wedged_recovered}, 2_000
      # Node was toggled off→on; final state is authorized again.
      assert File.read!(authorized) == "1"
    end

    test "non-VR timeouts do not trip the wedge (idle queries time out normally)" do
      pid =
        start_supervised!(
          {DeviceWorker,
           port_path: "x",
           key: @key,
           uart_module: FakeUART,
           skip_handshake: true,
           watchdog_interval: nil,
           cmd_timeout: 30},
          restart: :temporary
        )

      ref = Process.monitor(pid)
      # Many idle state-query timeouts must NOT wedge the worker.
      for _ <- 1..5, do: Task.start(fn -> DeviceWorker.query(pid, "ST") end)

      refute_receive {:DOWN, ^ref, :process, ^pid, :wedged_recovered}, 500
      assert Process.alive?(pid)
    end
  end
end
