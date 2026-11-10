defmodule UniversalProxy.Audio.HomeAssistantPairingTest do
  # async: false — the Store's DETS table name is a fixed atom.
  use ExUnit.Case, async: false

  alias UniversalProxy.Audio.{HomeAssistantPairing, Store}

  @table :ha_pairing_test_store
  @pubsub :ha_pairing_test_pubsub
  @key {"bcm2835 Headphones", nil, nil}
  @usb_key {"USB Audio", 0x1D6B, 0x0104}

  defmodule AudioServerStub do
    @moduledoc false
    # Answers `Audio.Server.get_output/2` from a map of present outputs.
    use GenServer

    def start_link(outputs), do: GenServer.start_link(__MODULE__, outputs)
    def set(pid, outputs), do: GenServer.call(pid, {:set, outputs})

    @impl true
    def init(outputs), do: {:ok, outputs}

    @impl true
    def handle_call({:get_output, key}, _from, outputs),
      do: {:reply, Map.fetch(outputs, key), outputs}

    def handle_call({:set, outputs}, _from, _outputs), do: {:reply, :ok, outputs}
  end

  setup do
    path =
      Path.join(System.tmp_dir!(), "ha_pairing_test_#{System.unique_integer([:positive])}.dets")

    on_exit(fn -> File.rm(path) end)

    start_supervised!({Phoenix.PubSub, name: @pubsub})
    store = start_supervised!({Store, name: nil, table: @table, dets_path: path})

    audio =
      start_supervised!(
        {AudioServerStub,
         %{
           @key => %{key: @key, enabled: true, sendspin_client_id: "hp-id"},
           @usb_key => %{key: @usb_key, enabled: true, sendspin_client_id: nil}
         }}
      )

    Phoenix.PubSub.subscribe(@pubsub, HomeAssistantPairing.topic())
    {:ok, store: store, audio: audio, path: path, espex: register_espex!(:espex_test)}
  end

  # Records the Espex calls; `results` (an Agent) scripts their replies.
  defp start_pairing!(ctx, opts \\ []) do
    test = self()
    results = start_supervised!({Agent, fn -> %{} end}, id: :results)

    reply = fn call ->
      Agent.get_and_update(results, fn r ->
        case Map.get(r, call, []) do
          [next | rest] -> {next, Map.put(r, call, rest)}
          [] -> {:ok, r}
        end
      end)
    end

    defaults = [
      name: nil,
      store: ctx.store,
      audio_server: ctx.audio,
      pubsub: @pubsub,
      espex_server: :espex_test,
      adapter: UniversalProxy.ESPHome.Sendspin,
      retry_ms: 10,
      update_adapters: fn server, changes ->
        send(test, {:update_adapters, server, changes})
        result(reply.(:update_adapters))
      end,
      disconnect_clients: fn server ->
        send(test, {:disconnect_clients, server})
        result(reply.(:disconnect_clients))
      end
    ]

    {drain?, opts} = Keyword.pop(opts, :drain, true)
    pid = start_supervised!({HomeAssistantPairing, Keyword.merge(defaults, opts)})

    # Its startup reconcile has run; its calls are dropped unless the test
    # is about them.
    sync(pid)
    if drain?, do: drain()

    {pid, results}
  end

  defp restart_pairing!(ctx, opts) do
    :ok = stop_supervised(HomeAssistantPairing)
    :ok = stop_supervised(:results)
    start_pairing!(ctx, opts)
  end

  # Stands in for a registered `Espex.Server` the process can monitor.
  defp register_espex!(name) do
    pid = spawn(fn -> receive(do: (:stop -> :ok)) end)
    Process.register(pid, name)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  # Like the real call: fails on a server that is gone.
  defp registered_update(test) do
    fn server, changes ->
      send(test, {:update_adapters, server, changes})
      if is_pid(server) and Process.alive?(server), do: :ok, else: exit(:noproc)
    end
  end

  defp kill_and_wait(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
  end

  defp result(:exit), do: exit(:noproc)
  defp result(:raise), do: raise(ArgumentError, "unknown registry")
  defp result(other), do: other

  defp script(results, call, replies), do: Agent.update(results, &Map.put(&1, call, replies))

  defp sync(pid), do: :sys.get_state(pid)

  # Drops the messages of a setup step.
  defp drain do
    receive do
      {tag, _} when tag in [:disconnect_clients, :home_assistant_pairing] -> drain()
      {:update_adapters, _, _} -> drain()
    after
      0 -> :ok
    end
  end

  test "nothing is selected by default, and the start applies that", ctx do
    {pid, _} = start_pairing!(ctx, drain: false)

    assert HomeAssistantPairing.selection(pid) == {:ok, nil}
    refute HomeAssistantPairing.selected?(pid)
    # The update goes to the server's pid, the reconnect through its name.
    espex = ctx.espex
    assert_received {:update_adapters, ^espex, [sendspin: nil]}
    assert_received {:disconnect_clients, :espex_test}
  end

  describe "a selection that can't be loaded" do
    test "is not taken as none: nothing is applied until the load works", ctx do
      :ok = Store.put_home_assistant_pairing(ctx.store, %{key: @key, client_id: "hp-id"})
      :ok = stop_supervised(Store)

      # A Store that isn't running yet, under the name the process uses.
      {pid, _} = start_pairing!(ctx, store: :ha_pairing_late_store, drain: false)

      assert HomeAssistantPairing.selection(pid) == {:error, :unavailable}
      refute HomeAssistantPairing.selected?(pid)
      assert {:error, :unavailable} = HomeAssistantPairing.select(pid, @usb_key)
      assert {:error, :unavailable} = HomeAssistantPairing.clear(pid)
      refute_receive {:update_adapters, _, _}, 50
      refute_received {:disconnect_clients, _}

      start_supervised!(
        {Store, name: :ha_pairing_late_store, table: @table, dets_path: ctx.path},
        id: :late_store
      )

      espex = ctx.espex
      assert_receive {:home_assistant_pairing, @key}, 2_000

      assert_receive {:update_adapters, ^espex, [sendspin: UniversalProxy.ESPHome.Sendspin]},
                     1_000

      assert_receive {:disconnect_clients, :espex_test}, 2_000
      assert HomeAssistantPairing.selection(pid) == {:ok, %{key: @key, client_id: "hp-id"}}
      assert :ok = HomeAssistantPairing.clear(pid)
    end
  end

  test "selected? is false while the process is down" do
    refute HomeAssistantPairing.selected?(:no_such_ha_pairing)
  end

  test "selecting an output persists it with its client id and reconnects HA", ctx do
    {pid, _} = start_pairing!(ctx)

    assert :ok = HomeAssistantPairing.select(pid, @key)

    assert HomeAssistantPairing.selection(pid) == {:ok, %{key: @key, client_id: "hp-id"}}
    assert Store.get_home_assistant_pairing(ctx.store) == %{key: @key, client_id: "hp-id"}
    assert_received {:home_assistant_pairing, @key}

    assert_received {:update_adapters, _espex, [sendspin: UniversalProxy.ESPHome.Sendspin]}

    assert_received {:disconnect_clients, :espex_test}
  end

  test "reselecting the selected output changes nothing", ctx do
    {pid, _} = start_pairing!(ctx)
    :ok = HomeAssistantPairing.select(pid, @key)
    assert_received {:disconnect_clients, _}
    drain()

    assert :ok = HomeAssistantPairing.select(pid, @key)
    refute_received {:home_assistant_pairing, _}
    refute_received {:update_adapters, _, _}
    refute_received {:disconnect_clients, _}
  end

  test "selecting another output replaces the selection", ctx do
    {pid, _} = start_pairing!(ctx)
    :ok = HomeAssistantPairing.select(pid, @key)

    assert :ok = HomeAssistantPairing.select(pid, @usb_key)
    assert HomeAssistantPairing.selection(pid) == {:ok, %{key: @usb_key, client_id: nil}}
    assert_received {:home_assistant_pairing, @usb_key}
  end

  test "an output that isn't present can't be selected", ctx do
    {pid, _} = start_pairing!(ctx)

    assert {:error, :not_found} = HomeAssistantPairing.select(pid, {"Gone", nil, nil})
    assert HomeAssistantPairing.selection(pid) == {:ok, nil}
    refute_received {:update_adapters, _, _}
  end

  test "selecting while the audio server is down is :unavailable", ctx do
    {pid, _} = start_pairing!(ctx)
    :ok = stop_supervised(AudioServerStub)

    assert {:error, :unavailable} = HomeAssistantPairing.select(pid, @key)
  end

  test "clearing unwires the adapter and reconnects HA", ctx do
    {pid, _} = start_pairing!(ctx)
    :ok = HomeAssistantPairing.select(pid, @key)
    assert_received {:disconnect_clients, _}
    drain()

    assert :ok = HomeAssistantPairing.clear(pid)

    assert HomeAssistantPairing.selection(pid) == {:ok, nil}
    assert Store.get_home_assistant_pairing(ctx.store) == nil
    assert_received {:home_assistant_pairing, nil}
    assert_received {:update_adapters, _espex, [sendspin: nil]}
    assert_received {:disconnect_clients, :espex_test}

    # Already clear.
    assert :ok = HomeAssistantPairing.clear(pid)
    refute_received {:update_adapters, _, _}
  end

  test "the selection survives a restart and is applied again, then HA reconnected", ctx do
    {pid, _} = start_pairing!(ctx)
    :ok = HomeAssistantPairing.select(pid, @key)
    drain()

    {pid, _} = restart_pairing!(ctx, drain: false)

    assert HomeAssistantPairing.selection(pid) == {:ok, %{key: @key, client_id: "hp-id"}}
    assert HomeAssistantPairing.selected?(pid)
    assert_received {:update_adapters, _espex, [sendspin: UniversalProxy.ESPHome.Sendspin]}
    assert_received {:disconnect_clients, :espex_test}
  end

  test "work a previous run left pending is done by the next one", ctx do
    {pid, results} = start_pairing!(ctx, retry_ms: 60_000)
    script(results, :update_adapters, [:exit])

    # The update fails and its retry is far off: the process dies with it pending.
    :ok = HomeAssistantPairing.select(pid, @key)
    assert_received {:update_adapters, _, [sendspin: UniversalProxy.ESPHome.Sendspin]}
    refute_received {:disconnect_clients, _}
    assert %{pending: :update} = sync(pid)

    restart_pairing!(ctx, drain: false)
    assert_received {:update_adapters, _espex, [sendspin: UniversalProxy.ESPHome.Sendspin]}
    assert_received {:disconnect_clients, :espex_test}
  end

  test "a selection kept while its output is unplugged keeps its cached client id", ctx do
    :ok =
      Store.put_home_assistant_pairing(ctx.store, %{key: {"Gone", nil, nil}, client_id: "old"})

    {pid, _} = start_pairing!(ctx)

    assert HomeAssistantPairing.selection(pid) ==
             {:ok, %{key: {"Gone", nil, nil}, client_id: "old"}}

    assert Store.get_home_assistant_pairing(ctx.store).client_id == "old"
  end

  test "a client id that changed while it was down is caught up at start", ctx do
    :ok = Store.put_home_assistant_pairing(ctx.store, %{key: @key, client_id: nil})
    {pid, _} = start_pairing!(ctx, drain: false)

    assert HomeAssistantPairing.selection(pid) == {:ok, %{key: @key, client_id: "hp-id"}}
    assert Store.get_home_assistant_pairing(ctx.store) == %{key: @key, client_id: "hp-id"}
    assert_received {:update_adapters, _espex, [sendspin: UniversalProxy.ESPHome.Sendspin]}
    assert_received {:disconnect_clients, :espex_test}
  end

  describe "an Espex.Server that is replaced" do
    @espex :ha_pairing_test_espex

    test "gets the current selection again, and HA is reconnected", ctx do
      first = register_espex!(@espex)

      {pid, _} =
        start_pairing!(ctx, espex_server: @espex, update_adapters: registered_update(self()))

      :ok = HomeAssistantPairing.select(pid, @key)
      assert %{espex_mon: {^first, _ref}} = sync(pid)
      drain()

      # Restarted with its start-time adapters: re-applied once it is back.
      # Nothing is sent while no server is registered.
      kill_and_wait(first)
      refute_receive {:update_adapters, _, _}, 50

      # The one registered meanwhile is the one updated, and monitored...
      second = register_espex!(@espex)

      assert_receive {:update_adapters, ^second, [sendspin: UniversalProxy.ESPHome.Sendspin]},
                     1_000

      assert_receive {:disconnect_clients, @espex}, 500
      drain()
      assert %{espex_mon: {^second, _ref}, pending: nil} = sync(pid)

      # ...so its own restart is re-applied too.
      kill_and_wait(second)
      third = register_espex!(@espex)

      assert_receive {:update_adapters, ^third, [sendspin: UniversalProxy.ESPHome.Sendspin]},
                     1_000

      assert_receive {:disconnect_clients, @espex}, 500
      assert %{espex_mon: {^third, _ref}} = sync(pid)
    end

    test "after a clear, gets no adapter again", ctx do
      first = register_espex!(@espex)

      {pid, _} =
        start_pairing!(ctx, espex_server: @espex, update_adapters: registered_update(self()))

      :ok = HomeAssistantPairing.select(pid, @key)
      :ok = HomeAssistantPairing.clear(pid)
      drain()

      kill_and_wait(first)
      register_espex!(@espex)
      assert_receive {:update_adapters, _server, [sendspin: nil]}, 2_000
      assert_receive {:disconnect_clients, @espex}, 500
    end
  end

  describe "the selected output's client id" do
    setup ctx do
      {pid, _} = start_pairing!(ctx)
      :ok = HomeAssistantPairing.select(pid, @usb_key)
      assert_received {:disconnect_clients, _}
      drain()
      {:ok, pairing: pid}
    end

    test "a new one is persisted and reconnects HA", %{pairing: pid, store: store} do
      Phoenix.PubSub.broadcast(
        @pubsub,
        "sendspin:state",
        {:sendspin_state, @usb_key, %{sendspin_client_id: "usb-id"}}
      )

      sync(pid)
      assert HomeAssistantPairing.selection(pid) == {:ok, %{key: @usb_key, client_id: "usb-id"}}
      assert Store.get_home_assistant_pairing(store) == %{key: @usb_key, client_id: "usb-id"}
      assert_received {:disconnect_clients, :espex_test}
      refute_received {:update_adapters, _, _}

      # The binary's own listening event with the same id changes nothing.
      Phoenix.PubSub.broadcast(
        @pubsub,
        "sendspin:state",
        {:sendspin_state, @usb_key, %{event: "listening", port: 8928, client_id: "usb-id"}}
      )

      sync(pid)
      refute_received {:disconnect_clients, _}

      # A different one (a new keypair) does.
      Phoenix.PubSub.broadcast(
        @pubsub,
        "sendspin:state",
        {:sendspin_state, @usb_key, %{event: "listening", port: 8928, client_id: "new-id"}}
      )

      sync(pid)
      assert {:ok, %{client_id: "new-id"}} = HomeAssistantPairing.selection(pid)
      assert_received {:disconnect_clients, :espex_test}
    end

    test "another output's is ignored", %{pairing: pid} do
      Phoenix.PubSub.broadcast(
        @pubsub,
        "sendspin:state",
        {:sendspin_state, @key, %{sendspin_client_id: "other"}}
      )

      sync(pid)
      assert {:ok, %{client_id: nil}} = HomeAssistantPairing.selection(pid)
      refute_received {:disconnect_clients, _}
    end
  end

  describe "an Espex that is down" do
    test "the update and the reconnect are retried until they work", ctx do
      {pid, results} = start_pairing!(ctx)
      script(results, :update_adapters, [:exit, {:error, :busy}])
      script(results, :disconnect_clients, [:raise])

      assert :ok = HomeAssistantPairing.select(pid, @key)

      # exit, {:error, _}, then :ok; the reconnect raises once, then works.
      for _ <- 1..3, do: assert_receive({:update_adapters, _espex, [sendspin: _]}, 500)
      for _ <- 1..2, do: assert_receive({:disconnect_clients, :espex_test}, 500)

      refute_receive {:update_adapters, _, _}, 100
      refute_received {:disconnect_clients, _}
      assert %{pending: nil} = sync(pid)
    end

    test "a change while a retry is pending applies the latest selection, once", ctx do
      {pid, results} = start_pairing!(ctx)
      script(results, :update_adapters, [:exit])

      :ok = HomeAssistantPairing.select(pid, @key)
      :ok = HomeAssistantPairing.clear(pid)

      assert_receive {:update_adapters, _, [sendspin: UniversalProxy.ESPHome.Sendspin]}
      assert_receive {:update_adapters, _, [sendspin: nil]}, 500
      assert_receive {:disconnect_clients, _}, 500
      refute_receive {:update_adapters, _, _}, 100
    end
  end
end
