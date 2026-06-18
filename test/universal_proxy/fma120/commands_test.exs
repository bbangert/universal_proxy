defmodule UniversalProxy.FMA120.CommandsTest do
  @moduledoc "Phases 5–7: write/command API, refresh, and persisted-pref re-apply."
  use ExUnit.Case, async: false

  alias UniversalProxy.FMA120
  alias UniversalProxy.FMA120.{DeviceWorker, Store}

  @port :fake_port
  @key {"1-1.3", 0x0A12, 0x4007}

  defmodule FakeUART do
    def start_link, do: Agent.start_link(fn -> %{} end)
    def open(_pid, _port, _opts), do: :ok

    def write(_pid, data) do
      case Application.get_env(:universal_proxy, :fma120_test_controller) do
        pid when is_pid(pid) -> send(pid, {:uart_write, data})
        _ -> :ok
      end

      :ok
    end

    def close(_pid), do: :ok
    def stop(pid), do: Agent.stop(pid)
  end

  setup do
    Application.put_env(:universal_proxy, :fma120_test_controller, self())
    on_exit(fn -> Application.delete_env(:universal_proxy, :fma120_test_controller) end)
    :ok
  end

  defp reply(pid, line), do: send(pid, {:circuits_uart, @port, line <> "\r\n"})

  defp drain_writes(acc \\ []) do
    receive do
      {:uart_write, data} -> drain_writes([data | acc])
    after
      300 -> Enum.reverse(acc)
    end
  end

  describe "DeviceWorker.refresh/2" do
    test "enqueues queries that run serialized after the in-flight command" do
      pid =
        start_supervised!(
          {DeviceWorker,
           port_path: "x",
           key: @key,
           uart_module: FakeUART,
           skip_handshake: true,
           cmd_timeout: 2_000}
        )

      DeviceWorker.refresh(pid, ["FN", "ST"])
      assert_receive {:uart_write, "BC:FN\r\n"}, 500
      # ST not written until FN completes (well under cmd_timeout 2000).
      refute_receive {:uart_write, "BC:ST\r\n"}, 600
      reply(pid, "ER=01")
      assert_receive {:uart_write, "BC:ST\r\n"}, 500
    end
  end

  describe "handshake re-applies persisted prefs" do
    test "appends LF/FT/BM/BN set-commands after the read handshake" do
      store = :"fma_store_#{System.unique_integer([:positive])}"
      path = Path.join(System.tmp_dir!(), "#{store}.dets")
      on_exit(fn -> File.rm(path) end)
      start_supervised!({Store, name: store, table: store, dets_path: path})

      :ok =
        Store.update_config(store, @key, %{
          le_preference: :lea,
          feature_flags: 0x01,
          broadcast_name: "Den"
        })

      # Small timeout so each unanswered read advances quickly.
      start_supervised!(
        {DeviceWorker,
         port_path: "x",
         key: @key,
         uart_module: FakeUART,
         store: store,
         cmd_timeout: 20,
         skip_handshake: false}
      )

      writes = drain_writes()

      # Read handshake VR is first; persisted set-commands appear afterwards.
      assert "BC:VR\r\n" in writes
      assert "BC:LF=01\r\n" in writes
      assert "BC:FT=01\r\n" in writes
      assert "BC:BN=Den\r\n" in writes
      # No broadcast_mode persisted → no BM set-command.
      refute Enum.any?(writes, &String.starts_with?(&1, "BC:BM="))

      vr_idx = Enum.find_index(writes, &(&1 == "BC:VR\r\n"))
      lf_idx = Enum.find_index(writes, &(&1 == "BC:LF=01\r\n"))
      assert vr_idx < lf_idx
    end
  end

  describe "boundary guards (no device attached)" do
    test "commands return {:error, :not_found} when the key has no worker" do
      key = {"absent-#{System.unique_integer([:positive])}", 0x0A12, 0x4007}
      assert FMA120.connect(key, 0) == {:error, :not_found}
      assert FMA120.inquiry(key) == {:error, :not_found}
      assert FMA120.set_discoverable(key, true) == {:error, :not_found}
      assert FMA120.set_le_preference(key, :lea) == {:error, :not_found}
    end

    test "set_audio_mode rejects an invalid mode without touching a worker" do
      assert FMA120.set_audio_mode(@key, :nonsense) == {:error, :invalid_mode}
    end
  end
end
