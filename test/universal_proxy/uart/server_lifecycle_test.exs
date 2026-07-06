defmodule UniversalProxy.UART.ServerLifecycleTest do
  # Manipulates the globally-supervised UART subsystem (kills the Server,
  # adds/removes PortSupervisor children), so it must not run alongside
  # other tests touching the same tree.
  use ExUnit.Case, async: false

  alias UniversalProxy.UART.PortSupervisor
  alias UniversalProxy.UART.Server

  defp port_count do
    %{active: active} = DynamicSupervisor.count_children(PortSupervisor)
    active
  end

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  # Returns the condition's last evaluation — no extra fun.() after the
  # loop (which could double-run side effects or flip a transient
  # success back to failure).
  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(20)
        do_wait_until(fun, deadline)
    end
  end

  describe "port child restart semantics" do
    test "a normally-stopped port child is not respawned by the supervisor" do
      baseline = port_count()

      {:ok, pid} = DynamicSupervisor.start_child(PortSupervisor, Server.port_child_spec())
      assert port_count() == baseline + 1

      :ok = Circuits.UART.stop(pid)

      assert wait_until(fn -> port_count() == baseline end),
             "expected no orphan respawn after normal stop, count=#{port_count()}"
    end

    test "a killed port child is not respawned by the supervisor" do
      baseline = port_count()

      {:ok, pid} = DynamicSupervisor.start_child(PortSupervisor, Server.port_child_spec())
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert wait_until(fn -> port_count() == baseline end),
             "expected no orphan respawn after kill, count=#{port_count()}"
    end
  end

  describe "init orphan sweep" do
    test "a Server-only restart sweeps leftover PortSupervisor children" do
      {:ok, stray} = DynamicSupervisor.start_child(PortSupervisor, Server.port_child_spec())
      stray_ref = Process.monitor(stray)

      old_server = Process.whereis(Server)
      assert is_pid(old_server)
      Process.exit(old_server, :kill)

      assert wait_until(fn ->
               case Process.whereis(Server) do
                 nil -> false
                 pid -> pid != old_server and Process.alive?(pid)
               end
             end),
             "UART.Server was not restarted by its supervisor"

      assert_receive {:DOWN, ^stray_ref, :process, ^stray, _reason}, 2_000
      assert port_count() == 0
    end
  end
end
