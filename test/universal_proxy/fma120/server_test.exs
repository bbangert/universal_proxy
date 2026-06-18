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
    end)

    sup_name = :"wsup_#{System.unique_integer([:positive])}"
    start_supervised!({DynamicSupervisor, name: sup_name, strategy: :one_for_one})
    {:ok, sup: sup_name}
  end

  defp start_server(sup) do
    name = :"fma_srv_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {Server,
         name: name,
         subscribe: false,
         worker_module: StubWorker,
         worker_supervisor: sup,
         hardware: StubHW},
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

  describe "get_state/2" do
    test "delegates to the worker's cache", %{sup: sup} do
      Application.put_env(:universal_proxy, :fma_test_ports, [port([])])
      srv = start_server(sup)

      assert {:ok, %{version: "stub", usb_port: "1-1.3"}} = Server.get_state(srv, @key)
      assert Server.get_state(srv, {"nope", 0, 0}) == {:error, :not_found}
    end
  end
end
