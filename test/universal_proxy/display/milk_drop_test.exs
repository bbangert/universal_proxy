defmodule UniversalProxy.Display.MilkDropTest do
  # async: false — the test Store's DETS table name is a shared atom.
  use ExUnit.Case, async: false

  alias UniversalProxy.Display.MilkDrop
  alias UniversalProxy.MilkDrop.Store

  @moduletag :tmp_dir
  @moduletag :python3

  @fake_binary Path.expand("../../support/fake_milkdrop_renderer.py", __DIR__)
  @table :milkdrop_display_test
  @version "2026.11.1"
  @mode %{width: 1280, height: 720, refresh: 60}
  # Each event is a round trip through a Python process; allow for a loaded host.
  @timeout 5_000

  setup %{tmp_dir: tmp_dir} do
    store =
      start_supervised!(
        {Store,
         name: nil,
         table: @table,
         dets_path: Path.join(tmp_dir, "settings.dets"),
         in_flight_grace_ms: 0}
      )

    skip_file = Path.join(tmp_dir, "skip.txt")
    # Every fake renderer this test spawned has its (per-test) skip file in argv.
    on_exit(fn -> Enum.each(renderer_os_pids(skip_file), &kill_os_pid/1) end)

    {:ok, store: store, skip_file: skip_file, pack_dir: tmp_dir}
  end

  defp start_renderer(ctx, opts \\ []) do
    opts =
      Keyword.merge(
        [
          mode: @mode,
          pack_dir: ctx.pack_dir,
          pack_version: @version,
          ladder: ["640x360", "480x270"],
          store: ctx.store,
          skip_file: ctx.skip_file,
          binary: @fake_binary
        ],
        opts
      )

    {:ok, pid} = MilkDrop.start(opts)
    on_exit(fn -> MilkDrop.stop(pid) end)
    assert_receive {:milkdrop, ^pid, %{event: :prepared} = prepared}, @timeout
    {pid, prepared}
  end

  defp emit(pid, line), do: MilkDrop.command(pid, %{cmd: "emit", line: line})

  defp wait_until(fun, timeout \\ 5_000) do
    cond do
      fun.() ->
        :ok

      timeout <= 0 ->
        flunk("condition not met in time")

      true ->
        Process.sleep(20)
        wait_until(fun, timeout - 20)
    end
  end

  defp cmd_lines(ctx) do
    case File.read(ctx.skip_file <> ".cmds") do
      {:ok, body} -> body |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      {:error, _} -> []
    end
  end

  describe "args/1" do
    test "minimal settings" do
      assert MilkDrop.args(%{
               mode: @mode,
               pack_dir: "/data/milkdrop/v1",
               ladder: ["640x360", "480x270"],
               skip_file: "/tmp/skip.txt",
               settings: Store.defaults()
             }) == [
               "--mode",
               "1280x720@60",
               "--pack-dir",
               "/data/milkdrop/v1",
               "--ladder",
               "640x360,480x270",
               "--rotate-s",
               "20",
               "--min-fps",
               "20",
               "--skip-file",
               "/tmp/skip.txt"
             ]
    end

    test "every option" do
      args =
        MilkDrop.args(%{
          mode: %{width: 1920, height: 1080, refresh: 59.94},
          pack_dir: "/p",
          ladder: ["960x540"],
          skip_file: "/s",
          ring_path: "/run/up-pcm-abc",
          settings: %{include_high_frequency: true, rotate_s: 45, min_fps: 30, locked: "x/y.milk"}
        })

      assert args == [
               "--mode",
               "1920x1080@59.94",
               "--pack-dir",
               "/p",
               "--ladder",
               "960x540",
               "--rotate-s",
               "45",
               "--min-fps",
               "30",
               "--skip-file",
               "/s",
               "--high-frequency",
               "--locked",
               "x/y.milk",
               "--pcm-ring",
               "/run/up-pcm-abc"
             ]
    end
  end

  test "args/1 without a refresh, and with a card and connector" do
    args =
      MilkDrop.args(%{
        mode: %{width: 1920, height: 1080},
        card: "/dev/dri/card1",
        connector: "HDMI-A-2",
        pack_dir: "/p",
        ladder: ["960x540"],
        skip_file: "/s",
        settings: Store.defaults()
      })

    assert ["--mode", "1920x1080" | _] = args
    assert Enum.take(args, -4) == ["--card", "/dev/dri/card1", "--connector", "HDMI-A-2"]

    assert ["--mode", "1280x720" | _] =
             MilkDrop.args(%{
               mode: %{width: 1280, height: 720, refresh: nil},
               pack_dir: "/p",
               ladder: ["640x360"],
               skip_file: "/s"
             })
  end

  test "default_ladder/1 per target" do
    assert MilkDrop.default_ladder(:rpi3) == ["640x360", "480x270"]
    assert MilkDrop.default_ladder(:rpi4) == ["960x540", "640x360", "480x270"]
    assert MilkDrop.default_ladder(:rpi5) == ["1280x720", "960x540", "640x360"]
  end

  test "default_binary/0 is the per-target priv path" do
    assert MilkDrop.default_binary()
           |> String.ends_with?("/milkdrop_renderer/host/milkdrop_renderer")
  end

  test "spawns the renderer with the Store's settings and skip list", ctx do
    {:ok, _} = Store.update(ctx.store, %{rotate_s: 45, include_high_frequency: true, min_fps: 25})
    :ok = Store.skip(ctx.store, @version, "b.milk", "draw")
    :ok = Store.skip(ctx.store, @version, "a.milk", "compile")

    {_pid, prepared} = start_renderer(ctx, ring_path: "/run/up-pcm-x")

    assert prepared.argv == [
             "--mode",
             "1280x720@60",
             "--pack-dir",
             ctx.pack_dir,
             "--ladder",
             "640x360,480x270",
             "--rotate-s",
             "45",
             "--min-fps",
             "25",
             "--skip-file",
             ctx.skip_file,
             "--high-frequency",
             "--pcm-ring",
             "/run/up-pcm-x"
           ]

    assert prepared.skip == ["a.milk", "b.milk"]
  end

  test "skips recorded for another pack version are not passed", ctx do
    :ok = Store.skip(ctx.store, "2020.01.1", "old.milk", "draw")
    {_pid, prepared} = start_renderer(ctx)
    assert prepared.skip == []
  end

  test "handover commands produce the renderer's events", ctx do
    {pid, _} = start_renderer(ctx)

    MilkDrop.take(pid)
    assert_receive {:milkdrop, ^pid, %{event: :presenting}}, @timeout

    MilkDrop.release(pid)
    assert_receive {:milkdrop, ^pid, %{event: :released}}, @timeout

    ref = Process.monitor(pid)
    MilkDrop.exit(pid)
    assert_receive {:milkdrop, ^pid, %{event: :exiting, reason: "requested"}}, @timeout
    assert_receive {:milkdrop_exit, ^pid, 0}, @timeout
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, @timeout
    wait_until(fn -> not File.exists?(ctx.skip_file) end)
  end

  test "preset commands are written as JSON lines", ctx do
    {pid, _} = start_renderer(ctx)

    MilkDrop.next(pid)
    MilkDrop.prev(pid)
    MilkDrop.lock(pid)
    MilkDrop.unlock(pid)
    MilkDrop.set_rotate(pid, 30)
    MilkDrop.set_high_frequency(pid, true)
    MilkDrop.set_min_fps(pid, 35)

    expected = [
      %{"cmd" => "next"},
      %{"cmd" => "prev"},
      %{"cmd" => "lock"},
      %{"cmd" => "unlock"},
      %{"cmd" => "set_rotate", "value" => 30},
      %{"cmd" => "set_high_frequency", "value" => true},
      %{"cmd" => "set_min_fps", "value" => 35}
    ]

    wait_until(fn -> cmd_lines(ctx) == expected end)
  end

  test "forwards events with atom keys", ctx do
    {pid, _} = start_renderer(ctx)

    emit(pid, ~s({"event":"stats","fps":30,"temp_mc":61000,"rung":"640x360"}))

    assert_receive {:milkdrop, ^pid, %{event: :stats, fps: 30, temp_mc: 61_000, rung: "640x360"}},
                   @timeout

    emit(pid, ~s({"event":"error","reason":"ring_stale"}))
    assert_receive {:milkdrop, ^pid, %{event: :error, reason: "ring_stale"}}, @timeout
  end

  test "persists skip events for the pack version", ctx do
    {pid, _} = start_renderer(ctx)

    emit(pid, ~s({"event":"skip","preset":"hf/strobe.milk","reason":"budget"}))

    assert_receive {:milkdrop, ^pid,
                    %{event: :skip, preset: "hf/strobe.milk", reason: "budget", persisted: true}},
                   @timeout

    assert Store.skipped(ctx.store, @version) == %{"hf/strobe.milk" => "budget"}
  end

  test "a budget skip is persisted with its measured fps", ctx do
    {pid, _} = start_renderer(ctx)

    emit(pid, ~s({"event":"skip","preset":"slow.milk","reason":"budget","fps":17.3}))

    assert_receive {:milkdrop, ^pid,
                    %{event: :skip, preset: "slow.milk", fps: 17.3, persisted: true}},
                   @timeout

    assert Store.skip_entries(ctx.store, @version) == %{
             "slow.milk" => %{reason: "budget", fps: 17.3}
           }
  end

  test "a gpu_hang skip is persisted before it is forwarded", ctx do
    {pid, _} = start_renderer(ctx)

    emit(
      pid,
      ~s({"event":"skip","preset":"hang.milk","reason":"gpu_hang","message":"[drm] Resetting GPU."})
    )

    assert_receive {:milkdrop, ^pid, %{event: :skip, reason: "gpu_hang", persisted: true}},
                   @timeout

    assert Store.skipped(ctx.store, @version) == %{"hang.milk" => "gpu_hang"}
  end

  describe "while the Store is down" do
    @store_name :milkdrop_display_test_store

    setup ctx do
      stop_supervised!(Store)
      start_named_store(ctx)
      stop_supervised!(Store)
      :ok
    end

    defp start_named_store(ctx) do
      start_supervised!(
        {Store,
         name: @store_name, table: @table, dets_path: Path.join(ctx.tmp_dir, "settings.dets")}
      )
    end

    test "a skip is forwarded as not persisted, then persisted when the Store is back", ctx do
      {pid, _} =
        start_renderer(ctx, store: @store_name, settings: Store.defaults(), skipped: %{})

      emit(pid, ~s({"event":"skip","preset":"a.milk","reason":"draw"}))

      assert_receive {:milkdrop, ^pid, %{event: :skip, preset: "a.milk", persisted: false}},
                     @timeout

      start_named_store(ctx)
      wait_until(fn -> Store.skipped(@store_name, @version) == %{"a.milk" => "draw"} end)
    end

    test "pending skips are flushed by the next event", ctx do
      {pid, _} =
        start_renderer(ctx,
          store: @store_name,
          settings: Store.defaults(),
          skipped: %{},
          skip_retry_ms: 600_000
        )

      emit(pid, ~s({"event":"skip","preset":"a.milk","reason":"draw"}))
      assert_receive {:milkdrop, ^pid, %{event: :skip, persisted: false}}, @timeout

      start_named_store(ctx)
      emit(pid, ~s({"event":"skip","preset":"b.milk","reason":"budget"}))

      assert_receive {:milkdrop, ^pid, %{event: :skip, preset: "b.milk", persisted: true}},
                     @timeout

      assert Store.skipped(@store_name, @version) == %{"a.milk" => "draw", "b.milk" => "budget"}
    end
  end

  test "persists a lock change from preset events", ctx do
    {pid, _} = start_renderer(ctx)

    emit(pid, ~s({"event":"preset","file":"a.milk","locked":true}))
    assert_receive {:milkdrop, ^pid, %{event: :preset, file: "a.milk", locked: true}}, @timeout
    assert Store.settings(ctx.store).locked == "a.milk"

    emit(pid, ~s({"event":"preset","file":"b.milk","locked":false}))
    assert_receive {:milkdrop, ^pid, %{event: :preset, file: "b.milk"}}, @timeout
    assert Store.settings(ctx.store).locked == nil
  end

  test "garbage, unknown and over-long lines are ignored", ctx do
    {pid, _} = start_renderer(ctx)

    emit(pid, "not json at all")
    emit(pid, ~s({"event":"bogus"}))
    emit(pid, ~s({"no_event":1}))
    emit(pid, ~s([1,2,3]))

    long_preset = String.duplicate("x", @timeout)
    emit(pid, ~s({"event":"skip","preset":"#{long_preset}","reason":"draw"}))

    emit(pid, ~s({"event":"stats","n":1}))
    assert_receive {:milkdrop, ^pid, %{event: :stats, n: 1}}, @timeout
    refute_received {:milkdrop, ^pid, _}

    assert Store.skipped(ctx.store, @version) == %{}
    assert Process.alive?(pid)
  end

  @tag capture_log: true
  test "forwards a non-zero exit status and stops", ctx do
    {pid, _} = start_renderer(ctx)
    ref = Process.monitor(pid)

    MilkDrop.command(pid, %{cmd: "crash", status: 3})
    assert_receive {:milkdrop_exit, ^pid, 3}, @timeout
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, @timeout

    # Commands to a stopped renderer are harmless.
    assert MilkDrop.next(pid) == :ok
  end

  test "a size-only mode, a card and a connector reach the renderer", ctx do
    {_pid, prepared} =
      start_renderer(ctx,
        mode: %{width: 1920, height: 1080},
        card: "/dev/dri/card1",
        connector: "HDMI-A-2"
      )

    assert ["--mode", "1920x1080" | _] = prepared.argv

    assert Enum.take(prepared.argv, -4) == [
             "--card",
             "/dev/dri/card1",
             "--connector",
             "HDMI-A-2"
           ]
  end

  # ── In-flight record (device resets) ──────────────────────────────────

  test "a loading event records the preset in flight before it is forwarded", ctx do
    {pid, _} = start_renderer(ctx)
    assert Store.in_flight(ctx.store) == nil

    emit(pid, ~s({"event":"loading","preset":"hf/a.milk"}))
    assert_receive {:milkdrop, ^pid, %{event: :loading, preset: "hf/a.milk"}}, @timeout
    assert %{pack_version: @version, preset: "hf/a.milk"} = Store.in_flight(ctx.store)

    MilkDrop.next(pid)
    assert_receive {:milkdrop, ^pid, %{event: :loading, preset: "p1.milk"}}, @timeout
    assert_receive {:milkdrop, ^pid, %{event: :preset, file: "p1.milk"}}, @timeout
    assert %{preset: "p1.milk"} = Store.in_flight(ctx.store)
  end

  test "a skipped candidate hands the record back to the preset showing", ctx do
    {pid, _} = start_renderer(ctx)

    emit(pid, ~s({"event":"preset","file":"a.milk","locked":false}))
    emit(pid, ~s({"event":"loading","preset":"b.milk"}))
    assert_receive {:milkdrop, ^pid, %{event: :loading}}, @timeout
    assert %{preset: "b.milk"} = Store.in_flight(ctx.store)

    emit(pid, ~s({"event":"skip","preset":"b.milk","reason":"compile_error"}))
    assert_receive {:milkdrop, ^pid, %{event: :skip, preset: "b.milk"}}, @timeout
    assert %{preset: "a.milk"} = Store.in_flight(ctx.store)
  end

  test "a release or a requested exit clears the record", ctx do
    {pid, _} = start_renderer(ctx)
    MilkDrop.take(pid)
    MilkDrop.next(pid)
    assert_receive {:milkdrop, ^pid, %{event: :preset, file: "p1.milk"}}, @timeout
    assert %{preset: "p1.milk"} = Store.in_flight(ctx.store)

    MilkDrop.release(pid)
    assert_receive {:milkdrop, ^pid, %{event: :released}}, @timeout
    assert Store.in_flight(ctx.store) == nil

    emit(pid, ~s({"event":"loading","preset":"b.milk"}))
    assert_receive {:milkdrop, ^pid, %{event: :loading}}, @timeout
    MilkDrop.exit(pid)
    assert_receive {:milkdrop, ^pid, %{event: :exiting, reason: "requested"}}, @timeout
    assert Store.in_flight(ctx.store) == nil
    assert_receive {:milkdrop_exit, ^pid, 0}, @timeout
  end

  @tag capture_log: true
  test "a crashed renderer's record outlasts it by the Store's grace period", ctx do
    stop_supervised!(Store)

    store =
      start_supervised!(
        {Store,
         name: nil,
         table: @table,
         dets_path: Path.join(ctx.tmp_dir, "settings.dets"),
         in_flight_grace_ms: 300}
      )

    {pid, _} = start_renderer(%{ctx | store: store})
    emit(pid, ~s({"event":"loading","preset":"a.milk"}))
    assert_receive {:milkdrop, ^pid, %{event: :loading}}, @timeout

    MilkDrop.command(pid, %{cmd: "crash", status: 3})
    assert_receive {:milkdrop_exit, ^pid, 3}, @timeout
    assert_receive {:milkdrop_reaped, ^pid}, @timeout
    assert %{preset: "a.milk"} = Store.in_flight(store)
    wait_until(fn -> Store.in_flight(store) == nil end)
  end

  @tag capture_log: true
  test "after a power cut mid-preset the next boot skips that preset", ctx do
    stop_supervised!(Store)

    store_spec = fn boot_id ->
      Supervisor.child_spec(
        {Store,
         name: nil,
         table: @table,
         dets_path: Path.join(ctx.tmp_dir, "settings.dets"),
         boot_id: boot_id,
         pack_version: @version},
        restart: :temporary
      )
    end

    store = start_supervised!(store_spec.("boot-1"))
    {pid, _} = start_renderer(%{ctx | store: store})
    emit(pid, ~s({"event":"loading","preset":"hang.milk"}))
    assert_receive {:milkdrop, ^pid, %{event: :loading}}, @timeout

    # Everything dies at once, nothing gets to clean up.
    ref = Process.monitor(store)
    Process.exit(store, :kill)
    assert_receive {:DOWN, ^ref, :process, ^store, :killed}
    Process.exit(pid, :kill)
    assert_receive {:milkdrop_reaped, ^pid}, @timeout

    store = start_supervised!(store_spec.("boot-2"))
    assert Store.skipped(store, @version) == %{"hang.milk" => "device_reset"}
    assert Store.in_flight(store) == nil

    {_pid, prepared} = start_renderer(%{ctx | store: store}, skip_file: ctx.skip_file <> "2")
    assert prepared.skip == ["hang.milk"]
  end

  describe "in-flight record while the Store fails" do
    @store_name :milkdrop_display_test_store

    setup do
      stop_supervised!(Store)
      :ok
    end

    defp store_spec(path, boot_id, opts \\ []) do
      opts =
        Keyword.merge(
          [
            name: @store_name,
            table: @table,
            dets_path: path,
            boot_id: boot_id,
            pack_version: @version
          ],
          opts
        )

      Supervisor.child_spec({Store, opts}, restart: :temporary)
    end

    defp power_cut(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    end

    # `{insert, allow_skips}`: an `:insert` stand-in refusing skip writes
    # until `allow_skips.()`.
    defp failing_skips do
      failing = :atomics.new(1, [])
      :atomics.put(failing, 1, 1)

      insert = fn
        table, {:skipped, _} = record ->
          if :atomics.get(failing, 1) == 1,
            do: {:error, :enospc},
            else: :dets.insert(table, record)

        table, record ->
          :dets.insert(table, record)
      end

      {insert, fn -> :atomics.put(failing, 1, 0) end}
    end

    defp hang_unpersisted(pid) do
      emit(pid, ~s({"event":"preset","file":"a.milk","locked":false}))
      emit(pid, ~s({"event":"loading","preset":"b.milk"}))
      assert_receive {:milkdrop, ^pid, %{event: :loading, preset: "b.milk"}}, @timeout

      emit(pid, ~s({"event":"skip","preset":"b.milk","reason":"gpu_hang"}))

      assert_receive {:milkdrop, ^pid,
                      %{event: :skip, preset: "b.milk", reason: "gpu_hang", persisted: false}},
                     @timeout
    end

    @tag capture_log: true
    test "a candidate skipped while the table is closed hands the record back", ctx do
      dir = Path.join(ctx.tmp_dir, "db")
      path = Path.join(dir, "settings.dets")
      store = start_supervised!(store_spec(path, "boot-1"))

      {pid, _} = start_renderer(ctx, store: @store_name, skip_retry_ms: 50)
      emit(pid, ~s({"event":"preset","file":"a.milk","locked":false}))
      assert_receive {:milkdrop, ^pid, %{event: :preset, file: "a.milk"}}, @timeout
      assert %{preset: "a.milk"} = Store.in_flight(@store_name)

      power_cut(store)
      File.rename!(dir, dir <> ".away")
      File.write!(dir, "not a directory")
      store = start_supervised!(store_spec(path, "boot-1", retry_ms: 20))

      # Both refused, and both queued by the Store: the second must win.
      emit(pid, ~s({"event":"loading","preset":"b.milk"}))
      emit(pid, ~s({"event":"skip","preset":"b.milk","reason":"compile_error"}))

      assert_receive {:milkdrop, ^pid, %{event: :skip, preset: "b.milk", persisted: false}},
                     @timeout

      File.rm!(dir)
      File.rename!(dir <> ".away", dir)
      wait_until(fn -> :sys.get_state(store).table != nil end)

      assert %{preset: "a.milk", owner: ^pid} = Store.in_flight(@store_name)

      wait_until(fn ->
        Store.skipped(@store_name, @version) == %{"b.milk" => "compile_error"}
      end)

      assert %{preset: "a.milk"} = Store.in_flight(@store_name)
    end

    @tag capture_log: true
    test "an unpersisted gpu_hang keeps the record until its skip is on disk", ctx do
      {insert, allow_skips} = failing_skips()
      path = Path.join(ctx.tmp_dir, "settings.dets")
      start_supervised!(store_spec(path, "boot-1", insert: insert))

      {pid, _} = start_renderer(ctx, store: @store_name, skip_retry_ms: 600_000)
      hang_unpersisted(pid)
      # The Store took in-flight writes all along, but not the skip.
      assert %{preset: "b.milk"} = Store.in_flight(@store_name)

      emit(pid, ~s({"event":"loading","preset":"c.milk"}))
      assert_receive {:milkdrop, ^pid, %{event: :loading, preset: "c.milk"}}, @timeout
      emit(pid, ~s({"event":"preset","file":"c.milk","locked":false}))
      assert_receive {:milkdrop, ^pid, %{event: :preset, file: "c.milk"}}, @timeout
      assert %{preset: "b.milk"} = Store.in_flight(@store_name)

      allow_skips.()
      emit(pid, ~s({"event":"loading","preset":"d.milk"}))
      assert_receive {:milkdrop, ^pid, %{event: :loading, preset: "d.milk"}}, @timeout
      assert Store.skipped(@store_name, @version) == %{"b.milk" => "gpu_hang"}
      assert %{preset: "d.milk"} = Store.in_flight(@store_name)
    end

    @tag capture_log: true
    test "a release while a gpu_hang is held clears once the skip retry lands", ctx do
      {insert, allow_skips} = failing_skips()
      path = Path.join(ctx.tmp_dir, "settings.dets")
      start_supervised!(store_spec(path, "boot-1", insert: insert))

      {pid, _} = start_renderer(ctx, store: @store_name, skip_retry_ms: 50)
      hang_unpersisted(pid)
      MilkDrop.release(pid)
      assert_receive {:milkdrop, ^pid, %{event: :released}}, @timeout
      assert %{preset: "b.milk", clear_at: nil} = Store.in_flight(@store_name)

      allow_skips.()
      wait_until(fn -> Store.skipped(@store_name, @version) == %{"b.milk" => "gpu_hang"} end)
      # Released: the deferred clear runs (grace 30 s), so a deadline is set.
      wait_until(fn -> is_integer(Store.in_flight(@store_name).clear_at) end)
    end

    @tag capture_log: true
    test "marks refused while the Store is down are retried for a stats-only stream", ctx do
      path = Path.join(ctx.tmp_dir, "settings.dets")
      store = start_supervised!(store_spec(path, "boot-1"))

      {pid, _} = start_renderer(ctx, store: @store_name, skip_retry_ms: 50)
      emit(pid, ~s({"event":"preset","file":"a.milk","locked":false}))
      assert_receive {:milkdrop, ^pid, %{event: :preset, file: "a.milk"}}, @timeout
      assert %{preset: "a.milk"} = Store.in_flight(@store_name)

      power_cut(store)
      emit(pid, ~s({"event":"loading","preset":"b.milk"}))
      emit(pid, ~s({"event":"preset","file":"b.milk","locked":true}))
      assert_receive {:milkdrop, ^pid, %{event: :preset, file: "b.milk"}}, @timeout

      # Locked: from here on the renderer only sends stats.
      start_supervised!(store_spec(path, "boot-1"))
      emit(pid, ~s({"event":"stats","fps":60}))
      assert_receive {:milkdrop, ^pid, %{event: :stats}}, @timeout

      wait_until(fn -> match?(%{preset: "b.milk", owner: ^pid}, Store.in_flight(@store_name)) end)
    end

    @tag capture_log: true
    test "a clear refused during a release is retried while the server lives on", ctx do
      path = Path.join(ctx.tmp_dir, "settings.dets")
      store = start_supervised!(store_spec(path, "boot-1"))

      {pid, _} = start_renderer(ctx, store: @store_name, skip_retry_ms: 50)
      emit(pid, ~s({"event":"preset","file":"a.milk","locked":false}))
      assert_receive {:milkdrop, ^pid, %{event: :preset, file: "a.milk"}}, @timeout
      assert %{preset: "a.milk"} = Store.in_flight(@store_name)

      power_cut(store)
      MilkDrop.release(pid)
      assert_receive {:milkdrop, ^pid, %{event: :released}}, @timeout

      # The server stays up (viewport recovery), so the restarted Store
      # finds a live owner and keeps the record until the clear lands.
      store = start_supervised!(store_spec(path, "boot-1", in_flight_grace_ms: 200))
      wait_until(fn -> Store.in_flight(@store_name) == nil end)
      assert %{intended: nil, acked?: true} = :sys.get_state(pid)
      assert Process.alive?(pid)

      power_cut(store)
      store = start_supervised!(store_spec(path, "boot-2"))
      assert Store.skipped(store, @version) == %{}
      assert Store.in_flight(store) == nil
    end

    @tag capture_log: true
    test "a power cut while a gpu_hang is held skips that preset on the next boot", ctx do
      {insert, _allow_skips} = failing_skips()
      path = Path.join(ctx.tmp_dir, "settings.dets")
      store = start_supervised!(store_spec(path, "boot-1", insert: insert))

      {pid, _} = start_renderer(ctx, store: @store_name, skip_retry_ms: 600_000)
      hang_unpersisted(pid)
      emit(pid, ~s({"event":"loading","preset":"c.milk"}))
      assert_receive {:milkdrop, ^pid, %{event: :loading, preset: "c.milk"}}, @timeout

      power_cut(store)
      Process.exit(pid, :kill)
      assert_receive {:milkdrop_reaped, ^pid}, @timeout

      store = start_supervised!(store_spec(path, "boot-2"))
      assert Store.skipped(store, @version) == %{"b.milk" => "device_reset"}
      assert Store.in_flight(store) == nil
    end
  end

  # ── Reaped ─────────────────────────────────────────────────────────────

  test "a renderer that exits is reported reaped", ctx do
    {pid, _} = start_renderer(ctx)
    MilkDrop.exit(pid)
    assert_receive {:milkdrop_exit, ^pid, 0}, @timeout
    assert_receive {:milkdrop_reaped, ^pid}, @timeout
  end

  test "a stopped server's renderer is reported reaped once it exits on EOF", ctx do
    {pid, _} = start_renderer(ctx, kill_grace_ms: 60_000)
    %{os_pid: os_pid} = :sys.get_state(pid)

    :ok = MilkDrop.stop(pid)
    # Well inside the grace period: the reaper saw the exit itself.
    assert_receive {:milkdrop_reaped, ^pid}, 3_000
    refute alive?(os_pid)
    assert File.exists?(ctx.skip_file <> ".eof")
  end

  @tag capture_log: true
  test "a killed server's renderer that ignores EOF is reported reaped after its SIGKILL", ctx do
    owner = forwarding_owner()
    {:ok, pid} = start_with_owner(ctx, owner, kill_grace_ms: 300)
    assert_receive {:owner_got, {:milkdrop, ^pid, %{event: :prepared}}}, @timeout
    os_pid = ignore_eof(ctx, pid)

    Process.exit(pid, :kill)
    refute_receive {:owner_got, {:milkdrop_reaped, ^pid}}, 200
    assert alive?(os_pid)
    assert_receive {:owner_got, {:milkdrop_reaped, ^pid}}, @timeout
    refute alive?(os_pid)
    refute File.exists?(ctx.skip_file <> ".eof")
  end

  @tag capture_log: true
  test "a killed reaper's renderer is reported reaped by the server", ctx do
    {pid, _} = start_renderer(ctx, kill_grace_ms: 60_000)
    os_pid = ignore_eof(ctx, pid)
    %{reaper: reaper} = :sys.get_state(pid)

    Process.exit(reaper, :kill)
    assert_receive {:milkdrop_exit, ^pid, :reaper_down}, @timeout
    assert_receive {:milkdrop_reaped, ^pid}, @timeout
    refute alive?(os_pid)
  end

  test "owner death closes the port (renderer sees EOF)", ctx do
    owner = forwarding_owner()
    {:ok, pid} = start_with_owner(ctx, owner)
    assert_receive {:owner_got, {:milkdrop, ^pid, %{event: :prepared}}}, @timeout
    ref = Process.monitor(pid)

    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, @timeout
    wait_until(fn -> File.exists?(ctx.skip_file <> ".eof") end)
  end

  @tag capture_log: true
  test "a renderer that ignores EOF is killed after the grace period", ctx do
    owner = forwarding_owner()
    {:ok, pid} = start_with_owner(ctx, owner, kill_grace_ms: 100)
    assert_receive {:owner_got, {:milkdrop, ^pid, %{event: :prepared}}}, @timeout

    %{os_pid: os_pid} = :sys.get_state(pid)
    MilkDrop.command(pid, %{cmd: "ignore_eof"})
    wait_until(fn -> cmd_lines(ctx) == [%{"cmd" => "ignore_eof"}] end)

    Process.exit(owner, :kill)
    wait_until(fn -> not File.exists?("/proc/#{os_pid}") end)
    refute File.exists?(ctx.skip_file <> ".eof")
  end

  @tag capture_log: true
  test "a linked owner's death still kills a renderer that ignores EOF", ctx do
    test_pid = self()

    owner =
      spawn(fn ->
        {:ok, pid} = MilkDrop.start_link(renderer_opts(ctx, kill_grace_ms: 100))
        send(test_pid, {:started, pid})
        forward(test_pid)
      end)

    assert_receive {:started, pid}, @timeout
    assert_receive {:owner_got, {:milkdrop, ^pid, %{event: :prepared}}}, @timeout
    os_pid = ignore_eof(ctx, pid)
    ref = Process.monitor(pid)
    assert File.exists?(ctx.skip_file)

    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, @timeout
    wait_until(fn -> not File.exists?("/proc/#{os_pid}") end)
    refute File.exists?(ctx.skip_file <> ".eof")
    wait_until(fn -> not File.exists?(ctx.skip_file) end)
  end

  @tag capture_log: true
  test "a killed server still kills a renderer that ignores EOF", ctx do
    owner = forwarding_owner()
    {:ok, pid} = start_with_owner(ctx, owner, kill_grace_ms: 100)
    assert_receive {:owner_got, {:milkdrop, ^pid, %{event: :prepared}}}, @timeout
    os_pid = ignore_eof(ctx, pid)

    Process.exit(pid, :kill)
    wait_until(fn -> not File.exists?("/proc/#{os_pid}") end)
    refute File.exists?(ctx.skip_file <> ".eof")
  end

  @tag capture_log: true
  test "a killed reaper kills the running renderer and stops the server", ctx do
    {pid, _} = start_renderer(ctx, kill_grace_ms: 60_000)
    os_pid = ignore_eof(ctx, pid)
    %{reaper: reaper} = :sys.get_state(pid)
    ref = Process.monitor(pid)

    Process.exit(reaper, :kill)
    assert_receive {:milkdrop_exit, ^pid, :reaper_down}, @timeout
    assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :reaper_down}}, @timeout
    wait_until(fn -> not File.exists?("/proc/#{os_pid}") end, 1_000)
  end

  @tag capture_log: true
  test "a reaper shut down by its supervisor kills the running renderer", ctx do
    sup = start_supervised!(Task.Supervisor)
    {pid, _} = start_renderer(ctx, task_supervisor: sup, kill_grace_ms: 60_000)
    os_pid = ignore_eof(ctx, pid)
    %{reaper: reaper} = :sys.get_state(pid)
    ref = Process.monitor(pid)

    :ok = Task.Supervisor.terminate_child(sup, reaper)
    wait_until(fn -> not File.exists?("/proc/#{os_pid}") end, 1_000)
    # The reaper's SIGKILL can reach the server as an exit status (128 + 9)
    # before the reaper's own DOWN does.
    assert_receive {:milkdrop_exit, ^pid, status}, @timeout
    assert status in [:reaper_down, 137]
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, @timeout
    assert reason in [{:shutdown, :reaper_down}, :normal]
  end

  @tag capture_log: true
  test "stopping the reaper's supervisor during the grace period kills the renderer", ctx do
    start_supervised!({Task.Supervisor, name: :milkdrop_reaper_test_sup}, id: :reaper_sup)
    owner = forwarding_owner()

    {:ok, pid} =
      start_with_owner(ctx, owner,
        task_supervisor: :milkdrop_reaper_test_sup,
        kill_grace_ms: 60_000
      )

    assert_receive {:owner_got, {:milkdrop, ^pid, %{event: :prepared}}}, @timeout
    os_pid = ignore_eof(ctx, pid)
    ref = Process.monitor(pid)

    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, @timeout
    assert File.exists?("/proc/#{os_pid}")

    :ok = stop_supervised(:reaper_sup)
    wait_until(fn -> not File.exists?("/proc/#{os_pid}") end, 1_000)
    refute File.exists?(ctx.skip_file <> ".eof")
  end

  @tag capture_log: true
  test "a session whose reaper is shut down after its server stopped is cleared", ctx do
    stop_supervised!(Store)

    store =
      start_supervised!(
        {Store,
         name: nil,
         table: @table,
         dets_path: Path.join(ctx.tmp_dir, "settings.dets"),
         in_flight_grace_ms: 1_500}
      )

    start_supervised!({Task.Supervisor, name: :milkdrop_reaper_clear_sup}, id: :reaper_sup)
    owner = forwarding_owner()

    {:ok, pid} =
      start_with_owner(%{ctx | store: store}, owner,
        task_supervisor: :milkdrop_reaper_clear_sup,
        kill_grace_ms: 60_000
      )

    assert_receive {:owner_got, {:milkdrop, ^pid, %{event: :prepared}}}, @timeout
    os_pid = ignore_eof(ctx, pid)
    emit(pid, ~s({"event":"loading","preset":"a.milk"}))
    assert_receive {:owner_got, {:milkdrop, ^pid, %{event: :loading}}}, @timeout
    ref = Process.monitor(pid)

    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, @timeout
    :ok = stop_supervised(:reaper_sup)
    wait_until(fn -> not File.exists?("/proc/#{os_pid}") end, 1_000)

    # Nothing of the session is left to ask: the Store saw its server go.
    assert %{preset: "a.milk", clear_at: clear_at} = Store.in_flight(store)
    assert is_integer(clear_at)
    wait_until(fn -> Store.in_flight(store) == nil end)
  end

  @tag capture_log: true
  test "no renderer is spawned when the reaper cannot start", ctx do
    assert {:error, {:reaper, _}} =
             MilkDrop.start(renderer_opts(ctx, task_supervisor: :no_such_milkdrop_task_sup))

    assert renderer_os_pids(ctx.skip_file) == []
    # Long enough for an already-spawned fake to have reached its marker.
    Process.sleep(300)
    refute File.exists?(ctx.skip_file <> ".spawned")
    refute File.exists?(ctx.skip_file)
  end

  @tag capture_log: true
  test "a renderer that stops reading stdin is reported wedged and killed", ctx do
    {pid, _} = start_renderer(ctx, kill_grace_ms: 100)
    %{os_pid: os_pid} = :sys.get_state(pid)
    # Unblocks a suspended server if the stdin-busy handling regresses.
    on_exit(fn ->
      System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end)

    ref = Process.monitor(pid)

    MilkDrop.command(pid, %{cmd: "stall"})
    wait_until(fn -> cmd_lines(ctx) == [%{"cmd" => "stall"}] end)

    filler = String.duplicate("x", 4_000)
    for _ <- 1..200, do: MilkDrop.command(pid, %{cmd: "pad", pad: filler})

    assert_receive {:milkdrop_exit, ^pid, :wedged}, @timeout
    assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :wedged}}, @timeout
    wait_until(fn -> not File.exists?("/proc/#{os_pid}") end)
  end

  # ── Hangs and crashes ─────────────────────────────────────────────────

  @tag capture_log: true
  test "an unanswered loading is a hang: skipped, killed and reported", ctx do
    {pid, _} = start_renderer(ctx, loading_timeout_ms: 200)
    %{os_pid: os_pid} = :sys.get_state(pid)
    ref = Process.monitor(pid)

    MilkDrop.command(pid, %{cmd: "hang_loading", preset: "loop.milk"})
    assert_receive {:milkdrop, ^pid, %{event: :loading, preset: "loop.milk"}}, @timeout
    assert_receive {:milkdrop_exit, ^pid, :hang}, @timeout
    # On disk before the owner heard of it.
    assert Store.skipped(ctx.store, @version) == %{"loop.milk" => "hang"}

    assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :hang}}, @timeout
    assert_receive {:milkdrop_reaped, ^pid}, @timeout
    refute alive?(os_pid)
    # The kill's exit status is never taken for a crash.
    refute_received {:milkdrop_exit, ^pid, _}
    assert Store.skipped(ctx.store, @version) == %{"loop.milk" => "hang"}
  end

  @tag capture_log: true
  test "a renderer silent while showing a preset is a hang of that preset", ctx do
    {pid, _} = start_renderer(ctx, silence_ms: 1_000)

    emit(pid, ~s({"event":"preset","file":"a.milk","locked":false}))
    assert_receive {:milkdrop, ^pid, %{event: :preset, file: "a.milk"}}, @timeout
    MilkDrop.command(pid, %{cmd: "stall"})

    assert_receive {:milkdrop_exit, ^pid, :hang}, @timeout
    assert Store.skipped(ctx.store, @version) == %{"a.milk" => "hang"}
    assert_receive {:milkdrop_reaped, ^pid}, @timeout
  end

  @tag capture_log: true
  test "stats keep a renderer alive; an unanswered loading still times out", ctx do
    {pid, _} = start_renderer(ctx, silence_ms: 300, loading_timeout_ms: 500)

    MilkDrop.command(pid, %{cmd: "stats", ms: 50})
    emit(pid, ~s({"event":"preset","file":"a.milk","locked":false}))
    assert_receive {:milkdrop, ^pid, %{event: :preset, file: "a.milk"}}, @timeout
    refute_receive {:milkdrop_exit, ^pid, _}, 1_000
    assert Store.skipped(ctx.store, @version) == %{}

    # The loading is blamed, not the preset showing.
    MilkDrop.command(pid, %{cmd: "hang_loading", preset: "b.milk"})
    assert_receive {:milkdrop_exit, ^pid, :hang}, @timeout
    assert Store.skipped(ctx.store, @version) == %{"b.milk" => "hang"}
  end

  test "the first preset's loading at start is answered by its preset event", ctx do
    File.write!(Path.join(ctx.pack_dir, "fake.json"), ~s({"startup_preset":"first.milk"}))
    {pid, _} = start_renderer(ctx, loading_timeout_ms: 200)

    assert_received {:milkdrop, ^pid, %{event: :loading, preset: "first.milk"}}
    assert_received {:milkdrop, ^pid, %{event: :preset, file: "first.milk", cause: "start"}}
    refute_receive {:milkdrop_exit, ^pid, _}, 600
    assert Store.skipped(ctx.store, @version) == %{}

    # Rotation's loading/preset pairs are answered too.
    MilkDrop.next(pid)
    assert_receive {:milkdrop, ^pid, %{event: :preset, file: "p1.milk"}}, @timeout
    refute_receive {:milkdrop_exit, ^pid, _}, 400
  end

  @tag capture_log: true
  test "stop_hung blames what it is asked to, then kills without an exit message", ctx do
    {pid, _} = start_renderer(ctx)
    %{os_pid: os_pid} = :sys.get_state(pid)
    emit(pid, ~s({"event":"preset","file":"a.milk","locked":false}))
    assert_receive {:milkdrop, ^pid, %{event: :preset, file: "a.milk"}}, @timeout

    # Nothing loading: `:loading` blames nobody.
    assert MilkDrop.stop_hung(pid, :loading) == :ok
    assert_receive {:milkdrop_reaped, ^pid}, @timeout
    refute alive?(os_pid)
    refute_received {:milkdrop_exit, ^pid, _}
    assert Store.skipped(ctx.store, @version) == %{}

    {pid, _} = start_renderer(ctx, skip_file: ctx.skip_file <> "2")
    emit(pid, ~s({"event":"preset","file":"a.milk","locked":false}))
    assert_receive {:milkdrop, ^pid, %{event: :preset, file: "a.milk"}}, @timeout
    assert MilkDrop.stop_hung(pid, :showing) == :ok
    assert Store.skipped(ctx.store, @version) == %{"a.milk" => "hang"}
    assert MilkDrop.stop_hung(pid, :showing) == :ok
  end

  @tag capture_log: true
  test "stop_hung with a loading pending blames it either way", ctx do
    {pid, _} = start_renderer(ctx)
    emit(pid, ~s({"event":"preset","file":"a.milk","locked":false}))
    emit(pid, ~s({"event":"loading","preset":"b.milk"}))
    assert_receive {:milkdrop, ^pid, %{event: :loading, preset: "b.milk"}}, @timeout

    assert MilkDrop.stop_hung(pid, :loading) == :ok
    assert Store.skipped(ctx.store, @version) == %{"b.milk" => "hang"}
  end

  @tag capture_log: true
  test "a crash while loading skips that preset before the exit is reported", ctx do
    {pid, _} = start_renderer(ctx)

    MilkDrop.command(pid, %{cmd: "crash_on_loading", preset: "bad.milk", status: 139})
    assert_receive {:milkdrop_exit, ^pid, 139}, @timeout
    assert Store.skipped(ctx.store, @version) == %{"bad.milk" => "crashed"}
    assert_receive {:milkdrop_reaped, ^pid}, @timeout

    {_pid, prepared} = start_renderer(ctx, skip_file: ctx.skip_file <> "2")
    assert prepared.skip == ["bad.milk"]
  end

  @tag capture_log: true
  test "a crash with no loading pending skips nothing", ctx do
    {pid, _} = start_renderer(ctx)

    MilkDrop.next(pid)
    assert_receive {:milkdrop, ^pid, %{event: :preset, file: "p1.milk"}}, @timeout
    MilkDrop.command(pid, %{cmd: "crash", status: 3})
    assert_receive {:milkdrop_exit, ^pid, 3}, @timeout
    assert Store.skipped(ctx.store, @version) == %{}
  end

  @tag capture_log: true
  test "a failed exit the renderer announced skips nothing", ctx do
    {pid, _} = start_renderer(ctx)

    emit(pid, ~s({"event":"loading","preset":"b.milk"}))
    emit(pid, ~s({"event":"exiting","reason":"gl"}))
    assert_receive {:milkdrop, ^pid, %{event: :exiting, reason: "gl"}}, @timeout
    MilkDrop.command(pid, %{cmd: "crash", status: 1})
    assert_receive {:milkdrop_exit, ^pid, 1}, @timeout
    assert Store.skipped(ctx.store, @version) == %{}
  end

  @tag capture_log: true
  test "a lock the Store failed to save is retried on the next preset event", ctx do
    store_opts = [
      name: :milkdrop_display_lock_store,
      table: :milkdrop_display_lock_test,
      dets_path: Path.join(ctx.tmp_dir, "lock.dets")
    ]

    start_supervised!({Store, store_opts}, id: :lock_store)

    {pid, _} =
      start_renderer(ctx, store: :milkdrop_display_lock_store, settings: Store.defaults())

    :ok = stop_supervised(:lock_store)
    emit(pid, ~s({"event":"preset","file":"a.milk","locked":true}))
    assert_receive {:milkdrop, ^pid, %{event: :preset, locked: true}}, @timeout

    start_supervised!({Store, store_opts}, id: :lock_store)
    emit(pid, ~s({"event":"preset","file":"a.milk","locked":true}))
    assert_receive {:milkdrop, ^pid, %{event: :preset, locked: true}}, @timeout
    assert Store.settings(:milkdrop_display_lock_store).locked == "a.milk"
  end

  @tag capture_log: true
  test "refuses to start without a binary or with a bad mode/ladder", ctx do
    base = [
      mode: @mode,
      pack_dir: ctx.pack_dir,
      pack_version: @version,
      store: ctx.store,
      skip_file: ctx.skip_file
    ]

    missing = Path.join(ctx.pack_dir, "nope")

    assert {:error, {:binary_missing, ^missing}} =
             MilkDrop.start(Keyword.put(base, :binary, missing))

    assert {:error, {:invalid_mode, _}} =
             MilkDrop.start(base |> Keyword.put(:binary, @fake_binary) |> Keyword.put(:mode, %{}))

    assert {:error, {:invalid_mode, _}} =
             MilkDrop.start(
               base
               |> Keyword.put(:binary, @fake_binary)
               |> Keyword.put(:mode, %{width: 1280, height: 720, refresh: 0})
             )

    for bad <- ["", "HDMI A 1", "../card0", String.duplicate("a", 33), :hdmi] do
      assert {:error, {:invalid_connector, ^bad}} =
               MilkDrop.start(
                 base
                 |> Keyword.put(:binary, @fake_binary)
                 |> Keyword.put(:connector, bad)
               )
    end

    for bad <- ["", "card1", "/dev/dri/card1\n--locked", "/dev/\0", 1] do
      assert {:error, {:invalid_card, ^bad}} =
               MilkDrop.start(
                 base
                 |> Keyword.put(:binary, @fake_binary)
                 |> Keyword.put(:card, bad)
               )
    end

    assert {:error, {:invalid_ladder, _}} =
             MilkDrop.start(
               base
               |> Keyword.put(:binary, @fake_binary)
               |> Keyword.put(:ladder, ["640x360", "huge"])
             )
  end

  defp forwarding_owner do
    test_pid = self()
    spawn(fn -> forward(test_pid) end)
  end

  defp forward(test_pid) do
    receive do
      msg -> send(test_pid, {:owner_got, msg})
    end

    forward(test_pid)
  end

  defp start_with_owner(ctx, owner, opts \\ []),
    do: MilkDrop.start(renderer_opts(ctx, [owner: owner] ++ opts))

  defp renderer_opts(ctx, opts) do
    [
      mode: @mode,
      pack_dir: ctx.pack_dir,
      pack_version: @version,
      store: ctx.store,
      skip_file: ctx.skip_file,
      binary: @fake_binary
    ] ++ opts
  end

  defp renderer_os_pids(skip_file) do
    for dir <- Path.wildcard("/proc/[0-9]*"),
        {:ok, cmdline} <- [File.read(Path.join(dir, "cmdline"))],
        skip_file in String.split(cmdline, <<0>>),
        do: dir |> Path.basename() |> String.to_integer()
  end

  defp kill_os_pid(os_pid),
    do: System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)

  defp alive?(os_pid) do
    case File.read("/proc/#{os_pid}/stat") do
      {:ok, stat} ->
        (stat |> String.split(") ") |> List.last() |> String.first()) not in ["Z", "X"]

      {:error, _} ->
        false
    end
  end

  defp ignore_eof(ctx, pid) do
    %{os_pid: os_pid} = :sys.get_state(pid)
    MilkDrop.command(pid, %{cmd: "ignore_eof"})
    wait_until(fn -> cmd_lines(ctx) == [%{"cmd" => "ignore_eof"}] end)
    os_pid
  end
end
