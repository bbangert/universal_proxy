defmodule UniversalProxy.BTD700.ResilienceTest do
  @moduledoc """
  Phase 4: `BTD700.Server` fast-crash backoff and post-restart lifecycle.
  Device-side wedge recovery (watchdog → USB re-authorize) is already
  covered end-to-end in `device_worker_test.exs`; this file exercises the
  Server's crash-parking/backoff/restart machinery in isolation, the same
  split FMA120 uses (`fma120/resilience_test.exs` is the template).
  """
  use ExUnit.Case, async: false

  alias UniversalProxy.BTD700.Server

  @key {"1-1.3.1", 0x3542, 0x3001}

  defmodule StubAudio do
    def list_outputs, do: Application.get_env(:universal_proxy, :btd700_res_test_outputs, [])
  end

  defmodule StubHidraw do
    def control_node(usb_port) do
      case Application.get_env(:universal_proxy, :btd700_res_test_hidraw, %{}) do
        %{^usb_port => path} -> {:ok, path}
        _ -> {:error, :not_found}
      end
    end
  end

  # Starts fine, then crashes immediately (a wedged dongle would do this on
  # every respawn — the tight loop the backoff exists to prevent).
  defmodule CrashingWorker do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def get_state(pid), do: GenServer.call(pid, :get_state)
    @impl true
    def init(_opts), do: {:ok, nil, {:continue, :die}}
    @impl true
    def handle_continue(:die, state), do: {:stop, :simulated_device_fault, state}
  end

  defp output do
    %{key: @key, usb_port: "1-1.3.1", vendor_id: 0x3542, product_id: 0x3001}
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:universal_proxy, :btd700_res_test_outputs)
      Application.delete_env(:universal_proxy, :btd700_res_test_hidraw)
    end)

    sup_name = :"btd700_res_wsup_#{System.unique_integer([:positive])}"
    start_supervised!({DynamicSupervisor, name: sup_name, strategy: :one_for_one})
    {:ok, sup: sup_name}
  end

  defp start_server(sup, worker_module, opts) do
    name = :"btd700_res_srv_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Server,
       Keyword.merge(
         [
           name: name,
           subscribe: false,
           worker_module: worker_module,
           worker_supervisor: sup,
           audio: StubAudio,
           hidraw: StubHidraw
         ],
         opts
       )},
      id: name
    )
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

  describe "fast-crash backoff" do
    test "a fast-crashing worker is parked with a delayed retry, not hot-looped", %{sup: sup} do
      Application.put_env(:universal_proxy, :btd700_res_test_outputs, [output()])

      Application.put_env(:universal_proxy, :btd700_res_test_hidraw, %{
        "1-1.3.1" => "/dev/hidraw3"
      })

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
      Application.put_env(:universal_proxy, :btd700_res_test_outputs, [output()])

      Application.put_env(:universal_proxy, :btd700_res_test_hidraw, %{
        "1-1.3.1" => "/dev/hidraw3"
      })

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

    test "a crash after a healthy run resets the backoff counter and restarts inline", %{
      sup: sup
    } do
      Application.put_env(:universal_proxy, :btd700_res_test_outputs, [output()])

      Application.put_env(:universal_proxy, :btd700_res_test_hidraw, %{
        "1-1.3.1" => "/dev/hidraw3"
      })

      # Long fast-crash window so the *first* respawn (inline, via :DOWN
      # below) is judged "healthy" only once it clears that window —
      # instead we prove the counter-reset the opposite way: a worker that
      # survives long enough between kills must not accumulate crash_count.
      defmodule HealthyThenExitWorker do
        use GenServer
        def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
        def get_state(pid), do: GenServer.call(pid, :get_state)
        @impl true
        def init(opts), do: {:ok, %{opts: opts}}
        @impl true
        def handle_call(:get_state, _from, s), do: {:reply, %{}, s}
      end

      srv =
        start_server(sup, HealthyThenExitWorker,
          fast_crash_window_ms: 10,
          retry_backoff_base_ms: 60_000
        )

      [{_, pid, _, _}] = DynamicSupervisor.which_children(sup)
      # Outlive the tiny fast_crash_window_ms so the next kill is judged a
      # "healthy run" — restarts inline with crash_count reset to 0, not
      # parked behind the (60 s) backoff.
      Process.sleep(50)
      Process.exit(pid, :kill)

      wait_until(fn ->
        case DynamicSupervisor.which_children(sup) do
          [{_, new_pid, _, _}] when is_pid(new_pid) and new_pid != pid -> true
          _ -> false
        end
      end)

      assert [%{connected: true, crash_count: 0}] = list_with_crash_count(srv)
    end
  end

  # `Server.list_devices/1` doesn't expose crash_count — read it straight
  # off the GenServer's internal inventory, same as the "fast-crash backoff"
  # tests above.
  defp list_with_crash_count(srv) do
    :sys.get_state(srv).inventory
    |> Enum.map(&%{connected: !!&1.worker_pid, crash_count: &1.crash_count})
  end

  describe "worker crash restart after wedge-recovery stop" do
    test ":DOWN with a wedge-recovery-shaped reason restarts on re-enumeration", %{sup: sup} do
      Application.put_env(:universal_proxy, :btd700_res_test_outputs, [output()])

      Application.put_env(:universal_proxy, :btd700_res_test_hidraw, %{
        "1-1.3.1" => "/dev/hidraw3"
      })

      defmodule WedgeStoppingWorker do
        use GenServer
        def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
        def get_state(pid), do: GenServer.call(pid, :get_state)
        @impl true
        def init(opts), do: {:ok, %{opts: opts}}
        @impl true
        def handle_call(:get_state, _from, s), do: {:reply, %{}, s}
      end

      srv = start_server(sup, WedgeStoppingWorker, fast_crash_window_ms: 0)

      [{_, pid, _, _}] = DynamicSupervisor.which_children(sup)
      # Simulate the DeviceWorker's own wedge-recovery stop: the Server only
      # ever learns about this via the ordinary `:DOWN` monitor message, the
      # same as any other worker exit (it doesn't distinguish stop reasons).
      Process.exit(pid, :wedged_recovered)

      wait_until(fn ->
        case DynamicSupervisor.which_children(sup) do
          [{_, new_pid, _, _}] when is_pid(new_pid) and new_pid != pid -> true
          _ -> false
        end
      end)

      assert [%{connected: true}] = Server.list_devices(srv)
    end
  end
end
