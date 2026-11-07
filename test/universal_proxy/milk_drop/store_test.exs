defmodule UniversalProxy.MilkDrop.StoreTest do
  # async: false — DETS table names must be atoms; one constant atom is
  # reused across tests (the GenServer itself is unnamed), and the PubSub
  # topic is global.
  use ExUnit.Case, async: false

  alias UniversalProxy.MilkDrop
  import ExUnit.CaptureLog

  alias UniversalProxy.MilkDrop.Store

  @moduletag :tmp_dir
  @table :milkdrop_store_test

  setup %{tmp_dir: tmp_dir} do
    {:ok, path: Path.join(tmp_dir, "settings.dets")}
  end

  defp start_store(path) do
    start_supervised!({Store, name: nil, table: @table, dets_path: path})
  end

  defp wait_until(fun, timeout \\ 2_000) do
    cond do
      fun.() ->
        :ok

      timeout <= 0 ->
        flunk("condition not met in time")

      true ->
        Process.sleep(10)
        wait_until(fun, timeout - 10)
    end
  end

  describe "settings" do
    test "defaults on a fresh file", %{path: path} do
      server = start_store(path)
      assert Store.settings(server) == %{include_high_frequency: false, rotate_s: 20, locked: nil}
    end

    test "round-trip survives a restart", %{path: path} do
      server = start_store(path)

      {:ok, _} = Store.update(server, %{include_high_frequency: true, rotate_s: 45})

      assert {:ok, %{include_high_frequency: true, rotate_s: 45, locked: "a/b.milk"}} =
               Store.update(server, %{"locked" => "a/b.milk"})

      stop_supervised!(Store)
      server = start_store(path)

      assert Store.settings(server) == %{
               include_high_frequency: true,
               rotate_s: 45,
               locked: "a/b.milk"
             }
    end

    test "an explicit nil/false is kept", %{path: path} do
      server = start_store(path)
      {:ok, _} = Store.update(server, %{include_high_frequency: true, locked: "x.milk"})

      assert {:ok, %{include_high_frequency: false, locked: nil}} =
               Store.update(server, %{include_high_frequency: false, locked: nil})
    end

    test "rotate_s is clamped to 10..120", %{path: path} do
      server = start_store(path)
      assert {:ok, %{rotate_s: 10}} = Store.update(server, %{rotate_s: 1})
      assert {:ok, %{rotate_s: 120}} = Store.update(server, %{rotate_s: 9_999})
      assert {:ok, %{rotate_s: 30}} = Store.update(server, %{rotate_s: 30})
    end

    test "wrongly-typed values keep the saved value; unknown keys are dropped", %{path: path} do
      server = start_store(path)
      {:ok, _} = Store.update(server, %{rotate_s: 30, include_high_frequency: true})

      assert {:ok, settings} =
               Store.update(server, %{
                 rotate_s: "fast",
                 include_high_frequency: "yes",
                 locked: "",
                 bogus: 1
               })

      assert settings == %{include_high_frequency: true, rotate_s: 30, locked: nil}
    end

    test "changes are broadcast", %{path: path} do
      server = start_store(path)
      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, MilkDrop.settings_topic())

      {:ok, settings} = Store.update(server, %{rotate_s: 60})
      assert_receive {:milkdrop_settings, ^settings}

      # No change, no broadcast.
      {:ok, _} = Store.update(server, %{rotate_s: 60})
      refute_receive {:milkdrop_settings, _}, 50
    end
  end

  describe "skip list" do
    test "records skips for the current pack version", %{path: path} do
      server = start_store(path)
      assert :ok = Store.skip(server, "2026.11.1", "a.milk", "compile")
      assert :ok = Store.skip(server, "2026.11.1", "b.milk", :budget)

      assert Store.skipped(server, "2026.11.1") == %{"a.milk" => "compile", "b.milk" => "budget"}
      assert Store.skipped(server, "2026.12.1") == %{}

      stop_supervised!(Store)
      server = start_store(path)
      assert Store.skipped(server, "2026.11.1") == %{"a.milk" => "compile", "b.milk" => "budget"}
    end

    test "a skip for another version drops the old entries", %{path: path} do
      server = start_store(path)
      :ok = Store.skip(server, "2026.11.1", "a.milk", "compile")
      :ok = Store.skip(server, "2026.12.1", "c.milk", "draw")

      assert Store.skipped(server, "2026.11.1") == %{}
      assert Store.skipped(server, "2026.12.1") == %{"c.milk" => "draw"}
    end

    test "clear_skipped/1 forgets everything and broadcasts", %{path: path} do
      server = start_store(path)
      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, MilkDrop.settings_topic())

      :ok = Store.skip(server, "v1", "a.milk", "compile")
      assert_receive {:milkdrop_skipped, "v1", %{"a.milk" => "compile"}}

      assert :ok = Store.clear_skipped(server)
      assert_receive {:milkdrop_skipped, nil, %{}}
      assert Store.skipped(server, "v1") == %{}
    end
  end

  describe "in-flight record" do
    # Not restarted by the test supervisor, so a test can kill it (a power
    # cut: no terminate/2) and start the next "boot" with another boot id.
    defp start_boot(path, boot_id, opts \\ []) do
      opts =
        Keyword.merge(
          [name: nil, table: @table, dets_path: path, boot_id: boot_id, pack_version: nil],
          opts
        )

      start_supervised!(Supervisor.child_spec({Store, opts}, restart: :temporary))
    end

    defp power_cut(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    end

    test "a mark replaces the last one and is read back", %{path: path} do
      server = start_boot(path, "boot-1")
      assert Store.in_flight(server) == nil

      assert :ok = Store.mark_in_flight(server, 7, "v1", "a.milk")
      assert :ok = Store.mark_in_flight(server, 7, "v1", "b.milk")

      assert %{pack_version: "v1", preset: "b.milk", session: 7, boot_id: "boot-1", at: at} =
               Store.in_flight(server)

      assert is_integer(at)
    end

    test "clear_in_flight/2 clears only its own session's record", %{path: path} do
      server = start_boot(path, "boot-1", in_flight_grace_ms: 0)

      :ok = Store.mark_in_flight(server, 7, "v1", "a.milk")
      assert :ok = Store.clear_in_flight(server, 8)
      assert %{preset: "a.milk"} = Store.in_flight(server)

      assert :ok = Store.clear_in_flight(server, 7)
      assert Store.in_flight(server) == nil
      assert :ok = Store.clear_in_flight(server, 7)
    end

    test "a clear waits out the grace period, and spares a newer record", %{path: path} do
      server = start_boot(path, "boot-1", in_flight_grace_ms: 100)

      :ok = Store.mark_in_flight(server, 7, "v1", "a.milk")
      :ok = Store.clear_in_flight(server, 7)
      assert %{preset: "a.milk"} = Store.in_flight(server)
      wait_until(fn -> Store.in_flight(server) == nil end)

      # Re-marked before the grace period ended: the newer record stays.
      :ok = Store.mark_in_flight(server, 7, "v1", "a.milk")
      :ok = Store.clear_in_flight(server, 7)
      :ok = Store.mark_in_flight(server, 9, "v1", "b.milk")
      Process.sleep(200)
      assert %{preset: "b.milk", session: 9} = Store.in_flight(server)
    end

    test "a clear spares a re-mark of the same preset by the same session", %{path: path} do
      server = start_boot(path, "boot-1", in_flight_grace_ms: 100)

      # Within one second: the same preset, session and timestamp.
      :ok = Store.mark_in_flight(server, 7, "v1", "a.milk")
      %{generation: first} = Store.in_flight(server)
      :ok = Store.clear_in_flight(server, 7)
      :ok = Store.mark_in_flight(server, 7, "v1", "a.milk")
      %{generation: second} = Store.in_flight(server)
      assert first != second

      Process.sleep(200)
      assert %{preset: "a.milk", session: 7, generation: ^second} = Store.in_flight(server)

      # Its own clear still applies.
      :ok = Store.clear_in_flight(server, 7)
      wait_until(fn -> Store.in_flight(server) == nil end)
    end

    test "a record from an earlier boot skips its preset as device_reset", %{path: path} do
      server = start_boot(path, "boot-1")
      :ok = Store.skip(server, "v1", "slow.milk", "budget")
      :ok = Store.mark_in_flight(server, 7, "v1", "hang.milk")
      power_cut(server)

      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, MilkDrop.settings_topic())

      {server, log} = with_log(fn -> start_boot(path, "boot-2") end)

      assert log =~
               "MilkDrop preset hang.milk was running when the device last stopped; skipping it"

      assert Store.skipped(server, "v1") == %{
               "slow.milk" => "budget",
               "hang.milk" => "device_reset"
             }

      assert_receive {:milkdrop_skipped, "v1", %{"hang.milk" => "device_reset"}}
      assert Store.in_flight(server) == nil

      # Consumed: the next boot skips nothing new.
      power_cut(server)
      server = start_boot(path, "boot-3")

      assert Store.skipped(server, "v1") == %{
               "slow.milk" => "budget",
               "hang.milk" => "device_reset"
             }
    end

    test "a record survives a store restart within the same boot", %{path: path} do
      server = start_boot(path, "boot-1")
      :ok = Store.mark_in_flight(server, 7, "v1", "a.milk")
      power_cut(server)

      server = start_boot(path, "boot-1")
      assert %{preset: "a.milk", session: 7} = Store.in_flight(server)
      assert Store.skipped(server, "v1") == %{}

      # Its session can still clear it.
      :ok = Store.clear_in_flight(server, 7)
      assert %{preset: "a.milk"} = Store.in_flight(server)
    end

    test "a store killed during the grace period still clears the record", %{path: path} do
      server = start_boot(path, "boot-1", in_flight_grace_ms: 300)
      :ok = Store.mark_in_flight(server, 7, "v1", "a.milk")
      :ok = Store.clear_in_flight(server, 7)
      assert %{clear_at: clear_at} = Store.in_flight(server)
      assert is_integer(clear_at)
      power_cut(server)

      # Restarted before the deadline: kept until then, then cleared.
      server = start_boot(path, "boot-1", in_flight_grace_ms: 300)
      assert %{preset: "a.milk", clear_at: ^clear_at} = Store.in_flight(server)
      wait_until(fn -> Store.in_flight(server) == nil end)

      # A later power cut skips nothing.
      power_cut(server)
      server = start_boot(path, "boot-2")
      assert Store.skipped(server, "v1") == %{}
    end

    test "a pending clear past its deadline applies when the store reopens", %{path: path} do
      server = start_boot(path, "boot-1", in_flight_grace_ms: 50)
      :ok = Store.mark_in_flight(server, 7, "v1", "a.milk")
      :ok = Store.clear_in_flight(server, 7)
      power_cut(server)
      Process.sleep(100)

      server = start_boot(path, "boot-1", in_flight_grace_ms: 50)
      assert Store.in_flight(server) == nil
      power_cut(server)

      server = start_boot(path, "boot-2")
      assert Store.skipped(server, "v1") == %{}
    end

    test "a pending clear waits at most one grace period after a restart", %{path: path} do
      # A clock stepped back: the persisted deadline is far ahead.
      server = start_boot(path, "boot-1", in_flight_grace_ms: 60_000)
      :ok = Store.mark_in_flight(server, 7, "v1", "a.milk")
      :ok = Store.clear_in_flight(server, 7)
      power_cut(server)

      server = start_boot(path, "boot-1", in_flight_grace_ms: 100)
      assert %{preset: "a.milk"} = Store.in_flight(server)
      wait_until(fn -> Store.in_flight(server) == nil end)
    end

    test "a re-mark after a clear is active again across a store restart", %{path: path} do
      server = start_boot(path, "boot-1", in_flight_grace_ms: 100)
      :ok = Store.mark_in_flight(server, 7, "v1", "a.milk")
      :ok = Store.clear_in_flight(server, 7)
      :ok = Store.mark_in_flight(server, 8, "v1", "b.milk")
      assert %{session: 8, clear_at: nil} = Store.in_flight(server)
      power_cut(server)

      server = start_boot(path, "boot-1", in_flight_grace_ms: 100)
      Process.sleep(200)
      assert %{preset: "b.milk", session: 8} = Store.in_flight(server)
    end

    test "a power cut during the grace period still skips the preset", %{path: path} do
      server = start_boot(path, "boot-1", in_flight_grace_ms: 5_000)
      :ok = Store.mark_in_flight(server, 7, "v1", "hang.milk")
      :ok = Store.clear_in_flight(server, 7)
      power_cut(server)

      {server, _log} = with_log(fn -> start_boot(path, "boot-2") end)
      assert Store.skipped(server, "v1") == %{"hang.milk" => "device_reset"}
      assert Store.in_flight(server) == nil
    end

    test "an orderly shutdown is not a device reset", %{path: path} do
      server = start_boot(path, "boot-1")
      :ok = Store.mark_in_flight(server, 7, "v1", "a.milk")
      :ok = GenServer.stop(server, :shutdown)

      server = start_boot(path, "boot-2")
      assert Store.in_flight(server) == nil
      assert Store.skipped(server, "v1") == %{}
    end

    @tag capture_log: true
    test "a record for a pack that is no longer pinned is dropped", %{path: path} do
      server = start_boot(path, "boot-1")
      :ok = Store.skip(server, "v1", "slow.milk", "budget")
      :ok = Store.mark_in_flight(server, 7, "v1", "a.milk")
      power_cut(server)

      server = start_boot(path, "boot-2", pack_version: "v2")
      assert Store.in_flight(server) == nil
      assert Store.skipped(server, "v1") == %{"slow.milk" => "budget"}
    end

    test "a record for the pinned pack replaces an older pack's skips", %{path: path} do
      server = start_boot(path, "boot-1")
      :ok = Store.skip(server, "v1", "slow.milk", "budget")
      :ok = Store.mark_in_flight(server, 7, "v2", "a.milk")
      power_cut(server)

      {server, _log} = with_log(fn -> start_boot(path, "boot-2", pack_version: "v2") end)
      assert Store.skipped(server, "v2") == %{"a.milk" => "device_reset"}
      assert Store.skipped(server, "v1") == %{}
    end

    @tag capture_log: true
    test "a malformed record is deleted", %{path: path} do
      {:ok, table} = :dets.open_file(@table, file: to_charlist(path), type: :set)
      :ok = :dets.insert(table, {:in_flight, {:bogus}})
      :ok = :dets.close(table)

      server = start_boot(path, "boot-2")
      assert Store.in_flight(server) == nil
      assert Store.skipped(server, "v1") == %{}
      power_cut(server)

      {:ok, table} = :dets.open_file(@table, file: to_charlist(path), type: :set)
      assert :dets.lookup(table, :in_flight) == []
      :ok = :dets.close(table)
    end
  end

  describe "corruption" do
    @tag capture_log: true
    test "a file DETS can't open is moved aside and defaults are served", %{path: path} do
      File.write!(path, :crypto.strong_rand_bytes(4096))

      server = start_store(path)
      assert Store.settings(server) == Store.defaults()
      assert Store.skipped(server, "v1") == %{}
      assert File.exists?(path <> ".corrupt")

      assert {:ok, %{rotate_s: 40}} = Store.update(server, %{rotate_s: 40})
    end

    @tag capture_log: true
    test "a truncated DETS file is moved aside", %{path: path} do
      {:ok, table} = :dets.open_file(@table, file: to_charlist(path), type: :set)
      for i <- 1..2000, do: :dets.insert(table, {i, String.duplicate("x", 100)})
      :ok = :dets.close(table)
      File.write!(path, binary_part(File.read!(path), 0, 3000))

      server = start_store(path)
      assert Store.settings(server) == Store.defaults()
      assert File.exists?(path <> ".corrupt")
      assert {:ok, %{rotate_s: 40}} = Store.update(server, %{rotate_s: 40})
    end

    @tag capture_log: true
    test "an unreadable file is left in place and reopened on the next write", %{path: path} do
      server = start_store(path)
      {:ok, _} = Store.update(server, %{rotate_s: 45})
      stop_supervised!(Store)

      File.chmod!(path, 0o000)
      on_exit(fn -> File.chmod(path, 0o644) end)

      # Root ignores file modes, so the file would simply open.
      if match?({:error, _}, File.read(path)) do
        server = start_store(path)
        assert Store.settings(server) == Store.defaults()
        assert {:error, {:file_error, _, :eacces}} = Store.update(server, %{rotate_s: 60})
        assert {:error, {:file_error, _, :eacces}} = Store.skip(server, "v1", "a.milk", "draw")
        refute File.exists?(path <> ".corrupt")

        File.chmod!(path, 0o644)

        # The saved record survived: an empty update reopens the table and
        # returns it unchanged.
        assert {:ok, %{rotate_s: 45}} = Store.update(server, %{})
        refute File.exists?(path <> ".corrupt")

        assert {:ok, %{rotate_s: 70, include_high_frequency: true}} =
                 Store.update(server, %{rotate_s: 70, include_high_frequency: true})
      end
    end

    @tag capture_log: true
    test "an unusable directory keeps the store up and the timer reopens it", %{tmp_dir: tmp_dir} do
      blocker = Path.join(tmp_dir, "blocker")
      File.write!(blocker, "not a directory")
      path = Path.join(blocker, "settings.dets")

      server =
        start_supervised!({Store, name: nil, table: @table, dets_path: path, retry_ms: 20})

      assert Store.settings(server) == Store.defaults()
      assert {:error, _} = Store.update(server, %{rotate_s: 30})

      File.rm!(blocker)
      wait_until(fn -> :sys.get_state(server).table != nil end)
      assert {:ok, %{rotate_s: 30}} = Store.update(server, %{rotate_s: 30})
    end

    @tag capture_log: true
    test "clear_skipped on a closed table reports the open error, then reopens", %{
      tmp_dir: tmp_dir
    } do
      blocker = Path.join(tmp_dir, "blocker")
      File.write!(blocker, "not a directory")
      path = Path.join(blocker, "settings.dets")

      server =
        start_supervised!({Store, name: nil, table: @table, dets_path: path, retry_ms: 0})

      assert :sys.get_state(server).table == nil
      assert {:error, reason} = Store.clear_skipped(server)
      assert reason != :not_running

      File.rm!(blocker)
      assert :ok = Store.clear_skipped(server)
      assert :sys.get_state(server).table != nil
    end

    test "malformed records read as defaults", %{path: path} do
      {:ok, table} = :dets.open_file(@table, file: to_charlist(path), type: :set)
      :ok = :dets.insert(table, {:settings, %{rotate_s: :fast, include_high_frequency: 1}})
      :ok = :dets.insert(table, {:skipped, :not_a_tuple})
      :ok = :dets.close(table)

      server = start_store(path)
      assert Store.settings(server) == Store.defaults()
      assert Store.skipped(server, "v1") == %{}
    end

    test "out-of-range stored values are clamped on read", %{path: path} do
      {:ok, table} = :dets.open_file(@table, file: to_charlist(path), type: :set)
      :ok = :dets.insert(table, {:settings, %{rotate_s: 5000, locked: 42}})
      :ok = :dets.insert(table, {:skipped, {"v1", %{"a.milk" => "draw", :bad => 1}}})
      :ok = :dets.close(table)

      server = start_store(path)

      assert Store.settings(server) == %{
               include_high_frequency: false,
               rotate_s: 120,
               locked: nil
             }

      assert Store.skipped(server, "v1") == %{"a.milk" => "draw"}
    end
  end

  describe "not running" do
    test "reads return defaults, writes an error" do
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, _, _, _}

      assert Store.settings(dead) == Store.defaults()
      assert Store.skipped(dead, "v1") == %{}
      assert Store.update(dead, %{rotate_s: 30}) == {:error, :not_running}
      assert Store.skip(dead, "v1", "a.milk", "draw") == {:error, :not_running}
      assert Store.clear_skipped(dead) == {:error, :not_running}
      assert Store.in_flight(dead) == nil
      assert Store.mark_in_flight(dead, 1, "v1", "a.milk") == {:error, :not_running}
      assert Store.clear_in_flight(dead, 1) == {:error, :not_running}
    end
  end
end
