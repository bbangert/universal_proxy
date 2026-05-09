defmodule UniversalProxy.ESPHome.ZWaveProxyTest do
  # Each test gets its own unnamed GenServer (pid only — no atom leakage)
  # and no UART hardware (port_path: nil).
  use ExUnit.Case, async: true

  alias UniversalProxy.ESPHome.ZWaveProxy

  setup do
    pid = start_supervised!({ZWaveProxy, name: nil, port_path: nil})
    {:ok, server: pid}
  end

  describe "without hardware" do
    test "available? returns false", %{server: server} do
      refute ZWaveProxy.available?(server)
    end

    test "home_id returns 0 when no controller", %{server: server} do
      assert ZWaveProxy.home_id(server) == 0
    end

    test "subscribe is rejected with :unavailable", %{server: server} do
      assert {:error, :unavailable} = ZWaveProxy.subscribe(server, self())
    end

    test "send_frame returns {:error, :unavailable}", %{server: server} do
      assert {:error, :unavailable} = ZWaveProxy.send_frame(server, <<1, 2, 3>>)
    end

    test "unsubscribe is idempotent for an unknown pid", %{server: server} do
      assert :ok = ZWaveProxy.unsubscribe(server, self())
    end
  end

  describe "callbacks tolerate a dead/missing server" do
    setup do
      {:ok, pid} = ZWaveProxy.start_link(name: nil, port_path: nil)
      ref = Process.monitor(pid)
      GenServer.stop(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
      {:ok, dead: pid}
    end

    test "available? returns false", %{dead: pid} do
      refute ZWaveProxy.available?(pid)
    end

    test "home_id returns 0", %{dead: pid} do
      assert ZWaveProxy.home_id(pid) == 0
    end

    test "subscribe returns {:error, :unavailable}", %{dead: pid} do
      assert {:error, :unavailable} = ZWaveProxy.subscribe(pid, self())
    end

    test "unsubscribe returns :ok (idempotent)", %{dead: pid} do
      assert :ok = ZWaveProxy.unsubscribe(pid, self())
    end

    test "send_frame returns {:error, :unavailable}", %{dead: pid} do
      assert {:error, :unavailable} = ZWaveProxy.send_frame(pid, <<1>>)
    end
  end
end
