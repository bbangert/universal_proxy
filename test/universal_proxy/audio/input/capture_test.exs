defmodule UniversalProxy.Audio.Input.CaptureTest do
  # Each test writes its own uniquely-named fake capture script (no
  # shared global state — unlike Audio.PlayerTest's MdnsStub Agent),
  # so this suite is safe to run async.
  use ExUnit.Case, async: true

  alias UniversalProxy.Audio.Input.Capture

  @default_frame_bytes 3_840

  # Writes a tiny Python script standing in for `arecord`: it emits
  # `chunks` (a list of byte counts) as successive stdout writes —
  # each write flushed and, if `sleep_s > 0`, followed by a sleep so
  # the writes land as separate Port `{:data, _}` arrivals instead of
  # coalescing into one. The byte stream is a deterministic running
  # sequence (`byte[i] = i rem 256` across the WHOLE stream, not reset
  # per chunk) so tests can compute the expected content independent
  # of how it happened to be chunked. Exits with `exit_code`, unless
  # overridden at runtime via `--test-exit-code N` in argv — the
  # `:args` test seam uses that to prove Capture's argv actually
  # reaches the child process without colliding with the module's real
  # `-D`/`-f`/... flags (which the script otherwise ignores).
  defp write_fake_capture!(chunks, exit_code \\ 0, sleep_s \\ 0.0) do
    path =
      Path.join(
        System.tmp_dir!(),
        "capture_fake_#{System.unique_integer([:positive])}.py"
      )

    # NOT `inspect(chunks)`: Elixir's inspect renders lists of small
    # integers that fall in printable-ASCII range (e.g. 101 = "e") as
    # Erlang charlist literals (`~c"eee..."`), which is invalid Python.
    chunks_literal = "[" <> Enum.map_join(chunks, ", ", &Integer.to_string/1) <> "]"

    script = """
    #!/usr/bin/env python3
    import sys, time

    CHUNKS = #{chunks_literal}
    EXIT_CODE = #{exit_code}
    SLEEP_S = #{sleep_s}

    def main():
        exit_code = EXIT_CODE
        args = sys.argv[1:]
        if "--test-exit-code" in args:
            exit_code = int(args[args.index("--test-exit-code") + 1])

        pos = 0
        for size in CHUNKS:
            data = bytes((pos + i) % 256 for i in range(size))
            pos += size
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()
            if SLEEP_S > 0:
                time.sleep(SLEEP_S)

        sys.exit(exit_code)

    main()
    """

    File.write!(path, script)
    File.chmod!(path, 0o755)

    on_exit(fn -> File.rm(path) end)

    path
  end

  # The same running sequence the fake script writes: byte i = i rem 256.
  defp expected_binary(total) do
    for i <- 0..(total - 1), into: <<>>, do: <<rem(i, 256)>>
  end

  defp start_capture!(opts) do
    opts =
      opts
      |> Keyword.put_new(:subscriber, self())
      |> Keyword.put_new(:alsa_device, "plughw:1,0")

    start_supervised!({Capture, opts})
  end

  # Collects `:capture_frame` messages (each tagged with its arrival
  # timestamp) until `:capture_exit` arrives, then returns both.
  defp drain_until_exit(timeout \\ 2_000), do: drain_until_exit([], timeout)

  defp drain_until_exit(frames, timeout) do
    receive do
      {:capture_frame, ts_us, frame} -> drain_until_exit([{ts_us, frame} | frames], timeout)
      {:capture_exit, status} -> {Enum.reverse(frames), status}
    after
      timeout -> flunk("timed out waiting for :capture_exit")
    end
  end

  # These describes' tests all rely on the write_fake_capture!/3 Python
  # fixture standing in for `arecord`; :python3 is excluded automatically
  # in test_helper.exs when python3 isn't on PATH.
  describe "framing" do
    @describetag :python3

    test "delivers exact frame_bytes-sized frames with correct content" do
      path = write_fake_capture!([@default_frame_bytes * 2])
      _pid = start_capture!(arecord_path: path)

      {frames, status} = drain_until_exit()

      assert status == 0
      assert length(frames) == 2
      assert Enum.all?(frames, fn {_ts, frame} -> byte_size(frame) == @default_frame_bytes end)

      expected = expected_binary(@default_frame_bytes * 2)
      <<expected_1::binary-size(@default_frame_bytes), expected_2::binary>> = expected
      assert [{_, ^expected_1}, {_, ^expected_2}] = frames
    end

    test "frames sliced from a single arrival share one arrival timestamp" do
      # No inter-write sleep — both frames come from the same write(2),
      # which lands as one Port {:data, _} message.
      path = write_fake_capture!([@default_frame_bytes * 2])
      _pid = start_capture!(arecord_path: path)

      {frames, _status} = drain_until_exit()

      assert [{ts_1, _}, {ts_2, _}] = frames
      assert ts_1 == ts_2
    end

    test "produces non-decreasing timestamps across separate port arrivals" do
      path = write_fake_capture!([@default_frame_bytes, @default_frame_bytes], 0, 0.05)
      _pid = start_capture!(arecord_path: path)

      {frames, status} = drain_until_exit(3_000)

      assert status == 0
      assert [{ts_1, _}, {ts_2, _}] = frames
      assert ts_2 >= ts_1
    end

    test "reframes across arbitrary chunk splits and carries the remainder across arrivals" do
      # 1000 + 5000 = 6000 bytes: one complete 3,840-byte frame plus a
      # 2,160-byte remainder that is never emitted (the process exits
      # before it completes a frame). Sleep between writes forces two
      # separate arrivals so the split lands mid-frame.
      path = write_fake_capture!([1_000, 5_000], 3, 0.05)
      _pid = start_capture!(arecord_path: path)

      {frames, status} = drain_until_exit()

      assert status == 3
      assert [{_ts, frame}] = frames
      assert byte_size(frame) == @default_frame_bytes
      assert frame == binary_part(expected_binary(6_000), 0, @default_frame_bytes)
    end

    test "reframes across many small non-4-aligned-length chunks without corrupting content" do
      # 40 x 101-byte writes = 4,040 bytes: one complete 3,840-byte
      # frame plus a 200-byte remainder. 101 is not a multiple of 4, so
      # several of these writes split a 16-bit stereo sample across two
      # arrivals — output-frame alignment still holds because every
      # emitted slice offset is a multiple of frame_bytes (itself a
      # multiple of 4), independent of how the raw stream was chunked.
      chunks = List.duplicate(101, 40)
      path = write_fake_capture!(chunks, 0, 0.002)
      _pid = start_capture!(arecord_path: path)

      {frames, status} = drain_until_exit(3_000)

      assert status == 0
      assert [{_ts, frame}] = frames
      assert frame == binary_part(expected_binary(4_040), 0, @default_frame_bytes)
    end

    test "supports a custom :frame_bytes size" do
      path = write_fake_capture!([250])
      _pid = start_capture!(arecord_path: path, frame_bytes: 100)

      {frames, status} = drain_until_exit()

      assert status == 0
      assert length(frames) == 2
      assert Enum.all?(frames, fn {_ts, frame} -> byte_size(frame) == 100 end)

      expected = binary_part(expected_binary(250), 0, 200)
      assert Enum.map(frames, fn {_ts, frame} -> frame end) |> IO.iodata_to_binary() == expected
    end
  end

  describe "exit propagation" do
    @describetag :python3

    test "propagates the exit status with no frames when no data is written" do
      path = write_fake_capture!([], 7)
      _pid = start_capture!(arecord_path: path)

      {frames, status} = drain_until_exit()

      assert frames == []
      assert status == 7
    end

    test "propagates a nonzero exit status alongside any complete frames" do
      path = write_fake_capture!([@default_frame_bytes], 9)
      _pid = start_capture!(arecord_path: path)

      {frames, status} = drain_until_exit()

      assert length(frames) == 1
      assert status == 9
    end
  end

  describe "binary_missing" do
    test "returns {:error, {:binary_missing, path}} instead of spawning a doomed port" do
      # trap_exit so start_link's {:stop, _} init return reports
      # {:error, _} to this test process instead of an :EXIT signal
      # tearing it down. ExUnit gives each test its own process, so
      # the flag dies with the test — no cleanup needed.
      Process.flag(:trap_exit, true)

      assert {:error, {:binary_missing, "/tmp/definitely-not-arecord"}} =
               Capture.start_link(
                 alsa_device: "plughw:9,0",
                 subscriber: self(),
                 arecord_path: "/tmp/definitely-not-arecord"
               )
    end
  end

  describe ":args test seam" do
    @describetag :python3

    test "overrides the built-in argv, proving argv reaches the child process" do
      path = write_fake_capture!([])
      _pid = start_capture!(arecord_path: path, args: ["--test-exit-code", "42"])

      {frames, status} = drain_until_exit()

      assert frames == []
      assert status == 42
    end

    test "default argv (no :args override) still runs the fake script normally" do
      path = write_fake_capture!([@default_frame_bytes], 0)
      _pid = start_capture!(arecord_path: path)

      {frames, status} = drain_until_exit()

      assert length(frames) == 1
      assert status == 0
    end
  end
end
