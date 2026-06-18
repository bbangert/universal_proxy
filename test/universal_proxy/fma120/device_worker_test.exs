defmodule UniversalProxy.FMA120.DeviceWorkerTest do
  use ExUnit.Case, async: false

  alias UniversalProxy.FMA120.DeviceWorker

  @port :fake_port
  @key {"1-1.3", 0x0A12, 0x4007}

  # Stub UART: forwards every write to the test controller pid (set in
  # Application env) and is otherwise inert. Replies are injected by sending
  # `{:circuits_uart, port, data}` straight to the worker (which is what
  # Circuits.UART does in active mode).
  defmodule FakeUART do
    def start_link, do: Agent.start_link(fn -> %{} end)
    def open(_pid, _port, _opts), do: :ok

    def write(_pid, data) do
      case Application.get_env(:universal_proxy, :fma120_test_controller) do
        pid when is_pid(pid) -> send(pid, {:uart_write, data})
        _ -> :ok
      end

      :ok
    end

    def close(_pid), do: :ok
    def stop(pid), do: Agent.stop(pid)
  end

  setup do
    Application.put_env(:universal_proxy, :fma120_test_controller, self())
    on_exit(fn -> Application.delete_env(:universal_proxy, :fma120_test_controller) end)
    :ok
  end

  defp start_worker(opts \\ []) do
    base = [
      port_path: "/dev/ttyACM0",
      key: @key,
      uart_module: FakeUART,
      cmd_timeout: 2_000,
      skip_handshake: true
    ]

    start_supervised!({DeviceWorker, Keyword.merge(base, opts)})
  end

  defp reply(pid, line), do: send(pid, {:circuits_uart, @port, line <> "\r\n"})

  describe "serialized command queue" do
    test "second command is not written until the first completes" do
      pid = start_worker()

      t1 = Task.async(fn -> DeviceWorker.command(pid, "AM", 0x01) end)
      assert_receive {:uart_write, "BC:AM=01\r\n"}, 500

      # Enqueue a second command while the first is in flight.
      t2 = Task.async(fn -> DeviceWorker.command(pid, "LF", 0x00) end)
      # Well under cmd_timeout (2000) so it can't false-pass on a slow runner.
      refute_receive {:uart_write, "BC:LF=00\r\n"}, 600

      # Completing the first releases the second.
      reply(pid, "OK")
      assert Task.await(t1) == :ok
      assert_receive {:uart_write, "BC:LF=00\r\n"}, 500

      reply(pid, "OK")
      assert Task.await(t2) == :ok
    end

    test "a query completes on its matching header reply" do
      pid = start_worker()
      t = Task.async(fn -> DeviceWorker.query(pid, "VR") end)
      assert_receive {:uart_write, "BC:VR\r\n"}, 500
      reply(pid, "VR=1.1.7G")
      assert Task.await(t) == {:ok, {:version, "1.1.7G"}}
    end

    test "a set-command completes on ER with the error code" do
      pid = start_worker()
      t = Task.async(fn -> DeviceWorker.command(pid, "TC", 0x00) end)
      assert_receive {:uart_write, "BC:TC=00\r\n"}, 500
      reply(pid, "ER=01")
      assert Task.await(t) == {:error, 1}
    end
  end

  describe "timeout handling" do
    test "a command times out (tolerated) and the next is sent" do
      pid = start_worker(cmd_timeout: 150)

      t1 = Task.async(fn -> DeviceWorker.command(pid, "AM", 0x00) end)
      assert_receive {:uart_write, "BC:AM=00\r\n"}, 500

      t2 = Task.async(fn -> DeviceWorker.query(pid, "VR") end)
      # No reply injected → the 200ms timer fires, completing t1 and sending t2.
      assert Task.await(t1, 1_000) == {:error, :timeout}
      assert_receive {:uart_write, "BC:VR\r\n"}, 1_000

      reply(pid, "VR=1.1.7G")
      assert Task.await(t2) == {:ok, {:version, "1.1.7G"}}
    end
  end

  describe "async state broadcast" do
    test "FD rows update the cache and broadcast on fma120:state regardless of in-flight" do
      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "fma120:state")
      pid = start_worker()

      reply(pid, "FD=00,905682D5F226,C5,00240404,Office BT")

      assert_receive {:fma120_state, @key, %{devices: devices}}, 500
      assert devices[0].name == "Office BT"
      assert devices[0].state_byte == 0xC5

      cache = DeviceWorker.get_state(pid)
      assert cache.devices[0].mac == "905682D5F226"
    end

    test "version reply caches and broadcasts" do
      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "fma120:state")
      pid = start_worker()

      t = Task.async(fn -> DeviceWorker.query(pid, "VR") end)
      assert_receive {:uart_write, "BC:VR\r\n"}, 500
      reply(pid, "VR=1.1.7G")
      assert Task.await(t) == {:ok, {:version, "1.1.7G"}}

      assert_receive {:fma120_state, @key, %{version: "1.1.7G"}}, 500
      assert DeviceWorker.get_state(pid).version == "1.1.7G"
    end
  end

  describe "init handshake" do
    test "queues VR first when handshake runs on open" do
      _pid = start_worker(skip_handshake: false)
      # First handshake command is VR; it must be the first thing written.
      assert_receive {:uart_write, "BC:VR\r\n"}, 500
      # AM must not be written until VR completes (serialization).
      refute_receive {:uart_write, "BC:AM\r\n"}, 200
    end
  end
end
