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
    {:ok, store: store, audio: audio}
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

    pid = start_supervised!({HomeAssistantPairing, Keyword.merge(defaults, opts)})
    {pid, results}
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

  test "nothing is selected by default", ctx do
    {pid, _} = start_pairing!(ctx)

    assert HomeAssistantPairing.selection(pid) == nil
    refute HomeAssistantPairing.selected?(pid)
    refute_received {:update_adapters, _, _}
    refute_received {:disconnect_clients, _}
  end

  test "selected? is false while the process is down" do
    refute HomeAssistantPairing.selected?(:no_such_ha_pairing)
  end

  test "selecting an output persists it with its client id and reconnects HA", ctx do
    {pid, _} = start_pairing!(ctx)

    assert :ok = HomeAssistantPairing.select(pid, @key)

    assert HomeAssistantPairing.selection(pid) == %{key: @key, client_id: "hp-id"}
    assert Store.get_home_assistant_pairing(ctx.store) == %{key: @key, client_id: "hp-id"}
    assert_received {:home_assistant_pairing, @key}

    assert_received {:update_adapters, :espex_test, [sendspin: UniversalProxy.ESPHome.Sendspin]}

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
    assert HomeAssistantPairing.selection(pid) == %{key: @usb_key, client_id: nil}
    assert_received {:home_assistant_pairing, @usb_key}
  end

  test "an output that isn't present can't be selected", ctx do
    {pid, _} = start_pairing!(ctx)

    assert {:error, :not_found} = HomeAssistantPairing.select(pid, {"Gone", nil, nil})
    assert HomeAssistantPairing.selection(pid) == nil
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

    assert HomeAssistantPairing.selection(pid) == nil
    assert Store.get_home_assistant_pairing(ctx.store) == nil
    assert_received {:home_assistant_pairing, nil}
    assert_received {:update_adapters, :espex_test, [sendspin: nil]}
    assert_received {:disconnect_clients, :espex_test}

    # Already clear.
    assert :ok = HomeAssistantPairing.clear(pid)
    refute_received {:update_adapters, _, _}
  end

  test "the selection survives a restart", ctx do
    :ok = Store.put_home_assistant_pairing(ctx.store, %{key: @key, client_id: "hp-id"})
    {pid, _} = start_pairing!(ctx)

    assert HomeAssistantPairing.selection(pid) == %{key: @key, client_id: "hp-id"}
    assert HomeAssistantPairing.selected?(pid)
    # Espex reads it when it starts: nothing to apply.
    refute_received {:update_adapters, _, _}
    refute_received {:disconnect_clients, _}
  end

  test "a selection kept while its output is unplugged keeps its cached client id", ctx do
    :ok =
      Store.put_home_assistant_pairing(ctx.store, %{key: {"Gone", nil, nil}, client_id: "old"})

    {pid, _} = start_pairing!(ctx)

    assert HomeAssistantPairing.selection(pid) == %{key: {"Gone", nil, nil}, client_id: "old"}
    refute_received {:disconnect_clients, _}
  end

  test "a client id that changed while it was down is caught up at start", ctx do
    :ok = Store.put_home_assistant_pairing(ctx.store, %{key: @key, client_id: nil})
    {pid, _} = start_pairing!(ctx)

    assert HomeAssistantPairing.selection(pid) == %{key: @key, client_id: "hp-id"}
    assert Store.get_home_assistant_pairing(ctx.store) == %{key: @key, client_id: "hp-id"}
    assert_received {:disconnect_clients, :espex_test}
    refute_received {:update_adapters, _, _}
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
      assert HomeAssistantPairing.selection(pid) == %{key: @usb_key, client_id: "usb-id"}
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
      assert HomeAssistantPairing.selection(pid).client_id == "new-id"
      assert_received {:disconnect_clients, :espex_test}
    end

    test "another output's is ignored", %{pairing: pid} do
      Phoenix.PubSub.broadcast(
        @pubsub,
        "sendspin:state",
        {:sendspin_state, @key, %{sendspin_client_id: "other"}}
      )

      sync(pid)
      assert HomeAssistantPairing.selection(pid).client_id == nil
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
      for _ <- 1..3, do: assert_receive({:update_adapters, :espex_test, [sendspin: _]}, 500)
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
