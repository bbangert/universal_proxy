defmodule UniversalProxy.MilkDrop.StoreTest do
  # async: false — DETS table names must be atoms; one constant atom is
  # reused across tests (the GenServer itself is unnamed), and the PubSub
  # topic is global.
  use ExUnit.Case, async: false

  alias UniversalProxy.MilkDrop
  alias UniversalProxy.MilkDrop.Store

  @moduletag :tmp_dir
  @table :milkdrop_store_test

  setup %{tmp_dir: tmp_dir} do
    {:ok, path: Path.join(tmp_dir, "settings.dets")}
  end

  defp start_store(path) do
    start_supervised!({Store, name: nil, table: @table, dets_path: path})
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
    end
  end
end
