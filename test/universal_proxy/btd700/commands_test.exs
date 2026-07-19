defmodule UniversalProxy.BTD700.CommandsTest do
  @moduledoc """
  Phase 4: the `BTD700` public boundary — command -> wire mapping,
  persist-before-send ordering, codec list->mask, name/key length guards,
  `call_worker/2`'s timeout-split, and `:not_found` guards.

  `BTD700.ex` hardcodes its `Server`/`Store` targets to their default
  (singleton) names, same as `FMA120.ex` — there is no override seam. So
  exercising real command dispatch means driving the real, already-running
  `UniversalProxy.BTD700.Server` (started by the application under test),
  with a real `DeviceWorker` + `FakeTransport` spliced into its inventory
  via `:sys.replace_state/2` (removed again in `on_exit`). This is more
  invasive than FMA120's own `commands_test.exs` (which sidesteps the
  problem entirely and only exercises the boundary's no-worker guards) —
  but the plan calls for wire-level assertions here, so the splice is the
  only way to reach them without adding a test-only seam to the boundary.

  async: false — mutates the shared singleton `BTD700.Server`'s inventory.
  """
  use ExUnit.Case, async: false

  alias UniversalProxy.BTD700
  alias UniversalProxy.BTD700.{DeviceWorker, Server, Store}

  @frame_size 64

  # A fresh, never-before-used key per test run (the real `Store` is a
  # singleton DETS table with no delete — see its moduledoc — so reusing a
  # fixed literal here would leak state across `mix test` invocations that
  # don't recompile this file). Harmless accumulation in the dev `_build`
  # dets file; never queried by any other test. The suffix is random, NOT
  # `System.unique_integer` — the DETS file outlives the VM while the
  # counter restarts with it, so counter-suffixed keys can collide with a
  # record persisted by a previous run and fail this run's "nothing saved"
  # assertions (witnessed in review, 2026-07-19).
  setup do
    key = {"1-1.9-#{Base.encode16(:crypto.strong_rand_bytes(4))}", 0x3542, 0x3001}
    {:ok, key: key}
  end

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
        {:btd700_cmd_test_report, data} -> {:ok, data}
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
      case Application.get_env(:universal_proxy, :btd700_cmd_test_controller) do
        pid when is_pid(pid) -> send(pid, msg)
        _ -> :ok
      end
    end
  end

  setup do
    Application.put_env(:universal_proxy, :btd700_cmd_test_controller, self())
    on_exit(fn -> Application.delete_env(:universal_proxy, :btd700_cmd_test_controller) end)
    :ok
  end

  defp start_worker(key) do
    start_supervised!(
      {DeviceWorker,
       device_path: "/dev/hidraw-cmdtest",
       key: key,
       transport_module: FakeTransport,
       skip_handshake: true,
       watchdog_interval: nil,
       query_timeout: 2_000,
       set_timeout: 2_000}
    )
  end

  defp await_reader(worker_pid) do
    assert_receive {:transport_open, ^worker_pid}, 500
    assert_receive {:transport_open, reader_pid}, 500
    refute reader_pid == worker_pid
    reader_pid
  end

  # Splice a spliced-in entry directly into the real, application-started
  # `BTD700.Server`'s inventory so `Server.worker_for/2` (and therefore
  # every boundary function under test) resolves `key` to `worker_pid`.
  # Never exercises Server's own restart/removal machinery (that's
  # server_test.exs/resilience_test.exs's job) — `monitor: nil` since we
  # tear the entry down ourselves in `on_exit`, not via a `:DOWN`.
  defp inject_worker(key, worker_pid) do
    entry = %{
      key: key,
      usb_port: elem(key, 0),
      device_path: "/dev/hidraw-cmdtest",
      worker_pid: worker_pid,
      monitor: nil,
      crash_count: 0,
      last_start: System.monotonic_time(:millisecond),
      retry_timer: nil
    }

    :sys.replace_state(Server, fn state ->
      %{state | inventory: [entry | Enum.reject(state.inventory, &(&1.key == key))]}
    end)

    on_exit(fn ->
      :sys.replace_state(Server, fn state ->
        %{state | inventory: Enum.reject(state.inventory, &(&1.key == key))}
      end)
    end)

    :ok
  end

  defp setup_worker(key) do
    worker = start_worker(key)
    reader = await_reader(worker)
    inject_worker(key, worker)
    reader
  end

  defp send_report(reader_pid, report), do: send(reader_pid, {:btd700_cmd_test_report, report})

  defp response_frame(cmd_id, payload \\ <<>>), do: frame(0xFF, cmd_id, payload)

  defp frame(marker, id, payload) do
    len = byte_size(payload)
    padding = @frame_size - 4 - len
    <<0x34, marker, id, len>> <> payload <> :binary.copy(<<0>>, padding)
  end

  # The 10 read-only handshake getters, in the plan's fixed order — used to
  # drain `refresh/1`'s (and `factory_reset/1`'s) full re-query.
  @full_refresh_ids [0x12, 0x01, 0x03, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0D, 0x15]

  describe "set_audio_mode/2" do
    test "persists before sending, pairs the mode with the CURRENT transport, and refreshes",
         %{key: key} do
      reader = setup_worker(key)

      task = Task.async(fn -> BTD700.set_audio_mode(key, :broadcast) end)

      # Mode byte 2 (:broadcast); transport byte falls back to 0
      # (:disconnected) since this worker's state_cache never populated
      # `audio_mode` (skip_handshake: true) — 0 is the documented fallback,
      # not evidence of a hardcoded value.
      assert_receive {:hid_write, <<0x34, 0xFE, 0x02, 2, 2, 0, _::binary>>}, 500

      # Persisted synchronously BEFORE the write above could even happen
      # (persist_and_send calls Store.update_config, then with_worker).
      assert {:ok, %{audio_mode: :broadcast}} = Store.get_config(key)

      send_report(reader, response_frame(0x02))
      assert Task.await(task) == :ok

      # Setter ack carries no payload -> send_and_refresh re-queries.
      assert_receive {:hid_write, <<0x34, 0xFE, 0x01, 0, _::binary>>}, 500
    end

    test "an invalid mode is rejected without persisting or touching a worker", %{key: key} do
      assert BTD700.set_audio_mode(key, :nonsense) == {:error, :invalid_mode}
      assert Store.get_config(key) == :error
    end
  end

  describe "set_codec_mask/2" do
    test "encodes the codec list as a u16 LE mask and refreshes both codec getters", %{key: key} do
      reader = setup_worker(key)

      # bit 1 (:aptx) + bit 5 (:lc3) = 0b10_0010 = 0x22.
      task = Task.async(fn -> BTD700.set_codec_mask(key, [:aptx, :lc3]) end)

      assert_receive {:hid_write, <<0x34, 0xFE, 0x04, 2, 0x22, 0x00, _::binary>>}, 500
      assert {:ok, %{codec_mask: [:aptx, :lc3]}} = Store.get_config(key)

      send_report(reader, response_frame(0x04))
      assert Task.await(task) == :ok

      assert_receive {:hid_write, <<0x34, 0xFE, 0x05, 0, _::binary>>}, 500
      send_report(reader, response_frame(0x05, <<0x22, 0x00>>))
      assert_receive {:hid_write, <<0x34, 0xFE, 0x03, 0, _::binary>>}, 500
    end
  end

  describe "connect/1 and disconnect/1" do
    test "connect sends bt_connect with arg 1 and refreshes dongle_state, without persisting",
         %{key: key} do
      reader = setup_worker(key)

      task = Task.async(fn -> BTD700.connect(key) end)
      assert_receive {:hid_write, <<0x34, 0xFE, 0x14, 1, 1, _::binary>>}, 500
      assert Store.get_config(key) == :error

      send_report(reader, response_frame(0x14))
      assert Task.await(task) == :ok
      assert_receive {:hid_write, <<0x34, 0xFE, 0x06, 0, _::binary>>}, 500
    end

    test "disconnect sends bt_connect with arg 0 and refreshes dongle_state", %{key: key} do
      reader = setup_worker(key)

      task = Task.async(fn -> BTD700.disconnect(key) end)
      assert_receive {:hid_write, <<0x34, 0xFE, 0x14, 1, 0, _::binary>>}, 500

      send_report(reader, response_frame(0x14))
      assert Task.await(task) == :ok
      assert_receive {:hid_write, <<0x34, 0xFE, 0x06, 0, _::binary>>}, 500
    end
  end

  describe "set_broadcast_info/2" do
    test "bundles state/encryption/quality into one frame, persists all three, and refreshes",
         %{key: key} do
      reader = setup_worker(key)

      task =
        Task.async(fn ->
          BTD700.set_broadcast_info(key, %{state: :on_public, encryption: true, quality: :high})
        end)

      # Corrected wire order: [state=on, quality=high, encryption=on].
      assert_receive {:hid_write, <<0x34, 0xFE, 0x0A, 3, 1, 2, 1, _::binary>>}, 500

      assert {:ok,
              %{broadcast_state: :on_public, broadcast_quality: :high, broadcast_encryption: true}} =
               Store.get_config(key)

      send_report(reader, response_frame(0x0A))
      assert Task.await(task) == :ok
      assert_receive {:hid_write, <<0x34, 0xFE, 0x09, 0, _::binary>>}, 500
    end
  end

  describe "set_broadcast_name/2" do
    test "persists and sends the raw name (Protocol NUL-terminates), then refreshes", %{
      key: key
    } do
      reader = setup_worker(key)

      task = Task.async(fn -> BTD700.set_broadcast_name(key, "Den") end)

      assert_receive {:hid_write, <<0x34, 0xFE, 0x0E, len, rest::binary>>}, 500
      assert binary_part(rest, 0, len) == "Den" <> <<0>>
      assert {:ok, %{broadcast_name: "Den"}} = Store.get_config(key)

      send_report(reader, response_frame(0x0E))
      assert Task.await(task) == :ok
      assert_receive {:hid_write, <<0x34, 0xFE, 0x0D, 0, _::binary>>}, 500
    end

    test "a name over 59 bytes is rejected with :name_too_long, never persisted or sent",
         %{key: key} do
      too_long = String.duplicate("x", 60)

      assert BTD700.set_broadcast_name(key, too_long) == {:error, :name_too_long}
      assert Store.get_config(key) == :error
      refute_receive {:hid_write, _}, 200
    end

    test "exactly 59 bytes is accepted (the boundary of the wire window)", %{key: key} do
      reader = setup_worker(key)
      name = String.duplicate("x", 59)

      task = Task.async(fn -> BTD700.set_broadcast_name(key, name) end)
      # 59-byte name + trailing NUL = the full 60-byte payload window.
      assert_receive {:hid_write, <<0x34, 0xFE, 0x0E, 60, _::binary>>}, 500

      send_report(reader, response_frame(0x0E))
      assert Task.await(task) == :ok
    end
  end

  describe "set_broadcast_key/2" do
    test "sends the key but never persists it, then refreshes broadcast_info", %{key: key} do
      reader = setup_worker(key)

      task = Task.async(fn -> BTD700.set_broadcast_key(key, "s3cr3t") end)
      assert_receive {:hid_write, <<0x34, 0xFE, 0x0C, 6, "s3cr3t", _::binary>>}, 500

      # The key never reaches the Store — only `broadcast_encryption` (set
      # via `set_broadcast_info/2`) round-trips through it.
      assert Store.get_config(key) == :error

      send_report(reader, response_frame(0x0C))
      assert Task.await(task) == :ok
      assert_receive {:hid_write, <<0x34, 0xFE, 0x09, 0, _::binary>>}, 500
    end

    test "a key over 60 bytes is rejected without touching the worker", %{key: key} do
      reader = setup_worker(key)
      too_long = String.duplicate("k", 61)

      assert BTD700.set_broadcast_key(key, too_long) == {:error, :key_too_long}
      refute_receive {:hid_write, _}, 200
      # Silence "unused variable" — the reader is only needed to prove the
      # worker was reachable at all (setup_worker/1's side effect).
      assert is_pid(reader)
    end
  end

  describe "factory_reset/1" do
    test "sends factory_reset (no args), then re-queries the full handshake set in order",
         %{key: key} do
      reader = setup_worker(key)

      task = Task.async(fn -> BTD700.factory_reset(key) end)
      assert_receive {:hid_write, <<0x34, 0xFE, 0x13, 0, _::binary>>}, 500
      assert Store.get_config(key) == :error

      send_report(reader, response_frame(0x13))
      assert Task.await(task) == :ok

      for cmd_id <- @full_refresh_ids do
        assert_receive {:hid_write, <<0x34, 0xFE, ^cmd_id, _len, _rest::binary>>}, 500
        send_report(reader, response_frame(cmd_id))
      end
    end
  end

  describe "refresh/1" do
    test "re-queries the full handshake set in the plan's fixed order", %{key: key} do
      reader = setup_worker(key)

      task = Task.async(fn -> BTD700.refresh(key) end)

      for cmd_id <- @full_refresh_ids do
        assert_receive {:hid_write, <<0x34, 0xFE, ^cmd_id, _len, _rest::binary>>}, 500
        send_report(reader, response_frame(cmd_id))
      end

      assert Task.await(task) == :ok
    end
  end

  describe "boundary guards (no device attached)" do
    test "commands return {:error, :not_found} when the key has no worker", %{key: key} do
      assert BTD700.set_audio_mode(key, :high_quality) == {:error, :not_found}
      assert BTD700.set_codec_mask(key, [:sbc]) == {:error, :not_found}
      assert BTD700.connect(key) == {:error, :not_found}
      assert BTD700.disconnect(key) == {:error, :not_found}

      assert BTD700.set_broadcast_info(key, %{
               state: :on_public,
               encryption: false,
               quality: :standard_16k
             }) == {:error, :not_found}

      assert BTD700.set_broadcast_name(key, "ok") == {:error, :not_found}
      assert BTD700.set_broadcast_key(key, "ok") == {:error, :not_found}
      assert BTD700.factory_reset(key) == {:error, :not_found}
      assert BTD700.refresh(key) == {:error, :not_found}
    end
  end

  describe "call_worker/2 timeout conversion" do
    test "a wedged worker call returns {:error, :timeout} instead of exiting" do
      # A process that never replies — the shape of a wedged DeviceWorker.
      wedged = spawn_link(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(wedged, :kill) end)

      assert BTD700.call_worker(wedged, fn pid ->
               GenServer.call(pid, :anything, 100)
             end) == {:error, :timeout}
    end

    test "a worker that stops mid-call returns {:error, :unavailable} instead of exiting" do
      # The wedge-recovery path stops the worker with a non-normal reason
      # while callers may still be blocked in GenServer.call.
      dying = spawn(fn -> receive(do: (_ -> exit(:wedged_recovered))) end)

      assert BTD700.call_worker(dying, fn pid ->
               GenServer.call(pid, :anything, 1_000)
             end) == {:error, :unavailable}
    end
  end
end
