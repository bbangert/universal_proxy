defmodule UniversalProxy.Audio.Input.Capture do
  @moduledoc """
  GenServer wrapping a single `arecord` OS process capturing PCM from
  one ALSA capture device.

  One `Audio.Input.Capture` per enabled capture card, supervised under
  a `DynamicSupervisor` (mirrors `UniversalProxy.Audio.Player`'s
  relationship to `Audio.PlayerSupervisor`). The process owns:

    * A `Port` opened with `{:spawn_executable, arecord_path}` in raw
      *stream* mode (no `{:line, _}` packet framing) — stdout is a
      continuous interleaved PCM byte stream, not line-delimited text.
    * Byte-accumulation across port messages so the subscriber always
      receives exact `frame_bytes`-sized chunks regardless of how the
      pipe happened to coalesce `arecord`'s writes.

  This is capture's sibling to `Audio.Player`'s playback Port, and
  much simpler: no bidirectional JSON IPC, no stdin commands, no mDNS
  — just a one-way PCM stream and an exit signal. See `Audio.Player`'s
  moduledoc ("Why raw Port (no MuonTrap)") for the shared rationale:
  `MuonTrap.Daemon` routes stdout through Logger, which would corrupt
  a binary PCM stream exactly as it would corrupt playback JSON.

  ## Wire format

  `arecord -D <alsa_device> -f S16_LE -r 48000 -c 2 -t raw -q -B 40000
  -F 20000` — 48 kHz stereo 16-bit little-endian, matching both native
  ALSA byte order on our ARM/x86 targets (no conversion) and the
  Sendspin `source@v1` PCM payload's wire order (only the binary
  frame's 8-byte timestamp header is big-endian, not the audio
  payload) — so no byte swap is needed anywhere in this path.
  `-B`/`-F` set a 40 ms buffer / 20 ms period, matching the 3,840-byte
  (20 ms @ 48k/16-bit stereo) default `frame_bytes`.

  `-q` silences arecord's own stderr chatter; deliberately NOT piped
  anywhere near stdout (see "No `:stderr_to_stdout`" below).

  ## Subscriber messages

  The `:subscriber` pid configured at `start_link/1` receives:

      {:capture_frame, ts_us, frame_binary}
      {:capture_exit, exit_status}

  `ts_us` is `System.os_time(:microsecond)` captured once per *port
  message arrival*, not once per emitted frame. A single port message
  routinely contains several `frame_bytes` chunks (arecord's period
  writes coalesce up to the pipe buffer); all frames sliced from one
  arrival share that arrival's timestamp rather than each getting its
  own read time. Downstream (`Sendspin.ClockFilter` and friends)
  tolerates this — the resulting jitter is bounded by one arrival's
  worth of frames (a handful of ms), well inside the filter's
  convergence tolerance — and it avoids a `System.os_time/1` call per
  20 ms frame for no measurable accuracy gain.

  ## Framing / alignment

  `frame_bytes` must be a multiple of 4 (2 channels × 2 bytes/sample
  for S16 stereo). Incoming bytes are accumulated onto an internal
  buffer; only complete `frame_bytes`-sized chunks are sliced off and
  emitted, and the byte remainder (0..frame_bytes-1 bytes) carries
  over to the next arrival. Because every slice offset is a multiple
  of `frame_bytes` (itself a multiple of 4), 4-byte sample alignment
  is preserved automatically — no separate alignment bookkeeping is
  needed.

  ## No `:stderr_to_stdout`

  Unlike some Port-wrapped tools, this port is opened WITHOUT
  `:stderr_to_stdout`. arecord's diagnostic text (xrun notices, etc.)
  would interleave into the raw PCM byte stream, corrupting audio
  data with no way to recover framing. Diagnostics are simply
  discarded (`-q` mostly silences them anyway); the observable failure
  signal is `{:exit_status, _}`.

  ## Binary-missing contract

  Mirrors `Audio.Player`: if `arecord_path` doesn't exist at `init/1`,
  `start_link/1` returns `{:error, {:binary_missing, path}}` instead
  of spawning a doomed Port. The owner (`Audio.Input.Server`, a later
  task) can remember this and skip retrying a capture card whose
  target has no arecord (see `research/capture-path.md` — x86_64 ships
  no arecord today).
  """

  # `:temporary` — mirrors `Audio.Player`: the parent DynamicSupervisor
  # never auto-restarts us. Respawn policy belongs to the owner
  # GenServer, which holds the per-card state (alsa_device, subscriber)
  # needed to spawn a sensible replacement; a supervisor-driven restart
  # would produce a fresh PID the owner doesn't know about.
  use GenServer, restart: :temporary

  require Logger

  @default_arecord_path "/usr/bin/arecord"
  # 20 ms @ 48 kHz / 16-bit / stereo: 48_000 * 2 * 2 * 0.020
  @default_frame_bytes 3_840

  defstruct [
    :alsa_device,
    :subscriber,
    :arecord_path,
    :frame_bytes,
    :args,
    port: nil,
    os_pid: nil,
    buffer: <<>>
  ]

  @type t :: %__MODULE__{
          alsa_device: String.t(),
          subscriber: pid(),
          arecord_path: String.t(),
          frame_bytes: pos_integer(),
          args: [String.t()] | nil,
          port: port() | nil,
          os_pid: pos_integer() | nil,
          buffer: binary()
        }

  # -- Client API --

  @doc """
  Start a capture process for one ALSA capture device.

  Opts:

    * `:alsa_device` (required) — e.g. `"plughw:1,0"`.
    * `:subscriber` (required) — pid to receive `:capture_frame` /
      `:capture_exit` messages.
    * `:arecord_path` — defaults to `#{@default_arecord_path}`.
    * `:frame_bytes` — defaults to `#{@default_frame_bytes}` (20 ms @
      48k/16/2). Must be a multiple of 4.
    * `:args` — test seam: full CLI argv override. When omitted the
      standard arecord argv is built from `:alsa_device`. Fake capture
      scripts used in tests ignore argv entirely, but this lets a test
      assert on/replace the exact argv without touching production
      argument-building logic.

  Returns `{:error, {:binary_missing, path}}` (not an exception) if
  `arecord_path` doesn't exist — see moduledoc.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @doc "Stop the capture process, running the terminate/2 cleanup."
  @spec stop(GenServer.server()) :: :ok
  def stop(server), do: GenServer.stop(server)

  # -- Server callbacks --

  @impl true
  def init(opts) do
    # Trap exits so a supervisor's :shutdown signal runs terminate/2
    # (Port.close + SIGKILL backstop) instead of killing us before we
    # can reap the OS process — same reasoning as Audio.Player.
    Process.flag(:trap_exit, true)

    alsa_device = Keyword.fetch!(opts, :alsa_device)
    subscriber = Keyword.fetch!(opts, :subscriber)
    arecord_path = Keyword.get(opts, :arecord_path) || @default_arecord_path
    frame_bytes = Keyword.get(opts, :frame_bytes, @default_frame_bytes)
    args = Keyword.get(opts, :args)

    state = %__MODULE__{
      alsa_device: alsa_device,
      subscriber: subscriber,
      arecord_path: arecord_path,
      frame_bytes: frame_bytes,
      args: args
    }

    if File.exists?(arecord_path) do
      port = open_port(state)

      # Port.info/2 returns nil if the port already closed between open
      # and this call (binary exited immediately — bad device, missing
      # libasound). force_kill/1 guards os_pid: nil, so pattern-match
      # instead of crashing init with a misleading error.
      os_pid =
        case Port.info(port, :os_pid) do
          {:os_pid, pid} -> pid
          nil -> nil
        end

      {:ok, %{state | port: port, os_pid: os_pid}}
    else
      Logger.error(
        "Audio.Input.Capture arecord binary missing at #{arecord_path}; " <>
          "refusing to start capture for #{alsa_device}"
      )

      {:stop, {:binary_missing, arecord_path}}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    # Stamped once per arrival, not per emitted frame — see moduledoc
    # "Subscriber messages".
    ts_us = System.os_time(:microsecond)
    buffer = state.buffer <> data
    {frames, remainder} = slice_frames(buffer, state.frame_bytes)

    Enum.each(frames, fn frame ->
      send(state.subscriber, {:capture_frame, ts_us, frame})
    end)

    {:noreply, %{state | buffer: remainder}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    send(state.subscriber, {:capture_exit, status})
    # Owner decides respawn policy (mirrors Audio.Player's
    # {:binary_exited, status} stop reason / Audio.Server convergence
    # pattern) — stop normally here since the exit was already
    # reported via the message, not the supervision tree.
    {:stop, :normal, %{state | port: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.port do
      safe_port_close(state.port)
    end

    force_kill(state)
    :ok
  end

  # -- Private --

  defp open_port(%__MODULE__{args: args} = state) when is_list(args) do
    Port.open(
      {:spawn_executable, String.to_charlist(state.arecord_path)},
      [:binary, :exit_status, {:args, args}]
    )
  end

  defp open_port(%__MODULE__{} = state) do
    Port.open(
      {:spawn_executable, String.to_charlist(state.arecord_path)},
      [:binary, :exit_status, {:args, build_args(state)}]
    )
  end

  defp build_args(%__MODULE__{alsa_device: alsa_device}) do
    [
      "-D",
      alsa_device,
      "-f",
      "S16_LE",
      "-r",
      "48000",
      "-c",
      "2",
      "-t",
      "raw",
      "-q",
      "-B",
      "40000",
      "-F",
      "20000"
    ]
  end

  # Slices complete frame_bytes-sized chunks off the front of `buffer`,
  # returning `{frames, remainder}`. Every slice offset is a multiple
  # of frame_bytes, which callers guarantee is itself a multiple of 4
  # — so 4-byte sample alignment falls out for free.
  defp slice_frames(buffer, frame_bytes) do
    frame_count = div(byte_size(buffer), frame_bytes)
    take = frame_count * frame_bytes
    <<complete::binary-size(^take), remainder::binary>> = buffer

    frames = for <<frame::binary-size(^frame_bytes) <- complete>>, do: frame

    {frames, remainder}
  end

  defp force_kill(%__MODULE__{os_pid: nil}), do: :ok

  defp force_kill(%__MODULE__{os_pid: pid}) do
    # SIGKILL via :os.cmd is portable and doesn't require muontrap.
    # The kernel reaps; we don't care about the result.
    _ = :os.cmd(~c"kill -9 #{pid} 2>/dev/null")
    :ok
  end

  defp safe_port_close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
