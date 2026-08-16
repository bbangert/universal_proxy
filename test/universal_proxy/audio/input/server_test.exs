defmodule UniversalProxy.Audio.Input.ServerTest do
  # async: false — these tests share named Agent stubs, subscribe the test PID
  # to global PubSub topics, and one of them stops the application-tree
  # `Audio.Input.Supervisor` to exercise façade degradation. Concurrent tests
  # would see each other's broadcasts.
  use ExUnit.Case, async: false

  alias UniversalProxy.Audio.Input
  alias UniversalProxy.Audio.Input.{Server, Source, Store}

  @pubsub UniversalProxy.PubSub
  @store_table :audio_input_server_store_test

  @usb_key {"1-1.3", 0x1D6B, 0x0105}
  @soc_key {"bcm2835 Capture", nil, nil}

  @usb_info %{
    name: "USB Capture Card",
    alsa_device: "plughw:1,0",
    card_index: 1,
    vid: 0x1D6B,
    pid: 0x0105,
    usb_port: "1-1.3"
  }

  @soc_info %{
    name: "bcm2835 Capture",
    alsa_device: "plughw:0,0",
    card_index: 0,
    vid: nil,
    pid: nil,
    usb_port: nil
  }

  defmodule EnumerateStub do
    @moduledoc false
    use Agent

    def start_link(initial \\ %{}) do
      Agent.start_link(fn -> initial end, name: __MODULE__)
    end

    def set(inputs), do: Agent.update(__MODULE__, fn _ -> inputs end)

    @doc false
    def safe, do: Agent.get(__MODULE__, & &1)
  end

  defmodule SourceStub do
    @moduledoc """
    Stand-in for `Audio.Input.Source`. Mirrors its `start_link/1` option
    contract and its `restart: :temporary` child spec, reports
    `{:listener_bound, port}` to the owner from `init/1` exactly as the real
    source does, and lets tests push any other owner event through `emit/2`.
    """
    use GenServer, restart: :temporary

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @doc "Send an arbitrary `{:source_event, key, event}` to the owner."
    def emit(pid, event), do: GenServer.call(pid, {:emit, event})

    @impl true
    def init(opts) do
      # Trap exits so `DynamicSupervisor.terminate_child/2` runs terminate/2,
      # matching the real Source (whose terminate/2 frees the ranch listener).
      Process.flag(:trap_exit, true)

      state = %{
        key: Keyword.fetch!(opts, :key),
        port: Keyword.fetch!(opts, :port),
        owner: Keyword.fetch!(opts, :owner),
        opts: opts
      }

      record({:started, state.key, state.port, opts})
      send(state.owner, {:source_event, state.key, {:listener_bound, state.port}})
      {:ok, state}
    end

    @impl true
    def handle_call({:emit, event}, _from, state) do
      send(state.owner, {:source_event, state.key, event})
      {:reply, :ok, state}
    end

    @impl true
    def terminate(_reason, state) do
      record({:terminated, state.key})
      :ok
    end

    defp record(event) do
      # Full module path: Elixir's auto-alias doesn't resolve sibling nested
      # modules from here, and the Agent is registered under the nested name.
      # Guarded against `:exit` because terminate/2 can fire after the Agent
      # has begun tearing down.
      Agent.update(
        UniversalProxy.Audio.Input.ServerTest.SourceStubCalls,
        fn calls -> [event | calls] end
      )
    catch
      :exit, _ -> :ok
    end
  end

  defmodule SourceStubCalls do
    @moduledoc false
    use Agent

    def start_link(_opts \\ []) do
      Agent.start_link(fn -> [] end, name: __MODULE__)
    end

    def calls, do: __MODULE__ |> Agent.get(& &1) |> Enum.reverse()
  end

  defmodule MdnsStub do
    @moduledoc false
    use Agent

    def start_link(_opts \\ []) do
      Agent.start_link(fn -> [] end, name: __MODULE__)
    end

    def add_mdns_service(service) do
      record({:add, service})
      :ok
    end

    def goodbye_service(id), do: record({:goodbye, id})
    def remove_mdns_service(id), do: record({:remove, id})

    def calls, do: __MODULE__ |> Agent.get(& &1) |> Enum.reverse()

    defp record(event) do
      Agent.update(__MODULE__, fn calls -> [event | calls] end)
      :ok
    catch
      :exit, _ -> :ok
    end
  end

  setup do
    start_supervised!({EnumerateStub, %{}})
    start_supervised!(SourceStubCalls, id: :source_stub_calls)
    start_supervised!(MdnsStub, id: :mdns_stub)

    store = start_store!(:store, @store_table)

    source_sup =
      start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: nil}, id: :source_sup)

    server =
      start_supervised!(
        {Server,
         name: nil,
         store: store,
         enumerate_module: EnumerateStub,
         start_timer: false,
         source_supervisor: source_sup,
         source_module: SourceStub,
         mdns_module: MdnsStub},
        id: :server
      )

    :ok = Phoenix.PubSub.subscribe(@pubsub, "sendspin:input_added")
    :ok = Phoenix.PubSub.subscribe(@pubsub, "sendspin:input_removed")
    :ok = Phoenix.PubSub.subscribe(@pubsub, "sendspin:input_state")

    {:ok, server: server, store: store, source_sup: source_sup}
  end

  defp start_store!(id, table) do
    path =
      Path.join(
        System.tmp_dir!(),
        "audio_input_server_test_#{System.unique_integer([:positive])}.dets"
      )

    on_exit(fn -> File.rm(path) end)

    start_supervised!({Store, name: nil, table: table, dets_path: path}, id: id)
  end

  defp add_usb_card!(server) do
    EnumerateStub.set(%{@usb_key => @usb_info})
    :ok = Server.check_now(server)
    assert_receive {:sendspin_input_added, input}
    input
  end

  defp source_pid(sup) do
    [{_, pid, _, _}] = DynamicSupervisor.which_children(sup)
    pid
  end

  describe "convergence: add" do
    test "seeds DETS, starts a source on an allocated port, and broadcasts", %{
      server: server,
      store: store,
      source_sup: sup
    } do
      input = add_usb_card!(server)

      assert input.key == @usb_key
      assert input.alsa_device == "plughw:1,0"
      assert input.name == "USB Capture Card"
      # The USB bus path disambiguates two identical capture cards, exactly
      # as it does for outputs.
      assert input.friendly_name == "USB Capture Card (1-1.3)"
      assert input.paired == false

      assert {:ok, cfg} = Store.get_config(store, @usb_key)
      assert cfg.friendly_name == "USB Capture Card (1-1.3)"
      # The keypair stays lazy — nothing in the orchestration path may mint
      # the long-term identity before a connection needs it.
      assert cfg.client_keypair == nil

      assert length(DynamicSupervisor.which_children(sup)) == 1

      usb_key = @usb_key

      assert Enum.any?(SourceStubCalls.calls(), fn
               {:started, ^usb_key, port, opts} when port in 9_928..65_535 ->
                 Keyword.fetch!(opts, :alsa_device) == "plughw:1,0" and
                   Keyword.fetch!(opts, :name) == "USB Capture Card (1-1.3)"

               _ ->
                 false
             end),
             "expected a source started on the input port base; got #{inspect(SourceStubCalls.calls())}"
    end

    test "allocates from a base that does not overlap the player range", %{server: server} do
      _input = add_usb_card!(server)

      assert [{:started, _key, port, _opts} | _] = SourceStubCalls.calls()
      # Audio.Server's players climb from 8928; inputs start a thousand
      # above so the two independent allocators can't trip over each other.
      assert port == 9_928
    end

    test "a persisted rename survives re-detection", %{store: store} do
      :ok = Store.save_config(store, @usb_key, %{friendly_name: "Turntable"})
      EnumerateStub.set(%{@usb_key => @usb_info})

      # A fresh Server simulates a reboot: the row is already in DETS and the
      # card arrives as an "add". The default name must not clobber it.
      reboot_server =
        start_supervised!(
          {Server,
           name: nil,
           store: store,
           enumerate_module: EnumerateStub,
           start_timer: false,
           source_supervisor: nil,
           mdns_module: nil},
          id: :reboot_server
        )

      :ok = Server.check_now(reboot_server)

      assert_receive {:sendspin_input_added, %{friendly_name: "Turntable"}}
    end

    test "does not re-broadcast for inputs already known", %{server: server} do
      _input = add_usb_card!(server)

      :ok = Server.check_now(server)
      refute_receive {:sendspin_input_added, _}, 200
    end

    test "list_inputs/1 and get_input/2 return merged rows sorted by friendly_name", %{
      server: server
    } do
      EnumerateStub.set(%{@usb_key => @usb_info, @soc_key => @soc_info})
      :ok = Server.check_now(server)
      assert_receive {:sendspin_input_added, _}
      assert_receive {:sendspin_input_added, _}

      assert [first, second] = Server.list_inputs(server)
      assert first.friendly_name == "USB Capture Card (1-1.3)"
      assert second.friendly_name == "bcm2835 Capture"

      # The derived live state is merged in, so a late LiveView mount reads
      # the truth without waiting for the next event.
      assert first.status == :waiting
      assert first.connection == :disconnected
      assert first.pin == nil
      assert is_integer(first.port)

      assert {:ok, soc} = Server.get_input(server, @soc_key)
      assert soc.alsa_device == "plughw:0,0"
      assert :error = Server.get_input(server, {"nope", nil, nil})
    end

    test "never leaks pairing key material into the merged row", %{server: server, store: store} do
      :ok = Store.save_config(store, @usb_key, %{psk: :crypto.strong_rand_bytes(32)})
      {:ok, _keypair} = Store.ensure_client_keypair(store, @usb_key)

      input = add_usb_card!(server)

      refute Map.has_key?(input, :psk)
      refute Map.has_key?(input, :psk_id)
      refute Map.has_key?(input, :client_keypair)
    end
  end

  describe "convergence: remove" do
    test "stops the source, sends a goodbye + unregister, keeps the DETS row", %{
      server: server,
      store: store,
      source_sup: sup
    } do
      _input = add_usb_card!(server)
      assert_receive {:input_state, @usb_key, %{status: :waiting}}

      EnumerateStub.set(%{})
      :ok = Server.check_now(server)

      assert_receive {:sendspin_input_removed, %{key: @usb_key}}
      assert DynamicSupervisor.which_children(sup) == []
      assert {:terminated, @usb_key} in SourceStubCalls.calls()

      id = {:sendspin_source, "1-1.3", 0x1D6B, 0x0105}
      calls = MdnsStub.calls()

      # Goodbye BEFORE remove: removing first strips the service from the
      # table and the TTL=0 packet would have nothing to build from. (The
      # leading `{:remove, id}` in `calls` is registration's own pre-emptive
      # cleanup of any orphan under this id, so look for a remove that
      # follows the goodbye rather than the first one.)
      goodbye_at = Enum.find_index(calls, &(&1 == {:goodbye, id}))
      assert goodbye_at, "expected a goodbye for #{inspect(id)}; got #{inspect(calls)}"

      assert {:remove, id} in Enum.drop(calls, goodbye_at + 1),
             "expected a remove after the goodbye; got #{inspect(calls)}"

      # The row survives the unplug so the pairing does too.
      assert {:ok, %{friendly_name: "USB Capture Card (1-1.3)"}} =
               Store.get_config(store, @usb_key)
    end
  end

  describe "convergence: hardware change" do
    test "an alsa_device change on a stable key restarts the source with the new device", %{
      server: server,
      source_sup: sup
    } do
      _input = add_usb_card!(server)
      assert_receive {:input_state, @usb_key, %{status: :waiting}}
      old_pid = source_pid(sup)

      # Same {slot_sub, vid, pid} key, but the card re-enumerated at a new ALSA
      # index — a remove/re-add collapsed by the hotplug debounce. It is
      # neither an add nor a remove, so only the `changed` branch reconciles it.
      moved = %{@usb_info | alsa_device: "plughw:2,0", card_index: 2}
      EnumerateStub.set(%{@usb_key => moved})
      :ok = Server.check_now(server)

      # The stale-plughw source is torn down and a fresh one started on the new
      # device (pairing survives — it's keyed by the unchanged key).
      assert {:terminated, @usb_key} in SourceStubCalls.calls()
      new_pid = source_pid(sup)
      assert new_pid != old_pid

      assert Enum.any?(SourceStubCalls.calls(), fn
               {:started, @usb_key, _port, opts} ->
                 Keyword.fetch!(opts, :alsa_device) == "plughw:2,0"

               _ ->
                 false
             end),
             "expected a restart on plughw:2,0; got #{inspect(SourceStubCalls.calls())}"

      # The row is upserted with the new hardware (same card, no add/remove
      # churn to the UI).
      assert_receive {:sendspin_input_added, %{key: @usb_key, alsa_device: "plughw:2,0"}}
      refute_received {:sendspin_input_removed, _}
      assert [%{alsa_device: "plughw:2,0", card_index: 2}] = Server.list_inputs(server)
    end

    test "an unchanged re-enumeration does not restart the source", %{
      server: server,
      source_sup: sup
    } do
      _input = add_usb_card!(server)
      assert_receive {:input_state, @usb_key, %{status: :waiting}}
      pid = source_pid(sup)

      EnumerateStub.set(%{@usb_key => @usb_info})
      :ok = Server.check_now(server)

      refute {:terminated, @usb_key} in SourceStubCalls.calls()
      assert source_pid(sup) == pid
    end
  end

  describe "mDNS" do
    test "registers only on listener_bound, with a leading-slash path TXT", %{server: server} do
      _input = add_usb_card!(server)
      # `check_now/1` returns before the source's `{:listener_bound, _}`
      # reaches the Server — the state broadcast is the synchronisation
      # point, and its arrival is itself the "only on listener_bound" proof.
      assert_receive {:input_state, @usb_key, %{status: :waiting}}

      assert [{:add, service}] = Enum.filter(MdnsStub.calls(), &match?({:add, _}, &1))

      assert service.id == {:sendspin_source, "1-1.3", 0x1D6B, 0x0105}
      assert service.protocol == "sendspin"
      assert service.transport == "tcp"
      assert service.port == 9_928
      assert String.starts_with?(service.instance_name, "USB Capture Card (1-1.3)")

      # MA silently ignores a `_sendspin._tcp` instance whose TXT `path` is
      # missing or doesn't start with "/". This is the whole discovery gate.
      assert "path=#{Source.default_path()}" in service.txt_payload
      assert String.starts_with?(Source.default_path(), "/")
      assert Enum.any?(service.txt_payload, &String.starts_with?(&1, "name="))
    end

    test "a source that never binds is never advertised", %{server: server, store: store} do
      defmodule SilentSource do
        @moduledoc false
        use GenServer, restart: :temporary

        def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

        @impl true
        def init(_opts), do: {:ok, %{}}
      end

      silent_sup =
        start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: nil}, id: :silent_sup)

      silent_server =
        start_supervised!(
          {Server,
           name: nil,
           store: store,
           enumerate_module: EnumerateStub,
           start_timer: false,
           source_supervisor: silent_sup,
           source_module: SilentSource,
           mdns_module: MdnsStub},
          id: :silent_server
        )

      EnumerateStub.set(%{@usb_key => @usb_info})
      :ok = Server.check_now(silent_server)
      assert_receive {:sendspin_input_added, _}

      assert length(DynamicSupervisor.which_children(silent_sup)) == 1
      refute Enum.any?(MdnsStub.calls(), &match?({:add, _}, &1))
    end
  end

  describe "source events → input_state" do
    setup %{server: server, source_sup: sup} do
      _input = add_usb_card!(server)
      assert_receive {:input_state, @usb_key, %{status: :waiting}}
      {:ok, source: source_pid(sup)}
    end

    test "connect → pairing → PIN → paired → streaming", %{
      server: server,
      source: source,
      store: store
    } do
      :ok = SourceStub.emit(source, :connected)
      assert_receive {:input_state, @usb_key, %{connection: :connected, status: :waiting}}

      :ok = SourceStub.emit(source, {:pairing_required, %{method: :dynamic_pin, pin_length: 6}})
      assert_receive {:input_state, @usb_key, %{status: :pairing, pin: nil}}

      :ok = SourceStub.emit(source, :pairing_started)
      assert_receive {:input_state, @usb_key, %{status: :pairing}}

      # The PIN is ours to display — the operator types it into MA — so it
      # has to reach the UI verbatim.
      :ok = SourceStub.emit(source, {:pairing_pin, "482915"})
      assert_receive {:input_state, @usb_key, %{status: :pairing, pin: "482915"}}
      assert [%{pin: "482915"}] = Server.list_inputs(server)

      # `:paired` lands after the Source has written the PSK, so the cached
      # row's `paired` flag has to be re-read, not left stale.
      :ok = Store.save_pairing(store, @usb_key, %{psk: :crypto.strong_rand_bytes(32)})
      :ok = SourceStub.emit(source, :paired)
      assert_receive {:input_state, @usb_key, %{status: :paired, pin: nil}}
      assert [%{paired: true}] = Server.list_inputs(server)

      :ok = SourceStub.emit(source, :streaming)
      assert_receive {:input_state, @usb_key, %{status: :streaming}}

      :ok = SourceStub.emit(source, :stopped)
      assert_receive {:input_state, @usb_key, %{status: :paired}}
    end

    test "a failed pairing clears the stale PIN but stays in :pairing", %{source: source} do
      :ok = SourceStub.emit(source, {:pairing_pin, "111111"})
      assert_receive {:input_state, @usb_key, %{pin: "111111"}}

      # MA retries by offering the pairing activity again, so the connection
      # is still up and the badge must not fall back to "waiting".
      :ok = SourceStub.emit(source, {:pairing_failed, :mcf_mismatch})
      assert_receive {:input_state, @usb_key, %{status: :pairing, pin: nil, last_error: err}}
      assert err =~ "mcf_mismatch"
    end

    test "disconnect resets the connection half but keeps the advertisement", %{
      source: source,
      server: server
    } do
      :ok = SourceStub.emit(source, :connected)
      assert_receive {:input_state, @usb_key, %{connection: :connected}}

      :ok = SourceStub.emit(source, :disconnected)
      assert_receive {:input_state, @usb_key, %{status: :waiting, connection: :disconnected}}

      # The listener is still bound, so the mDNS record must stay — MA
      # redials the same port. A retirement would show up as a goodbye (the
      # single `{:remove, _}` in the log is registration's own pre-emptive
      # orphan cleanup, not a teardown).
      assert [%{port: 9_928}] = Server.list_inputs(server)
      refute Enum.any?(MdnsStub.calls(), &match?({:goodbye, _}, &1))
      assert Enum.count(MdnsStub.calls(), &match?({:add, _}, &1)) == 1
    end

    test "a missing capture binary parks the input in :degraded", %{source: source} do
      :ok = SourceStub.emit(source, {:capture_missing, "/usr/bin/arecord"})
      assert_receive {:input_state, @usb_key, %{status: :degraded, last_error: msg}}
      assert msg =~ "capture binary missing"
    end

    test "a hotplug remove while streaming stops the source and retires it", %{
      server: server,
      source: source,
      source_sup: sup
    } do
      :ok = SourceStub.emit(source, :streaming)
      assert_receive {:input_state, @usb_key, %{status: :streaming}}

      # The card is yanked mid-stream.
      EnumerateStub.set(%{})
      :ok = Server.check_now(server)

      assert_receive {:sendspin_input_removed, %{key: @usb_key}}
      assert DynamicSupervisor.which_children(sup) == []
      assert {:terminated, @usb_key} in SourceStubCalls.calls()

      # And the advertisement is retired (goodbye) so MA stops dialing a dead port.
      id = {:sendspin_source, "1-1.3", 0x1D6B, 0x0105}
      assert Enum.any?(MdnsStub.calls(), &(&1 == {:goodbye, id}))
    end

    test "a protocol error is recorded but bounded", %{source: source} do
      :ok = SourceStub.emit(source, {:error, String.duplicate("x", 1_000)})
      assert_receive {:input_state, @usb_key, %{last_error: err}}
      assert String.length(err) == 256
    end
  end

  describe ":DOWN convergence" do
    test "a crashed source is dropped, unadvertised, and respawned", %{
      server: server,
      source_sup: sup
    } do
      _input = add_usb_card!(server)
      old_pid = source_pid(sup)

      ref = Process.monitor(old_pid)
      :ok = GenServer.stop(old_pid, :killed_for_test, 1_000)
      assert_receive {:DOWN, ^ref, :process, ^old_pid, _}, 1_000

      # `:sys.get_state/1` queues behind the Server's own :DOWN handling.
      assert :sys.get_state(server).sources == %{}

      # The listener behind the advertisement is gone; a live record pointing
      # at a dead port burns MA's one-shot discovery connect.
      id = {:sendspin_source, "1-1.3", 0x1D6B, 0x0105}
      assert {:remove, id} in MdnsStub.calls()
      assert_receive {:input_state, @usb_key, %{status: :detected, port: nil}}

      # The :DOWN handler must arm the debounced re-enumeration itself: on a
      # Nerves target enumeration is uevent-driven and a source crash emits
      # no uevent, so nothing else would bring it back.
      assert :sys.get_state(server).hotplug_pending

      :ok = Server.check_now(server)

      new_pid = source_pid(sup)
      assert new_pid != old_pid

      # The abnormal exit retires the port, so the replacement gets a fresh
      # one rather than fighting for a possibly-held socket.
      assert MapSet.member?(:sys.get_state(server).unusable_ports, 9_928)
      assert :sys.get_state(server).sources[@usb_key].port == 9_929
    end
  end

  describe "binary_missing tracking" do
    @attempts_topic "input_binary_missing_attempts"

    defmodule BinaryMissingSource do
      @moduledoc false
      use GenServer, restart: :temporary

      def start_link(opts) do
        # Broadcast the attempt: the flag is set synchronously and cleared
        # only on hotplug remove, so end-state inspection alone can't prove
        # a retry did or didn't happen.
        Phoenix.PubSub.broadcast(
          UniversalProxy.PubSub,
          "input_binary_missing_attempts",
          {:attempt, Keyword.fetch!(opts, :key)}
        )

        GenServer.start_link(__MODULE__, [])
      end

      @impl true
      def init(_), do: {:stop, {:binary_missing, "/usr/bin/arecord"}}
    end

    setup %{store: store} do
      missing_sup =
        start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: nil},
          id: :missing_sup
        )

      server =
        start_supervised!(
          {Server,
           name: nil,
           store: store,
           enumerate_module: EnumerateStub,
           start_timer: false,
           source_supervisor: missing_sup,
           source_module: BinaryMissingSource,
           mdns_module: MdnsStub},
          id: :missing_server
        )

      :ok = Phoenix.PubSub.subscribe(@pubsub, @attempts_topic)

      EnumerateStub.set(%{@usb_key => @usb_info})
      :ok = Server.check_now(server)
      assert_receive {:sendspin_input_added, _}
      assert_receive {:attempt, @usb_key}, 500

      {:ok, missing_server: server, missing_sup: missing_sup}
    end

    test "marks the key once and skips it on every later poll", %{
      missing_server: server,
      missing_sup: sup
    } do
      assert DynamicSupervisor.which_children(sup) == []
      assert MapSet.member?(:sys.get_state(server).binary_missing, @usb_key)

      :ok = Server.check_now(server)
      :ok = Server.check_now(server)

      refute_receive {:attempt, _}, 200
      assert DynamicSupervisor.which_children(sup) == []
    end

    test "hotplug remove clears the flag so a re-add retries", %{missing_server: server} do
      EnumerateStub.set(%{})
      :ok = Server.check_now(server)
      assert_receive {:sendspin_input_removed, %{key: @usb_key}}
      refute MapSet.member?(:sys.get_state(server).binary_missing, @usb_key)

      EnumerateStub.set(%{@usb_key => @usb_info})
      :ok = Server.check_now(server)
      assert_receive {:attempt, @usb_key}, 500
    end
  end

  describe "uevent-driven hotplug" do
    test "a sound uevent re-enumerates; an unrelated one does not", %{server: server} do
      EnumerateStub.set(%{@usb_key => @usb_info})

      send(server, %PropertyTable.Event{
        property: ["devices", "platform", "soc", "3f980000.usb", "usb1", "1-1"],
        value: %{}
      })

      refute_receive {:sendspin_input_added, _}, 200

      send(server, %PropertyTable.Event{
        property: ["devices", "platform", "soc", "sound", "card1"],
        value: %{}
      })

      # Debounce is 1 s; give the scheduled re-enumeration margin past it.
      assert_receive {:sendspin_input_added, %{key: @usb_key}}, 2_000
    end
  end

  describe "façade degradation" do
    test "answers with safe defaults when the input subtree is down" do
      # The façade is the only layer with the `catch :exit` wrappers (the
      # Server's own client API is bare, matching Audio/Audio.Server), so
      # this is where a down subtree has to be survivable.
      :ok = Supervisor.terminate_child(UniversalProxy.Supervisor, Input.Supervisor)

      on_exit(fn ->
        Supervisor.restart_child(UniversalProxy.Supervisor, Input.Supervisor)
      end)

      refute Process.whereis(Server)

      assert Input.list_inputs() == []
      assert Input.get_input(@usb_key) == :error
      assert Input.check_now() == :ok
    end
  end
end
