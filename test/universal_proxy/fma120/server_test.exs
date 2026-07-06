defmodule UniversalProxy.FMA120.ServerTest do
  use ExUnit.Case, async: false

  alias UniversalProxy.FMA120.Server

  @key {"1-1.3", 0x0A12, 0x4007}

  # Minimal worker stand-in: a GenServer that records its start opts and
  # serves a canned cache. No UART.
  defmodule StubWorker do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def get_state(pid), do: GenServer.call(pid, :get_state)
    @impl true
    def init(opts), do: {:ok, %{opts: opts, cache: %{version: "stub", usb_port: opts[:usb_port]}}}
    @impl true
    def handle_call(:get_state, _from, s), do: {:reply, s.cache, s}
  end

  # Fails its first start_link (simulating UART-busy at boot), succeeds after.
  defmodule FlakyWorker do
    use GenServer

    def start_link(opts) do
      n = Application.get_env(:universal_proxy, :fma_flaky_attempts, 0) + 1
      Application.put_env(:universal_proxy, :fma_flaky_attempts, n)
      if n == 1, do: {:error, :busy}, else: GenServer.start_link(__MODULE__, opts)
    end

    def get_state(pid), do: GenServer.call(pid, :get_state)
    @impl true
    def init(opts), do: {:ok, %{opts: opts}}
    @impl true
    def handle_call(:get_state, _from, s), do: {:reply, %{}, s}
  end

  # Hardware stand-in driven by Application env per test.
  defmodule StubHW do
    def list_ports, do: Application.get_env(:universal_proxy, :fma_test_ports, [])
    def live_port_keys, do: Application.get_env(:universal_proxy, :fma_test_keys, %{})
  end

  defp port(opts) do
    %{
      connected: Keyword.get(opts, :connected, true),
      kind: Keyword.get(opts, :kind, :bt_audio),
      vendor_id: 0x0A12,
      product_id: 0x4007,
      slot_sub: "1-1.3",
      tty_name: "ttyACM0"
    }
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:universal_proxy, :fma_test_ports)
      Application.delete_env(:universal_proxy, :fma_test_keys)
      Application.delete_env(:universal_proxy, :fma_flaky_attempts)
    end)

    sup_name = :"wsup_#{System.unique_integer([:positive])}"
    start_supervised!({DynamicSupervisor, name: sup_name, strategy: :one_for_one})
    {:ok, sup: sup_name}
  end

  # `fast_crash_window_ms: 0` disables the fast-crash backoff so the
  # legacy lifecycle tests keep exercising the inline-restart path; the
  # "fast-crash backoff" describe block overrides it.
  defp start_server(sup, worker_module \\ StubWorker, opts \\ []) do
    name = :"fma_srv_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {Server,
         Keyword.merge(
           [
             name: name,
             subscribe: false,
             worker_module: worker_module,
             worker_supervisor: sup,
             hardware: StubHW,
             fast_crash_window_ms: 0
           ],
           opts
         )},
        id: name
      )

    pid
  end

  defp wait_until(fun, tries \\ 100)
  defp wait_until(_fun, 0), do: flunk("condition not met in time")

  defp wait_until(fun, tries) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, tries - 1)
    end
  end

  describe "initial inventory" do
    test "starts a worker per connected FMA120 port", %{sup: sup} do
      Application.put_env(:universal_proxy, :fma_test_ports, [port([])])
      srv = start_server(sup)

      assert [%{key: @key, connected: true, port_path: "ttyACM0"}] = Server.list_devices(srv)
      assert length(DynamicSupervisor.which_children(sup)) == 1
    end

    test "ignores non-bt_audio and disconnected ports", %{sup: sup} do
      ports = [port(kind: :ir), port(connected: false)]
      Application.put_env(:universal_proxy, :fma_test_ports, ports)
      srv = start_server(sup)

      assert Server.list_devices(srv) == []
    end
  end

  describe "hotplug via audio events" do
    test "output_added starts a worker after correlating the ttyACM", %{sup: sup} do
      Application.put_env(:universal_proxy, :fma_test_keys, %{@key => "ttyACM0"})
      srv = start_server(sup)
      assert Server.list_devices(srv) == []

      send(srv, {:sendspin_output_added, %{key: @key, usb_port: "1-1.3"}})

      assert [%{key: @key, connected: true}] = Server.list_devices(srv)
    end

    test "output_added for a non-FMA120 key is ignored", %{sup: sup} do
      srv = start_server(sup)
      send(srv, {:sendspin_output_added, %{key: {"1-1.2", 0x1234, 0x5678}, usb_port: "1-1.2"}})
      assert Server.list_devices(srv) == []
    end

    test "retries a device whose worker failed to start, on the next output_added",
         %{sup: sup} do
      Application.put_env(:universal_proxy, :fma_test_keys, %{@key => "ttyACM0"})
      srv = start_server(sup, FlakyWorker)

      # First attempt: FlakyWorker.start_link returns {:error, :busy} → the
      # entry is kept but with no live worker.
      send(srv, {:sendspin_output_added, %{key: @key, usb_port: "1-1.3"}})
      assert [%{key: @key, connected: false}] = Server.list_devices(srv)

      # A later output event must retry rather than be ignored as "present".
      send(srv, {:sendspin_output_added, %{key: @key, usb_port: "1-1.3"}})
      assert [%{key: @key, connected: true}] = Server.list_devices(srv)
    end

    test "output_removed stops the matching worker", %{sup: sup} do
      Application.put_env(:universal_proxy, :fma_test_keys, %{@key => "ttyACM0"})
      srv = start_server(sup)
      send(srv, {:sendspin_output_added, %{key: @key, usb_port: "1-1.3"}})
      assert [%{connected: true}] = Server.list_devices(srv)

      send(srv, {:sendspin_output_removed, %{key: @key}})
      assert Server.list_devices(srv) == []
      assert DynamicSupervisor.which_children(sup) == []
    end
  end

  describe "worker crash restart" do
    test "restarts the worker on :DOWN while the device is still present", %{sup: sup} do
      Application.put_env(:universal_proxy, :fma_test_ports, [port([])])
      Application.put_env(:universal_proxy, :fma_test_keys, %{@key => "ttyACM0"})
      srv = start_server(sup)

      [{_, pid, _, _}] = DynamicSupervisor.which_children(sup)
      Process.exit(pid, :kill)

      wait_until(fn ->
        case DynamicSupervisor.which_children(sup) do
          [{_, new_pid, _, _}] when is_pid(new_pid) and new_pid != pid -> true
          _ -> false
        end
      end)

      assert [%{connected: true}] = Server.list_devices(srv)
    end

    test "drops the entry on :DOWN when the device is gone", %{sup: sup} do
      Application.put_env(:universal_proxy, :fma_test_ports, [port([])])
      Application.put_env(:universal_proxy, :fma_test_keys, %{@key => "ttyACM0"})
      srv = start_server(sup)

      [{_, pid, _, _}] = DynamicSupervisor.which_children(sup)
      # Device unplugged: tty no longer resolves.
      Application.put_env(:universal_proxy, :fma_test_keys, %{})
      Process.exit(pid, :kill)

      wait_until(fn -> Server.list_devices(srv) == [] end)
    end
  end

  # Starts fine, then crashes immediately (a broken device would do this
  # on every respawn — the tight loop F5 the backoff exists for).
  defmodule CrashingWorker do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def get_state(pid), do: GenServer.call(pid, :get_state)
    @impl true
    def init(_opts), do: {:ok, nil, {:continue, :die}}
    @impl true
    def handle_continue(:die, state), do: {:stop, :simulated_device_fault, state}
  end

  describe "fast-crash backoff" do
    test "a fast-crashing worker is parked with a delayed retry, not hot-looped",
         %{sup: sup} do
      Application.put_env(:universal_proxy, :fma_test_ports, [port([])])
      Application.put_env(:universal_proxy, :fma_test_keys, %{@key => "ttyACM0"})

      srv =
        start_server(sup, CrashingWorker,
          fast_crash_window_ms: 5_000,
          retry_backoff_base_ms: 100
        )

      # After the first crash the entry parks (no live pid) with a retry
      # timer, instead of respawning inline in a tight loop.
      wait_until(fn ->
        case :sys.get_state(srv).inventory do
          [entry] ->
            entry.worker_pid == nil and is_reference(entry.retry_timer) and
              entry.crash_count >= 1

          _ ->
            false
        end
      end)

      [%{crash_count: first_count}] = :sys.get_state(srv).inventory

      # The retry timer (not a hot loop) drives the next attempt, which
      # crashes again and grows the tally/backoff.
      wait_until(fn ->
        case :sys.get_state(srv).inventory do
          [entry] -> entry.crash_count > first_count
          _ -> false
        end
      end)
    end

    test "unplug while parked cancels the retry", %{sup: sup} do
      Application.put_env(:universal_proxy, :fma_test_ports, [port([])])
      Application.put_env(:universal_proxy, :fma_test_keys, %{@key => "ttyACM0"})

      srv =
        start_server(sup, CrashingWorker,
          fast_crash_window_ms: 5_000,
          retry_backoff_base_ms: 60_000
        )

      wait_until(fn ->
        case :sys.get_state(srv).inventory do
          [entry] -> entry.worker_pid == nil and is_reference(entry.retry_timer)
          _ -> false
        end
      end)

      [%{retry_timer: timer}] = :sys.get_state(srv).inventory

      send(srv, {:sendspin_output_removed, %{key: @key}})
      assert Server.list_devices(srv) == []

      # Prove the timer was actually cancelled, not merely unfired (the
      # 60 s base above guarantees it couldn't have fired on its own).
      assert Process.read_timer(timer) == false
    end
  end

  describe "call_worker/2 timeout conversion" do
    test "a wedged worker call returns {:error, :timeout} instead of exiting" do
      # A process that never replies — the shape of a wedged DeviceWorker.
      # Killed in on_exit: a linked process survives the test process's
      # :normal exit and would otherwise leak for the whole BEAM run.
      wedged = spawn_link(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(wedged, :kill) end)

      assert UniversalProxy.FMA120.call_worker(wedged, fn pid ->
               GenServer.call(pid, :anything, 100)
             end) == {:error, :timeout}
    end

    test "a worker that stops mid-call returns {:error, :unavailable} instead of exiting" do
      # The wedge-recovery path stops the worker with a non-normal
      # reason while callers may still be blocked in GenServer.call.
      dying = spawn(fn -> receive(do: (_ -> exit(:wedged_recovered))) end)

      assert UniversalProxy.FMA120.call_worker(dying, fn pid ->
               GenServer.call(pid, :anything, 1_000)
             end) == {:error, :unavailable}
    end
  end

  describe "get_state/2" do
    test "delegates to the worker's cache", %{sup: sup} do
      Application.put_env(:universal_proxy, :fma_test_ports, [port([])])
      srv = start_server(sup)

      assert {:ok, %{version: "stub", usb_port: "1-1.3"}} = Server.get_state(srv, @key)
      assert Server.get_state(srv, {"nope", 0, 0}) == {:error, :not_found}
    end
  end
end
