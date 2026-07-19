defmodule UniversalProxy.BTD700.DeviceWorkerTest do
  # async: false — the FakeTransport reports through a global
  # `:btd700_test_controller` Application env pid (mirrors FMA120's
  # `:fma120_test_controller` fixture); running in parallel would cross-talk.
  use ExUnit.Case, async: false

  alias UniversalProxy.BTD700.DeviceWorker
  alias UniversalProxy.BTD700.Store

  @key {"1-1.3.1", 0x3542, 0x3001}
  @frame_size 64

  # Test double for `BTD700.Transport`. `open/1` reports the *opening*
  # process's own pid back to the test controller — since the worker opens
  # the writer fd in its own process and the reader opens its own fd in a
  # freshly spawned child, this is exactly how the test learns the reader's
  # pid (to drive its blocking read) without the worker exposing it as
  # public API. `read/2` blocks in a `receive` on messages sent straight to
  # the calling (reader) process — the "message-driven blocking read".
  defmodule FakeTransport do
    @behaviour UniversalProxy.BTD700.Transport

    @impl true
    def open(_path) do
      notify({:transport_open, self()})
      {:ok, self()}
    end

    @impl true
    def read(_fd, _byte_count) do
      receive do
        {:btd700_test_report, data} -> {:ok, data}
        {:btd700_test_error, reason} -> {:error, reason}
      end
    end

    @impl true
    def write(_fd, data) do
      notify({:hid_write, data})
      :ok
    end

    @impl true
    def close(_fd), do: :ok

    defp notify(msg) do
      case Application.get_env(:universal_proxy, :btd700_test_controller) do
        pid when is_pid(pid) -> send(pid, msg)
        _ -> :ok
      end
    end
  end

  setup do
    Application.put_env(:universal_proxy, :btd700_test_controller, self())
    on_exit(fn -> Application.delete_env(:universal_proxy, :btd700_test_controller) end)
    :ok
  end

  defp start_worker(opts \\ []) do
    base = [
      device_path: "/dev/hidraw0",
      key: @key,
      transport_module: FakeTransport,
      query_timeout: 2_000,
      set_timeout: 2_000,
      skip_handshake: true,
      watchdog_interval: nil
    ]

    start_supervised!({DeviceWorker, Keyword.merge(base, opts)})
  end

  # The writer fd is opened in the worker's own process (handle_continue),
  # then the reader child opens its own fd — so the first {:transport_open,
  # pid} is the worker, the second is the reader.
  defp await_reader(worker_pid) do
    assert_receive {:transport_open, ^worker_pid}, 500
    assert_receive {:transport_open, reader_pid}, 500
    refute reader_pid == worker_pid
    reader_pid
  end

  defp send_report(reader_pid, report), do: send(reader_pid, {:btd700_test_report, report})

  # Send the same message `GenServer.call/3` would, but from the test
  # process itself and without blocking — guarantees enqueue order across
  # several commands (see the wedge test) since messages from one sender to
  # one receiver are always delivered in send order, which a `GenServer.call`
  # made from a freshly spawned `Task` cannot promise relative to another.
  defp enqueue_ref(pid, cmd, args \\ <<>>) do
    ref = make_ref()
    send(pid, {:"$gen_call", {self(), ref}, {:enqueue, cmd, args}})
    ref
  end

  defp response_frame(cmd_id, payload) do
    frame(0xFF, cmd_id, payload)
  end

  defp event_frame(evt_id, payload) do
    frame(0xFC, evt_id, payload)
  end

  defp frame(marker, id, payload) do
    len = byte_size(payload)
    padding = @frame_size - 4 - len
    <<0x34, marker, id, len>> <> payload <> :binary.copy(<<0>>, padding)
  end

  # {cmd_id, reply payload, field the reply is cached/broadcast under} for
  # every read-only handshake query, in the plan's fixed order.
  @handshake_steps [
    {0x12, <<3, 11, 0, 0>>, :firmware_version},
    {0x01, <<0, 1>>, :audio_mode},
    {0x03, <<0x07, 0x00>>, :supported_codecs},
    {0x05, <<0x00, 0x00>>, :codec_in_use},
    {0x06, <<2>>, :dongle_state},
    {0x07, <<1>>, :le_audio_state},
    {0x08, <<1, 2, 0>>, :audio_quality},
    {0x09, <<0, 0, 0>>, :broadcast_info},
    {0x0D, "BTD700_TEST" <> <<0>>, :broadcast_name},
    {0x15, <<1>>, :sink_transport}
  ]

  # Waits for and answers every handshake query in order, without asserting
  # on cache/broadcast — used by tests whose focus is what runs *after* the
  # handshake (e.g. persisted-prefs re-apply).
  defp complete_handshake(reader) do
    for {cmd_id, payload, _field} <- @handshake_steps do
      assert_receive {:hid_write, <<0x34, 0xFE, ^cmd_id, _len, _rest::binary>>}, 500
      send_report(reader, response_frame(cmd_id, payload))
    end
  end

  describe "init handshake" do
    test "queries run in the plan's fixed order, populating the cache and broadcasting each" do
      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "btd700:state")
      pid = start_worker(skip_handshake: false)
      reader = await_reader(pid)

      for {cmd_id, payload, field} <- @handshake_steps do
        assert_receive {:hid_write, <<0x34, 0xFE, ^cmd_id, _len, _rest::binary>>}, 500
        send_report(reader, response_frame(cmd_id, payload))
        assert_receive {:btd700_state, @key, %{^field => _}}, 500
      end

      cache = DeviceWorker.get_state(pid)
      assert cache.firmware_version.version == "3.11.0"
      assert cache.dongle_state == :connected
      assert cache.sink_transport == :classic
      assert cache.broadcast_name == "BTD700_TEST"
    end
  end

  describe "serialized command queue" do
    test "second command is not written until the first completes" do
      pid = start_worker()
      reader = await_reader(pid)

      t1 = Task.async(fn -> DeviceWorker.command(pid, :get_dongle_state) end)
      assert_receive {:hid_write, <<0x34, 0xFE, 0x06, 0, _::binary>>}, 500

      t2 = Task.async(fn -> DeviceWorker.command(pid, :get_le_audio_state) end)
      refute_receive {:hid_write, <<0x34, 0xFE, 0x07, _::binary>>}, 300

      send_report(reader, response_frame(0x06, <<2>>))
      assert Task.await(t1) == {:ok, :connected}

      assert_receive {:hid_write, <<0x34, 0xFE, 0x07, 0, _::binary>>}, 500
      send_report(reader, response_frame(0x07, <<1>>))
      assert {:ok, _} = Task.await(t2)
    end

    test "a response is matched to the in-flight command by its cmd echo" do
      pid = start_worker()
      reader = await_reader(pid)

      t = Task.async(fn -> DeviceWorker.command(pid, :set_audio_mode, <<0, 1>>) end)
      assert_receive {:hid_write, <<0x34, 0xFE, 0x02, 2, 0, 1, _::binary>>}, 500

      send_report(reader, response_frame(0x02, <<>>))
      assert Task.await(t) == {:ok, %{}}
    end

    test "a stale/mismatched response is dropped, not treated as completion" do
      pid = start_worker()
      reader = await_reader(pid)

      t = Task.async(fn -> DeviceWorker.command(pid, :get_dongle_state) end)
      assert_receive {:hid_write, <<0x34, 0xFE, 0x06, 0, _::binary>>}, 500

      # A late reply to a different command must not complete this call.
      send_report(reader, response_frame(0x01, <<0, 1>>))
      refute Task.yield(t, 200)

      send_report(reader, response_frame(0x06, <<2>>))
      assert Task.await(t) == {:ok, :connected}
    end
  end

  describe "async event handling" do
    test "an event merges into the cache and broadcasts, without ever being acked" do
      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "btd700:state")
      pid = start_worker()
      reader = await_reader(pid)

      send_report(reader, event_frame(0x0F, <<2>>))

      assert_receive {:btd700_state, @key, %{dongle_state: :connected}}, 500
      assert DeviceWorker.get_state(pid).dongle_state == :connected
      # No ack (0xFD) — and no traffic of any kind — should ever be written.
      refute_receive {:hid_write, _}, 200
    end

    test "a non-0x34 report (the shared consumer-keys collection) is ignored" do
      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, "btd700:state")
      pid = start_worker()
      reader = await_reader(pid)

      send_report(reader, <<0x01, 0x02, 0x03, 0x00>>)

      refute_receive {:btd700_state, _, _}, 200
      assert DeviceWorker.get_state(pid) == %{}
    end
  end

  describe "timeout handling" do
    test "a command times out, replies {:error, :timeout}, and unblocks the queue" do
      pid = start_worker(query_timeout: 150)

      t1 = Task.async(fn -> DeviceWorker.command(pid, :get_dongle_state) end)
      assert_receive {:hid_write, <<0x34, 0xFE, 0x06, _::binary>>}, 500

      t2 = Task.async(fn -> DeviceWorker.command(pid, :get_le_audio_state) end)
      # No reply injected → the query timer fires, completing t1 and sending t2.
      assert Task.await(t1, 1_000) == {:error, :timeout}
      assert_receive {:hid_write, <<0x34, 0xFE, 0x07, _::binary>>}, 1_000

      _ = Task.shutdown(t2, :brutal_kill)
    end
  end

  describe "reader exit" do
    test ":enodev from the reader takes the worker down" do
      pid = start_worker()
      reader = await_reader(pid)
      ref = Process.monitor(pid)

      send(reader, {:btd700_test_error, :enodev})

      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :device_gone}}, 1_000
    end
  end

  describe "persisted preferences" do
    test "saved prefs are re-applied as set-commands after the handshake" do
      store_pid = start_test_store()

      :ok =
        Store.update_config(store_pid, @key, %{
          audio_mode: :broadcast,
          codec_mask: [:sbc, :aptx],
          broadcast_state: :on_public,
          broadcast_quality: :high,
          broadcast_encryption: true,
          broadcast_name: "Living Room"
        })

      pid = start_worker(skip_handshake: false, store: store_pid)
      reader = await_reader(pid)
      complete_handshake(reader)

      # Persisted setters are queued right after the handshake — still
      # one-in-flight, so each needs its ack (or timeout) before the next
      # is written.
      # Mode byte = persisted :broadcast (2); transport byte = the CURRENT
      # transport from the handshake's get_audio_mode reply (:classic = 1),
      # not a hardcoded 0 — 0 is a real enum value (disconnected).
      assert_receive {:hid_write, <<0x34, 0xFE, 0x02, 2, 2, 1, _::binary>>}, 500
      send_report(reader, response_frame(0x02, <<>>))

      assert_receive {:hid_write, <<0x34, 0xFE, 0x04, 2, 0x03, 0x00, _::binary>>}, 500
      send_report(reader, response_frame(0x04, <<>>))

      assert_receive {:hid_write, <<0x34, 0xFE, 0x0A, 3, 1, 1, 2, _::binary>>}, 500
      send_report(reader, response_frame(0x0A, <<>>))

      assert_receive {:hid_write, <<0x34, 0xFE, 0x0E, len, rest::binary>>}, 500
      assert binary_part(rest, 0, len) == "Living Room" <> <<0>>
    end

    test "no persisted commands are queued when nothing has been saved" do
      store_pid = start_test_store()
      pid = start_worker(skip_handshake: false, store: store_pid)
      reader = await_reader(pid)
      complete_handshake(reader)

      # complete_handshake/1 already consumed exactly the 10 expected
      # handshake writes — anything more here would be a stray persisted
      # command, which an empty store must never produce.
      refute_receive {:hid_write, _}, 300
      assert DeviceWorker.get_state(pid).dongle_state == :connected
    end
  end

  describe "wedge watchdog" do
    test "N consecutive get_dongle_state timeouts trip recovery: queue drained, sysfs toggled, :wedged_recovered" do
      root = Path.join(System.tmp_dir!(), "btd700_sysfs_#{System.unique_integer([:positive])}")
      authorized = Path.join([root, "1-1.3.1", "authorized"])
      File.mkdir_p!(Path.dirname(authorized))
      File.write!(authorized, "1")
      on_exit(fn -> File.rm_rf(root) end)

      pid =
        start_supervised!(
          {DeviceWorker,
           device_path: "/dev/hidraw0",
           key: @key,
           usb_port: "1-1.3.1",
           transport_module: FakeTransport,
           skip_handshake: true,
           watchdog_interval: nil,
           query_timeout: 30,
           allow_reauthorize: true,
           sysfs_root: root,
           reauthorize_pause: 5},
          restart: :temporary
        )

      _reader = await_reader(pid)
      ref = Process.monitor(pid)

      # Enqueue directly (bypassing the blocking `command/3` API) so all
      # five `{:enqueue, ...}` messages land in the worker's mailbox in
      # exactly this order — concurrent `Task`s racing to call `command/3`
      # would not guarantee that the last one (the one we need parked
      # *behind* everything the wedge trip itself consumes) is actually
      # enqueued last.
      #
      # The 3rd `get_dongle_state` timeout is what trips the wedge, but
      # `complete_in_flight/2` already dequeues and *sends* the next queued
      # command as part of completing that 3rd one — before this handler
      # gets to check the threshold and drain what's left. So a 4th
      # `get_dongle_state` gets auto-sent and never replied to (the worker
      # stops before its own timer fires); only a 5th command is still
      # sitting in `state.queue` for `drain_queue/2` to actually reach.
      enqueue_ref(pid, :get_dongle_state)
      enqueue_ref(pid, :get_dongle_state)
      enqueue_ref(pid, :get_dongle_state)
      enqueue_ref(pid, :get_dongle_state)
      drained_ref = enqueue_ref(pid, :get_le_audio_state)

      assert_receive {:DOWN, ^ref, :process, ^pid, :wedged_recovered}, 2_000
      # The caller still parked in queue when the wedge trips gets a clean
      # tuple via `drain_queue/2`, not the raw `:wedged_recovered` exit.
      assert_receive {^drained_ref, {:error, :device_wedged}}, 500
      # Node was toggled off -> on; final state is authorized again.
      assert File.read!(authorized) == "1"
    end

    test "timeouts of a different command do not trip the wedge" do
      pid =
        start_worker(
          watchdog_interval: nil,
          query_timeout: 30
        )

      _reader = await_reader(pid)
      ref = Process.monitor(pid)

      for _ <- 1..5, do: Task.start(fn -> DeviceWorker.command(pid, :get_le_audio_state) end)

      refute_receive {:DOWN, ^ref, :process, ^pid, :wedged_recovered}, 500
      assert Process.alive?(pid)
    end
  end

  # Distinct constant table atom (mirrors StoreTest's `@table`) — the real
  # `BTD700.Store` already runs under its default table name as part of the
  # application supervision tree during `mix test`, so reusing that default
  # here collides on `:dets.open_file/2` (`:incompatible_arguments`).
  @test_store_table :btd700_device_worker_test_store

  defp start_test_store do
    path =
      Path.join(
        System.tmp_dir!(),
        "btd700_worker_test_#{System.unique_integer([:positive])}.dets"
      )

    on_exit(fn -> File.rm(path) end)
    start_supervised!({Store, name: nil, table: @test_store_table, dets_path: path})
  end
end
