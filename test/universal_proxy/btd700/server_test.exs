defmodule UniversalProxy.BTD700.ServerTest do
  use ExUnit.Case, async: false

  alias UniversalProxy.BTD700.Server

  @key {"1-1.3.1", 0x3542, 0x3001}

  # Minimal worker stand-in: a GenServer that records its start opts and
  # serves a canned cache. No hidraw fds.
  defmodule StubWorker do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def get_state(pid), do: GenServer.call(pid, :get_state)
    @impl true
    def init(opts), do: {:ok, %{opts: opts, cache: %{version: "stub", usb_port: opts[:usb_port]}}}
    @impl true
    def handle_call(:get_state, _from, s), do: {:reply, s.cache, s}
  end

  # Fails its first start_link (simulating a busy hidraw open at boot),
  # succeeds after.
  defmodule FlakyWorker do
    use GenServer

    def start_link(opts) do
      n = Application.get_env(:universal_proxy, :btd700_flaky_attempts, 0) + 1
      Application.put_env(:universal_proxy, :btd700_flaky_attempts, n)
      if n == 1, do: {:error, :busy}, else: GenServer.start_link(__MODULE__, opts)
    end

    def get_state(pid), do: GenServer.call(pid, :get_state)
    @impl true
    def init(opts), do: {:ok, %{opts: opts}}
    @impl true
    def handle_call(:get_state, _from, s), do: {:reply, %{}, s}
  end

  # Audio stand-in driven by Application env per test.
  defmodule StubAudio do
    def list_outputs, do: Application.get_env(:universal_proxy, :btd700_test_outputs, [])
  end

  # Hidraw stand-in driven by Application env per test — a map of
  # `usb_port => "/dev/hidrawN"`, so a missing entry simulates the
  # enumeration race (control node not there yet).
  defmodule StubHidraw do
    def control_node(usb_port) do
      case Application.get_env(:universal_proxy, :btd700_test_hidraw, %{}) do
        %{^usb_port => path} -> {:ok, path}
        _ -> {:error, :not_found}
      end
    end
  end

  defp output(opts \\ []) do
    %{
      key: @key,
      usb_port: "1-1.3.1",
      vendor_id: 0x3542,
      product_id: 0x3001,
      friendly_name: "Sennheiser BTD 700"
    }
    |> Map.merge(Map.new(opts))
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:universal_proxy, :btd700_test_outputs)
      Application.delete_env(:universal_proxy, :btd700_test_hidraw)
      Application.delete_env(:universal_proxy, :btd700_flaky_attempts)
    end)

    sup_name = :"wsup_#{System.unique_integer([:positive])}"
    start_supervised!({DynamicSupervisor, name: sup_name, strategy: :one_for_one})
    {:ok, sup: sup_name}
  end

  # `fast_crash_window_ms: 0` disables the fast-crash backoff so the basic
  # lifecycle tests keep exercising the inline-restart path; the "fast-crash
  # backoff"/"hidraw enumeration race" describe blocks override it.
  defp start_server(sup, worker_module \\ StubWorker, opts \\ []) do
    name = :"btd700_srv_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Server,
       Keyword.merge(
         [
           name: name,
           subscribe: false,
           worker_module: worker_module,
           worker_supervisor: sup,
           audio: StubAudio,
           hidraw: StubHidraw,
           fast_crash_window_ms: 0
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

  describe "initial inventory" do
    test "starts a worker per connected BTD 700 output", %{sup: sup} do
      Application.put_env(:universal_proxy, :btd700_test_outputs, [output()])
      Application.put_env(:universal_proxy, :btd700_test_hidraw, %{"1-1.3.1" => "/dev/hidraw3"})
      srv = start_server(sup)

      assert [%{key: @key, connected: true, device_path: "/dev/hidraw3"}] =
               Server.list_devices(srv)

      assert length(DynamicSupervisor.which_children(sup)) == 1
    end

    test "ignores outputs with a different vendor/product id", %{sup: sup} do
      other = output(key: {"1-1.4", 0x1234, 0x5678}, usb_port: "1-1.4")
      Application.put_env(:universal_proxy, :btd700_test_outputs, [other])
      srv = start_server(sup)

      assert Server.list_devices(srv) == []
    end

    test "ignores a matching key with no usb_port (should never happen for a real BTD 700)",
         %{sup: sup} do
      no_port = output(key: {"1-1.3.1", 0x3542, 0x3001}, usb_port: nil)
      Application.put_env(:universal_proxy, :btd700_test_outputs, [no_port])
      srv = start_server(sup)

      assert Server.list_devices(srv) == []
    end
  end

  describe "hotplug via audio events" do
    test "output_added starts a worker after resolving the hidraw control node", %{sup: sup} do
      Application.put_env(:universal_proxy, :btd700_test_hidraw, %{"1-1.3.1" => "/dev/hidraw3"})
      srv = start_server(sup)
      assert Server.list_devices(srv) == []

      send(srv, {:sendspin_output_added, output()})

      assert [%{key: @key, connected: true, device_path: "/dev/hidraw3"}] =
               Server.list_devices(srv)
    end

    test "output_added for a non-BTD700 key is ignored", %{sup: sup} do
      srv = start_server(sup)
      other = output(key: {"1-1.2", 0x1234, 0x5678}, usb_port: "1-1.2")
      send(srv, {:sendspin_output_added, other})
      assert Server.list_devices(srv) == []
    end

    test "output_removed stops the matching worker", %{sup: sup} do
      Application.put_env(:universal_proxy, :btd700_test_hidraw, %{"1-1.3.1" => "/dev/hidraw3"})
      srv = start_server(sup)
      send(srv, {:sendspin_output_added, output()})
      assert [%{connected: true}] = Server.list_devices(srv)

      send(srv, {:sendspin_output_removed, %{key: @key}})
      assert Server.list_devices(srv) == []
      assert DynamicSupervisor.which_children(sup) == []
    end
  end

  describe "hidraw-not-yet-there retry race" do
    test "output_added parks the entry with a retry timer when the control node isn't found yet",
         %{sup: sup} do
      # No hidraw entry registered at all — simulates the sound card
      # enumerating before the hidraw node.
      srv = start_server(sup, StubWorker, fast_crash_window_ms: 5_000, retry_backoff_base_ms: 100)

      send(srv, {:sendspin_output_added, output()})

      assert [%{key: @key, connected: false}] = Server.list_devices(srv)

      wait_until(fn ->
        case :sys.get_state(srv).inventory do
          [entry] -> is_reference(entry.retry_timer) and is_nil(entry.device_path)
          _ -> false
        end
      end)

      # Once the control node "appears" (StubHidraw now resolves it), the
      # scheduled retry (not a bespoke sleep/poll) picks it up and starts
      # the worker — no second `:output_added` event needed.
      Application.put_env(:universal_proxy, :btd700_test_hidraw, %{"1-1.3.1" => "/dev/hidraw3"})

      wait_until(fn ->
        case Server.list_devices(srv) do
          [%{connected: true}] -> true
          _ -> false
        end
      end)
    end

    test "retries a device whose worker failed to start, on the next output_added", %{sup: sup} do
      Application.put_env(:universal_proxy, :btd700_test_hidraw, %{"1-1.3.1" => "/dev/hidraw3"})
      srv = start_server(sup, FlakyWorker)

      # First attempt: FlakyWorker.start_link returns {:error, :busy} → the
      # entry is kept but with no live worker.
      send(srv, {:sendspin_output_added, output()})
      assert [%{key: @key, connected: false}] = Server.list_devices(srv)

      # A later output event must retry rather than be ignored as "present".
      send(srv, {:sendspin_output_added, output()})
      assert [%{key: @key, connected: true}] = Server.list_devices(srv)
    end
  end

  describe "worker crash restart" do
    test "restarts the worker on :DOWN while the device is still present", %{sup: sup} do
      Application.put_env(:universal_proxy, :btd700_test_outputs, [output()])
      Application.put_env(:universal_proxy, :btd700_test_hidraw, %{"1-1.3.1" => "/dev/hidraw3"})
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
      Application.put_env(:universal_proxy, :btd700_test_outputs, [output()])
      Application.put_env(:universal_proxy, :btd700_test_hidraw, %{"1-1.3.1" => "/dev/hidraw3"})
      srv = start_server(sup)

      [{_, pid, _, _}] = DynamicSupervisor.which_children(sup)
      # Device unplugged: hidraw node no longer resolves.
      Application.put_env(:universal_proxy, :btd700_test_hidraw, %{})
      Process.exit(pid, :kill)

      wait_until(fn -> Server.list_devices(srv) == [] end)
    end
  end

  describe "worker_for/2" do
    test "resolves the live worker pid, or :not_found", %{sup: sup} do
      Application.put_env(:universal_proxy, :btd700_test_outputs, [output()])
      Application.put_env(:universal_proxy, :btd700_test_hidraw, %{"1-1.3.1" => "/dev/hidraw3"})
      srv = start_server(sup)

      [{_, pid, _, _}] = DynamicSupervisor.which_children(sup)
      assert {:ok, ^pid} = Server.worker_for(srv, @key)
      assert Server.worker_for(srv, {"nope", 0, 0}) == {:error, :not_found}
    end
  end

  describe "get_state/2" do
    test "delegates to the worker's cache", %{sup: sup} do
      Application.put_env(:universal_proxy, :btd700_test_outputs, [output()])
      Application.put_env(:universal_proxy, :btd700_test_hidraw, %{"1-1.3.1" => "/dev/hidraw3"})
      srv = start_server(sup)

      assert {:ok, %{version: "stub", usb_port: "1-1.3.1"}} = Server.get_state(srv, @key)
      assert Server.get_state(srv, {"nope", 0, 0}) == {:error, :not_found}
    end
  end
end
