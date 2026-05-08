defmodule UniversalProxy.ESPHome.ZWaveProxyTest do
  # Each test gets its own GenServer name + no UART hardware (port_path: nil).
  use ExUnit.Case, async: true

  alias UniversalProxy.ESPHome.ZWaveProxy

  setup do
    name = :"zwave_proxy_test_#{System.unique_integer([:positive])}"
    pid = start_supervised!({ZWaveProxy, name: name, port_path: nil})
    {:ok, server: pid, name: name}
  end

  describe "without hardware" do
    test "available? returns false", %{name: server} do
      refute ZWaveProxy.available?(server)
    end

    test "home_id returns 0 when no controller", %{name: server} do
      assert ZWaveProxy.home_id(server) == 0
    end

    test "subscribe is rejected with :unavailable", %{name: server} do
      assert {:error, :unavailable} = ZWaveProxy.subscribe(server, self())
    end

    test "send_frame returns {:error, :unavailable}", %{name: server} do
      assert {:error, :unavailable} = ZWaveProxy.send_frame(server, <<1, 2, 3>>)
    end

    test "unsubscribe is idempotent for an unknown pid", %{name: server} do
      assert :ok = ZWaveProxy.unsubscribe(server, self())
    end
  end

  describe "available?/0 / home_id/0 fallback" do
    test "returns false / 0 when the server is dead" do
      # Start a fresh instance, stop it, then call the public API targeting
      # that name — the catch :exit clause should kick in.
      name = :"zwave_proxy_dead_#{System.unique_integer([:positive])}"
      {:ok, pid} = ZWaveProxy.start_link(name: name, port_path: nil)
      ref = Process.monitor(pid)
      GenServer.stop(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      refute ZWaveProxy.available?(name)
      assert ZWaveProxy.home_id(name) == 0
    end
  end
end
